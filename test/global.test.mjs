import {Database as SQLite} from 'bun:sqlite';
import {fixture} from './support/global-fixture.mjs';
import {test,expect} from 'bun:test';
import {spawnSync,spawn} from 'node:child_process';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync,existsSync,readdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {createServer} from 'node:net';
import {authorized,decodeAction} from '../output/Sbx.UI.Web.Server/index.js';
import {compatible} from '../output/Sbx.Management.System/index.js';
import {Left} from '../output/Data.Either/index.js';

test('global help and catalog are available without a runtime or configuration writes',()=>{
 const f=fixture();try{
  const result=f.run(['databases','--json']);expect(result.status,result.stderr).toBe(0);
  const dbs=JSON.parse(result.stdout);expect(dbs).toHaveLength(22);
  expect(dbs.find(d=>d.name==='mysql').guests).toEqual(['linux','freebsd','netbsd']);
  expect(dbs.find(d=>d.name==='chroma').guests).toEqual(['linux']);
  expect(f.run(['ps','--json']).stdout.trim()).toBe('[]');
  expect(f.calls()).toEqual([]);expect(readdirSync(f.config)).toEqual([]);
  for(const command of [['ps'],['doctor'],['databases'],['engine','status'],['ui'],['stop'],['completion']])expect(f.run([...command,'--help']).status).toBe(0);
  expect(f.run(['stop']).status).not.toBe(0);expect(f.run(['completion','powershell']).status).not.toBe(0);
 }finally{f.close();}
});

test('inventory marks selected forks, includes stopped servers only on request and redacts credentials',()=>{
 const f=fixture();try{f.seed();f.state('mysql-sbx','main',3306);
  f.state('postgres-sbx.branch-forged','evil');mkdirSync(join(f.config,'mariadb-sbx'));writeFileSync(join(f.config,'mariadb-sbx','state.json'),'{}');
  const r=f.run(['ps','--all','--json']);expect(r.status,r.stderr).toBe(0);expect(r.stdout).not.toContain('DO-NOT-LEAK');
  const rows=JSON.parse(r.stdout);expect(rows).toHaveLength(3);expect(rows.find(r=>r.branch==='feature').active).toBe(true);expect(rows.find(r=>r.tool==='postgres-sbx').active).toBe(false);expect(rows.find(r=>r.database==='mysql').status).toBe('STOPPED');
  expect(JSON.parse(f.run(['ps','--json']).stdout)).toHaveLength(2);
  const info=f.run(['engine','status','--json']);expect(info.status,info.stderr).toBe(0);expect(JSON.parse(info.stdout)).toMatchObject({status:'RUNNING',cpus:2,memoryMiB:2048,storageDriver:'overlay2',diskBytes:17179869184});
 }finally{f.close();}
});

test('stop --all stops parent and fork exactly once without stopping the engine or unrelated containers',()=>{
 const f=fixture();try{f.seed();const r=f.run(['stop','--all']);expect(r.status,r.stderr).toBe(0);
  expect(f.calls().filter(c=>c[0]==='docker'&&c[1]==='stop').map(c=>c[2])).toEqual([f.child,'postgres-sbx']);
  expect(f.calls().some(c=>c[0]==='bsdkrun'&&c[1]==='docker'&&c[2]==='stop')).toBe(false);
  expect(JSON.parse(readFileSync(f.runtime)).containers.find(c=>c.name==='unrelated').state).toBe('running');
  expect(existsSync(join(f.config,'postgres-sbx','state.json'))).toBe(true);expect(existsSync(join(f.config,f.child,'state.json'))).toBe(true);
 }finally{f.close();}
});

