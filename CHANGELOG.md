# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Check for Updates…** in the app menu. When a newer release exists, CcinnStarRocks shows its version and release notes. **Download & Open** downloads the disk image, verifies its size and SHA-256 against the release's `SHA256SUMS.txt`, saves it to Downloads without overwriting anything, and opens it. **Release Page**, **Skip This Version** and **Later** are also available.
- A quiet automatic check at most once a day (retried after an hour when offline), on by default, switchable in **Settings → General → Updates**.
- Project links: the Help menu now has **CcinnStarRocks on GitHub**, **Release Notes** and **Report an Issue…**; the About window shows the GitHub link; Settings → General shows the version and project links.

### Fixed

- **Stop** pressed while the SQL editor is still connecting is no longer ignored: the statement is not sent and the run ends as cancelled.

## [1.0.1] - 2026-11-14

### Fixed

- A connection attempt started by an already-cancelled operation (for example a superseded refresh) no longer waits for the full connect timeout while holding a pool slot; it fails immediately as cancelled.

## [1.0.0] - 2026-11-14

First public release.

### Added

- Pure-Swift MySQL protocol client (`mysql_native_password`, auth switch, opt-in `mysql_clear_password` for LDAP users, multi-result sets) tested against StarRocks 3.3 and 4.1.
- Connection manager with favourites, recents, colour tags, connection testing, SSH tunnels and Keychain-backed secrets.
- Catalog browser for internal and external catalogs that tells tables (with DUP / AGG / UNI / PK model badges), asynchronous materialized views (with refresh health), synchronous materialized views (with their base table), views and external tables apart.
- Table insights: design (keys, partitioning, distribution, properties), storage per index, partitions with sizes, rows and a distribution chart, tablets with skew detection and replica distribution per backend, DDL and a data preview.
- Materialized views: refresh status, refresh history from task runs, refresh / force refresh / cancel / activate.
- SQL workbench: highlighting, context-aware completion (catalogs, databases, tables, columns through aliases and CTEs, StarRocks functions), run current / selection / all, automatic LIMIT, `EXPLAIN` and `EXPLAIN COSTS`, cancellation with `KILL QUERY`, error positions, history, CSV/TSV/INSERT export.
- Charts from any result: automatic suggestion (line over time, bar by category, grouped bars, scatter), bar / line / area / scatter / pie with series and aggregation, reduced to at most 2,000 points for large results.
- MCP server (`CcinnStarRocks mcp`) so AI clients such as Claude Code, Codex and Claude Desktop can list connections, explore catalogs, inspect partitions, tablet skew and materialized views, see running tasks and run read-only queries on connections the user opted in; read & write access is opt-in per connection, and every call is audited.
- Operations: what is running now (queries, loads, MV refreshes and tasks, routine loads, schema changes), sessions with kill, loads, routine loads with pause / resume / stop, task runs, schema-change jobs and FE / BE / CN nodes.

[Unreleased]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/whiteCcinn/ccinnstarrocks/releases/tag/v1.0.0
