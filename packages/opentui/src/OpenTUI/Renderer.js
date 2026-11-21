const modules = new WeakMap();
export const available = () => Boolean(process.stdin.isTTY && process.stdout.isTTY);
export const openImpl = async () => {
  const core = await import('@opentui/core');
  const renderer = await core.createCliRenderer({exitOnCtrlC:false,exitSignals:[],screenMode:'alternate-screen',targetFps:30,useMouse:true,backgroundColor:'#09090b',consoleMode:'disabled',externalOutputMode:'passthrough'});
  const priorMode=process.env.DBSANDBOX_TUI;
  process.env.DBSANDBOX_TUI='1';
  const consoleMethods=Object.fromEntries(['log','warn','error','info','debug'].map(name=>[name,console[name]]));
  for(const name of Object.keys(consoleMethods))console[name]=()=>{};
  modules.set(renderer,{core,priorMode,consoleMethods});
  return renderer;
};
export const closeImpl = renderer => async () => {
  const info=modules.get(renderer);
  if(info?.priorMode===undefined)delete process.env.DBSANDBOX_TUI;else process.env.DBSANDBOX_TUI=info.priorMode;
  if(info?.consoleMethods)Object.assign(console,info.consoleMethods);
  await info?.terminal?.close();
  renderer.destroy();
  await renderer.closed;
  modules.delete(renderer);
};
export const box = options => children => ({kind:'box',options,children});
export const text = options => ({kind:'text',options});
export const styledText = options => spans => ({kind:'text',options,spans});
const dimension=value=>value ? (/^\d+$/.test(value)?Number(value):value) : undefined;
function tone(core,value,background=false){return process.env.NO_COLOR ? (background?core.RGBA.defaultBackground():core.RGBA.defaultForeground()) : value;}
function materialize(renderer,core,node){
  const o=node.options;
  if(node.kind==='text')return new core.TextRenderable(renderer,{id:o.id||undefined,content:node.spans?new core.StyledText(node.spans.map(span=>({__isChunk:true,text:span.text,fg:process.env.NO_COLOR?core.RGBA.defaultForeground():core.RGBA.fromHex(span.foreground),bg:process.env.NO_COLOR?core.RGBA.defaultBackground():core.RGBA.fromHex(span.background==='transparent'?'#111113':span.background),attributes:span.bold?core.TextAttributes.BOLD:0}))):o.content,fg:tone(core,o.foreground),bg:tone(core,o.background,true),attributes:o.bold?core.TextAttributes.BOLD:0,width:dimension(o.width),height:o.height||undefined,flexGrow:o.grow,flexShrink:0,wrapMode:'none',truncate:true});
  const box=new core.BoxRenderable(renderer,{id:o.id||undefined,flexDirection:o.direction,width:dimension(o.width),height:o.height||undefined,flexGrow:o.grow,flexShrink:0,paddingX:o.paddingX,paddingY:o.paddingY,gap:o.gap,...(o.border?{border:true,borderStyle:'rounded',borderColor:tone(core,o.borderColor)}:{border:false}),backgroundColor:tone(core,o.background,true),title:o.title||undefined,titleColor:tone(core,'#8129ff'),position:o.position||undefined,...(o.position?{left:o.left,top:o.top}:{}),zIndex:o.zIndex,overflow:'hidden'});
  for(const child of node.children)box.add(materialize(renderer,core,child));
  return box;
}
// A replacement tree is built before replacing the old one. Destroyed
// renderables release their native text buffers and layout resources.
export const render = renderer => node => () => {
  const info=modules.get(renderer);
  if(info.terminal){info.deferred=node;return;}
  const {core}=info;
  const next=materialize(renderer,core,node);
  for(const child of [...renderer.root.getChildren()])child.destroyRecursively();
  renderer.root.add(next);
  renderer.requestRender();
};
export const size = renderer => () => ({columns:renderer.width,rows:renderer.height});
export const onKey = renderer => handler => () => {
  const listener=key=>{key.preventDefault();const terminal=modules.get(renderer)?.terminal;if(terminal){if(key.name==='escape'){terminal.close();return;}if(key.ctrl&&key.name==='f'){terminal.toggle();return;}terminal.view.handleKeyPress(key);return;}handler({name:key.name,text:key.sequence||'',ctrl:key.ctrl,meta:key.meta})();};
  const paste=event=>{event.preventDefault();const terminal=modules.get(renderer)?.terminal;if(terminal){terminal.view.handlePaste(event);return;}handler({name:'paste',text:Buffer.from(event.bytes).toString('utf8'),ctrl:false,meta:false})();};
  renderer.keyInput.on('keypress',listener);renderer.keyInput.on('paste',paste);
  return ()=>{renderer.keyInput.off('keypress',listener);renderer.keyInput.off('paste',paste);};
};
export const onResize = renderer => handler => () => {renderer.on('resize',handler);return ()=>renderer.off('resize',handler);};
export const clipboard = renderer => value => () => {renderer.copyToClipboardOSC52(value);};
// Test support wraps OpenTUI's own memory renderer using the same bindings.
export const attachTestRenderer = (renderer,core) => {modules.set(renderer,{core});return renderer;};


