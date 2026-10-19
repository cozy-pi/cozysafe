//! PIN unlock for one vault on one device.
//!
//! The PIN alone is weak (10^4 to 10^10 values), so it never protects anything by
//! itself: the vault's Master Key is wrapped by a key derived with Argon2id from the
//! PIN *and* a random device key that lives only in this device's keystore (the app
//! passes it in). Copy the vault files elsewhere and the PIN is useless; take the
//! device key without the PIN and it is useless too. The app limits wrong tries and
//! calls [`Library::forget_pin`] when the limit is reached; the password still works.
//!
//! One vault per device has a PIN, like biometric unlock.

use std::fs;
use std::path::Path;

use cs_crypto::kdf::{self, KdfParams};
use cs_crypto::{generate_salt, wrap, SecretKey, SALT_LEN};
use serde::{Deserialize, Serialize};

use crate::{
    aad, decode_array, open_with, read_header, remove_if_exists, write_atomic, Error, Library,
    OpenVault, Result, VAULTS_DIR,
};

const PIN_FILE: &str = "pin";
pub const MIN_PIN_LEN: usize = 4;
pub const MAX_PIN_LEN: usize = 10;

#[derive(Serialize, Deserialize)]
struct PinFile {
    format: u32,
    salt: String,
    length: u8,
    m_kib: u32,
    t: u32,
    p: u32,
    wrapped_master_key: String,
}

fn valid(pin: &str) -> bool {
    (MIN_PIN_LEN..=MAX_PIN_LEN).contains(&pin.len()) && pin.bytes().all(|b| b.is_ascii_digit())
}

impl OpenVault {
    /// Set (or replace) this vault's PIN on this device; removes any other vault's PIN.
    pub fn enable_pin(&self, pin: &str, device_key: &SecretKey, params: KdfParams) -> Result<()> {
        if !valid(pin) {
            return Err(Error::BadPin);
        }
        if let Some(vaults) = self.dir.parent() {
            for entry in fs::read_dir(vaults)?.flatten() {
                remove_if_exists(&entry.path().join(PIN_FILE))?;
            }
        }
        let salt = generate_salt();
        let root = kdf::derive_root(pin.as_bytes(), device_key, &salt, params)?;
        let kek = kdf::vault_kek(&root, &salt);
        let file = PinFile {
            format: 1,
            salt: hex::encode(salt),
            length: pin.len() as u8,
            m_kib: params.m_kib,
            t: params.t,
            p: params.p,
            wrapped_master_key: hex::encode(wrap::wrap_key(
                &kek,
                &self.master_key,
                &aad(&self.id, "pin"),
            )),
        };
        write_atomic(
            &self.dir.join(PIN_FILE),
            &serde_json::to_vec(&file).expect("serialisable"),
        )
    }

    pub fn pin_enabled(&self) -> bool {
        self.dir.join(PIN_FILE).is_file()
    }

    pub fn disable_pin(&self) -> Result<()> {
        remove_if_exists(&self.dir.join(PIN_FILE))
    }
}

impl Library {
    /// Length of the PIN set on this device (to draw the dots), or `None`.
    pub fn pin_length(dir: &Path) -> Option<usize> {
        pin_files(dir)
            .into_iter()
            .next()
            .map(|(_, f)| f.length as usize)
    }

    /// Open the vault with this PIN. `Ok(None)` for a wrong PIN.
    pub fn unlock_pin(dir: &Path, pin: &str, device_key: &SecretKey) -> Result<Option<OpenVault>> {
        if !valid(pin) {
            return Ok(None);
        }
        for (vault_dir, file) in pin_files(dir) {
            let Some(id) = vault_dir
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
            else {
                continue;
            };
            let Some(header) = read_header(&vault_dir) else {
                continue;
            };
            let salt = decode_array::<SALT_LEN>(&file.salt, "pin salt")?;
            let params = KdfParams {
                m_kib: file.m_kib,
                t: file.t,
                p: file.p,
            };
            let root = kdf::derive_root(pin.as_bytes(), device_key, &salt, params)?;
            let kek = kdf::vault_kek(&root, &salt);
            let wrapped =
                hex::decode(&file.wrapped_master_key).map_err(|_| Error::Corrupt("pin"))?;
            if let Ok(mk) = wrap::unwrap_key(&kek, &wrapped, &aad(&id, "pin")) {
                return open_with(id, vault_dir, &header, mk).map(Some);
            }
        }
        Ok(None)
    }

    /// Remove every PIN on this device (too many wrong tries, or turned off).
    pub fn forget_pin(dir: &Path) -> Result<()> {
        if let Ok(entries) = fs::read_dir(dir.join(VAULTS_DIR)) {
            for e in entries.flatten() {
                remove_if_exists(&e.path().join(PIN_FILE))?;
            }
        }
        Ok(())
    }
}

fn pin_files(dir: &Path) -> Vec<(std::path::PathBuf, PinFile)> {
    let Ok(entries) = fs::read_dir(dir.join(VAULTS_DIR)) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|e| {
            let bytes = fs::read(e.path().join(PIN_FILE)).ok()?;
            let f: PinFile = serde_json::from_slice(&bytes).ok()?;
            (f.format == 1).then(|| (e.path(), f))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::sk;

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    const PW: &str = "orange kettle whispers at dawn 77";

    #[test]
    fn pin_opens_its_vault_only_with_the_device_key() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let v = l.create_vault("A", PW).unwrap();
        let device = SecretKey::generate();
        assert!(Library::pin_length(tmp.path()).is_none());
        v.enable_pin("2468", &device, FAST).unwrap();
        assert_eq!(Library::pin_length(tmp.path()), Some(4));

        let opened = Library::unlock_pin(tmp.path(), "2468", &device)
            .unwrap()
            .unwrap();
        assert_eq!(opened.id, v.id);
        assert!(Library::unlock_pin(tmp.path(), "2469", &device)
            .unwrap()
            .is_none());
        // Same PIN, files copied to a device without the device key: nothing.
        assert!(
            Library::unlock_pin(tmp.path(), "2468", &SecretKey::generate())
                .unwrap()
                .is_none()
        );

        Library::forget_pin(tmp.path()).unwrap();
        assert!(Library::unlock_pin(tmp.path(), "2468", &device)
            .unwrap()
            .is_none());
    }

    #[test]
    fn pin_rules() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, sk())
            .unwrap()
            .create_vault("A", PW)
            .unwrap();
        let d = SecretKey::generate();
        for bad in ["123", "12345678901", "12a4", ""] {
            assert!(
                matches!(v.enable_pin(bad, &d, FAST), Err(Error::BadPin)),
                "{bad}"
            );
        }
        v.enable_pin("1234567890", &d, FAST).unwrap();
        assert_eq!(Library::pin_length(tmp.path()), Some(10));
    }
}
