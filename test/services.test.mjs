import {test,expect} from 'bun:test';
import {spawnSync} from 'node:child_process';
import {mkdtempSync,rmSync,readFileSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {all,find} from '../output/Sbx.Profiles/index.js';
import {runArgs} from '../output/Sbx.Engine/index.js';
import {script} from '../output/Sbx.Services/index.js';
import {Linux} from '../output/Sbx.Profile/index.js';
import {Nothing} from '../output/Data.Maybe/index.js';

const expected=['databend','tigerbeetle','yugabytedb','vearch','timescale','tidb','spicedb','surrealdb','scylladb','qdrant','mongodb','cassandra','clickhouse','arangodb','cockroachdb'];
test('every requested local backend has a distinct runtime namespace; Pinecone is excluded',()=>{
  expect(all).toHaveLength(22);
  expect(new Set(all.map(d=>d.profile.tool)).size).toBe(all.length);
  for(const name of expected) expect(find(name).value0.name).toBe(name);
  expect(find('pinecone')).toBe(Nothing.value);
});
for(const name of expected) test(`${name}: rejects BSD before runtime access and mounts its branch persistently`,()=>{
  const p=find(name).value0.profile,dir=mkdtempSync(join(tmpdir(),'sbx-platform-'));
  try{
    for(const os of ['freebsd','netbsd']){
      const r=spawnSync(process.execPath,['bin/dbsandbox.js',name,'start',os],{encoding:'utf8',timeout:10000,env:{...process.env,XDG_CONFIG_HOME:dir,BSDKRUN_BIN:'/nonexistent/bsdkrun',BSDKRUN_NO_AUTO_INSTALL:'1'}});
      expect(r.status).not.toBe(0);expect(r.stderr).not.toContain('ENOENT');
    }
    const c={user:'fixture',password:'fixture-secret',db:'fixture'},st={os:'linux',version:p.defaultTag,port:65430,branch:'isolated',...c};
    const args=runArgs(p)(st)(c);
    expect(args).toContain(`/mnt/${p.tool}-isolated:${p.dataDir(Linux.value)}`);
    expect(args).toContain(`65430:${p.guestPort}`);
    expect(args).not.toContain('--network=host');
    expect(p.provision(Linux.value)).toBe(Nothing.value);
  }finally{rmSync(dir,{recursive:true,force:true});}
});
test('generated container entrypoints preserve quotes and literal shell characters',()=>{
  const dir=mkdtempSync(join(tmpdir(),'sbx-wrapper-')),path=join(dir,'start');
  try{
    const generated=script(path)(["printf '%s\\n' 'backtick ` literal $ value and single '\\''quote'",'test -f "$0"']);
    const write=spawnSync('sh',['-c',generated.slice(4)],{encoding:'utf8'});
    expect(write.status,write.stderr).toBe(0);
    expect(spawnSync('sh',['-n',path]).status).toBe(0);
    const run=spawnSync('sh',[path],{encoding:'utf8'});
    expect(run.status,run.stderr).toBe(0);expect(run.stdout).toContain("backtick ` literal $ value and single 'quote");
    expect(readFileSync(path,'utf8')).toContain('set -eu');
  }finally{rmSync(dir,{recursive:true,force:true});}

});


test('an invalid live-test selector fails instead of silently running zero databases',()=>{
  const r=spawnSync(process.execPath,['test','./test/live.e2e.mjs'],{encoding:'utf8',timeout:10000,env:{...process.env,DBSANDBOX_E2E_DATABASE:'pinecone',BSDKRUN_NO_AUTO_INSTALL:'1',BSDKRUN_BIN:'/nonexistent/bsdkrun'}});
  expect(r.status).not.toBe(0);expect(r.stderr).toContain('Unknown E2E database: pinecone');
});


test('TigerBeetle readiness accepts an empty database and rejects connection failures',()=>{
  const dir=mkdtempSync(join(tmpdir(),'sbx-tiger-ready-'));
  const p=find('tigerbeetle').value0.profile,argv=p.ready(Linux.value)(p.defaultTag)(p.defaults);
  try{
    writeFileSync(join(dir,'timeout'),'#!/bin/sh\nshift\nexec "$@"\n',{mode:0o755});
    const run=()=>spawnSync(argv[0],argv.slice(1),{encoding:'utf8',env:{...process.env,PATH:dir+':'+process.env.PATH}}).status;
    for(const [output,code,expected] of [['No accounts were found.',1,0],['connection refused',1,1],['account found',0,0]]){
      writeFileSync(join(dir,'tigerbeetle'),`#!/bin/sh\nprintf '%s\\n' '${output}' >&2\nexit ${code}\n`,{mode:0o755});
      expect(run()).toBe(expected);
    }
  }finally{rmSync(dir,{recursive:true,force:true});}
});
