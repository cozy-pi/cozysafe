//! Google Drive as a sync place (docs/adr/0003-sync.md). The vault's sealed files live in
//! one folder the app made ("Cozy Safe"), each named by its path in the sync layout
//! (`<vault>/records/<id>/<rev>`, …): with the `drive.file` scope the app sees only
//! what it made, and Google sees only sealed bytes and those names (random ids and
//! numbers). Every session needs a [`Permit::google_drive`] and an access token from
//! the person's sign-in; nothing runs in the background.

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
/// Most deletions in one batch request (Google takes up to 100 calls in one).
const BATCH: usize = 100;
/// Largest answer to a batch read (100 short answers come to a few tens of KiB).
const MAX_BATCH_ANSWER: usize = 1 << 20;
/// Separates the parts of a batch request. Drive ids are letters, digits, '-' and '_',
/// and no line of a part starts with "--", so it never occurs inside one.
const BOUNDARY: &str = "cozysafe_batch_9c1e4b";

/// What the sync needs from Drive, so the logic is tested without the network.
pub trait DriveApi: Send + Sync {
    /// The app's folder, made if missing.
    fn folder(&self) -> Result<String>;
    /// Every file in `folder`: (id, name).
    fn files(&self, folder: &str) -> Result<Vec<(String, String)>>;
    /// The file's bytes into `out`; false if it is gone.
    fn download(&self, id: &str, out: &mut dyn Write) -> Result<bool>;
    /// A new file named `name` in `folder`, `len` bytes from `src`; its id.
    fn upload(&self, folder: &str, name: &str, len: u64, src: &mut dyn Read) -> Result<String>;
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

/// The sync place: one Drive folder, listed once per session.
pub struct DriveRemote<A: DriveApi> {
    api: A,
    folder: String,
    /// name → id, kept up to date as files are added.
    index: Mutex<HashMap<String, String>>,
    /// Names being uploaded right now (items go up a few at once).
    uploading: Mutex<HashSet<String>>,
    /// Set by Cancel: the next request ends the sync (what was done is kept).
    stop: Option<&'static AtomicBool>,
}

impl<A: DriveApi> DriveRemote<A> {
    pub fn open(api: A) -> Result<Self> {
        let folder = api.folder()?;
        let index = api
            .files(&folder)?
            .into_iter()
            .map(|(id, name)| (name, id))
            .collect();
        Ok(DriveRemote {
            api,
            folder,
            index: Mutex::new(index),
            uploading: Mutex::new(HashSet::new()),
            stop: None,
        })
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
        let up = self.api.upload(&self.folder, path, len, src);
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
}

fn status_ok(status: u16) -> Result<()> {
    match status {
        200..=299 => Ok(()),
        401 | 403 => Err(Error::Corrupt("drive not signed in")),
        _ => Err(Error::Corrupt("drive request failed")),
    }
}

/// A batch request deleting `ids` (at most [`BATCH`]): one `DELETE` part each, numbered
/// from 1 in `Content-ID`. The outer request's sign-in covers every part.
fn batch_body(ids: &[String]) -> Result<Vec<u8>> {
    if ids.is_empty() || ids.len() > BATCH {
        return Err(Error::Corrupt("drive batch size"));
    }
    let mut out = String::new();
    for (n, id) in ids.iter().enumerate() {
        if id.is_empty()
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
        {
            return Err(Error::Corrupt("drive file id"));
        }
        out.push_str(&format!(
            "--{BOUNDARY}\r\nContent-Type: application/http\r\nContent-ID: <{}>\r\n\r\nDELETE /drive/v3/files/{id}\r\n\r\n",
            n + 1
        ));
    }
    out.push_str(&format!("--{BOUNDARY}--\r\n"));
    Ok(out.into_bytes())
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

/// Check the answer to a batch of `n` deletions: every part answered exactly once,
/// each with 204 (deleted) or 404 (gone already). Anything else fails the whole batch.
fn batch_check(content_type: &str, body: &[u8], n: usize) -> Result<()> {
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
    let mut answered = vec![false; n];
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
                if std::mem::replace(&mut answered[id], true) {
                    return Err(bad());
                }
                if !matches!(status, 204 | 404) {
                    status_ok(status)?;
                    return Err(Error::Corrupt("drive request failed"));
                }
                At::Body
            }
            At::Closed => unreachable!(),
        };
    }
    if !matches!(at, At::Closed) || answered.contains(&false) {
        return Err(bad());
    }
    Ok(())
}

