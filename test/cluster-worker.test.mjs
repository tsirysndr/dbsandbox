import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

test('PureScript snapshot executor preserves binary data, source settings and isolated resource identities', () => {
  const runtimeExecutable = process.versions.bun ? process.execPath : 'bun';
  const directory = mkdtempSync(join(tmpdir(), 'sbx-cluster-worker-'));
  const source = {
    id: randomUUID(),
    database: 'postgres',
    name: 'main',
    phase: 'ready',
  };
  const target = {
    id: randomUUID(),
    database: 'postgres',
    name: 'feature',
    phase: 'creating',
  };
  const tool = (record) => `sbx-${record.id.replaceAll('-', '')}`;
  const bytes = Buffer.from([0, 255, 128, 1, 2, 3, 10, 13, 0, 254]);
  const runtime = join(directory, 'runtime.json'),
    log = join(directory, 'calls'),
    snapshot = join(directory, 'snapshot'),
    received = join(directory, 'received');
  const binary = join(directory, 'bsdkrun');
  writeFileSync(
    binary,
    `#!${process.execPath}\n${readFileSync('test/fixtures/cluster-runtime.cjs', 'utf8')}`,
    { mode: 0o755 },
  );
  writeFileSync(
    runtime,
    JSON.stringify({
      running: true,
      volumes: [
        {
          name: tool(source),
          size_bytes: 1073741824,
          branches: [{ name: 'main' }],
          attached_to: [
            {
              machine: 'engine',
              machine_name: 'bsdkrun-docker',
              running: true,
              mounts: [
                { branch: 'main', mountpoint: `/mnt/${tool(source)}-main` },
              ],
            },
          ],
        },
      ],
    }),
  );
  const env = {
    ...process.env,
    XDG_CONFIG_HOME: join(directory, 'config'),
    BSDKRUN_BIN: binary,
    BSDKRUN_NO_AUTO_INSTALL: '1',
    CLUSTER_RUNTIME_STATE: runtime,
    CLUSTER_RUNTIME_LOG: log,
    CLUSTER_SNAPSHOT_BYTES: bytes.toString('base64'),
    CLUSTER_RECEIVED_BYTES: received,
  };
  const module = pathToFileURL(
    join(process.cwd(), 'output/Sbx.State/index.js'),
  ).href;
  const profiles = pathToFileURL(
    join(process.cwd(), 'output/Sbx.Database.Profiles/index.js'),
  ).href;
  const state = {
    os: 'linux',
    version: '18',
    port: 15432,
    user: 'snapshot-user',
    password: 'snapshot-secret',
    db: 'original',
    branch: 'main',
    cpus: 2,
    mem: 1024,
  };
  const setup = `import * as State from ${JSON.stringify(module)};import {all} from ${JSON.stringify(profiles)};const p={...all.find(p=>p.name==='postgres').profile,tool:${JSON.stringify(tool(source))}};State.saveFor(p)(${JSON.stringify(state)})();`;
  try {
    const seeded = spawnSync(runtimeExecutable, ['-e', setup], {
      env,
      encoding: 'utf8',
    });
    assert.equal(seeded.status, 0, seeded.stderr);
    const run = (payload) =>
      spawnSync(
        process.env.DBSANDBOX_TEST_BINARY || runtimeExecutable,
        [
          ...(process.env.DBSANDBOX_TEST_BINARY ? [] : ['bin/dbsandbox.js']),
          '__cluster-worker',
          JSON.stringify(payload),
        ],
        { env, encoding: 'utf8', timeout: 10000 },
      );
    const exported = run({ action: 'export', record: source, path: snapshot });
    assert.equal(exported.status, 0, exported.stderr);
    const metadata = JSON.parse(exported.stdout);
    assert.equal(
      metadata.sha256,
      createHash('sha256').update(bytes).digest('hex'),
    );
    assert.deepEqual(readFileSync(snapshot), bytes);
    assert.deepEqual(metadata.state.runtime, state);
    const imported = run({
      action: 'import',
      record: target,
      path: snapshot,
      state: metadata.state,
    });
    assert.equal(imported.status, 0, imported.stderr);
    assert.deepEqual(readFileSync(received), bytes);
    const inspect = `import * as State from ${JSON.stringify(module)};console.log(JSON.stringify(State.load(${JSON.stringify(tool(target))})().value0));`;
    const saved = spawnSync(runtimeExecutable, ['-e', inspect], {
      env,
      encoding: 'utf8',
    });
    assert.equal(saved.status, 0, saved.stderr);
    const restored = JSON.parse(saved.stdout);
    assert.equal(restored.password, state.password);
    assert.equal(restored.version, state.version);
    assert.equal(restored.user, state.user);
    assert.equal(restored.db, state.db);
    assert.notEqual(restored.port, state.port);
    const calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
    assert.ok(calls.some((args) => args[3] === 'send'));
    assert.ok(
      calls.some((args) => args[3] === 'receive' && !args.includes('-F')),
    );
    assert.ok(
      calls.some((args) => args[1] === 'create' && args[2] === tool(target)),
    );
    const missing = run({
      action: 'start',
      record: {
        id: randomUUID(),
        database: 'postgres',
        name: 'lost',
        phase: 'ready',
      },
    });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /storage is missing/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
