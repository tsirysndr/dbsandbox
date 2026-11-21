import {test,expect} from 'bun:test';
import {spawnSync,spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import {studioUrl,open as openBrowser,listening} from '../output/Sbx.UI.Browser/index.js';
import {runArgs} from '../output/Sbx.UI.DuckDB/index.js';
import {promise} from './support/aff.mjs';

test('Studio browser URLs preserve custom ports and connectable hosts',()=>{
  expect(studioUrl({host:'127.0.0.1',port:4983})).toBe('https://local.drizzle.studio');
  expect(studioUrl({host:'0.0.0.0',port:5100})).toBe('https://local.drizzle.studio?port=5100');
  expect(studioUrl({host:'localhost',port:5100})).toBe('https://local.drizzle.studio?port=5100&host=localhost');
  expect(studioUrl({host:'::',port:4983})).toBe('https://local.drizzle.studio?host=%3A%3A1');
});

test('Studio readiness detects an IPv6-only localhost server',async()=>{
  const server=createServer();
  try{
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'::1',resolve);});
    expect(await promise(listening('localhost')(server.address().port))).toBe(true);
    expect(await promise(listening('127.0.0.1')(server.address().port))).toBe(false);
  }finally{await new Promise(resolve=>server.close(resolve));}
});

test('browser opening passes a URL as one argument and tolerates launcher failure',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'sbx-browser-')),log=join(dir,'opened');
  const saved={PATH:process.env.PATH,DISPLAY:process.env.DISPLAY,WAYLAND_DISPLAY:process.env.WAYLAND_DISPLAY,OPEN_LOG:process.env.OPEN_LOG};
  try{
    const script=`#!${process.execPath}\nimport{writeFileSync}from'node:fs';writeFileSync(process.env.OPEN_LOG,JSON.stringify(process.argv.slice(2)));process.exit(1);\n`;
    for(const name of ['open','xdg-open']) writeFileSync(join(dir,name),script,{mode:0o755});
    Object.assign(process.env,{PATH:dir+':'+saved.PATH,DISPLAY:':test',OPEN_LOG:log});
    const url='https://local.drizzle.studio?port=5100&host=localhost';
    await promise(openBrowser(url));
    expect(JSON.parse(readFileSync(log,'utf8'))).toEqual([url]);
  }finally{
    for(const [key,value] of Object.entries(saved)) value===undefined?delete process.env[key]:process.env[key]=value;
    rmSync(dir,{recursive:true,force:true});
  }
});

test('UI containers connect through Quack and never mount the database file',()=>{
  const st={port:19494,password:'fixture-secret',db:'do-not-open',branch:'feature'};
  const args=runArgs('ui-image')('ui-session')('branch-server')(st)(4214);
  expect(args).toContain('4214:4215');
  expect(args).toContain('SBX_UI_PORT=4214');
  expect(args).toContain('SBX_DB_PORT=19494');
  expect(args).toContain('org.dbsandbox.server=branch-server');
  expect(args).not.toContain('-v');
  expect(args.join(' ')).not.toContain('do-not-open');
});

test('only DuckDB exposes ui; web commands support headless use and reject invalid ports',()=>{
  const dir=mkdtempSync(join(tmpdir(),'sbx-web-cli-'));
  const run=args=>spawnSync(process.execPath,['bin/dbsandbox.js',...args],{encoding:'utf8',timeout:10000,env:{...process.env,XDG_CONFIG_HOME:dir,BSDKRUN_BIN:'/nonexistent/bsdkrun',BSDKRUN_NO_AUTO_INSTALL:'1'}});
  try{
    for(const [database,command] of [['duckdb','ui'],['postgres','studio'],['sqlite','studio'],['mysql','studio'],['mariadb','studio']]){
      const help=run([database,command,'--help']);expect(help.status,help.stderr).toBe(0);expect(help.stdout).toContain('--no-open');
      const bad=run([database,command,'--no-open','--port','0']);expect(bad.status).not.toBe(0);expect(bad.stderr).toContain('between 1 and 65535');
    }
    expect(run(['postgres','ui','--help']).status).not.toBe(0);
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('interrupting a web session cleans up its child and returns the signal exit code',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'sbx-web-signal-')),ready=join(dir,'ready');
  const script=join(dir,'session.mjs');
  writeFileSync(script,`import{runAff_}from${JSON.stringify(resolve('output/Effect.Aff/index.js'))};import{session}from${JSON.stringify(resolve('output/Sbx.UI.Browser/index.js'))};import{spawnInherit}from${JSON.stringify(resolve('output/Sbx.Platform.Native/index.js'))};const action=spawnInherit(${JSON.stringify(process.execPath)})(['-e',${JSON.stringify(`require('node:fs').writeFileSync(${JSON.stringify(ready)},String(process.pid));setInterval(()=>{},1000)`)}])({});runAff_(r=>()=>{process.exitCode=r.value0})(session(action))();`);
  const child=spawn(process.execPath,[script],{stdio:['ignore','pipe','pipe']});
  const closed=new Promise(resolve=>child.on('close',(code,signal)=>resolve({code,signal})));
  try{
    for(let n=0;!existsSync(ready)&&n<100;n++) await Bun.sleep(25);
    expect(existsSync(ready)).toBe(true);
    const pid=Number(readFileSync(ready,'utf8'));
    child.kill('SIGTERM');
    expect(await closed).toEqual({code:143,signal:null});
    expect(()=>process.kill(pid,0)).toThrow();
  }finally{child.kill('SIGKILL');rmSync(dir,{recursive:true,force:true});}
});
