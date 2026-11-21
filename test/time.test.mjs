import {test,expect} from 'bun:test';
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';

const time=resolve('output/Sbx.UI.Time/foreign.js'),logs=resolve('output/Sbx.UI.LogPresentation/index.js'),web=resolve('ui/src/graph.js');
function inTimezone(zone,instant){
 const source=`import {created,timestamp} from ${JSON.stringify(time)};import {dated} from ${JSON.stringify(logs)};import {branchGraph} from ${JSON.stringify(web)};const instant=${JSON.stringify(instant)},seconds=Date.parse(instant)/1000;console.log(JSON.stringify({created:created(seconds),timestamp:timestamp(instant),logs:dated(instant)(instant+' ready'),web:branchGraph([{branch:'main',parent:null,createdAt:seconds}])[0].created}));`;
 const result=spawnSync(process.execPath,['-e',source],{env:{...process.env,TZ:zone},encoding:'utf8',timeout:10000});expect(result.status,result.stderr).toBe(0);return JSON.parse(result.stdout);
}

test('web and terminal dates honor local timezone, fractional offsets, DST and date rollover',()=>{
 for(const [zone,instant,date,stamp] of [
  ['Indian/Antananarivo','2026-11-21T23:30:00.009Z','2026-11-22 02:30 +03:00','2026-11-22 02:30:00.009 +03:00'],
  ['Asia/Kathmandu','2026-11-21T23:30:00.009Z','2026-11-22 05:15 +05:45','2026-11-22 05:15:00.009 +05:45'],
  ['America/New_York','2026-11-21T23:30:00.009Z','2026-11-21 18:30 -05:00','2026-11-21 18:30:00.009 -05:00'],
  ['America/New_York','2026-07-01T12:00:00.009Z','2026-07-01 08:00 -04:00','2026-07-01 08:00:00.009 -04:00'],
 ]){const result=inTimezone(zone,instant);expect(result).toEqual({created:date,timestamp:stamp,logs:{date:stamp,text:'ready'},web:date});}
});
