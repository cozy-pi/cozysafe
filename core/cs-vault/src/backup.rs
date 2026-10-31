//! One-file backup of a whole library, and restoring it on a fresh install.
//!
//! Everything in a library is already encrypted or public (salts, parameters, the
//! Secret Key fingerprint), so the backup is a plain container of those files. What a
//! backup leaves out on purpose: anything tied to this device (biometric and PIN
//! copies of vault keys, the first-preview `secret-key` file) and half-written temp
//! files. Opening a restored library needs the Secret Key (Emergency Kit) and a password.
//!
//! Layout: `MAGIC`, then per file `u16 path length ‖ path (UTF-8, '/') ‖ u64 size ‖
//! bytes`, ended by a zero path length and the number of files as `u32`. Files stream
//! through a fixed buffer, so multi-gigabyte libraries need no extra memory.
//!
//! Item files are named `vaults/<vault>/items/<item>.<ext>` in a backup, as they were on
//! disk before buckets (0.1.57): the format does not change. Export takes them from their
//! buckets (`items/<bucket>/`), import puts them back there.

use std::fs;
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use crate::items::ITEM_EXTS;
use crate::{Error, Result, HEADER_FILE, LIBRARY_FILE, VAULTS_DIR};

const MAGIC: &[u8; 16] = b"COZYSAFE-BACKUP1";
const ITEMS_DIR: &str = "items";

/// Write a backup of the library in `dir` to `out`. Returns the number of files.
pub fn export<W: Write>(dir: &Path, out: W) -> Result<u32> {
    let mut out = BufWriter::new(out);
    out.write_all(MAGIC)?;
    let mut count = 0u32;
    for (rel, path) in files(dir)? {
        let size = fs::metadata(&path)?.len();
        let name = rel.replace('\\', "/");
        out.write_all(&(name.len() as u16).to_be_bytes())?;
        out.write_all(name.as_bytes())?;
        out.write_all(&size.to_be_bytes())?;
        let copied = io::copy(&mut fs::File::open(&path)?.take(size), &mut out)?;
        if copied != size {
            return Err(Error::Corrupt("file changed during backup"));
        }
        count += 1;
    }
    out.write_all(&0u16.to_be_bytes())?;
    out.write_all(&count.to_be_bytes())?;
    out.flush()?;
    Ok(count)
}

/// Restore a backup into `dir`, which must not hold a library yet. Writes into a
/// staging directory first and moves it into place only once the whole file checked
/// out, so a damaged or truncated backup leaves nothing behind.
pub fn import<R: Read>(input: R, dir: &Path) -> Result<u32> {
    if dir.join(LIBRARY_FILE).exists() {
        return Err(Error::LibraryExists);
    }
    let staging = staging_dir(dir);
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    match read_into(input, &staging).and_then(|n| check_library(&staging).map(|_| n)) {
        Ok(n) if staging.join(LIBRARY_FILE).is_file() => {
            if dir.exists() {
                fs::remove_dir_all(dir)?; // empty or leftover without a library
            }
            fs::rename(&staging, dir)?;
            Ok(n)
        }
        Ok(_) => {
            let _ = fs::remove_dir_all(&staging);
            Err(Error::BadBackup)
        }
        Err(e) => {
            let _ = fs::remove_dir_all(&staging);
            Err(e)
        }
    }
}

/// The restored library's header, if it came: readable, and an Argon2 cost no lower
/// than the floor (a backup naming less was tampered with).
fn check_library(dir: &Path) -> Result<()> {
    if !dir.join(LIBRARY_FILE).is_file() {
        return Ok(()); // refused as not a backup by the caller
    }
    let header = crate::read_library_header(dir).map_err(|_| Error::BadBackup)?;
    cs_crypto::kdf::KdfParams::from(header.kdf).check()?;
    Ok(())
}

fn staging_dir(dir: &Path) -> PathBuf {
    let mut name = dir
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".restoring");
    dir.with_file_name(name)
}

