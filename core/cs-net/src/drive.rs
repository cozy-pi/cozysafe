//! Google Drive as a sync place (docs/adr/0003-sync.md). The vault's sealed files live in
//! a folder the app made ("Cozy Safe"), one folder per vault inside it named by the
//! vault's id; with the `drive.file` scope the app sees only what it made, and Google
//! sees only sealed bytes and these names (random ids and numbers):
//!
//! ```text
//! Cozy Safe/<vault>/index/<bucket>/<item>.<rev>              records/<item>/<rev>
//! Cozy Safe/<vault>/content/<bucket>/<item>.<rev>.<ext>      blobs/<item>.<rev>.<ext>
//! Cozy Safe/<vault>/log/<device>.<n>                         log/<device>/<n>
//! Cozy Safe/<vault>/lock/<name>                              lock/<name>
//! ```
//!
//! (right: the path in the sync layout, after `<vault>/`). `<bucket>` is the last two hex
//! digits of the item's id ([`cs_vault::bucket_of`]), as on the device: no folder holds
//! more than about 1/256 of a vault's items. Folders are made when first needed and
//! stay. Every session needs a [`Permit::google_drive`] and an access token from the
//! person's sign-in; nothing runs in the background.
//!
//! Earlier versions kept the files flat: in "Cozy Safe" named by their whole sync path
//! (`<vault>/records/<id>/<rev>`, up to 0.1.57), or in the vault's folder named by the
//! rest (never released). Opening moves them into place, one rename each, no bytes sent
//! again.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::{Read, Write};
use std::ops::Bound;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Mutex};

use cs_vault::bucket_of;
use cs_vault::sync::Remote;
use cs_vault::{Error, Result};
use serde_json::Value;

use crate::https::{self, Body};
use crate::Permit;

/// The folder the app keeps in the person's Drive.
pub const FOLDER: &str = "Cozy Safe";
const FOLDER_MIME: &str = "application/vnd.google-apps.folder";
/// Uploads up to this size are held in memory while sent.
const SMALL_UPLOAD: u64 = 1 << 20;
/// Items a sync sends at once: one kept connection each (round trips overlap).
const AT_ONCE: usize = https::POOL;
/// Most calls in one batch request (Google takes up to 100 calls in one).
const BATCH: usize = 100;
/// Largest answer to a batch read (100 short answers come to a few tens of KiB).
const MAX_BATCH_ANSWER: usize = 1 << 20;
/// Read at most this much of a failed answer, for Google's reason.
const ERROR_ANSWER: usize = 64 << 10;
/// Separates the parts of a batch request. Drive ids are letters, digits, '-' and '_',
/// and no line of a part starts with "--", so it never occurs inside one.
const BOUNDARY: &str = "cozysafe_batch_9c1e4b";

/// A file or folder in Drive.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    pub id: String,
    pub name: String,
    /// Its folder (the first, should it have several).
    pub parent: String,
    pub folder: bool,
    /// The SHA-256 Google keeps of the file's bytes (lowercase hex), when it gave one.
    pub sha256: Option<String>,
}

/// A file going into another folder under another name; its bytes stay where they are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Move {
    pub id: String,
    /// The folder it leaves.
    pub from: String,
    /// The folder it goes to.
    pub to: String,
    /// Its name there.
    pub name: String,
}

/// What the sync needs from Drive, so the logic is tested without the network.
pub trait DriveApi: Send + Sync {
    /// The app's folder, made if missing.
    fn folder(&self) -> Result<String>;
    /// Every file and folder the app can see (its own: `drive.file`), not in the bin;
    /// `listed` hears how many so far, page by page.
    fn tree(&self, listed: &dyn Fn(u32)) -> Result<Vec<Node>>;
    /// A new folder named `name` in `parent`; its id.
    fn make_folder(&self, parent: &str, name: &str) -> Result<String>;
    /// The file's bytes into `out`; false if it is gone.
    fn download(&self, id: &str, out: &mut dyn Write) -> Result<bool>;
    /// A new file named `name` in `folder`, `len` bytes from `src`; its id.
    fn upload(&self, folder: &str, name: &str, len: u64, src: &mut dyn Read) -> Result<String>;
    /// Move the file (its id stays); false if it is gone.
    fn move_file(&self, m: &Move) -> Result<bool>;
    /// [`DriveApi::move_file`] for many, in as few requests as the API allows; for each,
    /// whether it moved (false: gone).
    fn move_many(&self, moves: &[Move]) -> Result<Vec<bool>> {
        moves.iter().map(|m| self.move_file(m)).collect()
    }
    /// Delete the file (an old copy of the vault's lock, or a deleted item's files).
    fn delete(&self, id: &str) -> Result<()>;
    /// Delete many files (gone already is fine), in as few requests as the API allows.
    fn delete_many(&self, ids: &[String]) -> Result<()> {
        for id in ids {
            self.delete(id)?;
        }
        Ok(())
    }
}

/// What [`DriveRemote::open_with`] is doing, for the screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DrivePhase {
    /// Listing what the app has in Drive: `done` files and folders so far, `total` 0.
    Listing,
    /// Making the folders files are about to move into: `done` of `total`.
    Folders,
    /// Moving files of an earlier layout into place: `done` of `total`.
    Moving,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DriveSetup {
    pub phase: DrivePhase,
    pub done: u32,
    pub total: u32,
}

/// Per vault, the path after `<vault>/` → the file's id. Sorted, so a directory lists
/// as a range; boxed strings, as small as they come (about 170 bytes a file).
type Files = BTreeMap<Box<str>, Box<str>>;

/// The sync place: the app's Drive folder, listed once per session.
pub struct DriveRemote<A: DriveApi> {
    api: A,
    /// The "Cozy Safe" folder.
    root: String,
    /// Folder path under "Cozy Safe" (`<vault>/index/ab`) → id, made when first needed.
    folders: Mutex<HashMap<String, String>>,
    /// Vault id → its files, by sync path; kept up to date as files come and go.
    index: Mutex<HashMap<Box<str>, Files>>,
    /// Paths being uploaded right now (items go up a few at once).
    uploading: Mutex<HashSet<String>>,
    /// Set by Cancel: the next request ends the sync (what was done is kept).
    stop: Option<&'static AtomicBool>,
    /// Files of an earlier layout moved into place on open.
    moved: u32,
    /// File id → the SHA-256 Google listed for it on open (files sent since have none yet).
    sums: HashMap<Box<str>, Box<str>>,
}

