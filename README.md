![Database branching: main forks into feature, fix-auth and add-index, with a nested seed-data branch](docs/assets/readme-banner.svg)

[![Test](https://github.com/tsirysndr/dbsandbox/actions/workflows/test.yml/badge.svg)](https://github.com/tsirysndr/dbsandbox/actions/workflows/test.yml)

Database, search and authorization sandboxes in one PureScript CLI, powered by
[bsdkrun](https://github.com/tsirysndr/bsdkrun). Fork database data with ZFS
copy-on-write and run the forks as independent servers at the same time.

```sh
dbsandbox postgres start                         # Start a PostgreSQL server
dbsandbox postgres branch feature                # Fork the data and start a parallel server
dbsandbox postgres --branch feature url          # Show the feature server connection URL
dbsandbox postgres checkout feature              # Select feature; other servers keep running

dbsandbox mariadb start                          # Start a MariaDB server
dbsandbox duckdb start linux 2.0.0               # Start DuckDB 2.0.0 with a Quack server
dbsandbox duckdb ui                             # Open the running branch in DuckDB's web UI
dbsandbox sqlite start                           # Start a libSQL HTTP server
dbsandbox mysql start --port 3307                # Start MySQL alongside MariaDB on another port
dbsandbox typesense start --password my-api-key  # Start Typesense with a custom API key
dbsandbox chroma start                           # Start a Chroma vector database server
```

![dbsandbox terminal dashboard showing database branches, a colored ZFS branch graph, local creation dates, and server status](docs/assets/tui-preview.png)

## Installation

The host needs macOS Apple Silicon or Linux with KVM, [bsdkrun](https://github.com/tsirysndr/bsdkrun) **0.12.2 or newer**,
and the Docker CLI for Linux guests. Docker Desktop is unnecessary: [bsdkrun](https://github.com/tsirysndr/bsdkrun)
provides the engine VM. First startup needs network access for images/packages.

Install with Homebrew on macOS Apple Silicon or Linux:

```sh
brew install tsirysndr/tap/dbsandbox
dbsandbox --help
```

The formula installs the Docker CLI and bsdkrun dependencies.

Or use npm (Node.js 18+):

```sh
npx dbsandbox --help
# Or install globally:
npm install -g dbsandbox
```

The npm package downloads the matching GitHub release, verifies `SHA256SUMS`,
and includes `@bsdkrun/cli` as a dependency. Its source is in [`npm/`](npm/).
The matching release assets and npm package must be published first.

From source, use Bun 1.4.5 or newer (Node.js 22/24 is also used by Spago's toolchain):

```sh
bun install --frozen-lockfile
bun link
dbsandbox --help
dbsandbox postgres doctor
```

To build one standalone executable:

```sh
bun run build:bin
./dist/dbsandbox --version
```

The core executable needs neither Node.js nor Bun at runtime. Optional host
tools such as Drizzle Studio/drizzle-kit, pgcli/mycli and pgroll keep their
respective host dependencies. Source installs include Drizzle's Node packages;
standalone users can install `drizzle-kit`, `drizzle-orm` and the chosen driver
globally with Bun, and `uv` or `pipx` for the Python clients.

The GitHub release workflow builds macOS ARM64, Linux x86_64 and Linux ARM64
archives and `SHA256SUMS`. `install.sh` consumes a published release, checks its
checksum, and installs to `~/.local/bin`; set `DBSANDBOX_INSTALL_DIR` to change
that directory or pass a release tag. A release must be published before the
release installer can download it:

```sh
curl -fsSL https://raw.githubusercontent.com/tsirysndr/dbsandbox/main/install.sh | sh
# Pin a release:
curl -fsSL https://raw.githubusercontent.com/tsirysndr/dbsandbox/main/install.sh | sh -s -- v0.2.0
```

## Global commands

```sh
dbsandbox ps                     # List running servers across all databases
dbsandbox ps --all               # Include stopped servers and parallel branches
dbsandbox ps --all --json        # Machine-readable inventory with passwords redacted
dbsandbox databases              # List supported databases, versions, ports and guests
dbsandbox doctor                 # Check host tools, runtime version and virtualization
dbsandbox engine status          # Inspect the shared VM, memory, CPUs and image storage
dbsandbox stop --all             # Stop configured servers; retain their data and engine
dbsandbox ui                     # Open the local dashboard in your browser
dbsandbox tui                    # Open the native terminal dashboard
```

`databases`, `doctor` and `engine status` also accept `--json`. Inventory marks
the selected branch with `*` and colors it and `RUNNING` in neon teal. It reads
saved state without creating empty configuration directories; unrelated containers
are excluded. An unavailable runtime reports `UNKNOWN` rather than a stopped
server, and returns a nonzero exit code.

The Svelte dashboard uses bundled Tailwind CSS and Lucide SVG icons, with a dark
background, square corners and purple (`#8129ff`) accents. RUNNING indicators
stay teal green. Its quick search filters branches and
databases through SQLite FTS5, with case-insensitive word and prefix matching.
It works without a CDN or a separate frontend server.

Log filters highlight matching words. The Dates button toggles muted date prefixes.
Lines without a source timestamp use capture time. All date prefixes use local
time. Raw downloads retain the original text.

Choose a database from the branch dropdown to view only its branches. Search and
pagination stay within that database; the TUI uses Tab to open its database selector.

The branch graph shows colored fork lanes using ZFS origins and creation dates.
It is enabled by default; use the Graph/Table button on the web or `g` in the TUI.
Terminal `[` / `]` keys pan deep graphs. Unknown or deleted parents stay disconnected
and are labeled explicitly. Filtering hides parents outside the results rather than
inventing a new connection. Dates always use local time: the browser timezone for
the web UI and the host timezone for the TUI. Unavailable dates show `Unknown`. These are branch forks, not a database commit or merge history.

Use `/` to focus the sticky branch search and `?` for the web keyboard shortcuts modal.
Delete inactive branches with their Delete button or `d` on a highlighted row; confirmation is required. The selected branch, `main`, and the parent server dataset are protected.
Shortcuts pause while typing in form fields or while a dialog is open.

The branch table has 10/25/50-row pagination. The copy icon beside a connection
copies its full URL to the clipboard while the displayed URL remains redacted.
The **Logs** controls open monospaced database/container logs, VM console and
boot logs, or captured operation output. Follow refreshes the viewer; pause it
to inspect earlier output. A quick filter narrows displayed lines; Download `.txt`
saves the full current snapshot, independently of the filter. Operation logs retain the latest 256 KiB for each
of the last 50 tasks, with known credentials redacted.

The dashboard lists configured servers and every ZFS data branch, including
branches without an independent server. Those rows show **DATA ONLY**; use
**Switch** to mount one in the parent sandbox. Switching a data-only branch
restarts that parent server if it was running; other branch servers keep running.
The terminal dashboard lists the same branches (Enter switches, `/` searches).

The dashboard lists every configured server and branch. Start or stop servers,
fork a branch, select a branch, or launch DuckDB UI and Drizzle Studio from its
rows. New databases use the same defaults as the CLI. Database operations run
one at a time, with progress shown in Tasks. The dashboard listens on loopback
at the first free port from 8787; use `dbsandbox ui --port 8888 --no-open` for a
fixed port or a headless host. Keep the command running. Ctrl-C closes the
dashboard and its database UI sessions while database servers keep running.
Connection URLs in the dashboard hide passwords; use `dbsandbox DATABASE url`
when you need the credentials.

CPU and memory fields override VM resources when starting a database. Linux
databases share one engine: explicit resource overrides resize that VM and can
restart its servers. Use the settings control on the **VM resources** card to
change its CPU cores and memory in MiB; the dashboard asks before applying a
restart. BSD start overrides apply to that database's VM. Blank fields retain
the defaults or existing allocation.

### Terminal dashboard

`dbsandbox tui` uses OpenTUI's native renderer through the local PureScript
bindings: borderless panels, fuzzy search overlays and a Neovim-style status
bar. It is bundled into the standalone executable, including its native library.
Database operations run in child processes with piped output, so Docker builds
and provisioning logs cannot overwrite the terminal UI.
Nerd Font branch icons are enabled by default; use `DBSANDBOX_NERD_FONT=0 dbsandbox tui`
for the standard symbol. Terminals cannot reliably report their selected font.

| Key | Action |
| --- | --- |
| `Tab` | Choose the database shown in the branch list |
| `g` | Toggle branch graph / table |
| `[` / `]` | Pan graph lanes horizontally |
| `j` / `k`, arrows | Move between servers |
| `/`, `Ctrl-P` | Open fzf-style branch search; Enter jumps to a result |
| `Enter` | Select the highlighted branch |
| `b` | Fork a branch |
| `d` | Delete an inactive branch, with confirmation |
| `s` | Start or stop the selected server |
| `u` / `U` | Open or close its database UI |
| `y` | Copy its full connection URL |
| `l` / `L` | View database logs / VM logs |
| `o` | View captured operation output |
| `n` | Start a database: `database [guest] [version] [CPU] [MiB]` |
| `e` | Override shared VM CPU and memory |
| `S` | Stop all configured servers, with confirmation |
| `r` | Refresh |
| `?` | Show keyboard shortcuts |
| `q` / `Ctrl-C` | Quit and close owned UI sessions |

In the log viewer, use `v` to switch source, `f` to toggle follow, `j`/`k` or
Page Up/Down to scroll, `h`/`l` to pan horizontally, `G` to follow the latest
output, `/` to filter and highlight matches, `t` to toggle date prefixes, `d` to export the full snapshot to a text file, and Esc
to close. Clipboard copying uses host clipboard tools when
available, with OSC 52 as a terminal-dependent fallback.

CLI help is always plain text. Use `--no-color` or `NO_COLOR=1` to disable
colors in other CLI output and the TUI.

### Shell completion

Completion is available for Bash, Zsh and Fish. Configure it once for your shell:

```sh
# Bash: add to ~/.bashrc
source <(dbsandbox completion bash)

# Zsh: add to ~/.zshrc
autoload -Uz compinit && compinit
source <(dbsandbox completion zsh)

# Fish: generate the completion file
mkdir -p ~/.config/fish/completions
dbsandbox completion fish > ~/.config/fish/completions/dbsandbox.fish
```

Restart your shell or source its configuration after adding the Bash/Zsh lines.
Regenerate the Fish completion file after updating dbsandbox.

## Existing sandboxes

Sandbox configuration, fork manifests and selected branches are stored in
`$XDG_CONFIG_HOME/dbsandbox/state.sqlite` (default `~/.config/dbsandbox/state.sqlite`).
Bun SQLite and the local PureScript Drizzle bindings provide transactions,
WAL journaling and a versioned schema. The file has mode `0600`. The FTS5 index
contains database names, branch names, guest OS and versions; credentials are
excluded.

Existing JSON configuration is imported transactionally on first access. The
original files are retained as backups and are not imported again after changes
or deletion in SQLite. Runtime resource names, ZFS data and guest databases are
preserved:

```sh
dbsandbox postgres status
dbsandbox duckdb url
```

The visible command is `dbsandbox DATABASE`; resource names reported by [bsdkrun](https://github.com/tsirysndr/bsdkrun)
can still contain the original tool names. `XDG_CONFIG_HOME` is respected.

## Supported databases

| Database | Command | Default Linux image | Default port | BSD mode |
| --- | --- | --- | --- | --- |
| PostgreSQL | `postgres` (`postgresql`, `pg`) | `postgres:18` | 5432 | Official server packages |
| MariaDB | `mariadb` | `mariadb:12` | 3306 | Official server packages |
| MySQL | `mysql` | `mysql:8.4` | 3306 | FreeBSD 8.4 / NetBSD 8.0 pkgsrc; binary availability varies |
| Typesense | `typesense` | `typesense/typesense:30.2` | 8108 | Linux only |
| Chroma | `chroma` | `chromadb/chroma:1.5.3` | 8000 | Linux only |
| DuckDB | `duckdb` | `duckdb/duckdb:2.0.0` | 9494, Quack | Embedded file access; DuckDB >= 2 required |
| Databend | `databend` | `datafuselabs/databend:latest` | 8000, HTTP SQL | Linux only |
| TigerBeetle | `tigerbeetle` | `ghcr.io/tigerbeetle/tigerbeetle:latest` | 3000 | Linux only |
| YugabyteDB | `yugabytedb` | `yugabytedb/yugabyte:2026.1.3.0-b100` | 5433, YSQL | Linux only |
| Vearch | `vearch` | `vearch/vearch:latest` | 9001 | Linux only |
| TimescaleDB | `timescale` | `timescale/timescaledb:latest-pg18` | 5432 | Linux only |
| TiDB | `tidb` | `pingcap/tidb:latest` | 4000, MySQL | Linux only |
| SpiceDB | `spicedb` | `authzed/spicedb:latest` + PostgreSQL 17 | 8443, HTTP gateway | Linux only |
| SurrealDB | `surrealdb` | `surrealdb/surrealdb:latest` | 8000 | Linux only |
| ScyllaDB | `scylladb` | `scylladb/scylla:latest` | 9042, CQL | Linux only |
| Qdrant | `qdrant` | `qdrant/qdrant:latest` | 6333, HTTP | Linux only |
| MongoDB | `mongodb` | `mongo:8` | 27017 | Linux only |
| Cassandra | `cassandra` | `cassandra:5` | 9042, CQL | Linux only |
| ClickHouse | `clickhouse` | `clickhouse/clickhouse-server:latest` | 8123, HTTP | Linux only |
| ArangoDB | `arangodb` | `arangodb:latest` | 8529 | Linux only |
| CockroachDB | `cockroachdb` | `cockroachdb/cockroach:latest` | 26257, PostgreSQL | Linux only |
| SQLite | `sqlite` (`libsql`) | `ghcr.io/tursodatabase/libsql-server:latest` | 8080 | Linux only |

Each database has its own state, branches and selection. All Linux containers
share the Docker engine VM. PostgreSQL, MariaDB and MySQL on FreeBSD/NetBSD use a
shared VM per database, with separate processes for parallel branches.

## Parallel branches

```sh
dbsandbox postgres branch feature
dbsandbox postgres branch experiment --from feature
dbsandbox postgres branch staging --port 15433
dbsandbox postgres branch

dbsandbox postgres --branch feature status
dbsandbox postgres --branch feature psql -c 'select current_database()'
dbsandbox postgres --branch feature stop
dbsandbox postgres --branch feature start

dbsandbox postgres checkout feature
dbsandbox postgres url
dbsandbox postgres checkout main
dbsandbox postgres branch -d experiment
```

`branch NAME` snapshots and clones the source dataset, starts a parallel
instance, and leaves your selection unchanged. It inherits the source's guest
OS, database version, database name and credentials. Nested forks use `--from`.
Writes remain isolated in each dataset; committed data is recovered from the
cloned WAL/redo logs as after a crash.

Ports are chosen automatically above the source's host port, skipping live
listeners and reservations held by stopped branches. BSD forks also check guest
ports. An explicit `--port` collision fails before creating a dataset. Ports
remain reserved until the branch is deleted. A busy port on restart is reported.

Put `--branch NAME` after the database name and **before the command** to target
an instance without changing your selection. `checkout NAME` selects an
existing parallel instance; other servers keep running. For branches without
an instance, checkout keeps the parent-server mount-switching behavior.
`checkout -b NAME` retains that behavior too.

Linux runs one container per instance, bind-mounting only its own dataset.
BSD PostgreSQL/MariaDB/MySQL forks run separate processes with their own data paths,
ports, PID files, sockets and logs. Exactly one VM imports a ZFS pool; the same
disk is never imported into multiple VMs at once. BSD processes share a kernel
and are not a security boundary. DuckDB's BSD branches remain embedded file
access rather than network servers.

The active branch and `RUNNING` status use neon teal on terminals. `NO_COLOR`
and redirected output disable color.

## Commands and clients

Every database supports `start`, `stop`, `status`, `branch`, `checkout`, `url`,
`exec`, `ssh`, `log`, `doctor` and `destroy`. Use `--help` at any level.

```sh
dbsandbox postgres start freebsd --user app --password secret --db app
dbsandbox mariadb start netbsd --port 13306
dbsandbox duckdb start --password configurable-token
dbsandbox duckdb token
dbsandbox duckdb duckdb -noheader -csv -c 'select 42'
dbsandbox mariadb mariadb -N -e 'select 42'
dbsandbox sqlite sqlite3 'select 42'
```

PostgreSQL exposes `psql`, `pgcli`, Drizzle Studio/drizzle-kit, and the pgroll
`migrate`, `pgroll` and `setup` commands. MariaDB exposes `mariadb`/`mysql`,
`mycli`, and Studio/drizzle-kit. MySQL has its own `mysql` client, `mycli`,
and Studio/drizzle-kit. MySQL binary logging is disabled for local ZFS clones;
replication is not configured. On BSD, MySQL uses a separate server process per
branch and disables the X Plugin to avoid a second shared listening port.
SQLite exposes `sqlite3`/`tursodb`, `litecli`,
and Studio/drizzle-kit when running libSQL. DuckDB exposes `duckdb`/`sql`/`cli`
and Quack authentication tokens; Drizzle does not support that protocol.

SQLite also supports the in-process engines `turso` and `sqlite3`:

```sh
dbsandbox sqlite start linux turso
dbsandbox sqlite start linux sqlite3
```

Choose an engine/version on first creation; destroy that database's sandbox
before changing it. Serverless modes expose no port and disable Studio.
Database CLI arguments are forwarded without requiring a host database client.

`branch -d NAME` stops and deletes only the chosen fork. A failed fork startup
retains its data and configuration for `--branch NAME start` to retry.
`dbsandbox DATABASE destroy` removes that database's parent and all its forks,
with confirmation; `--yes` bypasses the prompt. It preserves other databases and
the shared Docker VM. An explicit `--branch NAME destroy` removes only that fork.

## Database web UIs

```sh
dbsandbox duckdb ui                              # Start DuckDB's UI and open your browser
dbsandbox duckdb --branch feature ui --port 4214  # Browse a specific parallel branch
dbsandbox duckdb ui --no-open                    # Print the URL without opening a browser
dbsandbox postgres studio                        # Start Drizzle Studio and open your browser
dbsandbox mysql studio --port 4984                # Use another Studio port
dbsandbox sqlite studio --no-open                 # Start Studio on a headless host
```

DuckDB's `ui` command requires a running Linux sandbox. It chooses a free host
port starting at 4213, or uses `--port`. The UI runs in a temporary container
and attaches the selected branch through Quack; it never opens the database
file as a second writer. The branch appears as the `sbx` catalog. Keep the
command running while using the UI; Ctrl-C removes its container and port
forward, leaving the database server running.
Stopping, deleting or recreating a database branch also closes its UI sessions.
If another client changes the schema, run `CALL quack_clear_cache();` in the UI
to refresh the attached catalog.

`studio` opens `https://local.drizzle.studio` after its local server is ready.
Custom ports and hosts are reflected in the URL; wildcard binds open through
loopback. Both commands
support `--no-open` and always print their URL. If automatic browser opening
is unavailable, open that URL manually.

## Typesense and Chroma APIs

Both services persist `/data` on their ZFS branch. `api` (also `http`) sends
requests to the selected server, prints the response, and exits nonzero on
HTTP errors. It needs no host curl or Python client.

```sh
dbsandbox typesense start --password my-api-key
dbsandbox typesense api POST /collections '{"name":"books","fields":[{"name":"title","type":"string"}]}'
dbsandbox typesense api GET /collections
dbsandbox typesense branch experiment
dbsandbox typesense --branch experiment api GET /collections
dbsandbox typesense token

dbsandbox chroma start
dbsandbox chroma api GET /api/v2/heartbeat
dbsandbox chroma api POST /api/v2/tenants/default_tenant/databases/default_database/collections '{"name":"documents"}'
dbsandbox chroma branch experiment
```

Typesense generates an API key when `--password` is omitted; the built-in
client supplies it as `X-TYPESENSE-API-KEY`. `token` prints the current branch's
key. Chroma uses its local, unauthenticated API. Both bind forwarded ports to
loopback. SQL clients, database/user flags and Drizzle commands are not exposed
for these API services. Typesense and Chroma currently use Linux guests
on both macOS and Linux hosts.

## Additional Linux backends

All services in the extended catalog use Linux guests. Aliases include
`timescaledb`, `mongo`, `cockroach`, `scylla` and `yugabyte`.

```sh
dbsandbox qdrant start --password my-api-key
dbsandbox qdrant api GET /collections
dbsandbox mongodb start --password local-secret
dbsandbox mongodb mongosh --eval 'db.runCommand({ping:1})'
dbsandbox cassandra cqlsh -e 'SELECT release_version FROM system.local'
dbsandbox clickhouse api POST / 'SELECT 42'
dbsandbox surrealdb api POST /sql 'INFO FOR ROOT;'
dbsandbox timescale start --port 15432
dbsandbox cockroachdb start
dbsandbox tidb start
dbsandbox tigerbeetle start
dbsandbox tigerbeetle repl
dbsandbox tigerbeetle repl --command="lookup_accounts id=1;"
dbsandbox spicedb start --password my-preshared-key
```

`branch NAME` and `--branch NAME` work across the catalog. When parent ports
conflict, select an unused port with `start --port PORT`; fork ports are chosen
automatically. Only each service's primary client endpoint is published.
SpiceDB exposes the authenticated HTTP gateway; its PostgreSQL datastore and
gRPC listener stay inside the container. TigerBeetle uses a single development
replica with cluster ID 0. TiDB uses persistent UniStore, and YugabyteDB and
CockroachDB use single-node configurations. These are local development setups.

MongoDB, ClickHouse, Databend and SurrealDB accept `--user`/`--password`.
ArangoDB uses the root user with `--password`. Qdrant and SpiceDB generate a
key by default, configurable with `--password` and readable with `token`.
Cassandra, ScyllaDB, Vearch, TiDB, YugabyteDB and CockroachDB use unauthenticated
local development modes; CockroachDB starts with `--insecure`.

SpiceDB's PostgreSQL, Databend's metadata and filesystem storage, and Vearch's
master/router/partition data are kept together on the ZFS branch. TigerBeetle
formats its data file only on first creation. Cassandra and ScyllaDB use
synchronous batch commit logs so acknowledged writes reach a fork immediately.
Image wrappers are generated from PureScript. Images must provide a build for the Linux guest's CPU
architecture; available architectures depend on the upstream tag.

Databend, TigerBeetle, ClickHouse, Cassandra, ScyllaDB and YugabyteDB request
6 GiB when creating a new engine, and grow smaller existing engines after a clean stop.
Other configured resources are preserved; the engine is never shrunk. ScyllaDB
limits networking IOCBs to 1024 per server so parallel branches share the VM's
async I/O capacity. For parallel branches of heavier servers, resize the shared
VM as needed:

```sh
bsdkrun docker stop
bsdkrun update bsdkrun-docker --cpus 4 --mem 6144
bsdkrun docker start --publish-bind 127.0.0.1
```

Pinecone is excluded: its local emulator was discontinued upstream.

## Development and CI

PureScript modules are grouped under `src/Sbx/Database`, `Runtime`, `Branch`,
`State`, `Management`, `Cli` and `UI` (with separate `Web` and `Terminal`
subfolders). Reusable bindings live in `packages/drizzle` and
`packages/opentui`. The Svelte/Tailwind/Lucide frontend lives in `ui/src`.

```sh
bun run format                   # purs-tidy and Prettier
bun run format:check             # Check PureScript and frontend formatting
```

```sh
bun run test                         # PureScript suites + Bun CLI, HTTP and CI tests
bun run build:bin
bun run test:e2e                  # all catalog live Linux suites, sequentially
bun bin/ci.js e2e duckdb         # one live profile
SBX_E2E_OS=freebsd bun bin/ci.js e2e postgres
SBX_E2E_OS=netbsd bun bin/ci.js e2e mariadb
SBX_E2E_OS=freebsd bun bin/ci.js e2e mysql
SBX_E2E_OS=netbsd bun bin/ci.js e2e mysql

fluentci run test unit
fluentci run --workflow test      # Ubuntu x86_64, sudo and /dev/kvm
```

The custom `.fluentci/test` PureScript component installs checksum-verified
[bsdkrun](https://github.com/tsirysndr/bsdkrun), runs unit tests, builds the executable, and tests real servers,
forwarded ports, credentials, nested forks, selection, persistence and cleanup.
Live tests use unique runtime names and temporary configuration. They preserve
existing services and remove their own containers/VMs and volumes in finalizers.
Missing virtualization is an error rather than a skipped test.

GitHub Actions uses `setup-fluentci@next` with pinned FluentCI 0.17.8 and the
locked `setup-purescript@v0.2.0` module. CI decisions, release validation and
cleanup live in `src/Ci` as PureScript; JavaScript supplies host/driver I/O.
Logs stream with progress heartbeats. Diagnostics go to
`.fluentci/test-logs/DATABASE/OS/` and are uploaded even after failure.

GitHub tests run one database per matrix job, including its unit tests and
protocol-specific persistence/branch suite. Set `DBSANDBOX_E2E_DATABASE` to
select a single service when running `bun run test:e2e` locally.

A `v*` tag matching `package.json` tests the project, builds three target
archives, verifies executable architecture, and publishes them with checksums
using the workflow's GitHub token. No extra repository secret is required.
