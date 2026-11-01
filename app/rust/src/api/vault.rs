//! The only surface Flutter sees. Keys never cross it: Dart gets vault names and IDs,
//! never key material. The password has to come from a Dart text field; it is wiped
//! here as soon as it has been used.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use cs_crypto::kdf::KdfParams;
use cs_crypto::SecretKey;
use cs_vault::items::NewItem;
use cs_vault::{ItemMeta, Library, OpenVault};
use zeroize::Zeroizing;

use crate::slot::{Hold, Kept, Slot};

/// The vault currently open, if any. One at a time by design. A sync running when it
/// locks keeps its own [`SyncHold`] until it ends (src/slot.rs, docs/security.md).
static OPEN: Slot<OpenVault> = Slot::new();

/// What the lock screen and settings read of the open vault without waiting for a sync.
#[derive(Clone)]
pub(crate) struct Glance {
    info: VaultInfo,
    pin: bool,
    biometric: bool,
}

impl Kept for OpenVault {
    type Glance = Glance;
    fn id(&self) -> &str {
        &self.id
    }
    fn glance(&self) -> Glance {
        Glance {
            info: info_of(self),
            pin: self.pin_enabled(),
            biometric: self.biometric_enabled(),
        }
    }
    fn reader(&self) -> Option<Self> {
        OpenVault::reader(self)
            .inspect_err(|_| debug_line(|| "vault reader: could not open".into()))
            .ok()
    }
}

/// A sync's own handle on the vault it syncs, kept through a lock until the sync ends.
pub(crate) type SyncHold = Hold<'static, OpenVault>;

/// The open vault for a sync from start to end; None when locked.
pub(crate) fn hold_for_sync() -> Option<SyncHold> {
    OPEN.hold()
}
/// Each library's Secret Key (api/run.rs: one library per set of 24 words), handed over
/// by Dart from the platform keystore at start.
static SECRET: Mutex<BTreeMap<PathBuf, SecretKey>> = Mutex::new(BTreeMap::new());

fn secrets() -> std::sync::MutexGuard<'static, BTreeMap<PathBuf, SecretKey>> {
    SECRET.lock().unwrap_or_else(|p| p.into_inner())
}
/// Technical lines for the Debug page: timings and error kinds, never names or content.
/// `None` (nothing kept) unless the app's debug mode turns it on.
static DEBUG_LOG: Mutex<Option<std::collections::VecDeque<String>>> = Mutex::new(None);

pub(crate) fn debug_line(line: impl FnOnce() -> String) {
    let mut log = DEBUG_LOG.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(q) = log.as_mut() {
        if q.len() >= 500 {
            q.pop_front();
        }
        let ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        q.push_back(format!("{ms}|{}", line()));
    }
}

/// Keep debug lines (debug mode on) or drop them all (off).
#[flutter_rust_bridge::frb(sync)]
pub fn set_debug_log(on: bool) {
    let mut log = DEBUG_LOG.lock().unwrap_or_else(|p| p.into_inner());
    *log = on.then(std::collections::VecDeque::new);
}

/// The debug lines kept since the last call, oldest first, each `<ms since epoch>|text`.
#[flutter_rust_bridge::frb(sync)]
pub fn take_debug_log() -> Vec<String> {
    let mut log = DEBUG_LOG.lock().unwrap_or_else(|p| p.into_inner());
    log.as_mut()
        .map(|q| q.drain(..).collect())
        .unwrap_or_default()
}

#[derive(Clone)]
pub struct VaultInfo {
    /// The library folder it is in (api/run.rs): the one to name for its 24 words.
    pub library_dir: String,
    pub id: String,
    pub name: String,
    /// Icon and colour ids from the app's sets (empty for vaults made before them).
    pub icon: String,
    pub color: String,
    pub has_password: bool,
    /// Top Secret Mode for this vault (ADR 0007).
    pub top_secret: bool,
}

/// Errors Dart shows to the user; each maps to a translated message.
pub enum VaultError {
    WeakPassword,
    PasswordInUse,
    EmptyName,
    /// A new PIN has at least 6 digits.
    BadPin,
    /// Another vault on this device already opens with this PIN.
    PinInUse,
    /// No vault is open (it locked while the screen was up).
    Locked,
    /// The Secret Key does not belong to this library (Emergency Kit from another one).
    WrongSecretKey,
    /// The chosen file is not a Cozy Safe backup, or it is damaged.
    BadBackup,
    /// Restoring needs an empty library; this device already has vaults.
    LibraryExists,
    /// The library, backup or sync place asks for a password-hashing cost below the
    /// least any release uses: its files were changed by someone. Nothing is opened.
    WeakKdf,
    /// The vault is in Top Secret Mode and this run opened an everyday vault: the app must
    /// start again before it opens (api/run.rs). Nothing was opened.
    RestartForMode,
    Storage,
}

/// A short fixed word for a [`VaultError`], for error codes the person can copy.
pub(crate) fn error_word(e: &VaultError) -> &'static str {
    match e {
        VaultError::WeakPassword => "weak-password",
        VaultError::PasswordInUse => "password-in-use",
        VaultError::EmptyName => "empty-name",
        VaultError::BadPin => "bad-pin",
        VaultError::PinInUse => "pin-in-use",
        VaultError::Locked => "locked",
        VaultError::WrongSecretKey => "wrong-secret-key",
        VaultError::BadBackup => "bad-backup",
        VaultError::LibraryExists => "library-exists",
        VaultError::WeakKdf => "weak-kdf",
        VaultError::RestartForMode => "restart-for-mode",
        VaultError::Storage => "storage",
    }
}

impl From<cs_vault::Error> for VaultError {
    fn from(e: cs_vault::Error) -> Self {
        super::errors::note("vault", &super::sync::error_code(&e));
        match e {
            cs_vault::Error::WeakPassword => VaultError::WeakPassword,
            cs_vault::Error::PasswordInUse => VaultError::PasswordInUse,
            cs_vault::Error::EmptyName => VaultError::EmptyName,
            cs_vault::Error::BadPin => VaultError::BadPin,
            cs_vault::Error::PinInUse => VaultError::PinInUse,
            cs_vault::Error::WrongSecretKey => VaultError::WrongSecretKey,
            cs_vault::Error::BadBackup => VaultError::BadBackup,
            cs_vault::Error::LibraryExists => VaultError::LibraryExists,
            cs_vault::Error::Crypto(cs_crypto::Error::KdfTooWeak) => VaultError::WeakKdf,
            _ => VaultError::Storage,
        }
    }
}

// The shipping app never opens a library below the phone floor: fails to build if the
// tests-only `test-kdf` feature of cs-crypto ever reaches it.
const _: () = assert!(
    KdfParams::ACCEPTED_FLOOR.m_kib == KdfParams::PHONE_FLOOR.m_kib
        && KdfParams::ACCEPTED_FLOOR.t == KdfParams::PHONE_FLOOR.t
);

