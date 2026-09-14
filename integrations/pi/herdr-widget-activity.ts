import {createHash} from 'node:crypto';
import {mkdir, writeFile, rename} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join} from 'node:path';

// Hashes are used only in memory for conservative input/message correlation.
export class ActivityMatcher {
 // A null value is an ambiguity tombstone, retained until session reset. Delivery
 // events have no submission ID, so neither order nor cancellation can resolve it.
 private pending = new Map<string, {source:string; at:number} | null>();
 private saturated = false;
 private static readonly capacity = 1024;
 private digest(content: unknown) { return createHash('sha256').update(JSON.stringify(content)).digest('hex'); }
 clear() { this.pending.clear(); this.saturated = false; }
 input(text:string, images:any[], source:string, at:number) {
  if(this.saturated) return;
  const digest = this.digest([{type:'text',text}, ...images]);
  if(this.pending.has(digest)) {
   this.pending.set(digest,null);
   return;
  }
  if(this.pending.size >= ActivityMatcher.capacity) {
   // Eviction could let a later input claim an old automated delivery. Stop
   // correlating until lifecycle reset instead of forgetting provenance.
   this.pending.clear();
   this.saturated = true;
   return;
  }
  // Queued messages can legitimately wait for hours. Retain candidates until
  // delivery/reset rather than making capture depend on an arbitrary timeout.
  this.pending.set(digest,{source,at});
 }
 message(message:any, now:number):number|null {
  if(this.saturated || message?.role !== 'user' || !Array.isArray(message.content)) return null;
  const digest = this.digest(message.content);
  const candidate = this.pending.get(digest);
  if(!candidate) return null;
  this.pending.delete(digest);
  // Correlation still cannot prove the origin of arbitrary injected messages
  // that bypass input events. Pi needs submission IDs for exact provenance.
  return candidate.source==='interactive' && now>=candidate.at ? candidate.at : null;
 }
}

export default function(pi:any) {
 return installActivity(pi,join(homedir(),'.local','share','herdr-widgets','activity'));
}

export function installActivity(pi:any,directory:string) {
 const matcher = new ActivityMatcher();
 let session = '';
 let lastRecorded = 0;
 let writing = Promise.resolve();
 const reset = (_event:any,ctx:any) => { matcher.clear(); lastRecorded = 0; session = ctx.sessionManager.getSessionFile() ?? ''; };
 pi.on('session_start',reset);
 pi.on('session_tree',reset);
 pi.on('input',(event:any,ctx:any)=>{
  if(ctx.hasUI && process.env.HERDR_PANE_ID) matcher.input(event.text,event.images??[],event.source,Date.now());
  return {action:'continue'};
 });
 pi.on('message_start',(event:any,ctx:any)=>{
  const at = matcher.message(event.message,Date.now());
  const current = ctx.sessionManager.getSessionFile() ?? '';
  if(at===null || !current || current!==session || !ctx.hasUI || !process.env.HERDR_PANE_ID) return;
  const sentAt = Math.max(at,lastRecorded);
  lastRecorded = sentAt;
  const key = createHash('sha256').update(current).digest('hex');
  writing = writing.then(async()=>{
   await mkdir(directory,{recursive:true,mode:0o700});
   const target = join(directory,key+'.json');
   const temp = target+'.'+process.pid+'.tmp';
   await writeFile(temp,JSON.stringify({version:1,source:'interactive-confirmed',sentAtMilliseconds:sentAt}),{mode:0o600});
   await rename(temp,target);
  }).catch(()=>{}); // Activity capture must never interrupt the user's agent.
 });
 pi.on('session_shutdown', async()=>{matcher.clear();await writing;});
}
