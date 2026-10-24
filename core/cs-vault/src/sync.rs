//! Sync between devices that hold the same vault, through a folder they share: a cloud
//! folder (Google Drive), or another device on the same Wi-Fi serving its own
//! (docs/adr/0003-sync.md).
//!
//! The shared folder only ever receives what is already encrypted on disk, and nothing
//! in it is overwritten:
//!
//! ```text
//! <vault>/records/<item>/<rev>      the item's sealed record at that revision
//! <vault>/blobs/<item>.<rev>.data   content written in revision <rev>
//! <vault>/blobs/<item>.<rev>.thumb  its preview
//! <vault>/log/<device>/<n>          sealed journal entries of one device, numbered
//! ```
//!
//! A sync reads the other devices' new journal entries and merges each item they name
//! (field by field against the last revision both sides agreed on), then uploads this
//! device's changes and appends one journal entry naming them. Conflicts never lose
//! typed text: when a note's text changed on both sides, the other text becomes a copy.

use std::collections::BTreeSet;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use cs_crypto::wrap;
use serde::{Deserialize, Serialize};

use crate::db::Index;
use crate::items::{kind, ItemRecord};
use crate::{Error, OpenVault, Result};

/// The shared folder, seen from this device. Paths use '/' and stay inside the folder.
pub trait Remote {
    /// A stable name for this place (the sync state kept here is per place).
    fn key(&self) -> String;
    /// File names directly in `dir` (empty when it does not exist).
    fn list(&self, dir: &str) -> Result<Vec<String>>;
    /// Copy the file at `path` into `out`; `false` when there is no such file.
    fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool>;
    /// Create the file at `path` from `src` (it never exists yet: nothing is overwritten).
    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()>;
    fn exists(&self, path: &str) -> Result<bool>;
    /// [`Remote::put`] from a file on this device.
    fn put_file(&self, path: &str, local: &Path) -> Result<()> {
        self.put(path, &mut fs::File::open(local)?)
    }
}

/// A folder on this device: tests, desktops, and any folder a sync client mirrors.
pub struct FolderRemote {
    root: PathBuf,
    key: Option<String>,
}

impl FolderRemote {
    pub fn new(root: &Path) -> FolderRemote {
        FolderRemote {
            root: root.to_path_buf(),
            key: None,
        }
    }

    /// The same, with a fixed name for its sync state (a folder made fresh each time).
    pub fn with_key(root: &Path, key: &str) -> FolderRemote {
        FolderRemote {
            root: root.to_path_buf(),
            key: Some(key.to_owned()),
        }
    }

