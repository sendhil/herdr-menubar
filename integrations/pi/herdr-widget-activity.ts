import {createHash} from 'node:crypto';
import {mkdir, writeFile, rename} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join} from 'node:path';

// Hashes are used only in memory for conservative input/message correlation.
export class ActivityMatcher {
 private pending: {digest:string; source:string; at:number}[] = [];
 private digest(content: unknown) { return createHash('sha256').update(JSON.stringify(content)).digest('hex'); }
 clear() { this.pending = []; }
 input(text:string, images:any[], source:string, at:number) {
  const content = [{type:'text',text}, ...images];
  const digest = this.digest(content);
  // Ambiguous repeated input supersedes the old candidate, never borrowing its provenance.
  this.pending = this.pending.filter(x => x.digest !== digest && at-x.at < 7_200_000).slice(-127);
  this.pending.push({digest,source,at});
 }
 message(message:any, now:number):number|null {
  if(message?.role !== 'user' || !Array.isArray(message.content)) return null;
  const digest = this.digest(message.content);
  const candidate = this.pending.find(x=>x.digest===digest);
  this.pending = this.pending.filter(x=>x.digest!==digest && now-x.at < 7_200_000);
  return candidate?.source==='interactive' && now>=candidate.at && now-candidate.at<7_200_000 ? candidate.at : null;
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
