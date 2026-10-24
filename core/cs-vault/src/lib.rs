//! Library and vault storage.
//!
//! On disk (all under one library directory):
//!
//! ```text
//! library.json            format, Argon2id parameters, library salt, Secret Key
//!                         fingerprint (none of it secret)
//! vaults/<id>/header.json vault salt, wrapped Master Key, sealed metadata (name)
//! vaults/<id>/items/      one encrypted object per item, see [`items`]
//! vaults/<id>/vault.db    SQLite index of the items' sealed records, see [`db`]
//! ```
//!
//! Unlocking derives the root key once and then tries every vault header; the
//! password alone decides which vault opens, and nothing on disk names a vault in
//! the clear.
//!
//! The Secret Key is not stored here: the app keeps it in the platform keystore and
//! passes it in (`docs/adr/0001-encryption.md`). Libraries from the first previews kept
//! it in a `secret-key` file; [`Library::legacy_secret_key`] reads that once for the
//! move, [`Library::forget_legacy_secret_key`] wipes it afterwards.

// No unsafe Rust in the core: the compiler refuses it (docs/supply-chain.md).
#![forbid(unsafe_code)]

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use cs_crypto::kdf::{self, KdfParams};
use cs_crypto::{wrap, Key, SecretKey, SALT_LEN, SECRET_KEY_LEN};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub mod backup;
pub mod db;
pub mod items;
pub mod passphrase;
pub mod pin;
pub mod sync;
pub use items::ItemMeta;

const FORMAT: u32 = 1;
pub(crate) const LIBRARY_FILE: &str = "library.json";
const SECRET_KEY_FILE: &str = "secret-key";
pub(crate) const VAULTS_DIR: &str = "vaults";
pub(crate) const HEADER_FILE: &str = "header.json";
/// Master Key wrapped by a key that lives in the platform keystore behind biometrics.
const BIOMETRIC_FILE: &str = "biometric";

/// zxcvbn score (0–4) from which the app calls a password strong. Shown, never enforced
/// (owner 2026-10-23): a backup also needs the 24 words.
pub const MIN_PASSWORD_SCORE: u8 = 3;
/// The only rule a vault password has: at least this many characters.
pub const MIN_PASSWORD_LEN: usize = 8;

fn long_enough(password: &str) -> bool {
    password.chars().count() >= MIN_PASSWORD_LEN
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("password too short")]
    WeakPassword,
    #[error("another vault already uses this password")]
    PasswordInUse,
    #[error("vault name is empty")]
    EmptyName,
    #[error("a PIN has at least 4 digits")]
    BadPin,
    #[error("another vault already opens with this PIN")]
    PinInUse,
    #[error("no such item")]
    NoSuchItem,
    #[error("this Secret Key belongs to another library")]
    WrongSecretKey,
    #[error("not a Cozy Safe backup, or the file is damaged")]
    BadBackup,
    #[error("a library already exists here")]
    LibraryExists,
    #[error("library data is damaged: {0}")]
    Corrupt(&'static str),
    #[error("vault index: {0}")]
    Index(String),
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
    /// [`SecretKey::fingerprint`]; absent in libraries from the first previews.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    secret_key: Option<String>,
    /// During a Secret Key change ([`Library::change_secret_key`]): the old key's
    /// fingerprint, still accepted until the device holds the new key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    prev_secret_key: Option<String>,
}

/// Argon2id cost, named as in RFC 9106: memory in KiB, passes (t), lanes (p).
#[derive(Serialize, Deserialize, Clone, Copy)]
pub(crate) struct KdfJson {
    pub(crate) m_kib: u32,
    pub(crate) t: u32,
    pub(crate) p: u32,
}

impl From<KdfParams> for KdfJson {
    fn from(k: KdfParams) -> Self {
        Self {
            m_kib: k.m_kib,
            t: k.t,
            p: k.p,
        }
    }
}

impl From<KdfJson> for KdfParams {
    fn from(k: KdfJson) -> Self {
        Self {
            m_kib: k.m_kib,
            t: k.t,
            p: k.p,
        }
    }
}

#[derive(Serialize, Deserialize)]
pub(crate) struct VaultHeader {
    format: u32,
    salt: String,
    /// Master Key wrapped by the password path. Empty until a password is set: a vault
    /// can start with only a PIN and biometrics on this device (docs/ui.md, first run).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    wrapped_master_key: String,
    /// During a Secret Key change: the Master Key wrapped with the password and the old
    /// key, dropped once the device holds the new one.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    prev_wrapped_master_key: String,
    meta: String,
}

