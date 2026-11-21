import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {async} from '../Bsdkrun.Internal/foreign.js';
export const start = body => output => () => {
  const compiled=typeof Bun!=='undefined'&&Bun.main.includes('$bunfs');
  const args=[...(compiled?[]:[fileURLToPath(new URL('../../bin/dbsandbox.js',import.meta.url))]),'__ui-action',body];
  return launch({program:process.execPath,args})(output)();
};
export const launch = command => output => () => {
  const env={...process.env};delete env.DBSANDBOX_TUI;
  const child=spawn(command.program,command.args,{env,stdio:['ignore','pipe','pipe'],detached:process.platform!=='win32'});
  let closed=false;
  const exited=new Promise((resolve,reject)=>{
    child.once('error',error=>{closed=true;reject(error);});
    child.once('close',code=>{closed=true;resolve(code??1);});
  });exited.catch(()=>{});
  for(const stream of [child.stdout,child.stderr]){stream.setEncoding('utf8');stream.on('data',chunk=>{try{output(chunk)();}catch{/* Never fall back to the UI terminal when a log sink fails. */}});}
  return {child,exited,isClosed:()=>closed};
};
export const waitImpl = handle => async(()=>handle.exited);
export const stopImpl = handle => async(async()=>{
  if(handle.isClosed())return;
  handle.child.kill('SIGTERM');
  const timer=setTimeout(()=>{
    try{process.platform==='win32'?handle.child.kill('SIGKILL'):process.kill(-handle.child.pid,'SIGKILL');}catch{}
  },8000);
  try{await handle.exited;}finally{clearTimeout(timer);}
});
