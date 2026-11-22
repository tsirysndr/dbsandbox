import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import cluster from '../packages/cluster/index.cjs';
import { storeFixture } from './fixtures/cluster-store.mjs';

const token = 'cluster-test-token-with-at-least-32-characters';
const apiToken = 'api-test-token-with-at-least-32-characters';
async function port() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}
for (const backend of ['consul', 'etcd']) {
  test(
    `${backend}: live join, remote snapshots, late joins, independent children and owner recovery`,
    { timeout: 30000 },
    async (t) => {
      const external =
        process.env[`DBSANDBOX_TEST_${backend.toUpperCase()}_URL`];
      const store = external
        ? { endpoint: external, close: async () => {} }
        : await storeFixture(backend);
      const nodes = [];
      const directory = await mkdtemp(
        join(tmpdir(), 'dbsandbox-cluster-test-'),
      );
      t.after(async () => {
        try {
          await Promise.all(nodes.map((node) => node.stop()));
        } finally {
          await store.close();
          await rm(directory, { recursive: true, force: true });
        }
      });
      const namespace = `test-${Date.now()}-${Math.random().toString(36).slice(2)}`;
      const config = async (node) => {
        const listen = `127.0.0.1:${await port()}`;
        return {
          backend,
          endpoint: store.endpoint,
          node_id: node,
          namespace,
          token,
          api_token: apiToken,
          listen,
          advertise: `http://${listen}`,
          executable: process.execPath,
          executable_args: [
            fileURLToPath(
              new URL('./fixtures/cluster-command.cjs', import.meta.url),
            ),
            join(directory, `${node}.json`),
            node,
          ],
        };
      };
      const a = await config('a'),
        b = await config('b');
      const first = await cluster.start(a);
      nodes.push(first);
      const second = await cluster.start({ ...b, join: a.advertise });
      nodes.push(second);
      if (external) await new Promise((resolve) => setTimeout(resolve, 17000));
      const request = (node, path, method = 'GET', body, auth = apiToken) =>
        fetch(`${node.advertise}${path}`, {
          method,
          headers: {
            Authorization: `Bearer ${auth}`,
            'Content-Type': 'application/json',
          },
          ...(body ? { body: JSON.stringify(body) } : {}),
        });
      assert.equal(
        (await request(a, '/v1/databases', 'GET', undefined, 'bad')).status,
        401,
      );
      assert.equal(
        (await request(a, '/v1/databases', 'GET', undefined, token)).status,
        401,
      );
      assert.equal(
        (await request(a, '/v1/cluster/join', 'POST', {}, apiToken)).status,
        401,
      );
      await assert.rejects(
        cluster.start({ ...a, listen: `127.0.0.1:${await port()}` }),
        /already registered/,
      );
      const starts = await Promise.all([
        request(a, '/v1/databases/postgres/start', 'POST'),
        request(b, '/v1/databases/postgres/start', 'POST'),
      ]);
      const outputs = await Promise.all(
        starts.map(async (response) => {
          assert.equal(response.status, 200);
          return (await response.json()).output.trim();
        }),
      );
      assert.equal(outputs[0], outputs[1]);
      const owner = outputs[0];
      assert.equal(owner, 'a');
      // With the parent on A, the child is scheduled onto B.
      const fork = await request(a, '/v1/databases/postgres/branches', 'POST', {
        name: 'feature',
        from: 'main',
      });
      assert.equal(fork.status, 200, await fork.clone().text());
      assert.equal((await fork.json()).output, 'b');
      const gateway = await config('c');
      const late = await cluster.start({ ...gateway, join: b.advertise });
      nodes.push(late);
      const preview = await request(
        a,
        '/v1/databases/postgres/branches',
        'POST',
        { name: 'preview', from: 'feature' },
      );
      assert.equal(preview.status, 200, await preview.clone().text());
      assert.equal((await preview.json()).output, 'c');
      let rows = await (
        await request(gateway, '/v1/databases/postgres/branches')
      ).json();
      assert.deepEqual(
        rows.map((row) => row.branch),
        ['feature', 'main', 'preview'],
      );
      assert.ok(rows.every((row) => row.data === 'a/postgres/seed'));
      assert.ok(rows.every((row) => row.phase === 'ready'));
      // A child stays usable after the original parent/seed goes offline.
      await first.stop();
      assert.equal(
        (await request(gateway, '/v1/databases/postgres/start', 'POST')).status,
        503,
      );
      assert.equal(
        (
          await request(
            gateway,
            '/v1/databases/postgres/branches/preview/stop',
            'POST',
          )
        ).status,
        200,
      );
      assert.equal(
        (
          await request(
            gateway,
            '/v1/databases/postgres/branches/preview/start',
            'POST',
          )
        ).status,
        200,
      );
      const restored = await cluster.start(a);
      nodes.push(restored);
      const restarted = await request(
        gateway,
        '/v1/databases/postgres/start',
        'POST',
      );
      assert.equal(restarted.status, 200);
      assert.equal((await restarted.json()).output, owner);
      assert.equal(
        (
          await request(
            gateway,
            '/v1/databases/postgres/branches/preview',
            'DELETE',
          )
        ).status,
        200,
      );
      // Reject corrupt transfers without publishing an empty ready branch.
      await writeFile(join(directory, 'a.json.corrupt'), '1');
      const broken = await request(
        gateway,
        '/v1/databases/postgres/branches',
        'POST',
        { name: 'broken', from: 'main' },
      );
      assert.equal(broken.status, 503);
      rows = await (
        await request(gateway, '/v1/databases/postgres/branches')
      ).json();
      assert.equal(rows.find((row) => row.branch === 'broken').phase, 'failed');
      assert.equal(
        (
          await request(
            gateway,
            '/v1/databases/postgres/branches/broken/start',
            'POST',
          )
        ).status,
        503,
      );
      await rm(join(directory, 'a.json.corrupt'));
      assert.equal(
        (
          await request(
            gateway,
            '/v1/databases/postgres/branches/broken',
            'DELETE',
          )
        ).status,
        200,
      );
      const recreated = await request(
        gateway,
        '/v1/databases/postgres/branches',
        'POST',
        { name: 'broken', from: 'main' },
      );
      assert.equal(recreated.status, 200);
      await restored.stop();
    },
  );
  test(
    `${backend}: membership loss shuts down the API and rejects closed`,
    { timeout: 15000 },
    async (t) => {
      const store = await storeFixture(backend);
      t.after(() => store.close());
      const listen = `127.0.0.1:${await port()}`;
      const running = await cluster.start({
        backend,
        endpoint: store.endpoint,
        node_id: 'lease-test',
        namespace: 'lease-test',
        token,
        api_token: apiToken,
        listen,
        advertise: `http://${listen}`,
        executable: process.execPath,
      });
      await new Promise((resolve) => setTimeout(resolve, 100));
      store.failRenew();
      await assert.rejects(running.closed, /membership lost/);
      await assert.rejects(running.stop(), /membership lost/);
      await assert.rejects(fetch(`http://${listen}/healthz`));
    },
  );
}

