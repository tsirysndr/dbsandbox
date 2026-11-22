# dbsandbox cluster

A Rust/Neon coordinator embedded in the existing `dbsandbox` executable. Tokio
and Axum provide the unified management API; PureScript implements command parsing,
configuration, branch runtime management and ZFS snapshot operations. JavaScript
provides the native-addon wrapper and filesystem/process stream FFI.

See [the architecture diagrams](../../docs/cluster-architecture.md).

## Build

```sh
bun run build
bun run build:bin
```

The native module always builds with `cargo build --release --locked` before Bun
compiles the executable. Release jobs use matching native OS/architecture runners.
The Nix flake uses Crane to cache Rust dependencies and build the addon, and exposes
Cargo, rustc, rustfmt and Clippy in the development shell.

## Configure and start

Run an external Consul or etcd cluster. Every node uses the same backend and
namespace. Example `node-a.json`:

```json
{
  "node_id": "node-a",
  "listen": "0.0.0.0:8788",
  "advertise": "http://10.0.0.10:8788",
  "backend": "consul",
  "endpoint": "http://127.0.0.1:8500",
  "namespace": "development"
}
```

For etcd, use `"backend": "etcd"` and `"endpoint": "http://127.0.0.1:2379"`.
The adapters use Consul's HTTP KV/session APIs or etcd's v3 JSON gateway.

```sh
dbsandbox cluster serve --config node-a.json
```

When no tokens are configured, `serve` generates two independent 32-byte random
tokens and prints their hexadecimal values in the terminal. Keep the printed
values to use with clients and joining nodes. To retain tokens across restarts,
set the environment variables explicitly:

```sh
export DBSANDBOX_CLUSTER_TOKEN='the-cluster-token-printed-by-the-server'
export DBSANDBOX_API_TOKEN='the-api-token-printed-by-the-server'
# Optional backend credential: Consul ACL token or etcd gateway auth token.
# export DBSANDBOX_STORE_TOKEN='...'

dbsandbox cluster join --server http://10.0.0.10:8788 --config node-b.json
```

`node-b.json` must have a unique `node_id` and a reachable `advertise` origin.
Joining requires both shared tokens. A node can join through any live node at any
time, without restarting existing nodes. The seed has no permanent leadership
role. New nodes become candidates for new branches immediately.

Config fields `token`, `api_token` and `store_token` are alternatives to environment
variables; environment values take precedence. Tokens must be at least 32
characters. Generated tokens are printed only by `serve`; configured secrets are
not echoed. HTTP is the native listener protocol: use HTTPS via a proxy or a
trusted private network for cross-host traffic.

## API

Use the **API token** for remote management. The **cluster token** authorizes
joining, internal execution and snapshot transfer. API tokens cannot access
internal routes; cluster tokens cannot access management routes.