/// A vault's id, as the app makes them: 32 lowercase hex digits.
fn is_vault(name: &str) -> bool {
    name.len() == 32 && name.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn is_bucket(name: &str) -> bool {
    name.len() == 2 && name.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A sync path's vault and the rest.
fn split(path: &str) -> Option<(&str, &str)> {
    path.split_once('/')
        .filter(|(vault, rest)| is_vault(vault) && !rest.is_empty())
}

/// Where a vault's file goes: (folder inside the vault's folder, file name), from its
/// path after `<vault>/`. `None` for anything outside the layout.
fn place(rest: &str) -> Option<(String, String)> {
    let one = |s: &str| !s.is_empty() && !s.contains('/');
    let (top, tail) = rest.split_once('/')?;
    match top {
        "records" => {
            let (item, rev) = tail.split_once('/')?;
            one(rev).then_some(())?;
            Some((
                format!("index/{}", bucket_of(item)?),
                format!("{item}.{rev}"),
            ))
        }
        "blobs" => {
            one(tail).then_some(())?;
            let (item, _) = tail.split_once('.')?;
            Some((format!("content/{}", bucket_of(item)?), tail.to_owned()))
        }
        "log" => {
            let (device, n) = tail.split_once('/')?;
            (one(device) && !device.contains('.') && one(n)).then_some(())?;
            Some(("log".to_owned(), format!("{device}.{n}")))
        }
        "lock" => one(tail).then(|| ("lock".to_owned(), tail.to_owned())),
        _ => None,
    }
}

/// The other way: the path after `<vault>/` of file `name` in folder `sub` of the
/// vault's folder, if it is one [`place`] puts there.
fn unplace(sub: &str, name: &str) -> Option<String> {
    let rest = match sub.split_once('/') {
        Some(("index", _)) => {
            let (item, rev) = name.split_once('.')?;
            format!("records/{item}/{rev}")
        }
        Some(("content", _)) => format!("blobs/{name}"),
        None if sub == "log" => {
            let (device, n) = name.split_once('.')?;
            format!("log/{device}/{n}")
        }
        None if sub == "lock" => format!("lock/{name}"),
        _ => return None,
    };
    let (s, n) = place(&rest)?;
    (s == sub && n == name).then_some(rest)
}

/// The folders the layout has under "Cozy Safe": `<vault>`, `<vault>/{index,content,
/// log,lock}`, `<vault>/{index,content}/<bucket>`.
fn folder_ok(path: &str) -> bool {
    match path.split('/').collect::<Vec<_>>().as_slice() {
        [v] => is_vault(v),
        [v, sub] => is_vault(v) && ["index", "content", "log", "lock"].contains(sub),
        [v, sub, b] => is_vault(v) && ["index", "content"].contains(sub) && is_bucket(b),
        _ => false,
    }
}

impl<A: DriveApi> DriveRemote<A> {
    pub fn open(api: A) -> Result<Self> {
        Self::open_with(api, &|_| {})
    }

    /// [`DriveRemote::open`], telling `progress` how the listing, the folders and the
    /// moves of an earlier layout go.
    pub fn open_with(api: A, progress: &dyn Fn(DriveSetup)) -> Result<Self> {
        let root = api.folder()?;
        let nodes = api.tree(&|done| {
            progress(DriveSetup {
                phase: DrivePhase::Listing,
                done,
                total: 0,
            })
        })?;
        // Folder paths, level by level (three at most); a path's folder is the first by
        // id, should two devices have made one at once.
        let mut paths: HashMap<&str, String> = HashMap::new();
        for _ in 0..3 {
            let mut more = Vec::new();
            for n in nodes
                .iter()
                .filter(|n| n.folder && !paths.contains_key(n.id.as_str()))
            {
                let above = if n.parent == root {
                    Some(String::new())
                } else {
                    paths.get(n.parent.as_str()).map(|p| format!("{p}/"))
                };
                if let Some(path) = above.map(|p| p + &n.name).filter(|p| folder_ok(p)) {
                    more.push((n.id.as_str(), path));
                }
            }
            paths.extend(more);
        }
        let mut found: Vec<(&String, &str)> = paths.iter().map(|(id, p)| (p, *id)).collect();
        found.sort();
        let mut folders: HashMap<String, String> = HashMap::new();
        for (path, id) in found {
            folders.entry(path.clone()).or_insert_with(|| id.to_owned());
        }
        // Every file by its sync path; those not where the layout puts them are gathered.
        let mut index: HashMap<Box<str>, Files> = HashMap::new();
        let mut astray = Vec::new();
        for n in nodes.iter().filter(|n| !n.folder) {
            let at = if n.parent == root {
                ""
            } else {
                match paths.get(n.parent.as_str()) {
                    Some(p) => p.as_str(),
                    None => continue,
                }
            };
            let path = match at.split_once('/') {
                // Flat in "Cozy Safe", named by the whole path (up to 0.1.57).
                _ if at.is_empty() => n.name.clone(),
                // Flat in the vault's folder, named by the rest (never released).
                None => format!("{at}/{}", n.name),
                Some((vault, sub)) => match unplace(sub, &n.name) {
                    Some(rest) => format!("{vault}/{rest}"),
                    None => continue,
                },
            };
            let Some((vault, rest)) = split(&path).filter(|_| check(&path).is_ok()) else {
                continue;
            };
            let home = place(rest).map(|(sub, name)| (format!("{vault}/{sub}"), name));
            let in_place = match &home {
                Some((folder, name)) => {
                    folder == at && *name == n.name && folders.get(at) == Some(&n.parent)
                }
                // Not in the layout (a first sync's header.json): known where it is.
                None => true,
            };
            if in_place {
                index
                    .entry(vault.into())
                    .or_default()
                    .entry(rest.into())
                    .or_insert_with(|| n.id.as_str().into());
            } else {
                astray.push((path, n.id.clone(), n.parent.clone(), home));
            }
        }
        let sums = nodes
            .iter()
            .filter_map(|n| Some((n.id.as_str().into(), n.sha256.as_deref()?.into())))
            .collect();
        drop(nodes);
        let mut remote = DriveRemote {
            api,
            root,
            folders: Mutex::new(folders),
            index: Mutex::new(index),
            uploading: Mutex::new(HashSet::new()),
            stop: None,
            moved: 0,
            sums,
        };
        remote.moved = remote.gather(astray, progress)?;
        Ok(remote)
    }

    /// How many files of an earlier layout opening moved into place.
    pub fn moved(&self) -> u32 {
        self.moved
    }

    /// Bring `astray` files (sync path, id, folder, where the layout puts it) into place:
    /// moved, or deleted when the right place has that file already (files never change,
    /// so the copies are the same). Each move is one rename, so a move cut short leaves
    /// every file in one place or the other, and the next open goes on. The folders the
    /// moves need are made first, a few at once; how many files moved.
    #[allow(clippy::type_complexity)]
    fn gather(
        &self,
        astray: Vec<(String, String, String, Option<(String, String)>)>,
        progress: &dyn Fn(DriveSetup),
    ) -> Result<u32> {
        // (file id, folder it leaves, folder path it goes to, name there, sync path)
        let mut wanted = Vec::new();
        let mut copies = Vec::new();
        let mut seen = HashSet::new();
        for (path, id, from, home) in astray {
            let Some((folder, name)) = home else {
                continue;
            };
            if self.id(&path).is_some() || !seen.insert(path.clone()) {
                copies.push(id);
                continue;
            }
            wanted.push((id, from, folder, name, path));
        }
        let needed: BTreeSet<&str> = wanted.iter().map(|w| w.2.as_str()).collect();
        self.make_folders(&needed, progress)?;
        let mut moves = Vec::with_capacity(wanted.len());
        let mut paths = Vec::with_capacity(wanted.len());
        for (id, from, folder, name, path) in wanted {
            moves.push(Move {
                id,
                from,
                to: self.folder_id(&folder)?,
                name,
            });
            paths.push(path);
        }
        let total = moves.len() as u32;
        let mut done = 0;
        let mut count = 0;
        if total > 0 {
            progress(DriveSetup {
                phase: DrivePhase::Moving,
                done,
                total,
            });
        }
        for (chunk, paths) in moves.chunks(BATCH).zip(paths.chunks(BATCH)) {
            let moved = self.api.move_many(chunk)?;
            if moved.len() != chunk.len() {
                return Err(Error::Corrupt("drive move answer"));
            }
            for ((m, path), ok) in chunk.iter().zip(paths).zip(moved) {
                if ok {
                    self.know(path, &m.id);
                    count += 1;
                }
            }
            done += chunk.len() as u32;
            progress(DriveSetup {
                phase: DrivePhase::Moving,
                done,
                total,
            });
        }
        if !copies.is_empty() {
            self.api.delete_many(&copies)?;
        }
        Ok(count)
    }

    /// Make the folders at `paths` under "Cozy Safe" that are missing, with the ones
    /// above them: level by level (a folder needs its parent's id), up to [`AT_ONCE`]
    /// at once through the kept connections. Only these, so no folder is made that no
    /// file goes into. Opening runs alone, so nothing else makes folders meanwhile; one
    /// already known is never made again.
    fn make_folders(&self, paths: &BTreeSet<&str>, progress: &dyn Fn(DriveSetup)) -> Result<()> {
        // Every missing folder, its parents too, by depth.
        let mut levels: BTreeMap<usize, BTreeSet<String>> = BTreeMap::new();
        {
            let folders = self.folders.lock().unwrap_or_else(|p| p.into_inner());
            for path in paths {
                let mut at = String::new();
                for (depth, part) in path.split('/').enumerate() {
                    if depth > 0 {
                        at.push('/');
                    }
                    at.push_str(part);
                    if !folders.contains_key(&at) {
                        levels.entry(depth).or_default().insert(at.clone());
                    }
                }
            }
        }
        let total: u32 = levels.values().map(|l| l.len() as u32).sum();
        if total == 0 {
            return Ok(());
        }
        let mut done = 0;
        progress(DriveSetup {
            phase: DrivePhase::Folders,
            done,
            total,
        });
        for level in levels.into_values() {
            // (path, parent id, name), parents all known by now.
            let jobs: Vec<(String, String, String)> = {
                let folders = self.folders.lock().unwrap_or_else(|p| p.into_inner());
                level
                    .into_iter()
                    .filter(|p| !folders.contains_key(p))
                    .map(|p| {
                        let (parent, name) = match p.rsplit_once('/') {
                            Some((above, name)) => (folders.get(above).cloned(), name.to_owned()),
                            None => (Some(self.root.clone()), p.clone()),
                        };
                        Ok((p, parent.ok_or(Error::Corrupt("drive folder"))?, name))
                    })
                    .collect::<Result<_>>()?
            };
            let next = AtomicUsize::new(0);
            let failed = AtomicBool::new(false);
            let (tx, rx) = mpsc::channel::<(usize, Result<String>)>();
            let mut first_error = None;
            std::thread::scope(|scope| {
                for _ in 0..AT_ONCE.min(jobs.len()) {
                    let tx = tx.clone();
                    let (jobs, next, failed) = (&jobs, &next, &failed);
                    scope.spawn(move || loop {
                        if failed.load(Ordering::Relaxed) {
                            return;
                        }
                        let n = next.fetch_add(1, Ordering::Relaxed);
                        let Some((_, parent, name)) = jobs.get(n) else {
                            return;
                        };
                        let made = self.api.make_folder(parent, name);
                        if made.is_err() {
                            failed.store(true, Ordering::Relaxed);
                        }
                        if tx.send((n, made)).is_err() {
                            return;
                        }
                    });
                }
                drop(tx);
                // Each folder is known as soon as it is made (kept even if another
                // fails), and counted here, on the caller's thread.
                for (n, made) in rx {
                    match made {
                        Ok(id) => {
                            self.folders
                                .lock()
                                .unwrap_or_else(|p| p.into_inner())
                                .entry(jobs[n].0.clone())
                                .or_insert(id);
                            done += 1;
                            progress(DriveSetup {
                                phase: DrivePhase::Folders,
                                done,
                                total,
                            });
                        }
                        Err(e) => {
                            first_error.get_or_insert(e);
                        }
                    }
                }
            });
            if let Some(e) = first_error {
                return Err(e);
            }
        }
        Ok(())
    }

    /// Stop at the next request once `stop` is set.
    pub fn stop_on(mut self, stop: &'static AtomicBool) -> Self {
        self.stop = Some(stop);
        self
    }

    fn go_on(&self) -> Result<()> {
        if self.stop.is_some_and(|s| s.load(Ordering::Relaxed)) {
            return Err(Error::Corrupt("drive cancelled"));
        }
        Ok(())
    }

    /// The vaults this Drive folder holds a lock for (to join one on a new device).
    pub fn vault_ids(&self) -> Vec<String> {
        let index = self.index.lock().unwrap_or_else(|p| p.into_inner());
        let mut ids: Vec<String> = index
            .iter()
            .filter(|(_, files)| first_under(files, "lock/").is_some())
            .map(|(vault, _)| vault.to_string())
            .collect();
        ids.sort();
        ids
    }

    fn id(&self, path: &str) -> Option<String> {
        let (vault, rest) = path.split_once('/')?;
        let index = self.index.lock().unwrap_or_else(|p| p.into_inner());
        index.get(vault)?.get(rest).map(|id| id.to_string())
    }

    fn know(&self, path: &str, id: &str) {
        if let Some((vault, rest)) = path.split_once('/') {
            self.index
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .entry(vault.into())
                .or_default()
                .insert(rest.into(), id.into());
        }
    }

    fn forget(&self, path: &str) -> Option<String> {
        let (vault, rest) = path.split_once('/')?;
        let mut index = self.index.lock().unwrap_or_else(|p| p.into_inner());
        index.get_mut(vault)?.remove(rest).map(|id| id.to_string())
    }

    /// The folder at `path` under "Cozy Safe", made (with the ones above it) the first
    /// time. Held while made, so items going up at once never make two.
    fn folder_id(&self, path: &str) -> Result<String> {
        let mut folders = self.folders.lock().unwrap_or_else(|p| p.into_inner());
        let mut parent = self.root.clone();
        let mut at = String::new();
        for part in path.split('/') {
            if !at.is_empty() {
                at.push('/');
            }
            at.push_str(part);
            parent = match folders.get(&at) {
                Some(id) => id.clone(),
                None => {
                    let id = self.api.make_folder(&parent, part)?;
                    folders.insert(at.clone(), id.clone());
                    id
                }
            };
        }
        Ok(parent)
    }

    /// Every sync path known, with its file's id (tests).
    #[cfg(test)]
    fn known(&self) -> Vec<(String, String)> {
        let index = self.index.lock().unwrap();
        let mut out: Vec<(String, String)> = index
            .iter()
            .flat_map(|(v, files)| {
                files
                    .iter()
                    .map(move |(r, id)| (format!("{v}/{r}"), id.to_string()))
            })
            .collect();
        out.sort();
        out
    }
}

/// The first file whose path starts with `prefix`.
fn first_under<'a>(files: &'a Files, prefix: &str) -> Option<&'a str> {
    files
        .range::<str, _>((Bound::Included(prefix), Bound::Unbounded))
        .next()
        .map(|(k, _)| &**k)
        .filter(|k| k.starts_with(prefix))
}

