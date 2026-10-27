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
pub mod history;
pub mod items;
pub mod join;
pub mod passphrase;
pub mod passwords;
pub use passwords::{check_new_password, PasswordCheck};
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

/// zxcvbn score (0–4) a new password needs, unless it is a passphrase of
/// [`passwords::MIN_WORDS`] words ([`check_new_password`]).
pub const MIN_PASSWORD_SCORE: u8 = 3;
/// A new password needs at least this many characters (and see [`check_new_password`]).
pub const MIN_PASSWORD_LEN: usize = 8;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A new password that [`check_new_password`] refuses.
    #[error("password too short or too easy to guess")]
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
    /// The vaults on this device, as far as can be told without opening them: an id and
    /// which ways open each (names and icons are sealed with each vault's own key). For
    /// the Debug page only: in everyday use the app never lists vaults, so a second vault
    /// stays unseen.
    pub fn vault_slots(dir: &Path) -> Result<Vec<VaultSlot>> {
        let entries = match fs::read_dir(dir.join(VAULTS_DIR)) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let mut slots = Vec::new();
        for entry in entries {
            let entry = entry?;
            let Some(id) = id_name(&entry.file_name().to_string_lossy()) else {
                continue;
            };
            let Some(header) = read_header(&entry.path()) else {
                continue;
            };
            slots.push(VaultSlot {
                size_bytes: dir_size(&entry.path()),
                has_password: header.has_password(),
                has_pin: entry.path().join(pin::PIN_FILE).is_file(),
                has_biometric: entry.path().join(BIOMETRIC_FILE).is_file(),
                id,
            });
        }
        slots.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(slots)
    }

    /// Delete a vault without opening it (its password and PIN forgotten): its folder,
    /// header first as [`OpenVault::destroy`] does. Nothing in it can be brought back.
    /// The caller makes sure it is not the open one and that the owner confirmed.
    pub fn destroy_unopened(dir: &Path, vault_id: &str) -> Result<()> {
        let id = id_name(vault_id).ok_or(Error::Corrupt("vault id"))?;
        let vault_dir = dir.join(VAULTS_DIR).join(&id);
        if !vault_dir.join(HEADER_FILE).is_file() {
            return Err(Error::Corrupt("no such vault"));
        }
        fs::remove_file(vault_dir.join(HEADER_FILE))?;
        fs::remove_dir_all(&vault_dir)?;
        Ok(())
    }

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
        // A cost under the floor means a tampered library.json: refused before any
        // password is tried with it.
        let params = KdfParams::from(header.kdf);
        params.check()?;
        let fits = |f: &Option<String>| {
            f.as_deref()
                .is_some_and(|f| secret_key.fingerprint_matches(f))
        };
        let (current, prev) = (fits(&header.secret_key), fits(&header.prev_secret_key));
        match &header.secret_key {
            // The new key of a change that has reached the device: the old one goes. Not
            // when the old key's 16 bits match too (one change in 65536): which one the
            // device holds cannot be told, so both stay accepted.
            Some(_) if current && header.prev_secret_key.is_some() && !prev => {
                finish_key_change(dir, &mut header)?;
            }
            // The old key of a change the device has not taken up yet: still fine.
            Some(_) if current || prev => {}
            Some(_) => return Err(Error::WrongSecretKey),
            None => {
                // Older library: record the fingerprint now.
                header.secret_key = Some(secret_key.fingerprint());
                write_atomic(
                    &header_path,
                    &serde_json::to_vec_pretty(&header).expect("serialisable"),
                )?;
            }
        }
        // Fingerprints from before 0.1.68 (16 hex) are cut to the 4 now written.
        if shorten_fingerprints(&mut header) {
            write_atomic(
                &header_path,
                &serde_json::to_vec_pretty(&header).expect("serialisable"),
            )?;
        }
        let salt = decode_array::<SALT_LEN>(&header.salt, "library salt")?;
        Ok(Library {
            dir: dir.to_path_buf(),
            params,
            salt,
            secret_key,
        })
    }

    /// Whether `secret_key` belongs to the library in `dir` (true when the library
    /// predates fingerprints and cannot tell). A hint only: a key that matches by chance
    /// still opens nothing.
    pub fn secret_key_fits(dir: &Path, secret_key: &SecretKey) -> bool {
        match read_library_header(dir) {
            Ok(h) => h
                .secret_key
                .is_none_or(|f| secret_key.fingerprint_matches(&f)),
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

    /// Create a vault. Refuses passwords [`check_new_password`] refuses and passwords another
    /// vault already opens with.
    pub fn create_vault(&self, name: &str, password: &str) -> Result<OpenVault> {
        let name = name.trim();
        if name.is_empty() {
            return Err(Error::EmptyName);
        }
        if check_new_password(password) != PasswordCheck::Ok {
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
        if check_new_password(password) != PasswordCheck::Ok {
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
    /// `password` is not this vault's. Only when no other vault here opens by password
    /// (they share the key); [`Library::change_secret_key_all`] moves them all.
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
        if self.password_vaults()?.iter().any(|id| *id != vault.id) {
            return Err(Error::Corrupt("another vault uses this Recovery Key"));
        }
        if !self.rewrap(vault, password, new_key)? {
            return Ok(false);
        }
        self.accept_key(new_key)?;
        Ok(true)
    }

    /// [`Library::change_secret_key`] for every vault here that opens by password (owner
    /// 2026-10-25: with two vaults the change refused): one password per vault, in any
    /// order. Nothing changes until each of them is given; then each is wrapped again
    /// (same crash-safe order), and only then does the library take the new key.
    /// Vaults opened only by a PIN do not depend on the key and are left alone.
    pub fn change_secret_key_all(
        &self,
        passwords: &[&str],
        new_key: &SecretKey,
    ) -> Result<KeyChange> {
        let mut opened: Vec<(OpenVault, &str)> = Vec::new();
        for &password in passwords {
            let Some(vault) = self.unlock(password)? else {
                return Ok(KeyChange::WrongPassword);
            };
            if !opened.iter().any(|(v, _)| v.id == vault.id) {
                opened.push((vault, password));
            }
        }
        let missing = self
            .password_vaults()?
            .iter()
            .filter(|id| !opened.iter().any(|(v, _)| v.id == **id))
            .count();
        if missing > 0 {
            return Ok(KeyChange::OthersNeeded(missing));
        }
        for (vault, password) in &opened {
            if !self.rewrap(vault, password, new_key)? {
                return Ok(KeyChange::WrongPassword);
            }
        }
        self.accept_key(new_key)?;
        Ok(KeyChange::Changed)
    }

    /// The vaults here that open by password (their wraps depend on the Recovery Key).
    fn password_vaults(&self) -> Result<Vec<String>> {
        let mut ids = Vec::new();
        for entry in fs::read_dir(self.dir.join(VAULTS_DIR))? {
            let entry = entry?;
            if read_header(&entry.path()).is_some_and(|h| h.has_password()) {
                ids.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
        Ok(ids)
    }

    /// Step 1 for one vault: its Master Key wrapped with `password` and `new_key`, the old
    /// wrap kept beside it. False if `password` is not this vault's.
    fn rewrap(&self, vault: &OpenVault, password: &str, new_key: &SecretKey) -> Result<bool> {
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
        let new_root = kdf::derive_root(password.as_bytes(), new_key, &self.salt, self.params)?;
        let new_kek = kdf::vault_kek(&new_root, &salt);
        header.prev_wrapped_master_key = old_wrap;
        header.wrapped_master_key = hex::encode(wrap::wrap_key(&new_kek, &vault.master_key, &aad));
        write_atomic(
            &vault.dir.join(HEADER_FILE),
            &serde_json::to_vec_pretty(&header).expect("serialisable"),
        )?;
        Ok(true)
    }

    /// Step 2: the library accepts both keys.
    fn accept_key(&self, new_key: &SecretKey) -> Result<()> {
        let mut lib = read_library_header(&self.dir)?;
        lib.prev_secret_key = Some(self.secret_key.fingerprint());
        lib.secret_key = Some(new_key.fingerprint());
        write_atomic(
            &self.dir.join(LIBRARY_FILE),
            &serde_json::to_vec_pretty(&lib).expect("serialisable"),
        )?;
        Ok(())
    }
}

/// The bytes under `dir`, folders included (0 for what cannot be read).
fn dir_size(dir: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_size(&e.path()),
            Ok(_) => e.metadata().map_or(0, |m| m.len()),
            Err(_) => 0,
        })
        .sum()
}

/// A vault on this device, seen from outside ([`Library::vault_slots`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultSlot {
    pub id: String,
    /// What it takes on this device (sealed files), in bytes.
    pub size_bytes: u64,
    pub has_password: bool,
    pub has_pin: bool,
    pub has_biometric: bool,
}

/// What came of [`Library::change_secret_key_all`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyChange {
    Changed,
    /// A password given opens no vault here.
    WrongPassword,
    /// This many vaults that open by password were not given theirs.
    OthersNeeded(usize),
}

/// Cut fingerprints written before 0.1.68 (8 bytes) to the 2 bytes written now: their
/// first characters are exactly the new fingerprint. True if anything changed.
fn shorten_fingerprints(header: &mut LibraryHeader) -> bool {
    let mut changed = false;
    for f in [&mut header.secret_key, &mut header.prev_secret_key]
        .into_iter()
        .flatten()
    {
        if f.len() > cs_crypto::FINGERPRINT_HEX && f.is_char_boundary(cs_crypto::FINGERPRINT_HEX) {
            f.truncate(cs_crypto::FINGERPRINT_HEX);
            changed = true;
        }
    }
    changed
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

/// An id (a vault's or an item's: 32 lowercase hex) as it may go into a file name,
/// rebuilt from its number: nothing but hex digits can reach a path, whatever came from
/// a sync place, another device or Dart (and CodeQL sees the check).
pub(crate) fn id_name(id: &str) -> Option<String> {
    if id.len() != SALT_LEN * 2 {
        return None;
    }
    let n = u128::from_str_radix(id, 16).ok()?;
    let name = format!("{n:032x}");
    // "+…" parses too, and capitals format back in lowercase: only the exact form passes.
    (name == id).then_some(name)
}

/// The bucket of an item: the last two hex digits of its id, "00" to "ff". Item ids are
/// random, so each of the 256 buckets holds about 1/256 of a vault's items: the folder
/// its files are kept in, on this device (`items/<bucket>/`) and in Google Drive alike.
/// `None` for anything that is not an item id.
pub fn bucket_of(item_id: &str) -> Option<&str> {
    id_name(item_id)?;
    Some(&item_id[item_id.len() - 2..])
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
    // Files from before buckets (0.1.57 and earlier) go into theirs.
    vault.move_into_buckets()?;
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

    #[test]
    fn only_exact_lowercase_hex_ids_reach_a_path() {
        let id = "0123456789abcdef0123456789abcdef";
        assert_eq!(id_name(id).as_deref(), Some(id));
        for bad in [
            "0123456789ABCDEF0123456789abcdef",
            "+123456789abcdef0123456789abcdef",
            "../../../../../../../../etc/pass",
            "0123456789abcdef0123456789abcde",
            "",
        ] {
            assert_eq!(id_name(bad), None, "{bad}");
        }
    }

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    /// A vault password, random each run: none is written in the code.
    fn pw_a() -> &'static str {
        static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        P.get_or_init(|| hex::encode(cs_crypto::generate_salt()))
    }
    /// A vault password, random each run: none is written in the code.
    fn pw_b() -> &'static str {
        static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        P.get_or_init(|| hex::encode(cs_crypto::generate_salt()))
    }

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
        let v = l.create_vault("Két", pw_a()).unwrap();
        let id = note(&v, "giữ nguyên");
        let dk = SecretKey::generate();
        v.enable_pin("246810", &dk, FAST).unwrap();

        assert!(
            !l.change_secret_key(&v, pw_b(), &new).unwrap(),
            "wrong password"
        );
        assert!(l.change_secret_key(&v, pw_a(), &new).unwrap());
        drop(v);
        // Until the device holds the new key, the old one still opens it.
        let still = Library::open_or_create(tmp.path(), FAST, old.clone()).unwrap();
        assert!(still.unlock(pw_a()).unwrap().is_some());
        // The new key: opens, and the change finishes.
        let l = Library::open_or_create(tmp.path(), FAST, new.clone()).unwrap();
        let v = l.unlock(pw_a()).unwrap().expect("opens with the new key");
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

    #[test]
    fn the_recovery_key_changes_for_every_vault_given_their_passwords() {
        let tmp = tempfile::tempdir().unwrap();
        let old = sk();
        let new = SecretKey::generate();
        let l = Library::open_or_create(tmp.path(), FAST, old.clone()).unwrap();
        let a = l.create_vault("A", pw_a()).unwrap();
        let b = l.create_vault("B", pw_b()).unwrap();
        let in_a = note(&a, "của A");
        let in_b = note(&b, "của B");
        drop((a, b));
        // One password is not enough while the other vault shares the key: nothing moves.
        assert_eq!(
            l.change_secret_key_all(&[pw_a()], &new).unwrap(),
            KeyChange::OthersNeeded(1)
        );
        assert!(Library::open_or_create(tmp.path(), FAST, old.clone())
            .unwrap()
            .unlock(pw_b())
            .unwrap()
            .is_some());
        let wrong: String = pw_a().chars().rev().collect();
        assert_eq!(
            l.change_secret_key_all(&[pw_a(), &wrong], &new).unwrap(),
            KeyChange::WrongPassword
        );
        // Both, in any order: both move.
        assert_eq!(
            l.change_secret_key_all(&[pw_b(), pw_a()], &new).unwrap(),
            KeyChange::Changed
        );
        let l = Library::open_or_create(tmp.path(), FAST, new.clone()).unwrap();
        for (pw, id, text) in [(pw_a(), &in_a, "của A"), (pw_b(), &in_b, "của B")] {
            let v = l.unlock(pw).unwrap().expect("opens with the new key");
            let mut out = Vec::new();
            v.read_item(id, &mut out).unwrap();
            assert_eq!(out, text.as_bytes());
        }
        assert!(matches!(
            Library::open_or_create(tmp.path(), FAST, old),
            Err(Error::WrongSecretKey)
        ));
    }

    #[test]
    fn a_forgotten_vault_is_listed_and_deleted_without_opening_it() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let a = l.create_vault("A", pw_a()).unwrap();
        let b = l.create_vault("B", pw_b()).unwrap();
        let (a_id, b_id) = (a.id.clone(), b.id.clone());
        drop((a, b));
        let slots = Library::vault_slots(tmp.path()).unwrap();
        assert_eq!(slots.len(), 2);
        assert!(slots
            .iter()
            .all(|s| s.has_password && !s.has_pin && s.size_bytes > 0));
        for bad in ["../x", "", &b_id.to_uppercase()] {
            assert!(Library::destroy_unopened(tmp.path(), bad).is_err());
        }
        Library::destroy_unopened(tmp.path(), &b_id).unwrap();
        let left = Library::vault_slots(tmp.path()).unwrap();
        assert_eq!(
            left.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            [a_id.as_str()]
        );
        assert!(l.unlock(pw_b()).unwrap().is_none());
        assert!(l.unlock(pw_a()).unwrap().is_some());
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
        let v = l.create_vault("Két", pw_a()).unwrap();
        let lib_before = fs::read(tmp.path().join(LIBRARY_FILE)).unwrap();
        // The app stopped after the vault header, before the library header.
        let k1 = SecretKey::generate();
        assert!(l.change_secret_key(&v, pw_a(), &k1).unwrap());
        fs::write(tmp.path().join(LIBRARY_FILE), &lib_before).unwrap();
        drop(v);
        let l = Library::open_or_create(tmp.path(), FAST, k0.clone()).unwrap();
        let v = l.unlock(pw_a()).unwrap().expect("the old key still opens");
        // Trying again with another key works, and keeps the old way in until the end.
        let k2 = SecretKey::generate();
        assert!(l.change_secret_key(&v, pw_a(), &k2).unwrap());
        drop(v);
        assert!(Library::open_or_create(tmp.path(), FAST, k0)
            .unwrap()
            .unlock(pw_a())
            .unwrap()
            .is_some());
        // The lost k1 opens nothing.
        assert!(Library::open_or_create(tmp.path(), FAST, k1).is_err());
        let l = Library::open_or_create(tmp.path(), FAST, k2).unwrap();
        assert!(l.unlock(pw_a()).unwrap().is_some());
    }

    #[test]
    fn an_empty_library_can_start_again_with_a_new_key() {
        let tmp = tempfile::tempdir().unwrap();
        let old = SecretKey::from_slice(&[9u8; 16]).unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, old.clone())
            .unwrap()
            .create_vault("Cũ", pw_a())
            .unwrap();
        // Not while a vault is there.
        assert!(!Library::reset_if_empty(tmp.path()).unwrap());
        assert!(matches!(
            Library::open_or_create(tmp.path(), FAST, sk()),
            Err(Error::WrongSecretKey)
        ));
        v.destroy().unwrap();
        assert!(Library::reset_if_empty(tmp.path()).unwrap());
        let fresh = lib(tmp.path()).create_vault("Mới", pw_b()).unwrap();
        assert_eq!(
            lib(tmp.path()).unlock(pw_b()).unwrap().unwrap().id,
            fresh.id
        );
    }

    #[test]
    fn create_then_unlock() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(!Library::has_vaults(tmp.path()));
        let v = lib(tmp.path()).create_vault("Cá nhân", pw_a()).unwrap();
        assert!(Library::has_vaults(tmp.path()));

        // A fresh Library instance, as after an app restart.
        let opened = lib(tmp.path())
            .unlock(pw_a())
            .unwrap()
            .expect("vault opens");
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
        let a = l.create_vault("A", pw_a()).unwrap();
        let b = l.create_vault("B", pw_b()).unwrap();
        assert_eq!(l.unlock(pw_a()).unwrap().unwrap().id, a.id);
        assert_eq!(l.unlock(pw_b()).unwrap().unwrap().id, b.id);
    }

    #[test]
    fn biometric_copy_opens_only_its_vault_and_moves_on_enable() {
        let tmp = tempfile::tempdir().unwrap();
        let l = lib(tmp.path());
        let a = l.create_vault("A", pw_a()).unwrap();
        let b = l.create_vault("B", pw_b()).unwrap();
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
        l.create_vault("A", pw_a()).unwrap();
        assert!(matches!(
            l.create_vault("B", pw_a()),
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
        assert!(matches!(
            l.create_vault("  ", pw_a()),
            Err(Error::EmptyName)
        ));
        assert!(!Library::has_vaults(tmp.path()));
    }

    #[test]
    fn nothing_on_disk_names_the_vault() {
        let tmp = tempfile::tempdir().unwrap();
        let v = lib(tmp.path())
            .create_vault("Hồ sơ thuế bí mật", pw_a())
            .unwrap();
        let header =
            fs::read_to_string(tmp.path().join(VAULTS_DIR).join(&v.id).join(HEADER_FILE)).unwrap();
        assert!(!header.contains("thuế") && !header.contains("Hồ sơ"));
    }

    #[test]
    fn another_secret_key_is_refused_up_front() {
        let tmp = tempfile::tempdir().unwrap();
        lib(tmp.path()).create_vault("A", pw_a()).unwrap();
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
        lib(tmp.path()).create_vault("A", pw_a()).unwrap();
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
            .unlock(pw_a())
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
        let a = l.create_vault("A", pw_a()).unwrap();
        l.create_vault("B", pw_b()).unwrap();
        fs::write(
            tmp.path().join(VAULTS_DIR).join(&a.id).join(HEADER_FILE),
            b"{not json",
        )
        .unwrap();
        assert!(l.unlock(pw_a()).unwrap().is_none());
        assert!(l.unlock(pw_b()).unwrap().is_some());
    }

    #[test]
    fn scores() {
        assert!(password_score("password1") < MIN_PASSWORD_SCORE);
        assert!(password_score(pw_a()) >= MIN_PASSWORD_SCORE);
        assert!(password_score(pw_b()) >= MIN_PASSWORD_SCORE);
    }

    #[test]
    fn destroy_removes_the_vault() {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let a = lib.create_vault("A", pw_a()).unwrap();
        lib.create_vault("B", pw_b()).unwrap();
        a.destroy().unwrap();
        assert!(lib.unlock(pw_a()).unwrap().is_none());
        assert!(lib.unlock(pw_b()).unwrap().is_some());
    }

    #[test]
    fn a_library_with_a_lowered_argon2_cost_does_not_open() {
        let tmp = tempfile::tempdir().unwrap();
        lib(tmp.path()).create_vault("A", pw_a()).unwrap();
        crate::backup::tests::weaken(tmp.path());
        assert!(matches!(
            Library::open_or_create(tmp.path(), FAST, sk()),
            Err(Error::Crypto(cs_crypto::Error::KdfTooWeak))
        ));
    }

    #[test]
    fn fingerprints_are_short_and_old_long_ones_still_open() {
        let tmp = tempfile::tempdir().unwrap();
        let v = lib(tmp.path()).create_vault("A", pw_a()).unwrap();
        let id = v.id.clone();
        drop(v);
        let header = read_library_header(tmp.path()).unwrap();
        assert_eq!(
            header.secret_key.as_deref(),
            Some(sk().fingerprint().as_str())
        );
        assert_eq!(sk().fingerprint().len(), cs_crypto::FINGERPRINT_HEX);

        // A library from 0.1.67: the same fingerprint, 16 hex long.
        let path = tmp.path().join(LIBRARY_FILE);
        let mut v: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        v["secret_key"] = serde_json::json!(format!("{}a1b2c3d4e5f6", sk().fingerprint()));
        fs::write(&path, serde_json::to_vec(&v).unwrap()).unwrap();
        assert!(Library::secret_key_fits(tmp.path(), &sk()));
        let opened = lib(tmp.path()).unlock(pw_a()).unwrap().unwrap();
        assert_eq!(opened.id, id);
        // Opening cut it to the 4 characters written now.
        let header = read_library_header(tmp.path()).unwrap();
        assert_eq!(
            header.secret_key.as_deref(),
            Some(sk().fingerprint().as_str())
        );
    }

    #[test]
    fn a_wrong_key_whose_fingerprint_matches_by_chance_still_opens_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        lib(tmp.path()).create_vault("A", pw_a()).unwrap();
        // Find another key with the same 16 bits (about 65536 tries, no Argon2 involved).
        let other = (0u32..)
            .map(|i| {
                let mut b = [0u8; SECRET_KEY_LEN];
                b[..4].copy_from_slice(&i.to_be_bytes());
                b[31] = 1;
                SecretKey::from_bytes(b)
            })
            .find(|k| k.fingerprint() == sk().fingerprint())
            .unwrap();
        assert!(Library::secret_key_fits(tmp.path(), &other));
        let l = Library::open_or_create(tmp.path(), FAST, other).unwrap();
        assert!(l.unlock(pw_a()).unwrap().is_none(), "the unwrap decides");
    }
}
