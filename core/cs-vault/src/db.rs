//! The vault index: one SQLite file per vault (`vaults/<id>/vault.db`), so listing,
//! sorting and filtering read one file instead of opening every `<item>.meta`
//! (docs/adr/0002-vault-index.md).
//!
//! Like 1Password's local store, nothing secret reaches SQLite in the clear: each row
//! holds the item's record exactly as sealed in `<item>.meta` (Master Key,
//! XChaCha20-Poly1305), next to columns that are no secret today either (the files on
//! disk already show when an item was written and how big it is). The `.meta` files
//! stay, byte for byte the same, as each item's rescue copy: a missing or damaged
//! index is rebuilt from them, and backups carry them, not the index.

use std::collections::HashSet;
use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};

use crate::{Error, Result};

pub(crate) const INDEX_FILE: &str = "vault.db";
/// `PRAGMA user_version` of the schema below; each new version gets one migration.
const SCHEMA_VERSION: i32 = 2;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS items (
    id            TEXT    PRIMARY KEY CHECK (length(id) = 32),
    created_ms    INTEGER NOT NULL,
    modified_ms   INTEGER NOT NULL,
    deleted_ms    INTEGER,
    size_bytes    INTEGER NOT NULL CHECK (size_bytes >= 0),
    sealed_record BLOB    NOT NULL
) STRICT;
-- The vault, newest first.
CREATE INDEX IF NOT EXISTS idx_items_created
    ON items (created_ms DESC, id) WHERE deleted_ms IS NULL;
-- Recently deleted, latest first, and the 30-day purge.
CREATE INDEX IF NOT EXISTS idx_items_deleted
    ON items (deleted_ms DESC) WHERE deleted_ms IS NOT NULL;
-- Sync (docs/adr/0003-sync.md), version 2. Local only: never in backups or the cloud.
-- This device's id, its clock, its journal number, and how far it has read each other
-- device's journal ('cursor:<device>').
CREATE TABLE IF NOT EXISTS sync_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) STRICT;
-- Per place synced with (the cloud, a nearby device) and item, the revision both last
-- agreed on.
CREATE TABLE IF NOT EXISTS sync_items (
    remote     TEXT NOT NULL,
    id         TEXT NOT NULL CHECK (length(id) = 32),
    synced_rev TEXT NOT NULL,
    PRIMARY KEY (remote, id)
) STRICT;
-- Items deleted for good, to tell every place synced with.
CREATE TABLE IF NOT EXISTS sync_gone (
    id  TEXT PRIMARY KEY CHECK (length(id) = 32),
    hlc INTEGER NOT NULL
) STRICT;
-- Which places have been told about a deletion.
CREATE TABLE IF NOT EXISTS sync_gone_sent (
    remote TEXT NOT NULL,
    id     TEXT NOT NULL,
    PRIMARY KEY (remote, id)
) STRICT;
";

/// What the index knows about an item without opening it.
pub(crate) struct Row {
    pub id: String,
    pub sealed_record: Vec<u8>,
}

/// The plain columns of a row, taken from the item's record.
pub(crate) struct Columns {
    pub created_ms: i64,
    pub modified_ms: i64,
    pub deleted_ms: Option<i64>,
    pub size_bytes: u64,
}

pub(crate) struct Index {
    db: Connection,
}

impl Index {
    /// Open the vault's index, creating it if missing. A file that is not a usable
    /// index (damaged, or from a future schema) is replaced by an empty one; the caller
    /// fills it from the `.meta` files.
    pub(crate) fn open(vault_dir: &Path) -> Result<Index> {
        let path = vault_dir.join(INDEX_FILE);
        match Self::open_at(&path) {
            Ok(index) => Ok(index),
            Err(_) => {
                for suffix in ["", "-wal", "-shm"] {
                    let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
                }
                Self::open_at(&path)
            }
        }
    }

