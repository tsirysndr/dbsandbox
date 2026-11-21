import {spawn} from 'node:child_process';
import {async} from '../Bsdkrun.Internal/foreign.js';
export const writeImpl = program => args => text => async(signal => new Promise(resolve=>{
  const child=spawn(program,args,{stdio:['pipe','ignore','ignore']});
  let done=false;
  const finish=code=>{if(done)return;done=true;clearTimeout(timer);signal.removeEventListener('abort',abort);resolve(code);};
  const abort=()=>{child.kill();finish(1);};
  const timer=setTimeout(abort,5000);
  child.on('error',()=>finish(1));child.on('exit',code=>finish(code??1));
  child.stdin.on('error',abort);child.stdin.end(text);
  signal.addEventListener('abort',abort,{once:true});
}));
