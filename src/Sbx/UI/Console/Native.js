import {fileURLToPath} from 'node:url';
export const resolve = plan => () => {
  const compiled=typeof Bun!=='undefined'&&Bun.main.includes('$bunfs');
  return {program:plan.cli?process.execPath:plan.program,args:plan.cli?[...(compiled?[]:[fileURLToPath(new URL('../../bin/dbsandbox.js',import.meta.url))]),...plan.args]:plan.args,label:plan.label};
};
