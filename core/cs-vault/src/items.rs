//! Items inside an open vault: photos, videos, notes, recordings, files and tags.
//!
//! ```text
//! items/<bucket>/<item>.meta   ItemRecord sealed with the Master Key (kind, name, size,
//!                              wrapped DEK)
//! items/<bucket>/<item>.data   content, STREAM-encrypted with the item's own random key
//! items/<bucket>/<item>.thumb  optional small preview, sealed with the same DEK
//! ```
//!
//! `<bucket>` is the last two hex digits of the item's id ([`crate::bucket_of`]), so no
//! folder holds more than about 1/256 of the items. Versions up to 0.1.57 kept every
//! file flat in `items/`; opening the vault moves them (`move_into_buckets`), and until
//! that is done a file is read from either place.
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
/// The files of an item, by extension.
pub(crate) const ITEM_EXTS: [&str; 3] = ["meta", "data", "thumb"];
/// Index meta: the files of versions up to 0.1.57 are in their buckets.
pub(crate) const BUCKETS_DONE: &str = "items-in-buckets";

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

fn is_zero(n: &i64) -> bool {
    *n == 0
}

/// One item's metadata, sealed in `<item>.meta` (and copied into the index).
///
/// Format 1 (0.1.0–0.1.6) wrote `size`, `has_thumb`, and folders: items of kind
/// `folder` with `color`/`space`, and `folder` on what was inside. Format 2 reads all
/// of that: the old names are aliases, a folder becomes a tag and an item in it carries
/// that tag (nested folders become separate tags). Records are rewritten in format 2
/// the next time they change; nothing is converted in bulk.
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ItemRecord {
    #[serde(default = "format_1")]
    pub(crate) format: u32,
    pub(crate) kind: String,
    pub(crate) name: String,
    pub(crate) mime: String,
    pub(crate) created_ms: i64,
    #[serde(alias = "size")]
    pub(crate) size_bytes: u64,
    #[serde(alias = "has_thumb")]
    pub(crate) has_thumbnail: bool,
    pub(crate) wrapped_dek: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) deleted_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) tag_ids: Vec<String>,
    /// Added in format 2 (0.1.31) without raising it: absent means no, and older apps
    /// ignore it (no `deny_unknown_fields`), so records stay readable both ways.
    #[serde(default, skip_serializing_if = "is_false")]
    pub(crate) is_favorite: bool,
    /// Also additive in format 2 (0.1.31); absent means "not changed since created".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) modified_ms: Option<i64>,
    /// Sync (docs/adr/0003-sync.md), additive like the two above. This revision, the one
    /// it was made from, the hybrid logical clock and the device that wrote it, and the
    /// revision whose content (`.data`, `.thumb`) it has.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub(crate) rev: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) base_rev: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub(crate) hlc: i64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub(crate) device: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub(crate) data_rev: String,
    /// SHA-256 of the encrypted `.data` and `.thumb` files, sealed in the record: a sync
    /// place cannot hand back older content under a newer revision (same item key, so
    /// it would decrypt) without the check failing.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub(crate) data_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub(crate) thumb_hash: String,
    /// Format 1: the folder the item was in. Read, never written.
    #[serde(default, rename = "folder", skip_serializing)]
    legacy_folder_id: Option<String>,
}

impl ItemRecord {
    pub(crate) fn has_thumbnail(&self) -> bool {
        self.has_thumbnail
    }

    pub(crate) fn set_thumbnail(&mut self, has: bool) {
        self.has_thumbnail = has;
    }

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
    pub(crate) fn items_dir(&self) -> PathBuf {
        self.dir.join(ITEMS_DIR)
    }

    pub(crate) fn item_aad(&self, item: &str, role: &str) -> Vec<u8> {
        crate::aad(&self.id, &format!("item/{item}/{role}"))
    }

    /// Where the item's file is written: in its bucket.
    pub(crate) fn path(&self, item: &str, ext: &str) -> Result<PathBuf> {
        // Item IDs come back from Dart: accept only our own format (no path tricks).
        let name = crate::id_name(item).ok_or(Error::NoSuchItem)?;
        let bucket = crate::bucket_of(&name).ok_or(Error::NoSuchItem)?;
        Ok(self.items_dir().join(bucket).join(format!("{name}.{ext}")))
    }

