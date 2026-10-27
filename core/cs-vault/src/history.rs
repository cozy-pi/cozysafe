//! Version history: older revisions of each item, kept on this device for a while so
//! any change can be undone (owner 2026-10-27: "like git", every item, 30 days).
//!
//! ```text
//! history/<bucket>/<item>/<superseded_ms>.<rev>.<data_rev>.meta   the old record, sealed
//!                                                                  exactly as it was
//! history/<bucket>/<item>/<data_rev>.data                          the old content, and
//! history/<bucket>/<item>/<data_rev>.thumb                         its preview
//! ```
//!
//! A record is kept when a newer one replaces it and something the person sees changed
//! (name, content, tags, favourite); moving to Recently deleted and back is not a
//! version. Content is kept once per `data_rev`: renaming a photo keeps a record, not a
//! second copy of the photo. Old content is hard-linked into history before the new
//! content is renamed over it, so keeping it costs no copy.
//!
//! The current revision is never here: it lives in `items/`, and pruning only ever
//! removes files under `history/`. History stays on this device. It is not synced,
//! not in backups, and the limits (how long, how much space) are this device's own,
//! kept in the index (`sync_meta`), like the rest of what is local.
//!
//! File names carry only what pruning needs (a time and random revision ids); names,
//! kinds and content stay sealed, as in `items/`.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use cs_crypto::stream;

use crate::items::{kind, ItemMeta, ItemRecord};
use crate::{Error, OpenVault, Result};

const HISTORY_DIR: &str = "history";
const DAYS_KEY: &str = "history-days";
const BYTES_KEY: &str = "history-max-bytes";
const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// How long and how much history this device keeps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HistoryLimits {
    /// Days a version is kept after it was replaced; 0 keeps none (history off).
    pub days: u32,
    /// Most space all history may take; 0 for no limit.
    pub max_bytes: u64,
}

impl Default for HistoryLimits {
    /// 30 days, 1 GB (owner 2026-10-27).
    fn default() -> Self {
        HistoryLimits {
            days: 30,
            max_bytes: 1 << 30,
        }
    }
}

/// One older version of an item, newest first in [`OpenVault::history`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryEntry {
    pub rev: String,
    /// When a newer version replaced it.
    pub replaced_ms: i64,
    /// The item as it was in this version.
    pub item: ItemMeta,
    /// Written on this device (otherwise it came from another one by sync).
    pub this_device: bool,
    /// Its content can still be opened (it may have been pruned for space).
    pub has_content: bool,
    /// Its content is the same as the current version's.
    pub same_content: bool,
}

/// A kept record's file name, read back.
struct Kept {
    replaced_ms: i64,
    rev: String,
    data_rev: String,
    path: PathBuf,
}

fn parse_kept(path: PathBuf) -> Option<Kept> {
    let name = path.file_name()?.to_str()?;
    let mut parts = name.strip_suffix(".meta")?.split('.');
    let (ms, rev, data_rev) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || !is_rev(rev) || !is_rev(data_rev) {
        return None;
    }
    Some(Kept {
        replaced_ms: ms.parse().ok()?,
        rev: rev.to_owned(),
        data_rev: data_rev.to_owned(),
        path,
    })
}

/// Revision ids are ours: hex, and come back from Dart (no path tricks).
fn is_rev(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Hard link (free), or a copy where links are not possible.
fn link_or_copy(from: &Path, to: &Path) -> Result<()> {
    if to.exists() {
        return Ok(());
    }
    if fs::hard_link(from, to).is_err() {
        let tmp = to.with_extension("tmp");
        fs::copy(from, &tmp)?;
        fs::rename(&tmp, to)?;
    }
    Ok(())
}

fn files_in(dir: &Path) -> Vec<(PathBuf, u64)> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let md = e.metadata().ok()?;
            md.is_file().then(|| (e.path(), md.len()))
        })
        .collect()
}

impl OpenVault {
    fn history_root(&self) -> PathBuf {
        self.dir.join(HISTORY_DIR)
    }