test(
  'PureScript server generates and prints separate tokens, and honors environment overrides',
  { timeout: 20000 },
  async (t) => {
    const store = await storeFixture('etcd');
    const directory = await mkdtemp(join(tmpdir(), 'dbsandbox-auth-test-'));
    const children = [];
    t.after(async () => {
      for (const child of children) {
        if (child.exitCode === null) {
          child.kill('SIGTERM');
          await child.closed;
        }
      }
      await store.close();
      await rm(directory, { recursive: true, force: true });
    });
    const launch = async (environment = {}) => {
      const listen = `127.0.0.1:${await port()}`;
      const file = join(directory, `config-${children.length}.json`);
      await writeFile(
        file,
        JSON.stringify({
          node_id: `auth-${children.length}`,
          namespace: 'auth-test',
          listen,
          advertise: `http://${listen}`,
          backend: 'etcd',
          endpoint: store.endpoint,
        }),
      );
      const env = { ...process.env, ...environment };
      if (!environment.DBSANDBOX_CLUSTER_TOKEN)
        delete env.DBSANDBOX_CLUSTER_TOKEN;
      if (!environment.DBSANDBOX_API_TOKEN) delete env.DBSANDBOX_API_TOKEN;
      const child = spawn(
        process.env.DBSANDBOX_TEST_BINARY || process.execPath,
        [
          ...(process.env.DBSANDBOX_TEST_BINARY ? [] : ['bin/dbsandbox.js']),
          'cluster',
          'serve',
          '--config',
          file,
        ],
        { env, stdio: ['ignore', 'pipe', 'pipe'] },
      );
      child.closed = new Promise((resolve) => child.once('close', resolve));
      children.push(child);
      let output = '';
      child.stdout.on('data', (chunk) => (output += chunk));
      child.stderr.on('data', (chunk) => (output += chunk));
      for (let attempt = 0; attempt < 100; attempt++) {
        if (
          output.includes('listening on') &&
          (environment.DBSANDBOX_API_TOKEN ||
            /API auth token: [0-9a-f]{64}/.test(output))
        )
          return { child, output, url: `http://${listen}`, file };
        if (child.exitCode !== null) throw Error(output);
        await new Promise((resolve) => setTimeout(resolve, 30));
      }
      throw Error(output || 'Server startup timed out');
    };
    const generated = await launch();
    const clusterToken = generated.output.match(
      /Cluster auth token: ([0-9a-f]{64})/,
    )[1];
    const publicToken = generated.output.match(
      /API auth token: ([0-9a-f]{64})/,
    )[1];
    assert.notEqual(clusterToken, publicToken);
    const request = (url, path, key, method = 'GET') =>
      fetch(url + path, {
        method,
        headers: { Authorization: `Bearer ${key}` },
      });
    assert.equal(
      (await request(generated.url, '/healthz', publicToken)).status,
      200,
    );
    assert.equal(
      (await request(generated.url, '/healthz', clusterToken)).status,
      401,
    );
    assert.equal(
      (await request(generated.url, '/internal/execute', publicToken, 'POST'))
        .status,
      401,
    );
    generated.child.kill('SIGTERM');
    assert.equal(await generated.child.closed, 0);
    const configured = await launch({
      DBSANDBOX_CLUSTER_TOKEN: token,
      DBSANDBOX_API_TOKEN: apiToken,
    });
    assert.doesNotMatch(configured.output, /auth token:/);
    assert.equal(
      (await request(configured.url, '/healthz', apiToken)).status,
      200,
    );
    assert.equal(
      (await request(configured.url, '/healthz', publicToken)).status,
      401,
    );
    const env = { ...process.env };
    delete env.DBSANDBOX_CLUSTER_TOKEN;
    delete env.DBSANDBOX_API_TOKEN;
    const rejected = spawnSync(
      process.env.DBSANDBOX_TEST_BINARY || process.execPath,
      [
        ...(process.env.DBSANDBOX_TEST_BINARY ? [] : ['bin/dbsandbox.js']),
        'cluster',
        'join',
        '--server',
        configured.url,
        '--config',
        configured.file,
      ],
      { env, encoding: 'utf8', timeout: 5000 },
    );
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /DBSANDBOX_CLUSTER_TOKEN/);
  },
);
