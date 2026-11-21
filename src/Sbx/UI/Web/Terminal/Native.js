import {WebSocketServer} from 'ws';
import {randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {async} from '../Bsdkrun.Internal/foreign.js';

export const create = () => ({pending:new Map(),active:new Map(),wss:null,closed:false});
export const reserve = manager => plan => () => {
  if(manager.closed)throw Error('Dashboard is closing');
  if(manager.pending.size+manager.active.size>=12)throw Error('Close a terminal before opening another');
  const id=randomBytes(16).toString('hex'),ticket=randomBytes(32).toString('hex');
  const timer=setTimeout(()=>manager.pending.delete(id),30000);timer.unref();
  manager.pending.set(id,{plan,ticket,timer});return {id,ticket,label:plan.label};
};
export function command(plan){
  if(!plan.cli)return [plan.program,...plan.args];
  const compiled=typeof Bun!=='undefined'&&Bun.main.includes('$bunfs');
  return [process.execPath,...(compiled?[]:[fileURLToPath(new URL('../../bin/dbsandbox.js',import.meta.url))]),...plan.args];
}
function stop(session){
  if(session.stopped)return;session.stopped=true;
  try{process.kill(-session.process.pid,'SIGTERM');}catch{session.process?.kill('SIGTERM');}
  const timer=setTimeout(()=>{try{process.kill(-session.process.pid,'SIGKILL');}catch{session.process?.kill('SIGKILL');}},1500);timer.unref();
  session.process?.exited.finally(()=>{clearTimeout(timer);session.process.terminal?.close();});
}
export const attach = manager => port => server => () => {
  const wss=new WebSocketServer({noServer:true,maxPayload:65536,perMessageDeflate:false});manager.wss=wss;
  server.on('upgrade',(request,socket,head)=>{
    const reject=()=>{socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');};
    const hosts=[`127.0.0.1:${port}`,`localhost:${port}`],origins=hosts.map(host=>'http://'+host);
    if(manager.closed||!hosts.includes(request.headers.host)||!origins.includes(request.headers.origin))return reject();
    const url=new URL(request.url,'http://127.0.0.1'),id=url.searchParams.get('id'),pending=manager.pending.get(id);
    if(url.pathname!=='/api/terminal/socket'||!pending||url.searchParams.get('ticket')!==pending.ticket)return reject();
    manager.pending.delete(id);clearTimeout(pending.timer);
    wss.handleUpgrade(request,socket,head,ws=>{
      const session={process:null,stopped:false,decoder:new TextDecoder()};manager.active.set(id,session);
      const send=message=>{if(ws.readyState===1)ws.send(JSON.stringify(message));};
      const env={...process.env,TERM:'xterm-256color',COLORTERM:'truecolor'};delete env.DBSANDBOX_TUI;delete env.NO_COLOR;
      try{
        session.process=Bun.spawn(command(pending.plan),{env,terminal:{cols:80,rows:24,data(_,data){
          if(ws.bufferedAmount>1024*1024){ws.close(1013,'Terminal output is too fast');stop(session);return;}
          // WebSocket text frames must preserve UTF-8 characters across PTY chunks.
          const output=session.decoder.decode(data,{stream:true});if(output)send({type:'output',data:output});
        }}});
        session.process.exited.then(code=>{const tail=session.decoder.decode();if(tail)send({type:'output',data:tail});send({type:'exit',code});ws.close(1000);session.process.terminal?.close();manager.active.delete(id);});
        ws.on('message',bytes=>{
          try{const message=JSON.parse(String(bytes));
            if(message.type==='input'&&typeof message.data==='string'&&message.data.length<=32768)session.process.terminal.write(message.data);
            else if(message.type==='resize'&&Number.isInteger(message.cols)&&Number.isInteger(message.rows)&&message.cols>=2&&message.cols<=500&&message.rows>=1&&message.rows<=300)session.process.terminal.resize(message.cols,message.rows);
            else ws.close(1008,'Invalid terminal message');
          }catch{ws.close(1008,'Invalid terminal message');}
        });
      }catch(error){send({type:'error',message:error.message});ws.close(1011);manager.active.delete(id);}
      ws.on('close',()=>{stop(session);manager.active.delete(id);});
      ws.on('error',()=>stop(session));
    });
  });
};
export const closeImpl = manager => async(async()=>{
  manager.closed=true;for(const pending of manager.pending.values())clearTimeout(pending.timer);manager.pending.clear();
  const sessions=[...manager.active.values()];for(const session of sessions)stop(session);
  for(const ws of manager.wss?.clients||[])ws.terminate();
  await Promise.allSettled(sessions.map(session=>session.process?.exited));
  manager.wss?.close();manager.active.clear();
});