impl VaultHeader {
    pub(crate) fn has_password(&self) -> bool {
        !self.wrapped_master_key.is_empty()
    }
}

/// Sealed with the Master Key: nothing on disk says what a vault is.
#[derive(Serialize, Deserialize, Default)]
struct VaultMeta {
    #[serde(default)]
    name: String,
    /// Vaults are told apart by an icon and a colour, chosen from the app's sets.
    #[serde(default)]
    icon: String,
    #[serde(default)]
    color: String,
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
    pub icon: String,
    pub color: String,
    dir: PathBuf,
    master_key: Key,
    index: db::Index,
}

impl OpenVault {
    /// The key a nearby-device session is built on (docs/adr/0003, P2P security): only a
    /// device holding this vault can derive it.
    pub fn p2p_key(&self) -> Key {
        cs_crypto::kdf::subkey(&self.master_key, &format!("p2p/v1/{}", self.id))
    }

    /// Forget what was agreed with a sync place that starts empty again.
    pub fn forget_sync_place(&self, key: &str) -> Result<()> {
        self.index.forget_remote(key)
    }

    /// The connections this vault made, newest first (Settings → Sync shows them). Sealed
    /// with the Master Key like everything else in the index.
    pub fn connection_log(&self) -> Result<Vec<String>> {
        let Some(sealed) = self.index.meta_get(CONNECTION_LOG)? else {
            return Ok(Vec::new());
        };
        let bytes = hex::decode(sealed).map_err(|_| Error::Corrupt("connection log"))?;
        let plain = cs_crypto::wrap::open(&self.master_key, &bytes, CONNECTION_LOG.as_bytes())
            .map_err(|_| Error::Corrupt("connection log"))?;
        serde_json::from_slice(&plain).map_err(|_| Error::Corrupt("connection log"))
    }

    /// Add one line to [`OpenVault::connection_log`], keeping the newest
    /// [`CONNECTION_LOG_LEN`].
    pub fn log_connection(&self, line: &str) -> Result<()> {
        let mut log = self.connection_log().unwrap_or_default();
        log.insert(0, line.to_owned());
        log.truncate(CONNECTION_LOG_LEN);
        let plain = serde_json::to_vec(&log).expect("serialisable");
        let sealed = cs_crypto::wrap::seal(&self.master_key, &plain, CONNECTION_LOG.as_bytes());
        self.index.meta_set(CONNECTION_LOG, &hex::encode(sealed))
    }
}