/// Argon2id cost for a library created on this device (ADR 0001 floors).
fn params_for_this_device() -> KdfParams {
    if cfg!(any(target_os = "android", target_os = "ios")) {
        KdfParams::PHONE_FLOOR
    } else {
        KdfParams::DESKTOP_FLOOR
    }
}

/// A library of this run (api/run.rs), created if absent, with its Secret Key.
fn library(dir: &str) -> Result<Library, VaultError> {
    let dir = super::run::library_dir(dir)?;
    Ok(Library::open_or_create(
        dir,
        params_for_this_device(),
        secret(dir)?,
    )?)
}

/// The library the open vault is in: what a change to the open vault (its password, its
/// words) uses, whatever folder the screen named, so a vault is never re-wrapped under
/// another library's key.
fn open_library() -> Result<Library, VaultError> {
    let dir = open_library_dir()?;
    Ok(Library::open_or_create(
        &dir,
        params_for_this_device(),
        secret(&dir)?,
    )?)
}

fn open_library_dir() -> Result<PathBuf, VaultError> {
    with_open(|v| library_of(v).ok_or(VaultError::Storage))
}

/// `<library>/vaults/<id>` → `<library>`.
fn library_of(v: &OpenVault) -> Option<PathBuf> {
    v.dir()
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

/// This run's libraries holding a vault, with their Secret Keys: what "which vault
/// opens" looks through.
fn libraries_with_vaults() -> Vec<(PathBuf, SecretKey)> {
    let keys = secrets();
    super::run::libraries()
        .into_iter()
        .filter(|d| Library::has_vaults(d))
        .filter_map(|d| keys.get(&d).cloned().map(|k| (d, k)))
        .collect()
}

/// The library holding the vault `vault_id`, among this run's.
fn library_holding(vault_id: &str) -> Result<PathBuf, VaultError> {
    super::run::libraries()
        .into_iter()
        .find(|d| Library::vault_slots(d).is_ok_and(|slots| slots.iter().any(|s| s.id == vault_id)))
        .ok_or(VaultError::Storage)
}

/// Whether any library of this run holds a vault (`dir`: the run's folder, checked).
#[flutter_rust_bridge::frb(sync)]
pub fn has_vaults(dir: String) -> bool {
    super::run::library_dir(&dir).is_ok()
        && super::run::libraries()
            .iter()
            .any(|d| Library::has_vaults(d))
}

/// Whether this library holds a vault (a new vault's own words, a restore beside others).
#[flutter_rust_bridge::frb(sync)]
pub fn library_has_vaults(dir: String) -> bool {
    super::run::library_dir(&dir).is_ok_and(Library::has_vaults)
}

/// 0 … 4 for the strength bars: an accepted password has `min_password_score()` or more
/// ([`password_problem`] says why one is refused).
#[flutter_rust_bridge::frb(sync)]
pub fn password_score(password: String) -> u8 {
    let password = Zeroizing::new(password);
    cs_vault::password_score(&password)
}

#[flutter_rust_bridge::frb(sync)]
pub fn min_password_score() -> u8 {
    cs_vault::MIN_PASSWORD_SCORE
}

/// A new vault password needs at least this many characters (and see
/// [`password_problem`]). Unlocking counts wrong passwords from 8 characters, the least
/// the earlier rule allowed (app/lib/screens/unlock.dart).
#[flutter_rust_bridge::frb(sync)]
pub fn min_password_length() -> u32 {
    cs_vault::MIN_PASSWORD_LEN as u32
}

/// Why a new password would be refused, to say so while it is typed.
pub enum PasswordProblem {
    None,
    TooShort,
    /// One of the most common passwords (maybe with a number or symbol added).
    Common,
    /// Too few different characters ("aaaaaaaaaaaa"), however long.
    Guessable,
}

/// What [`create_vault`] and [`set_password`] would say of this new password.
#[flutter_rust_bridge::frb(sync)]
pub fn password_problem(password: String) -> PasswordProblem {
    let password = Zeroizing::new(password);
    problem_of(cs_vault::check_new_password(&password))
}

fn problem_of(check: cs_vault::PasswordCheck) -> PasswordProblem {
    match check {
        cs_vault::PasswordCheck::Ok => PasswordProblem::None,
        cs_vault::PasswordCheck::TooShort => PasswordProblem::TooShort,
        cs_vault::PasswordCheck::Common => PasswordProblem::Common,
        cs_vault::PasswordCheck::TooFewChars => PasswordProblem::Guessable,
    }
}

/// A new or changed PIN needs at least this many digits.
#[flutter_rust_bridge::frb(sync)]
pub fn min_pin_length() -> u32 {
    cs_vault::pin::MIN_PIN_LEN as u32
}

/// Create a vault and leave it open. Runs Argon2id: call it off the UI thread (async).
pub fn create_vault(dir: String, name: String, password: String) -> Result<VaultInfo, VaultError> {
    let password = Zeroizing::new(password);
    let library = library(&dir)?;
    let vault = library.create_vault(&name, &password)?;
    set_open(vault)
}

/// Create a vault known by its icon and colour, opened by `password`, in its mode
/// (ADR 0007), and leave it open (the new-vault flow since the PIN went).
/// [`VaultError::RestartForMode`]: made, but this run cannot open it. Runs Argon2id: call
/// it off the UI thread.
pub fn create_vault_with_password(
    dir: String,
    icon: String,
    color: String,
    password: String,
    top_secret: bool,
) -> Result<VaultInfo, VaultError> {
    let password = Zeroizing::new(password);
    let library = library(&dir)?;
    let vault = library.create_vault_in_mode(&icon, &color, &password, top_secret)?;
    set_open(vault)
}

/// The test vault of Android test builds (lib/test_login.dart), opened by the fixed
/// [`test_vault_password`], left open. Runs Argon2id: call it off the UI thread.
pub fn create_test_vault(dir: String) -> Result<VaultInfo, VaultError> {
    let library = library(&dir)?;
    let vault = library.create_test_vault("bolt", "orange")?;
    set_open(vault)
}

/// The test vault's password: "1 to 9", typed by testers on their other devices.
#[flutter_rust_bridge::frb(sync)]
pub fn test_vault_password() -> String {
    cs_vault::TEST_VAULT_PASSWORD.to_owned()
}

/// Turn Top Secret Mode on or off for the open vault. The caller then ends the run
/// ([`super::run::end_run`]) and the app starts again.
pub fn set_top_secret(top_secret: bool) -> Result<VaultInfo, VaultError> {
    let info = change_open(|v| {
        v.set_top_secret(top_secret)?;
        Ok(info_of(v))
    })?;
    // The run ends here, not only when Dart asks: nothing more is decoded under the old
    // mode, whatever happens on the way to the restart.
    super::run::end_run();
    Ok(info)
}

/// Open the vault this password belongs to, in any library of this run (each costs one
/// Argon2id); `None` when no vault matches.
pub fn unlock(dir: String, password: String) -> Result<Option<VaultInfo>, VaultError> {
    let password = Zeroizing::new(password);
    super::run::library_dir(&dir)?;
    for (d, key) in libraries_with_vaults() {
        let library = Library::open_or_create(&d, params_for_this_device(), key)?;
        if let Some(v) = library.unlock(&password)? {
            return set_open(v).map(Some);
        }
    }
    Ok(None)
}

/// Whether `password` opens the vault that is open now: asked before its Recovery Key
/// is shown (owner 2026-10-24: Face ID alone was too little for that). Opens nothing.
pub fn check_password(dir: String, password: String) -> Result<bool, VaultError> {
    let password = Zeroizing::new(password);
    super::run::library_dir(&dir)?;
    let open_id = with_open(|v| Ok(v.id.clone()))?;
    Ok(open_library()?
        .unlock(&password)?
        .is_some_and(|v| v.id == open_id))
}

/// Whether a vault here has biometric unlock turned on (shows the button).
#[flutter_rust_bridge::frb(sync)]
pub fn has_biometric_unlock(dir: String) -> bool {
    super::run::library_dir(&dir).is_ok()
        && super::run::libraries()
            .iter()
            .any(|d| Library::has_biometric(d))
}

/// Forget biometric unlock for every vault here (the keystore lost its key).
pub fn forget_biometric_unlock(dir: String) -> Result<(), VaultError> {
    super::run::library_dir(&dir)?;
    for d in super::run::libraries() {
        Library::forget_biometric(&d)?;
    }
    Ok(())
}

/// Open the vault with the key the platform keystore released after Face ID / fingerprint.
pub fn unlock_with_biometric(dir: String, key: Vec<u8>) -> Result<Option<VaultInfo>, VaultError> {
    let key = Zeroizing::new(key);
    super::run::library_dir(&dir)?;
    let Ok(bytes) = <[u8; 32]>::try_from(key.as_slice()) else {
        return Ok(None);
    };
    let key = cs_crypto::Key::from_bytes(bytes);
    for d in super::run::libraries() {
        if let Some(v) = Library::unlock_biometric(&d, &key)? {
            return set_open(v).map(Some);
        }
    }
    Ok(None)
}

/// Turn on biometric unlock for the open vault (off for the others, in every library: one
/// vault per device opens with Face ID). Returns the key Dart stores behind biometrics; it
/// is useless without this device's vault files.
pub fn enable_biometric() -> Result<Vec<u8>, VaultError> {
    let own = open_library_dir()?;
    let key = change_open(|v| Ok(v.enable_biometric()?.as_bytes().to_vec()))?;
    for d in super::run::libraries() {
        if d != own {
            Library::forget_biometric(&d)?;
        }
    }
    Ok(key)
}

pub fn disable_biometric() -> Result<(), VaultError> {
    change_open(|v| Ok(v.disable_biometric()?))
}

#[flutter_rust_bridge::frb(sync)]
pub fn biometric_enabled() -> bool {
    OPEN.glance().is_some_and(|g| g.biometric)
}

/// The Secret Key of the library in `dir`.
pub(crate) fn secret(dir: &Path) -> Result<SecretKey, VaultError> {
    secrets()
        .get(dir)
        .cloned()
        .ok_or(VaultError::WrongSecretKey)
}

/// Whether `password` opens `vault` itself, through its own library: the password a
/// device typed after scanning this one's invite (ADR 0003, point 11). Runs Argon2id;
/// opens nothing that is kept.
pub(crate) fn password_opens(vault: &OpenVault, password: &str) -> bool {
    let Some(dir) = library_of(vault) else {
        return false;
    };
    let Ok(key) = secret(&dir) else {
        return false;
    };
    Library::open_or_create(&dir, params_for_this_device(), key)
        .and_then(|l| l.unlock(password))
        .is_ok_and(|v| v.is_some_and(|v| v.id == vault.id))
}

/// The Secret Key of the open vault's library.
pub(crate) fn open_secret() -> Result<SecretKey, VaultError> {
    secret(&open_library_dir()?)
}

/// A key from the keystore: 32 bytes, or 16 for one made before 2026-10-21.
fn key_from(bytes: &[u8]) -> Option<SecretKey> {
    SecretKey::from_slice(bytes)
}

/// With no vault in this library, let the next one start it with a new Secret Key (an
/// old 128-bit key cannot be shown as 24 words); a library beside the run's folder goes
/// altogether. False while any vault is in it. Dart then forgets its key.
pub fn reset_empty_library(dir: String) -> Result<bool, VaultError> {
    let path = super::run::library_dir(&dir)?;
    if !Library::reset_if_empty(path)? {
        return Ok(false);
    }
    if super::run::libraries().first().map(PathBuf::as_path) != Some(path) {
        match std::fs::remove_dir_all(path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(VaultError::Storage),
        }
    }
    secrets().remove(path);
    Ok(true)
}

/// Move this device's library to `new_key` (a new Recovery Key) with the password of
/// every vault here that opens by password (they share the key; the open vault's first).
/// Nothing is lost if the app stops before [`finish_secret_key_change`]: the old key
/// still opens them.
pub fn change_secret_key(
    dir: String,
    passwords: Vec<String>,
    new_key: Vec<u8>,
) -> Result<KeyChangeResult, VaultError> {
    let passwords: Vec<Zeroizing<String>> = passwords.into_iter().map(Zeroizing::new).collect();
    let refs: Vec<&str> = passwords.iter().map(|p| p.as_str()).collect();
    let new_key = Zeroizing::new(new_key);
    let new_key = key_from(&new_key).ok_or(VaultError::Storage)?;
    // Every failure names itself in the debug log (owner 2026-10-25: "it did not change"
    // told nothing).
    let logged = |e: cs_vault::Error| {
        debug_line(|| format!("key change: {e}"));
        VaultError::from(e)
    };
    super::run::library_dir(&dir)?;
    let own = open_library_dir()?;
    let secret =
        secret(&own).inspect_err(|_| debug_line(|| "key change: no Recovery Key in use".into()))?;
    let library =
        Library::open_or_create(&own, params_for_this_device(), secret).map_err(logged)?;
    let change = library
        .change_secret_key_all(&refs, &new_key)
        .map_err(logged)?;
    debug_line(|| format!("key change: {change:?} ({} password(s))", refs.len()));
    Ok(match change {
        cs_vault::KeyChange::Changed => KeyChangeResult {
            step: KeyChangeStep::Changed,
        },
        cs_vault::KeyChange::WrongPassword => KeyChangeResult {
            step: KeyChangeStep::WrongPassword,
        },
        cs_vault::KeyChange::OthersNeeded(_) => KeyChangeResult {
            step: KeyChangeStep::OtherVault,
        },
    })
}

/// What came of [`change_secret_key`].
pub enum KeyChangeStep {
    Changed,
    /// A password given opens no vault here.
    WrongPassword,
    /// Another vault here shares the key: its password is needed too (how many is not
    /// said, so the screen does not tell who holds the phone how many vaults it has).
    OtherVault,
}

pub struct KeyChangeResult {
    pub step: KeyChangeStep,
}

/// The new key is in the keystore (under the library `dir`, the open vault's): use it
/// from now on, which also drops the old one from the library (it opens nothing there any
/// more).
pub fn finish_secret_key_change(dir: String, new_key: Vec<u8>) -> Result<(), VaultError> {
    let new_key = Zeroizing::new(new_key);
    let key = key_from(&new_key).ok_or(VaultError::Storage)?;
    let dir = super::run::library_dir(&dir)?.to_path_buf();
    Library::open_or_create(&dir, params_for_this_device(), key.clone()).map_err(|e| {
        debug_line(|| format!("key change finish: {e}"));
        VaultError::from(e)
    })?;
    secrets().insert(dir, key);
    Ok(())
}

/// The run ended: drop every library's key held here.
#[flutter_rust_bridge::frb(sync)]
pub fn forget_secret_key() {
    secrets().clear();
}

/// Use `key` for the library in `dir` (a restore just made it).
pub(crate) fn use_secret(dir: &Path, key: SecretKey) {
    secrets().insert(dir.to_path_buf(), key);
}

/// A new random Secret Key, for the first vault on a device.
#[flutter_rust_bridge::frb(sync)]
pub fn new_secret_key() -> Vec<u8> {
    SecretKey::generate().as_bytes().to_vec()
}

/// Use this Secret Key for the library in `dir` from now on (read from the keystore at
/// start). False if malformed, or `dir` is not one of this run's libraries.
#[flutter_rust_bridge::frb(sync)]
pub fn set_secret_key(dir: String, key: Vec<u8>) -> bool {
    let key = Zeroizing::new(key);
    let Ok(dir) = super::run::library_dir(&dir) else {
        return false;
    };
    match key_from(&key) {
        Some(sk) => {
            use_secret(dir, sk);
            true
        }
        None => false,
    }
}

/// The Emergency Kit form: CS1-XXXX-…
#[flutter_rust_bridge::frb(sync)]
pub fn secret_key_text(key: Vec<u8>) -> String {
    let key = Zeroizing::new(key);
    key_from(&key)
        .map(|k| k.to_text().to_string())
        .unwrap_or_default()
}

/// The 2048 words of the Recovery Key list (BIP39 English), for the typing grid.
#[flutter_rust_bridge::frb(sync)]
pub fn recovery_word_list() -> Vec<String> {
    cs_crypto::recovery_word_list()
        .into_iter()
        .map(String::from)
        .collect()
}

/// Read a Secret Key typed from an Emergency Kit; None when it has a typo.
#[flutter_rust_bridge::frb(sync)]
pub fn parse_secret_key(text: String) -> Option<Vec<u8>> {
    let text = Zeroizing::new(text);
    SecretKey::from_text(&text).map(|k| k.as_bytes().to_vec())
}

/// Whether this Secret Key belongs to the library in `dir`.
#[flutter_rust_bridge::frb(sync)]
pub fn secret_key_fits(dir: String, key: Vec<u8>) -> bool {
    let key = Zeroizing::new(key);
    super::run::library_dir(&dir)
        .is_ok_and(|d| key_from(&key).is_some_and(|k| Library::secret_key_fits(d, &k)))
}

/// Secret Key from a first-preview install (a file), to move into the keystore.
pub fn legacy_secret_key(dir: String) -> Result<Option<Vec<u8>>, VaultError> {
    Ok(Library::legacy_secret_key(super::run::library_dir(&dir)?)?.map(|k| k.as_bytes().to_vec()))
}

/// Wipe the first-preview file once the keystore holds the key.
pub fn forget_legacy_secret_key(dir: String) -> Result<(), VaultError> {
    Ok(Library::forget_legacy_secret_key(super::run::library_dir(
        &dir,
    )?)?)
}

/// Write a backup of the library `dir` (every vault sharing its 24 words) to `path`.
/// Returns the number of files.
pub fn export_backup(dir: String, path: String) -> Result<u32, VaultError> {
    let dir = super::run::library_dir(&dir)?;
    let tmp = format!("{path}.part");
    let result = std::fs::File::create(&tmp)
        .map_err(cs_vault::Error::from)
        .and_then(|f| cs_vault::backup::export(dir, f));
    match result {
        Ok(n) => {
            std::fs::rename(&tmp, &path).map_err(|_| VaultError::Storage)?;
            Ok(n)
        }
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e.into())
        }
    }
}