impl DriveApi for GoogleDrive {
    fn folder(&self) -> Result<String> {
        let q = format!("name = '{FOLDER}' and mimeType = '{FOLDER_MIME}' and trashed = false");
        let found = self.json(
            "GET",
            &format!(
                "/drive/v3/files?q={}&fields=files(id)&spaces=drive",
                https::encode(&q)
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

    fn files(&self, folder: &str) -> Result<Vec<(String, String)>> {
        let q = format!("'{folder}' in parents and trashed = false");
        let mut out = Vec::new();
        let mut page = String::new();
        loop {
            let mut path = format!(
                "/drive/v3/files?q={}&fields=nextPageToken,files(id,name)&pageSize=1000&spaces=drive",
                https::encode(&q)
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

    /// Up to [`BATCH`] deletions per request, through Google's batch endpoint (same host).
    fn delete_many(&self, ids: &[String]) -> Result<()> {
        let kind = format!("multipart/mixed; boundary={BOUNDARY}");
        for chunk in ids.chunks(BATCH) {
            if let [id] = chunk {
                self.delete(id)?;
                continue;
            }
            let r = self.http.request(
                "POST",
                "/batch/drive/v3",
                &self.token,
                &[],
                Body::Bytes(&kind, batch_body(chunk)?),
            )?;
            let status = r.status;
            let answer_kind = r.header("Content-Type").unwrap_or("").to_owned();
            let body = r.bytes_max(MAX_BATCH_ANSWER)?;
            status_ok(status)?;
            batch_check(&answer_kind, &body, chunk.len())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{note, text, two};

    /// Drive in memory.
    /// (id, name, bytes) of every file.
    type Files = Vec<(String, String, Vec<u8>)>;

    #[derive(Default, Clone)]
    struct Fake(
        std::sync::Arc<Mutex<Files>>,
        std::sync::Arc<Mutex<Vec<usize>>>,
    );

    impl DriveApi for Fake {
        fn folder(&self) -> Result<String> {
            Ok("F".into())
        }
        fn files(&self, _: &str) -> Result<Vec<(String, String)>> {
            Ok(self
                .0
                .lock()
                .unwrap()
                .iter()
                .map(|(i, n, _)| (i.clone(), n.clone()))
                .collect())
        }
        fn download(&self, id: &str, out: &mut dyn Write) -> Result<bool> {
            let files = self.0.lock().unwrap();
            match files.iter().find(|(i, _, _)| i == id) {
                Some((_, _, b)) => {
                    out.write_all(b)?;
                    Ok(true)
                }
                None => Ok(false),
            }
        }
        fn upload(&self, _: &str, name: &str, len: u64, src: &mut dyn Read) -> Result<String> {
            let mut b = Vec::new();
            src.take(len).read_to_end(&mut b)?;
            let mut files = self.0.lock().unwrap();
            // Never reused, like Drive's ids (a count of files would repeat after a delete).
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let id = format!(
                "id{}",
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            );
            files.push((id.clone(), name.to_owned(), b));
            Ok(id)
        }
        fn delete(&self, id: &str) -> Result<()> {
            self.0.lock().unwrap().retain(|(i, _, _)| i != id);
            Ok(())
        }
        fn delete_many(&self, ids: &[String]) -> Result<()> {
            self.1.lock().unwrap().push(ids.len());
            self.0.lock().unwrap().retain(|(i, _, _)| !ids.contains(i));
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
        // One lock there, the newest.
        let locks = drive
            .0
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, n, _)| n.contains("/lock/"))
            .count();
        assert_eq!(locks, 1);
        // Only sealed bytes reach Drive.
        for (_, _, b) in drive.0.lock().unwrap().iter() {
            // Long markers: three random bytes can spell "aaa" by chance.
            assert!(!b.windows(10).any(|w| w == b"plain text"));
        }
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
        // One file per name, though several went up together.
        let names: Vec<String> = drive
            .0
            .lock()
            .unwrap()
            .iter()
            .map(|f| f.1.clone())
            .collect();
        let unique: HashSet<&String> = names.iter().collect();
        assert_eq!(unique.len(), names.len());
        t.b.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        for (i, id) in ids.iter().enumerate() {
            assert_eq!(text(&t.b, id), format!("text {i}"));
        }
        for id in &ids {
            t.a.delete_item(id).unwrap();
        }
        let before = drive.0.lock().unwrap().len();
        t.a.sync(&DriveRemote::open(drive.clone()).unwrap())
            .unwrap();
        // A record and its content per item, in two batches (records, then contents).
        assert_eq!(*drive.1.lock().unwrap(), vec![30, 30]);
        let after = drive.0.lock().unwrap().len();
        assert_eq!(before - after, 60 - 1); // and one journal entry more
    }

    #[test]
    fn a_batch_request_has_one_delete_per_file() {
        let ids: Vec<String> = vec!["abc-1".into(), "x_Y2".into()];
        let body = String::from_utf8(batch_body(&ids).unwrap()).unwrap();
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
        // Nothing that could break out of a part, and never more than Google takes.
        for bad in ["a/b", "a b", "a\r\nb", "", "a?b", "a%2F"] {
            assert!(batch_body(&[bad.to_owned()]).is_err(), "{bad:?}");
        }
        assert!(batch_body(&[]).is_err());
        assert!(batch_body(&vec!["a".to_owned(); BATCH + 1]).is_err());
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
}
