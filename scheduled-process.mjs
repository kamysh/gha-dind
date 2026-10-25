import { spawn } from 'node:child_process';
import { mkdir, rename, writeFile, open } from 'node:fs/promises';
import { dirname } from 'node:path';

export async function save(file,value) {
  await mkdir(dirname(file),{recursive:true,mode:0o700});
  const temporary=`${file}.${process.pid}.tmp`;
  await writeFile(temporary,JSON.stringify(value,null,2)+'\n',{mode:0o600});
  await rename(temporary,file);
}

// Complete stdout/stderr is retained; only explicitly requested small records
// are captured. Own the whole process group through timeout and cancellation.
export async function execute(argv,{cwd,env=process.env,log,deadline,signal,capture=false}) {
  if(!argv.length || !Number.isFinite(deadline) || deadline<=Date.now()) throw new Error('Command deadline exhausted');
  if(signal?.aborted) throw new Error('Interrupted');
  await mkdir(dirname(log),{recursive:true,mode:0o700});
  const handle=await open(log,'wx',0o600);
  const stream=handle.createWriteStream();
  const startedAt=new Date().toISOString();
  return new Promise((resolve,reject)=>{
    let output='',failure,killer;
    const child=spawn(argv[0],argv.slice(1),{cwd,env,detached:true,stdio:['ignore','pipe','pipe']});
    const kill=signal=>{try{if(child.pid)process.kill(-child.pid,signal);}catch(error){if(error.code!=='ESRCH')failure??=error;}};
    const stop=reason=>{if(failure)return;failure=new Error(reason);kill('SIGTERM');killer=setTimeout(()=>kill('SIGKILL'),5000);};
    const abort=()=>stop('Interrupted');signal?.addEventListener('abort',abort,{once:true});
    const timer=setTimeout(()=>stop('Absolute command deadline reached'),Math.min(deadline-Date.now(),2147483647));
    if(signal?.aborted)abort();
    child.stdout.on('data',data=>{stream.write(data);if(capture){output+=data;if(output.length>1024*1024)stop('Command record exceeded 1 MiB');}});
    child.stderr.on('data',data=>stream.write(data));
    child.on('error',error=>{failure=error;});stream.on('error',()=>stop('Cannot retain command log'));
    child.on('close',(code,termination)=>{
      clearTimeout(timer);clearTimeout(killer);kill('SIGKILL');signal?.removeEventListener('abort',abort);
      stream.end(async()=>{
        try {
          await save(log+'.result.json',{argv,startedAt,finishedAt:new Date().toISOString(),exitCode:code,signal:termination,error:failure?.message});
          if(failure || code!==0)reject(failure??new Error(`Command exited ${code??termination}; see retained log`));else resolve(output);
        } catch(error){reject(error);}
      });
    });
  });
}
