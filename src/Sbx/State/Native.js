import {mkdirSync,chmodSync} from 'node:fs';
import {dirname} from 'node:path';
export const prepare = path => () => { mkdirSync(dirname(path),{recursive:true,mode:0o700}); };
export const protect = path => () => chmodSync(path,0o600);
