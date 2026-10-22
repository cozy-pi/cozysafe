# ADR 0002: Vault index in SQLite

- Status: accepted
- Date: 2026-10-22

## Context

Listing a vault opened and decrypted one `<item>.meta` file per item: 1,000 items took
0.05 s, 10,000 took 3 s (release build, Mac, 2026-10-22), and the app lists after every
change. Apps that hold many items keep their metadata in SQLite (1Password, Signal,
Apple Photos).

## Options considered

1. **SQLCipher** (whole file encrypted page by page). Needs OpenSSL's libcrypto off
   Apple platforms. Tried on branch `sqlite`: the Android library then imported
   `socket`, `bind`, `accept`, `sendmsg`, `setsockopt`, and `tools/check-rust-symbols`
   failed. Rejected (docs/supply-chain.md: no network code ships).
2. **SQLite3 Multiple Ciphers** (same idea, crypto built in, no OpenSSL). No maintained
   Rust binding; we would vendor and maintain its C amalgamation. Kept as a fallback.
3. **Whole file encrypted by us, SQLite in memory** (KeePass-like). Full SQL, but the
   whole index sits decrypted in memory while the vault is open, every change rewrites
   the file, and recovery after a crash needs merge logic.
4. **Plain SQLite, sensitive fields sealed by us** (1Password-like). **Chosen.**

## Decision

One plain SQLite file per vault, `vaults/<vault>/vault.db` (`rusqlite`, SQLite compiled
from the bundled source; no system library, no C crypto). Nothing secret reaches SQLite
in the clear:

```sql
CREATE TABLE items (
    id            TEXT    PRIMARY KEY CHECK (length(id) = 32),
    created_ms    INTEGER NOT NULL,
    modified_ms   INTEGER NOT NULL,
    deleted_ms    INTEGER,
    size_bytes    INTEGER NOT NULL CHECK (size_bytes >= 0),
    sealed_record BLOB    NOT NULL
) STRICT;
CREATE INDEX idx_items_created ON items (created_ms DESC, id) WHERE deleted_ms IS NULL;
CREATE INDEX idx_items_deleted ON items (deleted_ms DESC) WHERE deleted_ms IS NOT NULL;
```

- `sealed_record` is the item's record exactly as in `<item>.meta`: kind, name, MIME
  type, groups, favourite, duration and the wrapped item key, sealed with the Master Key
  (XChaCha20-Poly1305, AAD naming vault, item and role). Groups stay items of kind
  `tag` inside sealed records, so the index does not reveal which items share a group.
- The plain columns (when added, last changed, deleted, size) are no secret today either:
  the files on disk show when they were written and how big they are.
- **Rescue copy and source of existence.** Each item keeps its `.meta` file, byte for
  byte the record in the index. Records go to the file first and the index second;
  deletes remove the file first. `OpenVault::sync_index` runs on every unlock: it
  compares file names with index rows (no decryption) and adds or drops rows. A missing,
  damaged or newer-schema index is replaced and rebuilt from the files. This is also the
  migration for vaults made before the index.
- **Backups** are unchanged: they carry the `.meta`, `.data` and `.thumb` files, not the
  index; restoring builds the index on first unlock
  (`core/cs-vault/tests/frozen_backup.rs`).
- Pragmas: `journal_mode = WAL`, `synchronous = NORMAL`, `secure_delete = ON`,
  `temp_store = MEMORY`. Schema version in `PRAGMA user_version`.

Result, same machine: 1,000 items list in 0.004 s, 10,000 in 0.045 s.

## Consequences

- Sorting by name and filtering by kind, group or favourite happen in memory after one
  read (the fields are sealed). Fast enough for tens of thousands of items.
- No full-text index: note search decrypts notes, as before. Revisit with option 2 if
  it becomes slow.
- One C library enters the app (SQLite itself); it has no network code and
  `tools/check-rust-symbols` keeps proving it.
- Changes to a record that the app makes between the file write and the index write are
  lost from the index if the app is killed in between (the file has them). Accepted: the
  window is a few milliseconds and only affects the changed fields of one item.