fn read_into<R: Read>(input: R, dir: &Path) -> Result<u32> {
    let mut input = BufReader::new(input);
    let mut magic = [0u8; 16];
    input.read_exact(&mut magic).map_err(|_| Error::BadBackup)?;
    if &magic != MAGIC {
        return Err(Error::BadBackup);
    }
    let mut count = 0u32;
    loop {
        let len = u16::from_be_bytes(read_n(&mut input)?) as usize;
        if len == 0 {
            let expected = u32::from_be_bytes(read_n(&mut input)?);
            return if expected == count {
                Ok(count)
            } else {
                Err(Error::BadBackup)
            };
        }
        let mut name = vec![0u8; len];
        input.read_exact(&mut name).map_err(|_| Error::BadBackup)?;
        let name = String::from_utf8(name).map_err(|_| Error::BadBackup)?;
        let rel = allowed(&name).ok_or(Error::BadBackup)?;
        let size = u64::from_be_bytes(read_n(&mut input)?);
        let path = dir.join(in_bucket(rel));
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut f = fs::File::create(&path)?;
        let copied = io::copy(&mut (&mut input).take(size), &mut f)?;
        if copied != size {
            return Err(Error::BadBackup);
        }
        f.sync_all()?;
        count += 1;
    }
}

fn read_n<const N: usize, R: Read>(r: &mut R) -> Result<[u8; N]> {
    let mut b = [0u8; N];
    r.read_exact(&mut b).map_err(|_| Error::BadBackup)?;
    Ok(b)
}

/// Where an item file of a backup goes: into its bucket.
fn in_bucket(rel: PathBuf) -> PathBuf {
    let bucket = rel
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(|n| n.split_once('.'))
        .and_then(|(item, _)| crate::bucket_of(item))
        .map(str::to_owned);
    match (bucket, rel.parent(), rel.file_name()) {
        (Some(b), Some(dir), Some(name)) if dir.ends_with(ITEMS_DIR) => dir.join(b).join(name),
        _ => rel,
    }
}

/// The library files a backup carries: its name for each (relative to `dir`, item
/// files as if flat in `items/`) and where it is, in a stable order.
fn files(dir: &Path) -> Result<Vec<(String, PathBuf)>> {
    let mut out = vec![(LIBRARY_FILE.to_owned(), dir.join(LIBRARY_FILE))];
    let mut vaults: Vec<_> = match fs::read_dir(dir.join(VAULTS_DIR)) {
        Ok(d) => d
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect(),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(e.into()),
    };
    vaults.sort();
    for v in vaults {
        if !is_hex_id(&v) || !dir.join(VAULTS_DIR).join(&v).join(HEADER_FILE).is_file() {
            continue;
        }
        // A vault without a password opens only on this device (PIN, biometrics); in a
        // backup it could never be opened, so it stays out.
        if !crate::read_header(&dir.join(VAULTS_DIR).join(&v)).is_some_and(|h| h.has_password()) {
            continue;
        }
        let header = format!("{VAULTS_DIR}/{v}/{HEADER_FILE}");
        out.push((header.clone(), dir.join(header)));
        let items = dir.join(VAULTS_DIR).join(&v).join(ITEMS_DIR);
        // Flat (a move into buckets cut short) first; a file in its bucket wins.
        let mut names = std::collections::BTreeMap::new();
        let mut buckets = Vec::new();
        for e in fs::read_dir(&items).into_iter().flatten().flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if crate::items::is_bucket(&n) && e.path().is_dir() {
                buckets.push(e.path());
            } else {
                names.insert(n, e.path());
            }
        }
        for b in buckets {
            for e in fs::read_dir(&b).into_iter().flatten().flatten() {
                names.insert(e.file_name().to_string_lossy().into_owned(), e.path());
            }
        }
        // Only live items: the content of one held from another device's deletion (no
        // `.meta`, only `.held`) stays out, as does the held record itself.
        let live: std::collections::HashSet<String> = names
            .keys()
            .filter_map(|n| n.strip_suffix(".meta").map(str::to_owned))
            .collect();
        for (n, path) in names {
            if n.split_once('.').is_some_and(|(id, _)| !live.contains(id)) {
                continue;
            }
            let rel = format!("{VAULTS_DIR}/{v}/{ITEMS_DIR}/{n}");
            if allowed(&rel).is_some() && path.is_file() {
                out.push((rel, path));
            }
        }
    }
    Ok(out)
}

