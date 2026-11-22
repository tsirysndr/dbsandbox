import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
const result = spawnSync(
  'cargo',
  ['build', '--release', '--locked', '-p', 'dbsandbox-cluster-neon'],
  { cwd: root, stdio: 'inherit' },
);
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
const library =
  process.platform === 'darwin'
    ? 'libdbsandbox_cluster_neon.dylib'
    : process.platform === 'win32'
      ? 'dbsandbox_cluster_neon.dll'
      : 'libdbsandbox_cluster_neon.so';
const target = process.env.CARGO_BUILD_TARGET;
const dir = process.env.CARGO_TARGET_DIR || join(root, 'target');
mkdirSync(join(root, 'packages/cluster'), { recursive: true });
copyFileSync(
  join(dir, ...(target ? [target] : []), 'release', library),
  join(root, 'packages/cluster/native.node'),
);
