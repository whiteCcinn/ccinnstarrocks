# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **A knowledge base the AI builds once and every session reuses**, one per database, shared by every connection that reaches the cluster:
  - relationships between tables with their evidence: declared `foreign_key_constraints`, joins inside view and materialized-view definitions, joins mined from the editor's query history, column and table names, code references (path, line, symbol) and AI assertions; confidence 0–100 is computed from the evidence, and only confirmed or declared relationships count as facts;
  - notes, a glossary in any language, subject areas and Mermaid ER diagrams;
  - structure fingerprints: when a table changes, what was written against it is marked stale; renames are suggested, dropped tables kept until pruned;
  - links to any number of local projects, so a session started in one finds the knowledge with `list_knowledge`.
- **MCP knowledge tools**: `list_knowledge`, `knowledge_overview`, `search_knowledge`, `explain_table`, `find_join_path` (join chain, `ON` conditions, SQL skeleton, a warning when rows would multiply), `er_diagram`, `refresh_knowledge`; writes with `link_project`, `add_notes`, `add_relationships`, `define_terms`, `define_subject_area`, `remove_knowledge`. Prompts `build_knowledge` and `answer_with_knowledge`.
- **Knowledge tab** (right-click a database → Knowledge): refresh, Confirm or Reject inferred relationships, notes and glossary, diagrams (Copy Mermaid), and linked projects (Link, Remap, Unlink). The tab follows writes from AI sessions as they happen.
- **Settings → MCP → AI may write knowledge**, per connection (on by default), and `mcp --no-knowledge-writes` for the whole server.
- **Export and import settings and knowledge** (File menu, and Settings → General → Backup): one file with connections, knowledge and linked projects, settings and optionally query history. Passwords only with a passphrase (AES-256-GCM, PBKDF2-HMAC-SHA256 600,000 iterations), which also authenticates the file. Import previews every change with per-connection choices, highlights changes that weaken security, remaps project folders, and saves a snapshot first that *Restore Pre-Import Snapshot* uses to undo exactly what the import wrote (connections and passwords it added, connections it replaced unless changed since, knowledge, history entries, settings); a restore that stops part-way can be retried. Importing the same file twice changes nothing.

### Changed

- The MCP audit log records the AI client's name and, for knowledge writes, what changed.
- Editing a connection's AI access or favourite now counts as a change of the connection, so the newer side wins an import conflict.

### Fixed

- Two windows on the same connection overwrote each other's query history: each kept its own copy and wrote it back. Windows now update the file under a shared lock and reread it when another one changed it. History files are private (0600) from the moment they are written.

## [1.4.0] - 2026-11-19

### Added

- **Excel export.** *Export as › Excel…* writes an `.xlsx` workbook (no Office needed, no external library):
  - numbers are number cells only when Excel keeps them exactly: integers show every digit (format `0`, never `1.2E+12`), decimals their scale (`26.90`); integers and decimals beyond 15 significant digits, such as 64-bit IDs, and values with leading zeros stay exact text;
  - dates, JSON and everything else are exact text; NULL is an empty cell; text that would not fit a cell (over 32,767 characters) is cut, and the toast says how many values were;
  - the header row is bold and frozen, and columns are sized to their content;
  - results larger than a sheet (1,048,575 rows or 16,384 columns) are refused before anything is written, with a hint to use CSV.
- **Multi-row SQL INSERT.** *Copy as* and *Export as › SQL INSERT, Multi-row* write `INSERT INTO t (…) VALUES` with one row per line. A new statement starts every 1,000 rows, or before a row that would take it past about 1 MB, so each statement fits the server's packet limit. Loading 20,000 rows took 8 seconds on StarRocks 4.1, where 20,000 single-row INSERTs take tens of minutes. The grid's context menu has *Copy Rows as Multi-row INSERT*.
- The result menu has *Copy as* (CSV, TSV, SQL INSERT one per row, multi-row) and *Export as* (all of those and Excel) for the whole result.

### Changed

- SQL `INSERT`s go to the table the rows came from. StarRocks sends no table name with result columns, so a plain single-table `SELECT … FROM db.t [alias]` names it: `select * from shop.orders o` exports `` INSERT INTO `shop`.`orders` ``, where 1.3 wrote `` `table` ``. Joins, subqueries in FROM, CTEs and set operations keep the placeholder rather than guess.
- Exported files are named after that table when there is one.

### Fixed

- `nan` and `inf` values of floating-point columns were written into INSERTs unquoted, which is not valid SQL; they are now quoted.

## [1.3.4] - 2026-11-19

### Fixed

- **Opening a table's Tablets tab could distort the whole window on clusters with many BEs.** *Replicas per backend* listed every BE in a column as tall as the cluster (about 46 pt per BE), and the page asked the window for that height: with 41 BEs the tab bar ended up 539 pt above the top of the window. The list now scrolls inside its card, and the tab fits the window however many BEs there are.