/// Only the exact shapes a library has; anything else (`..`, absolute paths, device
/// files, temp files) is refused, so a crafted backup cannot write outside `dir`.
fn allowed(name: &str) -> Option<PathBuf> {
    let parts: Vec<&str> = name.split('/').collect();
    let ok = match parts.as_slice() {
        [f] => *f == LIBRARY_FILE,
        [v, id, f] => *v == VAULTS_DIR && is_hex_id(id) && *f == HEADER_FILE,
        [v, id, i, f] => {
            *v == VAULTS_DIR
                && is_hex_id(id)
                && *i == ITEMS_DIR
                && f.split_once('.')
                    .is_some_and(|(item, ext)| is_hex_id(item) && ITEM_EXTS.contains(&ext))
        }
        _ => false,
    };
    ok.then(|| parts.iter().collect())
}

fn is_hex_id(s: &str) -> bool {
    s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::items::NewItem;
    use crate::tests::sk;
    use crate::{Library, OpenVault};
    use cs_crypto::kdf::KdfParams;

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    /// A vault password, random each run: none is written in the code.
    fn pw() -> &'static str {
        static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        P.get_or_init(|| cs_core::hex::encode(cs_crypto::generate_salt()))
    }

    #[test]
    fn backup_restores_on_a_fresh_install() {
        let a = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(a.path(), FAST, sk())
            .unwrap()
            .create_vault("A", pw())
            .unwrap();
        let big = vec![9u8; 300_000];
        let item = v
            .add_item(NewItem {
                kind: "photo",
                name: "x.jpg",
                mime: "image/jpeg",
                created_ms: 1,
                content: &big[..],
                thumbnail: Some(b"t"),
            })
            .unwrap();
        v.enable_biometric().unwrap(); // device-only: must not travel

        let mut file = Vec::new();
        let n = export(a.path(), &mut file).unwrap();
        assert_eq!(n, 5); // library.json, header, meta, data, thumb

        let b = tempfile::tempdir().unwrap();
        let target = b.path().join("library");
        import(&file[..], &target).unwrap();
        assert!(!Library::has_biometric(&target));
        let v2 = Library::open_or_create(&target, FAST, sk())
            .unwrap()
            .unlock(pw())
            .unwrap()
            .unwrap();
        let mut out = Vec::new();
        v2.read_item(&item.id, &mut out).unwrap();
        assert_eq!(out, big);
        // Restoring over an existing library is refused.
        assert!(matches!(
            import(&file[..], &target),
            Err(Error::LibraryExists)
        ));
    }

    #[test]
    fn damaged_or_crafted_backups_leave_nothing() {
        let a = tempfile::tempdir().unwrap();
        Library::open_or_create(a.path(), FAST, sk())
            .unwrap()
            .create_vault("A", pw())
            .unwrap();
        let mut file = Vec::new();
        export(a.path(), &mut file).unwrap();

        let b = tempfile::tempdir().unwrap();
        let target = b.path().join("library");
        // Truncated.
        assert!(import(&file[..file.len() - 10], &target).is_err());
        assert!(!target.exists() && !staging_dir(&target).exists());
        // Not a backup.
        assert!(matches!(
            import(&b"hello"[..], &target),
            Err(Error::BadBackup)
        ));

        // A path that tries to escape.
        let mut evil = MAGIC.to_vec();
        let name = b"../../evil";
        evil.extend((name.len() as u16).to_be_bytes());
        evil.extend(name);
        evil.extend(1u64.to_be_bytes());
        evil.push(b'x');
        evil.extend(0u16.to_be_bytes());
        evil.extend(1u32.to_be_bytes());
        assert!(matches!(import(&evil[..], &target), Err(Error::BadBackup)));
        assert!(!b.path().join("evil").exists() && !target.exists());
    }

    /// Lower `library.json`'s Argon2 memory under the floor, as a tampered copy would.
    pub(crate) fn weaken(dir: &Path) {
        let path = dir.join(LIBRARY_FILE);
        let mut v: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        v["kdf"]["m_kib"] = serde_json::json!(KdfParams::ACCEPTED_FLOOR.m_kib / 2);
        fs::write(path, serde_json::to_vec(&v).unwrap()).unwrap();
    }

    #[test]
    fn a_backup_with_a_lowered_argon2_cost_is_refused() {
        let a = tempfile::tempdir().unwrap();
        Library::open_or_create(a.path(), FAST, sk())
            .unwrap()
            .create_vault("A", pw())
            .unwrap();
        weaken(a.path());
        let mut file = Vec::new();
        export(a.path(), &mut file).unwrap();
        let b = tempfile::tempdir().unwrap();
        let target = b.path().join("library");
        assert!(matches!(
            import(&file[..], &target),
            Err(Error::Crypto(cs_crypto::Error::KdfTooWeak))
        ));
        assert!(!target.exists() && !staging_dir(&target).exists());
    }

    fn note(v: &OpenVault, name: &str, text: &str) -> String {
        v.add_item(NewItem {
            kind: crate::items::kind::NOTE,
            name,
            mime: "text/plain",
            created_ms: 1,
            content: text.as_bytes(),
            thumbnail: None,
        })
        .unwrap()
        .id
    }

    fn walk(dir: &Path) -> Vec<std::path::PathBuf> {
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

    #[test]
    fn history_is_not_in_backups() {
        let d = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(d.path(), FAST, sk())
            .unwrap()
            .create_vault("A", pw())
            .unwrap();
        let id = note(&v, "A", "one");
        v.replace_item(&id, "A", &b"two"[..]).unwrap();
        assert!(v.history_bytes().unwrap() > 0);
        let mut out = Vec::new();
        export(d.path(), &mut out).unwrap();
        let fresh = tempfile::tempdir().unwrap();
        import(&out[..], fresh.path()).unwrap();
        let has_history = walk(fresh.path()).iter().any(|p| {
            p.components()
                .any(|c| c.as_os_str() == crate::history::HISTORY_DIR)
        });
        assert!(!has_history);
    }

    #[test]
    fn a_vault_with_only_a_pin_is_left_out() {
        let tmp = tempfile::tempdir().unwrap();
        let device = cs_crypto::SecretKey::from_bytes([3; cs_crypto::SECRET_KEY_LEN]);
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        l.create_vault_with_pin("lock", "blue", "135790", &device, FAST)
            .unwrap();
        let mut out = Vec::new();
        assert_eq!(export(tmp.path(), &mut out).unwrap(), 1); // library.json only
    }

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

    #[test]
    fn a_backup_of_files_half_moved_into_buckets_restores_into_buckets() {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let v = lib.create_vault("A", pw()).unwrap();
        let items: Vec<_> = (0..3)
            .map(|i| {
                v.add_item(NewItem {
                    kind: "photo",
                    name: "IMG.jpg",
                    mime: "image/jpeg",
                    created_ms: i,
                    content: format!("photo {i}").as_bytes(),
                    thumbnail: Some(b"thumb"),
                })
                .unwrap()
            })
            .collect();
        // Half the files back where 0.1.57 kept them, flat in items/.
        let all = files_of(&v);
        for (b, f) in all.iter().take(all.len() / 2) {
            fs::rename(v.items_dir().join(b).join(f), v.items_dir().join(f)).unwrap();
        }
        v.index().meta_set(crate::items::BUCKETS_DONE, "0").unwrap();
        // A backup made now has every file once.
        let mut backup = Vec::new();
        assert_eq!(export(tmp.path(), &mut backup).unwrap(), 2 + 3 * 3);
        drop(v);
        let done = files_of(&lib.unlock(pw()).unwrap().unwrap());
        // It restores into buckets.
        let other = tempfile::tempdir().unwrap();
        let target = other.path().join("library");
        import(&backup[..], &target).unwrap();
        let w = Library::open_or_create(&target, FAST, sk())
            .unwrap()
            .unlock(pw())
            .unwrap()
            .unwrap();
        assert_eq!(files_of(&w), done);
        let mut out = Vec::new();
        w.read_item(&items[2].id, &mut out).unwrap();
        assert_eq!(out, b"photo 2");
    }
}
