'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { detect, binaryPath } = require('./platform.js');
const { version } = require('../package.json');

async function download(url) {
  let failure;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await fetch(url, {
        redirect: 'follow',
        signal: AbortSignal.timeout(180000),
      });
      if (!response.ok)
        throw Error(`HTTP ${response.status} downloading ${url}`);
      return Buffer.from(await response.arrayBuffer());
    } catch (error) {
      failure = error;
    }
  }
  throw failure;
}

function checksum(manifest, asset) {
  const entries = manifest
    .split(/\r?\n/)
    .map((line) => line.match(/^([a-fA-F0-9]{64})\s+\*?(.+)$/))
    .filter((match) => match && match[2] === asset);
  if (entries.length !== 1)
    throw Error(
      `SHA256SUMS must contain exactly one valid checksum for ${asset}`,
    );
  return entries[0][1].toLowerCase();
}

async function install() {
  const { asset } = detect();
  if (process.env.DBSANDBOX_SKIP_DOWNLOAD === '1') return;
  const dest = binaryPath();
  if (fs.existsSync(dest) && !process.env.DBSANDBOX_BINARY) return;
  const directory = path.dirname(dest);
  fs.mkdirSync(directory, { recursive: true });
  const staging = fs.mkdtempSync(path.join(directory, '.install-'));
  try {
    const candidate = path.join(staging, 'dbsandbox');
    if (process.env.DBSANDBOX_BINARY) {
      fs.copyFileSync(process.env.DBSANDBOX_BINARY, candidate);
    } else {
      const base = (
        process.env.DBSANDBOX_DOWNLOAD_BASE ||
        `https://github.com/tsirysndr/dbsandbox/releases/download/v${version}`
      ).replace(/\/$/, '');
      console.error(`[dbsandbox] downloading v${version} (${asset})`);
      const archive = await download(`${base}/${asset}`);
      const expected = checksum(
        (await download(`${base}/SHA256SUMS`)).toString('utf8'),
        asset,
      );
      if (createHash('sha256').update(archive).digest('hex') !== expected)
        throw Error(`Checksum mismatch for ${asset}`);
      const file = path.join(staging, asset);
      fs.writeFileSync(file, archive);
      execFileSync('tar', ['-xzf', file, '-C', staging, 'dbsandbox'], {
        stdio: ['ignore', 'ignore', 'pipe'],
      });
    }
    if (
      !fs.lstatSync(candidate).isFile() ||
      fs.lstatSync(candidate).isSymbolicLink()
    )
      throw Error(
        'Release archive must contain a regular dbsandbox executable',
      );
    fs.chmodSync(candidate, 0o755);
    fs.renameSync(candidate, dest);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

if (require.main === module)
  install().catch((error) => {
    console.error(
      `[dbsandbox] ${error.message}\nThe matching GitHub release v${version} must contain the platform archive and SHA256SUMS.`,
    );
    process.exitCode = 1;
  });
module.exports = { install, checksum };
