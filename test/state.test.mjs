import {test,expect} from 'bun:test';
import {Database as SQLite} from 'bun:sqlite';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync,existsSync,statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync,spawn} from 'node:child_process';
import * as Store from '../output/Sbx.State.Store/index.js';
import {instanceName} from '../output/Sbx.Branch.Identity/index.js';
import {Just,Nothing} from '../output/Data.Maybe/index.js';
import {open,close} from '../output/Drizzle.SQLite.BunSQLite/index.js';
import {execute,all,transaction} from '../output/Drizzle.Database/index.js';
import {raw,template,param} from '../output/Drizzle.SQL/index.js';
import {filterBranches} from '../ui/src/search.js';
const state={os:'linux',version:'18',port:5432,user:'postgres',password:'SECRET-FOR-STATE-TEST',db:'sandbox',branch:'main',cpus:2,mem:2048};
function fixture(action){const dir=mkdtempSync(join(tmpdir(),'sbx-sqlite-')),previous=process.env.XDG_CONFIG_HOME;process.env.XDG_CONFIG_HOME=dir;try{return action(dir);}finally{previous===undefined?delete process.env.XDG_CONFIG_HOME:process.env.XDG_CONFIG_HOME=previous;rmSync(dir,{recursive:true,force:true});}}

test('typed Drizzle bindings bind hostile values and roll back nested synchronous transactions',()=>{
 const db=open(':memory:')();try{
  execute(db)(raw('CREATE TABLE example (value TEXT NOT NULL)'))();
  const hostile="'); DROP TABLE example;--";
  execute(db)(template(['INSERT INTO example VALUES (',')'])([param(hostile)]))();
  expect(all(db)(raw('SELECT value FROM example'))()).toEqual([{value:hostile}]);
  expect(()=>transaction(db)(tx=>()=>{execute(tx)(raw("INSERT INTO example VALUES ('rollback')"))();throw Error('rollback');})()).toThrow('rollback');
  expect(all(db)(raw('SELECT value FROM example'))()).toHaveLength(1);
  transaction(db)(tx=>()=>{expect(()=>transaction(tx)(nested=>()=>{execute(nested)(raw("INSERT INTO example VALUES ('nested')"))();throw Error('nested');})()).toThrow('nested');execute(tx)(raw("INSERT INTO example VALUES ('committed')"))();})();
  expect(all(db)(raw('SELECT value FROM example'))()).toEqual([{value:hostile},{value:'committed'}]);
 }finally{close(db)();}
});

test('SQLite stores state, selections and fork manifests without writing JSON; FTS excludes credentials',()=>fixture(dir=>{
 const tool=instanceName('postgres-sbx')('feature-auth');
 expect(Store.load('postgres-sbx')()).toBeInstanceOf(Nothing);expect(existsSync(join(dir,'dbsandbox'))).toBe(false);
 Store.save('postgres-sbx')(state)();Store.save(tool)({...state,branch:'feature-auth',port:5433})();
 Store.saveEntries('postgres-sbx')([{name:'feature-auth',tool,running:true}])();Store.activate('postgres-sbx')(new Just('feature-auth'))();
 expect(Store.load(tool)().value0.branch).toBe('feature-auth');expect(Store.active('postgres-sbx')().value0).toBe('feature-auth');expect(Store.entries('postgres-sbx')()).toEqual([{name:'feature-auth',tool,running:true}]);
 expect(Store.search('fea au')()).toEqual([tool]);expect(Store.search('POSTGRES feature')()).toEqual([tool]);expect(Store.search('linux')()).toHaveLength(2);expect(Store.search(state.password)()).toEqual([]);expect(Store.search('" OR * NOT -')()).toEqual([]);
 const path=Store.databasePath();expect(statSync(path).mode&0o777).toBe(0o600);expect(existsSync(join(dir,'postgres-sbx','state.json'))).toBe(false);
 const sqlite=new SQLite(path,{readonly:true});try{expect(sqlite.query('PRAGMA user_version').get().user_version).toBe(1);const fts=sqlite.query('SELECT * FROM sandbox_search').all();expect(JSON.stringify(fts)).not.toContain(state.password);expect(Object.keys(fts[0]).sort()).toEqual(['branch','database','guest','tool','version']);}finally{sqlite.close();}
 Store.save(tool)({...state,branch:'renamed',port:5433})();expect(Store.search('feature')()).toEqual([]);expect(Store.search('ren')()).toEqual([tool]);Store.clear(tool)();expect(Store.load(tool)()).toBeInstanceOf(Nothing);expect(Store.search('ren')()).toEqual([]);
}));

