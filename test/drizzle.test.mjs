import { test, expect } from 'bun:test';
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  symlinkSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { usable } from '../output/Sbx.Tools.Drizzle/index.js';
import { promise } from './support/aff.mjs';

test('Drizzle checks drivers beside the real Kit installation, including PATH symlinks', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'sbx-drizzle-resolve-'));
  const entry = join(directory, 'global/node_modules/drizzle-kit/bin.cjs');
  const driver = join(directory, 'global/node_modules/@libsql/client');
  mkdirSync(join(directory, 'global/node_modules/drizzle-kit'), {
    recursive: true,
  });
  writeFileSync(entry, '// Kit fixture');
  mkdirSync(join(directory, 'global/node_modules/drizzle-orm'), {
    recursive: true,
  });
  writeFileSync(
    join(directory, 'global/node_modules/drizzle-orm/index.js'),
    'module.exports={};',
  );
  const executable = join(directory, 'drizzle-kit');
  symlinkSync(entry, executable);
  const kit = { cmd: executable, args: [], where: executable };
  try {
    // The repository has @libsql/client, but this separate global Kit does not.
    expect(await promise(usable(kit)('@libsql/client'))).toBe(false);
    mkdirSync(driver, { recursive: true });
    writeFileSync(
      join(driver, 'index.js'),
      'module.exports={createClient(){}};',
    );
    expect(await promise(usable(kit)('@libsql/client'))).toBe(true);
    expect(await promise(usable(kit)('pg'))).toBe(false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
