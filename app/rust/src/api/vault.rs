//! The only surface Flutter sees. Keys never cross it: Dart gets vault names and IDs,
//! never key material. The password has to come from a Dart text field; it is wiped
//! here as soon as it has been used.

use std::path::Path;
use std::sync::Mutex;

use cs_crypto::kdf::KdfParams;
use cs_crypto::{SecretKey, SECRET_KEY_LEN};
use cs_vault::items::NewItem;
use cs_vault::{ItemMeta, Library, OpenVault};
use zeroize::Zeroizing;

/// The vault currently open, if any. One at a time by design.
static OPEN: Mutex<Option<OpenVault>> = Mutex::new(None);
/// This device's Secret Key, handed over by Dart from the platform keystore at start.
static SECRET: Mutex<Option<SecretKey>> = Mutex::new(None);

pub struct VaultInfo {
    pub id: String,
    pub name: String,
    /// Icon and colour ids from the app's sets (empty for vaults made before them).
    pub icon: String,
    pub color: String,
    pub has_password: bool,
}

/// Errors Dart shows to the user; each maps to a translated message.
pub enum VaultError {
    WeakPassword,
    PasswordInUse,
    EmptyName,
    /// A PIN has at least 4 digits.
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
    /// A folder cannot go inside itself or one of its subfolders.
    FolderLoop,
    Storage,
}

impl From<cs_vault::Error> for VaultError {
    fn from(e: cs_vault::Error) -> Self {
        match e {
            cs_vault::Error::WeakPassword => VaultError::WeakPassword,
            cs_vault::Error::PasswordInUse => VaultError::PasswordInUse,
            cs_vault::Error::EmptyName => VaultError::EmptyName,
            cs_vault::Error::BadPin => VaultError::BadPin,
            cs_vault::Error::PinInUse => VaultError::PinInUse,
            cs_vault::Error::WrongSecretKey => VaultError::WrongSecretKey,
            cs_vault::Error::BadBackup => VaultError::BadBackup,
            cs_vault::Error::LibraryExists => VaultError::LibraryExists,
            cs_vault::Error::FolderLoop => VaultError::FolderLoop,
            _ => VaultError::Storage,
        }
    }
}

