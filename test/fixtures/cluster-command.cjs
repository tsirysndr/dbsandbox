// Test runtime: real cluster routing and snapshot transfers, without creating VMs.
const fs = require('node:fs');
const { createHash } = require('node:crypto');
const [file, node, , json] = process.argv.slice(2);
const payload = JSON.parse(json),
  record = payload.record;
const rows = fs.existsSync(file)
  ? JSON.parse(fs.readFileSync(file, 'utf8'))
  : {};
let result = { ok: true, branch: record.name, output: node };
switch (payload.action) {
  case 'start':
    rows[record.id] ??= {
      database: record.database,
      branch: record.name,
      data: `${node}/${record.database}/seed`,
      running: true,
    };
    rows[record.id].running = true;
    break;
  case 'stop':
    rows[record.id].running = false;
    break;
  case 'delete':
    delete rows[record.id];
    break;
  case 'inventory':
    result = rows[record.id];
    if (!result) throw Error('runtime missing');
    result = { ...result, status: result.running ? 'RUNNING' : 'STOPPED' };
    break;
  case 'export': {
    const bytes = Buffer.from(JSON.stringify(rows[record.id]));
    fs.writeFileSync(payload.path, bytes);
    result = {
      state: { fixture: true },
      sha256: fs.existsSync(`${file}.corrupt`)
        ? '0'.repeat(64)
        : createHash('sha256').update(bytes).digest('hex'),
    };
    break;
  }
  case 'import': {
    rows[record.id] = {
      ...JSON.parse(fs.readFileSync(payload.path, 'utf8')),
      database: record.database,
      branch: record.name,
      running: true,
    };
    break;
  }
  default:
    throw Error('unknown fixture action');
}
fs.writeFileSync(file, JSON.stringify(rows));
console.log(JSON.stringify(result));
