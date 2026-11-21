// Before the first PureScript build: apply the setup module's typed environment
// to the install and export children. The compiled CI code validates and exports
// it to GitHub before this bootstrap exits. No release/test policy here.
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const output = readFileSync(process.argv[2], 'utf8');
process.stdout.write(output);
const lines = output.trimEnd().split('\n');
let result;
for (let i = 0; i < lines.length; i++) {
  try { result = JSON.parse(lines.slice(i).join('\n')); break; } catch {}
}
if (!Array.isArray(result?.environment) || !result.environment.length) throw Error('Missing setup environment');
const environment = Object.fromEntries(result.environment.map(({ name, value }) => {
  if (typeof name !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || typeof value !== 'string' || value.includes('\0')) throw Error('Invalid setup environment');
  return [name, value];
}));
const options = { env: { ...process.env, ...environment }, stdio: 'inherit' };
const install = spawnSync('bun', ['install', '--frozen-lockfile'], options);
if (install.error) throw install.error;
if (install.status !== 0) {
  process.exitCode = install.status ?? 1;
} else {
  // Actions has not applied GITHUB_ENV yet: use the managed PATH for this child too.
  const exported = spawnSync('bun', ['bin/ci.js', 'export-env', process.argv[2]], options);
  if (exported.error) throw exported.error;
  process.exitCode = exported.status ?? 1;
}