test('legacy JSON is imported once, retained unchanged, and cannot resurrect deleted or updated state',()=>fixture(dir=>{
 const tool=instanceName('postgres-sbx')('feature');
 for(const [name,value] of [['postgres-sbx',state],[tool,{...state,branch:'feature',port:5433}]]){mkdirSync(join(dir,name));writeFileSync(join(dir,name,'state.json'),JSON.stringify(value));}
 writeFileSync(join(dir,'postgres-sbx','active.json'),'"feature"');writeFileSync(join(dir,'postgres-sbx','branches.json'),JSON.stringify([{name:'feature',tool,running:true}]));
 const original=readFileSync(join(dir,'postgres-sbx','state.json'),'utf8');
 expect(Store.load('postgres-sbx')().value0).toEqual(state);expect(Store.active('postgres-sbx')().value0).toBe('feature');expect(Store.entries('postgres-sbx')()).toHaveLength(1);
 Store.save('postgres-sbx')({...state,password:'new-password'})();Store.activate('postgres-sbx')(Nothing.value)();Store.clear(tool)();
 expect(Store.load('postgres-sbx')().value0.password).toBe('new-password');expect(Store.load(tool)()).toBeInstanceOf(Nothing);expect(Store.active('postgres-sbx')()).toBeInstanceOf(Nothing);expect(Store.entries('postgres-sbx')()).toEqual([]);expect(readFileSync(join(dir,'postgres-sbx','state.json'),'utf8')).toBe(original);
}));

test('FTS search treats operators and punctuation literally without SQL or FTS injection',()=>fixture(()=>{
 Store.save('postgres-sbx')({...state,branch:'café-feature'})();
 expect(Store.search('CAFE fea')()).toEqual(['postgres-sbx']);
 for(const input of ['"','*','()','"; DROP TABLE sandboxes; --','NEAR(feature, auth)','x OR postgres','a'.repeat(1000)])expect(()=>Store.search(input)()).not.toThrow();
 expect(Store.load('postgres-sbx')().value0.password).toBe(state.password);
}));

test('immediate branch filtering is case-insensitive and leaves source rows untouched',()=>{
 const rows=[{tool:'one',database:'postgres',branch:'feature-auth',guest:'linux'},{tool:'two',database:'duckdb',branch:'main',guest:'linux'}];
 expect(filterBranches(rows,' FEAT   post ')).toEqual([rows[0]]);expect(filterBranches(rows,'')).toEqual(rows);expect(filterBranches(rows,'missing')).toEqual([]);expect(rows).toHaveLength(2);
});

test('independent CLI processes can update state concurrently without dropping other rows',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'sbx-sqlite-concurrency-'));
 try{
  const setup=spawnSync(process.execPath,['-e',`import{save}from'./output/Sbx.State.Store/index.js';save('postgres-sbx')(${JSON.stringify(state)})();`],{env:{...process.env,XDG_CONFIG_HOME:dir},encoding:'utf8'});expect(setup.status,setup.stderr).toBe(0);
  await Promise.all(Array.from({length:6},(_,n)=>new Promise((resolve,reject)=>{
   const script=`import{save}from'./output/Sbx.State.Store/index.js';import{instanceName}from'./output/Sbx.Branch.Identity/index.js';save(instanceName('postgres-sbx')('concurrent-${n}'))(${JSON.stringify({...state,branch:`concurrent-${n}`,port:5433+n})})();`;
   const child=spawn(process.execPath,['-e',script],{env:{...process.env,XDG_CONFIG_HOME:dir},stdio:['ignore','pipe','pipe']});let err='';child.stderr.on('data',d=>err+=d);child.on('error',reject);child.on('close',code=>code===0?resolve():reject(Error(err)));
  })));
  const db=new SQLite(join(dir,'dbsandbox','state.sqlite'),{readonly:true});try{expect(db.query('SELECT count(*) AS total FROM sandboxes').get().total).toBe(7);expect(db.query('SELECT count(*) AS total FROM sandbox_search').get().total).toBe(7);}finally{db.close();}
 }finally{rmSync(dir,{recursive:true,force:true});}
});