/// Names in the layout are relative paths of plain segments; anything else is refused
/// before it reaches Drive.
fn check(path: &str) -> Result<()> {
    let ok = !path.is_empty()
        && path
            .split('/')
            .all(|s| !s.is_empty() && s != "." && s != ".." && !s.contains(['\\', ':', '\0']));
    if ok {
        Ok(())
    } else {
        Err(Error::Corrupt("drive path"))
    }
}

impl<A: DriveApi> Remote for DriveRemote<A> {
    fn key(&self) -> String {
        "google-drive".to_owned()
    }

    fn list(&self, dir: &str) -> Result<Vec<String>> {
        check(dir)?;
        let (vault, prefix) = match dir.split_once('/') {
            Some((vault, sub)) => (vault, format!("{sub}/")),
            None => (dir, String::new()),
        };
        let index = self.index.lock().unwrap_or_else(|p| p.into_inner());
        let Some(files) = index.get(vault) else {
            return Ok(Vec::new());
        };
        let mut names: Vec<String> = files
            .range::<str, _>((Bound::Included(prefix.as_str()), Bound::Unbounded))
            .map(|(k, _)| &**k)
            .take_while(|k| k.starts_with(&prefix))
            .map(|k| k[prefix.len()..].split('/').next().unwrap_or("").to_owned())
            .collect();
        names.sort();
        names.dedup();
        Ok(names)
    }

    fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
        check(path)?;
        self.go_on()?;
        match self.id(path) {
            Some(id) => self.api.download(&id, out),
            None => Ok(false),
        }
    }

    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        check(path)?;
        self.go_on()?;
        // Records and journal entries: small (the sync caps what it reads back at 1 MiB).
        let mut bytes = Vec::new();
        src.take(https::MAX_SMALL as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > https::MAX_SMALL {
            return Err(Error::Corrupt("drive upload too large"));
        }
        self.put_bytes(path, bytes.len() as u64, &mut bytes.as_slice())
    }

    fn exists(&self, path: &str) -> Result<bool> {
        check(path)?;
        Ok(self.id(path).is_some())
    }

    fn removes(&self) -> bool {
        true
    }

    fn listed(&self, path: &str) -> Option<cs_vault::sync::Listed> {
        use cs_vault::sync::Listed;
        check(path).ok()?;
        Some(match self.id(path) {
            None => Listed::Missing,
            Some(id) => match self.sums.get(id.as_str()) {
                Some(h) => Listed::Sha256(h.to_string()),
                None => Listed::Unknown,
            },
        })
    }

    fn remove(&self, path: &str) -> Result<()> {
        check(path)?;
        match self.forget(path) {
            Some(id) => self.api.delete(&id),
            None => Ok(()),
        }
    }

    fn put_file(&self, path: &str, local: &Path) -> Result<()> {
        check(path)?;
        self.go_on()?;
        let mut f = std::fs::File::open(local)?;
        let len = f.metadata()?.len();
        self.put_bytes(path, len, &mut f)
    }

    fn remove_many(&self, paths: &[String]) -> Result<()> {
        for p in paths {
            check(p)?;
        }
        self.go_on()?;
        let found: Vec<(&String, String)> = paths
            .iter()
            .filter_map(|p| self.id(p).map(|id| (p, id)))
            .collect();
        let ids: Vec<String> = found.iter().map(|(_, id)| id.clone()).collect();
        self.api.delete_many(&ids)?;
        for (p, _) in found {
            self.forget(p);
        }
        Ok(())
    }

    fn parallel(&self) -> usize {
        AT_ONCE
    }
}

impl<A: DriveApi> DriveRemote<A> {
    fn put_bytes(&self, path: &str, len: u64, src: &mut dyn Read) -> Result<()> {
        // Every file has its place in a vault's folder.
        let (folder, name) = split(path)
            .and_then(|(vault, rest)| {
                place(rest).map(|(sub, name)| (format!("{vault}/{sub}"), name))
            })
            .ok_or(Error::Corrupt("drive path"))?;
        // Never two files of one name: the layout's files never change once written. With
        // items going up at once, a name is claimed before its upload and known (in the
        // index) before the claim ends.
        {
            let index = self.index.lock().unwrap_or_else(|p| p.into_inner());
            let known = path
                .split_once('/')
                .is_some_and(|(v, rest)| index.get(v).is_some_and(|f| f.contains_key(rest)));
            if known {
                return Ok(());
            }
            let mut uploading = self.uploading.lock().unwrap_or_else(|p| p.into_inner());
            if !uploading.insert(path.to_owned()) {
                return Err(Error::Corrupt("drive file sent twice at once"));
            }
        }
        let up = self
            .folder_id(&folder)
            .and_then(|folder| self.api.upload(&folder, &name, len, src));
        if let Ok(id) = &up {
            self.know(path, id);
        }
        self.uploading
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(path);
        up.map(|_| ())
    }
}

/// The real Drive, through [`https`].
pub struct GoogleDrive {
    token: String,
    /// A few kept connections for the whole session.
    http: https::Client,
}

impl GoogleDrive {
    /// `permit` must be [`Permit::google_drive`]; `token` is the person's access token
    /// (scope `drive.file`), from their sign-in on this device.
    pub fn new(permit: Permit, token: String) -> Result<Self> {
        if !permit.is_drive() {
            return Err(Error::Corrupt("permit is not for Google Drive"));
        }
        if token.is_empty() || token.contains(['\r', '\n', ' ']) {
            return Err(Error::Corrupt("drive token"));
        }
        Ok(GoogleDrive {
            token,
            http: https::Client::new(),
        })
    }

    fn json(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value> {
        again(|| self.json_once(method, path, body))
    }

    fn json_once(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value> {
        let r = self.http.request(
            method,
            path,
            &self.token,
            &[],
            match body {
                Some(v) => Body::Bytes(
                    "application/json; charset=UTF-8",
                    serde_json::to_vec(v).expect("json"),
                ),
                None => Body::None,
            },
        )?;
        let status = r.status;
        let bytes = r.bytes()?;
        answer_ok(status, &bytes)?;
        serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt("drive json"))
    }

    /// Every file and folder matching the query `q`, page by page; `listed` hears how
    /// many so far after each page.
    fn list(&self, q: &str, listed: &dyn Fn(u32)) -> Result<Vec<Node>> {
        let mut out = Vec::new();
        let mut page = String::new();
        loop {
            let mut path = format!(
                "/drive/v3/files?q={}&fields=nextPageToken,files(id,name,parents,mimeType,sha256Checksum)&pageSize=1000&spaces=drive",
                https::encode(q)
            );
            if !page.is_empty() {
                path.push_str(&format!("&pageToken={}", https::encode(&page)));
            }
            let v = self.json("GET", &path, None)?;
            out.extend(nodes_of(&v));
            listed(out.len() as u32);
            match v["nextPageToken"].as_str() {
                Some(t) => page = t.to_owned(),
                None => return Ok(out),
            }
        }
    }

    /// Up to [`BATCH`] calls in one request to Google's batch endpoint (same host); the
    /// status of each, in order.
    fn batch(&self, parts: &[Part]) -> Result<Vec<u16>> {
        again(|| self.batch_once(parts))
    }

    fn batch_once(&self, parts: &[Part]) -> Result<Vec<u16>> {
        let kind = format!("multipart/mixed; boundary={BOUNDARY}");
        let r = self.http.request(
            "POST",
            "/batch/drive/v3",
            &self.token,
            &[],
            Body::Bytes(&kind, batch_body(parts)?),
        )?;
        let status = r.status;
        let answer_kind = r.header("Content-Type").unwrap_or("").to_owned();
        let body = r.bytes_max(MAX_BATCH_ANSWER)?;
        answer_ok(status, &body)?;
        batch_statuses(&answer_kind, &body, parts.len())
    }
}

/// Google's answer to a failed call, as one of a few fixed codes (never the answer's own
/// text: it is network data). 403 is not always the sign-in (owner 2026-10-26: Drive
/// failed and nobody could tell why): Google says why in `error.errors[0].reason`.
fn drive_error(status: u16, body: &[u8]) -> Error {
    Error::Corrupt(match status {
        401 => "drive not signed in",
        429 => "drive rate limited",
        403 => match reason(body).as_deref() {
            Some(
                "rateLimitExceeded"
                | "userRateLimitExceeded"
                | "sharingRateLimitExceeded"
                | "dailyLimitExceeded",
            ) => "drive rate limited",
            Some("storageQuotaExceeded" | "quotaExceeded") => "drive full",
            Some("authError" | "insufficientPermissions" | "insufficientFilePermissions") => {
                "drive not signed in"
            }
            _ => "drive forbidden",
        },
        404 => "drive not found",
        500..=599 => "drive server error",
        _ => "drive request failed",
    })
}

/// `error.errors[0].reason` of a Drive error answer, if it has one.
fn reason(body: &[u8]) -> Option<String> {
    let v: Value = serde_json::from_slice(body).ok()?;
    v["error"]["errors"][0]["reason"]
        .as_str()
        .map(str::to_owned)
}

fn status_ok(status: u16) -> Result<()> {
    answer_ok(status, &[])
}

/// Ok for 2xx, else what [`drive_error`] makes of the answer.
fn answer_ok(status: u16, body: &[u8]) -> Result<()> {
    match status {
        200..=299 => Ok(()),
        s => Err(drive_error(s, body)),
    }
}

/// Worth trying again after a pause: Google asked to slow down, or had a passing fault.
fn passing(e: &Error) -> bool {
    matches!(
        e,
        Error::Corrupt("drive rate limited" | "drive server error")
    )
}

/// Tries before giving up on a passing fault, and the first pause (doubled each time,
/// with a little jitter so the four connections do not come back at once).
const TRIES: u32 = 4;
const FIRST_PAUSE_MS: u64 = if cfg!(test) { 1 } else { 600 };

/// Runs `f`, again after a pause when it fails with a passing fault ([`passing`]).
fn again<T>(mut f: impl FnMut() -> Result<T>) -> Result<T> {
    let mut pause = FIRST_PAUSE_MS;
    for _ in 1..TRIES {
        match f() {
            Err(e) if passing(&e) => {
                let jitter = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| u64::from(d.subsec_millis()) % 250)
                    .unwrap_or(0);
                std::thread::sleep(std::time::Duration::from_millis(pause + jitter));
                pause *= 2;
            }
            r => return r,
        }
    }
    f()
}

