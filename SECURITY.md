# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnStarRocks.

| Version | Supported |
|---|---|
| 1.3.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnstarrocks/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (StarRocks version, connection options, sample data if relevant),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## Scope and design notes

- Passwords and SSH secrets are stored in the macOS Keychain; saved profiles on disk never contain them.
- The StarRocks query port does not use TLS. Use an SSH tunnel (built in) or a trusted network. `mysql_clear_password` (LDAP users) is only answered when explicitly enabled for a connection.
- SSH tunnels use the system `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new`: changed host keys are rejected.
- Statements built by the app (metadata, `KILL`, materialized-view refresh, routine-load control) quote identifiers and literals; issues that allow injecting SQL through object names are considered vulnerabilities.
- **AI (MCP) access** is off for every connection until the user enables it.
  - Read-only access checks every statement with the app's own lexer, on the exact text that is sent. That lexer reads characters the way StarRocks does (`#` is no comment there). Names holding a letter StarRocks may read as an ASCII letter (`ı` is I, `ſ` is S there) are refused.
  - Every AI connection uses the StarRocks SQL dialect, whatever the account or cluster default is. In the trino dialect `"…"` is a name, not a string. The dialect is set and read back on each connection, and the connection is refused if that fails.
  - Read-only access refuses administrator accounts by default: built-in admin roles, system privileges, `IMPERSONATE`, grant options, write privileges on all databases, followed through every role. A text check cannot stop an administrator.
  - The AI never reads other sessions' SQL, credentials or server files: no task or query history, no processlist, no load properties, no backend logs or configuration, no audit log. Running statements are shown with every literal replaced by `?`.
  - Read-only queries may call only reviewed built-in functions: not user-defined functions, and not functions that read files, other users' data or the network (`FILES()`, `ai_query()`, `lookup_string()`, `dict_mapping()`, `get_query_dump()`, the `inspect_…` functions). The list is reviewed for each supported StarRocks version, and functions a new version adds are refused until they are reviewed.
  - Cluster settings are never changed over MCP.
  - **Known limits:** user-defined functions (Java, Python) can do anything their author wrote, and a check cannot see inside them. Read-only queries refuse them, but `execute_statement` (read & write connections) and views can still call them. Privileges granted to the `public` role are not inspected, because StarRocks shows them only to accounts with the GRANT privilege.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnStarRocks/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
