# Horizontally scalable database branches

One `dbsandbox` executable runs on every node. `cluster serve` starts a node;
`cluster join --server URL` starts the same node implementation and discovers an
existing cluster through any live node. Nodes can join while databases and
branches are running. Applications use one management API URL; that entry node
routes each request to the branch's owner.

Branch ownership is tracked individually. Snapshot transfer gives a destination
node independent storage, so adding nodes increases aggregate branch capacity.

```mermaid
flowchart TB
    Consumer["Application / developer / Node.js consumer"]
    API["One management API URL<br/>any dbsandbox node or a load balancer"]
    Consumer --> API

    subgraph Control["Control plane — the same dbsandbox executable on every node"]
        A["Node A<br/>Node.js / Bun + Rust Neon module<br/>Tokio runtime + Axum API<br/>routing + placement<br/>PureScript local executor"]
        B["Node B<br/>Node.js / Bun + Rust Neon module<br/>Tokio runtime + Axum API<br/>routing + placement<br/>PureScript local executor"]
        C["Node C — joins at any time<br/>same executable and capabilities<br/>no restart of existing nodes"]
        Store["Configurable state backend<br/>Consul OR etcd<br/><br/>leased node membership<br/>durable placement PER BRANCH<br/>parent / operation ID / lifecycle state<br/>atomic compare-and-swap updates"]
        A <--> Store
        B <--> Store
        C <--> Store
        C -. "join through any live node" .-> B
        A <-->|"authenticated internal API"| B
        B <-->|"authenticated internal API"| C
        A <-->|"authenticated internal API"| C
    end

    API --> A
    API -. "same API available on every node" .-> B
    API -.-> C

    subgraph Data["Data plane — independent branch storage and compute"]
        Main["Node A<br/>postgres / main<br/>isolated runtime + ZFS volume"]
        Feature["Node B<br/>postgres / feature-a<br/>isolated runtime + ZFS volume"]
        Preview["Node C<br/>postgres / preview-123<br/>isolated runtime + ZFS volume"]
        Main ==>|"immutable snapshot transfer at fork"| Feature
        Feature ==>|"immutable snapshot transfer at fork"| Preview
    end

    A -->|"execute local branch operations"| Main
    B -->|"execute local branch operations"| Feature
    C -->|"execute local branch operations"| Preview
```

## Create a branch

```mermaid
sequenceDiagram
    participant User as API consumer
    participant Entry as Any dbsandbox API node
    participant State as Consul or etcd
    participant Source as Parent branch owner
    participant Target as Selected destination node

    User->>Entry: POST /v1/databases/postgres/branches<br/>{name: feature-a, from: main}
    Entry->>State: Read live membership and parent placement
    Entry->>State: Atomically reserve postgres/feature-a<br/>owner, parent, operation ID, creating
    State-->>Entry: Winning branch placement
    Entry->>Target: Create branch using the reserved operation
    Target->>Source: Prepare immutable snapshot of postgres/main
    Source-->>Target: Snapshot ID, size, checksum and runtime metadata
    Target->>Source: Pull snapshot stream
    Source-->>Target: Snapshot bytes
    Target->>Target: Verify transfer and receive into a fresh volume
    Target->>Target: Start independent branch runtime<br/>with parent's database version and credentials
    Target->>State: Compare-and-swap creating to ready
    Target-->>Entry: Branch ready
    Entry-->>User: Success through the same public API

    Note over Source,Target: After the fork, each branch runs on its own data.<br/>Normal database operations do not go through the parent node.
```

## Ownership and scaling

The scheduling unit is `(database, branch)`, not the database as a whole. For
example, `postgres/main`, `postgres/feature-a`, and `postgres/preview-123` can
belong to three different nodes. A child can itself be the source of another
branch. Each branch gets its own resource identity, runtime and writable volume.
The parent relationship records ancestry; it does not force colocation.

Membership is discovered from the configured backend on each placement decision.
New nodes become candidates for new branches immediately. The scheduler prefers
nodes with fewer assigned branches and can place children away from their source
when capacity is available. Existing branches keep their owners when membership
changes. A seed node is used for joining and has no permanent leadership role.

Every API node reads the same placement records and uses atomic writes to resolve
concurrent creation. The node that executes a mutation verifies membership,
ownership and the operation identity. Requests forwarded internally are executed
locally rather than forwarded again.

## State and failure behavior

Consul uses sessions for ephemeral membership and KV compare-and-swap for durable
branch records. Etcd uses leases for ephemeral membership and transactions for
durable branch records. Both retain placement independently of node liveness.
Separate tokens authorize remote API management (`DBSANDBOX_API_TOKEN`) and
node membership/internal traffic (`DBSANDBOX_CLUSTER_TOKEN`). `serve` generates
and prints missing tokens; environment variables override config-file values.

Branch lifecycle states distinguish `creating`, `ready`, `failed`, and `deleting`.
Local runtime metadata and database contents remain on the owning node; the state
backend does not hold database files or credentials.

A node that loses membership stops accepting management work and cancels in-flight
commands. An offline owner's branch stays unavailable until its storage is
recovered; a new empty database must never silently replace it. Failed snapshot
transfer must not publish a ready branch. Transfer files and snapshots require
bounded lifetimes and cleanup.

Cross-node forks transfer an immutable snapshot into independent destination
storage. They require time and network bandwidth proportional to the transferred
data. This design scales the number of independent branches and their aggregate
compute/storage across nodes. It does not shard an individual branch, replicate
writes, or provide automatic storage failover. Database protocol traffic is a
separate data-plane concern from the unified management API.

## Repository components

| Component | Responsibility |
| --- | --- |
| `crates/cluster` | Tokio/Axum coordinator, membership, branch placement, internal routing, snapshot orchestration |
| `crates/cluster-neon` | Node.js bindings and asynchronous lifecycle promises |
| `packages/cluster` | Node.js API and TypeScript declarations |
| `bin/dbsandbox.js` | Single executable entry point |
| `src/Sbx/Cluster` | PureScript CLI, token configuration, isolated runtimes and ZFS snapshot commands; minimal JS I/O FFI |
| Consul or etcd | Shared membership and branch lifecycle metadata |

The GitHub setup action installs Rust using FluentCI's pinned `setup-rust` module.
The native module is built with `cargo build --release --locked` before Bun
compiles the single executable. Each release platform builds on a matching native
runner so the embedded addon has the correct OS and architecture.
