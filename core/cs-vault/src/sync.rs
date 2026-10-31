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
//! <vault>/head/<device>             sealed, small: the device's last entry and how far
//!                                   it has read the others' (rewritten in place)
//! <vault>/lock/<ms>-<sha256>.json   the vault's lock (to join from the place)
//! ```
//!
//! A sync reads the other devices' new journal entries and merges each item they name
//! (field by field against the last revision both sides agreed on), then uploads this
//! device's changes and appends one journal entry naming them. Conflicts never lose
//! typed text: when a note's text changed on both sides, the other text becomes a copy.
//!
//! The head is the one file that changes: written last, after the journal entries it
//! counts, so a place that tells when a file changed (Google Drive's `version`) lets
//! another device see in one small request whether anything new was written
//! ([`HeadsSeen`]). Devices from before heads (0.1.80 and older) write none: their
//! changes are only seen by a full sync.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;

use cs_core::clock::{device_id, now_ms, observe_hlc};
use serde::{Deserialize, Serialize};

use crate::db::Gone;
use crate::items::{kind, ItemRecord, RecordExt};
use crate::{Error, OpenVault, Result};

/// The shared folder, seen from this device. Paths use '/' and stay inside the folder.
/// Shared between threads when [`Remote::parallel`] is above 1.
pub trait Remote: Sync {
    /// A stable name for this place (the sync state kept here is per place).
    fn key(&self) -> String;
    /// File names directly in `dir` (empty when it does not exist).
    fn list(&self, dir: &str) -> Result<Vec<String>>;
    /// Copy the file at `path` into `out`; `false` when there is no such file.
    fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool>;
    /// Create the file at `path` from `src` (it never exists yet: nothing is overwritten,
    /// except through [`Remote::replace`]).
    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()>;
    /// Write the file at `path` from `src`, replacing the one there. Only a device's head
    /// (`<vault>/head/<device>`) is ever rewritten. By default the old file is removed,
    /// then the new one put; a place that cannot remove (a nearby device's session
    /// folder) keeps the first one, which is fine for a folder thrown away anyway.
    fn replace(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        self.remove(path)?;
        self.put(path, src)
    }
    fn exists(&self, path: &str) -> Result<bool>;
    /// [`Remote::put`] from a file on this device.
    fn put_file(&self, path: &str, local: &Path) -> Result<()> {
        self.put(path, &mut fs::File::open(local)?)
    }
    /// [`Remote::put_file`], telling `read` the bytes as they leave (for the speed on
    /// screen). A place that streams the file tells them on the way; by default all of
    /// them once the file is up.
    fn put_file_told(&self, path: &str, local: &Path, read: &dyn Fn(u64)) -> Result<()> {
        self.put_file(path, local)?;
        read(fs::metadata(local)?.len());
        Ok(())
    }
    /// Delete the file at `path` (gone already is fine). Files are never rewritten: the
    /// vault's lock is replaced by a newer one (`<vault>/lock/…`), and the records and
    /// content of an item deleted for good are taken away. A place that lives for one
    /// session only (a P2P host's folder) may ignore it.
    fn remove(&self, _path: &str) -> Result<()> {
        Ok(())
    }
    /// Whether [`Remote::remove`] really deletes: then the files of items deleted for good
    /// are taken off the place too.
    fn removes(&self) -> bool {
        false
    }
    /// [`Remote::remove`] for many files at once (a place that can delete in batches
    /// does it in far fewer requests).
    fn remove_many(&self, paths: &[String]) -> Result<()> {
        for p in paths {
            self.remove(p)?;
        }
        Ok(())
    }
    /// How many items may go up at once. Above 1 only for places whose requests wait on
    /// the network (each one a round trip) and that take calls from several threads.
    fn parallel(&self) -> usize {
        1
    }
    /// What the place says about the file at `path` without reading it: Google Drive
    /// lists each file's SHA-256 with its name, so a sync checks every file it relies on
    /// at no extra request (owner 2026-10-26). `None`: this place cannot tell.
    fn listed(&self, _path: &str) -> Option<Listed> {
        None
    }
}

/// [`Remote::listed`]: a file the place does not have, one it has without a checksum
/// (just sent, Google computes it later), or one with its SHA-256 (lowercase hex).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Listed {
    Missing,
    Unknown,
    Sha256(String),
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
        Ok(self.root.join(format!(
            "{}.tmp",
            cs_core::hex::encode(cs_crypto::generate_salt())
        )))
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

    /// [`Remote::put`] writes beside and renames over: the file is replaced at once.
    fn replace(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        self.put(path, src)
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

    fn remove(&self, path: &str) -> Result<()> {
        match fs::remove_file(self.at(path)?) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }

    fn removes(&self) -> bool {
        true
    }
}

/// One journal entry: the items this device changed, at which revision, and the ones it
/// deleted for good.
#[derive(Serialize, Deserialize, Default)]
struct Entry {
    items: Vec<(String, String)>,
    #[serde(default)]
    gone: Vec<(String, i64)>,
}

/// Where a sync is, for the screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncPhase {
    /// Reading what the place holds.
    Checking,
    /// Fingerprinting items that never went anywhere yet (a first sync), before sending.
    Preparing,
    /// Bringing items in.
    Receiving,
    /// Sending this device's changes.
    Sending,
    /// Taking the files of items deleted for good off the place.
    Removing,
    /// Sending again files the place lost or damaged (`done`, `total` items).
    Repairing,
    /// Taking old revisions off the place, at most once a day (`done`, `total` items).
    Tidying,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SyncProgress {
    pub phase: SyncPhase,
    pub done: u32,
    pub total: u32,
    /// Bytes moved in this phase so far (for the speed on screen).
    pub bytes: u64,
    /// While sending: the bytes this device's changes come to (0 when not known).
    pub bytes_total: u64,
}

/// A place that counts the bytes crossing it.
struct Counted<'a> {
    inner: &'a dyn Remote,
    bytes: AtomicU64,
}

impl Counted<'_> {
    fn bytes(&self) -> u64 {
        self.bytes.load(Ordering::Relaxed)
    }

    fn add(&self, n: u64) {
        self.bytes.fetch_add(n, Ordering::Relaxed);
    }
}

/// A writer that counts what goes through it.
struct CountingWriter<'a, 'b> {
    out: &'a mut dyn Write,
    counted: &'a Counted<'b>,
}

impl Write for CountingWriter<'_, '_> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.out.write(buf)?;
        self.counted.add(n as u64);
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.out.flush()
    }
}

/// A reader that tells what goes through it, for [`Remote::put_file_told`].
pub struct Telling<'a> {
    pub src: &'a mut dyn Read,
    pub read: &'a dyn Fn(u64),
}

impl Read for Telling<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.src.read(buf)?;
        (self.read)(n as u64);
        Ok(n)
    }
}

/// A reader that counts what goes through it.
struct CountingReader<'a, 'b> {
    src: &'a mut dyn Read,
    counted: &'a Counted<'b>,
}

impl Read for CountingReader<'_, '_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.src.read(buf)?;
        self.counted.add(n as u64);
        Ok(n)
    }
}

impl Remote for Counted<'_> {
    fn key(&self) -> String {
        self.inner.key()
    }

    fn list(&self, dir: &str) -> Result<Vec<String>> {
        self.inner.list(dir)
    }

    fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
        self.inner
            .get(path, &mut CountingWriter { out, counted: self })
    }

    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        self.inner
            .put(path, &mut CountingReader { src, counted: self })
    }

    fn replace(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        self.inner
            .replace(path, &mut CountingReader { src, counted: self })
    }

    fn exists(&self, path: &str) -> Result<bool> {
        self.inner.exists(path)
    }

    fn put_file(&self, path: &str, local: &Path) -> Result<()> {
        // Counted as the bytes leave, not once the file is up: a big file used to show no
        // speed while it went, then a burst (owner 2026-10-27: "the KB/s looks wrong").
        self.inner.put_file_told(path, local, &|n| self.add(n))
    }

    fn remove(&self, path: &str) -> Result<()> {
        self.inner.remove(path)
    }

    fn removes(&self) -> bool {
        self.inner.removes()
    }

    fn remove_many(&self, paths: &[String]) -> Result<()> {
        self.inner.remove_many(paths)
    }

    fn parallel(&self) -> usize {
        self.inner.parallel()
    }

    fn listed(&self, path: &str) -> Option<Listed> {
        self.inner.listed(path)
    }
}

/// A record or a content file fetched ahead ([`OpenVault::fetch_ahead`]).
enum Got {
    Bytes(Vec<u8>),
    File(PathBuf),
}

/// The place, serving first what was fetched ahead (each once), the rest from the place.
struct Ahead<'a, 'b> {
    inner: &'a Counted<'b>,
    got: Mutex<std::collections::HashMap<String, Got>>,
}

impl Ahead<'_, '_> {
    /// Nothing to clear between items: each file is taken (and removed) as it is read.
    fn clear(&self) {}

    /// What was fetched but not taken (an item merged, or one that failed): removed.
    fn clear_all(&self) {
        for (_, g) in self.got.lock().unwrap_or_else(|p| p.into_inner()).drain() {
            if let Got::File(f) = g {
                let _ = fs::remove_file(f);
            }
        }
    }
}

impl Remote for Ahead<'_, '_> {
    fn key(&self) -> String {
        self.inner.key()
    }

    fn list(&self, dir: &str) -> Result<Vec<String>> {
        self.inner.list(dir)
    }

    fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
        let got = self
            .got
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(path);
        match got {
            Some(Got::Bytes(b)) => {
                out.write_all(&b)?;
                Ok(true)
            }
            Some(Got::File(f)) => {
                let copied = std::io::copy(&mut fs::File::open(&f)?, out);
                let _ = fs::remove_file(&f);
                copied?;
                Ok(true)
            }
            None => self.inner.get(path, out),
        }
    }

    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        self.inner.put(path, src)
    }

    fn replace(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        self.inner.replace(path, src)
    }

    fn exists(&self, path: &str) -> Result<bool> {
        self.inner.exists(path)
    }

    fn put_file(&self, path: &str, local: &Path) -> Result<()> {
        self.inner.put_file(path, local)
    }

    fn remove(&self, path: &str) -> Result<()> {
        self.inner.remove(path)
    }

    fn removes(&self) -> bool {
        self.inner.removes()
    }

    fn remove_many(&self, paths: &[String]) -> Result<()> {
        self.inner.remove_many(paths)
    }

    fn parallel(&self) -> usize {
        self.inner.parallel()
    }

    fn listed(&self, path: &str) -> Option<Listed> {
        self.inner.listed(path)
    }
}

/// A device's head (`<vault>/head/<device>`), sealed with the Master Key under its
/// path. Always small: a number per device that synced through the place.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Head {
    /// The device's last journal entry (`log/<device>/<n>`); 0 before the first.
    pub n: u64,
    /// Other device → the last of its journal entries this device has read. Kept for a
    /// later clean-up of entries every device has read; not used yet.
    #[serde(default)]
    pub read: BTreeMap<String, u64>,
}

/// What a place said about the heads at one moment: Google Drive's `version` of each
/// head file (it rises on every change), and the id of the folder holding them, so the
/// next look is one request. Kept per place in the index ([`OpenVault::remember_heads`]).
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeadsSeen {
    /// The place's own id for the folder of heads, when it had one.
    #[serde(default)]
    pub folder_id: Option<String>,
    /// Device → its head file's version.
    #[serde(default)]
    pub versions: BTreeMap<String, u64>,
}

/// Items per journal entry while sending, so a long first sync that stops half-way has
/// already told the other devices about what went up.
pub const LOG_EVERY: usize = 50;

/// What one sync did, for the app and the tests.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SyncReport {
    /// Items brought in or updated from other devices.
    pub received: u32,
    /// Items this device sent.
    pub sent: u32,
    /// Items another device deleted for good, moved here to Recently deleted (held
    /// for 30 days, not synced back).
    pub removed: u32,
    /// Notes whose text changed on both sides: the other text was kept as a copy.
    pub copies: u32,
    /// Files the place should hold but lost or holds damaged (by its own checksum), sent
    /// again from this device.
    pub repaired: u32,
    /// The same, for items whose copy here is not right either: nothing good to send.
    pub unrepaired: u32,
}

