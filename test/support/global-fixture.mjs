import {spawnSync} from 'node:child_process';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
export function fixture(){
  const dir=mkdtempSync(join(tmpdir(),'sbx-global-')),config=join(dir,'config'),log=join(dir,'calls'),runtime=join(dir,'runtime.json');
  mkdirSync(config);writeFileSync(runtime,JSON.stringify({running:true,containers:[]}));
  const script=`#!${process.execPath}\nimport{readFileSync,writeFileSync,appendFileSync}from'node:fs';
const a=process.argv.slice(2),docker=process.argv[1].endsWith('/docker'),r=JSON.parse(readFileSync(process.env.FIXTURE_RUNTIME)),out=v=>console.log(JSON.stringify(v));if(a[0]==='--log-level')a.splice(0,2);
appendFileSync(process.env.FIXTURE_LOG,JSON.stringify([docker?'docker':'bsdkrun',...a])+'\\n');
if(docker){if(a[0]==='stop'){r.containers=r.containers.map(c=>c.name===a[1]?{...c,state:'exited'}:c);writeFileSync(process.env.FIXTURE_RUNTIME,JSON.stringify(r));console.log(a[1]);}else if(a[0]==='rm'){r.containers=r.containers.filter(c=>c.name!==a.at(-1));writeFileSync(process.env.FIXTURE_RUNTIME,JSON.stringify(r));}else if(a[0]==='info')console.log('overlay2');else if(a[0]==='logs'){console.log('DATABASE LOG FIXTURE password=DO-NOT-LEAK');console.log('SECOND LOG LINE');}else if(a[0]!=='ps')process.exit(2);}
else if(a[0]==='--version')console.log('bsdkrun 0.12.2');
else if(a[0]==='probe')process.exit(0);
else if(a[0]==='docker'&&a[1]==='status')out({running:r.running,machine_id:'0123456789ab',socket:'/fixture/docker.sock',containers:r.containers.filter(c=>c.state==='running').length,version:'28.0',disk_size:17179869184});
else if(a[0]==='docker'&&a[1]==='ps')out(r.containers);
else if(a[0]==='docker'&&['stop','start'].includes(a[1])){r.running=a[1]==='start';writeFileSync(process.env.FIXTURE_RUNTIME,JSON.stringify(r));}
else if(a[0]==='update'){r.cpus=Number(a[a.indexOf('--cpus')+1]);r.mem=Number(a[a.indexOf('--mem')+1]);writeFileSync(process.env.FIXTURE_RUNTIME,JSON.stringify(r));}
else if(a[0]==='zfs'&&a[1]==='detach')console.log('Detached');
else if(a[0]==='zfs'&&a[1]==='destroy'){for(const target of a.slice(2)){const [volume,branch]=target.split('@');r.volumes=(r.volumes||[]).map(v=>v.name===volume?{...v,branches:v.branches.filter(b=>b.name!==branch)}:v);}writeFileSync(process.env.FIXTURE_RUNTIME,JSON.stringify(r));}
else if(a[0]==='zfs'&&a[1]==='ls')out(r.volumes||[]);
else if(a[0]==='ps')out([{id:'0123456789ab',name:'bsdkrun-docker',running:r.running,cpus:r.cpus||2,mem:r.mem||2048}]);
else if(a[0]==='logs')console.log(a.includes('--boot')?'VM BOOT FIXTURE':'VM CONSOLE FIXTURE');
else if(a[0]==='exec')console.log('/dev/vdb 16G 2G 14G 13% /var/lib/docker');
else {console.error('Unexpected mock command',a);process.exit(2);}\n`;
  for(const name of ['bsdkrun','docker'])writeFileSync(join(dir,name),script,{mode:0o755});
  const env={...process.env,XDG_CONFIG_HOME:config,BSDKRUN_BIN:join(dir,'bsdkrun'),BSDKRUN_NO_AUTO_INSTALL:'1',PATH:dir+':'+process.env.PATH,FIXTURE_RUNTIME:runtime,FIXTURE_LOG:log,NO_COLOR:'1'};
  const run=args=>spawnSync(process.execPath,['bin/dbsandbox.js',...args],{env,encoding:'utf8',timeout:15000});
  const state=(tool,branch='main',port=5432)=>{mkdirSync(join(config,tool),{recursive:true});writeFileSync(join(config,tool,'state.json'),JSON.stringify({os:'linux',version:'18',port,user:'postgres',password:'DO-NOT-LEAK',db:'sandbox',branch,cpus:2,mem:2048}));};
  const child='postgres-sbx.branch-'+createHash('sha256').update('feature').digest('hex').slice(0,20);
  const seed=()=>{state('postgres-sbx');state(child,'feature',5433);writeFileSync(join(config,'postgres-sbx','branches.json'),JSON.stringify([{name:'feature',tool:child,running:true}]));writeFileSync(join(config,'postgres-sbx','active.json'),'"feature"');writeFileSync(runtime,JSON.stringify({running:true,containers:[{name:'postgres-sbx',state:'running'},{name:child,state:'running'},{name:'unrelated',state:'running'}]}));};
  return{dir,config,env,run,state,child,seed,runtime,calls:()=>existsSync(log)?readFileSync(log,'utf8').trim().split('\n').map(JSON.parse):[],close:()=>rmSync(dir,{recursive:true,force:true})};
}

