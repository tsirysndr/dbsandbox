import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

test('DuckDB promotes old data branches and checkout creates/selects independent servers without stopping main', () => {
  const directory = mkdtempSync(join(tmpdir(), 'sbx-duckdb-parallel-'));
  const binary = join(directory, 'bsdkrun'),
    runtime = join(directory, 'runtime.json'),
    log = join(directory, 'calls');
  const executable = process.versions.bun ? process.execPath : 'bun';
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
          name: 'duckdb-sbx',
          size_bytes: 1073741824,
          branches: [{ name: 'main' }, { name: 'dev' }, { name: 'dev2' }],
          attached_to: [
            {
              machine: 'engine',
              machine_name: 'bsdkrun-docker',
              running: true,
              mounts: [{ branch: 'main', mountpoint: '/mnt/duckdb-sbx-main' }],
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
  };
  const module = (name) =>
    JSON.stringify(
      pathToFileURL(join(process.cwd(), 'output', name, 'index.js')).href,
    );
  const script = `
 import {profile} from ${module('Sbx.Database.DuckDB')};
 import {run,emptyStart} from ${module('Sbx.Branch.Manager')};
 import {OnBranch,Start,Checkout} from ${module('Sbx.Cli')};
 import * as State from ${module('Sbx.State')};
 import * as Store from ${module('Sbx.State.Store')};
 import {runAff_,applicativeAff} from ${module('Effect.Aff')};
 import {Left} from ${module('Data.Either')};
 const aff=action=>new Promise((resolve,reject)=>runAff_(r=>()=>r instanceof Left?reject(r.value0):resolve(r.value0))(action)());
 State.saveFor(profile)({os:'linux',version:'2.0.0',port:9494,user:'',password:'source-secret',db:'duckdb',branch:'main',cpus:2,mem:1024})();
 const calls=[],base=p=>command=>{calls.push({tool:p.tool,command:command.constructor.name});return applicativeAff.pure(0);};
 await aff(run(base)(profile)(new OnBranch('dev',new Start(emptyStart))));
 await aff(run(base)(profile)(new OnBranch('dev2',new Start(emptyStart))));
 await aff(run(base)(profile)(new Checkout({name:'dev',create:false})));
 await aff(run(base)(profile)(new Checkout({name:'main',create:false})));
 await aff(run(base)(profile)(new Checkout({name:'fresh',create:true})));
 const entries=Store.entries(profile.tool)();
 console.log('RESULT:'+JSON.stringify({calls,entries,parent:State.load(profile.tool)().value0,children:entries.map(e=>State.load(e.tool)().value0),selected:Store.active(profile.tool)().value0}));
 `;
  try {
    const result = spawnSync(executable, ['-e', script], {
      env,
      encoding: 'utf8',
      timeout: 15000,
    });
    assert.equal(result.status, 0, result.stderr);
    const value = JSON.parse(result.stdout.split('RESULT:')[1]);
    assert.equal(value.parent.branch, 'main');
    assert.equal(value.parent.port, 9494);
    assert.deepEqual(value.entries.map((row) => row.name).sort(), [
      'dev',
      'dev2',
      'fresh',
    ]);
    assert.ok(value.entries.every((row) => row.running));
    assert.equal(new Set(value.children.map((row) => row.port)).size, 3);
    assert.ok(
      value.children.every((row) => row.port > 9494 && row.port <= 65535),
    );
    assert.ok(value.children.every((row) => row.password === 'source-secret'));
    assert.equal(value.selected, 'fresh');
    assert.equal(value.calls.length, 3);
    assert.ok(
      value.calls.every(
        (call) => call.command === 'Start' && call.tool !== 'duckdb-sbx',
      ),
    );
    const calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
    assert.ok(
      !calls.some((args) => args[0] === 'docker' && args[1] === 'stop'),
    );
    assert.equal(
      calls.filter((args) => args[0] === 'zfs' && args[1] === 'branch').length,
      1,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
