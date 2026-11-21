import dayjs from 'dayjs';
import {test,expect} from 'bun:test';
import {create,append,read,limit,redact} from '../output/Sbx.UI.Session/index.js';
import {launch,waitImpl,stopImpl} from '../output/Sbx.UI.Session/foreign.js';
import {toAff} from '../output/Bsdkrun.Internal/index.js';
import {promise} from './support/aff.mjs';
import {filterLogLines,highlightMatches,datedLogLine} from '../ui/src/logs.js';
import {highlight,dated,chunks} from '../output/Sbx.UI.LogPresentation/index.js';
import {filterLines} from '../output/Sbx.Management.Logs/index.js';
import {Nothing} from '../output/Data.Maybe/index.js';

test('operation journals retain bounded tails and redact passwords across chunk boundaries',()=>{
 const journal=create();append(journal)('one')(['secret value'])('before secret ')();append(journal)('one')(['secret value'])('value after')();
 expect(read(journal)('one')().value0).toBe('before *** after');
 expect(redact(['p@ss word'])('p%40ss%20word')).toBe('***');
 append(journal)('large')([])('x'.repeat(limit+200))();expect(read(journal)('large')().value0.length).toBe(limit);
 for(let n=0;n<51;n++)append(journal)('job-'+n)([])('line')();expect(read(journal)('one')()).toBeInstanceOf(Nothing);expect(read(journal)('job-50')().value0).toBe('line');
});

test('inherited stdout/stderr from grandchildren is piped into the operation journal rather than the UI terminal',async()=>{
 let output='';
 const grandchild=`process.stdout.write('INHERITED-STDOUT\\n');process.stderr.write('INHERITED-STDERR\\n');`;
 const program=`import{spawnSync}from'node:child_process';spawnSync(process.execPath,['-e',${JSON.stringify(grandchild)}],{stdio:'inherit'});`;
 const child=launch({program:process.execPath,args:['-e',program]})(text=>()=>{output+=text;})();
 try{expect(await promise(toAff(waitImpl(child)))).toBe(0);expect(output).toContain('INHERITED-STDOUT');expect(output).toContain('INHERITED-STDERR');}finally{await promise(toAff(stopImpl(child)));}
});

test('log quick filters match case-insensitive words while retaining the full snapshot for export',()=>{
 const full='INFO ready\nERROR connection refused\nerror query failed\n';
 expect(filterLogLines(full,'ERROR')).toEqual({text:'ERROR connection refused\nerror query failed',matched:2,total:3});
 expect(filterLogLines(full,'error refused')).toMatchObject({text:'ERROR connection refused',matched:1});
 expect(filterLogLines(full,'absent').matched).toBe(0);expect(filterLogLines(full,'').text).toBe(full);
 expect(filterLines('ERROR refused')(full)).toEqual(['ERROR connection refused']);
});


test('web and terminal highlight literal repeated and overlapping matches without modifying log text',()=>{
 for(const [text,query] of [['ERROR query error','error'],['abab','aba bab'],['a[b] <script>','[b] <script>'],['ready','absent'],['','error']]){
  const web=highlightMatches(text,query),terminal=highlight(query)(text);
  expect(terminal).toEqual(web);expect(web.map(s=>s.text).join('')).toBe(text);
 }
 expect(highlightMatches('ERROR query error','error').filter(s=>s.match).map(s=>s.text)).toEqual(['ERROR','error']);
});

test('log dates preserve source instants, use capture time only when needed and toggle without changing exports',()=>{
 const captured='2026-11-21T10:00:00.000Z';
 for(const text of ['2026-11-21T09:10:11.123456789Z database ready','2026-11-21 09:10:11 ERROR query','plain output','<script>unsafe</script>'])expect(dated(captured)(text)).toEqual(datedLogLine(text,captured));
 expect(dated(captured)('plain output')).toEqual({date:dayjs(captured).format('YYYY-MM-DD HH:mm:ss.SSS Z'),text:'plain output'});
 const raw='2026-11-21T09:10:11Z ERROR query';
 expect(chunks(false)(captured)('error')(0)(100)(raw).map(s=>s.text).join('')).toBe('ERROR query');
 const spans=chunks(true)(captured)('error')(0)(100)(raw);expect(spans[0]).toMatchObject({text:dayjs('2026-11-21T09:10:11Z').format('YYYY-MM-DD HH:mm:ss.SSS Z')+'  ',foreground:'#71717a'});expect(spans.find(s=>s.bold)).toMatchObject({text:'ERROR',background:'#8129ff'});
});
