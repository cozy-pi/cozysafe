//! Items inside an open vault: photos, videos, notes, recordings, files and tags.
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
//!
//! The vault index (`vault.db`, see [`crate::db`]) holds a copy of every `.meta` record
//! and is what lists and lookups read. An item exists while its `.meta` file does:
//! records are written to the file first and the index second, deleted from the file
//! first, and [`OpenVault::sync_index`] brings the index back in line on every unlock.

use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;

use cs_crypto::{stream, wrap, Key};
use serde::{Deserialize, Serialize};

use crate::{write_atomic, Error, OpenVault, Result};

const ITEMS_DIR: &str = "items";

/// What Dart sees about an item. No key material. Names follow docs/naming.md.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ItemMeta {
    pub id: String,
    /// One of [`kind`]: photo, video, note, audio, file, tag.
    pub kind: String,
    pub name: String,
    pub mime: String,
    pub created_ms: i64,
    /// Size of the content in bytes (the encrypted file is a little larger).
    pub size_bytes: u64,
    /// When it was moved to Recently deleted; `None` for items in the vault.
    pub deleted_ms: Option<i64>,
    /// Length of a video or a recording, when known.
    pub duration_ms: Option<i64>,
    /// The tags (ids of items of kind `tag`) this item carries; empty for tags.
    pub tag_ids: Vec<String>,
    /// Marked as a favourite: shown first, and in Favourites on the home page.
    pub is_favorite: bool,
    /// Last change to the item (its content, name, tags…); its creation time for items
    /// not changed since the index came (0.1.31).
    pub modified_ms: i64,
}

/// The item kinds. Use these, never the string literals.
pub mod kind {
    pub const PHOTO: &str = "photo";
    pub const VIDEO: &str = "video";
    pub const NOTE: &str = "note";
    pub const AUDIO: &str = "audio";
    pub const FILE: &str = "file";
    /// A tag ("group" in the app): an item with a name and no content, so it is
    /// encrypted, backed up and restored like everything else.
    pub const TAG: &str = "tag";
    /// Format 1 only: folders, read back as tags (see `ItemRecord`).
    pub(crate) const LEGACY_FOLDER: &str = "folder";
}

/// How long Recently deleted keeps an item.
pub const TRASH_DAYS: i64 = 30;
const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// Current layout of `ItemRecord`.
const RECORD_FORMAT: u32 = 2;

