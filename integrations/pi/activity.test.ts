import {test, expect} from 'bun:test';
import {ActivityMatcher} from './herdr-widget-activity';
test('only matching interactive messages qualify', () => {
 const m = new ActivityMatcher();
 m.input('hello', [], 'interactive', 100);
 expect(m.message({role:'assistant',content:[{type:'text',text:'hello'}]}, 110)).toBeNull();
 expect(m.message({role:'user',content:[{type:'text',text:'hello'}]}, 110)).toBe(100);
 expect(m.message({role:'user',content:[{type:'text',text:'hello'}]}, 120)).toBeNull();
});
test('automated and unmatched transformed prompts do not qualify', () => {
 const m = new ActivityMatcher();
 m.input('auto', [], 'extension', 100);
 expect(m.message({role:'user',content:[{type:'text',text:'auto'}]},110)).toBeNull();
 m.input('raw', [], 'interactive', 100);
 expect(m.message({role:'user',content:[{type:'text',text:'transformed'}]},110)).toBeNull();
});
test('new automated input with the same text invalidates earlier human candidate', () => {
 const m = new ActivityMatcher();
 m.input('same', [], 'interactive', 100);
 m.input('same', [], 'rpc', 105);
 expect(m.message({role:'user',content:[{type:'text',text:'same'}]},110)).toBeNull();
});
test('reset prevents cross-session attribution', () => {
 const m = new ActivityMatcher();
 m.input('hello', [], 'interactive', 100);
 m.clear();
 expect(m.message({role:'user',content:[{type:'text',text:'hello'}]},110)).toBeNull();

});

test('companion persists only the correlated timestamp for the exact session', async () => {
 const {installActivity: install} = await import('./herdr-widget-activity');
 const {mkdtemp, readFile, readdir, rm} = await import('node:fs/promises');
 const {createHash} = await import('node:crypto');
 const root = await mkdtemp('/tmp/herdr-widget-test-');
 const previousPane = process.env.HERDR_PANE_ID;
 process.env.HERDR_PANE_ID = 'test:p1';
 try {
  const handlers = new Map<string,Function>();
  install({on:(name:string,handler:Function)=>handlers.set(name,handler)},root+'/.local/share/herdr-widgets/activity');
  const ctx = {hasUI:true,sessionManager:{getSessionFile:()=>'/test/session.jsonl'}};
  handlers.get('session_start')!({},ctx);
  handlers.get('input')!({text:'human',source:'interactive'},ctx);
  handlers.get('message_start')!({message:{role:'user',content:[{type:'text',text:'human'}]}},ctx);
  await handlers.get('session_shutdown')!();
  const key = createHash('sha256').update('/test/session.jsonl').digest('hex');
  const directory = root+'/.local/share/herdr-widgets/activity';
  const record = JSON.parse(await readFile(directory+'/'+key+'.json','utf8'));
  expect(record.source).toBe('interactive-confirmed');
  expect(record.sentAtMilliseconds).toBeGreaterThan(0);
  expect(Object.keys(record).sort()).toEqual(['sentAtMilliseconds','source','version']);
  expect(await readdir(directory)).toEqual([key+'.json']);
 } finally {
  if(previousPane===undefined) delete process.env.HERDR_PANE_ID; else process.env.HERDR_PANE_ID=previousPane;
  await rm(root,{recursive:true,force:true});
 }
});

