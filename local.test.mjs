import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root=dirname(fileURLToPath(import.meta.url));
async function launch(mode,{name='isolated',command=['printf','%s','literal space; $(false)']}={}) {
  const temp=await mkdtemp(resolve(tmpdir(),'gha-local-controls-'));
  const bin=resolve(temp,'bin'),workspace=resolve(temp,'workspace'),output=resolve(temp,'evidence');
  await mkdir(bin);await mkdir(workspace);
  const calls=resolve(temp,'calls.jsonl');
  await writeFile(resolve(bin,'docker'),`#!${process.execPath}
import fs from 'node:fs';
const a=process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_CALLS,JSON.stringify(a)+'\\n');
const mode=process.env.FAKE_MODE;
if(a[0]==='image'||a[0]==='network'){console.log('{}');}
else if(a[0]==='container'&&a[1]==='inspect'){process.exit(mode==='collision'?0:1);}
else if(a[0]==='volume'&&a[1]==='inspect'){process.exit(a[2]==='gha-dind-nix'?0:1);}
else if(a[0]==='create'){console.log('owned-local-id');}
else if(a[0]==='logs'){console.log('complete local command log');}
else if(a[0]==='wait'){
  if(mode==='timeout') await new Promise(r=>setTimeout(r,10000));
  console.log(mode==='failure'?'17':'0');
}
`,{mode:0o755});
  const p=spawnSync('bash',[resolve(root,'local.sh'),'--name',name,'--workspace',workspace,
    '--output',output,'--timeout-seconds',mode==='timeout'?'1':'10','--',...command],{
      env:{...process.env,PATH:`${bin}:${process.env.PATH}`,CACHE_DIR:resolve(temp,'cache'),FAKE_MODE:mode,FAKE_CALLS:calls},encoding:'utf8',timeout:20000});
  const events=await readFile(calls,'utf8').then(s=>s.trim().split('\n').map(x=>JSON.parse(x))).catch(()=>[]);
  return {temp,output,p,events};
}

test('local command preserves arguments, full logs, exit status and owned cleanup',async()=>{
  for(const mode of ['success','failure']) {
    const f=await launch(mode);
    try {
      const expected=mode==='failure'?17:0;
      assert.equal(f.p.status,expected,f.p.stderr);
      assert.equal((await readFile(resolve(f.output,'exit-status'),'utf8')).trim(),String(expected));
      assert.equal(await readFile(resolve(f.output,'container.log'),'utf8'),'complete local command log\n');
      const create=f.events.find(a=>a[0]==='create');
      assert.deepEqual(create.slice(-4),['/usr/local/bin/local-entry.sh','printf','%s','literal space; $(false)']);
      assert.ok(create.includes('type=volume,src=gha-local-isolated-docker,dst=/var/lib/docker'));
      assert.equal(create.some(a=>a.includes('RUNNER_TOKEN')||a.includes('/var/run/docker.sock')),false);
      assert.ok(f.events.some(a=>a[0]==='rm'&&a[1]==='owned-local-id'));
      assert.ok(f.events.some(a=>a[0]==='volume'&&a[1]==='rm'&&a[2]==='gha-local-isolated-docker'));
    } finally {await rm(f.temp,{recursive:true,force:true});}
  }
});

test('a local timeout fails and cleans only the container it created',async()=>{
  const f=await launch('timeout');
  try {
    assert.equal(f.p.status,124,f.p.stderr);
    assert.ok(f.events.some(a=>a[0]==='stop'&&a.at(-1)==='owned-local-id'));
    assert.ok(f.events.some(a=>a[0]==='rm'&&a[1]==='owned-local-id'));
  } finally {await rm(f.temp,{recursive:true,force:true});}
});

test('existing names and invalid names are refused without deleting other resources',async()=>{
  for(const [mode,name,expected] of [['collision','isolated',1],['success','../runner-slot',2]]) {
    const f=await launch(mode,{name});
    try {
      assert.equal(f.p.status,expected,f.p.stderr);
      assert.equal(f.events.some(a=>a[0]==='create'||a[0]==='rm'||a[0]==='stop'||(a[0]==='volume'&&a[1]==='rm')),false);
    } finally {await rm(f.temp,{recursive:true,force:true});}
  }
});