    /// The item's history folder.
    fn history_dir(&self, item: &str) -> Result<PathBuf> {
        let name = crate::id_name(item).ok_or(Error::NoSuchItem)?;
        let bucket = crate::bucket_of(&name).ok_or(Error::NoSuchItem)?;
        Ok(self.history_root().join(bucket).join(name))
    }

    /// This device's limits (the default until changed).
    pub fn history_limits(&self) -> Result<HistoryLimits> {
        let d = HistoryLimits::default();
        let days = self.index.meta_get(DAYS_KEY)?.and_then(|v| v.parse().ok());
        let max_bytes = self.index.meta_get(BYTES_KEY)?.and_then(|v| v.parse().ok());
        Ok(HistoryLimits {
            days: days.unwrap_or(d.days),
            max_bytes: max_bytes.unwrap_or(d.max_bytes),
        })
    }

    /// Change the limits; what falls outside them goes at once.
    pub fn set_history_limits(&self, limits: HistoryLimits, now_ms: i64) -> Result<()> {
        self.index.meta_set(DAYS_KEY, &limits.days.to_string())?;
        self.index
            .meta_set(BYTES_KEY, &limits.max_bytes.to_string())?;
        self.prune_history(now_ms).map(|_| ())
    }

    /// Before new content is renamed over the item's: keep the current content, linked
    /// under its `data_rev`. Nothing to do for a new item or with history off.
    pub(crate) fn keep_content(&self, id: &str) -> Result<()> {
        if self.history_limits()?.days == 0 {
            return Ok(());
        }
        let Ok(record) = self.record(id) else {
            return Ok(());
        };
        if record.data_rev.is_empty() || !is_rev(&record.data_rev) {
            return Ok(());
        }
        let dir = self.history_dir(id)?;
        for ext in ["data", "thumb"] {
            let from = self.read_path(id, ext)?;
            if from.exists() {
                fs::create_dir_all(&dir)?;
                link_or_copy(&from, &dir.join(format!("{}.{ext}", record.data_rev)))?;
            }
        }
        Ok(())
    }

    /// `old` (sealed as `old_sealed`) is being replaced by `new`: keep it when the
    /// change is one the person would call a new version.
    pub(crate) fn keep_record(
        &self,
        id: &str,
        old: &ItemRecord,
        old_sealed: &[u8],
        new: &ItemRecord,
    ) -> Result<()> {
        let seen_change = old.name != new.name
            || old.data_rev != new.data_rev
            || old.tag_ids != new.tag_ids
            || old.is_favorite != new.is_favorite;
        if old.rev == new.rev
            || old.rev.is_empty()
            || !seen_change
            || old.kind == kind::TAG
            || !is_rev(&old.rev)
            || !is_rev(&old.data_rev)
        {
            return Ok(());
        }
        let limits = self.history_limits()?;
        if limits.days == 0 {
            return Ok(());
        }
        let now = crate::items::now_ms();
        // Always after the newest kept one: two changes within one millisecond would
        // otherwise list in the order of their random revision ids.
        let newest = self.kept(id)?.first().map_or(i64::MIN, |k| k.replaced_ms);
        let at = now.max(newest.saturating_add(1));
        let dir = self.history_dir(id)?;
        fs::create_dir_all(&dir)?;
        crate::write_atomic(
            &dir.join(format!("{at}.{}.{}.meta", old.rev, old.data_rev)),
            old_sealed,
        )?;
        self.prune_history(now).map(|_| ())
    }

    fn kept(&self, id: &str) -> Result<Vec<Kept>> {
        let mut out: Vec<Kept> = files_in(&self.history_dir(id)?)
            .into_iter()
            .filter_map(|(p, _)| parse_kept(p))
            .collect();
        out.sort_by(|a, b| b.replaced_ms.cmp(&a.replaced_ms).then(b.rev.cmp(&a.rev)));
        Ok(out)
    }

