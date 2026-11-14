# Contributing to CcinnStarRocks

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- Docker, if you want to run the integration tests against real StarRocks clusters.

```bash
git clone https://github.com/whiteCcinn/ccinnstarrocks.git
cd ccinnstarrocks
swift build
swift test --skip IntegrationTests
scripts/build-app.sh --open
```

### Integration tests

```bash
eval "$(scripts/sr-up.sh)"            # StarRocks 3.3 and 4.1 all-in-one containers, seeded with demo data
swift test --filter IntegrationTests
scripts/sr-down.sh
```

`scripts/seed-demo.sql` creates the `shop` database used by the tests and screenshots: one table of every model (duplicate, aggregate, unique, primary key), monthly range partitions, a view, an asynchronous materialized view and a synchronous materialized view. The all-in-one images need about 2 GB of memory each.

### Running the app against a cluster directly

```bash
dist/CcinnStarRocks.app/Contents/MacOS/CcinnStarRocks \
  --connect 127.0.0.1:9030 --user root --database shop \
  --object shop.orders --section partitions
```

Other launch arguments: `--sql "…" --auto-run [--view chart]`, `--operations running|sessions|loads|cluster`, `--profile <saved name>` and `--snapshot <file.png> --snapshot-delay <seconds> --quit-after-snapshot` (renders the window without screen-recording permission).

## Project layout

| Module | Responsibility |
|---|---|
| `MySQLWire` | MySQL protocol: framing, handshake, authentication plugins, text result sets (no I/O) |
| `StarRocksKit` | Transport, connections, pool, sessions with `KILL QUERY` cancellation, SSH tunnels, StarRocks metadata, insights and operations |
| `CcinnStarRocksKit` | UI-independent app logic: profiles, SQL lexer/splitter/auto-limit, completion, charts, export, skew analysis, history |
| `CcinnStarRocks` | SwiftUI/AppKit application |

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Add or update tests with every behaviour change. Protocol logic is covered with the in-memory fake server in `Tests/StarRocksKitTests/FakeMySQLServer.swift`; StarRocks behaviour with the integration suite.
- **Read server output by column name.** `SHOW` commands and `information_schema` views change between StarRocks releases; use `Record.text("Name", "AlternativeName")`, never column positions.
- **Never crash on input.** No force unwraps/casts, unchecked indexing or trapping integer conversions on data that comes from a server, a file or the user. Throw a descriptive error instead.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; do not block the main actor with I/O, sorting or chart preparation.
- **Secrets** must never appear in logs, errors or files.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test --skip IntegrationTests` pass (and the integration suite, if you touched StarRocksKit).
3. Describe what changed and how you tested it (including StarRocks versions, if relevant).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
