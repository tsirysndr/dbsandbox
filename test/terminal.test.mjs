import {test,expect} from 'bun:test';
import {createServer} from 'node:http';
import {WebSocket} from 'ws';
import {create,reserve,attach,closeImpl,command} from '../output/Sbx.UI.Web.Terminal.Native/foreign.js';
import {boxOptions,textOptions} from '../output/OpenTUI.Renderer/index.js';
import {toAff} from '../output/Bsdkrun.Internal/index.js';
import {promise} from './support/aff.mjs';
import {createTestRenderer} from '@opentui/core/testing';
import * as core from '@opentui/core';
import {attachTestRenderer,terminalImpl,onKey,render,box,text} from '../output/OpenTUI.Renderer/foreign.js';

async function until(fn){for(let i=0;i<200;i++){const value=await fn();if(value)return value;await Bun.sleep(20);}throw Error('Timed out');}
async function harness(){const manager=create(),server=createServer((_,res)=>res.end());await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const port=server.address().port;attach(manager)(port)(server)();return{manager,base:`http://127.0.0.1:${port}`,url:`ws://127.0.0.1:${port}/api/terminal/socket`,async close(){await promise(toAff(closeImpl(manager)));await new Promise(resolve=>server.close(resolve));}};}
function connect(h,session,origin=h.base){const ws=new WebSocket(h.url+`?id=${session.id}&ticket=${session.ticket}`,{headers:{Origin:origin}});const messages=[];ws.on('message',data=>messages.push(JSON.parse(String(data))));return{ws,messages,text:()=>messages.filter(m=>m.type==='output').map(m=>m.data).join('')};}
async function rejected(h,session,origin){const c=connect(h,session,origin);const status=await new Promise((resolve,reject)=>{c.ws.on('unexpected-response',(_,res)=>{res.resume();resolve(res.statusCode);c.ws.terminate();});c.ws.on('error',()=>{});c.ws.on('open',()=>reject(Error('Unauthorized socket opened')));});return status;}
const shell=`process.stdin.setRawMode(true);console.log('READY '+process.stdout.columns+'x'+process.stdout.rows);process.stdin.on('data',data=>{const input=String(data);if(input.includes('size'))console.log('SIZE '+process.stdout.columns+'x'+process.stdout.rows);else if(input.includes('exit'))process.exit(42);else console.log('INPUT '+input);});`;

test('terminal sockets enforce origin and one-use tickets, preserve PTY input, resize and exit status',async()=>{
 const h=await harness();try{
  const session=reserve(h.manager)({cli:false,program:process.execPath,args:['-e',shell],label:'Database console'})();expect(await rejected(h,session,'http://evil.example')).toBe(403);
  const c=connect(h,session);await until(()=>c.text().includes('READY 80x24'));expect(await rejected(h,session,h.base)).toBe(403);
  c.ws.send(JSON.stringify({type:'input',data:'hello'}));await until(()=>c.text().includes('INPUT hello'));
  c.ws.send(JSON.stringify({type:'resize',cols:120,rows:37}));await Bun.sleep(50);c.ws.send(JSON.stringify({type:'input',data:'size'}));await until(()=>c.text().includes('SIZE 120x37'));
  c.ws.send(JSON.stringify({type:'input',data:'exit'}));await until(()=>c.messages.some(m=>m.type==='exit'));expect(c.messages.find(m=>m.type==='exit').code).toBe(42);await until(()=>h.manager.active.size===0);
 }finally{await h.close();}
});

test('closing a terminal kills its PTY process and malformed messages cannot reach the process',async()=>{
 const h=await harness();try{
  const session=reserve(h.manager)({cli:false,program:process.execPath,args:['-e',`console.log('PID '+process.pid);setInterval(()=>{},1000)`],label:'VM'})();const c=connect(h,session);await until(()=>c.text().includes('PID'));const pid=Number(c.text().match(/PID (\d+)/)[1]);
  c.ws.send(JSON.stringify({type:'resize',cols:-1,rows:24}));await until(()=>h.manager.active.size===0);await until(()=>{try{process.kill(pid,0);return false;}catch{return true;}});
 }finally{await h.close();}
});

test('native TUI terminal stays in a bottom panel, accepts input, toggles fullscreen and restores dashboard',async()=>{
 const t=await createTestRenderer({width:100,height:30}),renderer=attachTestRenderer(t.renderer,core);const off=onKey(renderer)(()=>()=>{})();
 const dashboard=box({...boxOptions,width:'100%',height:30})([text({...textOptions,content:'DASHBOARD',height:1})]);render(renderer)(dashboard)();
 let closed;
 try{
  closed=terminalImpl(renderer)({program:process.execPath,args:['-e',shell],label:'DuckDB console'})();
  await until(async()=>{await t.renderOnce();return t.captureCharFrame().includes('READY');});let frame=t.captureCharFrame();expect(frame).toContain('DASHBOARD');expect(frame).toContain('DuckDB console');expect(frame).toContain('TERMINAL');
  await t.mockInput.typeText('hello');await until(async()=>{await t.renderOnce();return t.captureCharFrame().includes('INPUT hello');});
  render(renderer)(box({...boxOptions,width:'100%',height:30})([text({...textOptions,content:'REFRESHED DASHBOARD',height:1})]))();await t.renderOnce();expect(t.captureCharFrame()).toContain('DuckDB console');
  t.mockInput.pressKey('f',{ctrl:true});await t.renderOnce();expect(t.captureCharFrame()).not.toContain('DASHBOARD');expect(t.captureCharFrame()).toContain('DuckDB console');
  t.mockInput.pressEscape();await closed;await t.renderOnce();frame=t.captureCharFrame();expect(frame).toContain('REFRESHED DASHBOARD');expect(frame).not.toContain('TERMINAL');
 }finally{t.mockInput.pressEscape();await closed;off();await t.dispose();}
});
