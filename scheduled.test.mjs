import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { Scheduler, calendar, validate } from './scheduled.mjs';
import { execute } from './scheduled-process.mjs';
const config={version:1,name:'oracle',repository:'owner/repo',ref:'main',timezone:'America/Los_Angeles',startDate:'2026-10-22',prepareAt:'03:00',startAt:'04:00',endAt:'06:00',reportAt:'06:15',command:['bash','scripts/oracle-scheduled.sh'],report:'verification/report.json'};
async function fixture(date='2026-10-22') {
 const state=await mkdtemp(resolve(tmpdir(),'scheduled-contract-')),plan=calendar(date,config),calls=[],messages=[];let now=plan.prepare;
 const scheduler=new Scheduler(config,{state,now:()=>now,env:{SLACK_WEBHOOK_URL:'https://example.invalid/secret'},run:async(argv,options)=>{calls.push({argv,options});},fetcher:async(url,options)=>{messages.push(JSON.parse(options.body));return {ok:true,text:async()=>'ok'};}});
 return {state,plan,scheduler,calls,messages,set:value=>{now=value;},close:()=>rm(state,{recursive:true,force:true})};
}
test('calendar follows Los Angeles DST including transition dates',()=>{
 for(const [date,hour] of [['2026-01-15',12],['2026-07-15',11],['2026-03-08',11],['2026-11-01',12]]) {const p=calendar(date,config);assert.equal(new Date(p.start).getUTCHours(),hour);assert.equal(p.end-p.start,7200000);}
 assert.throws(()=>validate({...config,startDate:'2026-02-30'}));assert.throws(()=>validate({...config,report:'../secret'}));
 assert.throws(()=>validate({...config,startAt:'02:30',prepareAt:'01:00',startDate:'2026-03-08'}));
});
test('restart reports interrupted and offline days without rerunning campaigns',async()=>{
 const f=await fixture('2026-10-24');try {
 await f.scheduler.store({date:'2026-10-22',status:'running',plan:calendar('2026-10-22',config)});
 await f.scheduler.initialize();f.set(f.plan.start);await f.scheduler.tick();
 assert.deepEqual((await f.scheduler.records()).map(r=>r.status),['interrupted','missed','missed']);assert.equal(f.calls.length,1);assert.match(f.calls[0].argv[1],/scheduled-cleanup/);
 assert.equal(f.messages.length,3);await f.scheduler.tick();assert.equal(f.messages.length,3);
 } finally {await f.close();}
});
test('Slack failures retry and concurrent sends deduplicate without retaining secrets',async()=>{
 const f=await fixture();try {
 const record={date:f.plan.date,status:'failed',plan:f.plan,error:'Execution failed'};await f.scheduler.store(record);
 f.scheduler.fetcher=async()=>{throw Error('https://example.invalid/secret');};await f.scheduler.notify(record);
 const stored=(await f.scheduler.records())[0];assert.ok(stored.nextNotifyAt);assert.equal(stored.deliveredAt,undefined);
 f.set(stored.nextNotifyAt);let count=0;f.scheduler.fetcher=async()=>{count++;await new Promise(r=>setTimeout(r,20));return {ok:true,text:async()=>'ok'};};
 await Promise.all([f.scheduler.notify(record),f.scheduler.notify(record)]);assert.equal(count,1);
 assert.doesNotMatch(await readFile(resolve(f.scheduler.directory(record.date),'notifications.jsonl'),'utf8'),/secret/);
 } finally {await f.close();}
});
test('failed preparation retains failure, performs owned cleanup and reports once',async()=>{
 const f=await fixture();try {
 f.scheduler.run=async(argv,options)=>{f.calls.push({argv,options});if(argv[0]==='git')throw Error('clone failed');};
 await f.scheduler.initialize();await f.scheduler.tick();await f.scheduler.active;
 const [r]=await f.scheduler.records();assert.equal(r.status,'failed');assert.equal(r.cleaned,true);assert.equal(f.messages.length,1);assert.equal(f.calls[0].options.env.SLACK_WEBHOOK_URL,undefined);
 await f.scheduler.tick();assert.equal(f.messages.length,1);
 } finally {await f.close();}
});
test('processes retain complete output and exit status and terminate on deadline',async()=>{
 const parent=await mkdtemp(resolve(tmpdir(),'scheduled-process-'));try {
 const log=resolve(parent,'full.log');await execute([process.execPath,'-e','process.stdout.write("x".repeat(200000));process.stderr.write("error marker")'],{log,deadline:Date.now()+5000});assert.equal((await readFile(log)).length,200012);
 await assert.rejects(execute(['bash','-c','exit 17'],{log:resolve(parent,'fail.log'),deadline:Date.now()+5000}));assert.equal(JSON.parse(await readFile(resolve(parent,'fail.log.result.json'))).exitCode,17);
 await assert.rejects(execute(['bash','-c','sleep 30 & wait'],{log:resolve(parent,'timeout.log'),deadline:Date.now()+100}));assert.match(JSON.parse(await readFile(resolve(parent,'timeout.log.result.json'))).error,/deadline/);
 } finally {await rm(parent,{recursive:true,force:true});}
});
test('completed command requires matching full-window evidence; premature and mismatched reports fail',async()=>{
 for(const mode of ['valid','premature','wrong-revision','missing-report']) {
 const f=await fixture();try {
 const record={date:f.plan.date,status:'running',plan:f.plan};await f.scheduler.store(record);
 f.scheduler.run=async(argv,options)=>{
  if(argv.includes('rev-parse'))return 'a'.repeat(40)+'\n';
  if(argv[0]==='bash' && argv[1]==='scripts/oracle-scheduled.sh') {
   const { save }=await import('./scheduled-process.mjs');
   if(mode!=='missing-report')await save(resolve(f.scheduler.directory(record.date),'verification/report.json'),{status:'passed',revision:(mode==='wrong-revision'?'b':'a').repeat(40),plan:f.plan});
   f.set(mode==='premature'?f.plan.end-1:f.plan.end);
  }
  if(argv.includes('worktree')) {
   const { mkdir }=await import('node:fs/promises');await mkdir(argv.at(-2),{recursive:true});
  }
  return '';
 };
 await f.scheduler.job(record,f.plan);
 assert.equal((await f.scheduler.records())[0].status,mode==='valid'?'passed':'failed',mode);
 assert.equal(f.messages.length,1);
 } finally {await f.close();}
 }
});