```sh
curl -X POST http://10.0.0.10:8788/v1/databases/postgres/start \
  -H "Authorization: Bearer $DBSANDBOX_API_TOKEN"
curl -X POST http://10.0.0.10:8788/v1/databases/postgres/branches \
  -H "Authorization: Bearer $DBSANDBOX_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"feature","from":"main"}'
```

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/healthz` | Readiness and membership |
| GET | `/v1/databases` | Inventory across all branch placements |
| POST | `/v1/databases/postgres/start` | Create/start `postgres/main` |
| POST | `/v1/databases/postgres/stop` | Stop `postgres/main` |
| GET | `/v1/databases/postgres/branches` | All branch inventory, including unavailable/failed branches |
| POST | `/v1/databases/postgres/branches` | Fork with `{"name":"feature","from":"main"}` |
| DELETE | `/v1/databases/postgres/branches/feature` | Delete a branch and its isolated data volume |
| POST | `/v1/databases/postgres/branches/feature/start` | Start a branch |
| POST | `/v1/databases/postgres/branches/feature/stop` | Stop a branch |

Database names are canonical dbsandbox engine names. Every API node accepts the
same routes and forwards internally to the appropriate branch owner.

## Horizontal branch scaling

Placement is per `(database, branch)`. Each branch has its own runtime, ZFS volume,
resource identity and port. Branches of the same database can run on different
nodes. A destination node receives an immutable ZFS snapshot from its parent,
checks the byte count and SHA-256, imports it into a fresh volume, restores runtime
settings/credentials and starts an independent server. A nested branch can use any
existing ready branch as its parent.

Scheduling prefers nodes with fewer assigned branches and avoids the parent on
otherwise equal candidates. Consul CAS or etcd transactions reserve ownership and
update `creating`, `ready`, `failed` and `deleting` lifecycle records. Parent IDs
prevent a deleted/recreated source name from silently changing a pending fork's
ancestry. Credentials and snapshot bytes are never written to the shared backend.

Membership uses 15-second leases, renewed every 4 seconds. Membership loss stops
the node's API and cancels its commands. Placement remains durable. A child branch
continues serving independently if its parent node stops. Offline owners are never
automatically replaced with empty storage. Recover their original local data and
restart with the same stable identity. A ready branch with missing local state or
volume is refused rather than initialized empty.

Snapshot files are temporary, released after transfer or expired after one hour.
The receive command never uses `-F`. A partially received volume must be removed
by deleting the failed branch before recreating it. Interrupted exports can leave
an unused `@dbsandbox-*` ZFS snapshot on the source; inspect these after forced
process termination. Mutations are not retried automatically.

Current cross-node transfer supports Linux branch runtimes on the same guest CPU
architecture. It transfers a full filesystem snapshot and is crash-consistent;
this is not database replication, sharding, application-level backup, incremental
shipping or automatic storage failover. Transfers require temporary disk space on
both endpoints and bandwidth proportional to snapshot size. Creating a new local
volume may restart that node's shared engine to attach its disk; existing
containers restart with the engine. SQL/Quack connection URLs keep the existing
local port-forwarding semantics; this API manages branches and does not proxy SQL
traffic. Existing standalone sandboxes are not automatically adopted by the
cluster's isolated branch resource namespace.

## Node.js API

```js
const { start } = require('./packages/cluster');
const node = await start({
  node_id: 'node-a', listen: '127.0.0.1:8788',
  advertise: 'http://127.0.0.1:8788',
  backend: 'etcd', endpoint: 'http://127.0.0.1:2379',
  namespace: 'development',
  token: process.env.DBSANDBOX_CLUSTER_TOKEN,
  api_token: process.env.DBSANDBOX_API_TOKEN,
  executable: '/absolute/path/to/dbsandbox'
});
// Resolves on shutdown, rejects on API/membership failure.
node.closed.catch(console.error);
await node.stop();
```

The addon works from Node.js. Use the compiled executable for workers, or specify
Bun as `executable` with `executable_args: ['/absolute/path/to/bin/dbsandbox.js']`:
the existing local state store uses Bun SQLite. `stop()` is idempotent. Rust work
runs on Tokio and Neon settles promises on the JavaScript thread.

## Tests

```sh
bun run test:cluster
node --test test/cluster-worker.test.mjs test/duckdb-parallel.test.mjs
# Exercise the same branch routing suite against real stores:
DBSANDBOX_TEST_CONSUL_URL=http://127.0.0.1:8500 \
DBSANDBOX_TEST_ETCD_URL=http://127.0.0.1:2379 \
node --test test/cluster.test.mjs
```

The cluster tests use disposable namespaces and a simulated database executor;
they exercise real Neon/Axum HTTP routing, CAS, snapshot streaming, checksums,
late joins, parent independence, recovery, authentication and lease loss. The
PureScript worker test checks binary ZFS command I/O and restored settings using a
bsdkrun protocol fixture. Actual guest/database end-to-end tests require a working
bsdkrun virtualization environment.