test('dashboard rejects hostile hosts, origins, tokens and invalid actions',()=>{
 const request={method:'POST',path:'/api/action',host:'127.0.0.1:8787',origin:'http://127.0.0.1:8787',token:'secret',body:''};
 expect(authorized(8787)('secret')(request)).toBe(true);
 for(const patch of [{host:'evil.example:8787'},{origin:'https://evil.example'},{origin:''},{token:'wrong'}])expect(authorized(8787)('secret')({...request,...patch})).toBe(false);
 expect(authorized(8787)('secret')({...request,method:'GET',origin:''})).toBe(true);
 for(const body of ['null','{}','{"action":"destroy"}','{"action":"branch","name":"../bad"}','{"action":"branch","name":"main"}'])expect(decodeAction(body)).toBeInstanceOf(Left);
 expect(decodeAction('{"action":"branch","name":"feature"}')).not.toBeInstanceOf(Left);
 for(const cpus of [0,-1,257,1.5,'4',null])expect(decodeAction(JSON.stringify({action:'configure-engine',cpus,mem:4096}))).toBeInstanceOf(Left);
 expect(decodeAction('{"action":"configure-engine","cpus":4,"mem":4096}')).not.toBeInstanceOf(Left);
 expect(decodeAction('{"action":"start","database":"postgres","cpus":4,"mem":4096}')).not.toBeInstanceOf(Left);
 expect(compatible('bsdkrun 0.12.2')).toBe(true);expect(compatible('0.13.0')).toBe(true);expect(compatible('0.12.1')).toBe(false);
});

async function freePort(){const server=createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));return port;}
async function until(fn){for(let n=0;n<150;n++){const value=await fn();if(value)return value;await Bun.sleep(30);}throw Error('Timed out');}

test('dashboard serves real HTTP, protects mutations, stops fixture servers and frees its port on interrupt',async()=>{
 const f=fixture();f.seed();const port=await freePort(),base=`http://127.0.0.1:${port}`;
 const child=spawn(process.execPath,['bin/dbsandbox.js','ui','--no-open','--port',String(port)],{env:f.env,stdio:['ignore','pipe','pipe']});let output='';child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>output+=d);
 const closed=new Promise(resolve=>child.on('close',code=>resolve(code)));
 try{
  const html=await until(async()=>{try{return await(await fetch(base)).text();}catch{return false;}});
  const token=html.match(/name="dbsandbox-token" content="([^"]+)"/)[1];const headers={'X-Dbsandbox-Token':token,Origin:base,'Content-Type':'application/json'};
  expect(html).toContain('dbsandbox');expect((await fetch(base+'/api/snapshot')).status).toBe(403);
  expect((await fetch(base+'/api/action',{method:'POST',headers:{...headers,Origin:'https://evil.example'},body:'{"action":"stop-all"}'})).status).toBe(403);
  const snapshot=await(await fetch(base+'/api/snapshot',{headers})).json();expect(snapshot.rows).toHaveLength(2);expect(JSON.stringify(snapshot)).not.toContain('DO-NOT-LEAK');
  expect(await(await fetch(base+'/api/search?q=feat',{headers})).json()).toEqual([f.child]);
  for(const [kind,label] of [['console','pgcli'],['container','Container'],['vm','VM']]){const response=await fetch(base+'/api/terminal',{method:'POST',headers,body:JSON.stringify({database:'postgres',branch:'feature',kind})});expect(response.status).toBe(201);const session=await response.json();expect(session.label).toContain(label);expect(session.ticket).toHaveLength(64);}
  expect((await fetch(base+'/api/terminal',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status).toBe(403);
  expect((await fetch(base+'/api/terminal',{method:'POST',headers,body:JSON.stringify({database:'postgres',branch:'feature',kind:'host'})})).status).toBe(400);

  expect((await fetch(base+'/api/search?q=feat')).status).toBe(403);
  expect((await fetch(base+'/api/connection?database=postgres&branch=feature')).status).toBe(403);
  const connection=await(await fetch(base+'/api/connection?database=postgres&branch=feature',{headers})).json();expect(connection.url).toContain('DO-NOT-LEAK@127.0.0.1:5433');
  expect((await fetch(base+'/api/connection?database=postgres&branch=missing',{headers})).status).toBe(404);
  for(const [source,marker] of [['server','DATABASE LOG FIXTURE'],['vm','VM CONSOLE FIXTURE'],['boot','VM BOOT FIXTURE']]){
    const logs=await(await fetch(base+`/api/logs?database=postgres&branch=feature&source=${source}`,{headers})).json();expect(logs.text).toContain(marker);expect(logs.text).not.toContain('DO-NOT-LEAK');
  }
  expect((await fetch(base+'/api/logs?source=vm')).status).toBe(403);
  const wrong=await fetch(base+'/api/action',{method:'POST',headers,body:'{"action":"branch","database":"postgres","name":"../evil"}'});expect(wrong.status).toBe(400);
  const accepted=await fetch(base+'/api/action',{method:'POST',headers,body:'{"action":"stop-all"}'});expect(accepted.status).toBe(202);const{id}=await accepted.json();
  await until(async()=>{const s=await(await fetch(base+'/api/snapshot',{headers})).json();return s.jobs.find(j=>j.id===id)?.status==='DONE';});
  const taskSnapshot=await(await fetch(base+'/api/snapshot',{headers})).json();const completedTask=taskSnapshot.jobs.find(j=>j.id===id);expect(typeof completedTask.createdAt).toBe('number');expect(completedTask.createdAt).toBeGreaterThan(Date.now()/1000-30);
  expect(f.calls().filter(c=>c[0]==='docker'&&c[1]==='stop').map(c=>c[2])).toEqual([f.child,'postgres-sbx']);
  const operation=await(await fetch(base+`/api/logs?source=operation&id=${id}`,{headers})).json();expect(operation.text).toContain('Stopping container');expect(operation.text).not.toContain('DO-NOT-LEAK');
  const resize=await fetch(base+'/api/action',{method:'POST',headers,body:'{"action":"configure-engine","cpus":4,"mem":4096}'});expect(resize.status).toBe(202);const resizeId=(await resize.json()).id;
  await until(async()=>{const s=await(await fetch(base+'/api/snapshot',{headers})).json();return s.jobs.find(j=>j.id===resizeId)?.status==='DONE';});
  expect(JSON.parse(readFileSync(f.runtime))).toMatchObject({running:true,cpus:4,mem:4096});
  expect(f.calls()).toContainEqual(['bsdkrun','update','bsdkrun-docker','--cpus','4','--mem','4096']);
  child.kill('SIGTERM');expect(await closed,output).toBe(143);
  const server=createServer();await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,'127.0.0.1',resolve);});await new Promise(r=>server.close(r));
 }finally{child.kill('SIGKILL');await closed;f.close();}
});

