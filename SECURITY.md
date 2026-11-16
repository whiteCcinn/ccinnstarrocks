# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnStarRocks.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

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
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnStarRocks/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