fn format_1() -> u32 {
    1
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// One item's metadata, sealed in `<item>.meta` (and copied into the index).
///
/// Format 1 (0.1.0–0.1.6) wrote `size`, `has_thumb`, and folders: items of kind
/// `folder` with `color`/`space`, and `folder` on what was inside. Format 2 reads all
/// of that: the old names are aliases, a folder becomes a tag and an item in it carries
/// that tag (nested folders become separate tags). Records are rewritten in format 2
/// the next time they change; nothing is converted in bulk.
#[derive(Clone, Serialize, Deserialize)]
struct ItemRecord {
    #[serde(default = "format_1")]
    format: u32,
    kind: String,
    name: String,
    mime: String,
    created_ms: i64,
    #[serde(alias = "size")]
    size_bytes: u64,
    #[serde(alias = "has_thumb")]
    has_thumbnail: bool,
    wrapped_dek: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    deleted_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tag_ids: Vec<String>,
    /// Added in format 2 (0.1.31) without raising it: absent means no, and older apps
    /// ignore it (no `deny_unknown_fields`), so records stay readable both ways.
    #[serde(default, skip_serializing_if = "is_false")]
    is_favorite: bool,
    /// Also additive in format 2 (0.1.31); absent means "not changed since created".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    modified_ms: Option<i64>,
    /// Format 1: the folder the item was in. Read, never written.
    #[serde(default, rename = "folder", skip_serializing)]
    legacy_folder_id: Option<String>,
}

impl ItemRecord {
    /// Bring a format-1 record up to date in memory.
    fn upgraded(mut self) -> Self {
        if self.kind == kind::LEGACY_FOLDER {
            self.kind = kind::TAG.to_owned();
        } else if let Some(f) = self.legacy_folder_id.take() {
            if !self.tag_ids.contains(&f) {
                self.tag_ids.push(f);
            }
        }
        if self.kind == kind::TAG {
            self.tag_ids.clear();
        }
        self.legacy_folder_id = None;
        self.format = RECORD_FORMAT;
        self
    }
}

/// Milliseconds spent in each step of adding an item: reading and encrypting the
/// content, making it durable on disk, sealing the thumbnail, writing the record and
/// the index row.
#[derive(Clone, Copy, Debug, Default)]
pub struct AddTimings {
    pub encrypt_ms: u32,
    pub sync_ms: u32,
    pub thumbnail_ms: u32,
    pub record_ms: u32,
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
        self.add_item_timed(new).map(|(m, _)| m)
    }

    /// [`Self::add_item`], and how long each step took (for the app's Debug page).
    pub fn add_item_timed<R: Read>(&self, new: NewItem<'_, R>) -> Result<(ItemMeta, AddTimings)> {
        let mut t = AddTimings::default();
        let mut clock = std::time::Instant::now();
        let mut lap = |slot: &mut u32| {
            *slot = clock.elapsed().as_millis() as u32;
            clock = std::time::Instant::now();
        };
        fs::create_dir_all(self.items_dir())?;
        let id = hex::encode(cs_crypto::generate_salt());
        let dek = Key::generate();

        let data_path = self.path(&id, "data")?;
        let tmp = data_path.with_extension("data.tmp");
        let size_bytes = {
            let mut f = fs::File::create(&tmp)?;
            let n = stream::encrypt(&dek, &self.item_aad(&id, "data"), new.content, &mut f)?;
            lap(&mut t.encrypt_ms);
            f.sync_all()?;
            n
        };
        fs::rename(&tmp, &data_path)?;
        lap(&mut t.sync_ms);

        if let Some(thumbnail) = new.thumbnail {
            let sealed = wrap::seal(&dek, thumbnail, &self.item_aad(&id, "thumb"));
            write_atomic(&self.path(&id, "thumb")?, &sealed)?;
        }
        lap(&mut t.thumbnail_ms);

        let record = ItemRecord {
            format: RECORD_FORMAT,
            kind: new.kind.to_owned(),
            name: new.name.to_owned(),
            mime: new.mime.to_owned(),
            created_ms: new.created_ms,
            size_bytes,
            has_thumbnail: new.thumbnail.is_some(),
            deleted_ms: None,
            duration_ms: None,
            tag_ids: Vec::new(),
            is_favorite: false,
            modified_ms: None,
            legacy_folder_id: None,
            wrapped_dek: hex::encode(wrap::wrap_key(
                &self.master_key,
                &dek,
                &self.item_aad(&id, "dek"),
            )),
        };
        let record = self.write_record(&id, &record)?;
        lap(&mut t.record_ms);
        Ok((meta(id, record), t))
    }

    /// Replace an item's content and name (editing a note). Same item, same key; the
    /// new content is encrypted with a fresh nonce prefix and swapped in atomically.
    pub fn replace_item<R: Read>(&self, id: &str, name: &str, content: R) -> Result<ItemMeta> {
        let (mut record, dek) = self.record_and_key(id)?;
        let data_path = self.path(id, "data")?;
        let tmp = data_path.with_extension("data.tmp");
        let size_bytes = {
            let mut f = fs::File::create(&tmp)?;
            let n = stream::encrypt(&dek, &self.item_aad(id, "data"), content, &mut f)?;
            f.sync_all()?;
            n
        };
        fs::rename(&tmp, &data_path)?;
        record.size_bytes = size_bytes;
        record.name = name.to_owned();
        let record = self.write_record(id, &record)?;
        Ok(meta(id.to_owned(), record))
    }

    /// Seal `record` into the item's `.meta` file, then into the index. Returns the
    /// record as stored (with its modification time). A new item's record is created
    /// unchanged: `modified_ms` stays empty until its first change.
    fn write_record(&self, id: &str, record: &ItemRecord) -> Result<ItemRecord> {
        let mut record = record.clone();
        if self.index.sealed_record(id)?.is_some() || self.path(id, "meta")?.exists() {
            record.modified_ms = Some(now_ms());
        }
        let json = serde_json::to_vec(&record).expect("serialisable");
        let sealed = wrap::seal(&self.master_key, &json, &self.item_aad(id, "meta"));
        write_atomic(&self.path(id, "meta")?, &sealed)?;
        self.index.upsert(id, &columns(&record), &sealed)?;
        Ok(record)
    }

    /// Bring the index in line with the `.meta` files: add what it misses (vaults from
    /// before the index, restored backups, an app stopped between the two writes) and
    /// drop what no longer exists. Reads only file names unless something is missing.
    pub(crate) fn sync_index(&self) -> Result<()> {
        let mut on_disk = std::collections::HashSet::new();
        match fs::read_dir(self.items_dir()) {
            Ok(dir) => {
                for entry in dir {
                    let name = entry?.file_name().to_string_lossy().into_owned();
                    if let Some(id) = name.strip_suffix(".meta") {
                        on_disk.insert(id.to_owned());
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let indexed = self.index.ids()?;
        if on_disk == indexed {
            return Ok(());
        }
        self.index.transaction(|| {
            for id in indexed.difference(&on_disk) {
                self.index.remove(id)?;
            }
            for id in on_disk.difference(&indexed) {
                let Ok(sealed) = fs::read(self.path(id, "meta")?) else {
                    continue;
                };
                // Damaged entries are skipped, not fatal (as listing always did).
                if let Ok(record) = self.open_record(id, &sealed) {
                    self.index.upsert(id, &columns(&record), &sealed)?;
                }
            }
            Ok(())
        })
    }

    fn open_record(&self, id: &str, sealed: &[u8]) -> Result<ItemRecord> {
        let json = wrap::open(&self.master_key, sealed, &self.item_aad(id, "meta"))?;
        serde_json::from_slice::<ItemRecord>(&json)
            .map(ItemRecord::upgraded)
            .map_err(|_| Error::Corrupt("item meta"))
    }

    /// Move an item to Recently deleted. Still encrypted, still in the vault.
    pub fn trash_item(&self, id: &str, now_ms: i64) -> Result<()> {
        let mut record = self.record(id)?;
        record.deleted_ms = Some(now_ms);
        self.write_record(id, &record).map(|_| ())
    }

    /// A new tag with no items yet.
    pub fn create_tag(&self, name: &str, created_ms: i64) -> Result<ItemMeta> {
        self.add_item(NewItem {
            kind: kind::TAG,
            name,
            mime: "",
            created_ms,
            content: std::io::empty(),
            thumbnail: None,
        })
    }

    /// Rename a tag.
    pub fn rename_tag(&self, tag_id: &str, name: &str) -> Result<ItemMeta> {
        let mut record = self.tag_record(tag_id)?;
        record.name = name.to_owned();
        self.write_record(tag_id, &record)?;
        Ok(meta(tag_id.to_owned(), record))
    }

    /// Put `tag_id` on an item (`tagged`) or take it off. Tags cannot carry tags.
    pub fn set_tag(&self, item_id: &str, tag_id: &str, tagged: bool) -> Result<()> {
        self.tag_record(tag_id)?;
        let mut record = self.record(item_id)?;
        if record.kind == kind::TAG {
            return Err(Error::NoSuchItem);
        }
        if record.tag_ids.iter().any(|t| t == tag_id) == tagged {
            return Ok(());
        }
        if tagged {
            record.tag_ids.push(tag_id.to_owned());
        } else {
            record.tag_ids.retain(|t| t != tag_id);
        }
        self.write_record(item_id, &record).map(|_| ())
    }

    /// Delete a tag. It comes off every item; no item is deleted.
    pub fn delete_tag(&self, tag_id: &str) -> Result<()> {
        self.tag_record(tag_id)?;
        for m in self.all_items()? {
            if m.tag_ids.iter().any(|t| t == tag_id) {
                let mut r = self.record(&m.id)?;
                r.tag_ids.retain(|t| t != tag_id);
                self.write_record(&m.id, &r)?;
            }
        }
        self.delete_item(tag_id)
    }

    fn tag_record(&self, tag_id: &str) -> Result<ItemRecord> {
        let r = self.record(tag_id)?;
        if r.kind != kind::TAG {
            return Err(Error::NoSuchItem);
        }
        Ok(r)
    }

    /// Rename an item (a recording, a file); its content is untouched.
    pub fn rename_item(&self, id: &str, name: &str) -> Result<ItemMeta> {
        let mut record = self.record(id)?;
        record.name = name.to_owned();
        let record = self.write_record(id, &record)?;
        Ok(meta(id.to_owned(), record))
    }

    /// Mark or unmark an item as a favourite.
    pub fn set_favorite(&self, id: &str, is_favorite: bool) -> Result<()> {
        let mut record = self.record(id)?;
        record.is_favorite = is_favorite;
        self.write_record(id, &record).map(|_| ())
    }

    /// Record a video's or a recording's length (measured by the app).
    pub fn set_duration(&self, id: &str, duration_ms: i64) -> Result<()> {
        let mut record = self.record(id)?;
        record.duration_ms = Some(duration_ms);
        self.write_record(id, &record).map(|_| ())
    }

    /// Bring an item back from Recently deleted.
    pub fn restore_item(&self, id: &str) -> Result<()> {
        let mut record = self.record(id)?;
        record.deleted_ms = None;
        self.write_record(id, &record).map(|_| ())
    }

    /// Items in Recently deleted, most recently deleted first.
    pub fn trashed(&self) -> Result<Vec<ItemMeta>> {
        self.listed(true)
    }

    /// Delete for good what has been in Recently deleted for 30 days. Returns how many.
    pub fn purge_expired(&self, now_ms: i64) -> Result<usize> {
        let mut n = 0;
        for m in self.trashed()? {
            if m.deleted_ms
                .is_some_and(|d| now_ms - d >= TRASH_DAYS * DAY_MS)
            {
                self.delete_item(&m.id)?;
                n += 1;
            }
        }
        Ok(n)
    }

    /// Items in the vault (not in Recently deleted), newest first.
    pub fn items(&self) -> Result<Vec<ItemMeta>> {
        self.listed(false)
    }

    /// Every item, including Recently deleted.
    fn all_items(&self) -> Result<Vec<ItemMeta>> {
        let mut out = self.listed(false)?;
        out.extend(self.listed(true)?);
        Ok(out)
    }

    /// One read of the index, then each sealed record opened in memory. Damaged
    /// entries are skipped, not fatal.
    fn listed(&self, deleted: bool) -> Result<Vec<ItemMeta>> {
        Ok(self
            .index
            .rows(deleted)?
            .into_iter()
            .filter_map(|row| {
                let record = self.open_record(&row.id, &row.sealed_record).ok()?;
                Some(meta(row.id, record))
            })
            .collect())
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
        if !record.has_thumbnail {
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
        // The file decides that the item exists: it goes first, the index row second.
        fs::remove_file(meta_path)?;
        self.index.remove(id)?;
        for ext in ["data", "thumb"] {
            match fs::remove_file(self.path(id, ext)?) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
                _ => {}
            }
        }
        Ok(())
    }

    fn record(&self, id: &str) -> Result<ItemRecord> {
        self.path(id, "meta")?; // rejects ids that are not ours
        match self.index.sealed_record(id)? {
            Some(sealed) => self.open_record(id, &sealed),
            None => Err(Error::NoSuchItem),
        }
    }

    fn record_and_key(&self, id: &str) -> Result<(ItemRecord, Key)> {
        let record = self.record(id)?;
        let wrapped = hex::decode(&record.wrapped_dek).map_err(|_| Error::Corrupt("item key"))?;
        let dek = wrap::unwrap_key(&self.master_key, &wrapped, &self.item_aad(id, "dek"))?;
        Ok((record, dek))
    }
}

/// The index's plain columns for a record.
fn columns(r: &ItemRecord) -> crate::db::Columns {
    crate::db::Columns {
        created_ms: r.created_ms,
        modified_ms: r.modified_ms.unwrap_or(r.created_ms),
        deleted_ms: r.deleted_ms,
        size_bytes: r.size_bytes,
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn meta(id: String, r: ItemRecord) -> ItemMeta {
    ItemMeta {
        modified_ms: r.modified_ms.unwrap_or(r.created_ms),
        id,
        kind: r.kind,
        name: r.name,
        mime: r.mime,
        created_ms: r.created_ms,
        size_bytes: r.size_bytes,
        deleted_ms: r.deleted_ms,
        duration_ms: r.duration_ms,
        tag_ids: r.tag_ids,
        is_favorite: r.is_favorite,
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
            kind: kind::PHOTO,
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
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        let big = vec![7u8; 200_000];
        let a = v.add_item(photo(&big, 1)).unwrap();
        let b = v.add_item(photo(b"second", 2)).unwrap();

        // After a restart the items are still there, newest first.
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
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
        let lib = Library::open_or_create(tmp.path(), FAST, crate::tests::sk()).unwrap();
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
    fn notes_can_be_edited_in_place() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        let n = v
            .add_item(NewItem {
                kind: kind::NOTE,
                name: "Wifi",
                mime: "text/plain",
                created_ms: 1,
                content: &b"first"[..],
                thumbnail: None,
            })
            .unwrap();
        let edited = v
            .replace_item(&n.id, "Wifi home", &b"second version"[..])
            .unwrap();
        assert_eq!(
            (edited.id.as_str(), edited.name.as_str(), edited.size_bytes),
            (n.id.as_str(), "Wifi home", 14)
        );
        let mut out = Vec::new();
        v.read_item(&n.id, &mut out).unwrap();
        assert_eq!(out, b"second version");
        assert_eq!(v.items().unwrap().len(), 1);
    }

    #[test]
    fn rejects_path_like_ids() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        for bad in ["../header", "", "zz", "../../library.json"] {
            assert!(matches!(v.delete_item(bad), Err(Error::NoSuchItem)));
        }
    }

    #[test]
    fn recently_deleted() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("V", PW)
            .unwrap();
        let a = v.add_item(photo(b"a", 1)).unwrap();
        let b = v.add_item(photo(b"b", 2)).unwrap();
        v.trash_item(&a.id, 1_000).unwrap();
        assert_eq!(
            v.items().unwrap().iter().map(|m| &m.id).collect::<Vec<_>>(),
            vec![&b.id]
        );
        assert_eq!(v.trashed().unwrap()[0].deleted_ms, Some(1_000));
        v.restore_item(&a.id).unwrap();
        assert_eq!(v.items().unwrap().len(), 2);
        v.trash_item(&a.id, 1_000).unwrap();
        // Not yet 30 days: kept. After: gone for good.
        assert_eq!(
            v.purge_expired(1_000 + (TRASH_DAYS * DAY_MS) - 1).unwrap(),
            0
        );
        assert_eq!(v.purge_expired(1_000 + TRASH_DAYS * DAY_MS).unwrap(), 1);
        assert!(v.trashed().unwrap().is_empty());
        assert!(matches!(v.read_thumbnail(&a.id), Err(Error::NoSuchItem)));
    }

    #[test]
    fn tags() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("V", PW)
            .unwrap();
        let papers = v.create_tag("Giấy tờ", 1).unwrap();
        let passport = v.create_tag("Hộ chiếu", 2).unwrap();
        let p = v.add_item(photo(b"p", 3)).unwrap();
        v.set_tag(&p.id, &papers.id, true).unwrap();
        v.set_tag(&p.id, &passport.id, true).unwrap();
        v.set_tag(&p.id, &passport.id, true).unwrap(); // twice is once
        let find = |id: &str| v.items().unwrap().into_iter().find(|m| m.id == id).unwrap();
        assert_eq!(
            find(&p.id).tag_ids,
            vec![papers.id.clone(), passport.id.clone()]
        );
        assert_eq!(find(&papers.id).kind, kind::TAG);
        // Only tags can be put on items, and tags carry none.
        assert!(matches!(
            v.set_tag(&p.id, &p.id, true),
            Err(Error::NoSuchItem)
        ));
        assert!(matches!(
            v.set_tag(&papers.id, &passport.id, true),
            Err(Error::NoSuchItem)
        ));
        v.rename_tag(&passport.id, "Visa").unwrap();
        assert_eq!(find(&passport.id).name, "Visa");
        v.set_tag(&p.id, &papers.id, false).unwrap();
        assert_eq!(find(&p.id).tag_ids, vec![passport.id.clone()]);
        // Deleting a tag never deletes what carried it.
        v.delete_tag(&passport.id).unwrap();
        assert!(find(&p.id).tag_ids.is_empty());
        assert!(v.items().unwrap().iter().all(|m| m.id != passport.id));
    }

    /// Records written by 0.1.0–0.1.6 (format 1) still read: folders become tags.
    #[test]
    fn reads_format_1_records() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("V", PW)
            .unwrap();
        // A real item, so its key unwraps; its record is then overwritten in format 1.
        let real = v.add_item(photo(b"p", 3)).unwrap();
        let wrapped = v.record(&real.id).unwrap().wrapped_dek;
        let write_v1 = |id: &str, json: &str| {
            let sealed = wrap::seal(&v.master_key, json.as_bytes(), &v.item_aad(id, "meta"));
            write_atomic(&v.path(id, "meta").unwrap(), &sealed).unwrap();
        };
        let folder = "a".repeat(32);
        let sub = "b".repeat(32);
        write_v1(
            &folder,
            r#"{"kind":"folder","name":"Giấy tờ","mime":"","created_ms":1,"size":0,"has_thumb":false,"wrapped_dek":"00","color":"amber","space":"file"}"#,
        );
        write_v1(
            &sub,
            &format!(
                r#"{{"kind":"folder","name":"Hộ chiếu","mime":"","created_ms":2,"size":0,"has_thumb":false,"wrapped_dek":"00","folder":"{folder}","color":"blue"}}"#
            ),
        );
        write_v1(
            &real.id,
            &format!(
                r#"{{"kind":"photo","name":"IMG.jpg","mime":"image/jpeg","created_ms":3,"size":42,"has_thumb":true,"wrapped_dek":"{wrapped}","folder":"{sub}","duration_ms":5}}"#
            ),
        );
        // As a vault from before the index: no rows yet, built from the files on unlock.
        for id in v.index.ids().unwrap() {
            v.index.remove(&id).unwrap();
        }
        v.sync_index().unwrap();
        let items = v.items().unwrap();
        let get = |id: &str| items.iter().find(|m| m.id == id).unwrap();
        assert_eq!(get(&folder).kind, kind::TAG);
        assert!(get(&folder).tag_ids.is_empty());
        assert_eq!(get(&sub).kind, kind::TAG); // a nested folder is a tag of its own
        assert_eq!(get(&real.id).tag_ids, vec![sub.clone()]);
        assert_eq!(
            (get(&real.id).size_bytes, get(&real.id).duration_ms),
            (42, Some(5))
        );
        assert_eq!(v.read_thumbnail(&real.id).unwrap().unwrap(), b"thumb");
        // Rewritten in format 2 when it changes.
        v.rename_item(&real.id, "IMG2.jpg").unwrap();
        let sealed = fs::read(v.path(&real.id, "meta").unwrap()).unwrap();
        let json = wrap::open(&v.master_key, &sealed, &v.item_aad(&real.id, "meta")).unwrap();
        let text = String::from_utf8(json.to_vec()).unwrap();
        assert!(text.contains(r#""format":2"#));
        assert!(text.contains(r#""size_bytes":42"#) && text.contains(r#""has_thumbnail":true"#));
        assert!(text.contains(r#""tag_ids""#) && !text.contains(r#""folder""#));
    }

    #[test]
    fn favourite_is_stored_and_old_records_read_as_not() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        let it = v.add_item(photo(b"x", 1)).unwrap();
        assert!(!v.items().unwrap()[0].is_favorite);
        v.set_favorite(&it.id, true).unwrap();
        assert!(v.items().unwrap()[0].is_favorite);
        v.set_favorite(&it.id, false).unwrap();
        assert!(!v.items().unwrap()[0].is_favorite);
        // A record as 0.1.30 wrote it (no is_favorite) reads as not a favourite.
        let old: ItemRecord = serde_json::from_str(
            r#"{"format":2,"kind":"note","name":"n","mime":"text/plain","created_ms":1,
                "size_bytes":1,"has_thumbnail":false,"wrapped_dek":"x"}"#,
        )
        .unwrap();
        assert!(!old.is_favorite);
    }

    #[test]
    fn the_index_follows_the_files() {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open_or_create(tmp.path(), FAST, crate::tests::sk()).unwrap();
        let v = lib.create_vault("A", PW).unwrap();
        let a = v.add_item(photo(b"a", 1)).unwrap();
        let b = v.add_item(photo(b"b", 2)).unwrap();
        v.rename_item(&a.id, "renamed.jpg").unwrap();
        let renamed = v
            .items()
            .unwrap()
            .into_iter()
            .find(|m| m.id == a.id)
            .unwrap();
        assert!(
            renamed.modified_ms > renamed.created_ms,
            "a change sets modified_ms"
        );
        // The index is lost: the next unlock builds it again from the .meta files.
        drop(v);
        let db = tmp.path().join(crate::VAULTS_DIR);
        let vault_dir = fs::read_dir(&db).unwrap().next().unwrap().unwrap().path();
        fs::remove_file(vault_dir.join(crate::db::INDEX_FILE)).unwrap();
        let v = lib.unlock(PW).unwrap().unwrap();
        let names: Vec<_> = v.items().unwrap().into_iter().map(|m| m.name).collect();
        assert_eq!(names, vec!["IMG.jpg", "renamed.jpg"]);
        // A .meta file gone (the app stopped mid-delete): its row goes too.
        fs::remove_file(v.path(&b.id, "meta").unwrap()).unwrap();
        drop(v);
        let v = lib.unlock(PW).unwrap().unwrap();
        assert_eq!(v.items().unwrap().len(), 1);
    }
}