    /// The file at `path`, open for reading, if there is one.
    pub fn open(&self, path: &str) -> Result<Option<fs::File>> {
        match fs::File::open(self.at(path)?) {
            Ok(f) => Ok(Some(f)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// A temporary file name inside the folder (ignored by listings).
    pub fn scratch(&self) -> Result<PathBuf> {
        fs::create_dir_all(&self.root)?;
        Ok(self
            .root
            .join(format!("{}.tmp", hex::encode(cs_crypto::generate_salt()))))
    }

    fn at(&self, path: &str) -> Result<PathBuf> {
        // '/' only: no "..", no empty parts, and none of what another system reads as a
        // separator or a drive ('\\' and ':' on Windows), nor NUL.
        if path.contains(['\\', ':', '\0'])
            || path
                .split('/')
                .any(|p| p.is_empty() || p == "." || p == "..")
        {
            return Err(Error::Corrupt("sync path"));
        }
        Ok(self.root.join(path))
    }
}

impl Remote for FolderRemote {
    fn key(&self) -> String {
        self.key
            .clone()
            .unwrap_or_else(|| format!("folder:{}", self.root.display()))
    }

    fn list(&self, dir: &str) -> Result<Vec<String>> {
        match fs::read_dir(self.at(dir)?) {
            Ok(d) => Ok(d
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| !n.ends_with(".tmp"))
                .collect()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(e.into()),
        }
    }

    fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
        match fs::File::open(self.at(path)?) {
            Ok(mut f) => {
                std::io::copy(&mut f, out)?;
                Ok(true)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        let to = self.at(path)?;
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = to.with_extension("tmp");
        {
            let mut f = fs::File::create(&tmp)?;
            std::io::copy(src, &mut f)?;
            f.sync_all()?;
        }
        fs::rename(tmp, to)?;
        Ok(())
    }

    fn exists(&self, path: &str) -> Result<bool> {
        Ok(self.at(path)?.exists())
    }

    /// A hard link when the folder is on the same disk (a P2P host's folder holds the
    /// whole vault for a moment: linking costs no space), a copy otherwise.
    fn put_file(&self, path: &str, local: &Path) -> Result<()> {
        let to = self.at(path)?;
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent)?;
        }
        if fs::hard_link(local, &to).is_ok() {
            return Ok(());
        }
        self.put(path, &mut fs::File::open(local)?)
    }
}

/// This device's id in the vault's sync, made the first time it is asked for.
pub(crate) fn device_id(index: &Index) -> Result<String> {
    if let Some(id) = index.meta_get("device")? {
        return Ok(id);
    }
    let id = hex::encode(&cs_crypto::generate_salt()[..8]);
    index.meta_set("device", &id)?;
    Ok(id)
}

/// The next hybrid-logical-clock reading: after the wall clock, after everything this
/// device has written or seen, and after `seen` (a record being changed or merged), so a
/// phone whose clock is wrong cannot make its edits always win or always lose.
pub(crate) fn next_hlc(index: &Index, seen: i64) -> Result<i64> {
    let last: i64 = index
        .meta_get("hlc")?
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let next = now_ms().max(last + 1).max(seen + 1);
    index.meta_set("hlc", &next.to_string())?;
    Ok(next)
}

fn observe_hlc(index: &Index, seen: i64) -> Result<()> {
    let last: i64 = index
        .meta_get("hlc")?
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if seen > last {
        index.meta_set("hlc", &seen.to_string())?;
    }
    Ok(())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// One journal entry: the items this device changed, at which revision, and the ones it
/// deleted for good.
#[derive(Serialize, Deserialize, Default)]
struct Entry {
    items: Vec<(String, String)>,
    #[serde(default)]
    gone: Vec<(String, i64)>,
}

/// What one sync did, for the app and the tests.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SyncReport {
    /// Items brought in or updated from other devices.
    pub received: u32,
    /// Items this device sent.
    pub sent: u32,
    /// Items deleted here because another device deleted them.
    pub removed: u32,
    /// Notes whose text changed on both sides: the other text was kept as a copy.
    pub copies: u32,
}

impl OpenVault {
    fn sync_dir(&self) -> String {
        self.id.clone()
    }

    /// Bring this vault and the shared folder in line: take the other devices' changes,
    /// then send this device's.
    pub fn sync(&self, remote: &dyn Remote) -> Result<SyncReport> {
        let mut report = SyncReport::default();
        self.pull(remote, &mut report)?;
        self.push(remote, &mut report)?;
        Ok(report)
    }

    fn log_aad(&self, device: &str, n: u64) -> Vec<u8> {
        crate::aad(&self.id, &format!("sync/log/{device}/{n}"))
    }

    fn pull(&self, remote: &dyn Remote, report: &mut SyncReport) -> Result<()> {
        let me = device_id(&self.index)?;
        let base = self.sync_dir();
        let mut devices = remote.list(&format!("{base}/log"))?;
        devices.sort();
        for device in devices.into_iter().filter(|d| *d != me) {
            if !device.bytes().all(|b| b.is_ascii_hexdigit()) {
                continue;
            }
            let key = format!("{}:cursor:{device}", remote.key());
            let cursor: u64 = self
                .index
                .meta_get(&key)?
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let mut entries: Vec<u64> = remote
                .list(&format!("{base}/log/{device}"))?
                .iter()
                .filter_map(|n| n.parse().ok())
                .filter(|n| *n > cursor)
                .collect();
            entries.sort_unstable();
            for n in entries {
                let mut sealed = Capped::new(MAX_SMALL);
                if !remote.get(&format!("{base}/log/{device}/{n}"), &mut sealed)? {
                    break;
                }
                let sealed = sealed.0;
                let json = wrap::open(&self.master_key, &sealed, &self.log_aad(&device, n))?;
                let entry: Entry =
                    serde_json::from_slice(&json).map_err(|_| Error::Corrupt("sync log"))?;
                for (id, rev) in entry.items {
                    self.take(remote, &id, &rev, report)?;
                }
                for (id, hlc) in entry.gone {
                    self.take_gone(remote, &id, hlc, report)?;
                }
                self.index.meta_set(&key, &n.to_string())?;
            }
        }
        Ok(())
    }

    fn remote_record(
        &self,
        remote: &dyn Remote,
        id: &str,
        rev: &str,
    ) -> Result<Option<(ItemRecord, Vec<u8>)>> {
        let mut sealed = Capped::new(MAX_SMALL);
        if !remote.get(
            &format!("{}/records/{id}/{rev}", self.sync_dir()),
            &mut sealed,
        )? {
            return Ok(None);
        }
        let sealed = sealed.0;
        let record = self.open_record(id, &sealed)?;
        if record.rev != rev {
            return Err(Error::Corrupt("sync record"));
        }
        Ok(Some((record, sealed)))
    }

    /// Fetch a revision's content into place (sealed as it is; nothing is decrypted).
    fn fetch_blobs(&self, remote: &dyn Remote, id: &str, record: &ItemRecord) -> Result<()> {
        fs::create_dir_all(self.items_dir())?;
        for ext in ["data", "thumb"] {
            if ext == "thumb" && !record.has_thumbnail() {
                continue;
            }
            let to = self.path(id, ext)?;
            let tmp = to.with_extension(format!("{ext}.tmp"));
            let found = {
                let mut f = fs::File::create(&tmp)?;
                let found = remote.get(
                    &format!("{}/blobs/{id}.{}.{ext}", self.sync_dir(), record.data_rev),
                    &mut f,
                )?;
                f.sync_all()?;
                found
            };
            if !found {
                let _ = fs::remove_file(&tmp);
                return Err(Error::Corrupt("sync content missing"));
            }
            // The content must be exactly what the (sealed) record says.
            let want = if ext == "data" {
                &record.data_hash
            } else {
                &record.thumb_hash
            };
            if want.is_empty() || crate::items::file_sha256_hex(&tmp)? != *want {
                let _ = fs::remove_file(&tmp);
                return Err(Error::Corrupt("sync content does not match its record"));
            }
            fs::rename(tmp, to)?;
        }
        Ok(())
    }

    /// Merge revision `rev` of item `id` from another device into this vault.
    fn take(
        &self,
        remote: &dyn Remote,
        id: &str,
        rev: &str,
        report: &mut SyncReport,
    ) -> Result<()> {
        let Some((theirs, _)) = self.remote_record(remote, id, rev)? else {
            return Ok(()); // not uploaded yet, or cleaned up: a later entry will name it
        };
        observe_hlc(&self.index, theirs.hlc)?;
        let ours = self
            .sealed_record(id)?
            .map(|s| self.open_record(id, &s))
            .transpose()?;
        let synced = self.index.synced_rev(&remote.key(), id)?;
        let Some(ours) = ours else {
            // New here, unless this device deleted it for good after that revision.
            if let Some(gone_hlc) = self.index.gone_hlc(id)? {
                if gone_hlc > theirs.hlc {
                    return Ok(());
                }
                self.index.forget_gone(id)?;
            }
            self.fetch_blobs(remote, id, &theirs)?;
            self.store_record(id, &theirs)?;
            self.index.set_synced(&remote.key(), id, rev)?;
            report.received += 1;
            return Ok(());
        };
        if ours.rev == theirs.rev {
            self.index.set_synced(&remote.key(), id, rev)?;
            return Ok(());
        }
        let changed_here = synced.as_deref() != Some(ours.rev.as_str());
        if !changed_here || theirs.base_rev.as_deref() == Some(ours.rev.as_str()) {
            // Only they changed it (or they built on ours): take theirs.
            if theirs.data_rev != ours.data_rev {
                self.fetch_blobs(remote, id, &theirs)?;
            }
            self.store_record(id, &theirs)?;
            self.index.set_synced(&remote.key(), id, rev)?;
            report.received += 1;
            return Ok(());
        }
        if ours.base_rev.as_deref() == Some(theirs.rev.as_str()) {
            return Ok(()); // ours already builds on theirs; it goes up at the push
        }
        // Both changed it: field by field against the revision both last had.
        let base = match synced.as_deref() {
            Some(s) => self.remote_record(remote, id, s)?.map(|(r, _)| r),
            None => None,
        };
        let merged = self.merge(remote, id, base.as_ref(), &ours, &theirs, report)?;
        self.store_record(id, &merged)?;
        // Agreed on theirs; ours (the merge) is the newer revision and goes up next.
        self.index.set_synced(&remote.key(), id, rev)?;
        report.received += 1;
        Ok(())
    }

    fn merge(
        &self,
        remote: &dyn Remote,
        id: &str,
        base: Option<&ItemRecord>,
        ours: &ItemRecord,
        theirs: &ItemRecord,
        report: &mut SyncReport,
    ) -> Result<ItemRecord> {
        let theirs_newer = (theirs.hlc, &theirs.device) > (ours.hlc, &ours.device);
        // For a field: whoever changed it from the base; both did, the later one.
        macro_rules! pick {
            ($f:ident) => {{
                let b = base.map(|b| &b.$f);
                if b == Some(&ours.$f) {
                    theirs.$f.clone()
                } else if b == Some(&theirs.$f) || !theirs_newer {
                    ours.$f.clone()
                } else {
                    theirs.$f.clone()
                }
            }};
        }
        let mut out = ours.clone();
        out.name = pick!(name);
        out.is_favorite = pick!(is_favorite);
        out.duration_ms = pick!(duration_ms);
        // Recently deleted: an edit on either side brings it back (never lose data).
        out.deleted_ms = match (ours.deleted_ms, theirs.deleted_ms) {
            (Some(_), Some(_)) => pick!(deleted_ms),
            (Some(_), None) | (None, Some(_)) => {
                let b = base.map(|b| b.deleted_ms);
                if b == Some(ours.deleted_ms) {
                    theirs.deleted_ms
                } else if b == Some(theirs.deleted_ms) {
                    ours.deleted_ms
                } else {
                    None
                }
            }
            (None, None) => None,
        };
        // Tags merge as sets: added on either side stays, removed on either side goes.
        let b: BTreeSet<&String> = base.map(|b| b.tag_ids.iter().collect()).unwrap_or_default();
        let o: BTreeSet<&String> = ours.tag_ids.iter().collect();
        let t: BTreeSet<&String> = theirs.tag_ids.iter().collect();
        let mut tags: Vec<String> = o
            .union(&t)
            .filter(|x| !(b.contains(*x) && (!o.contains(*x) || !t.contains(*x))))
            .map(|x| (*x).clone())
            .collect();
        tags.sort();
        out.tag_ids = tags;
        // Content: one side changed it, that side's; both did, the later one, and the
        // other note's text is kept as a copy.
        let base_data = base.map(|b| b.data_rev.as_str());
        let ours_changed = base_data != Some(ours.data_rev.as_str());
        let theirs_changed = base_data != Some(theirs.data_rev.as_str());
        let take_theirs_data = theirs_changed && (!ours_changed || theirs_newer);
        if ours_changed
            && theirs_changed
            && ours.data_rev != theirs.data_rev
            && ours.kind == kind::NOTE
        {
            let (loser_record, loser_is_theirs) = if take_theirs_data {
                (ours, false)
            } else {
                (theirs, true)
            };
            self.keep_copy(remote, id, loser_record, loser_is_theirs)?;
            report.copies += 1;
        }
        if take_theirs_data {
            self.fetch_blobs(remote, id, theirs)?;
            out.data_rev = theirs.data_rev.clone();
            out.size_bytes = theirs.size_bytes;
            out.wrapped_dek = theirs.wrapped_dek.clone();
            out.data_hash = theirs.data_hash.clone();
            out.thumb_hash = theirs.thumb_hash.clone();
            out.set_thumbnail(theirs.has_thumbnail());
        }
        out.rev = theirs.rev.clone();
        out.data_rev = if take_theirs_data {
            theirs.data_rev.clone()
        } else {
            ours.data_rev.clone()
        };
        let keep_data = out.data_rev.clone();
        self.stamp(&mut out)?;
        out.data_rev = keep_data;
        out.modified_ms = Some(now_ms());
        Ok(out)
    }

    /// The losing side of a note edited on two devices, saved as a new note so its text
    /// is not lost. Its content is copied as it is (re-encrypted under a new item id).
    fn keep_copy(
        &self,
        remote: &dyn Remote,
        id: &str,
        loser: &ItemRecord,
        from_remote: bool,
    ) -> Result<()> {
        let mut plain = Vec::new();
        if from_remote {
            // A note: small. Capped all the same, and checked against its record.
            let mut sealed = Capped::new(MAX_NOTE);
            remote.get(
                &format!("{}/blobs/{id}.{}.data", self.sync_dir(), loser.data_rev),
                &mut sealed,
            )?;
            let sealed = sealed.0;
            if loser.data_hash.is_empty() || crate::items::sha256_hex(&sealed) != loser.data_hash {
                return Err(Error::Corrupt("sync content does not match its record"));
            }
            let dek = self.unwrap_dek(id, loser)?;
            cs_crypto::stream::decrypt(&dek, &self.item_aad(id, "data"), &sealed[..], &mut plain)?;
        } else {
            self.read_item(id, &mut plain)?;
        }
        let name = format!("{} ({})", loser.name, short_device(&loser.device));
        let copy = self.add_item(crate::items::NewItem {
            kind: kind::NOTE,
            name: &name,
            mime: &loser.mime,
            created_ms: loser.created_ms,
            content: &plain[..],
            thumbnail: None,
        })?;
        for tag in &loser.tag_ids {
            let _ = self.set_tag(&copy.id, tag, true);
        }
        Ok(())
    }

    fn take_gone(
        &self,
        remote: &dyn Remote,
        id: &str,
        hlc: i64,
        report: &mut SyncReport,
    ) -> Result<()> {
        observe_hlc(&self.index, hlc)?;
        let Some(sealed) = self.sealed_record(id)? else {
            return Ok(());
        };
        let ours = self.open_record(id, &sealed)?;
        let changed_here =
            self.index.synced_rev(&remote.key(), id)?.as_deref() != Some(ours.rev.as_str());
        if changed_here && ours.hlc > hlc {
            return Ok(()); // edited here after: it stays (and goes up again)
        }
        self.remove_item(id)?;
        // Kept as a deletion to pass on to the other places, already known here.
        self.index.add_gone(id, hlc)?;
        self.index.gone_sent(&remote.key(), id)?;
        report.removed += 1;
        Ok(())
    }

    fn push(&self, remote: &dyn Remote, report: &mut SyncReport) -> Result<()> {
        let me = device_id(&self.index)?;
        let rk = remote.key();
        let base = self.sync_dir();
        // What the others need to open the vault: public files, sealed or not secret.
        if let Some(header) = self.dir.join(crate::HEADER_FILE).to_str() {
            if !remote.exists(&format!("{base}/header.json"))? {
                if let Ok(bytes) = fs::read(header) {
                    remote.put(&format!("{base}/header.json"), &mut &bytes[..])?;
                }
            }
        }
        let mut entry = Entry::default();
        for id in self.index.ids()? {
            let Some(sealed) = self.sealed_record(&id)? else {
                continue;
            };
            let mut record = self.open_record(&id, &sealed)?;
            let mut sealed = sealed;
            if record.rev.is_empty() || record.data_hash.is_empty() {
                // From before sync: a first revision, with its content's fingerprints
                // (same content, same time).
                let modified = record.modified_ms;
                record.data_hash = crate::items::file_sha256_hex(&self.path(&id, "data")?)?;
                if record.has_thumbnail() {
                    record.thumb_hash = crate::items::file_sha256_hex(&self.path(&id, "thumb")?)?;
                }
                record.data_rev.clear(); // its content goes up under this new revision
                self.stamp(&mut record)?;
                record.modified_ms = modified;
                sealed = self.store_record(&id, &record)?;
            }
            if self.index.synced_rev(&rk, &id)?.as_deref() == Some(record.rev.as_str()) {
                continue;
            }
            for ext in ["data", "thumb"] {
                if ext == "thumb" && !record.has_thumbnail() {
                    continue;
                }
                let to = format!("{base}/blobs/{id}.{}.{ext}", record.data_rev);
                if !remote.exists(&to)? {
                    remote.put_file(&to, &self.path(&id, ext)?)?;
                }
            }
            let to = format!("{base}/records/{id}/{}", record.rev);
            if !remote.exists(&to)? {
                remote.put(&to, &mut &sealed[..])?;
            }
            entry.items.push((id.clone(), record.rev.clone()));
        }
        entry.gone = self.index.gone_unsent(&rk)?;
        if entry.items.is_empty() && entry.gone.is_empty() {
            return Ok(());
        }
        let n: u64 = self
            .index
            .meta_get(&format!("{rk}:seq"))?
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
            + 1;
        let json = serde_json::to_vec(&entry).expect("serialisable");
        let sealed = wrap::seal(&self.master_key, &json, &self.log_aad(&me, n));
        remote.put(&format!("{base}/log/{me}/{n}"), &mut &sealed[..])?;
        self.index.meta_set(&format!("{rk}:seq"), &n.to_string())?;
        for (id, rev) in &entry.items {
            self.index.set_synced(&remote.key(), id, rev)?;
        }
        for (id, _) in &entry.gone {
            self.index.gone_sent(&rk, id)?;
        }
        report.sent += entry.items.len() as u32;
        Ok(())
    }
}

/// Records and journal entries are small: a place sending more is refused, not read
/// into memory.
const MAX_SMALL: usize = 1 << 20;
/// A note's content, read whole to keep a copy.
const MAX_NOTE: usize = 64 << 20;

/// A memory buffer that refuses to grow past its cap.
struct Capped(Vec<u8>, usize);

impl Capped {
    fn new(cap: usize) -> Capped {
        Capped(Vec::new(), cap)
    }
}

impl Write for Capped {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if self.0.len() + buf.len() > self.1 {
            return Err(std::io::Error::other("sync: more than expected"));
        }
        self.0.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn short_device(device: &str) -> String {
    format!("#{}", &device[..device.len().min(4)])
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::items::NewItem;
    use crate::Library;
    use cs_crypto::kdf::KdfParams;

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    const PW: &str = "orange kettle whispers at dawn 77";

    /// A vault on device A, the same vault copied to device B (without A's local sync
    /// state, as a new device starts), and the folder they share.
    pub(crate) struct Two {
        pub(crate) _dirs: (tempfile::TempDir, tempfile::TempDir, tempfile::TempDir),
        pub(crate) a: OpenVault,
        pub(crate) b: OpenVault,
        pub(crate) cloud: FolderRemote,
    }

    fn copy_dir(from: &Path, to: &Path) {
        fs::create_dir_all(to).unwrap();
        for e in fs::read_dir(from).unwrap().flatten() {
            let p = e.path();
            let name = e.file_name();
            if name.to_string_lossy().starts_with(crate::db::INDEX_FILE) {
                continue; // the index (and sync state) is per device
            }
            if p.is_dir() {
                copy_dir(&p, &to.join(&name));
            } else {
                fs::copy(&p, to.join(&name)).unwrap();
            }
        }
    }

    pub(crate) fn two() -> Two {
        let (da, db, dc) = (
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
        );
        let sk = crate::tests::sk();
        Library::open_or_create(da.path(), FAST, sk.clone())
            .unwrap()
            .create_vault("V", PW)
            .unwrap();
        copy_dir(da.path(), db.path());
        let a = Library::open_or_create(da.path(), FAST, sk.clone())
            .unwrap()
            .unlock(PW)
            .unwrap()
            .unwrap();
        let b = Library::open_or_create(db.path(), FAST, sk)
            .unwrap()
            .unlock(PW)
            .unwrap()
            .unwrap();
        assert_ne!(device_id(&a.index).unwrap(), device_id(&b.index).unwrap());
        let cloud = FolderRemote::new(dc.path());
        Two {
            _dirs: (da, db, dc),
            a,
            b,
            cloud,
        }
    }

    pub(crate) fn note(v: &OpenVault, name: &str, text: &str) -> String {
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

    pub(crate) fn text(v: &OpenVault, id: &str) -> String {
        let mut out = Vec::new();
        v.read_item(id, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    fn names(v: &OpenVault) -> Vec<String> {
        let mut n: Vec<_> = v.items().unwrap().into_iter().map(|m| m.name).collect();
        n.sort();
        n
    }

    #[test]
    fn an_item_added_on_one_device_arrives_on_the_other() {
        let t = two();
        let id = note(&t.a, "Wifi", "hunter2");
        assert_eq!(t.a.sync(&t.cloud).unwrap().sent, 1);
        assert_eq!(t.b.sync(&t.cloud).unwrap().received, 1);
        assert_eq!(text(&t.b, &id), "hunter2");
        // Nothing new: nothing moves.
        assert_eq!(t.a.sync(&t.cloud).unwrap(), SyncReport::default());
        assert_eq!(t.b.sync(&t.cloud).unwrap(), SyncReport::default());
    }

    #[test]
    fn the_cloud_holds_only_sealed_bytes() {
        let t = two();
        note(&t.a, "Bank PIN", "4921 secret");
        t.a.sync(&t.cloud).unwrap();
        fn walk(p: &Path, out: &mut Vec<u8>) {
            for e in fs::read_dir(p).unwrap().flatten() {
                if e.path().is_dir() {
                    walk(&e.path(), out)
                } else {
                    out.extend(fs::read(e.path()).unwrap())
                }
            }
        }
        let mut all = Vec::new();
        walk(&t.cloud.root, &mut all);
        let hay = String::from_utf8_lossy(&all);
        assert!(!hay.contains("Bank PIN") && !hay.contains("4921"));
    }

    #[test]
    fn an_edit_on_one_side_goes_across() {
        let t = two();
        let id = note(&t.a, "List", "milk");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.b.replace_item(&id, "List", &b"milk, eggs"[..]).unwrap();
        t.b.sync(&t.cloud).unwrap();
        assert_eq!(t.a.sync(&t.cloud).unwrap().received, 1);
        assert_eq!(text(&t.a, &id), "milk, eggs");
    }

    #[test]
    fn different_fields_changed_on_each_side_both_stay() {
        let t = two();
        let id = note(&t.a, "Old", "x");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.rename_item(&id, "New").unwrap();
        t.b.set_favorite(&id, true).unwrap();
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap(); // merges, then sends the merge
        t.a.sync(&t.cloud).unwrap();
        for v in [&t.a, &t.b] {
            let m = v.items().unwrap().into_iter().find(|m| m.id == id).unwrap();
            assert_eq!((m.name.as_str(), m.is_favorite), ("New", true));
        }
    }

    #[test]
    fn a_note_edited_on_both_sides_keeps_both_texts() {
        let t = two();
        let id = note(&t.a, "Plan", "v1");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.replace_item(&id, "Plan", &b"from A"[..]).unwrap();
        t.b.replace_item(&id, "Plan", &b"from B"[..]).unwrap(); // later: wins
        t.a.sync(&t.cloud).unwrap();
        let r = t.b.sync(&t.cloud).unwrap();
        assert_eq!(r.copies, 1);
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        for v in [&t.a, &t.b] {
            assert_eq!(text(v, &id), "from B");
            let texts: Vec<String> = v.items().unwrap().iter().map(|m| text(v, &m.id)).collect();
            assert!(texts.contains(&"from A".to_owned()), "{texts:?}");
            assert_eq!(names(v).len(), 2);
        }
    }

    #[test]
    fn tags_merge_as_sets() {
        let t = two();
        let id = note(&t.a, "N", "x");
        let work = t.a.create_tag("Work", 1).unwrap().id;
        let home = t.a.create_tag("Home", 1).unwrap().id;
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.set_tag(&id, &work, true).unwrap();
        t.b.set_tag(&id, &home, true).unwrap();
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.sync(&t.cloud).unwrap();
        for v in [&t.a, &t.b] {
            let m = v.items().unwrap().into_iter().find(|m| m.id == id).unwrap();
            let mut tags = m.tag_ids.clone();
            tags.sort();
            let mut want = vec![work.clone(), home.clone()];
            want.sort();
            assert_eq!(tags, want);
        }
    }

    #[test]
    fn deleted_for_good_on_one_side_goes_on_the_other() {
        let t = two();
        let id = note(&t.a, "Gone", "x");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.delete_item(&id).unwrap();
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(t.b.sync(&t.cloud).unwrap().removed, 1);
        assert!(t.b.items().unwrap().is_empty());
        // And it does not come back to A.
        t.b.sync(&t.cloud).unwrap();
        t.a.sync(&t.cloud).unwrap();
        assert!(t.a.items().unwrap().is_empty());
    }

    #[test]
    fn an_edit_after_a_delete_on_the_other_side_keeps_the_item() {
        let t = two();
        let id = note(&t.a, "Keep", "v1");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.delete_item(&id).unwrap();
        t.a.sync(&t.cloud).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
        t.b.replace_item(&id, "Keep", &b"v2"[..]).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(text(&t.b, &id), "v2");
        assert_eq!(text(&t.a, &id), "v2");
    }

    #[test]
    fn items_from_before_sync_get_a_first_revision() {
        let t = two();
        // An item written before revisions existed: no rev in its record.
        let id = note(&t.a, "Old", "x");
        let mut r = t.a.record(&id).unwrap();
        r.rev.clear();
        r.data_rev.clear();
        r.base_rev = None;
        t.a.store_record(&id, &r).unwrap();
        assert_eq!(t.a.sync(&t.cloud).unwrap().sent, 1);
        t.b.sync(&t.cloud).unwrap();
        assert_eq!(text(&t.b, &id), "x");
    }

    // ---------- a hostile sync place ----------

    fn blobs_of(cloud: &Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for v in fs::read_dir(cloud).unwrap().flatten() {
            if let Ok(d) = fs::read_dir(v.path().join("blobs")) {
                out.extend(
                    d.flatten()
                        .map(|e| e.path())
                        .filter(|p| p.extension().is_some_and(|e| e == "data")),
                );
            }
        }
        out.sort();
        out
    }

    #[test]
    fn older_content_handed_back_under_a_newer_revision_is_refused() {
        let t = two();
        let id = note(&t.a, "PIN", "old 1234");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap(); // B has revision 1, rightly
        let rev1 = t.b.record(&id).unwrap().rev;
        let before: Vec<_> = blobs_of(&t.cloud.root);
        t.a.replace_item(&id, "PIN", &b"new 9876"[..]).unwrap();
        t.a.sync(&t.cloud).unwrap();
        let newer = blobs_of(&t.cloud.root)
            .into_iter()
            .find(|p| !before.contains(p))
            .unwrap();
        // The cloud swaps the new content for the old one (same item key: it decrypts).
        fs::copy(&before[0], &newer).unwrap();
        assert!(t.b.sync(&t.cloud).is_err());
        // B did not take revision 2 with the swapped content: it stays at revision 1.
        assert_eq!(t.b.record(&id).unwrap().rev, rev1);
        assert_eq!(text(&t.b, &id), "old 1234");
    }

    #[test]
    fn an_oversized_record_is_refused_not_read() {
        let t = two();
        let id = note(&t.a, "N", "x");
        t.a.sync(&t.cloud).unwrap();
        let rev = t.a.record(&id).unwrap().rev;
        let path = t
            .cloud
            .root
            .join(&t.a.id)
            .join("records")
            .join(&id)
            .join(&rev);
        fs::write(&path, vec![0u8; (MAX_SMALL) + 1]).unwrap();
        assert!(t.b.sync(&t.cloud).is_err());
    }

    #[test]
    fn paths_cannot_leave_the_folder_on_any_system() {
        let dir = tempfile::tempdir().unwrap();
        let f = FolderRemote::new(dir.path());
        for bad in ["a/../b", "a\\..\\b", "C:/x", "a//b", "/etc", "a/\0b", "./a"] {
            assert!(f.list(bad).is_err(), "{bad}");
            assert!(f.put(bad, &mut &b"x"[..]).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_journal_entry_cannot_be_moved_or_forged() {
        let t = two();
        note(&t.a, "N", "x");
        t.a.sync(&t.cloud).unwrap();
        // Renumber A's entry 1 as 2: its sealed number no longer matches.
        let log = t.cloud.root.join(&t.a.id).join("log");
        let dev = fs::read_dir(&log).unwrap().next().unwrap().unwrap().path();
        fs::rename(dev.join("1"), dev.join("2")).unwrap();
        assert!(t.b.sync(&t.cloud).is_err());
        // A made-up entry fails as well.
        fs::write(dev.join("3"), b"not sealed").unwrap();
        fs::rename(dev.join("2"), dev.join("1")).unwrap();
        assert!(t.b.sync(&t.cloud).is_err());
    }
}