/// Restore a backup file into `dir` (which must have no library yet).
pub fn import_backup(path: String, dir: String) -> Result<u32, VaultError> {
    let f = std::fs::File::open(&path).map_err(|_| VaultError::BadBackup)?;
    Ok(cs_vault::backup::import(f, super::run::library_dir(&dir)?)?)
}

/// Digits of the PIN set on this device (for the dots), 0 when there is none.
#[flutter_rust_bridge::frb(sync)]
pub fn pin_length(dir: String) -> u32 {
    if super::run::library_dir(&dir).is_err() {
        return 0;
    }
    super::run::libraries()
        .iter()
        .find_map(|d| Library::pin_length(d))
        .unwrap_or(0) as u32
}

/// Open the vault with the PIN; `None` for a wrong PIN. `device_key` comes from the keystore.
pub fn unlock_with_pin(
    dir: String,
    pin: String,
    device_key: Vec<u8>,
) -> Result<Option<VaultInfo>, VaultError> {
    let pin = Zeroizing::new(pin);
    let device_key = Zeroizing::new(device_key);
    let Some(dk) = key_from(&device_key) else {
        return Ok(None);
    };
    super::run::library_dir(&dir)?;
    for d in super::run::libraries() {
        if let Some(v) = Library::unlock_pin(&d, &pin, &dk)? {
            return set_open(v).map(Some);
        }
    }
    Ok(None)
}

