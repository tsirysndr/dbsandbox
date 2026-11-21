import {test,expect} from 'bun:test';
import {createRequire} from 'node:module';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,cpSync,rmSync,existsSync,readdirSync,realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const require=createRequire(import.meta.url),{detect}=require('../npm/scripts/platform.js');
const node=spawnSync('node',['-p','process.execPath'],{encoding:'utf8'}).stdout.trim();
const run=(program,args,{env=process.env,cwd=process.cwd()}={})=>new Promise(resolve=>{
 const child=spawn(program,args,{env,cwd,stdio:['ignore','pipe','pipe']});let stdout='',stderr='';child.stdout.on('data',v=>stdout+=v);child.stderr.on('data',v=>stderr+=v);child.on('error',error=>resolve({status:1,stdout,stderr:stderr+error.message}));child.on('close',(status,signal)=>resolve({status,signal,stdout,stderr}));
});
function fixture(){
 const dir=mkdtempSync(join(tmpdir(),'dbsandbox-npm-')),pkg=join(dir,'package'),data=join(dir,'release');cpSync('npm',pkg,{recursive:true,filter:path=>!path.includes('/binaries')&&!path.includes('/node_modules')});mkdirSync(data);
 const bsd=join(pkg,'node_modules','@bsdkrun','cli');mkdirSync(join(bsd,'bin'),{recursive:true});writeFileSync(join(bsd,'package.json'),JSON.stringify({name:'@bsdkrun/cli',version:'0.12.2',bin:{bsdkrun:'bin/bsdkrun.js'}}));writeFileSync(join(bsd,'bin','bsdkrun.js'),`#!${node}\nconsole.log('bsdkrun 0.12.2');\n`,{mode:0o755});
 const native=`#!${node}\nconst{spawnSync}=require('node:child_process');if(process.argv[2]==='--version')console.log('dbsandbox 0.2.0');else if(process.argv[2]==='--wait'){console.log('READY');setInterval(()=>{},1000);}else{console.log(JSON.stringify({args:process.argv.slice(2),bsd:process.env.BSDKRUN_BIN,runtime:spawnSync(process.env.BSDKRUN_BIN,['--version'],{encoding:'utf8'}).stdout.trim()}));process.exitCode=Number(process.env.NPM_TEST_EXIT||0);}\n`;
 writeFileSync(join(data,'dbsandbox'),native,{mode:0o755});const asset=detect().asset,archive=join(dir,asset);const packed=spawnSync('tar',['-czf',archive,'-C',data,'dbsandbox']);if(packed.status!==0)throw Error(String(packed.stderr));const bytes=readFileSync(archive),digest=createHash('sha256').update(bytes).digest('hex');let manifest=`${digest}  ${asset}\n`;const requests=[];
 const server=Bun.serve({hostname:'127.0.0.1',port:0,fetch(request){const path=new URL(request.url).pathname;requests.push(path);return path.endsWith('/'+asset)?new Response(bytes):path.endsWith('/SHA256SUMS')?new Response(manifest):new Response('not found',{status:404});}});
 const env={...process.env,DBSANDBOX_DOWNLOAD_BASE:`http://127.0.0.1:${server.port}/v0.2.0`};delete env.DBSANDBOX_BINARY;delete env.DBSANDBOX_SKIP_DOWNLOAD;delete env.BSDKRUN_BIN;
 return{dir,pkg,data,bsd,env,asset,requests,binary:join(pkg,'binaries','dbsandbox'),manifest:value=>manifest=value,close(){server.stop(true);rmSync(dir,{recursive:true,force:true});}};
}

test('npm metadata stays aligned with releases and maps all supported hosts',()=>{
 const pkg=require('../npm/package.json'),project=require('../package.json');expect(pkg.name).toBe('dbsandbox');expect(pkg.version).toBe(project.version);expect(pkg.dependencies['@bsdkrun/cli']).toBe('^0.12.2');expect(pkg.bin.dbsandbox).toBe('bin/dbsandbox.js');
 expect(detect('darwin','arm64').target).toBe('darwin-aarch64');expect(detect('linux','x64').target).toBe('linux-x86_64');expect(detect('linux','arm64').target).toBe('linux-arm64');for(const [os,arch]of [['darwin','x64'],['win32','x64'],['linux','ia32']])expect(()=>detect(os,arch)).toThrow('unsupported platform');
});

