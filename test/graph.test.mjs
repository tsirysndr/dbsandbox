import dayjs from 'dayjs';
import {test,expect} from 'bun:test';
import {layout,position,terminal} from '../output/Sbx.Branch.Graph/index.js';
import {branchGraph,segmentPath} from '../ui/src/graph.js';
import {epoch,dateLabel} from '../output/Sbx.Branch.Graph.Metadata/foreign.js';
import {fixture} from './support/global-fixture.mjs';
import {writeFileSync,readFileSync} from 'node:fs';

const item=(branch,parent=null,createdAt=1)=>({branch,parent,createdAt});

test('graph draws nested forks and siblings in topological order with real parent indices',()=>{
 const input=[item('sibling','main',4),item('nested','feature',3),item('feature','main',2),item('main',null,1),item('orphan','removed',5)];
 const nodes=layout(input);expect(nodes.map(n=>n.item.branch)).toEqual(['main','feature','nested','sibling','orphan']);expect(nodes.map(n=>n.lane)).toEqual([0,1,2,1,0]);expect(nodes.map(n=>n.parentIndex)).toEqual([-1,0,1,0,-1]);expect(nodes.map(n=>n.unknown)).toEqual([false,false,false,false,true]);
 const nested=position(nodes)(nodes[2]);expect(nested.segments).toContainEqual({fromLane:1,toLane:2,fromY:0,toY:1,color:nested.color});expect(nested.segments).toContainEqual({fromLane:0,toLane:0,fromY:0,toY:2,color:position(nodes)(nodes[3]).color});
 expect(terminal(nested).map(s=>s.text).join('')).toContain('●');expect(new Set(branchGraph(input).map(n=>n.graph.color)).size).toBeGreaterThan(2);expect(segmentPath(nested.segments.find(s=>s.toLane===2))).toContain('Q');
});

test('graph handles cycles, unknown origins, search without ancestors and deep branches without inventing links',()=>{
 for(const input of [[item('a','b'),item('b','a')],[item('a','a')],[item('old')]]){
  const nodes=layout(input);expect(nodes).toHaveLength(input.length);expect(nodes.every(n=>n.unknown && n.parentIndex===-1)).toBe(true);expect(nodes.flatMap(n=>position(nodes)(n).segments)).toEqual([]);
 }
 const filtered=branchGraph([item('nested','feature')]);expect(filtered[0].graph.unknown).toBe(true);expect(filtered[0].graph.segments).toEqual([]);
 const deep=layout(Array.from({length:70},(_,i)=>item(i===0?'main':'b'+i,i===0?null:i===1?'main':'b'+(i-1),i)));expect(deep).toHaveLength(70);expect(deep.at(-1).lane).toBe(69);
 expect(layout([])).toEqual([]);
});

test('metadata preserves ISO date strings as epoch seconds, numeric wire dates and missing values',()=>{
 const iso='2026-11-21T10:15:30Z';expect(epoch(iso)).toBe(Date.parse(iso)/1000);expect(epoch(Date.parse(iso))).toBe(epoch(iso));expect(epoch(String(epoch(iso)))).toBe(epoch(iso));expect(dateLabel(epoch(iso))).toBe(dayjs('2026-11-21T10:15:30Z').format('YYYY-MM-DD HH:mm Z'));
 for(const value of [null,undefined,'',NaN,'bad',-1])expect(epoch(value)).toBeNull();expect(dateLabel(null)).toBe('Unknown');
});

test('inventory exposes ancestry, dates and graph positions for both dedicated servers and ZFS-only branches',()=>{
 const f=fixture();f.env.TZ='UTC';try{f.seed();const runtime=JSON.parse(readFileSync(f.runtime));runtime.volumes=[{name:'postgres-sbx',branches:[{name:'main',origin:null,created_at:'2026-11-20T10:00:00Z'},{name:'feature',origin:'main',created_at:'2026-11-21T10:15:30Z'},{name:'nested',origin:'feature',created_at:'2026-11-21T11:00:00Z'}],attached_to:[]}];writeFileSync(f.runtime,JSON.stringify(runtime));
  const result=f.run(['ps','--all','--json']);expect(result.status,result.stderr).toBe(0);const rows=JSON.parse(result.stdout);expect(rows.map(r=>r.branch)).toEqual(['main','feature','nested']);expect(rows[1]).toMatchObject({parent:'main',created:'2026-11-21 10:15 +00:00',graph:{lane:1,parentIndex:0,unknown:false}});expect(rows[2]).toMatchObject({parent:'feature',kind:'data',graph:{lane:2,parentIndex:1}});expect(rows[0].createdAt).toBe(Date.parse('2026-11-20T10:00:00Z')/1000);
 }finally{f.close();}
});