## [1.3.3] - 2026-11-19

### Fixed

- **SQL completion showed suggestions for text you had already typed past.** After the first suggestions appeared, the popup kept showing an earlier list while it moved and resized for the new one. `select * from` listed `SELECT` and `SET`; `from adx_publisher` still listed every `adx…` table with `adx_demand` selected, so Return inserted the wrong name. The popup now shows exactly the suggestions for the text at the cursor.
- **Table names are suggested right after `FROM`.** A space after `FROM`, `JOIN`, `INTO`, `UPDATE` or `TABLE` opens the list of tables, views and materialized views in the current database; a space after `USE` opens the databases. Return and Tab never open it.
- `ORDER BY … DESC` no longer suggests tables: only a statement that starts with `DESC` / `DESCRIBE` names a table.

## [1.3.2] - 2026-11-18

### Security

- **Read-only AI (MCP) access refuses administrator accounts.** No check on SQL text can stop an administrator: user-defined functions, file access and other users' data are reachable from a plain `SELECT`. An account is refused if it:
  - holds `root`, `cluster_admin`, `user_admin` or `db_admin`;
  - has any system privilege;
  - may impersonate other users;
  - holds a grant option;
  - or has write privileges on all databases.

  The check follows every role the account holds, active or not, and runs on every call. It fails closed when the grants cannot be read. **Settings → MCP → Allow privileged account** allows one connection's account (off by default; changing the host or user name clears it).
- **AI could read other sessions' SQL, tables beyond its privileges and files on the database servers.** In 1.3.1 and earlier, an account with nothing but SELECT on one database could use read-only AI access to:
  - read any file on the backend hosts, with `FILES('path' = 'file:///…')`;
  - read other users' scheduled SQL, string literals included, from `information_schema.tasks`;
  - read rows of tables it may not read with `lookup_string()` (3.3) and `dict_mapping()` (4.1), their DDL, row counts and column statistics with `get_query_dump()`, and materialized-view internals with the `inspect_…` functions. `SHOW BUILTIN FUNCTIONS` does not list these.

  AI tools now refuse:
  - in read-only queries, every function that is not a reviewed built-in: user-defined functions, and functions that read files, other users' data or the network. These include `FILES()`, `get_query_profile()`, `get_query_dump()`, `lookup_string()`, `dict_mapping()`, the `inspect_…` functions and, on 4.1, `ai_query()`, which makes the backends send query data to any URL and returns the reply. `execute_statement` refuses those named here too. Functions that a new StarRocks version adds are refused until they are reviewed;
  - names holding a letter StarRocks may read as a different ASCII letter (`ı`, `ſ`, `İ`, the Kelvin sign, ligatures such as `ﬁ`), quoted or not: `fıles(` is `FILES(` on the server;
  - system tables not on a reviewed list: tasks, task runs, query history, loads, pipes, routine loads, backend logs and configuration, and the audit log;
  - a system schema as the session database, however it is written (`default_catalog.information_schema`, back-quotes, control characters);
  - SHOW forms beyond metadata: `PROCESSLIST`, `PROC`, `LOAD`, `ROUTINE LOAD`, `CREATE CATALOG`, `RESOURCES`, `STORAGE VOLUMES` and `AUTHENTICATION`.

  `get_running_tasks` shows statements with every literal replaced by `?`.
- **The trino SQL dialect bypassed every check on AI SQL.** For an account whose `session.sql_dialect` property is `trino`, or on a cluster whose global dialect is `trino`, StarRocks reads `"…"` as a name. So `SELECT "lookup_string"(…)`, `"get_query_dump"(…)`, `information_schema."tasks"` and, on 4.1, `"ai_query"(…)` ran. The app's own quoted literals could also be broken out of with a quote in a name. AI connections now set the StarRocks dialect on every connection and check it, and refuse to connect when they can't. The SQL editor keeps the account's dialect. The app's own statements now double a quote inside a string instead of escaping it with a backslash, so no name can break out of them in either dialect, in the editor too.
- **Cluster settings could be changed over MCP with `SET @@global .x = …`.** Whitespace, a comment or a line break before the dot hid the global scope. Such statements:
  - passed execute_statement, which never changes cluster settings;
  - skipped the editor's confirmation;
  - were replayed after a reconnect.

  They are now recognised however they are written.

### Changed

- The text `run_query` and `explain_query` send is built and checked in one place, after the automatic `LIMIT`, so what is checked is exactly what runs.
- A NUL character in the user or database name is refused when connecting. Before, it was dropped, so the server got a different name than the one given. AI tools likewise refuse control characters in the names they are given (connection, catalog, database, table).

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

[Unreleased]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.3.4...v1.4.0
[1.3.4]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.3.3...v1.3.4
[1.3.3]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/whiteCcinn/ccinnstarrocks/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/whiteCcinn/ccinnstarrocks/releases/tag/v1.0.0