/// Set the PIN for the open vault (replaces any PIN on this device).
pub fn enable_pin(pin: String, device_key: Vec<u8>) -> Result<(), VaultError> {
    let pin = Zeroizing::new(pin);
    let device_key = Zeroizing::new(device_key);
    let dk = key_from(&device_key).ok_or(VaultError::Storage)?;
    change_open(|v| Ok(v.enable_pin(&pin, &dk, params_for_this_device())?))
}

pub fn disable_pin() -> Result<(), VaultError> {
    change_open(|v| Ok(v.disable_pin()?))
}

#[flutter_rust_bridge::frb(sync)]
pub fn pin_enabled() -> bool {
    OPEN.glance().is_some_and(|g| g.pin)
}

/// Remove the PIN on this device (too many wrong tries).
pub fn forget_pin(dir: String) -> Result<(), VaultError> {
    super::run::library_dir(&dir)?;
    for d in super::run::libraries() {
        Library::forget_pin(&d)?;
    }
    Ok(())
}

/// Remove the PIN of every vault here that opens with a password (the app no longer
/// offers a PIN, decisions 2026-10-28). A PIN-only vault keeps it until it gets a
/// password. Returns how many were removed.
#[flutter_rust_bridge::frb(sync)]
pub fn forget_pins_with_password(dir: String) -> Result<u32, VaultError> {
    super::run::library_dir(&dir)?;
    let mut n = 0;
    for d in super::run::libraries() {
        n += Library::forget_pins_with_password(&d)?;
    }
    Ok(n as u32)
}

