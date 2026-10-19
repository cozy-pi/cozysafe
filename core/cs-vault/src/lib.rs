//! Library and vault storage.
//!
//! On disk (all under one library directory):
//!
//! ```text
//! library.json            format, Argon2id parameters, library salt (not secret)
//! secret-key              the 128-bit Secret Key            ← M0 only, see below
//! vaults/<id>/header.json vault salt, wrapped Master Key, sealed metadata (name)
//! vaults/<id>/items/      one encrypted object per item, see [`items`]
//! ```
//!
//! Unlocking derives the root key once and then tries every vault header; the
//! password alone decides which vault opens, and nothing on disk names a vault in
//! the clear.
//!
//! **M0 limitation:** the Secret Key sits in a file readable only by the app. It moves
//! to the platform keystore (Keychain / Android Keystore / DPAPI / libsecret) with
//! key sync and the Emergency Kit; see `docs/adr/0001-encryption.md`.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use cs_crypto::kdf::{self, KdfParams};
use cs_crypto::{wrap, Key, SecretKey, SALT_LEN, SECRET_KEY_LEN};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub mod items;
pub use items::ItemMeta;

const FORMAT: u32 = 1;
const LIBRARY_FILE: &str = "library.json";
const SECRET_KEY_FILE: &str = "secret-key";
const VAULTS_DIR: &str = "vaults";
const HEADER_FILE: &str = "header.json";
/// Master Key wrapped by a key that lives in the platform keystore behind biometrics.
const BIOMETRIC_FILE: &str = "biometric";