/// Argon2id cost for a library created on this device (ADR 0001 floors).
fn params_for_this_device() -> KdfParams {
    if cfg!(any(target_os = "android", target_os = "ios")) {
        KdfParams::PHONE_FLOOR
    } else {
        KdfParams::DESKTOP_FLOOR
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn has_vaults(dir: String) -> bool {
    Library::has_vaults(Path::new(&dir))
}

/// 0 (trivial) … 4 (very strong); a vault needs at least `min_password_score()`.
#[flutter_rust_bridge::frb(sync)]
pub fn password_score(password: String) -> u8 {
    let password = Zeroizing::new(password);
    cs_vault::password_score(&password)
}

#[flutter_rust_bridge::frb(sync)]
pub fn min_password_score() -> u8 {
    cs_vault::MIN_PASSWORD_SCORE
}

/// Create a vault and leave it open. Runs Argon2id: call it off the UI thread (async).
pub fn create_vault(dir: String, name: String, password: String) -> Result<VaultInfo, VaultError> {
    let password = Zeroizing::new(password);
    let library = Library::open_or_create(Path::new(&dir), params_for_this_device(), secret()?)?;
    let vault = library.create_vault(&name, &password)?;
    Ok(set_open(vault))
}

/// Open the vault this password belongs to; `None` when no vault matches.
pub fn unlock(dir: String, password: String) -> Result<Option<VaultInfo>, VaultError> {
    let password = Zeroizing::new(password);
    let library = Library::open_or_create(Path::new(&dir), params_for_this_device(), secret()?)?;
    Ok(library.unlock(&password)?.map(set_open))
}

/// Whether a vault here has biometric unlock turned on (shows the button).
#[flutter_rust_bridge::frb(sync)]
pub fn has_biometric_unlock(dir: String) -> bool {
    Library::has_biometric(Path::new(&dir))
}

/// Forget biometric unlock for every vault here (the keystore lost its key).
pub fn forget_biometric_unlock(dir: String) -> Result<(), VaultError> {
    Ok(Library::forget_biometric(Path::new(&dir))?)
}

/// Open the vault with the key the platform keystore released after Face ID / fingerprint.
pub fn unlock_with_biometric(dir: String, key: Vec<u8>) -> Result<Option<VaultInfo>, VaultError> {
    let key = Zeroizing::new(key);
    let Ok(bytes) = <[u8; 32]>::try_from(key.as_slice()) else {
        return Ok(None);
    };
    let key = cs_crypto::Key::from_bytes(bytes);
    Ok(Library::unlock_biometric(Path::new(&dir), &key)?.map(set_open))
}

/// Turn on biometric unlock for the open vault (off for the others). Returns the key Dart
/// stores behind biometrics; it is useless without this device's vault files.
pub fn enable_biometric() -> Result<Vec<u8>, VaultError> {
    with_open(|v| Ok(v.enable_biometric()?.as_bytes().to_vec()))
}

pub fn disable_biometric() -> Result<(), VaultError> {
    with_open(|v| Ok(v.disable_biometric()?))
}

#[flutter_rust_bridge::frb(sync)]
pub fn biometric_enabled() -> bool {
    OPEN.lock()
        .unwrap_or_else(|p| p.into_inner())
        .as_ref()
        .is_some_and(|v| v.biometric_enabled())
}

fn secret() -> Result<SecretKey, VaultError> {
    SECRET
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
        .ok_or(VaultError::WrongSecretKey)
}

fn key16(bytes: &[u8]) -> Option<SecretKey> {
    <[u8; SECRET_KEY_LEN]>::try_from(bytes)
        .ok()
        .map(SecretKey::from_bytes)
}

/// A new random Secret Key, for the first vault on a device.
#[flutter_rust_bridge::frb(sync)]
pub fn new_secret_key() -> Vec<u8> {
    SecretKey::generate().as_bytes().to_vec()
}

/// Use this Secret Key from now on (read from the keystore at start). False if malformed.
#[flutter_rust_bridge::frb(sync)]
pub fn set_secret_key(key: Vec<u8>) -> bool {
    let key = Zeroizing::new(key);
    match key16(&key) {
        Some(sk) => {
            *SECRET.lock().unwrap_or_else(|p| p.into_inner()) = Some(sk);
            true
        }
        None => false,
    }
}

/// The Emergency Kit form: CS1-XXXX-…
#[flutter_rust_bridge::frb(sync)]
pub fn secret_key_text(key: Vec<u8>) -> String {
    let key = Zeroizing::new(key);
    key16(&key)
        .map(|k| k.to_text().to_string())
        .unwrap_or_default()
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
    key16(&key).is_some_and(|k| Library::secret_key_fits(Path::new(&dir), &k))
}

/// Secret Key from a first-preview install (a file), to move into the keystore.
pub fn legacy_secret_key(dir: String) -> Result<Option<Vec<u8>>, VaultError> {
    Ok(Library::legacy_secret_key(Path::new(&dir))?.map(|k| k.as_bytes().to_vec()))
}

/// Wipe the first-preview file once the keystore holds the key.
pub fn forget_legacy_secret_key(dir: String) -> Result<(), VaultError> {
    Ok(Library::forget_legacy_secret_key(Path::new(&dir))?)
}

/// Write a backup of the whole library to `path`. Returns the number of files.
pub fn export_backup(dir: String, path: String) -> Result<u32, VaultError> {
    let tmp = format!("{path}.part");
    let result = std::fs::File::create(&tmp)
        .map_err(cs_vault::Error::from)
        .and_then(|f| cs_vault::backup::export(Path::new(&dir), f));
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
    Ok(cs_vault::backup::import(f, Path::new(&dir))?)
}

/// Digits of the PIN set on this device (for the dots), 0 when there is none.
#[flutter_rust_bridge::frb(sync)]
pub fn pin_length(dir: String) -> u32 {
    Library::pin_length(Path::new(&dir)).unwrap_or(0) as u32
}

/// Open the vault with the PIN; `None` for a wrong PIN. `device_key` comes from the keystore.
pub fn unlock_with_pin(
    dir: String,
    pin: String,
    device_key: Vec<u8>,
) -> Result<Option<VaultInfo>, VaultError> {
    let pin = Zeroizing::new(pin);
    let device_key = Zeroizing::new(device_key);
    let Some(dk) = key16(&device_key) else {
        return Ok(None);
    };
    Ok(Library::unlock_pin(Path::new(&dir), &pin, &dk)?.map(set_open))
}

/// Set the PIN for the open vault (replaces any PIN on this device).
pub fn enable_pin(pin: String, device_key: Vec<u8>) -> Result<(), VaultError> {
    let pin = Zeroizing::new(pin);
    let device_key = Zeroizing::new(device_key);
    let dk = key16(&device_key).ok_or(VaultError::Storage)?;
    with_open(|v| Ok(v.enable_pin(&pin, &dk, params_for_this_device())?))
}

pub fn disable_pin() -> Result<(), VaultError> {
    with_open(|v| Ok(v.disable_pin()?))
}

#[flutter_rust_bridge::frb(sync)]
pub fn pin_enabled() -> bool {
    OPEN.lock()
        .unwrap_or_else(|p| p.into_inner())
        .as_ref()
        .is_some_and(|v| v.pin_enabled())
}

/// Remove the PIN on this device (too many wrong tries).
pub fn forget_pin(dir: String) -> Result<(), VaultError> {
    Ok(Library::forget_pin(Path::new(&dir))?)
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
    let dk = key16(&device_key).ok_or(VaultError::Storage)?;
    let library = Library::open_or_create(Path::new(&dir), params_for_this_device(), secret()?)?;
    let vault =
        library.create_vault_with_pin(&icon, &color, &pin, &dk, params_for_this_device())?;
    Ok(set_open(vault))
}

/// Set or change the open vault's password (instant: re-wraps the vault key).
pub fn set_password(dir: String, password: String) -> Result<VaultInfo, VaultError> {
    let password = Zeroizing::new(password);
    let library = Library::open_or_create(Path::new(&dir), params_for_this_device(), secret()?)?;
    let guard = OPEN.lock().unwrap_or_else(|p| p.into_inner());
    let vault = guard.as_ref().ok_or(VaultError::Locked)?;
    library.set_password(vault, &password)?;
    Ok(info_of(vault))
}

/// Change the open vault's icon and colour.
pub fn set_identity(icon: String, color: String) -> Result<VaultInfo, VaultError> {
    let mut guard = OPEN.lock().unwrap_or_else(|p| p.into_inner());
    let vault = guard.as_mut().ok_or(VaultError::Locked)?;
    vault.set_identity(&icon, &color)?;
    Ok(info_of(vault))
}

/// Whether any vault here opens with a password (show "Use password" on the lock screen).
#[flutter_rust_bridge::frb(sync)]
pub fn any_password(dir: String) -> bool {
    Library::any_password(Path::new(&dir))
}

/// PIN lengths in use on this device, shortest first (the pad checks at each).
#[flutter_rust_bridge::frb(sync)]
pub fn pin_lengths(dir: String) -> Vec<u32> {
    Library::pin_lengths(Path::new(&dir))
        .into_iter()
        .map(|n| n as u32)
        .collect()
}

fn info_of(vault: &OpenVault) -> VaultInfo {
    VaultInfo {
        id: vault.id.clone(),
        name: vault.name.clone(),
        icon: vault.icon.clone(),
        color: vault.color.clone(),
        has_password: vault.has_password(),
    }
}

/// Close the open vault and wipe its keys.
#[flutter_rust_bridge::frb(sync)]
pub fn lock() {
    *OPEN.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

fn set_open(vault: OpenVault) -> VaultInfo {
    let info = info_of(&vault);
    *OPEN.lock().unwrap_or_else(|p| p.into_inner()) = Some(vault);
    info
}

/// An item as the vault grid shows it. Content and preview are fetched separately.
pub struct ItemInfo {
    pub id: String,
    /// "photo", "note" or "file".
    pub kind: String,
    pub name: String,
    pub mime: String,
    pub created_ms: i64,
    pub size: u64,
    /// When it went to Recently deleted; None for items in the vault.
    pub deleted_ms: Option<i64>,
    /// Length of a video, when known.
    pub duration_ms: Option<i64>,
    /// The folder it is in; None at the top level.
    pub folder: Option<String>,
    /// A folder's colour id.
    pub color: Option<String>,
    /// What a folder holds: "note", "photo", "audio" or "file" (None: "file").
    pub space: Option<String>,
}

impl From<ItemMeta> for ItemInfo {
    fn from(m: ItemMeta) -> Self {
        ItemInfo {
            id: m.id,
            kind: m.kind,
            name: m.name,
            mime: m.mime,
            created_ms: m.created_ms,
            size: m.size,
            deleted_ms: m.deleted_ms,
            duration_ms: m.duration_ms,
            folder: m.folder,
            color: m.color,
            space: m.space,
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

fn with_open<T>(f: impl FnOnce(&OpenVault) -> Result<T, VaultError>) -> Result<T, VaultError> {
    let guard = OPEN.lock().unwrap_or_else(|p| p.into_inner());
    let vault = guard.as_ref().ok_or(VaultError::Locked)?;
    f(vault)
}

/// Encode a camera frame to JPEG in memory and store it encrypted. No file ever holds the
/// plaintext image. Runs off the UI thread.
pub fn add_photo(frame: CameraFrame, created_ms: i64) -> Result<ItemInfo, VaultError> {
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
            kind: "photo",
            name: "Photo.jpg",
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
pub fn add_file(
    path: String,
    kind: String,
    name: String,
    mime: String,
    created_ms: i64,
    thumbnail: Option<Vec<u8>>,
) -> Result<ItemInfo, VaultError> {
    let f = std::fs::File::open(&path).map_err(|_| VaultError::Storage)?;
    let thumb = thumbnail.map(Zeroizing::new);
    with_open(|v| {
        Ok(v.add_item(NewItem {
            kind: &kind,
            name: &name,
            mime: &mime,
            created_ms,
            content: std::io::BufReader::new(f),
            thumbnail: thumb.as_deref().map(|t| t.as_slice()),
        })?
        .into())
    })
}

/// A new note; `title` is what the list shows (the app passes the first line).
pub fn add_note(title: String, text: String, created_ms: i64) -> Result<ItemInfo, VaultError> {
    let text = Zeroizing::new(text);
    with_open(|v| {
        Ok(v.add_item(NewItem {
            kind: "note",
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
    with_open(|v| {
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
    with_open(|v| Ok(v.items()?.into_iter().map(Into::into).collect()))
}

/// Decrypted preview (JPEG), empty when the item has none.
pub fn item_thumbnail(id: String) -> Result<Vec<u8>, VaultError> {
    with_open(|v| Ok(v.read_thumbnail(&id)?.unwrap_or_default()))
}

/// Decrypted content. Kept in memory only; Dart shows it and drops it.
pub fn item_content(id: String) -> Result<Vec<u8>, VaultError> {
    with_open(|v| {
        let mut out = Vec::new();
        v.read_item(&id, &mut out)?;
        Ok(out)
    })
}

/// Delete for good (from Recently deleted).
pub fn delete_item(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.delete_item(&id)?))
}

/// A new folder (an item of kind "folder") inside `parent`, or at the top level.
pub fn create_folder(
    name: String,
    color: String,
    space: String,
    parent: Option<String>,
    created_ms: i64,
) -> Result<ItemInfo, VaultError> {
    with_open(|v| {
        Ok(v.create_folder(&name, &color, &space, parent.as_deref(), created_ms)?
            .into())
    })
}

pub fn update_folder(id: String, name: String, color: String) -> Result<ItemInfo, VaultError> {
    with_open(|v| Ok(v.update_folder(&id, &name, &color)?.into()))
}

/// Move items (and folders) into `folder`, or to the top level when None.
pub fn move_items(ids: Vec<String>, folder: Option<String>) -> Result<(), VaultError> {
    with_open(|v| {
        for id in &ids {
            v.move_item(id, folder.as_deref())?;
        }
        Ok(())
    })
}

/// Delete a folder; what it holds moves up to its parent.
pub fn delete_folder(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.delete_folder(&id)?))
}

pub fn rename_item(id: String, name: String) -> Result<ItemInfo, VaultError> {
    with_open(|v| Ok(v.rename_item(&id, &name)?.into()))
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
    with_open(|v| Ok(v.trashed()?.into_iter().map(Into::into).collect()))
}

/// Delete for good what has been in Recently deleted for 30 days (run on opening).
pub fn purge_expired(now_ms: i64) -> Result<u32, VaultError> {
    with_open(|v| Ok(v.purge_expired(now_ms)? as u32))
}

/// Delete the open vault from this device, confirmed by its PIN: the PIN must open
/// this very vault. Locks it. Returns false (nothing deleted) for any other PIN.
pub fn delete_vault(dir: String, pin: String, device_key: Vec<u8>) -> Result<bool, VaultError> {
    let pin = Zeroizing::new(pin);
    let device_key = Zeroizing::new(device_key);
    let Some(dk) = key16(&device_key) else {
        return Ok(false);
    };
    let open_id = with_open(|v| Ok(v.id.clone()))?;
    match Library::unlock_pin(Path::new(&dir), &pin, &dk)? {
        Some(v) if v.id == open_id => {
            *OPEN.lock().unwrap_or_else(|p| p.into_inner()) = None;
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
