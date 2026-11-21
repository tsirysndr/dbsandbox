import {createServer} from 'node:http';
import {async} from '../Bsdkrun.Internal/foreign.js';

export const listenImpl = port => handler => async(signal => new Promise((resolve,reject)=>{
  const server=createServer((req,res)=>{
    const chunks=[];let size=0,cancel;
    req.on('data',chunk=>{
      size+=chunk.length;
      if(size>16384){res.writeHead(413,{'Content-Type':'text/plain'});res.end('Request too large');req.destroy();}
      else chunks.push(chunk);
    });
    req.on('end',()=>{
      if(res.writableEnded)return;
      const url=new URL(req.url||'/', 'http://127.0.0.1');
      const request={method:req.method||'',path:url.pathname,query:url.searchParams.get('q')||'',database:url.searchParams.get('database')||'',branch:url.searchParams.get('branch')||'',source:url.searchParams.get('source')||'server',id:url.searchParams.get('id')||'',host:req.headers.host||'',origin:req.headers.origin||'',token:req.headers['x-dbsandbox-token']||'',body:Buffer.concat(chunks).toString('utf8')};
      cancel=handler(request)(()=>()=>{if(!res.writableEnded){res.writeHead(500,{'Content-Type':'text/plain'});res.end('Internal error');}})(response=>()=>{if(!res.destroyed){res.writeHead(response.status,response.headers);res.end(response.body);}})();
    });
    req.on('error',()=>{});
    res.on('close',()=>{if(!res.writableEnded)cancel?.();});
  });
  server.on('error',reject);
  server.listen(port,'127.0.0.1',()=>resolve(server));
  signal.addEventListener('abort',()=>{server.closeAllConnections();server.close();},{once:true});
}));

export const closeImpl = server => async(()=>new Promise((resolve,reject)=>{
  server.closeAllConnections();
  server.close(error=>error?reject(error):resolve());
}));
