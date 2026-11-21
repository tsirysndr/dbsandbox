import {expect} from 'bun:test';
import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomBytes} from 'node:crypto';
import {createServer,createConnection} from 'node:net';

const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const waitFor=async(check,label,timeout=180000)=>{
  const end=Date.now()+timeout;
  while(Date.now()<end){if(await check())return;await pause(200);}
  throw Error(`Timed out: ${label}`);
};
const freePort=()=>new Promise((resolve,reject)=>{
  const server=createServer();server.on('error',reject);
  server.listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>resolve(port));});
});
const listening=(host,port)=>new Promise(resolve=>{
  const socket=createConnection({host,port});
  const done=ok=>{socket.destroy();resolve(ok);};
  socket.setTimeout(500,()=>done(false));socket.once('connect',()=>done(true));socket.once('error',()=>done(false));
});

function fixture(database){
  const root=mkdtempSync(join(tmpdir(),'dbsandbox-web-e2e-'));
  const name=`dbsandbox-${database}-e2e-${randomBytes(6).toString('hex')}`;
  const opened=join(root,'opened.jsonl');writeFileSync(opened,'');
  // Real browser-launch paths, with harmless launchers that verify readiness.
  const launcher=`#!${process.execPath}
import{appendFileSync}from'node:fs';import{createConnection}from'node:net';
const url=process.argv[2],u=new URL(url),host=u.searchParams.get('host')||(u.hostname==='localhost'?'localhost':'127.0.0.1');
const port=Number(u.searchParams.get('port')||u.port||4983),s=createConnection({host,port});
let ended=false;const finish=reachable=>{if(ended)return;ended=true;s.destroy();appendFileSync(process.env.OPEN_LOG,JSON.stringify({url,reachable})+'\\n');process.exit(reachable?0:1)};
s.once('connect',()=>finish(true));s.once('error',()=>finish(false));s.setTimeout(2000,()=>finish(false));
`;
  for(const command of ['open','xdg-open'])writeFileSync(join(root,command),launcher,{mode:0o755});
  const env={...process.env,XDG_CONFIG_HOME:root,PATH:root+':'+process.env.PATH,DISPLAY:':fixture',OPEN_LOG:opened};
  const children=[];
  const start=(program,args)=>{
    let output='';
    const child=spawn(program,args,{env,stdio:['ignore','pipe','pipe']});
    child.stdout.on('data',chunk=>{output+=chunk;if(!result.quiet)process.stdout.write(chunk);});child.stderr.on('data',chunk=>{output+=chunk;if(!result.quiet)process.stderr.write(chunk);});
    const closed=new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',(code,signal)=>resolve({code,signal}));});
    const result={child,closed,output:()=>output,quiet:false};children.push(result);return result;
  };
  const command=async(program,args,allowFailure=false)=>{
    const task=start(program,args);
    let timedOut=false;
    const timeout=setTimeout(()=>{timedOut=true;task.child.kill('SIGKILL');},600000);
    const result=await task.closed;clearTimeout(timeout);
    if(timedOut||(!allowFailure&&result.code!==0))throw Error(`${program} failed: ${task.output().slice(-5000)}`);
    return {...result,output:task.output()};
  };
  const cli=(args,allowFailure=false)=>command(process.execPath,['bin/ci.js','sandbox-cli',database,name,...args],allowFailure);
  const launch=args=>start(process.execPath,['bin/ci.js','sandbox-cli',database,name,...args]);
  const stop=async task=>{
    if(task.child.exitCode!==null||task.child.signalCode!==null)return;
    task.quiet=true;task.child.kill('SIGTERM');
    const fallback=setTimeout(()=>task.child.kill('SIGKILL'),15000);
    await task.closed;clearTimeout(fallback);
  };
  let socket;
  const docker=async args=>{
    if(!socket){const r=await command(process.env.BSDKRUN_BIN||'bsdkrun',['docker','status','--json']);socket=JSON.parse(r.output.trim()).socket;}
    return command('docker',['--host','unix://'+socket,...args]);
  };
  const openedUrls=()=>readFileSync(opened,'utf8').trim().split('\n').filter(Boolean).map(line=>JSON.parse(line));
  const uiUrl=async task=>{
    let address;
    await waitFor(()=>{
      const match=/DuckDB UI for branch '[^']+': (http:\/\/localhost:\d+)/.exec(task.output());
      if(match){address=match[1];return true;}
      if(task.child.exitCode!==null)throw Error(task.output().slice(-5000));
      return false;
    },'UI ready');
    return address;
  };
  const close=async()=>{
    for(const child of children)await stop(child);
    try{
      const leftovers=await docker(['ps','-aq','--filter','label=org.dbsandbox.ui=true','--filter',`name=${name}`]);
      const ids=leftovers.output.trim().split(/\s+/).filter(Boolean);
      if(ids.length)await docker(['rm','-f',...ids]);
      await cli(['destroy','--yes']);
    }finally{rmSync(root,{recursive:true,force:true});}
  };
  return {name,cli,launch,stop,docker,openedUrls,uiUrl,close};
}

