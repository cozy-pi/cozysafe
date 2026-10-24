//! Google Drive as a sync place (docs/adr/0003-sync.md). The vault's sealed files live in
//! one folder the app made ("Cozy Safe"), each named by its path in the sync layout
//! (`<vault>/records/<id>/<rev>`, …): with the `drive.file` scope the app sees only
//! what it made, and Google sees only sealed bytes and those names (random ids and
//! numbers). Every session needs a [`Permit::google_drive`] and an access token from
//! the person's sign-in; nothing runs in the background.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::Mutex;

use cs_vault::sync::Remote;
use cs_vault::{Error, Result};
use serde_json::Value;

use crate::https::{self, Body};
use crate::Permit;

/// The folder the app keeps in the person's Drive.
pub const FOLDER: &str = "Cozy Safe";
const FOLDER_MIME: &str = "application/vnd.google-apps.folder";

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
    /// Delete the file (only ever an old copy of the vault's lock).
    fn delete(&self, id: &str) -> Result<()>;
}

/// The sync place: one Drive folder, listed once per session.
pub struct DriveRemote<A: DriveApi> {
    api: A,
    folder: String,
    /// name → id, kept up to date as files are added.
    index: Mutex<HashMap<String, String>>,
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
        })
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
        match self.id(path) {
            Some(id) => self.api.download(&id, out),
            None => Ok(false),
        }
    }

    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        check(path)?;
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
        let mut f = std::fs::File::open(local)?;
        let len = f.metadata()?.len();
        self.put_bytes(path, len, &mut f)
    }
}

impl<A: DriveApi> DriveRemote<A> {
    fn put_bytes(&self, path: &str, len: u64, src: &mut dyn Read) -> Result<()> {
        // Never two files of one name: the layout's files never change once written.
        if self.id(path).is_some() {
            return Ok(());
        }
        let id = self.api.upload(&self.folder, path, len, src)?;
        self.index
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(path.to_owned(), id);
        Ok(())
    }
}

/// The real Drive, through [`https`].
pub struct GoogleDrive {
    token: String,
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
        Ok(GoogleDrive { token })
    }

    fn json(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value> {
        let r = https::request(
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
        let r = https::request(
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
        let r = https::request(
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
        let path = at
            .strip_prefix(&format!("https://{}", https::HOST))
            .ok_or(Error::Corrupt("drive upload url on another host"))?;
        let r = https::request(
            "PUT",
            path,
            &self.token,
            &[],
            Body::Stream("application/octet-stream", len, src),
        )?;
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
        let r = https::request(
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{note, text, two};

    /// Drive in memory.
    /// (id, name, bytes) of every file.
    type Files = Vec<(String, String, Vec<u8>)>;

    #[derive(Default, Clone)]
    struct Fake(std::sync::Arc<Mutex<Files>>);

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
}
