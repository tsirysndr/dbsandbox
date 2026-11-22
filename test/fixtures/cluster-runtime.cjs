// Minimal bsdkrun protocol fixture for the real PureScript snapshot executor.
const fs = require('node:fs');
const args = process.argv.slice(2);
if (args[0] === '--log-level') args.splice(0, 2);
const path = process.env.CLUSTER_RUNTIME_STATE;
const runtime = JSON.parse(fs.readFileSync(path, 'utf8'));
const persist = () => fs.writeFileSync(path, JSON.stringify(runtime));
const out = (value) => console.log(JSON.stringify(value));
const attachment = (name) => [
  {
    machine: 'engine',
    machine_name: 'bsdkrun-docker',
    running: true,
    mounts: [{ branch: 'main', mountpoint: `/mnt/${name}-main` }],
  },
];
fs.appendFileSync(process.env.CLUSTER_RUNTIME_LOG, JSON.stringify(args) + '\n');
if (args[0] === 'docker' && args[1] === 'status')
  out({
    running: runtime.running,
    machine_id: 'engine',
    socket: '/fixture/docker.sock',
  });
else if (args[0] === 'docker' && args[1] === 'ps')
  out(
    runtime.volumes.map((volume) => ({ name: volume.name, state: 'running' })),
  );
else if (args[0] === 'docker' && ['start', 'stop'].includes(args[1])) {
  runtime.running = args[1] === 'start';
  persist();
} else if (args[0] === 'ps')
  out([{ id: 'engine', name: 'bsdkrun-docker', running: runtime.running }]);
else if (args[0] === 'zfs' && args[1] === 'ls') out(runtime.volumes);
else if (args[0] === 'zfs' && args[1] === 'create') {
  runtime.volumes.push({
    name: args[2],
    size_bytes: 1073741824,
    branches: [{ name: 'main' }],
    attached_to: [],
  });
  persist();
} else if (args[0] === 'zfs' && args[1] === 'branch') {
  runtime.volumes
    .find((volume) => volume.name === args[2])
    .branches.push({ name: args[3] });
  persist();
} else if (args[0] === 'zfs' && args[1] === 'attach') {
  const name = args[2].split('@')[0];
  runtime.volumes.find((volume) => volume.name === name).attached_to =
    attachment(name);
  persist();
} else if (args[0] === 'exec' && args[2] === 'zfs' && args[3] === 'send')
  process.stdout.write(
    Buffer.from(process.env.CLUSTER_SNAPSHOT_BYTES, 'base64'),
  );
else if (args[0] === 'exec' && args[2] === 'zfs' && args[3] === 'receive') {
  const chunks = [];
  process.stdin.on('data', (chunk) => chunks.push(chunk));
  process.stdin.on('end', () =>
    fs.writeFileSync(process.env.CLUSTER_RECEIVED_BYTES, Buffer.concat(chunks)),
  );
} else if (
  args[0] === 'exec' &&
  args[2] === 'zfs' &&
  ['snapshot', 'destroy'].includes(args[3])
) {
} else if (args[0] === 'exec' && args[2] === 'sh') {
  if (args.at(-1).includes('ip_local_port_range'))
    console.log('32768 60999\n sl local_address rem_address st');
} else if (args[0] === '--version') console.log('bsdkrun 0.12.2');
else {
  console.error('Unexpected cluster runtime command', args);
  process.exitCode = 2;
}
