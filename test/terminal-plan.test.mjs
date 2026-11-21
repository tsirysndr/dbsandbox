import {test,expect} from 'bun:test';
import {fixture} from './support/global-fixture.mjs';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';

test('database consoles use pgcli, mycli and litecli while container and VM commands remain separate',()=>{
 const f=fixture();try{f.seed();for(const [tool,port]of [['mariadb-sbx',3306],['mysql-sbx',3307],['sqlite-sbx',8080],['duckdb-sbx',9494]])f.state(tool,'main',port);const runtime=JSON.parse(readFileSync(f.runtime));for(const tool of ['mariadb-sbx','mysql-sbx','sqlite-sbx','duckdb-sbx'])runtime.containers.push({name:tool,state:'running'});runtime.volumes=[{name:'postgres-sbx',branches:[{name:'main'},{name:'archive'}],attached_to:[]}];writeFileSync(f.runtime,JSON.stringify(runtime));
 const targets=[...['postgres','mariadb','mysql','sqlite','duckdb'].map(database=>({database,branch:'main',kind:'console'})),{database:'postgres',branch:'feature',kind:'container'},{database:'postgres',branch:'feature',kind:'vm'},{database:'postgres',branch:'archive',kind:'console'}];
 const source=`import{prepare,decode}from${JSON.stringify(resolve('output/Sbx.UI.Console.Plan/index.js'))};import{promise}from${JSON.stringify(resolve('test/support/aff.mjs'))};const results=[];for(const request of ${JSON.stringify(targets)})results.push(await promise(prepare(request)));console.log(JSON.stringify(results));`;
 const result=spawnSync(process.execPath,['-e',source],{env:f.env,encoding:'utf8',timeout:15000});expect(result.status,result.stderr).toBe(0);const plans=JSON.parse(result.stdout).map(result=>result.value0);
 for(const [index,client] of ['pgcli','mycli','mycli','litecli','duckdb'].entries())expect(plans[index].args).toEqual([targets[index].database,'--branch','main',client]);
 expect(plans[5]).toMatchObject({cli:true,args:['postgres','--branch','feature','shell']});expect(plans[6]).toMatchObject({cli:false,program:f.env.BSDKRUN_BIN,args:['exec','-t','bsdkrun-docker','sh']});expect(plans[7]).toContain('no interactive console');
 }finally{f.close();}
});