    /// The item's older versions, newest first. Damaged ones are skipped.
    pub fn history(&self, id: &str) -> Result<Vec<HistoryEntry>> {
        let current = self.record(id)?;
        let here = crate::sync::device_id(&self.index)?;
        let dir = self.history_dir(id)?;
        let mut out = Vec::new();
        for k in self.kept(id)? {
            let Ok(sealed) = fs::read(&k.path) else {
                continue;
            };
            let Ok(record) = self.open_record(id, &sealed) else {
                continue;
            };
            if record.rev != k.rev {
                continue; // a file renamed by hand: not what its name says
            }
            let same_content = record.data_rev == current.data_rev;
            let has_content = same_content || dir.join(format!("{}.data", k.data_rev)).exists();
            out.push(HistoryEntry {
                rev: k.rev,
                replaced_ms: k.replaced_ms,
                this_device: record.device == here,
                has_content,
                same_content,
                item: crate::items::meta(id.to_owned(), record),
            });
        }
        Ok(out)
    }

    /// A kept version's record, checked against its file name.
    fn kept_record(&self, id: &str, rev: &str) -> Result<ItemRecord> {
        if !is_rev(rev) {
            return Err(Error::NoSuchItem);
        }
        let k = self
            .kept(id)?
            .into_iter()
            .find(|k| k.rev == rev)
            .ok_or(Error::NoSuchItem)?;
        let record = self.open_record(id, &fs::read(&k.path)?)?;
        if record.rev != rev {
            return Err(Error::Corrupt("history"));
        }
        Ok(record)
    }

    /// Where a kept version's content is: in history, or the item's own when unchanged.
    fn kept_content(&self, id: &str, record: &ItemRecord, ext: &str) -> Result<PathBuf> {
        let kept = self
            .history_dir(id)?
            .join(format!("{}.{ext}", record.data_rev));
        if kept.exists() {
            return Ok(kept);
        }
        if self.record(id)?.data_rev == record.data_rev {
            return self.read_path(id, ext);
        }
        Err(Error::NoSuchItem)
    }

    /// Decrypt a kept version's content into `out`.
    pub fn read_history_item<W: Write>(&self, id: &str, rev: &str, out: W) -> Result<u64> {
        let record = self.kept_record(id, rev)?;
        let dek = self.unwrap_dek(id, &record)?;
        let f = fs::File::open(self.kept_content(id, &record, "data")?)?;
        Ok(stream::decrypt(&dek, &self.item_aad(id, "data"), f, out)?)
    }

    /// Make a kept version the current one: a new version with its name, tags (those
    /// still there), favourite and content. The version replaced is kept in turn, so a
    /// restore can be undone too. Works on items in Recently deleted as they are.
    pub fn restore_history(&self, id: &str, rev: &str) -> Result<ItemMeta> {
        let old = self.kept_record(id, rev)?;
        let mut record = self.record(id)?;
        if old.data_rev != record.data_rev {
            let data = self.kept_content(id, &old, "data")?;
            let thumb = if old.has_thumbnail() {
                Some(self.kept_content(id, &old, "thumb")?)
            } else {
                None
            };
            self.keep_content(id)?;
            // Same item key, same sealed bytes: copied, not decrypted.
            let to = self.new_path(id, "data")?;
            let tmp = to.with_extension("data.tmp");
            fs::copy(&data, &tmp)?;
            fs::File::open(&tmp)?.sync_all()?;
            fs::rename(&tmp, &to)?;
            match thumb {
                Some(t) => crate::write_atomic(&self.new_path(id, "thumb")?, &fs::read(t)?)?,
                None => crate::remove_if_exists(&self.path(id, "thumb")?)?,
            }
            record.size_bytes = old.size_bytes;
            record.data_hash = old.data_hash.clone();
            record.thumb_hash = old.thumb_hash.clone();
            record.set_thumbnail(old.has_thumbnail());
            record.duration_ms = old.duration_ms;
            record.data_rev.clear(); // new content: this revision carries it
        }
        let tags = self.index.ids()?;
        record.name = old.name;
        record.is_favorite = old.is_favorite;
        record.tag_ids = old
            .tag_ids
            .into_iter()
            .filter(|t| tags.contains(t))
            .collect();
        self.write_record(id, &record)
            .map(|r| crate::items::meta(id.to_owned(), r))
    }

    /// Forget the item's history (Delete for good, or the person asked).
    pub fn clear_history(&self, id: &str) -> Result<()> {
        match fs::remove_dir_all(self.history_dir(id)?) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }

    /// Forget every item's history.
    pub fn clear_all_history(&self) -> Result<()> {
        match fs::remove_dir_all(self.history_root()) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }

    /// Space all history takes, in bytes.
    pub fn history_bytes(&self) -> Result<u64> {
        Ok(self
            .history_dirs()
            .iter()
            .flat_map(|d| files_in(d))
            .map(|(_, n)| n)
            .sum())
    }

    fn history_dirs(&self) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for b in fs::read_dir(self.history_root())
            .into_iter()
            .flatten()
            .flatten()
        {
            for i in fs::read_dir(b.path()).into_iter().flatten().flatten() {
                if i.path().is_dir() {
                    out.push(i.path());
                }
            }
        }
        out
    }

    /// Drop what falls outside the limits: versions replaced too long ago, then the
    /// oldest ones until history fits its space. Content goes with the last version
    /// that needs it. Only files under `history/` are ever removed: the current
    /// version of an item is never touched. Returns how many versions went.
    pub fn prune_history(&self, now_ms: i64) -> Result<usize> {
        let limits = self.history_limits()?;
        if limits.days == 0 {
            let had = self.history_dirs().iter().map(|d| files_in(d).len()).sum();
            self.clear_all_history()?;
            return Ok(had);
        }
        let cutoff = now_ms - i64::from(limits.days) * DAY_MS;
        // Every version and content file, by folder.
        struct Folder {
            dir: PathBuf,
            kept: Vec<Kept>,
            content: Vec<(String, PathBuf, u64)>,
        }
        let mut folders = Vec::new();
        let mut total = 0u64;
        let mut meta_sizes = std::collections::HashMap::new();
        for dir in self.history_dirs() {
            let mut kept = Vec::new();
            let mut content = Vec::new();
            for (path, n) in files_in(&dir) {
                total += n;
                let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                if name.ends_with(".meta") {
                    meta_sizes.insert(path.clone(), n);
                    match parse_kept(path.clone()) {
                        Some(k) => kept.push(k),
                        None => {
                            let _ = fs::remove_file(&path); // not ours
                        }
                    }
                } else if let Some((rev, _)) = name.split_once('.') {
                    content.push((rev.to_owned(), path, n));
                }
            }
            folders.push(Folder { dir, kept, content });
        }
        let mut gone = 0;
        // Oldest first, across every item.
        let mut order: Vec<(i64, usize, usize)> = folders
            .iter()
            .enumerate()
            .flat_map(|(f, folder)| {
                folder
                    .kept
                    .iter()
                    .enumerate()
                    .map(move |(i, k)| (k.replaced_ms, f, i))
            })
            .collect();
        order.sort();
        let mut removed = vec![Vec::<bool>::new(); folders.len()];
        for (f, folder) in folders.iter().enumerate() {
            removed[f] = vec![false; folder.kept.len()];
        }
        for (ms, f, i) in order {
            let over = limits.max_bytes != 0 && total > limits.max_bytes;
            if ms >= cutoff && !over {
                break;
            }
            let k = &folders[f].kept[i];
            fs::remove_file(&k.path)?;
            total -= meta_sizes.get(&k.path).copied().unwrap_or(0);
            removed[f][i] = true;
            gone += 1;
            // Content no version left needs.
            let needed: std::collections::HashSet<&str> = folders[f]
                .kept
                .iter()
                .zip(&removed[f])
                .filter(|(_, r)| !**r)
                .map(|(k, _)| k.data_rev.as_str())
                .collect();
            for (rev, path, n) in &folders[f].content {
                if !needed.contains(rev.as_str()) && path.exists() {
                    fs::remove_file(path)?;
                    total -= n;
                }
            }
        }
        // Content nothing points to (a keep cut short), and empty folders.
        for (f, folder) in folders.iter().enumerate() {
            let needed: std::collections::HashSet<&str> = folder
                .kept
                .iter()
                .zip(&removed[f])
                .filter(|(_, r)| !**r)
                .map(|(k, _)| k.data_rev.as_str())
                .collect();
            for (rev, path, _) in &folder.content {
                if !needed.contains(rev.as_str()) && path.exists() {
                    let _ = fs::remove_file(path);
                }
            }
            if files_in(&folder.dir).is_empty() {
                let _ = fs::remove_dir(&folder.dir);
            }
        }
        Ok(gone)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::items::NewItem;
    use crate::Library;
    use cs_crypto::kdf::KdfParams;

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    fn pw() -> &'static str {
        static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        P.get_or_init(|| hex::encode(cs_crypto::generate_salt()))
    }

    fn vault() -> (tempfile::TempDir, OpenVault) {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, crate::tests::sk())
            .unwrap()
            .create_vault("A", pw())
            .unwrap();
        (tmp, v)
    }

    fn note(v: &OpenVault, name: &str, text: &str) -> String {
        v.add_item(NewItem {
            kind: kind::NOTE,
            name,
            mime: "text/plain",
            created_ms: 1,
            content: text.as_bytes(),
            thumbnail: None,
        })
        .unwrap()
        .id
    }

    fn text(v: &OpenVault, id: &str) -> String {
        let mut out = Vec::new();
        v.read_item(id, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    fn old_text(v: &OpenVault, id: &str, rev: &str) -> String {
        let mut out = Vec::new();
        v.read_history_item(id, rev, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn every_edit_keeps_the_version_before_and_any_can_come_back() {
        let (_d, v) = vault();
        let id = note(&v, "List", "milk");
        v.replace_item(&id, "List", &b"milk, eggs"[..]).unwrap();
        v.rename_item(&id, "Shopping").unwrap();
        v.replace_item(&id, "Shopping", &b"bread"[..]).unwrap();

        let h = v.history(&id).unwrap();
        assert_eq!(h.len(), 3);
        let names: Vec<_> = h.iter().map(|e| e.item.name.as_str()).collect();
        assert_eq!(names, ["Shopping", "List", "List"]);
        assert!(h.iter().all(|e| e.has_content && e.this_device));
        assert_eq!(old_text(&v, &id, &h[0].rev), "milk, eggs");
        assert_eq!(old_text(&v, &id, &h[2].rev), "milk");

        // Back to the first: a new version, and the one it replaced is kept in turn.
        v.restore_history(&id, &h[2].rev).unwrap();
        assert_eq!(text(&v, &id), "milk");
        assert_eq!(v.record(&id).unwrap().name, "List");
        let h = v.history(&id).unwrap();
        assert_eq!(h.len(), 4);
        assert_eq!(old_text(&v, &id, &h[0].rev), "bread");
    }

    #[test]
    fn a_rename_keeps_no_second_copy_of_the_content() {
        let (_d, v) = vault();
        let id = note(&v, "A", "same");
        v.rename_item(&id, "B").unwrap();
        v.rename_item(&id, "C").unwrap();
        let h = v.history(&id).unwrap();
        assert_eq!(h.len(), 2);
        assert!(h.iter().all(|e| e.same_content));
        let files = files_in(&v.history_dir(&id).unwrap());
        assert!(files.iter().all(|(p, _)| p.extension().unwrap() == "meta"));
        assert_eq!(old_text(&v, &id, &h[1].rev), "same");
    }

    #[test]
    fn moving_to_recently_deleted_is_not_a_version_and_deleting_for_good_forgets_all() {
        let (_d, v) = vault();
        let id = note(&v, "A", "one");
        v.replace_item(&id, "A", &b"two"[..]).unwrap();
        v.trash_item(&id, 5).unwrap();
        v.restore_item(&id).unwrap();
        assert_eq!(v.history(&id).unwrap().len(), 1);
        v.delete_item(&id).unwrap();
        assert!(!v.history_dir(&id).unwrap().exists());
        assert_eq!(v.history_bytes().unwrap(), 0);
    }

    #[test]
    fn old_versions_go_after_the_days_chosen_and_the_current_one_never() {
        let (_d, v) = vault();
        let id = note(&v, "A", "one");
        v.replace_item(&id, "A", &b"two"[..]).unwrap();
        let now = crate::items::now_ms();
        assert_eq!(v.prune_history(now + 29 * DAY_MS).unwrap(), 0);
        assert_eq!(v.prune_history(now + 31 * DAY_MS).unwrap(), 1);
        assert!(v.history(&id).unwrap().is_empty());
        assert!(!v
            .history_root()
            .join(crate::bucket_of(&id).unwrap())
            .join(&id)
            .exists());
        assert_eq!(text(&v, &id), "two");
    }

    #[test]
    fn over_the_space_limit_the_oldest_go_first_and_the_current_one_never() {
        let (_d, v) = vault();
        let id = note(&v, "A", &"a".repeat(10_000));
        for c in ["b", "c", "d"] {
            v.replace_item(&id, "A", c.repeat(10_000).as_bytes())
                .unwrap();
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(v.history(&id).unwrap().len(), 3);
        let now = crate::items::now_ms();
        // Room for about one old version.
        v.set_history_limits(
            HistoryLimits {
                days: 30,
                max_bytes: 15_000,
            },
            now,
        )
        .unwrap();
        let h = v.history(&id).unwrap();
        assert_eq!(h.len(), 1);
        assert_eq!(old_text(&v, &id, &h[0].rev), "c".repeat(10_000));
        assert!(v.history_bytes().unwrap() <= 15_000);
        // Even no room at all leaves the item as it is.
        v.set_history_limits(
            HistoryLimits {
                days: 30,
                max_bytes: 1,
            },
            now,
        )
        .unwrap();
        assert!(v.history(&id).unwrap().is_empty());
        assert_eq!(text(&v, &id), "d".repeat(10_000));
    }

    #[test]
    fn history_off_keeps_nothing_and_clears_what_there_was() {
        let (_d, v) = vault();
        let id = note(&v, "A", "one");
        v.replace_item(&id, "A", &b"two"[..]).unwrap();
        let now = crate::items::now_ms();
        v.set_history_limits(
            HistoryLimits {
                days: 0,
                max_bytes: 0,
            },
            now,
        )
        .unwrap();
        assert_eq!(v.history_bytes().unwrap(), 0);
        v.replace_item(&id, "A", &b"three"[..]).unwrap();
        assert!(v.history(&id).unwrap().is_empty());
        assert_eq!(v.history_limits().unwrap().days, 0);
        assert_eq!(text(&v, &id), "three");
    }

    #[test]
    fn a_version_from_another_device_by_sync_is_kept_too() {
        let t = crate::sync::tests::two();
        let id = note(&t.a, "List", "milk");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.b.replace_item(&id, "List", &b"milk, eggs"[..]).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.sync(&t.cloud).unwrap();
        let h = t.a.history(&id).unwrap();
        assert_eq!(h.len(), 1);
        assert!(h[0].this_device);
        assert_eq!(old_text(&t.a, &id, &h[0].rev), "milk");
        // On B, the version A wrote is one from another device.
        let hb = t.b.history(&id).unwrap();
        assert_eq!(hb.len(), 1);
        assert!(!hb[0].this_device);
    }

    #[test]
    fn revision_ids_from_outside_cannot_reach_other_files() {
        let (_d, v) = vault();
        let id = note(&v, "A", "one");
        v.replace_item(&id, "A", &b"two"[..]).unwrap();
        for bad in ["../x", "", "zz", "a/b"] {
            assert!(v.read_history_item(&id, bad, Vec::new()).is_err());
            assert!(v.restore_history(&id, bad).is_err());
        }
    }

    #[test]
    fn history_is_not_in_backups() {
        let (d, v) = vault();
        let id = note(&v, "A", "one");
        v.replace_item(&id, "A", &b"two"[..]).unwrap();
        assert!(v.history_bytes().unwrap() > 0);
        let mut out = Vec::new();
        crate::backup::export(d.path(), &mut out).unwrap();
        let fresh = tempfile::tempdir().unwrap();
        crate::backup::import(&out[..], fresh.path()).unwrap();
        let has_history = walk(fresh.path())
            .iter()
            .any(|p| p.components().any(|c| c.as_os_str() == HISTORY_DIR));
        assert!(!has_history);
    }

    fn walk(dir: &Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for e in fs::read_dir(dir).into_iter().flatten().flatten() {
            if e.path().is_dir() {
                out.extend(walk(&e.path()));
            } else {
                out.push(e.path());
            }
        }
        out
    }
}
