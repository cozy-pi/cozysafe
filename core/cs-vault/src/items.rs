//! Items inside an open vault (photos now; notes and files use the same layout).
//!
//! ```text
//! items/<item>.meta   ItemRecord sealed with the Master Key (kind, name, size, wrapped DEK)
//! items/<item>.data   content, STREAM-encrypted with the item's own random key (DEK)
//! items/<item>.thumb  optional small preview, sealed with the same DEK
//! ```
//!
//! Every blob's associated data names the vault, the item and the blob's role, so
//! nothing can be swapped between items or vaults. The `.meta` file is written last:
//! an item exists only once its content is fully on disk.

use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;

use cs_crypto::{stream, wrap, Key};
use serde::{Deserialize, Serialize};

use crate::{write_atomic, Error, OpenVault, Result};

const ITEMS_DIR: &str = "items";

/// What Dart sees about an item. No key material.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ItemMeta {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub mime: String,
    pub created_ms: i64,
    pub size: u64,
}

#[derive(Serialize, Deserialize)]
struct ItemRecord {
    kind: String,
    name: String,
    mime: String,
    created_ms: i64,
    size: u64,
    has_thumb: bool,
    wrapped_dek: String,
}

/// Content to store as a new item.
pub struct NewItem<'a, R: Read> {
    pub kind: &'a str,
    pub name: &'a str,
    pub mime: &'a str,
    pub created_ms: i64,
    pub content: R,
    pub thumbnail: Option<&'a [u8]>,
}

impl OpenVault {
    fn items_dir(&self) -> PathBuf {
        self.dir.join(ITEMS_DIR)
    }

    fn item_aad(&self, item: &str, role: &str) -> Vec<u8> {
        crate::aad(&self.id, &format!("item/{item}/{role}"))
    }

    fn path(&self, item: &str, ext: &str) -> Result<PathBuf> {
        // Item IDs come back from Dart: accept only our own format (no path tricks).
        if item.len() != 32 || !item.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::NoSuchItem);
        }
        Ok(self.items_dir().join(format!("{item}.{ext}")))
    }

    /// Encrypt and store a new item; returns its metadata.
    pub fn add_item<R: Read>(&self, new: NewItem<'_, R>) -> Result<ItemMeta> {
        fs::create_dir_all(self.items_dir())?;
        let id = hex::encode(cs_crypto::generate_salt());
        let dek = Key::generate();

        let data_path = self.path(&id, "data")?;
        let tmp = data_path.with_extension("data.tmp");
        let size = {
            let mut f = fs::File::create(&tmp)?;
            let n = stream::encrypt(&dek, &self.item_aad(&id, "data"), new.content, &mut f)?;
            f.sync_all()?;
            n
        };
        fs::rename(&tmp, &data_path)?;

        if let Some(thumb) = new.thumbnail {
            let sealed = wrap::seal(&dek, thumb, &self.item_aad(&id, "thumb"));
            write_atomic(&self.path(&id, "thumb")?, &sealed)?;
        }

        let record = ItemRecord {
            kind: new.kind.to_owned(),
            name: new.name.to_owned(),
            mime: new.mime.to_owned(),
            created_ms: new.created_ms,
            size,
            has_thumb: new.thumbnail.is_some(),
            wrapped_dek: hex::encode(wrap::wrap_key(
                &self.master_key,
                &dek,
                &self.item_aad(&id, "dek"),
            )),
        };
        let json = serde_json::to_vec(&record).expect("serialisable");
        let sealed = wrap::seal(&self.master_key, &json, &self.item_aad(&id, "meta"));
        write_atomic(&self.path(&id, "meta")?, &sealed)?;
        Ok(meta(id, record))
    }

    /// All items, newest first. Damaged entries are skipped, not fatal.
    pub fn items(&self) -> Result<Vec<ItemMeta>> {
        let dir = match fs::read_dir(self.items_dir()) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let mut out = Vec::new();
        for entry in dir {
            let name = entry?.file_name().to_string_lossy().into_owned();
            let Some(id) = name.strip_suffix(".meta") else {
                continue;
            };
            if let Ok(record) = self.record(id) {
                out.push(meta(id.to_owned(), record));
            }
        }
        out.sort_by(|a, b| b.created_ms.cmp(&a.created_ms).then(a.id.cmp(&b.id)));
        Ok(out)
    }

    /// Decrypt an item's content into `out`. On error, discard what was written.
    pub fn read_item<W: Write>(&self, id: &str, out: W) -> Result<u64> {
        let (_, dek) = self.record_and_key(id)?;
        let f = fs::File::open(self.path(id, "data")?)?;
        Ok(stream::decrypt(&dek, &self.item_aad(id, "data"), f, out)?)
    }

    /// The decrypted preview, if the item has one.
    pub fn read_thumbnail(&self, id: &str) -> Result<Option<Vec<u8>>> {
        let (record, dek) = self.record_and_key(id)?;
        if !record.has_thumb {
            return Ok(None);
        }
        let sealed = fs::read(self.path(id, "thumb")?)?;
        let plain = wrap::open(&dek, &sealed, &self.item_aad(id, "thumb"))?;
        Ok(Some(plain.to_vec()))
    }

    /// Remove an item. The metadata goes first, so a crash midway never shows half an item.
    pub fn delete_item(&self, id: &str) -> Result<()> {
        let meta_path = self.path(id, "meta")?;
        if !meta_path.exists() {
            return Err(Error::NoSuchItem);
        }
        fs::remove_file(meta_path)?;
        for ext in ["data", "thumb"] {
            match fs::remove_file(self.path(id, ext)?) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
                _ => {}
            }
        }
        Ok(())
    }

    fn record(&self, id: &str) -> Result<ItemRecord> {
        let sealed = match fs::read(self.path(id, "meta")?) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(Error::NoSuchItem),
            r => r?,
        };
        let json = wrap::open(&self.master_key, &sealed, &self.item_aad(id, "meta"))?;
        serde_json::from_slice(&json).map_err(|_| Error::Corrupt("item meta"))
    }

    fn record_and_key(&self, id: &str) -> Result<(ItemRecord, Key)> {
        let record = self.record(id)?;
        let wrapped = hex::decode(&record.wrapped_dek).map_err(|_| Error::Corrupt("item key"))?;
        let dek = wrap::unwrap_key(&self.master_key, &wrapped, &self.item_aad(id, "dek"))?;
        Ok((record, dek))
    }
}

