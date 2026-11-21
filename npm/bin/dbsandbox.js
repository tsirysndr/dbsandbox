#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const { constants } = require('node:os');
const { binaryPath } = require('../scripts/platform.js');

async function main() {
  const binary = binaryPath();
  if (!fs.existsSync(binary))
    await require('../scripts/postinstall.js').install();
  if (!fs.existsSync(binary))
    throw Error(
      'Native binary is missing. Unset DBSANDBOX_SKIP_DOWNLOAD and run dbsandbox again.',
    );
  const env = { ...process.env };
  // Nested npm dependencies are not necessarily on PATH for a global install.
  if (!env.BSDKRUN_BIN)
    env.BSDKRUN_BIN = require.resolve('@bsdkrun/cli/bin/bsdkrun.js');
  const child = spawn(binary, process.argv.slice(2), { env, stdio: 'inherit' });
  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP'];
  const handlers = signals.map((signal) => {
    const handler = () => child.kill(signal);
    process.on(signal, handler);
    return [signal, handler];
  });
  const cleanup = () => {
    for (const [signal, handler] of handlers) process.off(signal, handler);
  };
  child.on('error', (error) => {
    cleanup();
    console.error(`[dbsandbox] ${error.message}`);
    process.exitCode = 1;
  });
  child.on('close', (code, signal) => {
    cleanup();
    process.exitCode =
      code != null && code >= 0
        ? code
        : signal
          ? 128 + (constants.signals[signal] || 0)
          : 1;
  });
}
main().catch((error) => {
  console.error(`[dbsandbox] ${error.message}`);
  process.exitCode = 1;
});
