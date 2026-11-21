import {test,expect} from 'bun:test';
import {spawnSync} from 'node:child_process';
import {fixture} from './support/global-fixture.mjs';
import {score,rank} from '../output/Sbx.UI.Terminal.Fuzzy/index.js';
import {initial,Search,Input,Fork,Help,Normal,LogView,DatabaseSelect,branches,databases,selectedDatabase,current,filtered,updateRows} from '../output/Sbx.UI.Terminal.Model/index.js';
import {tree} from '../output/Sbx.UI.Terminal.View/index.js';
import {render,attachTestRenderer} from '../output/OpenTUI.Renderer/foreign.js';
import {createTestRenderer} from '@opentui/core/testing';
import * as core from '@opentui/core';
import {paginate} from '../ui/src/pagination.js';
import {writeFileSync,readFileSync} from 'node:fs';
import {join} from 'node:path';
import {Nothing} from '../output/Data.Maybe/index.js';
import {clean} from '../output/Sbx.UI.Terminal.Native/foreign.js';

test('fzf-style subsequence search matches nonadjacent letters and ranks adjacent prefixes first',()=>{
 expect(score('ftr')('feature')).not.toBeInstanceOf(Nothing);
 expect(score('FTR')('feature')).not.toBeInstanceOf(Nothing);
 expect(score('zxy')('feature')).toBeInstanceOf(Nothing);
 const rows=[{branch:'some-feature',database:'postgres'},{branch:'feature',database:'postgres'},{branch:'main',database:'duckdb'}];
 expect(rank('feat')(rows).map(r=>r.branch)).toEqual(['feature','some-feature']);expect(rank('')(rows)).toHaveLength(3);
});

test('native OpenTUI panels, fuzzy overlays and bottom status bar render at desktop and compact terminal sizes',async()=>{
 const row={tool:'postgres-sbx',database:'postgres',branch:'feature-auth',guest:'linux',version:'18',status:'RUNNING',running:true,active:true,port:5432,url:'postgres://test:***@localhost:5432/db',ui:'studio'};
 const t=await createTestRenderer({width:120,height:40});const renderer=attachTestRenderer(t.renderer,core);
 try{
  for(const [width,height] of [[120,40],[80,24]]){
   t.resize(width,height);
   const model={...initial,loading:false,notice:'Ready',rows:[row],mode:Normal.value};
   render(renderer)(tree({columns:width,rows:height})(model))();await t.renderOnce();
   const frame=t.captureCharFrame();expect(frame).toContain('SERVERS & BRANCHES');expect(frame).toContain('feature-auth');expect(frame.trimEnd().split('\n').at(-1)).toContain('NORMAL');expect(frame).not.toContain('+---');expect(frame).not.toContain('╭');expect(frame).toContain('\ue0a0');
   render(renderer)(tree({columns:width,rows:height})({...model,nerdFont:false}))();await t.renderOnce();expect(t.captureCharFrame()).not.toContain('\ue0a0');
   for(const mode of [Search.value,new Input(Fork.value),Help.value,new LogView({database:"postgres",branch:"feature-auth",source:"server",id:"",offset:0,column:0,follow:true,filter:"",searching:false,timestamps:true})]){
    render(renderer)(tree({columns:width,rows:height})({...model,mode,query:'ftr',logText:'database log line\nsecond line'}))();await t.renderOnce();
    const modal=t.captureCharFrame();expect(modal.trimEnd().split('\n').at(-1)).toContain(mode instanceof Search?'SEARCH':mode instanceof Help?'HELP':mode instanceof LogView?'LOGS':'COMMAND');
    if(mode instanceof Search){expect(modal).toContain('FIND A BRANCH');expect(modal).toContain('1 matches');}
   }
  }
 }finally{await t.dispose();}
 expect(clean('\x1b[2Jhostile\ntext')).toBe('hostile text');
});

test('web branch pagination clamps after filtering and preserves all rows across pages',()=>{
 const items=Array.from({length:53},(_,index)=>index);
 expect(paginate(items,1,10)).toMatchObject({page:1,pages:6,start:1,end:10,total:53});
 expect(paginate(items,6,10).items).toEqual([50,51,52]);expect(paginate(items,9,25)).toMatchObject({page:3,pages:3,start:51,end:53});
 expect(paginate(items.slice(0,3),6,10)).toMatchObject({page:1,start:1,end:3});expect(paginate([],1,10)).toMatchObject({page:1,pages:1,start:0,end:0});
 expect(Array.from({length:6},(_,i)=>paginate(items,i+1,10).items).flat()).toEqual(items);
});

test('help is plain text and --no-color is accepted before and after subcommands',()=>{
 const f=fixture();try{for(const args of [['--no-color','--help'],['postgres','--no-color','--help']]){const r=f.run(args);expect(r.status,r.stderr).toBe(0);expect(r.stdout).not.toContain('\x1b[');}}finally{f.close();}
});

