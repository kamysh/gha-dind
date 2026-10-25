import { readFile, readdir, mkdir, rm, appendFile } from 'node:fs/promises';
import { resolve, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { save, execute } from './scheduled-process.mjs';

const dayMs=86400000;
const terminal=new Set(['passed','failed','interrupted','missed']);
const minute=value=>{
  if(!/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value??''))throw new Error('Schedule times must be HH:MM');
  return Number(value.slice(0,2))*60+Number(value.slice(3));
};
export function validate(config) {
  if(config.version!==1 || !/^[a-z0-9][a-z0-9-]{0,40}$/.test(config.name??''))throw new Error('Invalid scheduled job identity');
  if(!/^[\w.-]+\/[\w.-]+$/.test(config.repository??'') || !/^[\w./-]+$/.test(config.ref??'') || config.ref.includes('..'))throw new Error('Explicit GitHub repository/ref required');
  if(!Array.isArray(config.command) || !config.command.length || config.command.some(v=>typeof v!=='string' || !v || v.includes('\0')))throw new Error('Explicit command argument array required');
  if(isAbsolute(config.report??'') || !config.report || config.report.split('/').includes('..'))throw new Error('Relative result-report path required');
  new Intl.DateTimeFormat('en-CA',{timeZone:config.timezone});
  const times=['prepareAt','startAt','endAt','reportAt'].map(k=>minute(config[k]));
  if(times.some((v,i)=>i && v<=times[i-1]) || times[3]-times[2]<10)throw new Error('Ordered same-day preparation/window/report times and ten-minute cleanup are required');
  calendar(config.startDate,config);
  return config;
}
const formatter=timezone=>new Intl.DateTimeFormat('en-CA',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
const parts=(time,timezone)=>Object.fromEntries(formatter(timezone).formatToParts(new Date(time)).map(p=>[p.type,p.value]));
export function localDate(time,timezone) {
  const p=parts(time,timezone);return `${p.year}-${p.month}-${p.day}`;
}
function instant(date,time,timezone) {
  if(!/^\d{4}-\d{2}-\d{2}$/.test(date??''))throw new Error('Explicit schedule start date required');
  const day=Date.parse(date+'T00:00:00Z');
  if(!Number.isFinite(day) || new Date(day).toISOString().slice(0,10)!==date)throw new Error('Invalid schedule date');
  const target=day+minute(time)*60000,candidates=new Set();
  for(let hour=-36;hour<=36;hour+=6) {
    const probe=day+hour*3600000,p=parts(probe,timezone);
    const offset=Date.UTC(+p.year,+p.month-1,+p.day,+p.hour,+p.minute,+p.second)-probe;
    const candidate=target-offset,q=parts(candidate,timezone);
    if(`${q.year}-${q.month}-${q.day}`===date && `${q.hour}:${q.minute}`===time)candidates.add(candidate);
  }
  if(candidates.size!==1)throw new Error('Missing or ambiguous local schedule instant');
  return [...candidates][0];
}
export function calendar(date,config) {
  const plan={date,timezone:config.timezone};
  for(const [field,key] of [['prepare','prepareAt'],['start','startAt'],['end','endAt'],['report','reportAt']])plan[field]=instant(date,config[key],config.timezone);
  if(!(plan.prepare<plan.start && plan.start<plan.end && plan.end+600000<=plan.report))throw new Error('Invalid resolved schedule');
  return plan;
}
async function json(file) {try{return JSON.parse(await readFile(file,'utf8'));}catch(error){if(error.code==='ENOENT')return undefined;throw error;}}

export class Scheduler {
  constructor(config,{state='/scheduled',now=Date.now,run=execute,fetcher=fetch,env=process.env,signal}={}) {
    this.config=validate(config);this.state=state;this.now=now;this.run=run;this.fetcher=fetcher;this.env=env;this.signal=signal;this.active=undefined;this.deliveries=new Set();
  }
  directory(date){return resolve(this.state,'runs',date);}
  async records() {
    await mkdir(resolve(this.state,'runs'),{recursive:true,mode:0o700});
    const rows=[];
    for(const entry of await readdir(resolve(this.state,'runs'),{withFileTypes:true})) {
      if(!entry.isDirectory() || !/^\d{4}-\d{2}-\d{2}$/.test(entry.name))continue;
      const record=await json(resolve(this.directory(entry.name),'record.json'));if(record)rows.push(record);
    }
    return rows.sort((a,b)=>a.date.localeCompare(b.date));
  }
  async store(record){await save(resolve(this.directory(record.date),'record.json'),record);}
  async cleanup(record) {
    const log=resolve(this.directory(record.date),`cleanup-${Date.now()}-${Math.random().toString(16).slice(2)}.log`);
    record.cleanupLog=log;
    await this.run(['bash','/usr/local/bin/scheduled-cleanup.sh'],{log,deadline:Date.now()+60000});
    await rm(resolve(this.state,'work',record.date),{recursive:true,force:true});
    record.cleaned=true;
  }
  async initialize() {
    for(const record of await this.records())if(record.status==='running') {
      record.status='interrupted';record.error='Scheduler restarted during this attempt; no catchup run is credited';
      try{await this.cleanup(record);}catch{record.error+='; recovery cleanup failed';}
      record.finishedAt=new Date(this.now()).toISOString();await this.store(record);
    }
    const today=localDate(this.now(),this.config.timezone);
    for(let date=this.config.startDate;date<today;date=new Date(Date.parse(date+'T00:00:00Z')+dayMs).toISOString().slice(0,10)) {
      if(!await json(resolve(this.directory(date),'record.json')))await this.store({version:1,date,plan:calendar(date,this.config),status:'missed',error:'Scheduler was unavailable; no catchup campaign was launched'});
    }
    await save(resolve(this.state,'controller.json'),{status:'ready',job:this.config.name,startedAt:new Date(this.now()).toISOString(),heartbeat:this.now()});
  }
  async notify(record) {
    if(this.deliveries.has(record.date))return;
    this.deliveries.add(record.date);
    try {await this.deliver(record.date);} finally {this.deliveries.delete(record.date);}
  }
  async deliver(date) {
    const record=await json(resolve(this.directory(date),'record.json'));
    if(!record)return;
    if(!terminal.has(record.status) || record.deliveredAt || (record.nextNotifyAt??0)>this.now())return;
    const summary=record.summary;
    const text=`${this.config.name} ${record.status.toUpperCase()} — ${record.date}, ${this.config.startAt}–${this.config.endAt} ${record.plan.timezone}\n`+
      `Source: ${record.revision??'not established'}; campaign: ${summary?.plan?.campaign?.id??'not established'}.\n`+
      `Evidence: gha-scheduled-${this.config.name}-state:/runs/${record.date}\n`+
      `Result identity: ${this.config.name}/${record.date}. ${record.error??'Execution and cleanup completed.'}`;
    const attempt={at:new Date(this.now()).toISOString(),status:'failed'};
    try {
      const webhook=this.env.SLACK_WEBHOOK_ENGINEERING_URL || this.env.SLACK_WEBHOOK_URL;
      if(!webhook || new URL(webhook).protocol!=='https:')throw new Error();
      const response=await this.fetcher(webhook,{method:'POST',redirect:'error',headers:{'Content-Type':'application/json'},body:JSON.stringify({text}),signal:AbortSignal.timeout(15000)});
      if(!response.ok || (await response.text()).trim()!=='ok')throw new Error();
      record.deliveredAt=new Date(this.now()).toISOString();attempt.status='sent';delete record.nextNotifyAt;
    } catch {record.nextNotifyAt=this.now()+5*60000;}
    await appendFile(resolve(this.directory(record.date),'notifications.jsonl'),JSON.stringify(attempt)+'\n',{mode:0o600});
    await this.store(record);
  }
  async job(record,plan) {
    const directory=this.directory(record.date),work=resolve(this.state,'work',record.date),repository=resolve(work,'repository'),checkout=resolve(work,'checkout');
    const environment={...this.env,CI:'true',GOTOOLCHAIN:'local'};
    for(const key of Object.keys(environment))if(/^(SLACK_|RUNNER_TOKEN$|PAT_FILE$)/.test(key))delete environment[key];
    let sequence=0;
    const command=(argv,{cwd,capture=false,deadline=plan.start}={})=>this.run(argv,{cwd,env:environment,capture,signal:this.signal,deadline,log:resolve(directory,`${++sequence}-command.log`)});
    try {
      await mkdir(work,{recursive:true,mode:0o700});
      await command(['git','-c','credential.helper=','-c','credential.helper=!/usr/local/bin/scheduled-credential.sh','clone','--no-checkout',`https://github.com/${this.config.repository}.git`,repository]);
      record.revision=(await command(['git','-C',repository,'rev-parse','--verify',`refs/remotes/origin/${this.config.ref}^{commit}`],{capture:true})).trim();
      if(!/^[a-f0-9]{40}$/.test(record.revision))throw new Error('Invalid pinned source revision');
      await this.store(record);
      await command(['git','-C',repository,'worktree','add','--detach',checkout,record.revision]);
      const expectedNode=await readFile(resolve(checkout,'.node-version'),'utf8').catch(error=>{if(error.code==='ENOENT')return '';throw error;});
      if(expectedNode && expectedNode.trim()!==process.versions.node)throw new Error('Required Node version is not baked into this scheduler image');
      const module=await readFile(resolve(checkout,'services/engine-go/go.mod'),'utf8').catch(error=>{if(error.code==='ENOENT')return '';throw error;});
      const expectedGo=/^go\s+(\S+)/m.exec(module)?.[1];
      if(expectedGo && !(await command(['go','version'],{capture:true})).includes(`go${expectedGo} `))throw new Error('Required Go version is not baked into this scheduler image');
      Object.assign(environment,{SCHEDULED_JOB_DATE:record.date,SCHEDULED_JOB_START_AT:new Date(plan.start).toISOString(),SCHEDULED_JOB_END_AT:new Date(plan.end).toISOString(),
        SCHEDULED_JOB_OUTPUT:resolve(directory,'verification'),CODEX_VERIFICATION_STATE:resolve(directory,'committed-verification')});
      await command(this.config.command,{cwd:checkout,deadline:plan.end+10*60000});
      const summary=await json(resolve(directory,this.config.report));
      record.summary=summary;
      if(!summary || summary.status!=='passed' || summary.revision!==record.revision || summary.plan?.date!==record.date || summary.plan?.timezone!==plan.timezone ||
        summary.plan?.start!==plan.start || summary.plan?.end!==plan.end || this.now()<plan.end)throw new Error('Missing, incomplete or premature campaign evidence');
      record.status='passed';
    } catch {
      record.status=this.signal?.aborted?'interrupted':'failed';record.error='Preparation/execution failed; inspect complete command logs and campaign evidence';
      try{record.summary=await json(resolve(directory,this.config.report));}catch{ /* Raw malformed report remains retained. */ }
    } finally {
      try{await this.cleanup(record);}catch{record.status='failed';record.error='Owned cleanup failed; inspect retained cleanup log';}
      record.finishedAt=new Date(this.now()).toISOString();await this.store(record);await this.notify(record);
    }
  }
  async tick() {
    const now=this.now(),date=localDate(now,this.config.timezone);
    if(date>=this.config.startDate) {
      const plan=calendar(date,this.config),path=resolve(this.directory(date),'record.json');
      if(now>=plan.prepare && !this.active && !await json(path)) {
        const record={version:1,date,plan,status:now<plan.start?'running':'missed',startedAt:new Date(now).toISOString()};
        await this.store(record);
        if(record.status==='running') {
          this.active=this.job(record,plan).catch(async()=>{record.status='failed';record.error='Supervisor failure';await this.store(record);}).finally(()=>{this.active=undefined;});
        } else {record.error='Preparation window was missed; no late campaign was launched';await this.store(record);}
      }
    }
    for(const record of await this.records()) {
      await this.notify(record);
      await save(resolve(this.state,'heartbeat.json'),{at:this.now(),job:this.config.name,active:Boolean(this.active)});
    }
    await save(resolve(this.state,'heartbeat.json'),{at:this.now(),job:this.config.name,active:Boolean(this.active)});
  }
}

if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const mode=process.argv[2]??'run',state=process.env.SCHEDULED_STATE??'/scheduled';
  if(mode==='health') {
    const heartbeat=await json(resolve(state,'heartbeat.json'));
    if(!heartbeat || Date.now()-heartbeat.at>90000)process.exitCode=1;
  } else if(mode==='status') {
    console.log(JSON.stringify({controller:await json(resolve(state,'controller.json')),heartbeat:await json(resolve(state,'heartbeat.json')),
      records:(await new Scheduler(JSON.parse(await readFile(resolve(state,'job.json'))),{state}).records()).map(({date,status,revision,deliveredAt,error})=>({date,status,revision,deliveredAt,error}))},null,2));
  } else if(mode==='run') {
    const controller=new AbortController(),stop=()=>controller.abort();process.on('SIGTERM',stop);process.on('SIGINT',stop);
    const config=JSON.parse(await readFile(resolve(state,'job.json')));
    const scheduler=new Scheduler(config,{state,signal:controller.signal});
    await scheduler.initialize();
    try {while(!controller.signal.aborted){await scheduler.tick();await sleep(1000,undefined,{signal:controller.signal});}}
    catch(error){if(!controller.signal.aborted)throw error;}
    finally {await scheduler.active;process.off('SIGTERM',stop);process.off('SIGINT',stop);}
  } else throw new Error('Use run|health|status');
}
