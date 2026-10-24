//! Google Drive as a sync place (docs/adr/0003-sync.md). The vault's sealed files live in
//! a folder the app made ("Cozy Safe"), one folder per vault inside it named by the
//! vault's id, each file named by the rest of its path in the sync layout
//! (`records/<id>/<rev>`, …; no deeper folders): with the `drive.file` scope the app sees
//! only what it made, and Google sees only sealed bytes and those names (random ids and
//! numbers). Every session needs a [`Permit::google_drive`] and an access token from
//! the person's sign-in; nothing runs in the background.
//!
//! Earlier versions kept every file flat in "Cozy Safe", named by its whole path
//! (`<vault>/records/<id>/<rev>`). Opening moves those into their vault's folder, one
//! rename each, no bytes sent again.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

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
/// Separates the parts of a batch request. Drive ids are letters, digits, '-' and '_',
/// and no line of a part starts with "--", so it never occurs inside one.
const BOUNDARY: &str = "cozysafe_batch_9c1e4b";

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
    /// Every folder directly in `parent`: (id, name).
    fn folders(&self, parent: &str) -> Result<Vec<(String, String)>>;
    /// Every file (not folder) directly in `folder`: (id, name).
    fn files(&self, folder: &str) -> Result<Vec<(String, String)>>;
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

/// The sync place: the app's Drive folder and its vault folders, listed once per session.
pub struct DriveRemote<A: DriveApi> {
    api: A,
    /// The "Cozy Safe" folder.
    root: String,
    /// vault id → its folder, made on the vault's first file.
    vaults: Mutex<HashMap<String, String>>,
    /// Sync path (`<vault>/<name>`) → file id, kept up to date as files are added.
    index: Mutex<HashMap<String, String>>,
    /// Paths being uploaded right now (items go up a few at once).
    uploading: Mutex<HashSet<String>>,
    /// Set by Cancel: the next request ends the sync (what was done is kept).
    stop: Option<&'static AtomicBool>,
}

/// A vault's id, as the app makes them: 32 lowercase hex digits.
fn is_vault(name: &str) -> bool {
    name.len() == 32 && name.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A sync path's vault and the rest (its file name in the vault's folder).
fn split(path: &str) -> Option<(&str, &str)> {
    path.split_once('/')
        .filter(|(vault, rest)| is_vault(vault) && !rest.is_empty())
}

impl<A: DriveApi> DriveRemote<A> {
    pub fn open(api: A) -> Result<Self> {
        let root = api.folder()?;
        // A vault's folder: the first by id, should two devices have made one at once.
        let mut found: Vec<(String, String)> = api
            .folders(&root)?
            .into_iter()
            .filter(|(_, name)| is_vault(name))
            .collect();
        found.sort();
        let mut vaults: HashMap<String, String> = HashMap::new();
        let mut others = Vec::new();
        for (id, vault) in found {
            match vaults.entry(vault) {
                Entry::Occupied(e) => others.push((id, e.key().clone())),
                Entry::Vacant(e) => {
                    e.insert(id);
                }
            }
        }
        let mut index = HashMap::new();
        for (vault, folder) in &vaults {
            for (id, name) in api.files(folder)? {
                let path = format!("{vault}/{name}");
                if check(&path).is_ok() {
                    index.entry(path).or_insert(id);
                }
            }
        }
        // Files not in their vault's folder yet: in a second folder of the vault, or flat
        // in "Cozy Safe" (earlier versions), named by their whole path.
        let mut astray = Vec::new();
        for (folder, vault) in &others {
            for (id, name) in api.files(folder)? {
                astray.push((format!("{vault}/{name}"), id, folder.clone()));
            }
        }
        for (id, name) in api.files(&root)? {
            if split(&name).is_some() {
                astray.push((name, id, root.clone()));
            }
        }
        let remote = DriveRemote {
            api,
            root,
            vaults: Mutex::new(vaults),
            index: Mutex::new(HashMap::new()),
            uploading: Mutex::new(HashSet::new()),
            stop: None,
        };
        remote.gather(&mut index, astray)?;
        *remote.index.lock().unwrap_or_else(|p| p.into_inner()) = index;
        Ok(remote)
    }

