# Changelog

## 0.2.0 — 2026-11-21

### Added

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

- Check host and VM ports when allocating Linux branch servers, avoiding ephemeral-port collisions.

- Prepare all OpenTUI OS, CPU, and libc variants before compiling standalone binaries.

- Include ZFS-only branches in inventory and allow switching to them.
- Keep keyboard selection on the same branch when background inventory refreshes reorder rows.
- Protect the selected branch, main, and the dataset mounted by the parent server from dashboard deletion.
- Preserve RFC3339 ZFS creation dates and show unknown ancestry without inventing connections.

## 0.1.0

- Initial unified database sandbox CLI with Linux/BSD guests and parallel ZFS branches.
