# Changelog

## 0.2.1 — 2026-11-22

### Added

- Rust/Neon cluster coordination with Tokio and Axum, configurable Consul or etcd state, dynamic node joins, and one management API for databases and branches.
- Per-branch placement and cross-node ZFS snapshot transfer for Linux runtimes on matching CPU architectures, with lifecycle tracking, checksum verification, and independent branch runtimes.
- Separate cluster and remote API tokens, configurable through environment variables; servers generate and print missing tokens.
- Cluster architecture diagrams, FluentCI Rust setup, native release runners, and Crane-based Rust builds in the Nix flake.

### Changed

- Use Debian Trixie for Debian-based runtime and helper images.
- Install Debian packages in a temporary RAM-backed build root to avoid dpkg stale-file-handle failures on legacy virtio-fs Docker stores.
- Include the Dockerfile hash in runtime image tags so changed image definitions do not reuse stale cached runtimes.

### Fixed

- Promote existing Linux DuckDB data branches to independent servers with distinct ports; checkout keeps other branch servers running.
- Default the dashboard's database creation selector to PostgreSQL when available.
- Recover Drizzle Studio's missing database drivers by provisioning an isolated, pinned toolchain, with dependency checks performed in an external runtime.

## 0.2.0 — 2026-11-21

### Added

- Nix source builds and development shells, with bsdkrun and Docker, plus multi-platform CI and FlakeHub/Flakestry release publishing.

- Separate database consoles, container shells, and VM terminals in web and TUI bottom panels, with fullscreen and resize controls.
- Bundled Caskaydia Nerd Mono for browser terminals and logs, plus local task and database UI timestamps.

- npm launcher package with a verified GitHub release installer and an `@bsdkrun/cli` dependency.

- Global sandbox inventory, database catalog, diagnostics, engine controls, stop-all, and shell completions.
- Svelte web dashboard and native OpenTUI dashboard, bundled into the standalone executable.
- Database-scoped branch lists, fuzzy search, pagination, keyboard shortcuts, URL copying, and confirmed inactive-branch deletion.
- Colored branch graphs with real ZFS ancestry, creation dates, selectable nodes, and terminal lane panning.
- Database, VM, boot, and operation log viewers with filtering, highlighted matches, follow/pause, timestamp toggles, and raw text export.
- DuckDB web UI and automatic browser opening for supported database UIs.
- VM CPU and memory overrides from the CLI and dashboards.
- Reusable PureScript bindings for Drizzle ORM and OpenTUI.

### Changed

- Store sandbox state in Bun SQLite through Drizzle ORM, with FTS5 search and automatic legacy-state import.
- Isolate provisioning output from the terminal UI using captured child processes.
- Display dates in local time using Day.js: browser time for the web UI and host time for the terminal.
- Group PureScript modules by responsibility and format PureScript and web sources consistently.
- Use Bun for dependency installation, tests, CI, and standalone release builds, including native OpenTUI assets.
- Add the README banner and document installation, dashboards, branches, logs, and completions.

### Fixed

- Keep modal scrolling inside the modal and sort database selectors alphabetically.

- Check host and VM ports when allocating Linux branch servers, avoiding ephemeral-port collisions.

- Prepare all OpenTUI OS, CPU, and libc variants before compiling standalone binaries.

- Include ZFS-only branches in inventory and allow switching to them.
- Keep keyboard selection on the same branch when background inventory refreshes reorder rows.
- Protect the selected branch, main, and the dataset mounted by the parent server from dashboard deletion.
- Preserve RFC3339 ZFS creation dates and show unknown ancestry without inventing connections.

## 0.1.0

- Initial unified database sandbox CLI with Linux/BSD guests and parallel ZFS branches.
