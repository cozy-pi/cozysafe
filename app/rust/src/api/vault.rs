//! The only surface Flutter sees. Keys never cross it: Dart gets vault names and IDs,
//! never key material. The password has to come from a Dart text field; it is wiped
//! here as soon as it has been used.

use std::path::Path;
use std::sync::Mutex;

use cs_crypto::kdf::KdfParams;
use cs_vault::{Library, OpenVault};
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

/// Close the open vault and wipe its keys.
#[flutter_rust_bridge::frb(sync)]
pub fn lock() {
    *OPEN.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

fn set_open(vault: OpenVault) -> VaultInfo {
    let info = VaultInfo { id: vault.id.clone(), name: vault.name.clone() };
    *OPEN.lock().unwrap_or_else(|p| p.into_inner()) = Some(vault);
    info
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