/// Create a vault that starts with only a PIN on this device (no password yet) and
/// leave it open. Runs Argon2id: call it off the UI thread.
pub fn create_vault_with_pin(
    dir: String,
    icon: String,
    color: String,
    pin: String,
    device_key: Vec<u8>,
) -> Result<VaultInfo, VaultError> {
    let pin = Zeroizing::new(pin);
    let device_key = Zeroizing::new(device_key);
    let dk = key_from(&device_key).ok_or(VaultError::Storage)?;
    let library = library(&dir)?;
    let vault =
        library.create_vault_with_pin(&icon, &color, &pin, &dk, params_for_this_device())?;
    set_open(vault)
}

/// Set or change the open vault's password (instant: re-wraps the vault key, under its
/// own library's).
pub fn set_password(dir: String, password: String) -> Result<VaultInfo, VaultError> {
    let password = Zeroizing::new(password);
    super::run::library_dir(&dir)?;
    let library = open_library()?;
    change_open(|vault| {
        library.set_password(vault, &password)?;
        Ok(info_of(vault))
    })
}

/// Change the open vault's icon and colour.
pub fn set_identity(icon: String, color: String) -> Result<VaultInfo, VaultError> {
    change_open(|vault| {
        vault.set_identity(&icon, &color)?;
        Ok(info_of(vault))
    })
}

/// Whether any vault here opens with a password (show "Use password" on the lock screen).
#[flutter_rust_bridge::frb(sync)]
pub fn any_password(dir: String) -> bool {
    super::run::library_dir(&dir).is_ok()
        && super::run::libraries()
            .iter()
            .any(|d| Library::any_password(d))
}

/// PIN lengths in use on this device, shortest first (the pad checks at each).
#[flutter_rust_bridge::frb(sync)]
pub fn pin_lengths(dir: String) -> Vec<u32> {
    if super::run::library_dir(&dir).is_err() {
        return Vec::new();
    }
    let mut all: Vec<u32> = super::run::libraries()
        .iter()
        .flat_map(|d| Library::pin_lengths(d))
        .map(|n| n as u32)
        .collect();
    all.sort_unstable();
    all.dedup();
    all
}

fn info_of(vault: &OpenVault) -> VaultInfo {
    VaultInfo {
        library_dir: library_of(vault)
            .map(|d| d.to_string_lossy().into_owned())
            .unwrap_or_default(),
        id: vault.id.clone(),
        name: vault.name.clone(),
        icon: vault.icon.clone(),
        color: vault.color.clone(),
        has_password: vault.has_password(),
        top_secret: vault.top_secret,
    }
}

/// Close the open vault and wipe its keys. A sync running with it keeps it, out of the
/// UI's reach, until the sync ends; then it is wiped too.
#[flutter_rust_bridge::frb(sync)]
pub fn lock() {
    OPEN.clear();
}

/// The vault open now, if any (e.g. right after a restore from another device).
#[flutter_rust_bridge::frb(sync)]
pub fn open_vault_info() -> Option<VaultInfo> {
    OPEN.glance().map(|g| g.info)
}

/// The vault just opened becomes the open one (the one a sync still holds, if the same),
/// when this run may open it in its mode ([`super::run::vault_opening`]); otherwise it is
/// dropped (keys wiped) and [`VaultError::RestartForMode`]. Opening it with its password,
/// Face ID or PIN keeps it: a deletion set for it is dropped.
pub(crate) fn set_open(vault: OpenVault) -> Result<VaultInfo, VaultError> {
    // Opened with its password, Face ID or PIN: its deletion is dropped first, so a
    // failure here leaves the run as it was.
    if let Some(library) = vault.dir().parent().and_then(std::path::Path::parent) {
        if Library::delete_at(library, &vault.id).is_some() {
            Library::cancel_delete(library, &vault.id)?;
            debug_line(|| "vault opened: its deletion is cancelled".into());
        }
    }
    super::run::vault_opening(vault.top_secret)?;
    Ok(OPEN.put(vault).info)
}

/// An item as the vault shows it. Content and preview are fetched separately.
/// Names follow docs/naming.md.
pub struct ItemInfo {
    pub id: String,
    /// "photo", "video", "note", "audio", "file" or "tag" (cs_vault::items::kind).
    pub kind: String,
    pub name: String,
    pub mime: String,
    pub created_ms: i64,
    /// Content size in bytes.
    pub size_bytes: u64,
    /// When it went to Recently deleted; None for items in the vault.
    pub deleted_ms: Option<i64>,
    /// Length of a video or a recording, when known.
    pub duration_ms: Option<i64>,
    /// Ids of the tags it carries; empty for tags.
    pub tag_ids: Vec<String>,
    /// Marked as a favourite.
    pub is_favorite: bool,
    /// Last change (content, name, groups…); the creation time if never changed.
    pub modified_ms: i64,
}

impl From<ItemMeta> for ItemInfo {
    fn from(m: ItemMeta) -> Self {
        ItemInfo {
            id: m.id,
            kind: m.kind,
            name: m.name,
            mime: m.mime,
            created_ms: m.created_ms,
            size_bytes: m.size_bytes,
            deleted_ms: m.deleted_ms,
            duration_ms: m.duration_ms,
            tag_ids: m.tag_ids,
            is_favorite: m.is_favorite,
            modified_ms: m.modified_ms,
        }
    }
}

pub enum FrameFormat {
    Bgra8888,
    Yuv420,
}

pub struct FramePlane {
    pub bytes: Vec<u8>,
    pub bytes_per_row: u32,
    pub bytes_per_pixel: u32,
}

/// A raw frame from the camera preview stream, still in memory.
pub struct CameraFrame {
    pub width: u32,
    pub height: u32,
    pub format: FrameFormat,
    pub planes: Vec<FramePlane>,
    /// Clockwise degrees that turn the frame upright.
    pub rotation: u32,
}

pub(crate) fn with_open<T>(
    f: impl FnOnce(&OpenVault) -> Result<T, VaultError>,
) -> Result<T, VaultError> {
    OPEN.with(f).unwrap_or(Err(VaultError::Locked))
}

/// [`with_open`] for a call that only reads (open, preview, list): it does not wait for a
/// sync working with the vault (owner 2026-11-01: a note stayed on its spinner while
/// Drive uploaded two videos).
pub(crate) fn read_open<T>(
    f: impl FnOnce(&OpenVault) -> Result<T, VaultError>,
) -> Result<T, VaultError> {
    OPEN.read(f).unwrap_or(Err(VaultError::Locked))
}

/// [`with_open`] for a change the lock screen or settings show (PIN, Face ID, password,
/// icon): what they read without waiting is brought up to date.
fn change_open<T>(
    f: impl FnOnce(&mut OpenVault) -> Result<T, VaultError>,
) -> Result<T, VaultError> {
    OPEN.change(f).unwrap_or(Err(VaultError::Locked))
}

