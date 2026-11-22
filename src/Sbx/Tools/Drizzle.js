import { execFile } from 'node:child_process';
import { async } from '../Bsdkrun.Internal/foreign.js';

// Probe in the external runtime that runs Kit, rather than the compiled Bun
// bundle. A fresh process also avoids cached missing-module results after install.
const probe = `
const {createRequire}=require('node:module');
const {realpathSync}=require('node:fs');
const {pathToFileURL}=require('node:url');
(async()=>{
  const loader=createRequire(realpathSync(process.argv[1]));
  for(const name of JSON.parse(process.argv[2]))
    await import(pathToFileURL(loader.resolve(name)).href);
})().catch(()=>{process.exitCode=1;});
`;
export const usableImpl = (runtime) => (entry) => (packages) =>
  async(
    (signal) =>
      new Promise((resolve) => {
        execFile(
          runtime,
          ['-e', probe, entry, JSON.stringify(packages)],
          { signal, timeout: 15000, maxBuffer: 65536 },
          (error) => resolve(!error),
        );
      }),
  );