    /// [`Self::path`], with its bucket made.
    pub(crate) fn new_path(&self, item: &str, ext: &str) -> Result<PathBuf> {
        let path = self.path(item, ext)?;
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        Ok(path)
    }

    /// Where versions up to 0.1.57 kept it: flat in `items/`.
    pub(crate) fn flat_path(&self, item: &str, ext: &str) -> Result<PathBuf> {
        let name = crate::id_name(item).ok_or(Error::NoSuchItem)?;
        Ok(self.items_dir().join(format!("{name}.{ext}")))
    }

    /// Where the item's file is read: its bucket, or flat in `items/` while the move into
    /// buckets is not finished (it stopped half-way).
    pub(crate) fn read_path(&self, item: &str, ext: &str) -> Result<PathBuf> {
        let path = self.path(item, ext)?;
        if !path.exists() {
            let flat = self.flat_path(item, ext)?;
            if flat.exists() {
                return Ok(flat);
            }
        }
        Ok(path)
    }

    /// Move the item files of versions up to 0.1.57 (flat in `items/`) into their
    /// buckets: one rename each, so a file is always in one place or the other and a
    /// move cut short goes on at the next open. A file already in its bucket is the
    /// newer one (written since): the flat copy goes. Done once, then remembered.
    pub(crate) fn move_into_buckets(&self) -> Result<()> {
        if self.index.meta_get(BUCKETS_DONE)?.as_deref() == Some("1") {
            return Ok(());
        }
        let mut flat = Vec::new();
        match fs::read_dir(self.items_dir()) {
            Ok(dir) => {
                for entry in dir {
                    let entry = entry?;
                    if !entry.file_type()?.is_file() {
                        continue;
                    }
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if let Some((item, ext)) = name.split_once('.') {
                        if ITEM_EXTS.contains(&ext) && crate::bucket_of(item).is_some() {
                            flat.push((item.to_owned(), ext.to_owned()));
                        }
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        // Content before records: an item whose record has moved has its content too.
        flat.sort_by(|a, b| (a.1 == "meta", &a.0).cmp(&(b.1 == "meta", &b.0)));
        for (item, ext) in flat {
            let (from, to) = (self.flat_path(&item, &ext)?, self.new_path(&item, &ext)?);
            if to.exists() {
                crate::remove_if_exists(&from)?;
            } else {
                fs::rename(&from, &to)?;
            }
        }
        self.index.meta_set(BUCKETS_DONE, "1")
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
        let id = hex::encode(cs_crypto::generate_salt());
        let dek = Key::generate();

        let data_path = self.new_path(&id, "data")?;
        let tmp = data_path.with_extension("data.tmp");
        let (size_bytes, data_hash) = {
            let mut f = Hashing::new(fs::File::create(&tmp)?);
            let n = stream::encrypt(&dek, &self.item_aad(&id, "data"), new.content, &mut f)?;
            lap(&mut t.encrypt_ms);
            f.inner.sync_all()?;
            (n, f.hex())
        };
        fs::rename(&tmp, &data_path)?;
        lap(&mut t.sync_ms);

        let mut thumb_hash = String::new();
        if let Some(thumbnail) = new.thumbnail {
            let sealed = wrap::seal(&dek, thumbnail, &self.item_aad(&id, "thumb"));
            write_atomic(&self.new_path(&id, "thumb")?, &sealed)?;
            thumb_hash = sha256_hex(&sealed);
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
            rev: String::new(),
            base_rev: None,
            hlc: 0,
            device: String::new(),
            data_rev: String::new(),
            data_hash,
            thumb_hash,
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
        let data_path = self.new_path(id, "data")?;
        let tmp = data_path.with_extension("data.tmp");
        let (size_bytes, data_hash) = {
            let mut f = Hashing::new(fs::File::create(&tmp)?);
            let n = stream::encrypt(&dek, &self.item_aad(id, "data"), content, &mut f)?;
            f.inner.sync_all()?;
            (n, f.hex())
        };
        fs::rename(&tmp, &data_path)?;
        record.size_bytes = size_bytes;
        record.data_hash = data_hash;
        record.name = name.to_owned();
        record.data_rev.clear(); // new content: this revision carries it
        let record = self.write_record(id, &record)?;
        Ok(meta(id.to_owned(), record))
    }

    /// Seal `record` into the item's `.meta` file, then into the index. Returns the
    /// record as stored (with its modification time). A new item's record is created
    /// unchanged: `modified_ms` stays empty until its first change.
    fn write_record(&self, id: &str, record: &ItemRecord) -> Result<ItemRecord> {
        let mut record = record.clone();
        if self.index.sealed_record(id)?.is_some() || self.read_path(id, "meta")?.exists() {
            record.modified_ms = Some(now_ms());
        }
        self.stamp(&mut record)?;
        self.store_record(id, &record)?;
        Ok(record)
    }

    /// A new revision of `record`, made here now. An empty `data_rev` means the content
    /// changed in this revision.
    pub(crate) fn stamp(&self, record: &mut ItemRecord) -> Result<()> {
        let rev = hex::encode(cs_crypto::generate_salt());
        record.base_rev = (!record.rev.is_empty()).then(|| std::mem::take(&mut record.rev));
        record.hlc = crate::sync::next_hlc(&self.index, record.hlc)?;
        record.device = crate::sync::device_id(&self.index)?;
        if record.data_rev.is_empty() {
            record.data_rev = rev.clone();
        }
        record.rev = rev;
        Ok(())
    }

    /// Seal `record` as it is into `.meta` and the index (no new revision).
    pub(crate) fn store_record(&self, id: &str, record: &ItemRecord) -> Result<Vec<u8>> {
        let json = serde_json::to_vec(record).expect("serialisable");
        let sealed = wrap::seal(&self.master_key, &json, &self.item_aad(id, "meta"));
        write_atomic(&self.new_path(id, "meta")?, &sealed)?;
        self.index.upsert(id, &columns(record), &sealed)?;
        Ok(sealed)
    }

    /// The sealed `.meta` bytes of an item, as stored.
    pub(crate) fn sealed_record(&self, id: &str) -> Result<Option<Vec<u8>>> {
        self.path(id, "meta")?;
        self.index.sealed_record(id)
    }

    /// Bring the index in line with the `.meta` files: add what it misses (vaults from
    /// before the index, restored backups, an app stopped between the two writes) and
    /// drop what no longer exists. Reads only file names unless something is missing.
    pub(crate) fn sync_index(&self) -> Result<()> {
        let mut on_disk = std::collections::HashSet::new();
        // The buckets, and flat in `items/` (a move into buckets cut short).
        let mut dirs = vec![self.items_dir()];
        while let Some(at) = dirs.pop() {
            let top = at == self.items_dir();
            match fs::read_dir(&at) {
                Ok(dir) => {
                    for entry in dir {
                        let entry = entry?;
                        let name = entry.file_name().to_string_lossy().into_owned();
                        if top && is_bucket(&name) && entry.file_type()?.is_dir() {
                            dirs.push(entry.path());
                        } else if let Some(id) = name.strip_suffix(".meta") {
                            on_disk.insert(id.to_owned());
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.into()),
            }
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
                let Ok(sealed) = fs::read(self.read_path(id, "meta")?) else {
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

    pub(crate) fn open_record(&self, id: &str, sealed: &[u8]) -> Result<ItemRecord> {
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
        let f = fs::File::open(self.read_path(id, "data")?)?;
        Ok(stream::decrypt(&dek, &self.item_aad(id, "data"), f, out)?)
    }

    /// The decrypted preview, if the item has one.
    pub fn read_thumbnail(&self, id: &str) -> Result<Option<Vec<u8>>> {
        let (record, dek) = self.record_and_key(id)?;
        if !record.has_thumbnail {
            return Ok(None);
        }
        let sealed = fs::read(self.read_path(id, "thumb")?)?;
        let plain = wrap::open(&dek, &sealed, &self.item_aad(id, "thumb"))?;
        Ok(Some(plain.to_vec()))
    }

    /// Remove an item. The metadata goes first, so a crash midway never shows half an item.
    /// The other devices hear of it at the next sync.
    pub fn delete_item(&self, id: &str) -> Result<()> {
        let (hlc, rev) = self.record(id).map(|r| (r.hlc, r.rev)).unwrap_or_default();
        self.remove_item(id)?;
        // Its last revision here is older than the deletion: a place drops it unread.
        self.index
            .add_gone(id, crate::sync::next_hlc(&self.index, hlc)?, &rev)
    }

    /// [`Self::delete_item`] without telling the other devices (a sync applying theirs).
    pub(crate) fn remove_item(&self, id: &str) -> Result<()> {
        if !self.read_path(id, "meta")?.exists() {
            return Err(Error::NoSuchItem);
        }
        // The file decides that the item exists: it goes first (from both places a move
        // into buckets cut short may have left it), the index row second.
        crate::remove_if_exists(&self.flat_path(id, "meta")?)?;
        crate::remove_if_exists(&self.path(id, "meta")?)?;
        self.index.remove(id)?;
        for ext in ["data", "thumb"] {
            crate::remove_if_exists(&self.path(id, ext)?)?;
            crate::remove_if_exists(&self.flat_path(id, ext)?)?;
        }
        Ok(())
    }

    pub(crate) fn record(&self, id: &str) -> Result<ItemRecord> {
        self.path(id, "meta")?; // rejects ids that are not ours
        match self.index.sealed_record(id)? {
            Some(sealed) => self.open_record(id, &sealed),
            None => Err(Error::NoSuchItem),
        }
    }

    fn record_and_key(&self, id: &str) -> Result<(ItemRecord, Key)> {
        let record = self.record(id)?;
        let dek = self.unwrap_dek(id, &record)?;
        Ok((record, dek))
    }

    /// The item's own content key, from its record.
    pub(crate) fn unwrap_dek(&self, id: &str, record: &ItemRecord) -> Result<Key> {
        let wrapped = hex::decode(&record.wrapped_dek).map_err(|_| Error::Corrupt("item key"))?;
        Ok(wrap::unwrap_key(
            &self.master_key,
            &wrapped,
            &self.item_aad(id, "dek"),
        )?)
    }
}

/// A bucket's name: two lowercase hex digits.
pub(crate) fn is_bucket(name: &str) -> bool {
    name.len() == 2 && name.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
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

/// Hex SHA-256 of some bytes.
pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    hex::encode(sha2::Sha256::digest(bytes))
}

/// Hex SHA-256 of a file, read in pieces.
pub(crate) fn file_sha256_hex(path: &std::path::Path) -> Result<String> {
    use sha2::Digest;
    let mut h = sha2::Sha256::new();
    let mut f = fs::File::open(path)?;
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex::encode(h.finalize()))
}

/// A writer that hashes what goes through it (the encrypted content, as written).
pub(crate) struct Hashing<W: Write> {
    pub(crate) inner: W,
    hash: sha2::Sha256,
}

impl<W: Write> Hashing<W> {
    pub(crate) fn new(inner: W) -> Self {
        use sha2::Digest;
        Hashing {
            inner,
            hash: sha2::Sha256::new(),
        }
    }

    pub(crate) fn hex(self) -> String {
        use sha2::Digest;
        hex::encode(self.hash.finalize())
    }
}

impl<W: Write> Write for Hashing<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        use sha2::Digest;
        let n = self.inner.write(buf)?;
        self.hash.update(&buf[..n]);
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
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

        let bucket = a
            .path(&item.id, "data")
            .unwrap()
            .parent()
            .unwrap()
            .to_owned();
        for e in fs::read_dir(bucket).unwrap() {
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
            write_atomic(&v.new_path(id, "meta").unwrap(), &sealed).unwrap();
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

    // ---------- buckets ----------

    /// Every item file of the vault: (folder name under items/, file name).
    fn files_of(v: &OpenVault) -> Vec<(String, String)> {
        let mut out = Vec::new();
        for e in fs::read_dir(v.items_dir()).unwrap().flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if e.path().is_dir() {
                for f in fs::read_dir(e.path()).unwrap().flatten() {
                    out.push((n.clone(), f.file_name().to_string_lossy().into_owned()));
                }
            } else {
                out.push((String::new(), n));
            }
        }
        out.sort();
        out
    }

    /// The layout of 0.1.57: every item file flat in items/ (the `take`-th first only).
    fn flatten(v: &OpenVault, take: usize) {
        let mut n = 0;
        for (b, f) in files_of(v) {
            if !b.is_empty() && n < take {
                fs::rename(v.items_dir().join(&b).join(&f), v.items_dir().join(&f)).unwrap();
                n += 1;
            }
        }
        v.index.meta_set(BUCKETS_DONE, "0").unwrap();
    }

    #[test]
    fn the_bucket_is_the_last_two_hex_digits_of_the_item_id() {
        let id = format!("{}c7", "0".repeat(30));
        assert_eq!(crate::bucket_of(&id), Some("c7"));
        for bad in [
            "",
            "c7",
            "../../00000000000000000000000000c7",
            &id.to_uppercase(),
        ] {
            assert_eq!(crate::bucket_of(bad), None, "{bad}");
        }
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        let item = v.add_item(photo(b"p", 1)).unwrap();
        let bucket = crate::bucket_of(&item.id).unwrap().to_owned();
        let want: Vec<(String, String)> = ["data", "meta", "thumb"]
            .iter()
            .map(|ext| (bucket.clone(), format!("{}.{ext}", item.id)))
            .collect();
        assert_eq!(files_of(&v), want);
    }

    #[test]
    fn files_of_earlier_versions_move_into_buckets_on_open() {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open_or_create(tmp.path(), FAST, crate::tests::sk()).unwrap();
        let v = lib.create_vault("A", PW).unwrap();
        let items: Vec<ItemMeta> = (0..6)
            .map(|i| {
                v.add_item(photo(format!("photo {i}").as_bytes(), i))
                    .unwrap()
            })
            .collect();
        let moved = files_of(&v);
        flatten(&v, usize::MAX);
        assert!(files_of(&v).iter().all(|(b, _)| b.is_empty()));
        drop(v);
        let v = lib.unlock(PW).unwrap().unwrap();
        assert_eq!(files_of(&v), moved);
        assert_eq!(v.items().unwrap().len(), 6);
        for (i, m) in items.iter().enumerate() {
            let mut out = Vec::new();
            v.read_item(&m.id, &mut out).unwrap();
            assert_eq!(out, format!("photo {i}").as_bytes());
        }
        assert_eq!(
            v.index.meta_get(BUCKETS_DONE).unwrap().as_deref(),
            Some("1")
        );
    }

    #[test]
    fn a_move_into_buckets_cut_short_goes_on_and_reads_meanwhile() {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open_or_create(tmp.path(), FAST, crate::tests::sk()).unwrap();
        let v = lib.create_vault("A", PW).unwrap();
        let items: Vec<ItemMeta> = (0..4)
            .map(|i| {
                v.add_item(photo(format!("photo {i}").as_bytes(), i))
                    .unwrap()
            })
            .collect();
        let all = files_of(&v);
        // Half the files back where 0.1.57 kept them, as if the move stopped half-way;
        // and one stale flat copy of a file that is also in its bucket.
        flatten(&v, all.len() / 2);
        let (b, f) = all.last().unwrap();
        fs::copy(v.items_dir().join(b).join(f), v.items_dir().join(f)).unwrap();
        let half = files_of(&v);
        assert!(half.iter().any(|(b, _)| b.is_empty()) && half.iter().any(|(b, _)| !b.is_empty()));
        // Meanwhile every item reads, lists and is deleted from either place.
        v.sync_index().unwrap();
        assert_eq!(v.items().unwrap().len(), 4);
        for (i, m) in items.iter().enumerate() {
            let mut out = Vec::new();
            v.read_item(&m.id, &mut out).unwrap();
            assert_eq!(out, format!("photo {i}").as_bytes());
            assert_eq!(v.read_thumbnail(&m.id).unwrap().unwrap(), b"thumb");
        }
        v.delete_item(&items[0].id).unwrap();
        assert!(!files_of(&v)
            .iter()
            .any(|(_, f)| f.starts_with(&items[0].id)));
        // A backup made now has every file once, under its old name.
        let mut backup = Vec::new();
        assert_eq!(
            crate::backup::export(tmp.path(), &mut backup).unwrap(),
            2 + 3 * 3
        );
        drop(v);
        // The next open finishes the move.
        let v = lib.unlock(PW).unwrap().unwrap();
        let done = files_of(&v);
        assert!(done
            .iter()
            .all(|(b, f)| crate::bucket_of(&f[..32]) == Some(b.as_str())));
        assert_eq!(done.len(), 3 * 3);
        assert_eq!(v.items().unwrap().len(), 3);
        // The backup restores into buckets.
        let other = tempfile::tempdir().unwrap();
        let target = other.path().join("library");
        crate::backup::import(&backup[..], &target).unwrap();
        let w = Library::open_or_create(&target, FAST, crate::tests::sk())
            .unwrap()
            .unlock(PW)
            .unwrap()
            .unwrap();
        assert_eq!(files_of(&w), done);
        let mut out = Vec::new();
        w.read_item(&items[3].id, &mut out).unwrap();
        assert_eq!(out, b"photo 3");
    }
}