/// Sync of a vault with a place (docs/adr/0003-sync.md), on top of the Top secret core.
pub trait VaultSync {
    /// Bring this vault and the shared folder in line: take the other devices' changes,
    /// then send this device's.
    fn sync(&self, remote: &dyn Remote) -> Result<SyncReport>;

    /// [`OpenVault::sync`], telling `progress` how far it is. Stopping anywhere loses
    /// nothing: what came in is kept, what went up is recorded every [`LOG_EVERY`]
    /// items, and the next sync goes on from there.
    fn sync_with(&self, remote: &dyn Remote, progress: &dyn Fn(SyncProgress))
        -> Result<SyncReport>;

    /// A device's head read from `remote` (`None`: it has none, as devices from before
    /// heads). Sealed under its path, so it cannot pass for another device's.
    fn read_head(&self, remote: &dyn Remote, device: &str) -> Result<Option<Head>>;

    /// What `place` last said about the heads, kept after a full sync that worked
    /// ([`OpenVault::remember_heads`]); `None` before the first.
    fn heads_seen(&self, place: &str) -> Result<Option<HeadsSeen>>;

    /// Keep what `place` said about the heads. Called only after a full sync that worked,
    /// with what the place said BEFORE that sync read the journals: a change written
    /// meanwhile, or by a sync that failed, is then still seen as new.
    fn remember_heads(&self, place: &str, seen: &HeadsSeen) -> Result<()>;

    /// Whether `now` (what `place` says about the heads at this moment; `None`: it has no
    /// folder of heads) shows another device has written since the last full sync.
    /// Changed when nothing is remembered yet, when there is no folder of heads, or when
    /// another device's head is new, has another version, or is gone; this device's own
    /// head is left out. A false "changed" only costs a sync; "unchanged" is said only
    /// when every other device's head is as it was before the last full sync read the
    /// journals. Devices without a head (0.1.80 and older) are not seen here. A folder
    /// found again under another id is kept for the next look.
    fn heads_changed(&self, place: &str, now: Option<&HeadsSeen>) -> Result<bool>;
}

impl VaultSync for OpenVault {
    fn sync(&self, remote: &dyn Remote) -> Result<SyncReport> {
        self.sync_with(remote, &|_| {})
    }

    fn sync_with(
        &self,
        remote: &dyn Remote,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<SyncReport> {
        let mut report = SyncReport::default();
        let counted = Counted {
            inner: remote,
            bytes: AtomicU64::new(0),
        };
        progress(SyncProgress {
            phase: SyncPhase::Checking,
            done: 0,
            total: 0,
            bytes: 0,
            bytes_total: 0,
        });
        let synced = self
            .pull(&counted, &mut report, progress)
            .and_then(|()| self.push(&counted, &mut report, progress));
        if synced.is_err() {
            // Entries may have gone up before it failed: the head says so if it can.
            self.write_head_quietly(&counted);
        }
        synced.map(|()| report)
    }

    fn read_head(&self, remote: &dyn Remote, device: &str) -> Result<Option<Head>> {
        let mut sealed = Capped::new(MAX_SMALL);
        if !remote.get(&format!("{}/head/{device}", self.sync_dir()), &mut sealed)? {
            return Ok(None);
        }
        let json = self.sealer().open(&sealed.0, &self.head_aad(device))?;
        serde_json::from_slice(&json)
            .map(Some)
            .map_err(|_| Error::Corrupt("sync head"))
    }

    fn heads_seen(&self, place: &str) -> Result<Option<HeadsSeen>> {
        Ok(self
            .index()
            .meta_get(&format!("{place}:heads-seen"))?
            .and_then(|v| serde_json::from_str(&v).ok()))
    }

    fn remember_heads(&self, place: &str, seen: &HeadsSeen) -> Result<()> {
        self.index().meta_set(
            &format!("{place}:heads-seen"),
            &serde_json::to_string(seen).expect("json"),
        )
    }

    fn heads_changed(&self, place: &str, now: Option<&HeadsSeen>) -> Result<bool> {
        let Some(seen) = self.heads_seen(place)? else {
            return Ok(true);
        };
        let Some(now) = now else {
            return Ok(true);
        };
        if now.folder_id.is_some() && now.folder_id != seen.folder_id {
            self.remember_heads(
                place,
                &HeadsSeen {
                    folder_id: now.folder_id.clone(),
                    versions: seen.versions.clone(),
                },
            )?;
        }
        let me = device_id(self.index())?;
        let others = |m: &BTreeMap<String, u64>| -> BTreeMap<String, u64> {
            m.iter()
                .filter(|(d, _)| **d != me)
                .map(|(d, v)| (d.clone(), *v))
                .collect()
        };
        Ok(others(&now.versions) != others(&seen.versions))
    }
}

/// The steps of [`VaultSync`].
trait SyncSteps {
    fn sync_dir(&self) -> String;

    fn log_aad(&self, device: &str, n: u64) -> Vec<u8>;

    fn head_aad(&self, device: &str) -> Vec<u8>;

    /// This device's head as it stands for `remote`: its last journal entry there, and
    /// the cursors it keeps of the other devices.
    fn head(&self, remote: &dyn Remote) -> Result<Head>;

    /// Write this device's head to `remote` when it says something new (or the place
    /// lost it): one small file, replaced in place.
    fn write_head(&self, remote: &dyn Remote) -> Result<()>;

    /// [`OpenVault::write_head`], never failing the sync: a head not written now is
    /// written by the next sync (meanwhile other devices see the change only by a full
    /// sync).
    fn write_head_quietly(&self, remote: &dyn Remote);