/// Encode a camera frame to JPEG in memory and store it encrypted. No file ever holds the
/// plaintext image. Runs off the UI thread.
pub fn add_photo(
    frame: CameraFrame,
    name: String,
    created_ms: i64,
) -> Result<ItemInfo, VaultError> {
    let planes = frame
        .planes
        .iter()
        .map(|p| cs_photo::Plane {
            bytes: &p.bytes,
            bytes_per_row: p.bytes_per_row as usize,
            bytes_per_pixel: p.bytes_per_pixel as usize,
        })
        .collect();
    let photo = cs_photo::encode(&cs_photo::Frame {
        width: frame.width as usize,
        height: frame.height as usize,
        format: match frame.format {
            FrameFormat::Bgra8888 => cs_photo::Format::Bgra8888,
            FrameFormat::Yuv420 => cs_photo::Format::Yuv420,
        },
        planes,
        rotation: frame.rotation,
    })
    .map_err(|_| VaultError::Storage)?;
    let jpeg = Zeroizing::new(photo.jpeg);
    let thumb = Zeroizing::new(photo.thumbnail);
    with_open(|v| {
        Ok(v.add_item(NewItem {
            kind: cs_vault::items::kind::PHOTO,
            name: &name,
            mime: "image/jpeg",
            created_ms,
            content: jpeg.as_slice(),
            thumbnail: Some(&thumb),
        })?
        .into())
    })
}

/// Encrypt a file from disk into the open vault, streaming (any size). `thumbnail` is a
/// small JPEG/PNG preview made by the app for images, or None. The caller deletes its
/// own temporary copies (picker caches) afterwards.
fn thumb_bytes(thumbnail: Option<Vec<u8>>) -> Option<Zeroizing<Vec<u8>>> {
    thumbnail.map(Zeroizing::new)
}

pub fn add_file(
    path: String,
    kind: String,
    name: String,
    mime: String,
    created_ms: i64,
    thumbnail: Option<Vec<u8>>,
) -> Result<ItemInfo, VaultError> {
    if thumbnail.is_some() {
        // A preview made from outside data means it was decoded.
        super::run::refuse_in_top_secret("thumbnail from outside")?;
    }
    let f = std::fs::File::open(&path).map_err(|_| VaultError::Storage)?;
    let thumb = thumb_bytes(thumbnail);
    let waited = std::time::Instant::now();
    with_open(|v| {
        let wait_ms = waited.elapsed().as_millis();
        let (meta, t) = v.add_item_timed(NewItem {
            kind: &kind,
            name: &name,
            mime: &mime,
            created_ms,
            content: std::io::BufReader::new(f),
            thumbnail: thumb.as_deref().map(|t| t.as_slice()),
        })?;
        debug_line(|| {
            format!(
                "rust add_file {kind} {} KB: wait {wait_ms} ms · encrypt {} · sync {} · thumb {} · record {} ms",
                meta.size_bytes / 1024,
                t.encrypt_ms,
                t.sync_ms,
                t.thumbnail_ms,
                t.record_ms
            )
        });
        Ok(meta.into())
    })
}

/// A new note; `title` is what the list shows (the app passes the first line).
pub fn add_note(title: String, text: String, created_ms: i64) -> Result<ItemInfo, VaultError> {
    let text = Zeroizing::new(text);
    with_open(|v| {
        Ok(v.add_item(NewItem {
            kind: cs_vault::items::kind::NOTE,
            name: &title,
            mime: "text/plain",
            created_ms,
            content: text.as_bytes(),
            thumbnail: None,
        })?
        .into())
    })
}

/// Save an edited note in place.
pub fn update_note(id: String, title: String, text: String) -> Result<ItemInfo, VaultError> {
    let text = Zeroizing::new(text);
    with_open(|v| Ok(v.replace_item(&id, &title, text.as_bytes())?.into()))
}

/// Decrypt an item to `path` (a private temporary file), to open it in another app.
/// The caller deletes it afterwards.
pub fn export_item(id: String, path: String) -> Result<(), VaultError> {
    read_open(|v| {
        let f = std::fs::File::create(&path).map_err(|_| VaultError::Storage)?;
        let mut w = std::io::BufWriter::new(f);
        let r = v.read_item(&id, &mut w);
        if r.is_err() {
            drop(w);
            let _ = std::fs::remove_file(&path);
        }
        r?;
        Ok(())
    })
}

/// "Suggest a password": five random words (about 64 bits).
#[flutter_rust_bridge::frb(sync)]
pub fn suggest_passphrase() -> String {
    cs_vault::passphrase::suggest(cs_vault::passphrase::SUGGESTED_WORDS)
}

/// Items in the open vault, newest first.
pub fn list_items() -> Result<Vec<ItemInfo>, VaultError> {
    let waited = std::time::Instant::now();
    read_open(|v| {
        let wait_ms = waited.elapsed().as_millis();
        let start = std::time::Instant::now();
        let items: Vec<ItemInfo> = v.items()?.into_iter().map(Into::into).collect();
        debug_line(|| {
            format!(
                "rust list_items {}: wait {wait_ms} ms · read {} ms",
                items.len(),
                start.elapsed().as_millis()
            )
        });
        Ok(items)
    })
}

/// Decrypted preview (JPEG), empty when the item has none.
pub fn item_thumbnail(id: String) -> Result<Vec<u8>, VaultError> {
    super::run::refuse_in_top_secret("thumbnail")?;
    read_open(|v| Ok(v.read_thumbnail(&id)?.unwrap_or_default()))
}

/// Decrypted content. Kept in memory only; Dart shows it and drops it.
pub fn item_content(id: String) -> Result<Vec<u8>, VaultError> {
    read_open(|v| {
        readable_in_app(v, &id)?;
        let mut out = Vec::new();
        v.read_item(&id, &mut out)?;
        Ok(out)
    })
}

