# Cozy Safe

An open-source, cross-platform encrypted vault for notes, files and photos.

> Status: **design phase** — no code yet. This repository currently holds the
> decisions made so far. See [`docs/`](docs/).

## Goals

- Everything is encrypted on the device before it is stored or synced.
- Multiple vaults, each with its own password.
- Runs on Android, iOS, macOS, Windows and Linux from one codebase.
- Sync through a cloud folder, LAN peer-to-peer, and later a self-hosted
  server or internet peer-to-peer — the sync transport never sees plaintext.
- No password recovery: lose the password, lose the data. Backups are the
  user's responsibility and the app makes them easy.
- Fully open source, reproducible builds, independently audited before 1.0.

## Stack

| Layer | Choice |
|---|---|
| Core (crypto, storage, sync) | Rust workspace |
| UI | Flutter |
| Bridge | `flutter_rust_bridge` v2 |

## Documents

| Document | Contents |
|---|---|
| [Requirements & roadmap](docs/requirements.md) | MVP scope, milestones |
| [Architecture](docs/architecture.md) | Core layout, data model, sync adapters |
| [Engineering practices](docs/engineering.md) | Testing, CI, build speed |
| [Supply-chain security](docs/supply-chain.md) | Dependency policy |
| [UI](docs/ui.md) | Design direction, theming, screens |
| [Naming](docs/naming.md) | Identifiers on every platform |
| [Decision records](docs/adr/) | Why each choice was made |

## License

[GPL-3.0-only](LICENSE) with an
[additional permission for app-store distribution](LICENSE-EXCEPTION.md).

A project of [Cozy Pi](https://cozypi.com) · <https://safe.cozypi.com>