    fn pull(
        &self,
        remote: &Counted<'_>,
        report: &mut SyncReport,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()>;

    /// The records and content of `items` this device will take, fetched several at once
    /// into files beside where they go (`.ahead`), for [`Ahead`] to serve. Only the
    /// network part: nothing here touches the index, and what fails is simply not
    /// fetched (taking it reads it again and says why).
    fn fetch_ahead(
        &self,
        remote: &Counted<'_>,
        items: &[(String, String)],
        tick: &dyn Fn(),
    ) -> Result<std::collections::HashMap<String, Got>>;

    /// Whether a journal entry's revision would change this device: not a revision it
    /// already has, nor an item it deleted for good (judged here, without the place).
    fn would_take(&self, id: &str, rev: &str) -> Result<bool>;

    fn remote_record(
        &self,
        remote: &dyn Remote,
        id: &str,
        rev: &str,
    ) -> Result<Option<(ItemRecord, Vec<u8>)>>;

    /// Fetch a revision's content into place (sealed as it is; nothing is decrypted).
    fn fetch_blobs(&self, remote: &dyn Remote, id: &str, record: &ItemRecord) -> Result<()>;

    /// Merge revision `rev` of item `id` from another device into this vault.
    fn take(&self, remote: &dyn Remote, id: &str, rev: &str, report: &mut SyncReport)
        -> Result<()>;

    fn merge(
        &self,
        remote: &dyn Remote,
        id: &str,
        base: Option<&ItemRecord>,
        ours: &ItemRecord,
        theirs: &ItemRecord,
        report: &mut SyncReport,
    ) -> Result<ItemRecord>;

    /// The losing side of a note edited on two devices, saved as a new note so its text
    /// is not lost. Its content is copied as it is (re-encrypted under a new item id).
    fn keep_copy(
        &self,
        remote: &dyn Remote,
        id: &str,
        loser: &ItemRecord,
        from_remote: bool,
    ) -> Result<()>;

    fn take_gone(
        &self,
        remote: &dyn Remote,
        id: &str,
        hlc: i64,
        report: &mut SyncReport,
    ) -> Result<()>;

    /// The vault's lock as this device has it: its header (the Master Key wrapped with
    /// the password and the Recovery Key, sealed meta) and the library's (salt, Argon2
    /// cost, the key's fingerprint). What a new device needs, with the 24 words and the
    /// password, to open the vault from the place. Nothing in it opens anything alone.
    /// With when it last changed here (ms), so an older lock never replaces a newer one.
    fn lock_bytes(&self) -> Result<(u64, Vec<u8>)>;

    /// Put this device's lock in the place, named by its content, and only then remove
    /// any other: after the password or Recovery Key changed, the old ones no longer
    /// open the copy there (owner 2026-10-24).
    ///
    /// Names are `<ms changed>-<sha256>.json`. A device whose lock is older (its password
    /// or key not changed yet) leaves the newer one alone.
    fn push_lock(&self, remote: &dyn Remote, base: &str) -> Result<()>;

    fn push(
        &self,
        remote: &Counted<'_>,
        report: &mut SyncReport,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()>;

    /// Every file of the revisions the place holds, checked against what the place lists
    /// (a missing file, or one whose SHA-256 is not the one sealed in the record): sent
    /// again from here when the copy here is right. Places that cannot tell are skipped;
    /// a file without a checksum yet (just sent) counts as fine.
    fn mend_place(
        &self,
        remote: &Counted<'_>,
        base: &str,
        held: &[(String, ItemRecord, Vec<u8>)],
        report: &mut SyncReport,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()>;

    /// Take old revisions off the place (at most once a day): the record of a revision
    /// superseded more than [`KEEP_OLD_MS`] ago (the next newer one, by `hlc`, made
    /// before then), and its content unless a revision that stays uses it too. A device
    /// that has not synced for that long finds them gone and takes the newer revision
    /// its journal names. Only items this device holds, at the revision the place has;
    /// never their current revision or its content, nor a revision newer than it (another
    /// device's, not told yet). Records go before content, in batches.
    fn collect_garbage(
        &self,
        remote: &Counted<'_>,
        now: i64,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()>;

    /// Take the files of items deleted for good off the place (owner 2026-10-24: 700
    /// deleted photos stayed in Google Drive). Only revisions made before the deletion
    /// go: one edited on another device after it stays, with its content. The first
    /// time on a place, deletions it was already told about are cleaned as well.
    ///
    /// The revision this device last had is older than the deletion and goes unread;
    /// any other is read to compare its clock. Files go in batches of about
    /// [`REMOVE_EVERY`], each batch's records before its content, so a device catching
    /// up finds a record gone (and skips it) rather than a record without content.
    fn clean_gone(
        &self,
        remote: &Counted<'_>,
        base: &str,
        unsent: &[Gone],
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()>;

    /// One journal entry up, then mark its items and deletions as told to this place.
    fn send_entry(&self, remote: &dyn Remote, entry: Entry, report: &mut SyncReport) -> Result<()>;
}

impl SyncSteps for OpenVault {
    fn sync_dir(&self) -> String {
        self.id.clone()
    }

    fn log_aad(&self, device: &str, n: u64) -> Vec<u8> {
        crate::aad(&self.id, &format!("sync/log/{device}/{n}"))
    }

    fn head_aad(&self, device: &str) -> Vec<u8> {
        crate::aad(&self.id, &format!("sync/head/{device}"))
    }

    fn head(&self, remote: &dyn Remote) -> Result<Head> {
        let rk = remote.key();
        let n = self
            .index()
            .meta_get(&format!("{rk}:seq"))?
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let prefix = format!("{rk}:cursor:");
        let read = self
            .index()
            .meta_prefixed(&prefix)?
            .into_iter()
            .filter_map(|(k, v)| Some((k[prefix.len()..].to_owned(), v.parse().ok()?)))
            .collect();
        Ok(Head { n, read })
    }

    fn write_head(&self, remote: &dyn Remote) -> Result<()> {
        let me = device_id(self.index())?;
        let rk = remote.key();
        let json = serde_json::to_string(&self.head(remote)?).expect("json");
        let path = format!("{}/head/{me}", self.sync_dir());
        let written = format!("{rk}:head");
        if self.index().meta_get(&written)?.as_deref() == Some(json.as_str())
            && remote.exists(&path)?
        {
            return Ok(());
        }
        let sealed = self.sealer().seal(json.as_bytes(), &self.head_aad(&me));
        remote.replace(&path, &mut &sealed[..])?;
        self.index().meta_set(&written, &json)
    }

    fn write_head_quietly(&self, remote: &dyn Remote) {
        let _ = self.write_head(remote);
    }

    fn pull(
        &self,
        remote: &Counted<'_>,
        report: &mut SyncReport,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()> {
        let me = device_id(self.index())?;
        let base = self.sync_dir();
        // First every new journal entry (small), so the screen knows how much is coming.
        // Fetched several at once (owner 2026-10-26: a device that had not synced for a
        // while sat on "Looking at Google Drive", reading them one by one).
        let mut wanted: Vec<(String, u64)> = Vec::new();
        let mut devices = remote.list(&format!("{base}/log"))?;
        devices.sort();
        for device in devices.into_iter().filter(|d| *d != me) {
            if !device.bytes().all(|b| b.is_ascii_hexdigit()) {
                continue;
            }
            let key = format!("{}:cursor:{device}", remote.key());
            let cursor: u64 = self
                .index()
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
            wanted.extend(entries.into_iter().map(|n| (device.clone(), n)));
        }
        let fetched: Vec<Mutex<Option<Entry>>> = wanted.iter().map(|_| Mutex::new(None)).collect();
        // The closure runs on several threads: no `self` in it (the index is single-threaded).
        let (sealer, vault_id) = (self.sealer(), self.id.as_str());
        let read = |i: &usize| -> Result<()> {
            let (device, n) = &wanted[*i];
            let mut sealed = Capped::new(MAX_SMALL);
            if !remote.get(&format!("{base}/log/{device}/{n}"), &mut sealed)? {
                return Ok(()); // not there (yet): this device's entries stop before it
            }
            let aad = crate::aad(vault_id, &format!("sync/log/{device}/{n}"));
            let json = sealer.open(&sealed.0, &aad)?;
            let entry: Entry =
                serde_json::from_slice(&json).map_err(|_| Error::Corrupt("sync log"))?;
            *fetched[*i].lock().unwrap_or_else(|p| p.into_inner()) = Some(entry);
            Ok(())
        };
        let jobs: Vec<usize> = (0..wanted.len()).collect();
        let mut read_so_far = 0u32;
        each_at_once(remote.parallel(), &jobs, &read, |_| {
            read_so_far += 1;
            progress(SyncProgress {
                phase: SyncPhase::Checking,
                done: read_so_far,
                total: jobs.len() as u32,
                bytes: 0,
                bytes_total: 0,
            });
            Ok(())
        })?;
        // In order per device, up to the first entry missing (as when read one by one).
        let mut todo: Vec<(String, u64, Entry)> = Vec::new();
        let mut stopped: Option<String> = None;
        for ((device, n), slot) in wanted.into_iter().zip(fetched) {
            if stopped.as_deref() == Some(device.as_str()) {
                continue;
            }
            match slot.into_inner().unwrap_or_else(|p| p.into_inner()) {
                Some(entry) => todo.push((device, n, entry)),
                None => stopped = Some(device),
            }
        }
        // Counted: only what will change here (owner 2026-10-25: 848 shown for 90 items).
        // An entry naming a revision this device has, an item it deleted for good, or a
        // deletion of an item it no longer holds is still read, but not counted.
        let mut total = 0u32;
        for (_, _, e) in &todo {
            for (id, rev) in &e.items {
                total += self.would_take(id, rev)? as u32;
            }
            for (id, _) in &e.gone {
                total += self.sealed_record(id)?.is_some() as u32;
            }
        }
        let mut done = 0u32;
        // Bringing in from the first byte (owner 2026-10-27: every step says what it does,
        // the sync runs in the background).
        if total > 0 {
            progress(SyncProgress {
                phase: SyncPhase::Receiving,
                done: 0,
                total,
                bytes: remote.bytes(),
                bytes_total: 0,
            });
        }
        let done_now = std::cell::Cell::new(0u32);
        let tick = || {
            progress(SyncProgress {
                phase: SyncPhase::Receiving,
                done: done_now.get(),
                total,
                bytes: remote.bytes(),
                bytes_total: 0,
            })
        };
        for (device, n, entry) in todo {
            // A few items at a time are fetched ahead, several at once (owner 2026-10-27:
            // bringing in went one request after another), then taken in here in order,
            // one by one, as before: the index is single-threaded.
            let batch = remote.parallel().clamp(1, MAX_AT_ONCE) * 2;
            for items in entry.items.chunks(batch) {
                let ahead = Ahead {
                    inner: remote,
                    got: Mutex::new(self.fetch_ahead(remote, items, &tick)?),
                };
                for (id, rev) in items {
                    let counted = self.would_take(id, rev)?;
                    let taken = self.take(&ahead, id, rev, report);
                    ahead.clear();
                    taken?;
                    if counted {
                        done += 1;
                        done_now.set(done);
                        progress(SyncProgress {
                            phase: SyncPhase::Receiving,
                            done,
                            total,
                            bytes: remote.bytes(),
                            bytes_total: 0,
                        });
                    }
                }
                ahead.clear_all();
            }
            for (id, hlc) in entry.gone {
                let counted = self.sealed_record(&id)?.is_some();
                self.take_gone(remote, &id, hlc, report)?;
                if counted {
                    done += 1;
                    progress(SyncProgress {
                        phase: SyncPhase::Receiving,
                        done,
                        total,
                        bytes: remote.bytes(),
                        bytes_total: 0,
                    });
                }
            }
            self.index()
                .meta_set(&format!("{}:cursor:{device}", remote.key()), &n.to_string())?;
        }
        Ok(())
    }

    fn fetch_ahead(
        &self,
        remote: &Counted<'_>,
        items: &[(String, String)],
        tick: &dyn Fn(),
    ) -> Result<std::collections::HashMap<String, Got>> {
        let base = self.sync_dir();
        let mut jobs = Vec::new();
        for (id, rev) in items {
            if !self.would_take(id, rev)? || self.sealed_record(id)?.is_some() {
                continue; // a merge with what is here: read as it goes, as before
            }
            jobs.push((
                id.clone(),
                rev.clone(),
                self.item_aad(id, "meta"),
                self.new_path(id, "data")?.with_extension("data.ahead"),
                self.new_path(id, "thumb")?.with_extension("thumb.ahead"),
            ));
        }
        let got = Mutex::new(std::collections::HashMap::new());
        if jobs.len() < 2 {
            return Ok(got.into_inner().unwrap_or_else(|p| p.into_inner()));
        }
        let sealer = self.sealer();
        let work = |(id, rev, aad, data, thumb): &(String, String, Vec<u8>, PathBuf, PathBuf)| -> Result<()> {
            let record_path = format!("{base}/records/{id}/{rev}");
            let mut sealed = Capped::new(MAX_SMALL);
            if !remote.get(&record_path, &mut sealed).unwrap_or(false) {
                return Ok(());
            }
            let Ok(record) = sealer.open(&sealed.0, aad)
                .ok()
                .and_then(|json| ItemRecord::from_json(&json).ok())
                .map(ItemRecord::upgraded)
                .ok_or(())
            else {
                return Ok(());
            };
            if record.rev != *rev {
                return Ok(());
            }
            let mut files = Vec::new();
            for (ext, local) in [("data", data), ("thumb", thumb)] {
                if ext == "thumb" && !record.has_thumbnail {
                    continue;
                }
                let path = format!("{base}/blobs/{id}.{}.{ext}", record.data_rev);
                let ok = fs::File::create(local)
                    .ok()
                    .map(|mut f| remote.get(&path, &mut f).unwrap_or(false))
                    .unwrap_or(false);
                if !ok {
                    let _ = fs::remove_file(local);
                    return Ok(());
                }
                files.push((path, local.clone()));
            }
            let mut got = got.lock().unwrap_or_else(|p| p.into_inner());
            got.insert(record_path, Got::Bytes(sealed.0));
            for (path, local) in files {
                got.insert(path, Got::File(local));
            }
            Ok(())
        };
        each_at_once_ticking(remote.parallel(), &jobs, &work, tick, |_| Ok(()))?;
        Ok(got.into_inner().unwrap_or_else(|p| p.into_inner()))
    }

    fn would_take(&self, id: &str, rev: &str) -> Result<bool> {
        if let Some(sealed) = self.sealed_record(id)? {
            return Ok(self.open_record(id, &sealed)?.rev != rev);
        }
        Ok(self.index().gone_hlc(id)?.is_none())
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

    fn fetch_blobs(&self, remote: &dyn Remote, id: &str, record: &ItemRecord) -> Result<()> {
        self.keep_content(id)?; // the content it replaces, into the version history
        for ext in ["data", "thumb"] {
            if ext == "thumb" && !record.has_thumbnail {
                continue;
            }
            let to = self.new_path(id, ext)?;
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

    fn take(
        &self,
        remote: &dyn Remote,
        id: &str,
        rev: &str,
        report: &mut SyncReport,
    ) -> Result<()> {
        // Already this revision here: nothing to read (a device catching up reads many
        // entries naming revisions it already has).
        if let Some(sealed) = self.sealed_record(id)? {
            if self.open_record(id, &sealed)?.rev == rev {
                self.index().set_synced(&remote.key(), id, rev)?;
                return Ok(());
            }
        }
        let Some((theirs, _)) = self.remote_record(remote, id, rev)? else {
            return Ok(()); // not uploaded yet, or cleaned up: a later entry will name it
        };
        observe_hlc(self.index(), theirs.hlc)?;
        let ours = self
            .sealed_record(id)?
            .map(|s| self.open_record(id, &s))
            .transpose()?;
        let synced = self.index().synced_rev(&remote.key(), id)?;
        let Some(ours) = ours else {
            // New here, unless this device deleted it for good after that revision.
            if let Some(gone_hlc) = self.index().gone_hlc(id)? {
                if gone_hlc > theirs.hlc {
                    return Ok(());
                }
                self.index().forget_gone(id)?;
            }
            self.fetch_blobs(remote, id, &theirs)?;
            self.store_record(id, &theirs)?;
            self.drop_held(id)?;
            self.index().set_synced(&remote.key(), id, rev)?;
            report.received += 1;
            return Ok(());
        };
        if ours.rev == theirs.rev {
            self.index().set_synced(&remote.key(), id, rev)?;
            return Ok(());
        }
        let changed_here = synced.as_deref() != Some(ours.rev.as_str());
        if !changed_here || theirs.base_rev.as_deref() == Some(ours.rev.as_str()) {
            // Only they changed it (or they built on ours): take theirs.
            if theirs.data_rev != ours.data_rev {
                self.fetch_blobs(remote, id, &theirs)?;
            }
            self.store_record(id, &theirs)?;
            self.index().set_synced(&remote.key(), id, rev)?;
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
        self.index().set_synced(&remote.key(), id, rev)?;
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
            out.has_thumbnail = theirs.has_thumbnail;
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
        observe_hlc(self.index(), hlc)?;
        let Some(sealed) = self.sealed_record(id)? else {
            return Ok(());
        };
        let ours = self.open_record(id, &sealed)?;
        let changed_here =
            self.index().synced_rev(&remote.key(), id)?.as_deref() != Some(ours.rev.as_str());
        if changed_here && ours.hlc > hlc {
            return Ok(()); // edited here after: it stays (and goes up again)
        }
        // Kept here for 30 days, not removed (owner 2026-10-25); a tag simply goes.
        let held = ours.kind != crate::items::kind::TAG;
        if held {
            self.hold_item(id, now_ms())?;
        } else {
            self.remove_item(id)?;
        }
        // Kept as a deletion to pass on to the other places, already known here. Our
        // revision is dropped unread there only if it is older than the deletion.
        let rev = if ours.hlc <= hlc {
            ours.rev.as_str()
        } else {
            ""
        };
        self.index().add_gone(id, hlc, rev)?;
        self.index().gone_sent(&remote.key(), id)?;
        if held {
            report.removed += 1;
        }
        Ok(())
    }

    fn lock_bytes(&self) -> Result<(u64, Vec<u8>)> {
        let header_file = self.dir().join(crate::HEADER_FILE);
        let library_file = self
            .dir()
            .parent()
            .and_then(Path::parent)
            .map(|d| d.join(crate::LIBRARY_FILE))
            .ok_or(Error::Corrupt("library"))?;
        let changed = [&header_file, &library_file]
            .iter()
            .filter_map(|f| fs::metadata(f).and_then(|m| m.modified()).ok())
            .filter_map(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as u64)
            .max()
            .unwrap_or(0);
        let vault: serde_json::Value = serde_json::from_slice(&fs::read(header_file)?)
            .map_err(|_| Error::Corrupt("vault header"))?;
        let library: serde_json::Value = serde_json::from_slice(&fs::read(library_file)?)
            .map_err(|_| Error::Corrupt("library.json"))?;
        let bytes = serde_json::to_vec(&serde_json::json!({ "vault": vault, "library": library }))
            .expect("json");
        Ok((changed, bytes))
    }

    fn push_lock(&self, remote: &dyn Remote, base: &str) -> Result<()> {
        let (changed, bytes) = self.lock_bytes()?;
        let name = format!("{changed:013}-{}.json", crate::items::sha256_hex(&bytes));
        let dir = format!("{base}/lock");
        let there = remote.list(&dir)?;
        let when = |n: &str| {
            n.split('-')
                .next()
                .and_then(|t| t.parse::<u64>().ok())
                .unwrap_or(0)
        };
        if there.iter().any(|n| when(n) > changed) {
            return Ok(());
        }
        if !there.contains(&name) {
            remote.put(&format!("{dir}/{name}"), &mut &bytes[..])?;
        }
        for old in there {
            if old != name {
                remote.remove(&format!("{dir}/{old}"))?;
            }
        }
        // The single header of the first sync builds.
        remote.remove(&format!("{base}/header.json"))
    }

    fn push(
        &self,
        remote: &Counted<'_>,
        report: &mut SyncReport,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()> {
        let rk = remote.key();
        let base = self.sync_dir();
        self.push_lock(remote, &base)?;
        // First what has changed here since this place last heard, so the screen knows
        // how much is going.
        let mut todo: Vec<(String, ItemRecord, Vec<u8>)> = Vec::new();
        let mut held: Vec<(String, ItemRecord, Vec<u8>)> = Vec::new();
        // Items from before sync need their content's fingerprints first: read several
        // at once (owner 2026-10-27: a first sync read a whole vault one file at a
        // time), with a count on the screen. Only the reading is shared out; the index
        // stays in this thread.
        let mut items = Vec::new();
        let mut fingerprint = Vec::new();
        for id in self.index().ids()? {
            let Some(sealed) = self.sealed_record(&id)? else {
                continue;
            };
            let record = self.open_record(&id, &sealed)?;
            if record.rev.is_empty() || record.data_hash.is_empty() {
                let thumb = record
                    .has_thumbnail
                    .then(|| self.read_path(&id, "thumb"))
                    .transpose()?;
                fingerprint.push((id.clone(), self.read_path(&id, "data")?, thumb));
            }
            items.push((id, record, sealed));
        }
        let hashes = Mutex::new(std::collections::HashMap::new());
        let hash = |(id, data, thumb): &(String, PathBuf, Option<PathBuf>)| -> Result<()> {
            let data = crate::items::file_sha256_hex(data)?;
            let thumb = thumb
                .as_deref()
                .map(crate::items::file_sha256_hex)
                .transpose()?;
            hashes
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(id.clone(), (data, thumb));
            Ok(())
        };
        let all = fingerprint.len() as u32;
        let mut read = 0u32;
        each_at_once(MAX_AT_ONCE, &fingerprint, &hash, |_| {
            read += 1;
            progress(SyncProgress {
                phase: SyncPhase::Preparing,
                done: read,
                total: all,
                bytes: 0,
                bytes_total: 0,
            });
            Ok(())
        })?;
        let mut hashes = hashes.into_inner().unwrap_or_else(|p| p.into_inner());
        for (id, mut record, mut sealed) in items {
            if let Some((data, thumb)) = hashes.remove(&id) {
                // From before sync: a first revision, with its content's fingerprints
                // (same content, same time).
                let modified = record.modified_ms;
                record.data_hash = data;
                if let Some(thumb) = thumb {
                    record.thumb_hash = thumb;
                }
                record.data_rev.clear(); // its content goes up under this new revision
                self.stamp(&mut record)?;
                record.modified_ms = modified;
                sealed = self.store_record(&id, &record)?;
            }
            if self.index().synced_rev(&rk, &id)?.as_deref() == Some(record.rev.as_str()) {
                // The place has this revision: check it still holds every file of it.
                held.push((id, record, sealed));
                continue;
            }
            todo.push((id, record, sealed));
        }
        self.mend_place(remote, &base, &held, report, progress)?;
        drop(held);
        let gone = self.index().gone_unsent(&rk)?;
        // Deletions are counted apart (Removing): they are not items going up.
        let total = todo.len() as u32;
        let start = remote.bytes();
        let mut bytes_total = 0u64;
        let mut jobs = Vec::with_capacity(todo.len());
        for (id, record, sealed) in todo {
            let mut files = Vec::new();
            for ext in ["data", "thumb"] {
                if ext == "thumb" && !record.has_thumbnail {
                    continue;
                }
                let local = self.read_path(&id, ext)?;
                bytes_total += fs::metadata(&local).map_or(0, |m| m.len());
                files.push((
                    format!("{base}/blobs/{id}.{}.{ext}", record.data_rev),
                    local,
                ));
            }
            bytes_total += sealed.len() as u64;
            jobs.push(Upload {
                record: format!("{base}/records/{id}/{}", record.rev),
                id,
                rev: record.rev,
                files,
                sealed,
            });
        }
        // Content first, the record last: a record in the place always has its content.
        let send = |job: &Upload| -> Result<()> {
            for (to, local) in &job.files {
                if !remote.exists(to)? {
                    remote.put_file(to, local)?;
                }
            }
            if !remote.exists(&job.record)? {
                remote.put(&job.record, &mut &job.sealed[..])?;
            }
            Ok(())
        };
        let mut done = 0u32;
        let mut entry = Entry::default();
        // Sending from the first byte (owner 2026-10-27: a big first file kept the screen
        // on "Looking at Google Drive" while it went up), and the bytes every second
        // while a file is on its way, not only when it is done.
        if total > 0 {
            progress(SyncProgress {
                phase: SyncPhase::Sending,
                done: 0,
                total,
                bytes: 0,
                bytes_total,
            });
        }
        let done_now = std::cell::Cell::new(0u32);
        let tick = || {
            progress(SyncProgress {
                phase: SyncPhase::Sending,
                done: done_now.get(),
                total,
                bytes: remote.bytes() - start,
                bytes_total,
            })
        };
        // Items are told in the order they are fully up, so a journal entry only ever
        // names items whose files are all in the place.
        each_at_once_ticking(remote.parallel(), &jobs, &send, tick, |i| {
            entry.items.push((jobs[i].id.clone(), jobs[i].rev.clone()));
            done += 1;
            done_now.set(done);
            progress(SyncProgress {
                phase: SyncPhase::Sending,
                done,
                total,
                bytes: remote.bytes() - start,
                bytes_total,
            });
            if entry.items.len() >= LOG_EVERY {
                self.send_entry(remote, std::mem::take(&mut entry), report)?;
            }
            Ok(())
        })?;
        // Before the deletions are told: stopped half-way, it is done again next time.
        self.clean_gone(remote, &base, &gone, progress)?;
        entry.gone = gone.into_iter().map(|(id, hlc, _)| (id, hlc)).collect();
        if !entry.items.is_empty() || !entry.gone.is_empty() {
            self.send_entry(remote, entry, report)?;
            progress(SyncProgress {
                phase: SyncPhase::Sending,
                done,
                total,
                bytes: remote.bytes() - start,
                bytes_total,
            });
        }
        // The head last, after every entry it counts (and before tidying, which may take
        // a while once a day).
        self.write_head_quietly(remote);
        self.collect_garbage(remote, now_ms(), progress)
    }

    fn mend_place(
        &self,
        remote: &Counted<'_>,
        base: &str,
        held: &[(String, ItemRecord, Vec<u8>)],
        report: &mut SyncReport,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()> {
        // A place that lists nothing about its files: nothing to check.
        let Some((first, r, _)) = held.first() else {
            return Ok(());
        };
        if remote
            .listed(&format!("{base}/records/{first}/{}", r.rev))
            .is_none()
        {
            return Ok(());
        }
        // First what needs sending again, so the screen can count it: the record, the
        // files (where they go, the copy here) and the record's path when it is missing.
        type Fix<'a> = (&'a [u8], Vec<(String, PathBuf)>, Option<String>);
        let mut fix: Vec<Fix<'_>> = Vec::new();
        for (id, record, sealed) in held {
            let mut bad = false;
            let mut good_here = true;
            let mut files = Vec::new();
            for (ext, want) in [("data", &record.data_hash), ("thumb", &record.thumb_hash)] {
                if ext == "thumb" && !record.has_thumbnail {
                    continue;
                }
                let path = format!("{base}/blobs/{id}.{}.{ext}", record.data_rev);
                let wrong = match remote.listed(&path) {
                    Some(Listed::Missing) => true,
                    Some(Listed::Sha256(h)) => !want.is_empty() && h != *want,
                    _ => false,
                };
                if wrong {
                    bad = true;
                    let local = self.read_path(id, ext)?;
                    if want.is_empty() || crate::items::file_sha256_hex(&local)? != *want {
                        good_here = false;
                    }
                    files.push((path, local));
                }
            }
            let record_path = format!("{base}/records/{id}/{}", record.rev);
            let record_missing = remote.listed(&record_path) == Some(Listed::Missing);
            if !bad && !record_missing {
                continue;
            }
            if !good_here {
                report.unrepaired += 1;
                continue;
            }
            fix.push((sealed, files, record_missing.then_some(record_path)));
        }
        let total = fix.len() as u32;
        let start = remote.bytes();
        for (n, (sealed, files, record_path)) in fix.iter().enumerate() {
            progress(SyncProgress {
                phase: SyncPhase::Repairing,
                done: n as u32,
                total,
                bytes: remote.bytes() - start,
                bytes_total: 0,
            });
            for (path, local) in files {
                // Files never change once written: the damaged one goes first.
                remote.remove(path)?;
                remote.put_file(path, local)?;
            }
            if let Some(record_path) = record_path {
                remote.put(record_path, &mut &sealed[..])?;
            }
            report.repaired += 1;
        }
        if total > 0 {
            progress(SyncProgress {
                phase: SyncPhase::Repairing,
                done: total,
                total,
                bytes: remote.bytes() - start,
                bytes_total: 0,
            });
        }
        Ok(())
    }

    fn collect_garbage(
        &self,
        remote: &Counted<'_>,
        now: i64,
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()> {
        if !remote.removes() {
            return Ok(());
        }
        let rk = remote.key();
        let at_key = format!("{rk}:gc-at");
        let last: i64 = self
            .index()
            .meta_get(&at_key)?
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        if now - last < GC_EVERY_MS {
            return Ok(());
        }
        progress(SyncProgress {
            phase: SyncPhase::Tidying,
            done: 0,
            total: 0,
            bytes: 0,
            bytes_total: 0,
        });
        let base = self.sync_dir();
        let cutoff = now - KEEP_OLD_MS;
        let mut todo = Vec::new();
        for id in self.index().ids()? {
            let Some(sealed) = self.sealed_record(&id)? else {
                continue;
            };
            let current = self.open_record(&id, &sealed)?;
            if current.rev.is_empty()
                || self.index().synced_rev(&rk, &id)?.as_deref() != Some(current.rev.as_str())
            {
                continue;
            }
            let revs = remote.list(&format!("{base}/records/{id}"))?;
            if revs.iter().any(|r| *r != current.rev) {
                todo.push((id, current, revs));
            }
        }
        if !todo.is_empty() {
            let blobs = remote.list(&format!("{base}/blobs"))?;
            let total = todo.len() as u32;
            let start = remote.bytes();
            let (mut records, mut contents) = (Vec::new(), Vec::new());
            for (n, (id, current, revs)) in todo.iter().enumerate() {
                // The other revisions, oldest first. Each record is read once per place,
                // its clock kept here; unreadable ones are left alone (and tried again).
                let mut known = std::collections::HashMap::new();
                for (rev, hlc, data_rev) in self.index().rev_clocks(&rk, id)? {
                    if rev == current.rev || !revs.contains(&rev) {
                        self.index().forget_rev_clock(&rk, id, &rev)?;
                    } else {
                        known.insert(rev, (hlc, data_rev));
                    }
                }
                let mut others: Vec<(i64, String, String)> = Vec::new();
                for rev in revs.iter().filter(|r| **r != current.rev) {
                    if let Some((hlc, data_rev)) = known.remove(rev) {
                        others.push((hlc, rev.clone(), data_rev));
                    } else if let Ok(Some((r, _))) = self.remote_record(remote, id, rev) {
                        self.index()
                            .set_rev_clock(&rk, id, rev, r.hlc, &r.data_rev)?;
                        others.push((r.hlc, r.rev, r.data_rev));
                    }
                }
                others.sort();
                let mut keep = BTreeSet::from([current.data_rev.clone()]);
                let mut dropped = BTreeSet::new();
                for (i, (hlc, rev, data_rev)) in others.iter().enumerate() {
                    let superseded = others
                        .get(i + 1)
                        .map_or(current.hlc, |o| o.0.min(current.hlc));
                    if *hlc < current.hlc && superseded <= cutoff {
                        records.push(format!("{base}/records/{id}/{rev}"));
                        self.index().forget_rev_clock(&rk, id, rev)?;
                        dropped.insert(data_rev.clone());
                    } else {
                        keep.insert(data_rev.clone());
                    }
                }
                let prefix = format!("{id}.");
                for name in &blobs {
                    let Some(rest) = name.strip_prefix(&prefix) else {
                        continue;
                    };
                    let data_rev = rest.rsplit_once('.').map_or("", |(d, _)| d);
                    if dropped.contains(data_rev) && !keep.contains(data_rev) {
                        contents.push(format!("{base}/blobs/{name}"));
                    }
                }
                let full = records.len() + contents.len() >= REMOVE_EVERY;
                if (full || n + 1 == todo.len()) && !(records.is_empty() && contents.is_empty()) {
                    remote.remove_many(&std::mem::take(&mut records))?;
                    remote.remove_many(&std::mem::take(&mut contents))?;
                    progress(SyncProgress {
                        phase: SyncPhase::Tidying,
                        done: n as u32 + 1,
                        total,
                        bytes: remote.bytes() - start,
                        bytes_total: 0,
                    });
                }
            }
        }
        self.index().meta_set(&at_key, &now.to_string())
    }

    fn clean_gone(
        &self,
        remote: &Counted<'_>,
        base: &str,
        unsent: &[Gone],
        progress: &dyn Fn(SyncProgress),
    ) -> Result<()> {
        if !remote.removes() {
            return Ok(());
        }
        let swept_key = format!("{}:gone-swept", remote.key());
        let swept = self.index().meta_get(&swept_key)?.is_some();
        let todo: Vec<Gone> = if swept {
            unsent.to_vec()
        } else {
            self.index().all_gone()?
        };
        if !todo.is_empty() {
            progress(SyncProgress {
                phase: SyncPhase::Removing,
                done: 0,
                total: todo.len() as u32,
                bytes: 0,
                bytes_total: 0,
            });
            let blobs = remote.list(&format!("{base}/blobs"))?;
            let total = todo.len() as u32;
            let start = remote.bytes();
            let (mut records, mut contents) = (Vec::new(), Vec::new());
            for (n, (id, hlc, last_rev)) in todo.iter().enumerate() {
                let mut keep = BTreeSet::new();
                for rev in remote.list(&format!("{base}/records/{id}"))? {
                    let path = format!("{base}/records/{id}/{rev}");
                    if !last_rev.is_empty() && rev == *last_rev {
                        records.push(path);
                        continue;
                    }
                    match self.remote_record(remote, id, &rev) {
                        Ok(Some((r, _))) if r.hlc > *hlc => {
                            keep.insert(r.data_rev);
                        }
                        Ok(_) => records.push(path),
                        // Unreadable: not ours to judge; leave it.
                        Err(_) => {}
                    }
                }
                let prefix = format!("{id}.");
                for name in &blobs {
                    let Some(rest) = name.strip_prefix(&prefix) else {
                        continue;
                    };
                    let data_rev = rest.rsplit_once('.').map_or("", |(d, _)| d);
                    if !keep.contains(data_rev) {
                        contents.push(format!("{base}/blobs/{name}"));
                    }
                }
                if records.len() + contents.len() >= REMOVE_EVERY || n + 1 == todo.len() {
                    remote.remove_many(&std::mem::take(&mut records))?;
                    remote.remove_many(&std::mem::take(&mut contents))?;
                    progress(SyncProgress {
                        phase: SyncPhase::Removing,
                        done: n as u32 + 1,
                        total,
                        bytes: remote.bytes() - start,
                        bytes_total: 0,
                    });
                }
            }
        }
        if !swept {
            self.index().meta_set(&swept_key, "1")?;
        }
        Ok(())
    }

    fn send_entry(&self, remote: &dyn Remote, entry: Entry, report: &mut SyncReport) -> Result<()> {
        let me = device_id(self.index())?;
        let rk = remote.key();
        let n: u64 = self
            .index()
            .meta_get(&format!("{rk}:seq"))?
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
            + 1;
        let json = serde_json::to_vec(&entry).expect("serialisable");
        let sealed = self.sealer().seal(&json, &self.log_aad(&me, n));
        remote.put(
            &format!("{}/log/{me}/{n}", self.sync_dir()),
            &mut &sealed[..],
        )?;
        self.index()
            .meta_set(&format!("{rk}:seq"), &n.to_string())?;
        for (id, rev) in &entry.items {
            self.index().set_synced(&rk, id, rev)?;
        }
        for (id, _) in &entry.gone {
            self.index().gone_sent(&rk, id)?;
        }
        report.sent += entry.items.len() as u32;
        Ok(())
    }
}

/// One item going up: its content files (place path, file here), then its record.
struct Upload {
    id: String,
    rev: String,
    files: Vec<(String, PathBuf)>,
    record: String,
    sealed: Vec<u8>,
}

/// Most items sent at once, whatever a place allows.
const MAX_AT_ONCE: usize = 4;
/// Files of deleted items removed per batch (Google Drive takes 100 per request).
const REMOVE_EVERY: usize = 100;

/// A revision superseded longer ago than this leaves the place (30 days).
const KEEP_OLD_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// Old revisions are looked for at most this often on a place (a day).
const GC_EVERY_MS: i64 = 24 * 60 * 60 * 1000;

/// Run `work` on every job, up to `n` at once on their own threads (here, in order,
/// when `n` is 1), and hand each job that worked to `done`, in this thread, as it
/// finishes. The first error (from `work` or `done`) stops the jobs not started yet,
/// waits for those running, and is returned; what they did is not handed on.
fn each_at_once<J: Sync>(
    n: usize,
    jobs: &[J],
    work: &(dyn Fn(&J) -> Result<()> + Sync),
    done: impl FnMut(usize) -> Result<()>,
) -> Result<()> {
    each_at_once_ticking(n, jobs, work, || {}, done)
}

/// [`each_at_once`], calling `tick` about every second while jobs run (several at
/// once only: one at a time has no free thread to tell from).
fn each_at_once_ticking<J: Sync>(
    n: usize,
    jobs: &[J],
    work: &(dyn Fn(&J) -> Result<()> + Sync),
    tick: impl Fn(),
    mut done: impl FnMut(usize) -> Result<()>,
) -> Result<()> {
    let n = n.clamp(1, MAX_AT_ONCE).min(jobs.len());
    if n <= 1 {
        for (i, job) in jobs.iter().enumerate() {
            work(job)?;
            done(i)?;
        }
        return Ok(());
    }
    let next = AtomicUsize::new(0);
    let halt = AtomicBool::new(false);
    let (tx, rx) = std::sync::mpsc::channel::<(usize, Result<()>)>();
    std::thread::scope(|s| {
        for _ in 0..n {
            let tx = tx.clone();
            let (next, halt) = (&next, &halt);
            s.spawn(move || {
                while !halt.load(Ordering::SeqCst) {
                    let i = next.fetch_add(1, Ordering::SeqCst);
                    let Some(job) = jobs.get(i) else { break };
                    let r = work(job);
                    if r.is_err() {
                        halt.store(true, Ordering::SeqCst);
                    }
                    if tx.send((i, r)).is_err() {
                        break;
                    }
                }
            });
        }
        drop(tx);
        let mut first = None;
        // Ends once every worker has stopped.
        // Ends once every worker has stopped (the channel closes).
        loop {
            let (i, r) = match rx.recv_timeout(std::time::Duration::from_secs(1)) {
                Ok(got) => got,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if first.is_none() {
                        tick();
                    }
                    continue;
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            if first.is_some() {
                continue;
            }
            if let Err(e) = r.and_then(|()| done(i)) {
                halt.store(true, Ordering::SeqCst);
                first = Some(e);
            }
        }
        first.map_or(Ok(()), Err)
    })
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
    /// A vault password, random each run: none is written in the code.
    pub(crate) fn pw() -> &'static str {
        static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        P.get_or_init(|| cs_core::hex::encode(cs_crypto::generate_salt()))
    }

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
            .create_vault("V", pw())
            .unwrap();
        copy_dir(da.path(), db.path());
        let a = Library::open_or_create(da.path(), FAST, sk.clone())
            .unwrap()
            .unlock(pw())
            .unwrap()
            .unwrap();
        let b = Library::open_or_create(db.path(), FAST, sk)
            .unwrap()
            .unlock(pw())
            .unwrap()
            .unwrap();
        assert_ne!(device_id(a.index()).unwrap(), device_id(b.index()).unwrap());
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
        // Later by the clock, not by luck: on a fast machine both edits can share a
        // millisecond, and then the device id decides (by design), not the order.
        std::thread::sleep(std::time::Duration::from_millis(5));
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

    const DAY: i64 = 24 * 60 * 60 * 1000;

    #[test]
    fn a_deletion_from_elsewhere_is_held_here_and_not_sent_back() {
        let t = two();
        let id = note(&t.a, "Bank", "PIN 4821");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.delete_item(&id).unwrap();
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(t.b.sync(&t.cloud).unwrap().removed, 1);
        // Out of the vault, kept in Recently deleted as "deleted on another device".
        assert!(t.b.items().unwrap().is_empty());
        let held = t.b.held().unwrap();
        assert_eq!(held.len(), 1);
        assert_eq!(held[0].id, id);
        assert!(held[0].deleted_ms.is_some());
        // Held is not live: syncing again sends nothing back, A stays without it.
        let again = t.b.sync(&t.cloud).unwrap();
        assert_eq!((again.sent, again.removed), (0, 0));
        t.a.sync(&t.cloud).unwrap();
        assert!(t.a.items().unwrap().is_empty());
        assert_eq!(t.b.held().unwrap().len(), 1);
    }

    #[test]
    fn a_held_item_restored_comes_back_everywhere_with_its_content() {
        let t = two();
        let id = note(&t.a, "Bank", "PIN 4821");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.delete_item(&id).unwrap();
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.b.restore_held(&id).unwrap();
        assert!(t.b.held().unwrap().is_empty());
        assert_eq!(text(&t.b, &id), "PIN 4821");
        t.b.sync(&t.cloud).unwrap();
        assert_eq!(t.a.sync(&t.cloud).unwrap().received, 1);
        assert_eq!(text(&t.a, &id), "PIN 4821");
    }

    #[test]
    fn a_held_item_goes_for_good_on_delete_now_or_after_30_days() {
        let t = two();
        let one = note(&t.a, "One", "1");
        let two_ = note(&t.a, "Two", "2");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.delete_item(&one).unwrap();
        t.a.delete_item(&two_).unwrap();
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(t.b.sync(&t.cloud).unwrap().removed, 2);
        t.b.purge_held(&one).unwrap();
        assert_eq!(t.b.held().unwrap().len(), 1);
        assert!(!t.b.path(&one, "data").unwrap().exists());
        let held_at = t.b.held().unwrap()[0].deleted_ms.unwrap();
        assert_eq!(t.b.purge_expired(held_at + 29 * DAY).unwrap(), 0);
        assert_eq!(t.b.purge_expired(held_at + 30 * DAY).unwrap(), 1);
        assert!(t.b.held().unwrap().is_empty());
        assert!(!t.b.path(&two_, "data").unwrap().exists());
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
        // The screen is told: getting it ready, then sending from the start (owner
        // 2026-10-27: it said "Looking at Google Drive" all along).
        let seen = std::sync::Mutex::new(Vec::new());
        assert_eq!(
            t.a.sync_with(&t.cloud, &|p| seen.lock().unwrap().push(p))
                .unwrap()
                .sent,
            1
        );
        let phases: Vec<_> = seen
            .into_inner()
            .unwrap()
            .iter()
            .map(|p| (p.phase, p.done))
            .collect();
        let prep = phases
            .iter()
            .position(|p| p.0 == SyncPhase::Preparing)
            .unwrap();
        let start = phases
            .iter()
            .position(|p| p.0 == SyncPhase::Sending)
            .unwrap();
        assert!(prep < start);
        assert_eq!(phases[start], (SyncPhase::Sending, 0));
        t.b.sync(&t.cloud).unwrap();
        assert_eq!(text(&t.b, &id), "x");
    }

    /// The files item `id` has in the place (records and content).
    fn files_of(t: &Two, id: &str) -> usize {
        let base = t.cloud.root.join(&t.a.id);
        let records = fs::read_dir(base.join("records").join(id)).map_or(0, |d| d.count());
        let prefix = format!("{id}.");
        let blobs = fs::read_dir(base.join("blobs")).map_or(0, |d| {
            d.flatten()
                .filter(|e| e.file_name().to_string_lossy().starts_with(&prefix))
                .count()
        });
        records + blobs
    }

    #[test]
    fn an_item_deleted_for_good_leaves_the_place() {
        let t = two();
        let keep = note(&t.a, "keep", "k");
        let gone = note(&t.a, "gone", "g");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        assert!(files_of(&t, &gone) >= 2);
        t.a.delete_item(&gone).unwrap();
        let seen = std::sync::Mutex::new(Vec::new());
        t.a.sync_with(&t.cloud, &|p| seen.lock().unwrap().push(p))
            .unwrap();
        assert_eq!(files_of(&t, &gone), 0);
        assert!(files_of(&t, &keep) >= 2);
        // Told apart from the items going up (none here).
        let seen = seen.into_inner().unwrap();
        assert!(seen
            .iter()
            .any(|p| (p.phase, p.done, p.total) == (SyncPhase::Removing, 1, 1)));
        assert!(seen
            .iter()
            .filter(|p| p.phase == SyncPhase::Sending)
            .all(|p| p.total == 0));
        // The other device still learns it is gone, and its record missing is no error.
        t.b.sync(&t.cloud).unwrap();
        assert!(t.b.sealed_record(&gone).unwrap().is_none());
        assert_eq!(text(&t.b, &keep), "k");
    }

    /// A place as before deleted items were cleaned: deletions are told, nothing removed.
    struct NoRemove<'a>(&'a FolderRemote);

    impl Remote for NoRemove<'_> {
        fn key(&self) -> String {
            self.0.key()
        }
        fn list(&self, dir: &str) -> Result<Vec<String>> {
            self.0.list(dir)
        }
        fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
            self.0.get(path, out)
        }
        fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
            self.0.put(path, src)
        }
        fn exists(&self, path: &str) -> Result<bool> {
            self.0.exists(path)
        }
    }

    #[test]
    fn deletions_told_before_cleaning_existed_are_cleaned_once() {
        let t = two();
        let gone = note(&t.a, "gone", "g");
        t.a.sync(&NoRemove(&t.cloud)).unwrap();
        t.a.delete_item(&gone).unwrap();
        t.a.sync(&NoRemove(&t.cloud)).unwrap();
        assert!(files_of(&t, &gone) >= 2);
        // The first sync with a place that removes sweeps every deletion kept here.
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(files_of(&t, &gone), 0);
    }

    /// A place that says what was asked of it: paths read, batches removed. It can take
    /// several items at once, and fail every put after the first `fail_after`.
    struct Watched<'a> {
        inner: &'a FolderRemote,
        at_once: usize,
        fail_after: Option<usize>,
        puts: AtomicUsize,
        gets: std::sync::Mutex<Vec<String>>,
        batches: std::sync::Mutex<Vec<usize>>,
        /// Reads of content under way now, and the most there ever were together.
        reading: AtomicUsize,
        most: AtomicUsize,
    }

    impl<'a> Watched<'a> {
        fn new(inner: &'a FolderRemote, at_once: usize) -> Self {
            Watched {
                inner,
                at_once,
                fail_after: None,
                puts: AtomicUsize::new(0),
                gets: Default::default(),
                batches: Default::default(),
                reading: AtomicUsize::new(0),
                most: AtomicUsize::new(0),
            }
        }

        fn got(&self, part: &str) -> usize {
            self.gets
                .lock()
                .unwrap()
                .iter()
                .filter(|p| p.contains(part))
                .count()
        }

        fn put_ok(&self) -> Result<()> {
            let n = self.puts.fetch_add(1, Ordering::SeqCst);
            match self.fail_after {
                Some(k) if n >= k => Err(Error::Corrupt("test: place failed")),
                _ => Ok(()),
            }
        }
    }

    impl Remote for Watched<'_> {
        fn key(&self) -> String {
            self.inner.key()
        }
        fn list(&self, dir: &str) -> Result<Vec<String>> {
            self.inner.list(dir)
        }
        fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
            self.gets.lock().unwrap().push(path.to_owned());
            if !path.contains("/blobs/") {
                return self.inner.get(path, out);
            }
            let now = self.reading.fetch_add(1, Ordering::SeqCst) + 1;
            self.most.fetch_max(now, Ordering::SeqCst);
            // Slow enough that several are under way together.
            std::thread::sleep(std::time::Duration::from_millis(2));
            let r = self.inner.get(path, out);
            self.reading.fetch_sub(1, Ordering::SeqCst);
            r
        }
        fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
            self.put_ok()?;
            self.inner.put(path, src)
        }
        fn put_file(&self, path: &str, local: &Path) -> Result<()> {
            self.put_ok()?;
            // Slow enough that several are under way together.
            std::thread::sleep(std::time::Duration::from_millis(1));
            self.inner.put_file(path, local)
        }
        fn exists(&self, path: &str) -> Result<bool> {
            self.inner.exists(path)
        }
        fn remove(&self, path: &str) -> Result<()> {
            self.inner.remove(path)
        }
        fn removes(&self) -> bool {
            true
        }
        fn remove_many(&self, paths: &[String]) -> Result<()> {
            if !paths.is_empty() {
                self.batches.lock().unwrap().push(paths.len());
            }
            for p in paths {
                self.inner.remove(p)?;
            }
            Ok(())
        }
        fn parallel(&self) -> usize {
            self.at_once
        }
    }

    #[test]
    fn a_deleted_item_with_one_revision_is_cleaned_unread() {
        let t = two();
        let gone = note(&t.a, "gone", "g");
        t.a.sync(&t.cloud).unwrap();
        t.a.delete_item(&gone).unwrap();
        let w = Watched::new(&t.cloud, 1);
        t.a.sync(&w).unwrap();
        assert_eq!(files_of(&t, &gone), 0);
        // Its record was this device's last revision: removed without reading it back.
        assert_eq!(w.got(&format!("/records/{gone}/")), 0);
    }

    #[test]
    fn a_revision_made_elsewhere_after_the_deletion_survives_with_its_content() {
        let t = two();
        let id = note(&t.a, "Keep", "v1");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.delete_item(&id).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
        t.b.replace_item(&id, "Keep", &b"v2"[..]).unwrap();
        t.b.sync(&t.cloud).unwrap();
        // A has not read B's journal yet (B's entry held back), so its cleaning meets
        // B's newer revision in the place.
        let me_b = device_id(t.b.index()).unwrap();
        let log_b = t.cloud.root.join(&t.a.id).join("log").join(&me_b);
        let held = t._dirs.2.path().join("held");
        fs::rename(&log_b, &held).unwrap();
        let w = Watched::new(&t.cloud, 1);
        t.a.sync(&w).unwrap();
        // Its own old revision went unread; B's was read, and stays with its content.
        let rev_b = t.b.record(&id).unwrap().rev;
        assert_eq!(w.got(&format!("/records/{id}/")), 1);
        assert_eq!(w.got(&format!("/records/{id}/{rev_b}")), 1);
        assert_eq!(
            t.cloud.list(&format!("{}/records/{id}", t.a.id)).unwrap(),
            vec![rev_b]
        );
        fs::rename(&held, &log_b).unwrap();
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(text(&t.a, &id), "v2");
    }

    #[test]
    fn items_go_up_several_at_once_and_the_journal_names_only_items_fully_up() {
        let t = two();
        let n = LOG_EVERY + 7;
        let ids: Vec<String> = (0..n).map(|i| note(&t.a, &format!("N{i}"), "x")).collect();
        // The place fails part-way through: whatever the journal names is all there.
        let mut w = Watched::new(&t.cloud, 4);
        w.fail_after = Some(LOG_EVERY * 2 + 9);
        assert!(t.a.sync(&w).is_err());
        let me = device_id(t.a.index()).unwrap();
        let base = t.a.sync_dir();
        for e in t.cloud.list(&format!("{base}/log/{me}")).unwrap() {
            let n: u64 = e.parse().unwrap();
            let mut sealed = Vec::new();
            t.cloud
                .get(&format!("{base}/log/{me}/{n}"), &mut sealed)
                .unwrap();
            let json = t.a.sealer().open(&sealed, &t.a.log_aad(&me, n)).unwrap();
            let entry: Entry = serde_json::from_slice(&json).unwrap();
            for (id, rev) in entry.items {
                let r = t.a.record(&id).unwrap();
                assert!(t
                    .cloud
                    .exists(&format!("{base}/records/{id}/{rev}"))
                    .unwrap());
                let data = format!("{base}/blobs/{id}.{}.data", r.data_rev);
                assert!(t.cloud.exists(&data).unwrap());
            }
        }
        t.b.sync(&t.cloud).unwrap();
        // Then the rest goes up, several at once, and every item arrives.
        let seen = std::sync::Mutex::new(Vec::new());
        t.a.sync_with(&Watched::new(&t.cloud, 4), &|p| {
            seen.lock().unwrap().push(p)
        })
        .unwrap();
        let sending: Vec<u32> = seen
            .into_inner()
            .unwrap()
            .iter()
            .filter(|p| p.phase == SyncPhase::Sending)
            .map(|p| p.done)
            .collect();
        assert!(sending.windows(2).all(|w| w[0] <= w[1]));
        t.b.sync(&t.cloud).unwrap();
        for id in &ids {
            assert_eq!(text(&t.b, id), "x");
        }
    }

    #[test]
    fn deleted_items_leave_the_place_in_batches() {
        let t = two();
        let n = 70;
        let ids: Vec<String> = (0..n).map(|i| note(&t.a, &format!("N{i}"), "x")).collect();
        t.a.sync(&t.cloud).unwrap();
        for id in &ids {
            t.a.delete_item(id).unwrap();
        }
        let w = Watched::new(&t.cloud, 1);
        let seen = std::sync::Mutex::new(Vec::new());
        t.a.sync_with(&w, &|p| seen.lock().unwrap().push(p))
            .unwrap();
        assert!(ids.iter().all(|id| files_of(&t, id) == 0));
        assert_eq!(w.got("/records/"), 0);
        // 140 files (a record and its content each) in a handful of batches, records
        // first; none read back.
        let batches = w.batches.into_inner().unwrap();
        assert_eq!(batches.iter().sum::<usize>(), 2 * n);
        assert!(batches.len() <= 4 && batches.iter().all(|b| *b <= REMOVE_EVERY));
        let removing: Vec<_> = seen
            .into_inner()
            .unwrap()
            .into_iter()
            .filter(|p| p.phase == SyncPhase::Removing)
            .collect();
        assert_eq!(removing.last().unwrap().done, n as u32);
        assert!(removing.len() >= 2);
    }

    /// A place that streams a file in pieces, saying how far it got after each.
    struct Streams {
        at: std::sync::Mutex<Vec<u64>>,
    }

    impl Remote for Streams {
        fn key(&self) -> String {
            "streams".into()
        }
        fn list(&self, _: &str) -> Result<Vec<String>> {
            Ok(Vec::new())
        }
        fn get(&self, _: &str, _: &mut dyn Write) -> Result<bool> {
            Ok(false)
        }
        fn put(&self, _: &str, src: &mut dyn Read) -> Result<()> {
            std::io::copy(src, &mut std::io::sink())?;
            Ok(())
        }
        fn exists(&self, _: &str) -> Result<bool> {
            Ok(false)
        }
        fn put_file_told(&self, _: &str, local: &Path, read: &dyn Fn(u64)) -> Result<()> {
            let len = fs::metadata(local)?.len();
            for _ in 0..4 {
                read(len / 4);
                self.at.lock().unwrap().push(len / 4);
            }
            Ok(())
        }
    }

    /// The bytes of a file going up count as they leave, not all at once at the end
    /// (the speed on screen stood still on a big file, then jumped).
    #[test]
    fn upload_bytes_count_on_the_way() {
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("f");
        fs::write(&local, vec![0u8; 4000]).unwrap();
        let place = Streams {
            at: Default::default(),
        };
        let counted = Counted {
            inner: &place,
            bytes: AtomicU64::new(0),
        };
        counted.put_file("v/blobs/x", &local).unwrap();
        assert_eq!(counted.bytes(), 4000);
        assert_eq!(place.at.lock().unwrap().len(), 4);
        // A place that does not stream: the whole file once it is up, counted once.
        let plain = FolderRemote::new(dir.path());
        let counted = Counted {
            inner: &plain,
            bytes: AtomicU64::new(0),
        };
        counted.put_file("v/blobs/y", &local).unwrap();
        assert_eq!(counted.bytes(), 4000);
    }

    // ---------- old revisions ----------

    /// Look for old revisions on `t.cloud` from device A, as if it were `now`.
    fn collect(t: &Two, now: i64) -> Vec<SyncProgress> {
        collect_on(t, &t.cloud, now)
    }

    fn collect_on(t: &Two, place: &dyn Remote, now: i64) -> Vec<SyncProgress> {
        let seen = std::sync::Mutex::new(Vec::new());
        let counted = Counted {
            inner: place,
            bytes: AtomicU64::new(0),
        };
        t.a.collect_garbage(&counted, now, &|p| seen.lock().unwrap().push(p))
            .unwrap();
        let seen = seen.into_inner().unwrap();
        // It always says first that it is tidying (owner 2026-10-27), then each batch.
        if let Some(first) = seen.first() {
            assert_eq!(
                (first.phase, first.done, first.total),
                (SyncPhase::Tidying, 0, 0)
            );
        }
        seen.into_iter().skip(1).collect()
    }

    /// The revisions of `id` on the place: (hlc, rev, data_rev), oldest first.
    fn revisions(t: &Two, id: &str) -> Vec<(i64, String, String)> {
        let mut out: Vec<_> = t
            .cloud
            .list(&format!("{}/records/{id}", t.a.sync_dir()))
            .unwrap()
            .iter()
            .map(|r| {
                let (r, _) = t.a.remote_record(&t.cloud, id, r).unwrap().unwrap();
                (r.hlc, r.rev, r.data_rev)
            })
            .collect();
        out.sort();
        out
    }

    fn contents(t: &Two, id: &str) -> Vec<String> {
        let mut out: Vec<String> = t
            .cloud
            .list(&format!("{}/blobs", t.a.sync_dir()))
            .unwrap()
            .into_iter()
            .filter(|n| n.starts_with(id))
            .collect();
        out.sort();
        out
    }

    #[test]
    fn revisions_superseded_over_30_days_ago_leave_the_place() {
        let t = two();
        let id = note(&t.a, "N1", "first text");
        let other = note(&t.a, "Other", "never changed");
        t.a.sync(&t.cloud).unwrap();
        // B syncs once, then not for a long time.
        t.b.sync(&t.cloud).unwrap();
        // r2 keeps r1's content; r3 has new content, which r4 keeps.
        t.a.rename_item(&id, "N2").unwrap();
        t.a.sync(&t.cloud).unwrap();
        t.a.replace_item(&id, "N3", &b"second text"[..]).unwrap();
        t.a.sync(&t.cloud).unwrap();
        t.a.rename_item(&id, "N4").unwrap();
        t.a.sync(&t.cloud).unwrap();
        let all = revisions(&t, &id);
        assert_eq!(all.len(), 4);
        assert_eq!(all[0].2, all[1].2);
        assert_eq!(all[2].2, all[3].2);
        assert_eq!(contents(&t, &id).len(), 2);
        let now = now_ms();
        // Nothing superseded 30 days ago yet.
        assert!(collect(&t, now + GC_EVERY_MS).is_empty());
        assert_eq!(revisions(&t, &id), all);
        // When only r1 was superseded (by r2) over 30 days ago: r1 goes, its content
        // stays (r2 uses it).
        let seen = collect(&t, all[2].0 - 1 + KEEP_OLD_MS);
        assert!(seen.iter().all(|p| p.phase == SyncPhase::Tidying) && !seen.is_empty());
        assert_eq!(revisions(&t, &id), all[1..]);
        assert_eq!(contents(&t, &id).len(), 2);
        // Later, r2 and r3 as well, and r1's content; the current revision and its content
        // (shared with r3) stay, as does the item never changed.
        collect(&t, now + KEEP_OLD_MS + 2 * GC_EVERY_MS);
        assert_eq!(revisions(&t, &id), all[3..]);
        assert_eq!(contents(&t, &id), vec![format!("{id}.{}.data", all[3].2)]);
        assert_eq!(revisions(&t, &other).len(), 1);
        assert_eq!(contents(&t, &other).len(), 1);
        // Once a day at most.
        let removed_again = collect(&t, now + KEEP_OLD_MS + 2 * GC_EVERY_MS + 1);
        assert!(removed_again.is_empty());
        // B, a month behind (it had r1), catches up through the journal.
        assert!(t.b.sync(&t.cloud).unwrap().received >= 1);
        assert_eq!(text(&t.b, &id), "second text");
        assert_eq!(names(&t.b), vec!["N4", "Other"]);
        assert_eq!(text(&t.b, &other), "never changed");
        // And both go on syncing.
        t.b.rename_item(&id, "N5").unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(names(&t.a), vec!["N5", "Other"]);
    }

    #[test]
    fn each_old_record_is_read_once_per_place() {
        let t = two();
        let id = note(&t.a, "N1", "text");
        t.a.sync(&t.cloud).unwrap();
        for n in 2..=4 {
            t.a.rename_item(&id, &format!("N{n}")).unwrap();
            t.a.sync(&t.cloud).unwrap();
        }
        let all = revisions(&t, &id);
        assert_eq!(all.len(), 4);
        let now = now_ms() + GC_EVERY_MS;
        // First pass: the three older records are read; nothing is old enough yet.
        let watched = Watched::new(&t.cloud, 1);
        assert!(collect_on(&t, &watched, now).is_empty());
        assert_eq!(watched.got("/records/"), 3);
        // The next day: nothing read again.
        let watched = Watched::new(&t.cloud, 1);
        assert!(collect_on(&t, &watched, now + GC_EVERY_MS).is_empty());
        assert_eq!(watched.got("/records/"), 0);
        // A new revision: only it is read (its predecessor became an older one).
        t.a.rename_item(&id, "N5").unwrap();
        t.a.sync(&t.cloud).unwrap();
        let watched = Watched::new(&t.cloud, 1);
        collect_on(&t, &watched, now + 2 * GC_EVERY_MS);
        assert_eq!(watched.got("/records/"), 1);
        // Removed ones are forgotten, and the clocks of the rest still decide.
        collect(&t, all[2].0 - 1 + KEEP_OLD_MS + 3 * GC_EVERY_MS);
        let left = revisions(&t, &id);
        assert_eq!(left.len(), 1);
        assert_eq!(
            t.a.index().rev_clocks(&t.cloud.key(), &id).unwrap().len(),
            left.len() - 1
        );
        // An item deleted for good takes its clocks along.
        t.a.delete_item(&id).unwrap();
        assert!(t
            .a
            .index()
            .rev_clocks(&t.cloud.key(), &id)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn a_revision_newer_than_this_devices_is_never_collected() {
        let t = two();
        let id = note(&t.a, "N1", "text");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        // B's newer revision is in the place but A has not taken it yet.
        t.b.rename_item(&id, "From B").unwrap();
        t.b.sync(&t.cloud).unwrap();
        let all = revisions(&t, &id);
        assert_eq!(all.len(), 2);
        collect(&t, now_ms() + 10 * KEEP_OLD_MS);
        assert_eq!(revisions(&t, &id), all);
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(names(&t.a), vec!["From B"]);
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

    #[test]
    fn the_connection_log_is_sealed_and_kept_short() {
        let t = two();
        for n in 0..(crate::CONNECTION_LOG_LEN + 5) {
            t.a.log_connection(&format!("line {n}")).unwrap();
        }
        let log = t.a.connection_log().unwrap();
        assert_eq!(log.len(), crate::CONNECTION_LOG_LEN);
        assert_eq!(log[0], format!("line {}", crate::CONNECTION_LOG_LEN + 4));
        // Nothing readable in the index file.
        fn all_bytes(dir: &Path, out: &mut Vec<u8>) {
            for e in fs::read_dir(dir).unwrap() {
                let p = e.unwrap().path();
                if p.is_dir() {
                    all_bytes(&p, out)
                } else {
                    out.extend(fs::read(&p).unwrap())
                }
            }
        }
        let mut bytes = Vec::new();
        all_bytes(t._dirs.0.path(), &mut bytes);
        assert!(!bytes.windows(6).any(|w| w == b"line 1"));
        assert!(t.b.connection_log().unwrap().is_empty());
    }

    #[test]
    fn the_newest_lock_replaces_the_one_in_the_place() {
        let t = two();
        let locks = |t: &Two| {
            let dir = t._dirs.2.path().join(t.a.sync_dir()).join("lock");
            let mut n: Vec<String> = fs::read_dir(dir)
                .map(|d| {
                    d.flatten()
                        .map(|e| e.file_name().to_string_lossy().into_owned())
                        .collect()
                })
                .unwrap_or_default();
            n.sort();
            n
        };
        t.a.sync(&t.cloud).unwrap();
        let first = locks(&t);
        assert_eq!(first.len(), 1);
        assert!(!t
            ._dirs
            .2
            .path()
            .join(t.a.sync_dir())
            .join("header.json")
            .exists());
        // A new password on A: its lock replaces the old one there.
        std::thread::sleep(std::time::Duration::from_millis(20));
        let la = Library::open_or_create(t._dirs.0.path(), FAST, crate::tests::sk()).unwrap();
        la.set_password(&t.a, "a brand new vault password 2026")
            .unwrap();
        t.a.sync(&t.cloud).unwrap();
        let second = locks(&t);
        assert_eq!(second.len(), 1);
        assert_ne!(second, first);
        // B, still on the old password, never puts its older lock back.
        t.b.sync(&t.cloud).unwrap();
        assert_eq!(locks(&t), second);
        let body = fs::read_to_string(
            t._dirs
                .2
                .path()
                .join(t.a.sync_dir())
                .join("lock")
                .join(&second[0]),
        )
        .unwrap();
        let mine = fs::read_to_string(t.a.dir().join(crate::HEADER_FILE)).unwrap();
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        let h: serde_json::Value = serde_json::from_str(&mine).unwrap();
        assert_eq!(v["vault"], h);
    }

    #[test]
    fn only_what_changes_here_is_counted_as_coming_in() {
        let t = two();
        let ids: Vec<String> = (0..10).map(|i| note(&t.a, &format!("N{i}"), "x")).collect();
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        for id in &ids[..7] {
            t.b.delete_item(id).unwrap();
        }
        t.b.sync(&t.cloud).unwrap();
        // B reads A's journal again from the start (its place forgotten): every entry names
        // an item B already has or deleted for good, so nothing is counted.
        t.b.forget_sync_place(&t.cloud.key()).unwrap();
        let seen = std::sync::Mutex::new(Vec::new());
        t.b.sync_with(&t.cloud, &|p| seen.lock().unwrap().push(p))
            .unwrap();
        let seen = seen.into_inner().unwrap();
        assert!(seen
            .iter()
            .filter(|p| p.phase == SyncPhase::Receiving)
            .all(|p| p.total == 0));
        assert!(t.b.sealed_record(&ids[0]).unwrap().is_none());
        assert_eq!(text(&t.b, &ids[9]), "x");
    }

    #[test]
    fn progress_counts_up_and_a_long_send_is_told_in_parts() {
        let t = two();
        let n = LOG_EVERY + 7;
        let ids: Vec<String> = (0..n).map(|i| note(&t.a, &format!("N{i}"), "x")).collect();
        let seen = std::sync::Mutex::new(Vec::new());
        t.a.sync_with(&t.cloud, &|p| seen.lock().unwrap().push(p))
            .unwrap();
        let seen = seen.into_inner().unwrap();
        let sending: Vec<_> = seen
            .iter()
            .filter(|p| p.phase == SyncPhase::Sending)
            .collect();
        assert_eq!(sending.last().unwrap().done, n as u32);
        assert!(sending.iter().all(|p| p.total == n as u32));
        // Bytes count up to at least what the changes come to (journal entries add a bit).
        let total_bytes = sending[0].bytes_total;
        assert!(total_bytes > 0 && sending.iter().all(|p| p.bytes_total == total_bytes));
        assert!(sending.windows(2).all(|w| w[0].bytes <= w[1].bytes));
        assert!(sending.last().unwrap().bytes >= total_bytes);
        // Two journal entries: the first LOG_EVERY items, then the rest.
        let me = device_id(t.a.index()).unwrap();
        let entries = t
            .cloud
            .list(&format!("{}/log/{me}", t.a.sync_dir()))
            .unwrap();
        assert_eq!(entries.len(), 2);
        let seen_b = std::sync::Mutex::new(Vec::new());
        t.b.sync_with(&t.cloud, &|p| seen_b.lock().unwrap().push(p))
            .unwrap();
        let seen_b = seen_b.into_inner().unwrap();
        let receiving: Vec<_> = seen_b
            .iter()
            .filter(|p| p.phase == SyncPhase::Receiving)
            .collect();
        // Told from the start, before the first item is in.
        assert_eq!((receiving[0].done, receiving[0].total), (0, n as u32));
        let last = *receiving.last().unwrap();
        assert_eq!(
            (last.phase, last.done, last.total),
            (SyncPhase::Receiving, n as u32, n as u32)
        );
        assert!(last.bytes > 0);
        assert_eq!(text(&t.b, &ids[n - 1]), "x");
    }

    #[test]
    fn bringing_in_reads_several_items_at_once_and_takes_them_in_order() {
        let t = two();
        let ids: Vec<String> = (0..12)
            .map(|i| note(&t.a, &format!("N{i}"), &format!("text {i}")))
            .collect();
        t.a.sync(&t.cloud).unwrap();
        // Owner 2026-10-27: bringing in went one request after another.
        let w = Watched::new(&t.cloud, 4);
        assert_eq!(t.b.sync(&w).unwrap().received, 12);
        assert!(w.most.load(Ordering::SeqCst) > 1);
        for (i, id) in ids.iter().enumerate() {
            assert_eq!(text(&t.b, id), format!("text {i}"));
        }
        // Each content file read once, and nothing left behind beside the items.
        assert_eq!(w.got("/blobs/"), 12);
        fn ahead_files(p: &Path) -> usize {
            fs::read_dir(p).map_or(0, |d| {
                d.flatten()
                    .map(|e| {
                        let p = e.path();
                        if p.is_dir() {
                            ahead_files(&p)
                        } else {
                            p.to_string_lossy().ends_with(".ahead") as usize
                        }
                    })
                    .sum()
            })
        }
        assert_eq!(ahead_files(t.b.dir()), 0);
    }

    fn me(v: &OpenVault) -> String {
        device_id(v.index()).unwrap()
    }

    /// The highest journal entry of `device` in the place.
    fn last_entry(t: &Two, device: &str) -> u64 {
        t.cloud
            .list(&format!("{}/log/{device}", t.a.id))
            .unwrap()
            .iter()
            .filter_map(|n| n.parse().ok())
            .max()
            .unwrap_or(0)
    }

    #[test]
    fn the_head_says_the_last_entry_and_what_was_read() {
        let t = two();
        let (a, b) = (me(&t.a), me(&t.b));
        note(&t.a, "one", "1");
        t.a.sync(&t.cloud).unwrap();
        let head = t.a.read_head(&t.cloud, &a).unwrap().unwrap();
        assert!(head.n >= 1);
        assert_eq!(head.n, last_entry(&t, &a));
        assert!(head.read.is_empty());
        // B read A's entries: its head says how far.
        t.b.sync(&t.cloud).unwrap();
        let hb = t.b.read_head(&t.cloud, &b).unwrap().unwrap();
        assert_eq!(hb.read.get(&a), Some(&head.n));
        assert_eq!(hb.n, last_entry(&t, &b));
        // A new entry: the head follows, in the same file.
        note(&t.a, "two", "2");
        t.a.sync(&t.cloud).unwrap();
        let again = t.a.read_head(&t.cloud, &a).unwrap().unwrap();
        assert_eq!(again.n, last_entry(&t, &a));
        assert!(again.n > head.n);
        // (A cursor only once B wrote an entry.)
        assert_eq!(again.read.get(&b).copied().unwrap_or(0), hb.n);
        let path = format!("{}/head/{a}", t.a.id);
        assert_eq!(t.cloud.list(&format!("{}/head", t.a.id)).unwrap().len(), 2);
        // Nothing new: not written again (sealing twice never gives the same bytes).
        let read = |p: &str| {
            let mut out = Vec::new();
            t.cloud.get(p, &mut out).unwrap();
            out
        };
        let before = read(&path);
        assert!(!before.windows(4).any(|w| w == b"read"));
        t.a.sync(&t.cloud).unwrap();
        assert_eq!(read(&path), before);
        // Sealed under its path: it cannot pass for another device's head.
        t.cloud
            .put(&format!("{}/head/{b}", t.a.id), &mut &before[..])
            .unwrap();
        assert!(t.a.read_head(&t.cloud, &b).is_err());
        assert!(t.a.read_head(&t.cloud, "0123").unwrap().is_none());
    }

    /// A place that refuses to rewrite heads.
    struct NoHead<'a>(&'a FolderRemote);

    impl Remote for NoHead<'_> {
        fn key(&self) -> String {
            self.0.key()
        }
        fn list(&self, dir: &str) -> Result<Vec<String>> {
            self.0.list(dir)
        }
        fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
            self.0.get(path, out)
        }
        fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
            self.0.put(path, src)
        }
        fn replace(&self, _: &str, _: &mut dyn Read) -> Result<()> {
            Err(Error::Corrupt("test: place failed"))
        }
        fn exists(&self, path: &str) -> Result<bool> {
            self.0.exists(path)
        }
    }

    #[test]
    fn a_head_that_cannot_be_written_does_not_fail_the_sync() {
        let t = two();
        let id = note(&t.a, "one", "the text");
        assert_eq!(t.a.sync(&NoHead(&t.cloud)).unwrap().sent, 1);
        let a = me(&t.a);
        assert!(t.a.read_head(&t.cloud, &a).unwrap().is_none());
        t.b.sync(&t.cloud).unwrap();
        assert_eq!(text(&t.b, &id), "the text");
        // The next sync writes it, though nothing else is new.
        t.a.sync(&t.cloud).unwrap();
        let head = t.a.read_head(&t.cloud, &a).unwrap().unwrap();
        assert_eq!(head.n, last_entry(&t, &a));
    }

    #[test]
    fn heads_changed_only_when_another_devices_head_moved() {
        let t = two();
        let (a, b) = (me(&t.a), me(&t.b));
        let at = |folder: &str, pairs: &[(&str, u64)]| HeadsSeen {
            folder_id: Some(folder.to_owned()),
            versions: pairs.iter().map(|(d, v)| (d.to_string(), *v)).collect(),
        };
        let changed = |now: HeadsSeen| t.a.heads_changed("p", Some(&now)).unwrap();
        // Nothing remembered yet: changed.
        assert!(changed(at("h", &[(&b, 4)])));
        t.a.remember_heads("p", &at("h", &[(&a, 1), (&b, 4)]))
            .unwrap();
        assert!(!changed(at("h", &[(&a, 1), (&b, 4)])));
        // This device's own head is left out.
        assert!(!changed(at("h", &[(&a, 9), (&b, 4)])));
        assert!(!changed(at("h", &[(&b, 4)])));
        // Another device wrote, is new, or its head is gone.
        assert!(changed(at("h", &[(&a, 1), (&b, 5)])));
        assert!(changed(at("h", &[(&a, 1), (&b, 4), ("c0", 1)])));
        assert!(changed(at("h", &[(&a, 1)])));
        // No folder of heads, or another place: changed.
        assert!(t.a.heads_changed("p", None).unwrap());
        assert!(t.a.heads_changed("q", Some(&at("h", &[(&b, 4)]))).unwrap());
        // The folder found again under another id is kept; what was seen stays.
        assert!(!changed(at("h2", &[(&b, 4)])));
        assert_eq!(
            t.a.heads_seen("p").unwrap(),
            Some(at("h2", &[(&a, 1), (&b, 4)]))
        );
    }

    #[test]
    fn a_version_from_another_device_by_sync_is_kept_too() {
        let t = two();
        let id = note(&t.a, "List", "milk");
        t.a.sync(&t.cloud).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.b.replace_item(&id, "List", &b"milk, eggs"[..]).unwrap();
        t.b.sync(&t.cloud).unwrap();
        t.a.sync(&t.cloud).unwrap();
        let h = t.a.history(&id).unwrap();
        assert_eq!(h.len(), 1);
        assert!(h[0].this_device);
        let mut old = Vec::new();
        t.a.read_history_item(&id, &h[0].rev, &mut old).unwrap();
        assert_eq!(old, b"milk");
        // On B, the version A wrote is one from another device.
        let hb = t.b.history(&id).unwrap();
        assert_eq!(hb.len(), 1);
        assert!(!hb[0].this_device);
    }
}