/// A Drive file or folder id: letters, digits, '-' and '_' only, so it can go into a
/// path, a query or a batch part as it is.
fn drive_id(id: &str) -> Result<&str> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
    {
        return Err(Error::Corrupt("drive file id"));
    }
    Ok(id)
}

/// A string in a Drive query: quoted, with `\` and `'` escaped.
fn quoted(s: &str) -> String {
    format!("'{}'", s.replace('\\', "\\\\").replace('\'', "\\'"))
}

/// The query for the app's folder.
fn folder_query() -> String {
    format!(
        "name = {} and mimeType = {} and trashed = false",
        quoted(FOLDER),
        quoted(FOLDER_MIME)
    )
}

/// The query for everything the app can see (`drive.file`: only its own files), in one
/// listing however many folders there are.
const TREE_QUERY: &str = "trashed = false";

/// The files and folders of one page of a listing; any with an odd id, or no folder, are
/// left out.
fn nodes_of(page: &Value) -> Vec<Node> {
    page["files"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|f| {
            let id = drive_id(f["id"].as_str()?).ok()?;
            let parent = drive_id(f["parents"][0].as_str()?).ok()?;
            Some(Node {
                id: id.to_owned(),
                name: f["name"].as_str()?.to_owned(),
                parent: parent.to_owned(),
                folder: f["mimeType"].as_str() == Some(FOLDER_MIME),
                sha256: f["sha256Checksum"]
                    .as_str()
                    .filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
                    .map(str::to_ascii_lowercase),
            })
        })
        .collect()
}

/// The request line of a move: into `to`, out of `from`, by id.
fn move_line(m: &Move) -> Result<String> {
    Ok(format!(
        "/drive/v3/files/{}?addParents={}&removeParents={}&fields=id",
        drive_id(&m.id)?,
        drive_id(&m.to)?,
        drive_id(&m.from)?
    ))
}

/// A move's body: the new name, as one line of JSON (it never starts with "--").
fn move_body(m: &Move) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({ "name": m.name })).expect("json")
}

/// One call in a batch: its request line, and a JSON body if it has one.
struct Part {
    line: String,
    json: Option<Vec<u8>>,
}

fn delete_parts(ids: &[String]) -> Result<Vec<Part>> {
    ids.iter()
        .map(|id| {
            Ok(Part {
                line: format!("DELETE /drive/v3/files/{}", drive_id(id)?),
                json: None,
            })
        })
        .collect()
}

fn move_parts(moves: &[Move]) -> Result<Vec<Part>> {
    moves
        .iter()
        .map(|m| {
            Ok(Part {
                line: format!("PATCH {}", move_line(m)?),
                json: Some(move_body(m)),
            })
        })
        .collect()
}

/// A batch request of `parts` (at most [`BATCH`]), numbered from 1 in `Content-ID`. The
/// outer request's sign-in covers every part.
fn batch_body(parts: &[Part]) -> Result<Vec<u8>> {
    if parts.is_empty() || parts.len() > BATCH {
        return Err(Error::Corrupt("drive batch size"));
    }
    let mut out = Vec::new();
    for (n, part) in parts.iter().enumerate() {
        out.extend_from_slice(
            format!(
                "--{BOUNDARY}\r\nContent-Type: application/http\r\nContent-ID: <{}>\r\n\r\n{}\r\n",
                n + 1,
                part.line
            )
            .as_bytes(),
        );
        match &part.json {
            Some(json) => {
                if json.contains(&b'\n') || json.starts_with(b"-") {
                    return Err(Error::Corrupt("drive batch body"));
                }
                out.extend_from_slice(b"Content-Type: application/json; charset=UTF-8\r\n\r\n");
                out.extend_from_slice(json);
                out.extend_from_slice(b"\r\n");
            }
            None => out.extend_from_slice(b"\r\n"),
        }
    }
    out.extend_from_slice(format!("--{BOUNDARY}--\r\n").as_bytes());
    Ok(out)
}

/// The boundary named in a `multipart/mixed` content type, if it is a valid one.
fn boundary_of(content_type: &str) -> Option<&str> {
    let (kind, params) = content_type.split_once(';')?;
    if !kind.trim().eq_ignore_ascii_case("multipart/mixed") {
        return None;
    }
    let b = params.split(';').find_map(|p| {
        let (k, v) = p.split_once('=')?;
        k.trim().eq_ignore_ascii_case("boundary").then(|| v.trim())
    })?;
    let b = b
        .strip_prefix('"')
        .and_then(|b| b.strip_suffix('"'))
        .unwrap_or(b);
    // RFC 2046: 1 to 70 of these, not ending in a space.
    let ok = (1..=70).contains(&b.len())
        && !b.ends_with(' ')
        && b.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"'()+_,-./:=? ".contains(&c));
    ok.then_some(b)
}

/// Read the answer to a batch of `n` calls strictly: every part answered exactly once,
/// with an HTTP status line. The status of each call, in the order sent.
fn batch_statuses(content_type: &str, body: &[u8], n: usize) -> Result<Vec<u16>> {
    let bad = || Error::Corrupt("drive batch answer");
    let boundary = boundary_of(content_type).ok_or_else(bad)?;
    let delim = format!("--{boundary}");
    let close = format!("--{boundary}--");
    enum At {
        Preamble,
        Head(Option<usize>),
        Status(usize),
        Body,
        Closed,
    }
    let mut at = At::Preamble;
    let mut answered: Vec<Option<u16>> = vec![None; n];
    for line in body.split(|&c| c == b'\n') {
        if matches!(at, At::Closed) {
            break; // the epilogue, ignored
        }
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let is_close = line == close.as_bytes();
        if is_close || line == delim.as_bytes() {
            // A part that ended before its answer's status line.
            if matches!(at, At::Head(_) | At::Status(_)) {
                return Err(bad());
            }
            at = if is_close { At::Closed } else { At::Head(None) };
            continue;
        }
        at = match at {
            At::Preamble | At::Body => at,
            At::Head(id) if line.is_empty() => At::Status(id.ok_or_else(bad)?),
            At::Head(id) => {
                let line = std::str::from_utf8(line).map_err(|_| bad())?;
                let (k, v) = line.split_once(':').ok_or_else(bad)?;
                if !k.trim().eq_ignore_ascii_case("content-id") {
                    At::Head(id)
                } else if id.is_some() {
                    return Err(bad());
                } else {
                    let v = v.trim();
                    let v = v
                        .strip_prefix('<')
                        .and_then(|v| v.strip_suffix('>'))
                        .unwrap_or(v);
                    let k: usize = v
                        .strip_prefix("response-")
                        .and_then(|k| k.parse().ok())
                        .filter(|k| (1..=n).contains(k))
                        .ok_or_else(bad)?;
                    At::Head(Some(k - 1))
                }
            }
            At::Status(id) => {
                let line = std::str::from_utf8(line).map_err(|_| bad())?;
                let mut words = line.split(' ');
                let status: u16 = match (words.next(), words.next()) {
                    (Some(v), Some(s)) if v.starts_with("HTTP/") => s.parse().map_err(|_| bad())?,
                    _ => return Err(bad()),
                };
                if answered[id].replace(status).is_some() {
                    return Err(bad());
                }
                At::Body
            }
            At::Closed => unreachable!(),
        };
    }
    if !matches!(at, At::Closed) {
        return Err(bad());
    }
    answered.into_iter().map(|s| s.ok_or_else(bad)).collect()
}

/// A failed call in a batch fails it all; a sign-in problem says so.
fn failed(status: u16) -> Error {
    match status_ok(status) {
        Err(e) => e,
        Ok(()) => Error::Corrupt("drive request failed"),
    }
}

fn deleted(statuses: Vec<u16>) -> Result<()> {
    match statuses.into_iter().find(|s| !matches!(s, 204 | 404)) {
        Some(s) => Err(failed(s)),
        None => Ok(()),
    }
}

