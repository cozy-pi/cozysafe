//! The vault index: one SQLCipher database per vault (`vault.db`), the whole file
//! encrypted with a key derived from the vault's Master Key.

use rusqlite::Connection;
use std::path::Path;

/// Open (or create) the database at `path` with a raw 256-bit key. SQLCipher's own
/// password stretching is skipped: the key already comes from Argon2id and HKDF.
pub fn open(path: &Path, key: &[u8; 32]) -> rusqlite::Result<Connection> {
    let db = Connection::open(path)?;
    db.pragma_update(None, "key", format!("x'{}'", hex::encode(key)))?;
    // Fails here, not later, when the key is wrong.
    db.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))?;
    Ok(db)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypted_on_disk_and_wrong_key_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        {
            let db = open(&path, &[1; 32]).unwrap();
            db.execute_batch("CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('secret-word');")
                .unwrap();
        }
        let raw = std::fs::read(&path).unwrap();
        assert!(!raw.windows(11).any(|w| w == b"secret-word"));
        assert!(!raw.starts_with(b"SQLite format 3"));
        assert!(open(&path, &[2; 32]).is_err());
        let db = open(&path, &[1; 32]).unwrap();
        let x: String = db.query_row("SELECT x FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(x, "secret-word");
        let v: String = db
            .query_row("PRAGMA cipher_version", [], |r| r.get(0))
            .unwrap();
        assert!(!v.is_empty());
    }
}