/// At most the first `max` bytes of an item, decrypting only as far as needed, so a
/// text preview of a huge file never holds the whole file in memory.
pub fn item_content_head(id: String, max: u32) -> Result<Vec<u8>, VaultError> {
    /// Collects up to `max` bytes, then stops the decryption by refusing more.
    struct Head {
        buf: Vec<u8>,
        max: usize,
    }
    impl std::io::Write for Head {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            let room = self.max - self.buf.len();
            self.buf.extend_from_slice(&b[..b.len().min(room)]);
            if self.buf.len() >= self.max {
                return Err(std::io::Error::other("enough"));
            }
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    read_open(|v| {
        readable_in_app(v, &id)?;
        let mut head = Head {
            buf: Vec::new(),
            max: max as usize,
        };
        match v.read_item(&id, &mut head) {
            Ok(_) => Ok(head.buf),
            // Stopped on purpose once full: every chunk read so far was authenticated.
            Err(_) if head.buf.len() >= head.max => Ok(head.buf),
            Err(e) => Err(e.into()),
        }
    })
}

/// Top Secret Mode (ADR 0006): only notes are read into the app; anything else leaves
/// the vault by [`export_item`] alone, to be opened in another app.
/// A plain text file's text, for the plain text page; in Top Secret Mode too, where it is
/// the only file content handed over, and only when every check in [`crate::plain_text`]
/// passes: a file named as plain text, at most 1 MB, valid UTF-8 without control
/// characters. Anything else is refused, as for any file in that mode.
pub fn item_plain_text(id: String) -> Result<String, VaultError> {
    /// Collects up to one byte past the limit, then stops the decryption. Wiped when
    /// dropped.
    struct Capped(Zeroizing<Vec<u8>>);
    impl std::io::Write for Capped {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            let room = crate::plain_text::MAX + 1 - self.0.len();
            self.0.extend_from_slice(&b[..b.len().min(room)]);
            if self.0.len() > crate::plain_text::MAX {
                return Err(std::io::Error::other("too big"));
            }
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    read_open(|v| {
        let r = v.record(&id)?;
        if r.kind != cs_vault::items::kind::FILE
            || !crate::plain_text::allowed_name(&r.name)
            || r.size_bytes > crate::plain_text::MAX as u64
        {
            debug_line(|| "plain text refused: not a small text file".into());
            return Err(VaultError::Storage);
        }
        let mut out = Capped(Zeroizing::new(Vec::new()));
        if v.read_item(&id, &mut out).is_err() {
            return Err(VaultError::Storage);
        }
        crate::plain_text::checked(&out.0).ok_or_else(|| {
            debug_line(|| "plain text refused: not plain text".into());
            VaultError::Storage
        })
    })
}

fn readable_in_app(v: &OpenVault, id: &str) -> Result<(), VaultError> {
    if super::run::top_secret() && v.record(id)?.kind != cs_vault::items::kind::NOTE {
        return super::run::refuse_in_top_secret("content");
    }
    Ok(())
}

/// Delete for good (from Recently deleted).
pub fn delete_item(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.delete_item(&id)?))
}

/// A new tag (an item of kind "tag").
pub fn create_tag(name: String, created_ms: i64) -> Result<ItemInfo, VaultError> {
    with_open(|v| Ok(v.create_tag(&name, created_ms)?.into()))
}

pub fn rename_tag(tag_id: String, name: String) -> Result<ItemInfo, VaultError> {
    with_open(|v| Ok(v.rename_tag(&tag_id, &name)?.into()))
}

/// Put a tag on items (`tagged`) or take it off them.
pub fn set_tag(item_ids: Vec<String>, tag_id: String, tagged: bool) -> Result<(), VaultError> {
    with_open(|v| {
        for id in &item_ids {
            v.set_tag(id, &tag_id, tagged)?;
        }
        Ok(())
    })
}

/// Delete a tag; it comes off every item and no item is deleted.
pub fn delete_tag(tag_id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.delete_tag(&tag_id)?))
}

pub fn rename_item(id: String, name: String) -> Result<ItemInfo, VaultError> {
    with_open(|v| Ok(v.rename_item(&id, &name)?.into()))
}

/// Mark or unmark an item as a favourite.
pub fn set_item_favorite(id: String, is_favorite: bool) -> Result<(), VaultError> {
    with_open(|v| Ok(v.set_favorite(&id, is_favorite)?))
}

pub fn set_item_duration(id: String, duration_ms: i64) -> Result<(), VaultError> {
    with_open(|v| Ok(v.set_duration(&id, duration_ms)?))
}

/// Move to Recently deleted (kept 30 days, still encrypted).
pub fn trash_item(id: String, now_ms: i64) -> Result<(), VaultError> {
    with_open(|v| Ok(v.trash_item(&id, now_ms)?))
}

pub fn restore_item(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.restore_item(&id)?))
}

/// Recently deleted, most recently deleted first.
pub fn list_trash() -> Result<Vec<ItemInfo>, VaultError> {
    read_open(|v| Ok(v.trashed()?.into_iter().map(Into::into).collect()))
}

/// Items another device deleted for good, held here for 30 days (shown in Recently
/// deleted, marked, never synced). Their content and preview read like any item's.
pub fn list_held() -> Result<Vec<ItemInfo>, VaultError> {
    read_open(|v| Ok(v.held()?.into_iter().map(Into::into).collect()))
}

/// Bring a held item back here and, at the next sync, everywhere.
pub fn restore_held(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.restore_held(&id)?))
}

/// Delete a held item here for good now.
pub fn purge_held(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.purge_held(&id)?))
}

/// Delete for good what has been in Recently deleted for 30 days (run on opening).
pub fn purge_expired(now_ms: i64) -> Result<u32, VaultError> {
    with_open(|v| Ok(v.purge_expired(now_ms)? as u32))
}

/// A vault on this device as the Debug page lists it: names stay sealed until opened.
pub struct VaultSlot {
    /// The library folder it is in (api/run.rs).
    pub library_dir: String,
    pub id: String,
    /// Sealed files on this device, in bytes.
    pub size_bytes: u64,
    pub has_password: bool,
    pub has_pin: bool,
    pub has_biometric: bool,
    /// The vault open now.
    pub is_open: bool,
    /// When it will be deleted (ms since the epoch), when a deletion is set.
    pub delete_at_ms: Option<i64>,
    /// When it was made (or came) on this device, when the file system knows.
    pub created_ms: Option<i64>,
}

/// Every vault on this device, in every library (Vault manager, Debug).
pub fn list_vaults(dir: String) -> Result<Vec<VaultSlot>, VaultError> {
    super::run::library_dir(&dir)?;
    let open = OPEN.open_id();
    let mut all = Vec::new();
    for d in super::run::libraries() {
        let library = d.to_string_lossy().into_owned();
        for s in Library::vault_slots(&d)? {
            all.push(VaultSlot {
                library_dir: library.clone(),
                is_open: open.as_deref() == Some(s.id.as_str()),
                id: s.id,
                size_bytes: s.size_bytes,
                has_password: s.has_password,
                has_pin: s.has_pin,
                has_biometric: s.has_biometric,
                delete_at_ms: s.delete_at_ms,
                created_ms: s.created_ms,
            });
        }
    }
    Ok(all)
}

/// Whether `password` opens the vault `vault_id` (open or not), in whatever library it is:
/// asked before the countdown to delete it (owner 2026-11-01: the password first). Opens
/// nothing that is kept. Runs Argon2id: call it off the UI thread.
pub fn vault_password_opens(
    dir: String,
    vault_id: String,
    password: String,
) -> Result<bool, VaultError> {
    let password = Zeroizing::new(password);
    super::run::library_dir(&dir)?;
    let own = library_holding(&vault_id)?;
    let library = Library::open_or_create(&own, params_for_this_device(), secret(&own)?)?;
    Ok(library.unlock(&password)?.is_some_and(|v| v.id == vault_id))
}

/// Delete a vault that is not open, confirmed by its own password: the password must open
/// that very vault (it is opened only to check, never kept). False for any other password.
/// Runs Argon2id: call it off the UI thread.
pub fn delete_other_vault(
    dir: String,
    vault_id: String,
    password: String,
) -> Result<bool, VaultError> {
    let password = Zeroizing::new(password);
    super::run::library_dir(&dir)?;
    if OPEN.in_use(&vault_id) {
        return Ok(false);
    }
    let own = library_holding(&vault_id)?;
    let library = Library::open_or_create(&own, params_for_this_device(), secret(&own)?)?;
    match library.unlock(&password)? {
        Some(v) if v.id == vault_id => {
            v.destroy()?;
            Library::cancel_delete(&own, &vault_id)?;
            debug_line(|| "delete vault with its password: done".into());
            Ok(true)
        }
        _ => Ok(false),
    }
}