fn meta(id: String, r: ItemRecord) -> ItemMeta {
    ItemMeta {
        id,
        kind: r.kind,
        name: r.name,
        mime: r.mime,
        created_ms: r.created_ms,
        size: r.size,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Library;
    use cs_crypto::kdf::KdfParams;

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    const PW: &str = "orange kettle whispers at dawn 77";

    fn photo<'a>(content: &'a [u8], created_ms: i64) -> NewItem<'a, &'a [u8]> {
        NewItem {
            kind: "photo",
            name: "IMG.jpg",
            mime: "image/jpeg",
            created_ms,
            content,
            thumbnail: Some(b"thumb"),
        }
    }

    #[test]
    fn add_list_read_delete() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST)
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        let big = vec![7u8; 200_000];
        let a = v.add_item(photo(&big, 1)).unwrap();
        let b = v.add_item(photo(b"second", 2)).unwrap();

        // After a restart the items are still there, newest first.
        let v = Library::open_or_create(tmp.path(), FAST)
            .unwrap()
            .unlock(PW)
            .unwrap()
            .unwrap();
        let ids: Vec<_> = v.items().unwrap().into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec![b.id.clone(), a.id.clone()]);

        let mut out = Vec::new();
        v.read_item(&a.id, &mut out).unwrap();
        assert_eq!(out, big);
        assert_eq!(v.read_thumbnail(&a.id).unwrap().unwrap(), b"thumb");

        v.delete_item(&a.id).unwrap();
        assert_eq!(v.items().unwrap().len(), 1);
        assert!(matches!(
            v.read_item(&a.id, Vec::new()),
            Err(Error::NoSuchItem)
        ));
    }

    #[test]
    fn nothing_readable_on_disk_and_no_cross_vault_reads() {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open_or_create(tmp.path(), FAST).unwrap();
        let a = lib.create_vault("A", PW).unwrap();
        let b = lib
            .create_vault("B", "mây tháng mười rơi trên phố cổ")
            .unwrap();
        let secret = b"PLAINTEXT-MARKER-0123456789";
        let item = a.add_item(photo(secret, 1)).unwrap();

        for e in fs::read_dir(a.items_dir()).unwrap() {
            let bytes = fs::read(e.unwrap().path()).unwrap();
            assert!(!bytes.windows(secret.len()).any(|w| w == secret));
            assert!(!bytes.windows(5).any(|w| w == b"photo"));
        }
        // Vault B cannot open A's item even if pointed at it.
        assert!(b.read_item(&item.id, Vec::new()).is_err());
    }

    #[test]
    fn rejects_path_like_ids() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST)
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        for bad in ["../header", "", "zz", "../../library.json"] {
            assert!(matches!(v.delete_item(bad), Err(Error::NoSuchItem)));
        }
    }
}