/// Each move done (200) or its file gone (404, false).
fn moved(statuses: Vec<u16>) -> Result<Vec<bool>> {
    statuses
        .into_iter()
        .map(|s| match s {
            200 => Ok(true),
            404 => Ok(false),
            s => Err(failed(s)),
        })
        .collect()
}

impl DriveApi for GoogleDrive {
    fn folder(&self) -> Result<String> {
        let found = self.json(
            "GET",
            &format!(
                "/drive/v3/files?q={}&fields=files(id)&spaces=drive",
                https::encode(&folder_query())
            ),
            None,
        )?;
        if let Some(id) = found["files"][0]["id"].as_str() {
            return Ok(id.to_owned());
        }
        let made = self.json(
            "POST",
            "/drive/v3/files?fields=id",
            Some(&serde_json::json!({ "name": FOLDER, "mimeType": FOLDER_MIME })),
        )?;
        made["id"]
            .as_str()
            .map(str::to_owned)
            .ok_or(Error::Corrupt("drive folder"))
    }

    fn tree(&self, listed: &dyn Fn(u32)) -> Result<Vec<Node>> {
        self.list(TREE_QUERY, listed)
    }

    fn make_folder(&self, parent: &str, name: &str) -> Result<String> {
        let made = self.json(
            "POST",
            "/drive/v3/files?fields=id",
            Some(&serde_json::json!({
                "name": name,
                "mimeType": FOLDER_MIME,
                "parents": [drive_id(parent)?],
            })),
        )?;
        made["id"]
            .as_str()
            .map(str::to_owned)
            .ok_or(Error::Corrupt("drive folder"))
    }

    fn download(&self, id: &str, out: &mut dyn Write) -> Result<bool> {
        // Only the answer's status is tried again: once bytes went to `out`, a failure ends it.
        let r = again(|| {
            let r = self.http.request(
                "GET",
                &format!("/drive/v3/files/{}?alt=media", https::encode(id)),
                &self.token,
                &[],
                Body::None,
            )?;
            match r.status {
                200..=299 | 404 => Ok(r),
                s => Err(drive_error(s, &r.bytes_max(ERROR_ANSWER)?)),
            }
        })?;
        if r.status == 404 {
            return Ok(false);
        }
        r.copy_to(out)?;
        Ok(true)
    }