/// Set a vault whose password is forgotten to be deleted at `at_ms` (seven days on);
/// never the open one. The app asks the phone's owner first.
pub fn schedule_vault_delete(
    dir: String,
    vault_id: String,
    at_ms: i64,
) -> Result<bool, VaultError> {
    super::run::library_dir(&dir)?;
    if OPEN.in_use(&vault_id) {
        return Ok(false);
    }
    Library::schedule_delete(&library_holding(&vault_id)?, &vault_id, at_ms)?;
    debug_line(|| "vault set to be deleted".into());
    Ok(true)
}

/// Keep a vault set to be deleted.
pub fn cancel_vault_delete(dir: String, vault_id: String) -> Result<(), VaultError> {
    super::run::library_dir(&dir)?;
    Ok(Library::cancel_delete(
        &library_holding(&vault_id)?,
        &vault_id,
    )?)
}

/// Delete the vaults whose time has come (at start and on the vault list), never the open
/// one. How many went.
pub fn purge_due_vaults(dir: String, now_ms: i64) -> Result<u32, VaultError> {
    super::run::library_dir(&dir)?;
    let mut gone = Vec::new();
    for d in super::run::libraries() {
        gone.extend(Library::purge_due(&d, now_ms, &|id| OPEN.in_use(id))?);
    }
    if !gone.is_empty() {
        debug_line(|| format!("deleted {} vault(s) whose time came", gone.len()));
    }
    Ok(gone.len() as u32)
}

/// Delete a vault whose password and PIN are forgotten, without opening it; never the
/// open one. The app asks the phone's owner first (Face ID or the phone's passcode).
pub fn delete_vault_unopened(dir: String, vault_id: String) -> Result<bool, VaultError> {
    super::run::library_dir(&dir)?;
    if OPEN.in_use(&vault_id) {
        return Ok(false);
    }
    Library::destroy_unopened(&library_holding(&vault_id)?, &vault_id).map_err(|e| {
        debug_line(|| format!("delete unopened vault: {e}"));
        VaultError::from(e)
    })?;
    debug_line(|| "delete unopened vault: done".into());
    Ok(true)
}

/// Delete the open vault from this device, confirmed by its password: the password
/// must open this very vault. Locks it. Returns false (nothing deleted) for any other
/// password. Runs Argon2id: call it off the UI thread.
pub fn delete_vault(dir: String, password: String) -> Result<bool, VaultError> {
    let password = Zeroizing::new(password);
    super::run::library_dir(&dir)?;
    let open_id = with_open(|v| Ok(v.id.clone()))?;
    let library = open_library()?;
    match library.unlock(&password)? {
        Some(v) if v.id == open_id => {
            OPEN.clear();
            v.destroy()?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[cfg(test)]
mod tests {
    use super::super::run::{self, RunMode};
    use super::*;

    fn ok<T>(r: Result<T, VaultError>) -> T {
        r.unwrap_or_else(|_| panic!("vault call failed"))
    }

    /// The only test here that touches this run's state (RUN, SECRET, OPEN).
    #[test]
    fn each_set_of_words_has_its_own_library() {
        // In this crate's own build folder, not the shared temporary one.
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("test-libraries-{:08x}", cs_crypto::rand_u32()));
        std::fs::create_dir_all(&root).unwrap();
        let main = root.join("library").to_string_lossy().into_owned();
        assert!(run::start_run(RunMode::Everyday, main.clone()));
        let (pa, pb, pb2) = (
            suggest_passphrase(),
            suggest_passphrase(),
            suggest_passphrase(),
        );

        let k1 = new_secret_key();
        assert!(set_secret_key(main.clone(), k1.clone()));
        let a = ok(create_vault_with_password(
            main.clone(),
            "home".into(),
            "green".into(),
            pa.clone(),
            false,
        ));
        assert_eq!(a.library_dir, main);
        lock();

        let other = run::new_library_dir().unwrap();
        assert!(!set_secret_key(
            root.join("elsewhere").to_string_lossy().into_owned(),
            k1.clone()
        ));
        let k2 = new_secret_key();
        assert!(set_secret_key(other.clone(), k2.clone()));
        let b = ok(create_vault_with_password(
            main.clone(),
            "bolt".into(),
            "orange".into(),
            pb.clone(),
            false,
        ));
        // Made in the run's library: the folder named is the one used.
        assert_eq!(b.library_dir, main);
        lock();
        assert!(ok(delete_other_vault(main.clone(), b.id, pb.clone())));

        let b = ok(create_vault_with_password(
            other.clone(),
            "bolt".into(),
            "orange".into(),
            pb.clone(),
            false,
        ));
        assert_eq!(b.library_dir, other);
        // A change to the open vault uses its own library, whatever folder is named.
        ok(set_password(main.clone(), pb2.clone()));
        lock();
        assert_eq!(run::library_dirs(), vec![main.clone(), other.clone()]);

        // Unlocking looks in every library.
        assert_eq!(
            ok(unlock(main.clone(), pa.clone())).map(|v| v.id),
            Some(a.id.clone())
        );
        lock();
        let opened = ok(unlock(main.clone(), pb2.clone())).expect("opens");
        assert_eq!(
            (opened.id, opened.library_dir),
            (b.id.clone(), other.clone())
        );
        lock();
        assert!(
            ok(unlock(main.clone(), pb.clone())).is_none(),
            "the old password"
        );

        // Each set of words fits its own library only.
        assert!(secret_key_fits(other.clone(), k2.clone()));
        assert!(!secret_key_fits(main.clone(), k2.clone()));
        assert!(!secret_key_fits(other.clone(), k1.clone()));
        let slots = ok(list_vaults(main.clone()));
        assert_eq!(slots.len(), 2);
        assert!(slots.iter().any(|s| s.id == b.id && s.library_dir == other));

        // Each password checks its own vault only, wherever it is.
        assert!(ok(vault_password_opens(
            main.clone(),
            b.id.clone(),
            pb2.clone()
        )));
        assert!(!ok(vault_password_opens(
            main.clone(),
            b.id.clone(),
            pa.clone()
        )));
        assert!(ok(vault_password_opens(
            main.clone(),
            a.id.clone(),
            pa.clone()
        )));

        // Its last vault gone, a library beside the run's goes altogether; the run's stays.
        assert!(
            !ok(reset_empty_library(other.clone())),
            "not while it holds a vault"
        );
        assert!(ok(delete_other_vault(main.clone(), b.id, pb2)));
        assert!(ok(reset_empty_library(other.clone())));
        assert!(!Path::new(&other).exists());
        assert_eq!(run::library_dirs(), vec![main.clone()]);
        assert!(!ok(reset_empty_library(main)));

        run::end_run();
        let _ = std::fs::remove_dir_all(root);
    }
}