    /// Bring `astray` files (path, id, folder) into their vault's folder: moved, or
    /// deleted when the vault's folder has that file already (files never change, so the
    /// copies are the same). Each move is one rename, so a move cut short leaves every
    /// file in one place or the other, and the next open goes on.
    fn gather(
        &self,
        index: &mut HashMap<String, String>,
        astray: Vec<(String, String, String)>,
    ) -> Result<()> {
        let mut moves = Vec::new();
        let mut paths = Vec::new();
        let mut seen = HashSet::new();
        let mut copies = Vec::new();
        for (path, id, from) in astray {
            let Some((vault, name)) = split(&path).filter(|_| check(&path).is_ok()) else {
                continue;
            };
            if index.contains_key(&path) || !seen.insert(path.clone()) {
                copies.push(id);
                continue;
            }
            moves.push(Move {
                id,
                from,
                to: self.vault_folder(vault)?,
                name: name.to_owned(),
            });
            paths.push(path);
        }
        if !moves.is_empty() {
            let moved = self.api.move_many(&moves)?;
            if moved.len() != moves.len() {
                return Err(Error::Corrupt("drive move answer"));
            }
            for ((m, path), ok) in moves.into_iter().zip(paths).zip(moved) {
                if ok {
                    index.insert(path, m.id);
                }
            }
        }
        if !copies.is_empty() {
            self.api.delete_many(&copies)?;
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
            .keys()
            .filter_map(|n| n.split_once("/lock/").map(|(id, _)| id.to_owned()))
            .collect();
        ids.sort();
        ids.dedup();
        ids
    }

    fn id(&self, path: &str) -> Option<String> {
        self.index
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(path)
            .cloned()
    }

    /// The vault's folder, made the first time (held while made, so items going up at
    /// once never make two).
    fn vault_folder(&self, vault: &str) -> Result<String> {
        let mut vaults = self.vaults.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(id) = vaults.get(vault) {
            return Ok(id.clone());
        }
        let id = self.api.make_folder(&self.root, vault)?;
        vaults.insert(vault.to_owned(), id.clone());
        Ok(id)
    }
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
        let prefix = format!("{dir}/");
        let index = self.index.lock().unwrap_or_else(|p| p.into_inner());
        let mut names: Vec<String> = index
            .keys()
            .filter_map(|n| n.strip_prefix(&prefix))
            .map(|rest| rest.split('/').next().unwrap_or(rest).to_owned())
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

    fn remove(&self, path: &str) -> Result<()> {
        check(path)?;
        let id = self
            .index
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(path);
        match id {
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
        let found: Vec<(&String, String)> = {
            let index = self.index.lock().unwrap_or_else(|p| p.into_inner());
            paths
                .iter()
                .filter_map(|p| index.get(p).map(|id| (p, id.clone())))
                .collect()
        };
        let ids: Vec<String> = found.iter().map(|(_, id)| id.clone()).collect();
        self.api.delete_many(&ids)?;
        let mut index = self.index.lock().unwrap_or_else(|p| p.into_inner());
        for (p, _) in found {
            index.remove(p);
        }
        Ok(())
    }

    fn parallel(&self) -> usize {
        AT_ONCE
    }
}

impl<A: DriveApi> DriveRemote<A> {
    fn put_bytes(&self, path: &str, len: u64, src: &mut dyn Read) -> Result<()> {
        // Every file belongs to a vault: `<vault>/<name>`.
        let (vault, name) = split(path).ok_or(Error::Corrupt("drive path"))?;
        // Never two files of one name: the layout's files never change once written. With
        // items going up at once, a name is claimed before its upload and known (in the
        // index) before the claim ends.
        {
            let index = self.index.lock().unwrap_or_else(|p| p.into_inner());
            if index.contains_key(path) {
                return Ok(());
            }
            let mut uploading = self.uploading.lock().unwrap_or_else(|p| p.into_inner());
            if !uploading.insert(path.to_owned()) {
                return Err(Error::Corrupt("drive file sent twice at once"));
            }
        }
        let up = self
            .vault_folder(vault)
            .and_then(|folder| self.api.upload(&folder, name, len, src));
        if let Ok(id) = &up {
            self.index
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(path.to_owned(), id.clone());
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
        status_ok(status)?;
        serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt("drive json"))
    }

    /// Every (id, name) matching the query `q`, page by page.
    fn list(&self, q: &str) -> Result<Vec<(String, String)>> {
        let mut out = Vec::new();
        let mut page = String::new();
        loop {
            let mut path = format!(
                "/drive/v3/files?q={}&fields=nextPageToken,files(id,name)&pageSize=1000&spaces=drive",
                https::encode(q)
            );
            if !page.is_empty() {
                path.push_str(&format!("&pageToken={}", https::encode(&page)));
            }
            let v = self.json("GET", &path, None)?;
            for f in v["files"].as_array().into_iter().flatten() {
                if let (Some(id), Some(name)) = (f["id"].as_str(), f["name"].as_str()) {
                    out.push((id.to_owned(), name.to_owned()));
                }
            }
            match v["nextPageToken"].as_str() {
                Some(t) => page = t.to_owned(),
                None => return Ok(out),
            }
        }
    }

    /// Up to [`BATCH`] calls in one request to Google's batch endpoint (same host); the
    /// status of each, in order.
    fn batch(&self, parts: &[Part]) -> Result<Vec<u16>> {
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
        status_ok(status)?;
        batch_statuses(&answer_kind, &body, parts.len())
    }
}

fn status_ok(status: u16) -> Result<()> {
    match status {
        200..=299 => Ok(()),
        401 | 403 => Err(Error::Corrupt("drive not signed in")),
        _ => Err(Error::Corrupt("drive request failed")),
    }
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

/// The query for what is directly in `parent`: its folders, or its other files.
fn children_query(parent: &str, folders: bool) -> Result<String> {
    Ok(format!(
        "{} in parents and mimeType {} {} and trashed = false",
        quoted(drive_id(parent)?),
        if folders { "=" } else { "!=" },
        quoted(FOLDER_MIME)
    ))
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

    fn folders(&self, parent: &str) -> Result<Vec<(String, String)>> {
        self.list(&children_query(parent, true)?)
    }

    fn files(&self, folder: &str) -> Result<Vec<(String, String)>> {
        self.list(&children_query(folder, false)?)
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
        let r = self.http.request(
            "GET",
            &format!("/drive/v3/files/{}?alt=media", https::encode(id)),
            &self.token,
            &[],
            Body::None,
        )?;
        if r.status == 404 {
            return Ok(false);
        }
        status_ok(r.status)?;
        r.copy_to(out)?;
        Ok(true)
    }

    fn upload(&self, folder: &str, name: &str, len: u64, src: &mut dyn Read) -> Result<String> {
        // Resumable upload: the metadata first, then the bytes to the URL Drive gives,
        // which must be on the same host.
        let meta = serde_json::json!({ "name": name, "parents": [folder] });
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
        status_ok(r.status)?;
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
        let body = if len <= SMALL_UPLOAD {
            let mut b = Vec::new();
            src.take(len).read_to_end(&mut b)?;
            if b.len() as u64 != len {
                return Err(Error::Corrupt("drive upload short"));
            }
            Body::Bytes("application/octet-stream", b)
        } else {
            Body::Stream("application/octet-stream", len, src)
        };
        let r = self.http.request("PUT", path, &self.token, &[], body)?;
        let status = r.status;
        let v: Value =
            serde_json::from_slice(&r.bytes()?).map_err(|_| Error::Corrupt("drive json"))?;
        status_ok(status)?;
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

    /// A file or folder of the fake Drive.
    #[derive(Clone, Debug)]
    struct Node {
        id: String,
        parent: String,
        name: String,
        bytes: Vec<u8>,
        folder: bool,
    }

    #[derive(Default)]
    struct State {
        nodes: Vec<Node>,
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

        fn children(&self, parent: &str, folder: bool) -> Vec<(String, String)> {
            self.state()
                .nodes
                .iter()
                .filter(|n| n.parent == parent && n.folder == folder)
                .map(|n| (n.id.clone(), n.name.clone()))
                .collect()
        }

        fn add(&self, parent: &str, name: &str, bytes: Vec<u8>, folder: bool) -> String {
            let id = new_id();
            self.state().nodes.push(Node {
                id: id.clone(),
                parent: parent.to_owned(),
                name: name.to_owned(),
                bytes,
                folder,
            });
            id
        }

        /// The layout of earlier versions: every file flat in "F", named by its whole
        /// path; no vault folders.
        fn flatten(&self) {
            let mut s = self.state();
            let folders: HashMap<String, String> = s
                .nodes
                .iter()
                .filter(|n| n.folder)
                .map(|n| (n.id.clone(), n.name.clone()))
                .collect();
            s.nodes.retain(|n| !n.folder);
            for n in &mut s.nodes {
                n.name = format!("{}/{}", folders[&n.parent], n.name);
                n.parent = "F".into();
            }
        }

        /// Every file: (folder name, file name, id).
        fn layout(&self) -> Vec<(String, String, String)> {
            let s = self.state();
            let name_of = |id: &str| {
                s.nodes
                    .iter()
                    .find(|n| n.id == id)
                    .map_or(id.to_owned(), |n| n.name.clone())
            };
            let mut out: Vec<_> = s
                .nodes
                .iter()
                .filter(|n| !n.folder)
                .map(|n| (name_of(&n.parent), n.name.clone(), n.id.clone()))
                .collect();
            out.sort();
            out
        }
    }

    impl DriveApi for Fake {
        fn folder(&self) -> Result<String> {
            Ok("F".into())
        }
        fn folders(&self, parent: &str) -> Result<Vec<(String, String)>> {
            Ok(self.children(parent, true))
        }
        fn files(&self, folder: &str) -> Result<Vec<(String, String)>> {
            Ok(self.children(folder, false))
        }
        fn make_folder(&self, parent: &str, name: &str) -> Result<String> {
            Ok(self.add(parent, name, Vec::new(), true))
        }
        fn download(&self, id: &str, out: &mut dyn Write) -> Result<bool> {
            let s = self.state();
            match s.nodes.iter().find(|n| n.id == id && !n.folder) {
                Some(n) => {
                    out.write_all(&n.bytes)?;
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
                .any(|n| n.id == folder && n.folder));
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
            match s.nodes.iter_mut().find(|n| n.id == m.id) {
                Some(n) => {
                    assert_eq!(n.parent, m.from);
                    n.parent = m.to.clone();
                    n.name = m.name.clone();
                    Ok(true)
                }
                None => Ok(false),
            }
        }
        fn delete(&self, id: &str) -> Result<()> {
            self.state().nodes.retain(|n| n.id != id);
            Ok(())
        }
        fn delete_many(&self, ids: &[String]) -> Result<()> {
            let mut s = self.state();
            s.batches.push(ids.len());
            s.nodes.retain(|n| !ids.contains(&n.id));
            Ok(())
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
        // One folder, the vault's, in the app's folder; every file in it, named by the
        // rest of its path.
        assert_eq!(drive.children("F", true).len(), 1);
        assert_eq!(drive.children("F", true)[0].1, t.a.id);
        assert!(drive.children("F", false).is_empty());
        let layout = drive.layout();
        assert!(
            layout.iter().all(|(folder, name, _)| folder == &t.a.id
                && !name.starts_with(&t.a.id)
                && !name.contains(".."))
                && ["records/", "blobs/", "log/", "lock/"]
                    .iter()
                    .all(|p| layout.iter().any(|(_, n, _)| n.starts_with(p)))
        );
        // One lock there, the newest.
        let locks = layout
            .iter()
            .filter(|(_, n, _)| n.starts_with("lock/"))
            .count();
        assert_eq!(locks, 1);
        // Only sealed bytes reach Drive.
        for n in drive.state().nodes.iter() {
            // Long markers: three random bytes can spell "aaa" by chance.
            assert!(!n.bytes.windows(10).any(|w| w == b"plain text"));
        }
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
        let mut folders: Vec<String> = drive.children("F", true).into_iter().map(|f| f.1).collect();
        folders.sort();
        let mut ids = vec![one.a.id.clone(), other.a.id.clone()];
        ids.sort();
        assert_eq!(folders, ids);
        let r = DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(r.vault_ids(), ids);
        one.b.sync(&r).unwrap();
        other.b.sync(&r).unwrap();
        assert_eq!(text(&one.b, &a), "vault one");
        assert_eq!(text(&other.b, &b), "vault two");
        // Every file sits in its own vault's folder.
        for (folder, name, _) in drive.layout() {
            assert!(ids.contains(&folder), "{folder}/{name}");
        }
        // A path outside any vault is refused, never put in "Cozy Safe" itself.
        assert!(r.put("records/x", &mut &b"x"[..]).is_err());
        assert!(r.put(&one.a.id, &mut &b"x"[..]).is_err());
    }

    #[test]
    fn files_of_earlier_versions_move_into_the_vault_folder() {
        let t = two();
        let drive = Fake::default();
        let ids: Vec<String> = (0..5)
            .map(|i| note(&t.a, &format!("N{i}"), &format!("text {i}")))
            .collect();
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        drive.flatten();
        let flat = drive.layout();
        assert!(flat
            .iter()
            .all(|(f, n, _)| f == "F" && n.starts_with(&t.a.id)));
        let uploads = drive.state().uploads;
        // Anything else in the folder is left alone.
        drive.add("F", "notes.txt", b"x".to_vec(), false);
        let r = DriveRemote::open(drive.clone()).unwrap();
        // Renamed in place: the same files (ids), none sent again.
        let moved = drive.layout();
        assert_eq!(drive.state().uploads, uploads);
        assert_eq!(drive.state().moves, flat.len());
        assert_eq!(moved.len(), flat.len() + 1);
        for (folder, name, id) in &flat {
            let rest = name.strip_prefix(&format!("{}/", t.a.id)).unwrap();
            assert!(
                moved.contains(&(t.a.id.clone(), rest.to_owned(), id.clone())),
                "{folder}/{name}"
            );
        }
        assert_eq!(r.vault_ids(), vec![t.a.id.clone()]);
        // Then it syncs as usual.
        t.b.sync(&r).unwrap();
        for (i, id) in ids.iter().enumerate() {
            assert_eq!(text(&t.b, id), format!("text {i}"));
        }
        // Opened again, nothing more to move.
        DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(drive.state().moves, flat.len());
    }

    #[test]
    fn a_move_cut_short_goes_on_next_time() {
        let t = two();
        let drive = Fake::default();
        let id = note(&t.a, "N", "moved in two goes");
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        drive.flatten();
        let all = drive.layout().len();
        assert!(all > 3);
        drive.state().moves_left = Some(3);
        assert!(DriveRemote::open(drive.clone()).is_err());
        // Each file in one place or the other.
        let half = drive.layout();
        assert_eq!(half.len(), all);
        assert_eq!(half.iter().filter(|(f, _, _)| f == &t.a.id).count(), 3);
        drive.state().moves_left = None;
        let r = DriveRemote::open(drive.clone()).unwrap();
        assert!(drive.layout().iter().all(|(f, _, _)| f == &t.a.id));
        assert_eq!(drive.state().moves, all);
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
        let before = drive.layout();
        let first = drive.children("F", true)[0].0.clone();
        let bytes = |file: &str| {
            let s = drive.state();
            s.nodes.iter().find(|n| n.id == file).unwrap().bytes.clone()
        };
        // An old flat copy of every file (a move cut short between the rename and the
        // listing), and a second folder of the vault (two devices made one at once)
        // holding a copy of one file and a file of its own.
        for (_, name, file) in &before {
            let b = bytes(file);
            drive.add("F", &format!("{}/{name}", t.a.id), b, false);
        }
        let second = drive.add("F", &t.a.id, Vec::new(), true);
        let b = bytes(&before[0].2);
        drive.add(&second, &before[0].1, b, false);
        drive.add(&second, "log/zz/1", b"x".to_vec(), false);
        let uploads = drive.state().uploads;
        let r = DriveRemote::open(drive.clone()).unwrap();
        assert_eq!(drive.state().uploads, uploads);
        // The copies are gone: each name once, in one of the vault's folders (the other
        // left empty), nothing in the app's folder itself.
        assert!(drive.children("F", false).is_empty());
        let after = drive.layout();
        assert_eq!(after.len(), before.len() + 1);
        assert!(after.iter().all(|(f, _, _)| f == &t.a.id));
        let kept = [first, second].map(|f| drive.children(&f, false).len());
        assert!(kept.contains(&0) && kept.contains(&after.len()), "{kept:?}");
        for (_, name, _) in &before {
            assert!(after.iter().any(|(_, n, _)| n == name), "{name}");
        }
        assert!(r.exists(&format!("{}/log/zz/1", t.a.id)).unwrap());
        assert_eq!(r.vault_ids(), vec![t.a.id.clone()]);
        t.b.sync(&r).unwrap();
        assert_eq!(text(&t.b, &id), "one copy");
    }

    #[test]
    fn drive_queries_are_quoted_and_ids_checked() {
        assert_eq!(
            folder_query(),
            "name = 'Cozy Safe' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        );
        assert_eq!(
            children_query("aB-9_x", true).unwrap(),
            "'aB-9_x' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        );
        assert_eq!(
            children_query("aB-9_x", false).unwrap(),
            "'aB-9_x' in parents and mimeType != 'application/vnd.google-apps.folder' and trashed = false"
        );
        assert_eq!(quoted(r"it's a \ name"), r"'it\'s a \\ name'");
        for bad in ["", "a' or 'x", "a b", "a\\b", "a/b", "a%27"] {
            assert!(children_query(bad, true).is_err(), "{bad:?}");
        }
        // And encoded whole into the URL.
        assert_eq!(
            https::encode(&children_query("x", true).unwrap()),
            "%27x%27%20in%20parents%20and%20mimeType%20%3D%20%27application%2Fvnd.google-apps.folder%27%20and%20trashed%20%3D%20false"
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
        // One file per name and one folder, though several went up together.
        assert_eq!(drive.children("F", true).len(), 1);
        let names: Vec<(String, String, String)> = drive.layout();
        let unique: HashSet<(&String, &String)> = names.iter().map(|(f, n, _)| (f, n)).collect();
        assert_eq!(unique.len(), names.len());
        t.b.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        for (i, id) in ids.iter().enumerate() {
            assert_eq!(text(&t.b, id), format!("text {i}"));
        }
        for id in &ids {
            t.a.delete_item(id).unwrap();
        }
        let before = drive.layout().len();
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        // A record and its content per item, in two batches (records, then contents).
        assert_eq!(drive.state().batches, vec![30, 30]);
        let after = drive.layout().len();
        assert_eq!(before - after, 60 - 1); // and one journal entry more
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
        let forbidden = answer(&[("1", "200 OK"), ("2", "403 Forbidden")]);
        assert!(matches!(
            moved(batch_statuses(KIND, &forbidden, 2).unwrap()),
            Err(Error::Corrupt("drive not signed in"))
        ));
        assert!(batch_statuses(KIND, &answer(&[("1", "200 OK")]), 2).is_err());
    }
}