    fn upload(&self, folder: &str, name: &str, len: u64, src: &mut dyn Read) -> Result<String> {
        // Resumable upload: the metadata first, then the bytes to the URL Drive gives,
        // which must be on the same host.
        let meta = serde_json::json!({ "name": name, "parents": [folder] });
        let r = again(|| {
            let r = self.http.request(
                "POST",
                "/upload/drive/v3/files?uploadType=resumable&fields=id",
                &self.token,
                &[("X-Upload-Content-Length", len.to_string())],
                Body::Bytes(
                    "application/json; charset=UTF-8",
                    serde_json::to_vec(&meta).expect("json"),
                ),
            )?;
            match r.status {
                200..=299 => Ok(r),
                s => Err(drive_error(s, &r.bytes_max(ERROR_ANSWER)?)),
            }
        })?;
        let at = r
            .header("Location")
            .ok_or(Error::Corrupt("drive upload url"))?
            .to_owned();
        drop(r);
        let path = at
            .strip_prefix(&format!("https://{}", https::HOST))
            .ok_or(Error::Corrupt("drive upload url on another host"))?;
        // Small ones (records, journal entries) from memory, so the request can be sent
        // again if a kept connection turns out closed; files stream.
        // Small ones from memory can be sent again after a passing fault; a stream cannot.
        let put = |body: Body| -> Result<Value> {
            let r = self.http.request("PUT", path, &self.token, &[], body)?;
            let status = r.status;
            let bytes = r.bytes()?;
            answer_ok(status, &bytes)?;
            serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt("drive json"))
        };
        let v = if len <= SMALL_UPLOAD {
            let mut b = Vec::new();
            src.take(len).read_to_end(&mut b)?;
            if b.len() as u64 != len {
                return Err(Error::Corrupt("drive upload short"));
            }
            again(|| put(Body::Bytes("application/octet-stream", b.clone())))?
        } else {
            put(Body::Stream("application/octet-stream", len, src))?
        };
        v["id"]
            .as_str()
            .map(str::to_owned)
            .ok_or(Error::Corrupt("drive upload"))
    }

    /// A rename into another folder (`PATCH` with addParents/removeParents): no bytes move.
    fn move_file(&self, m: &Move) -> Result<bool> {
        let r = self.http.request(
            "PATCH",
            &move_line(m)?,
            &self.token,
            &[],
            Body::Bytes("application/json; charset=UTF-8", move_body(m)),
        )?;
        let status = r.status;
        drop(r.bytes()?);
        Ok(moved(vec![status])?[0])
    }

    /// Up to [`BATCH`] moves per request, through Google's batch endpoint.
    fn move_many(&self, moves: &[Move]) -> Result<Vec<bool>> {
        let mut out = Vec::new();
        for chunk in moves.chunks(BATCH) {
            if let [m] = chunk {
                out.push(self.move_file(m)?);
                continue;
            }
            out.extend(moved(self.batch(&move_parts(chunk)?)?)?);
        }
        Ok(out)
    }

    fn delete(&self, id: &str) -> Result<()> {
        let r = self.http.request(
            "DELETE",
            &format!("/drive/v3/files/{}", https::encode(id)),
            &self.token,
            &[],
            Body::None,
        )?;
        match r.status {
            404 => Ok(()),
            s => status_ok(s),
        }
    }

    /// Up to [`BATCH`] deletions per request, through Google's batch endpoint.
    fn delete_many(&self, ids: &[String]) -> Result<()> {
        for chunk in ids.chunks(BATCH) {
            if let [id] = chunk {
                self.delete(id)?;
                continue;
            }
            deleted(self.batch(&delete_parts(chunk)?)?)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{note, text, two};
    use std::sync::atomic::AtomicU64;
    use std::sync::Arc;

    #[derive(Default)]
    struct State {
        nodes: Vec<(Node, Vec<u8>)>,
        /// Size of each delete_many call.
        batches: Vec<usize>,
        uploads: usize,
        moves: usize,
        /// Moves that go through before the next one fails (a cut connection).
        moves_left: Option<usize>,
    }

    /// Drive in memory; the app's folder is "F".
    #[derive(Default, Clone)]
    struct Fake(Arc<Mutex<State>>);

    /// Never reused, like Drive's ids (a count of files would repeat after a delete).
    fn new_id() -> String {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        format!("id{}", NEXT.fetch_add(1, Ordering::Relaxed))
    }

    impl Fake {
        fn state(&self) -> std::sync::MutexGuard<'_, State> {
            self.0.lock().unwrap()
        }

        fn add(&self, parent: &str, name: &str, bytes: Vec<u8>, folder: bool) -> String {
            let id = new_id();
            let node = Node {
                id: id.clone(),
                name: name.to_owned(),
                parent: parent.to_owned(),
                folder,
                sha256: None,
            };
            self.state().nodes.push((node, bytes));
            id
        }

        /// The folder's path under "F" ("" for "F" itself).
        fn path_of(&self, id: &str) -> String {
            let s = self.state();
            let mut parts = Vec::new();
            let mut at = id.to_owned();
            while at != "F" {
                let Some((n, _)) = s.nodes.iter().find(|(n, _)| n.id == at) else {
                    return format!("?{at}");
                };
                parts.push(n.name.clone());
                at = n.parent.clone();
            }
            parts.reverse();
            parts.join("/")
        }

        /// Every file: (its folder's path, its name, its id).
        fn layout(&self) -> Vec<(String, String, String)> {
            let files: Vec<Node> = self
                .state()
                .nodes
                .iter()
                .filter(|(n, _)| !n.folder)
                .map(|(n, _)| n.clone())
                .collect();
            let mut out: Vec<_> = files
                .into_iter()
                .map(|n| (self.path_of(&n.parent), n.name, n.id))
                .collect();
            out.sort();
            out
        }

        fn folders(&self) -> Vec<String> {
            let ids: Vec<String> = self
                .state()
                .nodes
                .iter()
                .filter(|(n, _)| n.folder)
                .map(|(n, _)| n.id.clone())
                .collect();
            let mut out: Vec<String> = ids.iter().map(|id| self.path_of(id)).collect();
            out.sort();
            out
        }

        /// An earlier layout: every file flat in "F" named by its whole sync path (up to
        /// 0.1.57), or flat in its vault's folder named by the rest.
        fn flatten(&self, in_vault_folder: bool) {
            let known = DriveRemote::open(self.clone()).unwrap().known();
            let vaults: HashMap<String, String> = self
                .state()
                .nodes
                .iter()
                .filter(|(n, _)| n.folder && n.parent == "F")
                .map(|(n, _)| (n.name.clone(), n.id.clone()))
                .collect();
            let mut s = self.state();
            for (path, id) in known {
                let (vault, rest) = path.split_once('/').unwrap();
                let (n, _) = s.nodes.iter_mut().find(|(n, _)| n.id == id).unwrap();
                if in_vault_folder {
                    n.parent = vaults[vault].clone();
                    n.name = rest.to_owned();
                } else {
                    n.parent = "F".into();
                    n.name = path.clone();
                }
            }
            let keep: HashSet<String> = if in_vault_folder {
                vaults.into_values().collect()
            } else {
                HashSet::new()
            };
            s.nodes.retain(|(n, _)| !n.folder || keep.contains(&n.id));
        }
    }

    impl DriveApi for Fake {
        fn folder(&self) -> Result<String> {
            Ok("F".into())
        }
        fn tree(&self, listed: &dyn Fn(u32)) -> Result<Vec<Node>> {
            // Google lists each file's SHA-256 with it.
            let nodes: Vec<Node> = self
                .state()
                .nodes
                .iter()
                .map(|(n, b)| Node {
                    sha256: (!n.folder).then(|| {
                        use sha2::Digest;
                        hex::encode(sha2::Sha256::digest(b))
                    }),
                    ..n.clone()
                })
                .collect();
            // Two pages, as Drive gives a long listing.
            listed(nodes.len() as u32 / 2);
            listed(nodes.len() as u32);
            Ok(nodes)
        }
        fn make_folder(&self, parent: &str, name: &str) -> Result<String> {
            Ok(self.add(parent, name, Vec::new(), true))
        }
        fn download(&self, id: &str, out: &mut dyn Write) -> Result<bool> {
            let s = self.state();
            match s.nodes.iter().find(|(n, _)| n.id == id && !n.folder) {
                Some((_, b)) => {
                    out.write_all(b)?;
                    Ok(true)
                }
                None => Ok(false),
            }
        }
        fn upload(&self, folder: &str, name: &str, len: u64, src: &mut dyn Read) -> Result<String> {
            let mut b = Vec::new();
            src.take(len).read_to_end(&mut b)?;
            assert!(self
                .state()
                .nodes
                .iter()
                .any(|(n, _)| n.id == folder && n.folder));
            self.state().uploads += 1;
            Ok(self.add(folder, name, b, false))
        }
        fn move_file(&self, m: &Move) -> Result<bool> {
            let mut s = self.state();
            if let Some(left) = &mut s.moves_left {
                if *left == 0 {
                    return Err(Error::Io(std::io::ErrorKind::ConnectionReset.into()));
                }
                *left -= 1;
            }
            s.moves += 1;
            match s.nodes.iter_mut().find(|(n, _)| n.id == m.id) {
                Some((n, _)) => {
                    assert_eq!(n.parent, m.from);
                    n.parent = m.to.clone();
                    n.name = m.name.clone();
                    Ok(true)
                }
                None => Ok(false),
            }
        }
        fn delete(&self, id: &str) -> Result<()> {
            self.state().nodes.retain(|(n, _)| n.id != id);
            Ok(())
        }
        fn delete_many(&self, ids: &[String]) -> Result<()> {
            let mut s = self.state();
            s.batches.push(ids.len());
            s.nodes.retain(|(n, _)| !ids.contains(&n.id));
            Ok(())
        }
    }

    /// Where each kind of file sits in the vault's folder.
    fn assert_in_place(drive: &Fake, vault: &str) {
        let layout = drive.layout();
        assert!(!layout.is_empty());
        for (folder, name, _) in &layout {
            let sub = folder.strip_prefix(&format!("{vault}/")).unwrap_or("?");
            let ok = match sub.split_once('/') {
                Some(("index", b)) => {
                    name.len() == 65 && name[30..32] == *b && &name[32..33] == "."
                }
                Some(("content", b)) => {
                    name[30..32] == *b && (name.ends_with(".data") || name.ends_with(".thumb"))
                }
                None => {
                    (sub == "log" && name.contains('.'))
                        || (sub == "lock" && name.ends_with(".json"))
                }
                _ => false,
            };
            assert!(ok, "{folder}/{name}");
        }
    }

    #[test]
    fn two_devices_sync_through_drive() {
        let t = two();
        let drive = Fake::default();
        let from_a = note(&t.a, "From A", "plain text from device A");
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        let from_b = note(&t.b, "From B", "plain text from device B");
        // A new session lists the folder afresh, as on another device.
        t.b.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        assert_eq!(text(&t.b, &from_a), "plain text from device A");
        assert_eq!(text(&t.a, &from_b), "plain text from device B");
        // The vault's folder, and in it the layout's folders, each once; every file in
        // its place.
        let v = &t.a.id;
        let mut want = vec![
            v.clone(),
            format!("{v}/content"),
            format!("{v}/index"),
            format!("{v}/lock"),
            format!("{v}/log"),
        ];
        for id in [&from_a, &from_b] {
            let b = &id[30..];
            want.push(format!("{v}/content/{b}"));
            want.push(format!("{v}/index/{b}"));
        }
        want.sort();
        want.dedup();
        assert_eq!(drive.folders(), want);
        assert_in_place(&drive, v);
        let layout = drive.layout();
        let content = format!("{v}/content/{}", &from_a[30..]);
        assert!(layout
            .iter()
            .any(|(f, n, _)| *f == content && n.starts_with(&from_a) && n.ends_with(".data")));
        // One lock there, the newest.
        let locks = layout
            .iter()
            .filter(|(f, _, _)| f.ends_with("/lock"))
            .count();
        assert_eq!(locks, 1);
        // Only sealed bytes reach Drive.
        for (_, b) in drive.state().nodes.iter() {
            // Long markers: three random bytes can spell "aaa" by chance.
            assert!(!b.windows(10).any(|w| w == b"plain text"));
        }
    }

    #[test]
    fn files_drive_lost_or_damaged_are_sent_again() {
        let t = two();
        let drive = Fake::default();
        let one = note(&t.a, "One", "the first note");
        let two_ = note(&t.a, "Two", "the second note");
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        // Drive loses one item's content and damages the other's.
        {
            let mut s = drive.state();
            let at = |s: &State, id: &str| {
                s.nodes
                    .iter()
                    .position(|(n, _)| n.name.starts_with(id) && n.name.ends_with(".data"))
                    .unwrap()
            };
            let lost = at(&s, &one);
            s.nodes.remove(lost);
            let damaged = at(&s, &two_);
            s.nodes[damaged].1[0] ^= 1;
        }
        // The next sync from A sees both from Drive's own checksums and mends them.
        let seen = Mutex::new(Vec::new());
        let report =
            t.a.sync_with(&DriveRemote::open(drive.clone()).unwrap(), &|p| {
                seen.lock().unwrap().push(p)
            })
            .unwrap();
        assert_eq!((report.repaired, report.unrepaired), (2, 0));
        // The screen says it is sending them again, with a count (owner 2026-10-27).
        let mending: Vec<_> = seen
            .into_inner()
            .unwrap()
            .into_iter()
            .filter(|p| p.phase == cs_vault::sync::SyncPhase::Repairing)
            .map(|p| (p.done, p.total))
            .collect();
        assert_eq!(mending, [(0, 2), (1, 2), (2, 2)]);
        // B reads both back intact.
        t.b.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        assert_eq!(text(&t.b, &one), "the first note");
        assert_eq!(text(&t.b, &two_), "the second note");
        // Nothing left to mend.
        let again =
            t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
                .unwrap();
        assert_eq!((again.repaired, again.unrepaired), (0, 0));
    }

    #[test]
    fn the_layout_maps_both_ways() {
        let item = format!("{}a7", "0".repeat(30));
        let rev = "f".repeat(32);
        for (rest, sub, name) in [
            (
                format!("records/{item}/{rev}"),
                "index/a7".to_owned(),
                format!("{item}.{rev}"),
            ),
            (
                format!("blobs/{item}.{rev}.data"),
                "content/a7".to_owned(),
                format!("{item}.{rev}.data"),
            ),
            (
                "log/0123abcd/17".to_owned(),
                "log".to_owned(),
                "0123abcd.17".to_owned(),
            ),
            (
                "lock/0001-ab.json".to_owned(),
                "lock".to_owned(),
                "0001-ab.json".to_owned(),
            ),
        ] {
            assert_eq!(place(&rest), Some((sub.clone(), name.clone())), "{rest}");
            assert_eq!(unplace(&sub, &name), Some(rest.clone()), "{rest}");
        }
        for bad in [
            "records/x/1",
            &format!("records/{item}"),
            &format!("records/{item}/a/b"),
            "blobs/x.1.data",
            "log/a.b/1",
            "log/a",
            "lock/a/b",
            "header.json",
            "other/x",
        ] {
            assert_eq!(place(bad), None, "{bad}");
        }
        // A file in the wrong bucket or folder is not taken for one in place.
        assert_eq!(unplace("index/a8", &format!("{item}.{rev}")), None);
        assert_eq!(unplace("content/a7", &format!("{item}.{rev}.data/x")), None);
        assert_eq!(unplace("lock", "a/b"), None);
        assert_eq!(unplace("other", "x"), None);
        assert!(folder_ok(&format!("{item}/index/ff")) && !folder_ok(&format!("{item}/log/ff")));
        assert!(!folder_ok("x") && !folder_ok(&format!("{item}/index/FF")));
    }

    #[test]
    fn two_vaults_keep_to_their_own_folders() {
        let (one, other) = (two(), two());
        assert_ne!(one.a.id, other.a.id);
        let drive = Fake::default();
        let a = note(&one.a, "A", "vault one");
        let b = note(&other.a, "B", "vault two");
        one.a
            .sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        other
            .a
            .sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        let mut ids = vec![one.a.id.clone(), other.a.id.clone()];
        ids.sort();
        let top: Vec<String> = drive
            .folders()
            .into_iter()
            .filter(|f| !f.contains('/'))
            .collect();
        assert_eq!(top, ids);
        let r = DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(r.vault_ids(), ids);
        one.b.sync(&r).unwrap();
        other.b.sync(&r).unwrap();
        assert_eq!(text(&one.b, &a), "vault one");
        assert_eq!(text(&other.b, &b), "vault two");
        for (folder, name, _) in drive.layout() {
            assert!(
                ids.iter().any(|v| folder.starts_with(v.as_str())),
                "{folder}/{name}"
            );
        }
        // A path outside the layout is refused, never put anywhere.
        assert!(r.put("records/x", &mut &b"x"[..]).is_err());
        assert!(r.put(&one.a.id, &mut &b"x"[..]).is_err());
        assert!(r
            .put(&format!("{}/other/x", one.a.id), &mut &b"x"[..])
            .is_err());
    }

    /// An earlier layout moves into place on open (renamed, nothing sent again), then
    /// syncs as usual.
    fn earlier_layout_moves(in_vault_folder: bool) {
        let t = two();
        let drive = Fake::default();
        let ids: Vec<String> = (0..5)
            .map(|i| note(&t.a, &format!("N{i}"), &format!("text {i}")))
            .collect();
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        let placed = drive.layout();
        drive.flatten(in_vault_folder);
        assert_ne!(drive.layout(), placed);
        let uploads = drive.state().uploads;
        // Anything else in the folders is left alone.
        drive.add("F", "notes.txt", b"x".to_vec(), false);
        let r = DriveRemote::open(drive.clone()).unwrap();
        let mut now = drive.layout();
        now.retain(|f| f.1 != "notes.txt");
        assert_eq!(now, placed);
        assert_eq!(drive.state().uploads, uploads);
        assert_eq!(drive.state().moves, placed.len());
        assert_eq!(r.moved() as usize, placed.len());
        assert_eq!(r.vault_ids(), vec![t.a.id.clone()]);
        t.b.sync(&r).unwrap();
        for (i, id) in ids.iter().enumerate() {
            assert_eq!(text(&t.b, id), format!("text {i}"));
        }
        // Opened again, nothing more to move.
        DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(drive.state().moves, placed.len());
    }

    #[test]
    fn files_of_0_1_57_move_into_place() {
        earlier_layout_moves(false);
    }

    #[test]
    fn files_flat_in_the_vault_folder_move_into_place() {
        earlier_layout_moves(true);
    }

    #[test]
    fn opening_tells_how_the_listing_folders_and_moves_go() {
        let t = two();
        let drive = Fake::default();
        let ids: Vec<String> = (0..60)
            .map(|i| note(&t.a, &format!("N{i}"), &format!("text {i}")))
            .collect();
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        let placed = drive.layout();
        let folders = drive.folders();
        // More than one batch of moves.
        assert!(placed.len() > BATCH);
        drive.flatten(false);
        assert!(drive.folders().is_empty());
        let seen = Mutex::new(Vec::new());
        let r = DriveRemote::open_with(drive.clone(), &|s| seen.lock().unwrap().push(s)).unwrap();
        let seen = seen.into_inner().unwrap();
        assert_eq!(r.moved() as usize, placed.len());
        assert_eq!(drive.layout(), placed);
        // The same folders as before, each made once, none empty.
        assert_eq!(drive.folders(), folders);
        let layout = drive.layout();
        for f in drive.folders() {
            assert!(
                layout
                    .iter()
                    .any(|(at, _, _)| *at == f || at.starts_with(&format!("{f}/"))),
                "{f} is empty"
            );
        }
        // Phases in order, counts going up, each ending at its total.
        let of = |phase| -> Vec<DriveSetup> {
            seen.iter().copied().filter(|s| s.phase == phase).collect()
        };
        let order: Vec<DrivePhase> = seen.iter().map(|s| s.phase).collect();
        let mut sorted = order.clone();
        sorted.sort_by_key(|p| *p as u8);
        assert_eq!(order, sorted);
        let listing = of(DrivePhase::Listing);
        assert!(listing.len() >= 2 && listing.iter().all(|s| s.total == 0));
        assert_eq!(listing.last().unwrap().done as usize, placed.len());
        for (phase, total) in [
            (DrivePhase::Folders, folders.len()),
            (DrivePhase::Moving, placed.len()),
        ] {
            let steps = of(phase);
            assert_eq!(steps[0].done, 0, "{phase:?}");
            assert!(steps.iter().all(|s| s.total as usize == total), "{phase:?}");
            assert_eq!(steps.last().unwrap().done as usize, total, "{phase:?}");
            assert!(steps.windows(2).all(|w| w[0].done < w[1].done), "{phase:?}");
        }
        assert_eq!(of(DrivePhase::Folders).len(), folders.len() + 1);
        assert_eq!(
            of(DrivePhase::Moving).len(),
            placed.len().div_ceil(BATCH) + 1
        );
        // Opened again: nothing to make or move.
        let seen = Mutex::new(Vec::new());
        let again =
            DriveRemote::open_with(drive.clone(), &|s| seen.lock().unwrap().push(s)).unwrap();
        assert_eq!(again.moved(), 0);
        assert!(seen
            .into_inner()
            .unwrap()
            .iter()
            .all(|s| s.phase == DrivePhase::Listing));
        t.b.sync(&again).unwrap();
        for (i, id) in ids.iter().enumerate() {
            assert_eq!(text(&t.b, id), format!("text {i}"));
        }
    }

    #[test]
    fn a_move_cut_short_goes_on_next_time() {
        let t = two();
        let drive = Fake::default();
        let id = note(&t.a, "N", "moved in two goes");
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        let placed = drive.layout();
        drive.flatten(false);
        assert!(placed.len() > 3);
        drive.state().moves_left = Some(3);
        assert!(DriveRemote::open(drive.clone()).is_err());
        // Each file in one place or the other.
        let half = drive.layout();
        assert_eq!(half.len(), placed.len());
        assert_eq!(half.iter().filter(|f| placed.contains(f)).count(), 3);
        drive.state().moves_left = None;
        let r = DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(drive.layout(), placed);
        assert_eq!(drive.state().moves, placed.len());
        t.b.sync(&r).unwrap();
        assert_eq!(text(&t.b, &id), "moved in two goes");
    }

    #[test]
    fn a_file_in_two_places_is_kept_once() {
        let t = two();
        let drive = Fake::default();
        let id = note(&t.a, "N", "one copy");
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        let placed = drive.layout();
        let known = DriveRemote::open(drive.clone()).unwrap().known();
        let bytes = |file: &str| {
            let s = drive.state();
            s.nodes
                .iter()
                .find(|(n, _)| n.id == file)
                .unwrap()
                .1
                .clone()
        };
        // An old flat copy of every file (a move cut short between the rename and the
        // listing), and a second folder for one bucket (two devices made one at once)
        // holding a copy of the record and a file of its own.
        for (path, file) in &known {
            let b = bytes(file);
            drive.add("F", path, b, false);
        }
        let v = &t.a.id;
        let index = drive
            .state()
            .nodes
            .iter()
            .find(|(n, _)| n.folder && n.name == "index")
            .unwrap()
            .0
            .id
            .clone();
        let second = drive.add(&index, &id[30..], Vec::new(), true);
        let (record_path, record_file) =
            known.iter().find(|(p, _)| p.contains("/records/")).unwrap();
        let rest = record_path
            .rsplit_once("/records/")
            .unwrap()
            .1
            .replace('/', ".");
        let b = bytes(record_file);
        drive.add(&second, &rest, b, false);
        let extra = format!("{id}.{}", "e".repeat(32));
        drive.add(&second, &extra, b"x".to_vec(), false);
        let uploads = drive.state().uploads;
        let r = DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(drive.state().uploads, uploads);
        // The copies are gone: each file once, in place; the extra one moved in.
        let after: Vec<(String, String)> =
            drive.layout().into_iter().map(|(f, n, _)| (f, n)).collect();
        assert_eq!(after.len(), placed.len() + 1);
        for (f, n, _) in &placed {
            assert!(after.contains(&(f.clone(), n.clone())), "{f}/{n}");
        }
        assert!(drive.layout().iter().all(|(f, _, _)| !f.is_empty()));
        assert!(r
            .exists(&format!("{v}/records/{id}/{}", "e".repeat(32)))
            .unwrap());
        assert_eq!(r.vault_ids(), vec![v.clone()]);
        t.b.sync(&r).unwrap();
        assert_eq!(text(&t.b, &id), "one copy");
    }

    #[test]
    fn drive_queries_are_quoted() {
        assert_eq!(
            folder_query(),
            "name = 'Cozy Safe' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        );
        assert_eq!(quoted(r"it's a \ name"), r"'it\'s a \\ name'");
        // And encoded whole into the URL.
        assert_eq!(
            https::encode(&folder_query()),
            "name%20%3D%20%27Cozy%20Safe%27%20and%20mimeType%20%3D%20%27application%2Fvnd.google-apps.folder%27%20and%20trashed%20%3D%20false"
        );
        assert_eq!(https::encode(TREE_QUERY), "trashed%20%3D%20false");
        for bad in ["", "a' or 'x", "a b", "a\\b", "a/b", "a%27"] {
            assert!(drive_id(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_listing_becomes_nodes() {
        let page = serde_json::json!({ "files": [
            { "id": "a1", "name": "Cozy Safe", "parents": ["root"], "mimeType": FOLDER_MIME },
            { "id": "b2", "name": "x.data", "parents": ["a1", "z"], "mimeType": "application/octet-stream" },
            { "id": "c3", "name": "no parent" },
            { "id": "d 4", "name": "bad id", "parents": ["a1"] },
        ]});
        assert_eq!(
            nodes_of(&page),
            vec![
                Node {
                    id: "a1".into(),
                    name: "Cozy Safe".into(),
                    parent: "root".into(),
                    folder: true,
                    sha256: None
                },
                Node {
                    id: "b2".into(),
                    name: "x.data".into(),
                    parent: "a1".into(),
                    folder: false,
                    sha256: None
                },
            ]
        );
    }

    #[test]
    fn paths_outside_the_layout_are_refused() {
        let r = DriveRemote::open(Fake::default()).unwrap();
        for bad in ["", "../x", "a//b", "a/./b", "a\\b", "c:x"] {
            assert!(r.exists(bad).is_err(), "{bad}");
        }
        assert!(
            GoogleDrive::new(Permit::listen(std::net::Ipv4Addr::LOCALHOST), "t".into()).is_err()
        );
        assert!(GoogleDrive::new(Permit::google_drive(), "a\r\nb".into()).is_err());
    }

    #[test]
    fn many_items_go_up_at_once_and_deleted_ones_leave_in_batches() {
        let t = two();
        let drive = Fake::default();
        let ids: Vec<String> = (0..30)
            .map(|i| note(&t.a, &format!("N{i}"), &format!("text {i}")))
            .collect();
        let r = DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(r.parallel(), 4);
        t.a.sync(&r).unwrap();
        // One file per name and each folder once, though several went up together.
        let folders = drive.folders();
        let unique: HashSet<&String> = folders.iter().collect();
        assert_eq!(unique.len(), folders.len());
        let names = drive.layout();
        let unique: HashSet<(&String, &String)> = names.iter().map(|(f, n, _)| (f, n)).collect();
        assert_eq!(unique.len(), names.len());
        assert_in_place(&drive, &t.a.id);
        t.b.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        for (i, id) in ids.iter().enumerate() {
            assert_eq!(text(&t.b, id), format!("text {i}"));
        }
        for id in &ids {
            t.a.delete_item(id).unwrap();
        }
        let before = drive.layout().len();
        let folders = drive.folders();
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        // A record and its content per item, in two batches (records, then contents).
        assert_eq!(drive.state().batches, vec![30, 30]);
        let after = drive.layout().len();
        assert_eq!(before - after, 60 - 1); // and one journal entry more
                                            // Folders stay, empty or not.
        assert_eq!(drive.folders(), folders);
    }

    #[test]
    fn a_batch_request_has_one_call_per_file() {
        let ids: Vec<String> = vec!["abc-1".into(), "x_Y2".into()];
        let body = String::from_utf8(batch_body(&delete_parts(&ids).unwrap()).unwrap()).unwrap();
        assert_eq!(
            body,
            format!(
                "--{BOUNDARY}\r\nContent-Type: application/http\r\nContent-ID: <1>\r\n\r\n\
                 DELETE /drive/v3/files/abc-1\r\n\r\n\
                 --{BOUNDARY}\r\nContent-Type: application/http\r\nContent-ID: <2>\r\n\r\n\
                 DELETE /drive/v3/files/x_Y2\r\n\r\n\
                 --{BOUNDARY}--\r\n"
            )
        );
        let moves = vec![Move {
            id: "f1".into(),
            from: "root".into(),
            to: "v-1".into(),
            name: "records/ab/cd".into(),
        }];
        let body = String::from_utf8(batch_body(&move_parts(&moves).unwrap()).unwrap()).unwrap();
        assert_eq!(
            body,
            format!(
                "--{BOUNDARY}\r\nContent-Type: application/http\r\nContent-ID: <1>\r\n\r\n\
                 PATCH /drive/v3/files/f1?addParents=v-1&removeParents=root&fields=id\r\n\
                 Content-Type: application/json; charset=UTF-8\r\n\r\n\
                 {{\"name\":\"records/ab/cd\"}}\r\n\
                 --{BOUNDARY}--\r\n"
            )
        );
        // A name cannot break out of its part: JSON keeps it on one line.
        let mut odd = moves[0].clone();
        odd.name = format!("a\r\n--{BOUNDARY}--\r\nb");
        let body = batch_body(&move_parts(&[odd]).unwrap()).unwrap();
        assert_eq!(body.split(|&b| b == b'\n').count(), 10);
        // Nothing that could break out of a part, and never more than Google takes.
        for bad in ["a/b", "a b", "a\r\nb", "", "a?b", "a%2F", "a&b"] {
            assert!(delete_parts(&[bad.to_owned()]).is_err(), "{bad:?}");
            let mut m = moves[0].clone();
            m.to = bad.to_owned();
            assert!(move_parts(&[m]).is_err(), "{bad:?}");
            let mut m = moves[0].clone();
            m.from = bad.to_owned();
            assert!(move_parts(&[m]).is_err(), "{bad:?}");
        }
        assert!(batch_body(&[]).is_err());
        assert!(batch_body(&delete_parts(&vec!["a".to_owned(); BATCH + 1]).unwrap()).is_err());
    }

    /// An answer as Drive writes it: parts in any order, each an HTTP answer.
    fn answer(parts: &[(&str, &str)]) -> Vec<u8> {
        let mut out = String::from("\r\n");
        for (id, status) in parts {
            out.push_str(&format!(
                "--batch_Ab9\r\nContent-Type: application/http\r\nContent-ID: <response-{id}>\r\n\r\n\
                 HTTP/1.1 {status}\r\nContent-Type: application/json\r\n\r\n{{\"x\": 1}}\r\n\r\n"
            ));
        }
        out.push_str("--batch_Ab9--\r\n");
        out.into_bytes()
    }

    const KIND: &str = "multipart/mixed; boundary=batch_Ab9";

    /// The answer to a batch of `n` deletions, as `delete_many` reads it.
    fn batch_check(content_type: &str, body: &[u8], n: usize) -> Result<()> {
        deleted(batch_statuses(content_type, body, n)?)
    }

    #[test]
    fn a_batch_answer_is_read_strictly() {
        let ok = answer(&[("2", "404 Not Found"), ("1", "204 No Content")]);
        batch_check(KIND, &ok, 2).unwrap();
        batch_check("multipart/mixed; boundary=\"batch_Ab9\"", &ok, 2).unwrap();
        // One part failing fails the batch; a sign-in problem says so.
        let one_failed = answer(&[("1", "204 No Content"), ("2", "500 Internal Server Error")]);
        assert!(batch_check(KIND, &one_failed, 2).is_err());
        let forbidden = answer(&[("1", "204 No Content"), ("2", "403 Forbidden")]);
        assert!(matches!(
            batch_check(KIND, &forbidden, 2),
            Err(Error::Corrupt("drive forbidden"))
        ));
        let signed_out = answer(&[("1", "204 No Content"), ("2", "401 Unauthorized")]);
        assert!(matches!(
            batch_check(KIND, &signed_out, 2),
            Err(Error::Corrupt("drive not signed in"))
        ));
        assert!(batch_check(KIND, &answer(&[("1", "200 OK")]), 1).is_err());
        // A part missing, twice, out of range, or without a number.
        assert!(batch_check(KIND, &answer(&[("1", "204 No Content")]), 2).is_err());
        let twice = answer(&[("1", "204 No Content"), ("1", "204 No Content")]);
        assert!(batch_check(KIND, &twice, 2).is_err());
        assert!(batch_check(KIND, &answer(&[("3", "204 No Content")]), 1).is_err());
        assert!(batch_check(KIND, &answer(&[("x", "204 No Content")]), 1).is_err());
        // Cut short (no closing line), or a part with no status line.
        let mut cut = answer(&[("1", "204 No Content")]);
        cut.truncate(cut.len() - 16);
        assert!(batch_check(KIND, &cut, 1).is_err());
        let headless = b"--batch_Ab9\r\nContent-ID: <response-1>\r\n--batch_Ab9--\r\n";
        assert!(batch_check(KIND, headless, 1).is_err());
        let not_http =
            b"--batch_Ab9\r\nContent-ID: <response-1>\r\n\r\nhello 204\r\n--batch_Ab9--\r\n";
        assert!(batch_check(KIND, not_http, 1).is_err());
        // Another boundary, or not a batch at all.
        assert!(batch_check("multipart/mixed; boundary=other", &ok, 2).is_err());
        assert!(batch_check("application/json", &ok, 2).is_err());
        assert!(batch_check("multipart/mixed", &ok, 2).is_err());
        let long = format!("multipart/mixed; boundary={}", "a".repeat(71));
        assert!(batch_check(&long, &ok, 2).is_err());
    }

    #[test]
    fn a_batch_of_moves_answers_each_in_order() {
        let ok = answer(&[("2", "404 Not Found"), ("1", "200 OK")]);
        assert_eq!(
            moved(batch_statuses(KIND, &ok, 2).unwrap()).unwrap(),
            vec![true, false]
        );
        let deleted_answer = answer(&[("1", "204 No Content")]);
        assert!(moved(batch_statuses(KIND, &deleted_answer, 1).unwrap()).is_err());
        let forbidden = answer(&[("1", "200 OK"), ("2", "401 Unauthorized")]);
        assert!(matches!(
            moved(batch_statuses(KIND, &forbidden, 2).unwrap()),
            Err(Error::Corrupt("drive not signed in"))
        ));
        assert!(batch_statuses(KIND, &answer(&[("1", "200 OK")]), 2).is_err());
    }

    #[test]
    fn a_failed_answer_says_why_in_a_fixed_code() {
        let why = |r: &str| {
            format!(
                r#"{{"error":{{"errors":[{{"domain":"usageLimits","reason":"{r}"}}],"code":403}}}}"#
            )
        };
        let code = |status, body: &str| match drive_error(status, body.as_bytes()) {
            Error::Corrupt(c) => c,
            _ => unreachable!(),
        };
        assert_eq!(code(401, ""), "drive not signed in");
        assert_eq!(
            code(403, &why("userRateLimitExceeded")),
            "drive rate limited"
        );
        assert_eq!(code(403, &why("rateLimitExceeded")), "drive rate limited");
        assert_eq!(code(403, &why("storageQuotaExceeded")), "drive full");
        assert_eq!(
            code(403, &why("insufficientPermissions")),
            "drive not signed in"
        );
        // A reason it does not know, or none: not taken for a sign-in problem any more.
        assert_eq!(code(403, &why("somethingNew")), "drive forbidden");
        assert_eq!(code(403, "not json"), "drive forbidden");
        assert_eq!(code(429, ""), "drive rate limited");
        assert_eq!(code(503, ""), "drive server error");
        assert_eq!(code(404, ""), "drive not found");
        assert_eq!(code(400, ""), "drive request failed");
    }

    #[test]
    fn passing_faults_are_tried_again_then_given_up() {
        let tries = std::cell::Cell::new(0);
        let r: Result<()> = again(|| {
            tries.set(tries.get() + 1);
            Err(Error::Corrupt("drive server error"))
        });
        assert!(r.is_err());
        assert_eq!(tries.get(), TRIES);
        // Not a passing fault: once.
        tries.set(0);
        let r: Result<()> = again(|| {
            tries.set(tries.get() + 1);
            Err(Error::Corrupt("drive full"))
        });
        assert!(r.is_err());
        assert_eq!(tries.get(), 1);
        // Recovers on the second try.
        tries.set(0);
        let r = again(|| {
            tries.set(tries.get() + 1);
            if tries.get() < 2 {
                Err(Error::Corrupt("drive rate limited"))
            } else {
                Ok(7)
            }
        });
        assert_eq!(r.unwrap(), 7);
    }
}