test('npm first-run installation verifies release bytes and forwards arguments, dependency path and exit status',async()=>{
 const f=fixture();try{
  const script=join(f.pkg,'bin','dbsandbox.js'),result=await run(node,[script,'postgres','start','--password','spaces $ and ;'],{env:{...f.env,NPM_TEST_EXIT:'7'}});expect(result.status,result.stderr).toBe(7);const output=JSON.parse(result.stdout);expect(output.args).toEqual(['postgres','start','--password','spaces $ and ;']);expect(output.bsd).toBe(realpathSync(join(f.bsd,'bin','bsdkrun.js')));expect(output.runtime).toBe('bsdkrun 0.12.2');expect(f.requests).toEqual(['/v0.2.0/'+f.asset,'/v0.2.0/SHA256SUMS']);expect(readFileSync(f.binary)).toEqual(readFileSync(join(f.data,'dbsandbox')));
  const again=await run(node,[script,'--version'],{env:f.env});expect(again.status,again.stderr).toBe(0);expect(again.stdout.trim()).toBe('dbsandbox 0.2.0');expect(f.requests).toHaveLength(2);
  const override=join(f.dir,'bsd-override');writeFileSync(override,`#!${node}\nconsole.log('bsdkrun override');`,{mode:0o755});const custom=await run(node,[script,'doctor'],{env:{...f.env,BSDKRUN_BIN:override}});expect(JSON.parse(custom.stdout).bsd).toBe(override);
  const child=spawn(node,[script,'--wait'],{env:f.env,stdio:['ignore','pipe','pipe']});const closed=new Promise(resolve=>child.on('close',resolve));await new Promise(resolve=>child.stdout.once('data',resolve));child.kill('SIGTERM');expect(await closed).toBe(143);
 }finally{f.close();}
});

test('npm installation rejects invalid checksums and leaves existing binaries intact on failure',async()=>{
 const f=fixture();try{
  f.manifest('0'.repeat(64)+'  '+f.asset+'\n');let result=await run(node,[join(f.pkg,'scripts','postinstall.js')],{env:f.env});expect(result.status).toBe(1);expect(result.stderr).toContain('Checksum mismatch');expect(existsSync(f.binary)).toBe(false);expect(readdirSync(join(f.pkg,'binaries'))).toEqual([]);
  mkdirSync(join(f.pkg,'binaries'),{recursive:true});writeFileSync(f.binary,'existing');result=await run(node,[join(f.pkg,'scripts','postinstall.js')],{env:{...f.env,DBSANDBOX_BINARY:join(f.dir,'missing')}});expect(result.status).toBe(1);expect(readFileSync(f.binary,'utf8')).toBe('existing');
 }finally{f.close();}
});

test('npm skip and local executable installation work without downloading',async()=>{
 const f=fixture();try{
  const installer=join(f.pkg,'scripts','postinstall.js');let result=await run(node,[installer],{env:{...f.env,DBSANDBOX_SKIP_DOWNLOAD:'1'}});expect(result.status,result.stderr).toBe(0);expect(existsSync(f.binary)).toBe(false);
  result=await run(node,[installer],{env:{...f.env,DBSANDBOX_BINARY:join(f.data,'dbsandbox')}});expect(result.status,result.stderr).toBe(0);expect(f.requests).toEqual([]);expect(readFileSync(f.binary)).toEqual(readFileSync(join(f.data,'dbsandbox')));
 }finally{f.close();}
});

test('packed npm package supports npx with install scripts disabled and includes only launcher files',async()=>{
 const f=fixture();try{
  const consumer=join(f.dir,'consumer');mkdirSync(consumer);const options={env:{...f.env,npm_config_cache:join(f.dir,'cache')},cwd:f.dir};
  let result=await run('npm',['pack',f.bsd,'--json','--pack-destination',f.dir],options);expect(result.status,result.stderr).toBe(0);const bsdPack=join(f.dir,JSON.parse(result.stdout)[0].filename);
  result=await run('npm',['pack',f.pkg,'--json','--pack-destination',f.dir],options);expect(result.status,result.stderr).toBe(0);const info=JSON.parse(result.stdout)[0],paths=info.files.map(f=>f.path);expect(paths).toContain('bin/dbsandbox.js');expect(paths).toContain('LICENSE');expect(paths.some(path=>path.startsWith('binaries/')||path.startsWith('node_modules/'))).toBe(false);expect(paths.some(path=>path.endsWith('.purs'))).toBe(false);
  result=await run('npm',['install','--prefix',consumer,'--ignore-scripts','--package-lock=false','--no-audit','--no-fund',bsdPack,join(f.dir,info.filename)],options);expect(result.status,result.stderr).toBe(0);expect(existsSync(join(consumer,'node_modules','dbsandbox','binaries','dbsandbox'))).toBe(false);
  result=await run('npx',['--no-install','dbsandbox','--version'],{env:options.env,cwd:consumer});expect(result.status,result.stderr).toBe(0);expect(result.stdout.trim()).toBe('dbsandbox 0.2.0');expect(f.requests).toContain('/v0.2.0/'+f.asset);
 }finally{f.close();}
});
