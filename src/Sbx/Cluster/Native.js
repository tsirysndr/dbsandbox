import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, readFileSync } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { resolve } from 'node:path';
import * as SDK from '@bsdkrun/sdk';
import cluster from '../../packages/cluster/index.cjs';
import { async } from '../Bsdkrun.Internal/foreign.js';
const entry = {
  executable: process.execPath,
  args: /\.[cm]?js$/.test(process.argv[1] || '')
    ? [resolve(process.argv[1])]
    : [],
};
export const invocation = () => entry;
export const internalWorker = () =>
  process.argv[2] === '__cluster-worker' ? process.argv[3] || '{}' : null;
export const quiet = () => {
  console.log = (...args) => console.error(...args);
};
export const respond = (text) => () => process.stdout.write(text + '\n');
export const readText = (path) => () => readFileSync(path, 'utf8');
export const uuid = () => randomUUID();
export const hashFileImpl = (path) =>
  async(async (signal) => {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(path, { signal }))
      hash.update(chunk);
    return hash.digest('hex');
  });
export const execImpl = (args) =>
  async((signal) => SDK.runCli(args, { signal }));
export const transferImpl = (args) => (path) => (receive) =>
  async(async (signal) => {
    await SDK.ensurePreflight();
    const child = SDK.spawnCli(args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      signal,
    });
    let detail = '';
    child.stderr.on('data', (chunk) => {
      if (detail.length < 65536) detail += chunk;
    });
    const exit = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
    try {
      if (receive) {
        child.stdout.resume();
        await pipeline(createReadStream(path), child.stdin, { signal });
      } else {
        child.stdin.end();
        await pipeline(
          child.stdout,
          createWriteStream(path, { flags: 'wx', mode: 0o600 }),
          { signal },
        );
      }
      if ((await exit) !== 0)
        throw Error(detail || 'Snapshot transfer command failed');
    } catch (error) {
      child.kill();
      await exit.catch(() => {});
      throw error;
    }
  });
export const launchImpl = (config) =>
  async(async () => {
    const server = await cluster.start(JSON.parse(config));
    return { address: server.address, server };
  });
export const waitImpl = (server) => async(() => server.closed);
export const stopImpl = (server) => async(() => server.stop());