async function uiQuery(address,sql){
  const r=await fetch(address.replace('localhost','127.0.0.1')+'/ddb/run',{
    method:'POST',headers:{Origin:address,'X-DuckDB-UI-Errors-As-JSON':'true'},body:sql,signal:AbortSignal.timeout(15000),
  });
  expect(r.status).toBe(200);
  const result=Buffer.from(await r.arrayBuffer());
  if(result[0]===123)throw Error(result.toString());
  return result;
}

export async function duckUiLive(){
  const f=fixture('duckdb');
  const blocker=createServer();
  console.info('[ui:e2e] DuckDB UI: create isolated server');
  try{
    await f.cli(['start','linux','2.0.0','--port',String(await freePort()),'--password','fixture-ui-token','-d']);
    const query=async(selected,sql)=>(await f.cli([...selected,'duckdb','-noheader','-csv','-c',sql])).output.trim();
    await query([],"CREATE TABLE ui_values(marker VARCHAR); INSERT INTO ui_values VALUES ('original_ui_marker');");
    await new Promise(resolve=>{blocker.once('error',resolve);blocker.listen(4213,'127.0.0.1',resolve);});
    const main=f.launch(['ui','--no-open']),address=await f.uiUrl(main);
    expect(new URL(address).port).not.toBe('4213');
    expect((await fetch(address.replace('localhost','127.0.0.1'))).status).toBe(200);
    expect((await uiQuery(address,'SELECT marker FROM sbx.main.ui_values;')).includes(Buffer.from('original_ui_marker'))).toBe(true);
    await uiQuery(address,"UPDATE sbx.main.ui_values SET marker='edited_ui_marker';");
    expect(await query([],'SELECT marker FROM ui_values;')).toBe('edited_ui_marker');
    expect(f.openedUrls()).toEqual([]);
    const collision=await f.cli(['ui','--no-open','--port',new URL(address).port],true);
    expect(collision.code).not.toBe(0);expect(collision.output).toContain('in use');
    await f.stop(main);
    expect((await f.docker(['ps','-q','--filter','label=org.dbsandbox.ui=true','--filter',`name=${f.name}`])).output.trim()).toBe('');
    expect(await query([],'SELECT marker FROM ui_values;')).toBe('edited_ui_marker');
    console.info('[ui:e2e] DuckDB UI: writes, automatic ports, collisions and cleanup passed; test selected branch');
    await f.cli(['branch','feature']);
    await query(['--branch','feature'],"UPDATE ui_values SET marker='feature_ui_marker';");
    const port=await freePort(),feature=f.launch(['--branch','feature','ui','--port',String(port)]);
    const featureAddress=await f.uiUrl(feature);
    await waitFor(()=>f.openedUrls().length===1,'UI browser opened');
    expect(f.openedUrls()).toEqual([{url:featureAddress,reachable:true}]);
    expect((await uiQuery(featureAddress,'SELECT marker FROM sbx.main.ui_values;')).includes(Buffer.from('feature_ui_marker'))).toBe(true);
    await uiQuery(featureAddress,"UPDATE sbx.main.ui_values SET marker='feature_edited_ui_marker';");
    expect(await query(['--branch','feature'],'SELECT marker FROM ui_values;')).toBe('feature_edited_ui_marker');
    expect(await query([],'SELECT marker FROM ui_values;')).toBe('edited_ui_marker');
    await f.cli(['--branch','feature','stop']);
    await waitFor(()=>feature.child.exitCode!==null,'UI closes when its branch stops');
    await f.stop(feature);
    expect((await f.docker(['ps','-q','--filter','label=org.dbsandbox.ui=true','--filter',`name=${f.name}`])).output.trim()).toBe('');
    expect(await query([],'SELECT marker FROM ui_values;')).toBe('edited_ui_marker');
    console.info('[ui:e2e] DuckDB UI: selected branch, browser readiness, isolation and branch-stop cleanup passed');
  }finally{
    if(blocker.listening)await new Promise(resolve=>blocker.close(resolve));
    await f.close();
  }
}

export async function studioLive(){
  const f=fixture('postgres');
  console.info('[ui:e2e] Studio: create isolated PostgreSQL server');
  try{
    await f.cli(['start','linux','18','--port',String(await freePort()),'--user','studio_test','--password','fixture-studio-password','--db','studio_test','-d']);
    const port=await freePort(),studio=f.launch(['studio','--port',String(port),'--host','localhost']);
    await waitFor(()=>{
      if(studio.child.exitCode!==null)throw Error(studio.output().slice(-5000));
      return f.openedUrls().length===1;
    },'Studio browser opened');
    expect(f.openedUrls()).toEqual([{url:`https://local.drizzle.studio?port=${port}&host=localhost`,reachable:true}]);
    await f.stop(studio);
    await waitFor(async()=>!await listening('localhost',port),'Studio port closed',20000);
    const headlessPort=await freePort(),headless=f.launch(['studio','--no-open','--port',String(headlessPort)]);
    await waitFor(()=>listening('127.0.0.1',headlessPort),'headless Studio ready');
    expect(f.openedUrls()).toHaveLength(1);
    await f.stop(headless);
    await waitFor(async()=>!await listening('127.0.0.1',headlessPort),'headless Studio port closed',20000);
    console.info('[ui:e2e] Studio: browser readiness, custom URL, headless mode and cleanup passed');
  }finally{await f.close();}
}
