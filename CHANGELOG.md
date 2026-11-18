# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.3.1] - 2026-11-18

### Security

- **`#` and characters such as emoji could hide SQL from read-only checks.** In 1.3.0 and earlier, AI (MCP) read-only mode, and the confirmation before cluster-setting changes, could be bypassed:
  - `#` could hide a second statement, for example `SELECT 1 # ; CREATE DATABASE …`;
  - `#` or a character above U+FFFF (an emoji, or an invisible tag character) could hide an `INTO OUTFILE` export.

  StarRocks does not treat `#` as a comment and ignores those characters; the app read them differently and missed what the server ran. It now reads them as StarRocks does. MCP refuses any statement with `#`, `\`, control characters or such characters outside quotes and comments.

### Fixed

- `#` is no longer highlighted or checked as a comment, since StarRocks runs the rest of the line.
- Format SQL leaves text containing those characters unchanged instead of rewriting it.

## [1.3.0] - 2026-11-17

### Added

- **Format SQL** (⌥⌘L, toolbar button and Edit menu) formats the selection, or the whole script when nothing is selected, as one undoable edit:
  - main clauses on their own lines and one item per line in multi-item SELECT / GROUP BY / ORDER BY / SET / VALUES lists;
  - `AND` / `OR` conditions on their own lines in WHERE, HAVING and ON (not inside parentheses, CASE or BETWEEN);
  - indented subqueries and CTEs, split multi-branch CASE expressions;
  - StarRocks `CREATE TABLE` column lists and `PROPERTIES` one per line.

  What changes:
  - whitespace, but never between tokens the server could then read differently;
  - the letter case of keywords StarRocks never accepts as names, and of words such as `END` or `DISTRIBUTED BY` only where the statement proves they are keywords.

  Names, functions, strings, quoted identifiers, comments, optimizer hints and inline function bodies (`$$ … $$`) keep their exact text. The result is re-lexed and compared with the original before it replaces anything; when that cannot be proven, or the text changed meanwhile, nothing changes and the editor's status bar says why. A selection is widened to whole tokens and keeps the indentation of its first line. CRLF line endings stay CRLF. **Settings ▸ General** sets the keyword case (UPPER, lower or unchanged) and the indent (2 or 4 spaces).

### Changed

- **MCP:** `run_query`, `explain_query` and `execute_statement` refuse `$$` outside quotes and comments. StarRocks 4.1 reads `$$ … $$` as one block while 3.3 reads `$$` as part of a name, so where such a statement ends cannot be known.

### Fixed

- Starting a connection in a window, for example by double-clicking a saved connection twice, cancels a connection still in progress there instead of leaving it open in the background, and the status shown is always that of the newest connection.
- SSH tunnels no longer join or become a connection-sharing master (`ControlMaster` in `~/.ssh/config`), so closing a window always closes its forward.
- The read-only check of MCP `run_query` sees a keyword written right after a decimal number (`1.5into outfile …`) as StarRocks does, and refuses it.

## [1.2.0] - 2026-11-17

### Added

- **Load search.** Operations ▸ Loads has a search box that searches any field or one chosen field (label, database, table, state, type, error message, job id, user), plus type and state filters. The search runs on the server, so matching jobs are found even when they are not among the newest 500.
- **Stream Loads.** Cluster ▸ **Stream Loads** lists Stream Load jobs. Every load's details now include its client IP, load and transaction ids, bytes, unselected rows, commit time, properties, rejected-record path and the error tracking query.
- **Load history.** *Include history* also searches `_statistics_.loads_history` (StarRocks 3.3+) for jobs the frontends no longer keep in memory. Without the privilege, a notice explains why history is missing.
- **Configuration** section in Operations (Cluster ▸ Configuration):
  - every variable with its global and default value;
  - every FE setting of the connected frontend;
  - every BE setting with its default and per-node values.
  It offers search, *Modified only* and copy. Values that differ from the default or between backends are marked. The view is read-only: **Edit in SQL Editor…** opens a pre-filled `SET GLOBAL` / `ADMIN SET FRONTEND CONFIG` / `UPDATE information_schema.be_configs` statement in a new tab without running it.
- **Precise SQL error markers.**
  - Errors are underlined over the exact token or range, with the message shown after the line and in a bar under the editor.
  - Unknown columns, tables and databases are located by name, although StarRocks reports no position for them.
  - Positions are read in Unicode code points, as StarRocks counts them, including digit-grouped ones such as `column 1,214`.
  - `EXPLAIN` and auto-`LIMIT` runs map back to the right place.
  - **Show in Editor** jumps to the error.
- **Multiple windows made easy.** File ▸ **New Window with This Connection** (⇧⌘N) and the toolbar's **New Window** button open the current connection in another window, with the password already in use, so unsaved connections and passwords not in the Keychain work too. Saved connections have **Open in New Window**. Every window keeps its own connection; closing one disconnects only that window.
- **Checks while typing.** Unclosed strings, back-quoted names, `/*` comments and parentheses are flagged without contacting the server.

### Changed

- Statements that change cluster settings (`SET GLOBAL`, `ADMIN SET … CONFIG`, `UPDATE information_schema.be_configs`) **always** ask for confirmation in the SQL editor, even when the connection does not ask before data changes. MCP `execute_statement` refuses them.
- Loads, Running Now and MCP `get_running_tasks` no longer list the internal `_statistics_` jobs that StarRocks writes every minute. Choose `_statistics_` in the database picker to see them.
- **Cancel** is offered only for loads that `CANCEL LOAD` can cancel, which excludes Stream Loads and routine load tasks.
- The database context menu's **Loads** opens Loads filtered to that database.

### Fixed

- Error markers in the SQL editor no longer stay at a stale position after editing: they move with edits made before the failing statement and disappear when that statement is edited or the text is replaced, including edits made while it was still running.

## [1.1.0] - 2026-11-16

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

[Unreleased]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/whiteCcinn/ccinnstarrocks/releases/tag/v1.0.0