// Keep the embedded terminal outside replacement dashboard trees. Background
// refreshes are deferred so they cannot destroy its live parser or PTY.
export const terminalImpl = renderer => command => async () => {
  const info=modules.get(renderer),{core}=info;
  if(info.terminal)throw Error('A terminal is already open');
  let processHandle, fullscreen=false, closing=false, resolveClosed;
  const closed=new Promise(resolve=>resolveClosed=resolve);
  const height=()=>fullscreen?renderer.height:Math.max(8,Math.floor(renderer.height/2));
  const box=new core.BoxRenderable(renderer,{position:'absolute',left:0,top:renderer.height-height(),width:renderer.width,height:height(),backgroundColor:tone(core,'#111113',true),paddingX:1,flexDirection:'column',zIndex:200,border:false});
  const heading=new core.TextRenderable(renderer,{content:command.label+'  ·  Esc close  ·  Ctrl-F fullscreen  ·  Ctrl-C interrupt',fg:tone(core,'#8129ff'),height:1,truncate:true,wrapMode:'none'});
  const view=new core.EmbeddedTerminalRenderable(renderer,{width:'100%',flexGrow:1,cols:Math.max(2,renderer.width-2),rows:Math.max(1,height()-2),maxScrollback:2000,onData:data=>{if(!closing)processHandle?.terminal?.write(data);},onTerminalResize:(cols,rows)=>processHandle?.terminal?.resize(cols,rows)});
  const bar=new core.TextRenderable(renderer,{content:' TERMINAL  '+command.label,fg:tone(core,'#ffffff'),bg:tone(core,'#8129ff',true),height:1,truncate:true});
  box.add(heading);box.add(view);box.add(bar);renderer.root.add(box);
  const resize=()=>{box.width=renderer.width;box.height=height();box.top=renderer.height-height();renderer.requestRender();};
  renderer.on('resize',resize);
  const session={view,toggle(){fullscreen=!fullscreen;resize();},async close(){
    if(closing)return closed;closing=true;
    renderer.off('resize',resize);
    if(processHandle){try{process.kill(-processHandle.pid,'SIGTERM');}catch{processHandle.kill('SIGTERM');}
      const timer=setTimeout(()=>{try{process.kill(-processHandle.pid,'SIGKILL');}catch{processHandle.kill('SIGKILL');}},1500);
      try{await processHandle.exited;}finally{clearTimeout(timer);processHandle.terminal?.close();}
    }
    box.destroyRecursively();info.terminal=null;
    if(info.deferred){const deferred=info.deferred;info.deferred=null;render(renderer)(deferred)();}
    renderer.requestRender();resolveClosed();return closed;
  }};
  info.terminal=session;
  try{
    const env={...process.env,TERM:'xterm-256color',COLORTERM:'truecolor'};delete env.DBSANDBOX_TUI;delete env.NO_COLOR;
    processHandle=Bun.spawn([command.program,...command.args],{env,terminal:{cols:Math.max(2,renderer.width-2),rows:Math.max(1,height()-2),data(_,data){view.write(data);renderer.requestRender();}}});
    processHandle.exited.then(code=>{if(!closing){heading.content=command.label+'  ·  Exited ('+code+')  ·  Esc close';processHandle.terminal?.close();renderer.requestRender();}});
  }catch(error){heading.content=error.message+'  ·  Esc close';}
  return closed;
};
