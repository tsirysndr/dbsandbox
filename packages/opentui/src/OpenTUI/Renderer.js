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
  const {core}=modules.get(renderer);
  const next=materialize(renderer,core,node);
  for(const child of [...renderer.root.getChildren()])child.destroyRecursively();
  renderer.root.add(next);
  renderer.requestRender();
};
export const size = renderer => () => ({columns:renderer.width,rows:renderer.height});
export const onKey = renderer => handler => () => {
  const listener=key=>{key.preventDefault();handler({name:key.name,text:key.sequence||'',ctrl:key.ctrl,meta:key.meta})();};
  const paste=event=>{event.preventDefault();handler({name:'paste',text:Buffer.from(event.bytes).toString('utf8'),ctrl:false,meta:false})();};
  renderer.keyInput.on('keypress',listener);renderer.keyInput.on('paste',paste);
  return ()=>{renderer.keyInput.off('keypress',listener);renderer.keyInput.off('paste',paste);};
};
export const onResize = renderer => handler => () => {renderer.on('resize',handler);return ()=>renderer.off('resize',handler);};
export const clipboard = renderer => value => () => {renderer.copyToClipboardOSC52(value);};
// Test support wraps OpenTUI's own memory renderer using the same bindings.
export const attachTestRenderer = (renderer,core) => {modules.set(renderer,{core});return renderer;};