const CONNECTION_LOG: &str = "connection-log";
/// Lines kept in the connection log.
pub const CONNECTION_LOG_LEN: usize = 50;

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

    /// With no vault left in `dir`, forget the library's salt and Secret Key fingerprint,
    /// so the next vault can start it with a new Secret Key (a device whose last vault was
    /// deleted, holding a 128-bit key from before the 24 words). Refuses, returning
    /// false, while any vault is there.
    pub fn reset_if_empty(dir: &Path) -> Result<bool> {
        if Library::has_vaults(dir) {
            return Ok(false);
        }
        match fs::remove_file(dir.join(LIBRARY_FILE)) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(true),
            Err(e) => Err(e.into()),
        }
    }

    /// Open the library in `dir` with the app's Secret Key, creating the library (salt,
    /// fingerprint) with `params_if_new` if absent. A Secret Key from another library is
    /// refused with [`Error::WrongSecretKey`] instead of failing every password.
    pub fn open_or_create(
        dir: &Path,
        params_if_new: KdfParams,
        secret_key: SecretKey,
    ) -> Result<Library> {
        let header_path = dir.join(LIBRARY_FILE);
        if !header_path.exists() {
            fs::create_dir_all(dir.join(VAULTS_DIR))?;
            let header = LibraryHeader {
                format: FORMAT,
                kdf: KdfJson {
                    m_kib: params_if_new.m_kib,
                    t: params_if_new.t,
                    p: params_if_new.p,
                },
                salt: hex::encode(cs_crypto::generate_salt()),
                secret_key: Some(secret_key.fingerprint()),
                prev_secret_key: None,
            };
            write_atomic(
                &header_path,
                &serde_json::to_vec_pretty(&header).expect("serialisable"),
            )?;
        }

        let mut header = read_library_header(dir)?;
        let fp = secret_key.fingerprint();
        match &header.secret_key {
            // The new key of a change that has reached the device: the old one goes.
            Some(f) if *f == fp && header.prev_secret_key.is_some() => {
                finish_key_change(dir, &mut header)?;
            }
            // The old key of a change the device has not taken up yet: still fine.
            Some(_) if header.prev_secret_key.as_deref() == Some(fp.as_str()) => {}
            Some(f) if *f != fp => return Err(Error::WrongSecretKey),
            Some(_) => {}
            None => {
                // Older library: record the fingerprint now.
                header.secret_key = Some(secret_key.fingerprint());
                write_atomic(
                    &header_path,
                    &serde_json::to_vec_pretty(&header).expect("serialisable"),
                )?;
            }
        }
        let salt = decode_array::<SALT_LEN>(&header.salt, "library salt")?;
        Ok(Library {
            dir: dir.to_path_buf(),
            params: KdfParams {
                m_kib: header.kdf.m_kib,
                t: header.kdf.t,
                p: header.kdf.p,
            },
            salt,
            secret_key,
        })
    }

    /// Whether `secret_key` belongs to the library in `dir` (true when the library
    /// predates fingerprints and cannot tell).
    pub fn secret_key_fits(dir: &Path, secret_key: &SecretKey) -> bool {
        match read_library_header(dir) {
            Ok(h) => h.secret_key.is_none_or(|f| f == secret_key.fingerprint()),
            Err(_) => false,
        }
    }

    /// The Secret Key from a first-preview `secret-key` file, if there is one.
    pub fn legacy_secret_key(dir: &Path) -> Result<Option<SecretKey>> {
        let bytes = match fs::read(dir.join(SECRET_KEY_FILE)) {
            Ok(b) => Zeroizing::new(b),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        Ok(Some(
            SecretKey::from_slice(&bytes).ok_or(Error::Corrupt("secret key length"))?,
        ))
    }

    /// Overwrite and delete the `secret-key` file once the key is in the keystore.
    pub fn forget_legacy_secret_key(dir: &Path) -> Result<()> {
        let path = dir.join(SECRET_KEY_FILE);
        if path.exists() {
            let mut f = fs::OpenOptions::new().write(true).open(&path)?;
            f.write_all(&[0u8; SECRET_KEY_LEN])?; // at least as long as the file
            f.sync_all()?;
            drop(f);
            fs::remove_file(path)?;
        }
        Ok(())
    }

    /// Create a vault. Refuses passwords under 8 characters and passwords another vault already opens with.
    pub fn create_vault(&self, name: &str, password: &str) -> Result<OpenVault> {
        let name = name.trim();
        if name.is_empty() {
            return Err(Error::EmptyName);
        }
        if !long_enough(password) {
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
            ..Default::default()
        })
        .expect("serialisable");
        let header = VaultHeader {
            format: FORMAT,
            prev_wrapped_master_key: String::new(),
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
        let index = db::Index::open(&vault_dir)?;
        Ok(OpenVault {
            id,
            name: name.to_owned(),
            icon: String::new(),
            color: String::new(),
            dir: vault_dir,
            master_key,
            index,
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
            if !header.has_password() {
                continue;
            }
            let Ok(salt) = decode_array::<SALT_LEN>(&header.salt, "vault salt") else {
                continue;
            };
            let kek = kdf::vault_kek(root, &salt);
            // The current wrap, or the old one while a Secret Key change is under way.
            let opened = [&header.wrapped_master_key, &header.prev_wrapped_master_key]
                .into_iter()
                .filter(|w| !w.is_empty())
                .filter_map(|w| hex::decode(w).ok())
                .find_map(|w| wrap::unwrap_key(&kek, &w, &aad(&id, "master-key")).ok());
            let Some(master_key) = opened else {
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

impl Library {
    /// Create a vault that starts with only a PIN on this device (no password yet).
    /// The PIN must not open another vault here: a PIN picks its vault.
    pub fn create_vault_with_pin(
        &self,
        icon: &str,
        color: &str,
        pin: &str,
        device_key: &SecretKey,
        pin_params: KdfParams,
    ) -> Result<OpenVault> {
        if Library::pin_owner(&self.dir, pin, device_key)?.is_some() {
            return Err(Error::PinInUse);
        }
        let id = hex::encode(cs_crypto::generate_salt());
        let master_key = Key::generate();
        let meta = VaultMeta {
            icon: icon.to_owned(),
            color: color.to_owned(),
            ..Default::default()
        };
        let header = VaultHeader {
            format: FORMAT,
            prev_wrapped_master_key: String::new(),
            salt: hex::encode(cs_crypto::generate_salt()),
            wrapped_master_key: String::new(),
            meta: hex::encode(wrap::seal(
                &master_key,
                &serde_json::to_vec(&meta).expect("serialisable"),
                &aad(&id, "meta"),
            )),
        };
        let vault_dir = self.dir.join(VAULTS_DIR).join(&id);
        fs::create_dir_all(&vault_dir)?;
        write_atomic(
            &vault_dir.join(HEADER_FILE),
            &serde_json::to_vec_pretty(&header).expect("serialisable"),
        )?;
        let index = db::Index::open(&vault_dir)?;
        let vault = OpenVault {
            id,
            name: String::new(),
            icon: meta.icon,
            color: meta.color,
            dir: vault_dir,
            master_key,
            index,
        };
        if let Err(e) = vault.enable_pin(pin, device_key, pin_params) {
            let _ = fs::remove_dir_all(&vault.dir);
            return Err(e);
        }
        Ok(vault)
    }

    /// Whether any vault here can be opened with a password (shows "Use password").
    pub fn any_password(dir: &Path) -> bool {
        fs::read_dir(dir.join(VAULTS_DIR))
            .map(|it| {
                it.flatten()
                    .any(|e| read_header(&e.path()).is_some_and(|h| h.has_password()))
            })
            .unwrap_or(false)
    }

    /// Set or change this vault's password: re-wraps the Master Key, nothing else is
    /// re-encrypted, so it is instant whatever the vault's size. A password that already
    /// opens another vault is refused (the password picks the vault).
    pub fn set_password(&self, vault: &OpenVault, password: &str) -> Result<()> {
        if !long_enough(password) {
            return Err(Error::WeakPassword);
        }
        let root = kdf::derive_root(
            password.as_bytes(),
            &self.secret_key,
            &self.salt,
            self.params,
        )?;
        if let Some(other) = self.find_vault(&root)? {
            if other.id != vault.id {
                return Err(Error::PasswordInUse);
            }
        }
        let mut header = read_header(&vault.dir).ok_or(Error::Corrupt("vault header"))?;
        let salt = decode_array::<SALT_LEN>(&header.salt, "vault salt")?;
        let kek = kdf::vault_kek(&root, &salt);
        header.wrapped_master_key = hex::encode(wrap::wrap_key(
            &kek,
            &vault.master_key,
            &aad(&vault.id, "master-key"),
        ));
        write_atomic(
            &vault.dir.join(HEADER_FILE),
            &serde_json::to_vec_pretty(&header).expect("serialisable"),
        )
    }

    /// Move this library to `new_key` (a new Recovery Key), keeping every item: the
    /// vault's Master Key is wrapped again with its password and the new key. False if
    /// `password` is not this vault's.
    ///
    /// Crash-safe in this order: (1) the vault keeps its old wrap beside the new one,
    /// (2) the library accepts both keys, (3) the app stores the new key, (4) opening with
    /// it ([`Library::open_or_create`]) drops the old wrap and fingerprint. Stopped
    /// anywhere, the key the device holds still opens the vault. Backups made before
    /// still need the old key.
    pub fn change_secret_key(
        &self,
        vault: &OpenVault,
        password: &str,
        new_key: &SecretKey,
    ) -> Result<bool> {
        let old_root = kdf::derive_root(
            password.as_bytes(),
            &self.secret_key,
            &self.salt,
            self.params,
        )?;
        let mut header = read_header(&vault.dir).ok_or(Error::Corrupt("vault header"))?;
        let salt = decode_array::<SALT_LEN>(&header.salt, "vault salt")?;
        let old_kek = kdf::vault_kek(&old_root, &salt);
        let aad = aad(&vault.id, "master-key");
        // Which wrap the old key opens (the current one, or the kept one after a change
        // that stopped half-way): that one is kept until the end.
        let Some(old_wrap) = [&header.wrapped_master_key, &header.prev_wrapped_master_key]
            .into_iter()
            .filter(|w| !w.is_empty())
            .find(|w| {
                hex::decode(w).is_ok_and(|b| {
                    wrap::unwrap_key(&old_kek, &b, &aad).is_ok_and(|k| k == vault.master_key)
                })
            })
            .cloned()
        else {
            return Ok(false);
        };
        // Another vault opening by password would stop opening (debug builds only).
        for entry in fs::read_dir(self.dir.join(VAULTS_DIR))? {
            let entry = entry?;
            if entry.file_name().to_string_lossy() != vault.id
                && read_header(&entry.path()).is_some_and(|h| h.has_password())
            {
                return Err(Error::Corrupt("another vault uses this Recovery Key"));
            }
        }
        let new_root = kdf::derive_root(password.as_bytes(), new_key, &self.salt, self.params)?;
        let new_kek = kdf::vault_kek(&new_root, &salt);
        header.prev_wrapped_master_key = old_wrap;
        header.wrapped_master_key = hex::encode(wrap::wrap_key(&new_kek, &vault.master_key, &aad));
        write_atomic(
            &vault.dir.join(HEADER_FILE),
            &serde_json::to_vec_pretty(&header).expect("serialisable"),
        )?;
        let mut lib = read_library_header(&self.dir)?;
        lib.prev_secret_key = Some(self.secret_key.fingerprint());
        lib.secret_key = Some(new_key.fingerprint());
        write_atomic(
            &self.dir.join(LIBRARY_FILE),
            &serde_json::to_vec_pretty(&lib).expect("serialisable"),
        )?;
        Ok(true)
    }
}

/// The end of a Secret Key change: the old key no longer opens anything here.
fn finish_key_change(dir: &Path, header: &mut LibraryHeader) -> Result<()> {
    if let Ok(entries) = fs::read_dir(dir.join(VAULTS_DIR)) {
        for entry in entries.flatten() {
            if let Some(mut h) = read_header(&entry.path()) {
                if !h.prev_wrapped_master_key.is_empty() {
                    h.prev_wrapped_master_key.clear();
                    write_atomic(
                        &entry.path().join(HEADER_FILE),
                        &serde_json::to_vec_pretty(&h).expect("serialisable"),
                    )?;
                }
            }
        }
    }
    header.prev_secret_key = None;
    write_atomic(
        &dir.join(LIBRARY_FILE),
        &serde_json::to_vec_pretty(&*header).expect("serialisable"),
    )
}

impl OpenVault {
    pub fn has_password(&self) -> bool {
        read_header(&self.dir).is_some_and(|h| h.has_password())
    }

    /// Change the icon and colour (sealed with the Master Key like the rest of the meta).
    pub fn set_identity(&mut self, icon: &str, color: &str) -> Result<()> {
        let mut header = read_header(&self.dir).ok_or(Error::Corrupt("vault header"))?;
        let meta = VaultMeta {
            name: self.name.clone(),
            icon: icon.to_owned(),
            color: color.to_owned(),
        };
        header.meta = hex::encode(wrap::seal(
            &self.master_key,
            &serde_json::to_vec(&meta).expect("serialisable"),
            &aad(&self.id, "meta"),
        ));
        write_atomic(
            &self.dir.join(HEADER_FILE),
            &serde_json::to_vec_pretty(&header).expect("serialisable"),
        )?;
        self.icon = meta.icon;
        self.color = meta.color;
        Ok(())
    }

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

    /// Delete this vault and everything in it from this device: items, its PIN and
    /// biometric copies all live in its folder. The header goes first, so a crash
    /// midway leaves a folder that no longer opens (and is cleaned up next time).
    pub fn destroy(self) -> Result<()> {
        fs::remove_file(self.dir.join(HEADER_FILE))?;
        fs::remove_dir_all(&self.dir)?;
        Ok(())
    }

    pub fn biometric_enabled(&self) -> bool {
        self.dir.join(BIOMETRIC_FILE).is_file()
    }
}

fn read_library_header(dir: &Path) -> Result<LibraryHeader> {
    let header: LibraryHeader = serde_json::from_slice(&fs::read(dir.join(LIBRARY_FILE))?)
        .map_err(|_| Error::Corrupt("library.json"))?;
    if header.format != FORMAT {
        return Err(Error::Corrupt("unsupported library format"));
    }
    Ok(header)
}

pub(crate) fn read_header(vault_dir: &Path) -> Option<VaultHeader> {
    let bytes = fs::read(vault_dir.join(HEADER_FILE)).ok()?;
    let header: VaultHeader = serde_json::from_slice(&bytes).ok()?;
    (header.format == FORMAT).then_some(header)
}

pub(crate) fn open_with(
    id: String,
    dir: PathBuf,
    header: &VaultHeader,
    master_key: Key,
) -> Result<OpenVault> {
    let meta_bytes = hex::decode(&header.meta).map_err(|_| Error::Corrupt("vault meta"))?;
    let meta_json = wrap::open(&master_key, &meta_bytes, &aad(&id, "meta"))?;
    let meta: VaultMeta =
        serde_json::from_slice(&meta_json).map_err(|_| Error::Corrupt("vault meta"))?;
    let index = db::Index::open(&dir)?;
    let vault = OpenVault {
        id,
        name: meta.name,
        icon: meta.icon,
        color: meta.color,
        dir,
        master_key,
        index,
    };
    // Every vault from before the index, every restored backup, and any change the
    // index missed (the app stopped between the two writes) comes in here.
    vault.sync_index()?;
    Ok(vault)
}

pub(crate) fn remove_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
        _ => Ok(()),
    }
}

/// Associated data binding a sealed value to its vault and role.
pub(crate) fn aad(vault_id: &str, role: &str) -> Vec<u8> {
    format!("cozysafe/v1/vault/{vault_id}/{role}").into_bytes()
}

pub(crate) fn decode_array<const N: usize>(s: &str, what: &'static str) -> Result<[u8; N]> {
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

#[cfg(test)]
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
pub(crate) mod tests {
    use super::*;

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    const PW_A: &str = "mây tháng mười rơi trên phố cổ";
    const PW_B: &str = "orange kettle whispers at dawn 77";

    pub(crate) fn sk() -> SecretKey {
        SecretKey::from_bytes([7; SECRET_KEY_LEN])
    }

    fn lib(dir: &Path) -> Library {
        Library::open_or_create(dir, FAST, sk()).unwrap()
    }

    fn note(v: &OpenVault, text: &str) -> String {
        v.add_item(crate::items::NewItem {
            kind: crate::items::kind::NOTE,
            name: "n",
            mime: "text/plain",
            created_ms: 1,
            content: text.as_bytes(),
            thumbnail: None,
        })
        .unwrap()
        .id
    }

    #[test]
    fn the_recovery_key_changes_from_the_old_kind_to_24_words() {
        let tmp = tempfile::tempdir().unwrap();
        let old = SecretKey::from_slice(&[9u8; 16]).unwrap();
        let new = SecretKey::generate();
        let l = Library::open_or_create(tmp.path(), FAST, old.clone()).unwrap();
        let v = l.create_vault("Két", PW_A).unwrap();
        let id = note(&v, "giữ nguyên");
        let dk = SecretKey::generate();
        v.enable_pin("246810", &dk, FAST).unwrap();

        assert!(
            !l.change_secret_key(&v, PW_B, &new).unwrap(),
            "wrong password"
        );
        assert!(l.change_secret_key(&v, PW_A, &new).unwrap());
        drop(v);
        // Until the device holds the new key, the old one still opens it.
        let still = Library::open_or_create(tmp.path(), FAST, old.clone()).unwrap();
        assert!(still.unlock(PW_A).unwrap().is_some());
        // The new key: opens, and the change finishes.
        let l = Library::open_or_create(tmp.path(), FAST, new.clone()).unwrap();
        let v = l.unlock(PW_A).unwrap().expect("opens with the new key");
        let mut out = Vec::new();
        v.read_item(&id, &mut out).unwrap();
        assert_eq!(out, "giữ nguyên".as_bytes());
        drop(v);
        // The old key opens nothing any more; the PIN still does.
        assert!(matches!(
            Library::open_or_create(tmp.path(), FAST, old),
            Err(Error::WrongSecretKey)
        ));
        assert!(Library::unlock_pin(tmp.path(), "246810", &dk)
            .unwrap()
            .is_some());
        let h = read_header(&tmp.path().join(VAULTS_DIR).join(id_of(tmp.path()))).unwrap();
        assert!(h.prev_wrapped_master_key.is_empty());
    }

    fn id_of(dir: &Path) -> String {
        fs::read_dir(dir.join(VAULTS_DIR))
            .unwrap()
            .flatten()
            .next()
            .unwrap()
            .file_name()
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn a_key_change_stopped_half_way_never_locks_the_vault_out() {
        let tmp = tempfile::tempdir().unwrap();
        let k0 = sk();
        let l = Library::open_or_create(tmp.path(), FAST, k0.clone()).unwrap();
        let v = l.create_vault("Két", PW_A).unwrap();
        let lib_before = fs::read(tmp.path().join(LIBRARY_FILE)).unwrap();
        // The app stopped after the vault header, before the library header.
        let k1 = SecretKey::generate();
        assert!(l.change_secret_key(&v, PW_A, &k1).unwrap());
        fs::write(tmp.path().join(LIBRARY_FILE), &lib_before).unwrap();
        drop(v);
        let l = Library::open_or_create(tmp.path(), FAST, k0.clone()).unwrap();
        let v = l.unlock(PW_A).unwrap().expect("the old key still opens");
        // Trying again with another key works, and keeps the old way in until the end.
        let k2 = SecretKey::generate();
        assert!(l.change_secret_key(&v, PW_A, &k2).unwrap());
        drop(v);
        assert!(Library::open_or_create(tmp.path(), FAST, k0)
            .unwrap()
            .unlock(PW_A)
            .unwrap()
            .is_some());
        // The lost k1 opens nothing.
        assert!(Library::open_or_create(tmp.path(), FAST, k1).is_err());
        let l = Library::open_or_create(tmp.path(), FAST, k2).unwrap();
        assert!(l.unlock(PW_A).unwrap().is_some());
    }

    #[test]
    fn an_empty_library_can_start_again_with_a_new_key() {
        let tmp = tempfile::tempdir().unwrap();
        let old = SecretKey::from_slice(&[9u8; 16]).unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, old.clone())
            .unwrap()
            .create_vault("Cũ", PW_A)
            .unwrap();
        // Not while a vault is there.
        assert!(!Library::reset_if_empty(tmp.path()).unwrap());
        assert!(matches!(
            Library::open_or_create(tmp.path(), FAST, sk()),
            Err(Error::WrongSecretKey)
        ));
        v.destroy().unwrap();
        assert!(Library::reset_if_empty(tmp.path()).unwrap());
        let fresh = lib(tmp.path()).create_vault("Mới", PW_B).unwrap();
        assert_eq!(lib(tmp.path()).unlock(PW_B).unwrap().unwrap().id, fresh.id);
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
    fn short_password_and_empty_name_are_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let l = lib(tmp.path());
        assert!(matches!(
            l.create_vault("A", "short12"),
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
    fn another_secret_key_is_refused_up_front() {
        let tmp = tempfile::tempdir().unwrap();
        lib(tmp.path()).create_vault("A", PW_A).unwrap();
        let other = SecretKey::generate();
        assert!(!Library::secret_key_fits(tmp.path(), &other));
        assert!(Library::secret_key_fits(tmp.path(), &sk()));
        assert!(matches!(
            Library::open_or_create(tmp.path(), FAST, other),
            Err(Error::WrongSecretKey)
        ));
    }

    #[test]
    fn legacy_secret_key_file_moves_out() {
        let tmp = tempfile::tempdir().unwrap();
        lib(tmp.path()).create_vault("A", PW_A).unwrap();
        // A first-preview library: key in a file, no fingerprint in library.json.
        write_private(&tmp.path().join(SECRET_KEY_FILE), sk().as_bytes()).unwrap();
        let mut h = read_library_header(tmp.path()).unwrap();
        h.secret_key = None;
        fs::write(
            tmp.path().join(LIBRARY_FILE),
            serde_json::to_vec(&h).unwrap(),
        )
        .unwrap();

        let key = Library::legacy_secret_key(tmp.path()).unwrap().unwrap();
        assert_eq!(key, sk());
        Library::forget_legacy_secret_key(tmp.path()).unwrap();
        assert!(Library::legacy_secret_key(tmp.path()).unwrap().is_none());
        // Opening records the fingerprint; the vault still opens.
        assert!(Library::open_or_create(tmp.path(), FAST, key)
            .unwrap()
            .unlock(PW_A)
            .unwrap()
            .is_some());
        assert!(!Library::secret_key_fits(
            tmp.path(),
            &SecretKey::generate()
        ));
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

    #[test]
    fn destroy_removes_the_vault() {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let a = lib.create_vault("A", PW_A).unwrap();
        lib.create_vault("B", PW_B).unwrap();
        a.destroy().unwrap();
        assert!(lib.unlock(PW_A).unwrap().is_none());
        assert!(lib.unlock(PW_B).unwrap().is_some());
    }
}