    fn open_at(path: &Path) -> Result<Index> {
        let db = Connection::open(path).map_err(sql)?;
        db.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA secure_delete = ON;
             PRAGMA temp_store = MEMORY;",
        )
        .map_err(sql)?;
        let version: i32 = db
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .map_err(sql)?;
        if version > SCHEMA_VERSION {
            return Err(Error::Corrupt("vault index from a newer version"));
        }
        db.execute_batch(SCHEMA).map_err(sql)?;
        db.pragma_update(None, "user_version", SCHEMA_VERSION)
            .map_err(sql)?;
        Ok(Index { db })
    }

    pub(crate) fn upsert(&self, id: &str, c: &Columns, sealed_record: &[u8]) -> Result<()> {
        self.db
            .execute(
                "INSERT INTO items (id, created_ms, modified_ms, deleted_ms, size_bytes, sealed_record)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT (id) DO UPDATE SET
                     created_ms = excluded.created_ms,
                     modified_ms = excluded.modified_ms,
                     deleted_ms = excluded.deleted_ms,
                     size_bytes = excluded.size_bytes,
                     sealed_record = excluded.sealed_record",
                params![id, c.created_ms, c.modified_ms, c.deleted_ms, c.size_bytes as i64, sealed_record],
            )
            .map_err(sql)?;
        Ok(())
    }

    pub(crate) fn sealed_record(&self, id: &str) -> Result<Option<Vec<u8>>> {
        self.db
            .query_row("SELECT sealed_record FROM items WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .optional()
            .map_err(sql)
    }

    pub(crate) fn remove(&self, id: &str) -> Result<()> {
        self.db
            .execute("DELETE FROM items WHERE id = ?1", [id])
            .map_err(sql)?;
        Ok(())
    }

    /// Items in the vault (`deleted` false, newest first) or in Recently deleted
    /// (`deleted` true, latest deletion first).
    pub(crate) fn rows(&self, deleted: bool) -> Result<Vec<Row>> {
        let query = if deleted {
            "SELECT id, sealed_record FROM items
             WHERE deleted_ms IS NOT NULL ORDER BY deleted_ms DESC, id"
        } else {
            "SELECT id, sealed_record FROM items
             WHERE deleted_ms IS NULL ORDER BY created_ms DESC, id"
        };
        let mut stmt = self.db.prepare_cached(query).map_err(sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(Row {
                    id: r.get(0)?,
                    sealed_record: r.get(1)?,
                })
            })
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(sql)
    }

    pub(crate) fn ids(&self) -> Result<HashSet<String>> {
        let mut stmt = self.db.prepare("SELECT id FROM items").map_err(sql)?;
        let ids = stmt.query_map([], |r| r.get(0)).map_err(sql)?;
        ids.collect::<rusqlite::Result<HashSet<_>>>().map_err(sql)
    }

    pub(crate) fn meta_get(&self, key: &str) -> Result<Option<String>> {
        self.db
            .query_row("SELECT value FROM sync_meta WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()
            .map_err(sql)
    }

    pub(crate) fn meta_set(&self, key: &str, value: &str) -> Result<()> {
        self.db
            .execute(
                "INSERT INTO sync_meta (key, value) VALUES (?1, ?2)
                 ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(sql)?;
        Ok(())
    }

    pub(crate) fn synced_rev(&self, remote: &str, id: &str) -> Result<Option<String>> {
        self.db
            .query_row(
                "SELECT synced_rev FROM sync_items WHERE remote = ?1 AND id = ?2",
                [remote, id],
                |r| r.get(0),
            )
            .optional()
            .map_err(sql)
    }

    pub(crate) fn set_synced(&self, remote: &str, id: &str, rev: &str) -> Result<()> {
        self.db
            .execute(
                "INSERT INTO sync_items (remote, id, synced_rev) VALUES (?1, ?2, ?3)
                 ON CONFLICT (remote, id) DO UPDATE SET synced_rev = excluded.synced_rev",
                params![remote, id, rev],
            )
            .map_err(sql)?;
        Ok(())
    }

    /// A deletion for good, to tell every place synced with.
    pub(crate) fn add_gone(&self, id: &str, hlc: i64) -> Result<()> {
        self.db
            .execute(
                "INSERT INTO sync_gone (id, hlc) VALUES (?1, ?2)
                 ON CONFLICT (id) DO UPDATE SET hlc = excluded.hlc",
                params![id, hlc],
            )
            .map_err(sql)?;
        self.db
            .execute("DELETE FROM sync_items WHERE id = ?1", [id])
            .map_err(sql)?;
        self.db
            .execute("DELETE FROM sync_gone_sent WHERE id = ?1", [id])
            .map_err(sql)?;
        Ok(())
    }

    pub(crate) fn gone_hlc(&self, id: &str) -> Result<Option<i64>> {
        self.db
            .query_row("SELECT hlc FROM sync_gone WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .optional()
            .map_err(sql)
    }

    /// Deletions `remote` has not been told about.
    pub(crate) fn gone_unsent(&self, remote: &str) -> Result<Vec<(String, i64)>> {
        let mut stmt = self
            .db
            .prepare(
                "SELECT id, hlc FROM sync_gone WHERE id NOT IN
                 (SELECT id FROM sync_gone_sent WHERE remote = ?1) ORDER BY id",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([remote], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(sql)
    }

    pub(crate) fn gone_sent(&self, remote: &str, id: &str) -> Result<()> {
        self.db
            .execute(
                "INSERT OR IGNORE INTO sync_gone_sent (remote, id) VALUES (?1, ?2)",
                [remote, id],
            )
            .map_err(sql)?;
        Ok(())
    }

    /// The item came back (edited elsewhere after the deletion): forget the deletion.
    pub(crate) fn forget_gone(&self, id: &str) -> Result<()> {
        self.db
            .execute("DELETE FROM sync_gone WHERE id = ?1", [id])
            .map_err(sql)?;
        self.db
            .execute("DELETE FROM sync_gone_sent WHERE id = ?1", [id])
            .map_err(sql)?;
        Ok(())
    }

    /// Forget what was agreed with `remote` (it is a new, empty place).
    pub(crate) fn forget_remote(&self, remote: &str) -> Result<()> {
        self.db
            .execute("DELETE FROM sync_items WHERE remote = ?1", [remote])
            .map_err(sql)?;
        self.db
            .execute("DELETE FROM sync_gone_sent WHERE remote = ?1", [remote])
            .map_err(sql)?;
        Ok(())
    }

    /// Run `f` in one transaction: all of it lands, or none.
    pub(crate) fn transaction<T>(&self, f: impl FnOnce() -> Result<T>) -> Result<T> {
        let tx = self.db.unchecked_transaction().map_err(sql)?;
        let out = f()?;
        tx.commit().map_err(sql)?;
        Ok(out)
    }
}

fn sql(e: rusqlite::Error) -> Error {
    Error::Index(e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cols(created_ms: i64, deleted_ms: Option<i64>) -> Columns {
        Columns {
            created_ms,
            modified_ms: created_ms,
            deleted_ms,
            size_bytes: 1,
        }
    }

    #[test]
    fn rows_come_back_in_order_and_survive_reopening() {
        let dir = tempfile::tempdir().unwrap();
        let a = "a".repeat(32);
        let b = "b".repeat(32);
        let c = "c".repeat(32);
        {
            let ix = Index::open(dir.path()).unwrap();
            ix.upsert(&a, &cols(1, None), b"A").unwrap();
            ix.upsert(&b, &cols(3, None), b"B").unwrap();
            ix.upsert(&c, &cols(2, Some(9)), b"C").unwrap();
            ix.upsert(&a, &cols(1, None), b"A2").unwrap(); // update in place
        }
        let ix = Index::open(dir.path()).unwrap();
        let live: Vec<_> = ix.rows(false).unwrap().into_iter().map(|r| r.id).collect();
        assert_eq!(live, vec![b.clone(), a.clone()]);
        assert_eq!(ix.rows(true).unwrap()[0].id, c);
        assert_eq!(ix.sealed_record(&a).unwrap().as_deref(), Some(&b"A2"[..]));
        ix.remove(&a).unwrap();
        assert!(ix.sealed_record(&a).unwrap().is_none());
        assert_eq!(ix.ids().unwrap().len(), 2);
    }

    #[test]
    fn a_damaged_index_is_replaced() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(INDEX_FILE), b"not a database at all").unwrap();
        let ix = Index::open(dir.path()).unwrap();
        assert!(ix.ids().unwrap().is_empty());
    }

    #[test]
    fn an_index_from_a_newer_version_is_replaced() {
        let dir = tempfile::tempdir().unwrap();
        {
            let db = Connection::open(dir.path().join(INDEX_FILE)).unwrap();
            db.pragma_update(None, "user_version", SCHEMA_VERSION + 1)
                .unwrap();
        }
        let ix = Index::open(dir.path()).unwrap();
        assert!(ix.ids().unwrap().is_empty());
    }
}