test('generated shell completions parse and suggest database commands in Bash, Zsh and Fish',()=>{
 const f=fixture();try{
  for(const shell of ['bash','zsh','fish']){
   const script=f.run(['completion',shell]);expect(script.status).toBe(0);const path=join(f.dir,`completion.${shell}`);writeFileSync(path,script.stdout);
   const binary=shell==='fish'?'/opt/homebrew/bin/fish':shell;
   const available=spawnSync(binary,['--version'],{encoding:'utf8'});if(available.error?.code==='ENOENT')continue;
   const syntax=spawnSync(binary,['-n',path],{encoding:'utf8'});expect(syntax.status,syntax.stderr).toBe(0);
   const command=shell==='bash'?`source '${path}'; COMP_WORDS=(dbsandbox po); COMP_CWORD=1; _dbsandbox_complete; printf '%s\\n' "\${COMPREPLY[@]}"`:shell==='zsh'?`compdef() {}; source '${path}'; compadd() { print -l -- "$@"; }; words=(dbsandbox po); CURRENT=2; _dbsandbox`:`source '${path}'; complete -C 'dbsandbox po'`;
   const result=spawnSync(binary,['-c',command],{encoding:'utf8'});expect(result.status,result.stderr).toBe(0);expect(result.stdout).toContain('postgres');
  }
 }finally{f.close();}
});

test('inventory includes data-only ZFS branches and UI checkout can switch to them and back',()=>{
 const f=fixture();try{
  f.state('postgres-sbx');
  const path=join(f.config,'postgres-sbx','state.json');const state=JSON.parse(readFileSync(path));state.os='netbsd';state.version='10.1';writeFileSync(path,JSON.stringify(state));
  writeFileSync(f.runtime,JSON.stringify({running:true,containers:[],volumes:[{name:'postgres-sbx',path:'/fixture/postgres',branches:[{name:'archive'},{name:'main'}],attached_to:[]}]}));
  let result=f.run(['ps','--all','--json']);expect(result.status,result.stderr).toBe(0);let rows=JSON.parse(result.stdout);expect(rows.map(r=>r.branch).sort()).toEqual(['archive','main']);expect(rows.find(r=>r.branch==='archive')).toMatchObject({kind:'data',status:'DATA ONLY',port:0,running:false,active:false});
  for(const branch of ['archive','main']){
   result=f.run(['__ui-action',JSON.stringify({action:'checkout',database:'postgres',branch})]);expect(result.status,result.stderr).toBe(0);
   rows=JSON.parse(f.run(['ps','--all','--json']).stdout);expect(rows.find(r=>r.active).branch).toBe(branch);expect(rows.filter(r=>r.kind==='data')).toHaveLength(1);
   const db=new SQLite(join(f.config,'dbsandbox','state.sqlite'),{readonly:true});try{expect(db.query('SELECT branch FROM sandboxes WHERE tool=?').get('postgres-sbx').branch).toBe(branch);expect(db.query("SELECT branch FROM sandbox_search WHERE sandbox_search MATCH 'arch*'").all()).toEqual([{branch:'archive'}]);}finally{db.close();}
  }
  expect(f.calls().some(c=>c[0]==='docker'&&c[1]==='stop')).toBe(false);
 }finally{f.close();}
});