test('tui rejects non-interactive input and still provides help and shell completion',()=>{
 const f=fixture();try{const rejected=f.run(['tui']);expect(rejected.status).toBe(1);expect(rejected.stderr).toContain('interactive terminal');expect(f.run(['tui','--help']).status).toBe(0);expect(f.run(['completion','bash']).stdout).toContain('tui');expect(f.calls()).toEqual([]);}finally{f.close();}
});

const python=spawnSync('python3',['--version']);
test.skipIf(python.status!==0)('real PTY keys search and stop the exact fork, override resources and restore terminal on q/Ctrl-C',()=>{
 const f=fixture();try{f.seed();f.state('typesense-sbx','vector-only',8108);const runtime=JSON.parse(readFileSync(f.runtime));runtime.volumes=[{name:'postgres-sbx',branches:[{name:'main',origin:null,created_at:'2026-11-20T10:00:00Z'},{name:'feature',origin:'main',created_at:'2026-11-21T10:15:30Z'},{name:'archive',origin:'feature',created_at:'2026-11-21T11:00:00Z'}],attached_to:[]}];writeFileSync(f.runtime,JSON.stringify(runtime));
 const clipboard=join(f.dir,'clipboard');
 const script=`#!${process.execPath}\nimport{writeFileSync}from'node:fs';writeFileSync(process.env.CLIPBOARD_LOG,await Bun.stdin.text());`;
 for(const name of ['pbcopy','wl-copy','xclip','xsel'])writeFileSync(join(f.dir,name),script,{mode:0o755});
 const result=spawnSync('python3',['test/support/tui-pty.py',process.execPath],{env:{...f.env,DISPLAY:':fixture',WAYLAND_DISPLAY:'fixture',CLIPBOARD_LOG:clipboard,LOG_EXPORT_FILE:join(f.dir,'exported.txt')},encoding:'utf8',timeout:60000});expect(result.status,result.stderr).toBe(0);expect(result.stdout).toContain('restore terminal');expect(readFileSync(clipboard,'utf8')).toContain('DO-NOT-LEAK@127.0.0.1:5433');expect(f.calls().filter(c=>c[0]==='docker'&&c[1]==='stop').map(c=>c[2])).toEqual([f.child]);expect(f.calls()).toContainEqual(['bsdkrun','update','bsdkrun-docker','--cpus','4','--mem','4096']);}finally{f.close();}
});


test('terminal database selection scopes navigation and fuzzy search to one database and recovers from removal',()=>{
 const rows=[{tool:'duckdb-sbx',database:'duckdb',branch:'main'},{tool:'postgres-sbx',database:'postgres',branch:'main'},{tool:'pg-feature',database:'postgres',branch:'feature'}];
 const model={...initial,rows};expect(databases(model)).toEqual(['duckdb','postgres']);expect(selectedDatabase(model)).toBe('duckdb');expect(branches(model).map(r=>r.tool)).toEqual(['duckdb-sbx']);
 const postgres={...model,database:'postgres',cursor:1};expect(current(postgres).value0.tool).toBe('pg-feature');expect(filtered({...postgres,query:'main'}).map(r=>r.tool)).toEqual(['postgres-sbx']);
 expect(branches({...postgres,rows:[rows[0]]}).map(r=>r.tool)).toEqual(['duckdb-sbx']);expect(branches({...postgres,rows:[]})).toEqual([]);
});


test('terminal graph renders nested colored lanes and dates, and polling preserves the highlighted tool',async()=>{
 const make=(branch,parent,createdAt)=>({tool:branch,database:'postgres',branch,parent,createdAt,guest:'linux',version:'18',status:'RUNNING',running:true,active:branch==='feature',port:5432,url:'postgres://test:***@localhost:5432/db',ui:'studio',kind:'server',deletable:false});
 const rows=[make('main',null,1795168800),make('feature','main',1795256130),make('nested','feature',1795258800)];
 const t=await createTestRenderer({width:140,height:40}),renderer=attachTestRenderer(t.renderer,core);
 try{const model={...initial,rows,loading:false,cursor:1};render(renderer)(tree({columns:140,rows:40})(model))();await t.renderOnce();const frame=t.captureCharFrame();expect(frame).toContain('GRAPH');expect(frame).toContain('CREATED (LOCAL)');expect(frame).toContain('2026-11-21');expect(frame).toContain('nested');expect(frame).toContain('│');expect(frame).toContain('●');
  const updated=updateRows([rows[0],make('earlier','main',1795200000),...rows.slice(1)])(model);expect(current(updated).value0.tool).toBe('feature');expect(updated.cursor).toBe(2);
 }finally{await t.dispose();}
});