/// Minimum zxcvbn score (0–4) for a vault password.
pub const MIN_PASSWORD_SCORE: u8 = 3;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("password too weak")]
    WeakPassword,
    #[error("another vault already uses this password")]
    PasswordInUse,
    #[error("vault name is empty")]
    EmptyName,
    #[error("no such item")]
    NoSuchItem,
    #[error("library data is damaged: {0}")]
    Corrupt(&'static str),
    #[error(transparent)]
    Crypto(#[from] cs_crypto::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

/// Strength of a candidate password, 0 (trivial) to 4 (very strong).
pub fn password_score(password: &str) -> u8 {
    u8::from(zxcvbn::zxcvbn(password, &[]).score())
}

#[derive(Serialize, Deserialize)]
struct LibraryHeader {
    format: u32,
    kdf: KdfJson,
    salt: String,
}

#[derive(Serialize, Deserialize, Clone, Copy)]
struct KdfJson {
    m_kib: u32,
    t: u32,
    p: u32,
}

#[derive(Serialize, Deserialize)]
struct VaultHeader {
    format: u32,
    salt: String,
    wrapped_master_key: String,
    meta: String,
}

#[derive(Serialize, Deserialize)]
struct VaultMeta {
    name: String,
}

/// The set of vaults in one directory, sharing a library salt and Secret Key.
pub struct Library {
    dir: PathBuf,
    params: KdfParams,
    salt: [u8; SALT_LEN],
    secret_key: SecretKey,
}

/// An unlocked vault. Holds the Master Key until dropped (wiped on drop).
pub struct OpenVault {
    pub id: String,
    pub name: String,
    dir: PathBuf,
    master_key: Key,
}

impl Library {
    /// Whether a library with at least one vault exists in `dir`.
    pub fn has_vaults(dir: &Path) -> bool {
        fs::read_dir(dir.join(VAULTS_DIR))
            .map(|mut it| {
                it.any(|e| {
                    e.map(|e| e.path().join(HEADER_FILE).is_file())
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false)
    }

    /// Open the library in `dir`, creating it (salt, Secret Key) with `params_if_new` if absent.
    pub fn open_or_create(dir: &Path, params_if_new: KdfParams) -> Result<Library> {
        let header_path = dir.join(LIBRARY_FILE);
        if !header_path.exists() {
            fs::create_dir_all(dir.join(VAULTS_DIR))?;
            let salt = cs_crypto::generate_salt();
            let secret_key = SecretKey::generate();
            write_private(&dir.join(SECRET_KEY_FILE), secret_key.as_bytes())?;
            let header = LibraryHeader {
                format: FORMAT,
                kdf: KdfJson {
                    m_kib: params_if_new.m_kib,
                    t: params_if_new.t,
                    p: params_if_new.p,
                },
                salt: hex::encode(salt),
            };
            write_atomic(
                &header_path,
                &serde_json::to_vec_pretty(&header).expect("serialisable"),
            )?;
        }

        let header: LibraryHeader = serde_json::from_slice(&fs::read(&header_path)?)
            .map_err(|_| Error::Corrupt("library.json"))?;
        if header.format != FORMAT {
            return Err(Error::Corrupt("unsupported library format"));
        }
        let salt = decode_array::<SALT_LEN>(&header.salt, "library salt")?;
        let sk_bytes = Zeroizing::new(fs::read(dir.join(SECRET_KEY_FILE))?);
        let sk: [u8; SECRET_KEY_LEN] = sk_bytes
            .as_slice()
            .try_into()
            .map_err(|_| Error::Corrupt("secret key length"))?;
        Ok(Library {
            dir: dir.to_path_buf(),
            params: KdfParams {
                m_kib: header.kdf.m_kib,
                t: header.kdf.t,
                p: header.kdf.p,
            },
            salt,
            secret_key: SecretKey::from_bytes(sk),
        })
    }

    /// Create a vault. Refuses weak passwords and passwords another vault already opens with.
    pub fn create_vault(&self, name: &str, password: &str) -> Result<OpenVault> {
        let name = name.trim();
        if name.is_empty() {
            return Err(Error::EmptyName);
        }
        if password_score(password) < MIN_PASSWORD_SCORE {
            return Err(Error::WeakPassword);
        }
        let root = kdf::derive_root(
            password.as_bytes(),
            &self.secret_key,
            &self.salt,
            self.params,
        )?;
        if self.find_vault(&root)?.is_some() {
            return Err(Error::PasswordInUse);
        }

        let id = hex::encode(cs_crypto::generate_salt());
        let vault_salt = cs_crypto::generate_salt();
        let kek = kdf::vault_kek(&root, &vault_salt);
        let master_key = Key::generate();
        let meta = serde_json::to_vec(&VaultMeta {
            name: name.to_owned(),
        })
        .expect("serialisable");
        let header = VaultHeader {
            format: FORMAT,
            salt: hex::encode(vault_salt),
            wrapped_master_key: hex::encode(wrap::wrap_key(
                &kek,
                &master_key,
                &aad(&id, "master-key"),
            )),
            meta: hex::encode(wrap::seal(&master_key, &meta, &aad(&id, "meta"))),
        };
        let vault_dir = self.dir.join(VAULTS_DIR).join(&id);
        fs::create_dir_all(&vault_dir)?;
        write_atomic(
            &vault_dir.join(HEADER_FILE),
            &serde_json::to_vec_pretty(&header).expect("serialisable"),
        )?;
        Ok(OpenVault {
            id,
            name: name.to_owned(),
            dir: vault_dir,
            master_key,
        })
    }

    /// Open whichever vault this password belongs to, or `None`.
    pub fn unlock(&self, password: &str) -> Result<Option<OpenVault>> {
        let root = kdf::derive_root(
            password.as_bytes(),
            &self.secret_key,
            &self.salt,
            self.params,
        )?;
        self.find_vault(&root)
    }

    fn find_vault(&self, root: &Key) -> Result<Option<OpenVault>> {
        let dir = match fs::read_dir(self.dir.join(VAULTS_DIR)) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        for entry in dir {
            let entry = entry?;
            let id = entry.file_name().to_string_lossy().into_owned();
            // A damaged header must not stop the other vaults from opening.
            let Some(header) = read_header(&entry.path()) else {
                continue;
            };
            let (Ok(salt), Ok(wrapped)) = (
                decode_array::<SALT_LEN>(&header.salt, "vault salt"),
                hex::decode(&header.wrapped_master_key),
            ) else {
                continue;
            };
            let kek = kdf::vault_kek(root, &salt);
            let Ok(master_key) = wrap::unwrap_key(&kek, &wrapped, &aad(&id, "master-key")) else {
                continue;
            };
            return open_with(id, entry.path(), &header, master_key).map(Some);
        }
        Ok(None)
    }

    /// Whether some vault in `dir` can be opened with biometrics on this device.
    pub fn has_biometric(dir: &Path) -> bool {
        fs::read_dir(dir.join(VAULTS_DIR))
            .map(|mut it| {
                it.any(|e| {
                    e.map(|e| e.path().join(BIOMETRIC_FILE).is_file())
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false)
    }

    /// Drop every biometric copy, e.g. after the keystore invalidated its key because
    /// the enrolled fingerprints or face changed.
    pub fn forget_biometric(dir: &Path) -> Result<()> {
        if let Ok(entries) = fs::read_dir(dir.join(VAULTS_DIR)) {
            for entry in entries.flatten() {
                remove_if_exists(&entry.path().join(BIOMETRIC_FILE))?;
            }
        }
        Ok(())
    }

    /// Open the vault whose biometric copy `key` unwraps. Needs neither the password nor
    /// the Secret Key: `key` comes out of the platform keystore only after a biometric check.
    pub fn unlock_biometric(dir: &Path, key: &Key) -> Result<Option<OpenVault>> {
        let entries = match fs::read_dir(dir.join(VAULTS_DIR)) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        for entry in entries {
            let path = entry?.path();
            let Ok(wrapped) = fs::read_to_string(path.join(BIOMETRIC_FILE)) else {
                continue;
            };
            let (Some(header), Some(id)) = (read_header(&path), path.file_name()) else {
                continue;
            };
            let id = id.to_string_lossy().into_owned();
            let Ok(wrapped) = hex::decode(wrapped.trim()) else {
                continue;
            };
            let Ok(master_key) = wrap::unwrap_key(key, &wrapped, &aad(&id, "biometric")) else {
                continue;
            };
            return open_with(id, path, &header, master_key).map(Some);
        }
        Ok(None)
    }
}

impl OpenVault {
    /// Turn on biometric unlock for this vault and off for every other one (one per
    /// device). Returns the key the caller must put in the biometric-gated keystore.
    pub fn enable_biometric(&self) -> Result<Key> {
        if let Some(vaults) = self.dir.parent() {
            for entry in fs::read_dir(vaults)?.flatten() {
                if entry.path() != self.dir {
                    remove_if_exists(&entry.path().join(BIOMETRIC_FILE))?;
                }
            }
        }
        let key = Key::generate();
        let wrapped = wrap::wrap_key(&key, &self.master_key, &aad(&self.id, "biometric"));
        write_atomic(
            &self.dir.join(BIOMETRIC_FILE),
            hex::encode(wrapped).as_bytes(),
        )?;
        Ok(key)
    }

    pub fn disable_biometric(&self) -> Result<()> {
        remove_if_exists(&self.dir.join(BIOMETRIC_FILE))
    }

    pub fn biometric_enabled(&self) -> bool {
        self.dir.join(BIOMETRIC_FILE).is_file()
    }
}

fn read_header(vault_dir: &Path) -> Option<VaultHeader> {
    let bytes = fs::read(vault_dir.join(HEADER_FILE)).ok()?;
    let header: VaultHeader = serde_json::from_slice(&bytes).ok()?;
    (header.format == FORMAT).then_some(header)
}

fn open_with(id: String, dir: PathBuf, header: &VaultHeader, master_key: Key) -> Result<OpenVault> {
    let meta_bytes = hex::decode(&header.meta).map_err(|_| Error::Corrupt("vault meta"))?;
    let meta_json = wrap::open(&master_key, &meta_bytes, &aad(&id, "meta"))?;
    let meta: VaultMeta =
        serde_json::from_slice(&meta_json).map_err(|_| Error::Corrupt("vault meta"))?;
    Ok(OpenVault {
        id,
        name: meta.name,
        dir,
        master_key,
    })
}

fn remove_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
        _ => Ok(()),
    }
}

/// Associated data binding a sealed value to its vault and role.
pub(crate) fn aad(vault_id: &str, role: &str) -> Vec<u8> {
    format!("cozysafe/v1/vault/{vault_id}/{role}").into_bytes()
}

fn decode_array<const N: usize>(s: &str, what: &'static str) -> Result<[u8; N]> {
    hex::decode(s)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or(Error::Corrupt(what))
}

/// Write via a temporary file and rename, so a crash never leaves a half-written header.
pub(crate) fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

fn write_private(path: &Path, data: &[u8]) -> Result<()> {
    let mut opts = fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(path)?;
    f.write_all(data)?;
    f.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    const PW_A: &str = "mây tháng mười rơi trên phố cổ";
    const PW_B: &str = "orange kettle whispers at dawn 77";

    fn lib(dir: &Path) -> Library {
        Library::open_or_create(dir, FAST).unwrap()
    }

    #[test]
    fn create_then_unlock() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(!Library::has_vaults(tmp.path()));
        let v = lib(tmp.path()).create_vault("Cá nhân", PW_A).unwrap();
        assert!(Library::has_vaults(tmp.path()));

        // A fresh Library instance, as after an app restart.
        let opened = lib(tmp.path()).unlock(PW_A).unwrap().expect("vault opens");
        assert_eq!(opened.id, v.id);
        assert_eq!(opened.name, "Cá nhân");
        assert!(lib(tmp.path())
            .unlock("wrong password entirely 123")
            .unwrap()
            .is_none());
    }

    #[test]
    fn password_picks_the_vault() {
        let tmp = tempfile::tempdir().unwrap();
        let l = lib(tmp.path());
        let a = l.create_vault("A", PW_A).unwrap();
        let b = l.create_vault("B", PW_B).unwrap();
        assert_eq!(l.unlock(PW_A).unwrap().unwrap().id, a.id);
        assert_eq!(l.unlock(PW_B).unwrap().unwrap().id, b.id);
    }

    #[test]
    fn biometric_copy_opens_only_its_vault_and_moves_on_enable() {
        let tmp = tempfile::tempdir().unwrap();
        let l = lib(tmp.path());
        let a = l.create_vault("A", PW_A).unwrap();
        let b = l.create_vault("B", PW_B).unwrap();
        assert!(!Library::has_biometric(tmp.path()));

        let ka = a.enable_biometric().unwrap();
        assert!(Library::has_biometric(tmp.path()));
        let opened = Library::unlock_biometric(tmp.path(), &ka).unwrap().unwrap();
        assert_eq!(
            (opened.id.as_str(), opened.name.as_str()),
            (a.id.as_str(), "A")
        );
        assert!(Library::unlock_biometric(tmp.path(), &Key::generate())
            .unwrap()
            .is_none());

        // Enabling on B turns A off: A's key no longer opens anything.
        let kb = b.enable_biometric().unwrap();
        assert!(!a.biometric_enabled());
        assert!(Library::unlock_biometric(tmp.path(), &ka)
            .unwrap()
            .is_none());
        assert_eq!(
            Library::unlock_biometric(tmp.path(), &kb)
                .unwrap()
                .unwrap()
                .id,
            b.id
        );

        Library::forget_biometric(tmp.path()).unwrap();
        assert!(!Library::has_biometric(tmp.path()));
        let kb = b.enable_biometric().unwrap();
        b.disable_biometric().unwrap();
        assert!(!Library::has_biometric(tmp.path()));
        assert!(Library::unlock_biometric(tmp.path(), &kb)
            .unwrap()
            .is_none());
    }

    #[test]
    fn same_password_twice_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let l = lib(tmp.path());
        l.create_vault("A", PW_A).unwrap();
        assert!(matches!(
            l.create_vault("B", PW_A),
            Err(Error::PasswordInUse)
        ));
    }

    #[test]
    fn weak_password_and_empty_name_are_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let l = lib(tmp.path());
        assert!(matches!(
            l.create_vault("A", "password1"),
            Err(Error::WeakPassword)
        ));
        assert!(matches!(l.create_vault("  ", PW_A), Err(Error::EmptyName)));
        assert!(!Library::has_vaults(tmp.path()));
    }

    #[test]
    fn nothing_on_disk_names_the_vault() {
        let tmp = tempfile::tempdir().unwrap();
        let v = lib(tmp.path())
            .create_vault("Hồ sơ thuế bí mật", PW_A)
            .unwrap();
        let header =
            fs::read_to_string(tmp.path().join(VAULTS_DIR).join(&v.id).join(HEADER_FILE)).unwrap();
        assert!(!header.contains("thuế") && !header.contains("Hồ sơ"));
    }

    #[test]
    fn another_secret_key_cannot_open() {
        let tmp = tempfile::tempdir().unwrap();
        lib(tmp.path()).create_vault("A", PW_A).unwrap();
        fs::remove_file(tmp.path().join(SECRET_KEY_FILE)).unwrap();
        write_private(
            &tmp.path().join(SECRET_KEY_FILE),
            SecretKey::generate().as_bytes(),
        )
        .unwrap();
        assert!(lib(tmp.path()).unlock(PW_A).unwrap().is_none());
    }

    #[test]
    fn damaged_header_does_not_block_other_vaults() {
        let tmp = tempfile::tempdir().unwrap();
        let l = lib(tmp.path());
        let a = l.create_vault("A", PW_A).unwrap();
        l.create_vault("B", PW_B).unwrap();
        fs::write(
            tmp.path().join(VAULTS_DIR).join(&a.id).join(HEADER_FILE),
            b"{not json",
        )
        .unwrap();
        assert!(l.unlock(PW_A).unwrap().is_none());
        assert!(l.unlock(PW_B).unwrap().is_some());
    }

    #[test]
    fn scores() {
        assert!(password_score("password1") < MIN_PASSWORD_SCORE);
        assert!(password_score(PW_A) >= MIN_PASSWORD_SCORE);
        assert!(password_score(PW_B) >= MIN_PASSWORD_SCORE);
    }
}
