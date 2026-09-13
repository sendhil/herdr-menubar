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
test('reset and expiration prevent cross-session attribution', () => {
 const m = new ActivityMatcher();
 m.input('hello', [], 'interactive', 100);
 m.clear();
 expect(m.message({role:'user',content:[{type:'text',text:'hello'}]},110)).toBeNull();
 m.input('hello', [], 'interactive', 100);
 expect(m.message({role:'user',content:[{type:'text',text:'hello'}]},7_200_101)).toBeNull();
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