const userMessage = (text:string) => ({role:'user',content:[{type:'text',text}]});
for (const sources of [['extension','interactive'],['interactive','extension'],['interactive','interactive']]) {
 test(`overlapping identical input remains ambiguous: ${sources.join(' then ')}`, () => {
  const m = new ActivityMatcher();
  m.input('continue',[],sources[0],100);
  m.input('continue',[],sources[1],200);
  expect(m.message(userMessage('continue'),210)).toBeNull();
  expect(m.message(userMessage('continue'),220)).toBeNull();
  // Cancellation is not observable: a later input must not adopt a surviving old delivery.
  m.input('continue',[],'interactive',230);
  expect(m.message(userMessage('continue'),240)).toBeNull();
  m.input('different',[],'interactive',250);
  expect(m.message(userMessage('different'),260)).toBe(250);
 });
}
test('human follow-up remains eligible after a queue longer than two hours', () => {
 const m = new ActivityMatcher();
 m.input('long queued',[],'interactive',100);
 m.input('other',[],'extension',7_200_200);
 expect(m.message(userMessage('other'),7_200_210)).toBeNull();
 expect(m.message(userMessage('long queued'),7_200_300)).toBe(100);
});
test('capacity exhaustion fails closed rather than losing older provenance', () => {
 const m = new ActivityMatcher();
 m.input('old automated',[],'extension',1);
 for(let i=0;i<1100;i++) m.input(`pending ${i}`,[],'interactive',i+2);
 m.input('old automated',[],'interactive',2000);
 expect(m.message(userMessage('old automated'),2100)).toBeNull();
 expect(m.message(userMessage('pending 1099'),2100)).toBeNull();
 m.clear();
 m.input('fresh session',[],'interactive',2200);
 expect(m.message(userMessage('fresh session'),2300)).toBe(2200);
});
test('session reset releases ambiguity for a new session', () => {
 const m = new ActivityMatcher();
 m.input('same',[],'extension',1);
 m.input('same',[],'interactive',2);
 m.clear();
 m.input('same',[],'interactive',3);
 expect(m.message(userMessage('same'),4)).toBe(3);
});

for(const resetEvent of ['session_start','session_tree']) {
 test(`${resetEvent} prevents old pending input from writing activity`, async () => {
  const {installActivity} = await import('./herdr-widget-activity');
  const {mkdtemp,readdir,rm} = await import('node:fs/promises');
  const root = await mkdtemp('/tmp/herdr-widget-lifecycle-');
  const previousPane = process.env.HERDR_PANE_ID;
  process.env.HERDR_PANE_ID = 'test:p1';
  try {
   const handlers = new Map<string,Function>();
   installActivity({on:(name:string,handler:Function)=>handlers.set(name,handler)},root);
   let sessionFile = '/test/old.jsonl';
   const ctx = {hasUI:true,sessionManager:{getSessionFile:()=>sessionFile}};
   handlers.get('session_start')!({},ctx);
   handlers.get('input')!({text:'old queued',source:'interactive'},ctx);
   if(resetEvent==='session_start') sessionFile='/test/new.jsonl';
   handlers.get(resetEvent)!({},ctx);
   handlers.get('message_start')!({message:userMessage('old queued')},ctx);
   await handlers.get('session_shutdown')!();
   expect(await readdir(root)).toEqual([]);
  } finally {
   if(previousPane===undefined) delete process.env.HERDR_PANE_ID; else process.env.HERDR_PANE_ID=previousPane;
   await rm(root,{recursive:true,force:true});
  }
 });
}
test('ambiguous automated delivery cannot persist a human timestamp when later input is canceled', async () => {
 const {installActivity} = await import('./herdr-widget-activity');
 const {mkdtemp,readdir,rm} = await import('node:fs/promises');
 const root = await mkdtemp('/tmp/herdr-widget-ambiguity-');
 const previousPane = process.env.HERDR_PANE_ID;
 process.env.HERDR_PANE_ID = 'test:p1';
 try {
  const handlers = new Map<string,Function>();
  installActivity({on:(name:string,handler:Function)=>handlers.set(name,handler)},root);
  const ctx = {hasUI:true,sessionManager:{getSessionFile:()=>'/test/session.jsonl'}};
  handlers.get('session_start')!({},ctx);
  handlers.get('input')!({text:'continue',source:'extension'},ctx);
  handlers.get('input')!({text:'continue',source:'interactive'},ctx);
  handlers.get('message_start')!({message:userMessage('continue')},ctx);
  // Only the earlier automated item is delivered. The human item is canceled.
  await handlers.get('session_shutdown')!();
  expect(await readdir(root)).toEqual([]);
 } finally {
  if(previousPane===undefined) delete process.env.HERDR_PANE_ID; else process.env.HERDR_PANE_ID=previousPane;
  await rm(root,{recursive:true,force:true});
 }
});