test('UI deletion removes only inactive ZFS data and protects selected and parent branches',()=>{
 const f=fixture();try{
  f.seed();const runtime=JSON.parse(readFileSync(f.runtime));runtime.volumes=[{name:'postgres-sbx',path:'/fixture/postgres',branches:[{name:'main'},{name:'feature'},{name:'archive'}],attached_to:[]}];writeFileSync(f.runtime,JSON.stringify(runtime));
  let rows=JSON.parse(f.run(['ps','--all','--json']).stdout);
  expect(rows.find(r=>r.branch==='archive').deletable).toBe(true);
  for(const branch of ['feature','main']){
   expect(rows.find(r=>r.branch===branch).deletable).toBe(false);
   const result=f.run(['__ui-action',JSON.stringify({action:'delete',database:'postgres',branch})]);expect(result.status).not.toBe(0);
  }
  expect(f.calls().some(c=>c[1]==='zfs'&&c[2]==='destroy')).toBe(false);
  const result=f.run(['__ui-action',JSON.stringify({action:'delete',database:'postgres',branch:'archive'})]);expect(result.status,result.stderr).toBe(0);
  rows=JSON.parse(f.run(['ps','--all','--json']).stdout);expect(rows.map(r=>r.branch).sort()).toEqual(['feature','main']);
  expect(f.calls().filter(c=>c[1]==='zfs'&&c[2]==='destroy')).toEqual([['bsdkrun','zfs','destroy','postgres-sbx@archive']]);
  expect(f.calls().some(c=>c[0]==='docker'&&c[1]==='stop')).toBe(false);
  const db=new SQLite(join(f.config,'dbsandbox','state.sqlite'),{readonly:true});try{expect(db.query("SELECT branch FROM sandbox_search WHERE sandbox_search MATCH 'arch*'").all()).toEqual([]);}finally{db.close();}
 }finally{f.close();}
});


test('deleting an inactive running fork removes its server, dataset and manifest while retaining the selected fork',()=>{
 const f=fixture();try{
  f.seed();const tool='postgres-sbx.branch-'+createHash('sha256').update('review').digest('hex').slice(0,20);f.state(tool,'review',5434);
  const manifest=join(f.config,'postgres-sbx','branches.json');writeFileSync(manifest,JSON.stringify([...JSON.parse(readFileSync(manifest)),{name:'review',tool,running:true}]));
  const runtime=JSON.parse(readFileSync(f.runtime));runtime.containers.push({name:tool,state:'running'});runtime.volumes=[{name:'postgres-sbx',branches:[{name:'main'},{name:'feature'},{name:'review'}],attached_to:[]}];writeFileSync(f.runtime,JSON.stringify(runtime));
  const result=f.run(['__ui-action',JSON.stringify({action:'delete',database:'postgres',branch:'review'})]);expect(result.status,result.stderr).toBe(0);
  const rows=JSON.parse(f.run(['ps','--all','--json']).stdout);expect(rows.map(r=>r.branch).sort()).toEqual(['feature','main']);expect(rows.find(r=>r.branch==='feature').active).toBe(true);
  expect(f.calls().filter(c=>c[0]==='docker'&&c[1]==='stop')).toEqual([['docker','stop',tool]]);expect(f.calls()).toContainEqual(['docker','rm','-f',tool]);expect(f.calls()).toContainEqual(['bsdkrun','zfs','destroy','postgres-sbx@review']);
  const db=new SQLite(join(f.config,'dbsandbox','state.sqlite'),{readonly:true});try{expect(db.query('SELECT tool FROM sandboxes WHERE tool=?').get(tool)).toBeNull();}finally{db.close();}
 }finally{f.close();}
});
