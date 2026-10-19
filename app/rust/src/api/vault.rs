//! The only surface Flutter sees. Keys never cross it: Dart gets vault names and IDs,
//! never key material. The password has to come from a Dart text field; it is wiped
//! here as soon as it has been used.

use std::path::Path;
use std::sync::Mutex;

use cs_crypto::kdf::KdfParams;
use cs_vault::items::NewItem;
use cs_vault::{ItemMeta, Library, OpenVault};
use zeroize::Zeroizing;

/// The vault currently open, if any. One at a time by design.
static OPEN: Mutex<Option<OpenVault>> = Mutex::new(None);

pub struct VaultInfo {
    pub id: String,
    pub name: String,
}

/// Errors Dart shows to the user; each maps to a translated message.
pub enum VaultError {
    WeakPassword,
    PasswordInUse,
    EmptyName,
    /// No vault is open (it locked while the screen was up).
    Locked,
    Storage,
}

impl From<cs_vault::Error> for VaultError {
    fn from(e: cs_vault::Error) -> Self {
        match e {
            cs_vault::Error::WeakPassword => VaultError::WeakPassword,
            cs_vault::Error::PasswordInUse => VaultError::PasswordInUse,
            cs_vault::Error::EmptyName => VaultError::EmptyName,
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
    let library = Library::open_or_create(Path::new(&dir), params_for_this_device())?;
    let vault = library.create_vault(&name, &password)?;
    Ok(set_open(vault))
}

/// Open the vault this password belongs to; `None` when no vault matches.
pub fn unlock(dir: String, password: String) -> Result<Option<VaultInfo>, VaultError> {
    let password = Zeroizing::new(password);
    let library = Library::open_or_create(Path::new(&dir), params_for_this_device())?;
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

/// Close the open vault and wipe its keys.
#[flutter_rust_bridge::frb(sync)]
pub fn lock() {
    *OPEN.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

fn set_open(vault: OpenVault) -> VaultInfo {
    let info = VaultInfo {
        id: vault.id.clone(),
        name: vault.name.clone(),
    };
    *OPEN.lock().unwrap_or_else(|p| p.into_inner()) = Some(vault);
    info
}

/// An item as the vault grid shows it. Content and preview are fetched separately.
pub struct ItemInfo {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub created_ms: i64,
    pub size: u64,
}

impl From<ItemMeta> for ItemInfo {
    fn from(m: ItemMeta) -> Self {
        ItemInfo {
            id: m.id,
            kind: m.kind,
            name: m.name,
            created_ms: m.created_ms,
            size: m.size,
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

pub fn delete_item(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.delete_item(&id)?))
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
