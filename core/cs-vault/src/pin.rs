//! PIN unlock for one vault on one device.
//!
//! The PIN alone is weak (10^4 to 10^10 values), so it never protects anything by
//! itself: the vault's Master Key is wrapped by a key derived with Argon2id from the
//! PIN *and* a random device key that lives only in this device's keystore (the app
//! passes it in). Copy the vault files elsewhere and the PIN is useless; take the
//! device key without the PIN and it is useless too. The app limits wrong tries and
//! calls [`Library::forget_pin`] when the limit is reached; the password still works.
//!
//! Every vault can have its own PIN on a device, and a PIN picks its vault the way a
//! password does: two vaults here never share a PIN.

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
    /// Set (or replace) this vault's PIN on this device. Refused if the PIN already
    /// opens another vault here.
    pub fn enable_pin(&self, pin: &str, device_key: &SecretKey, params: KdfParams) -> Result<()> {
        if !valid(pin) {
            return Err(Error::BadPin);
        }
        if let Some(library) = self.dir.parent().and_then(|v| v.parent()) {
            if Library::pin_owner(library, pin, device_key)?.is_some_and(|id| id != self.id) {
                return Err(Error::PinInUse);
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
    /// Longest PIN set on this device (to draw the dots), or `None`.
    pub fn pin_length(dir: &Path) -> Option<usize> {
        Self::pin_lengths(dir).last().copied()
    }

    /// Every PIN length in use here, shortest first: the pad checks at each of them.
    pub fn pin_lengths(dir: &Path) -> Vec<usize> {
        let mut v: Vec<usize> = pin_files(dir)
            .into_iter()
            .map(|(_, f)| f.length as usize)
            .collect();
        v.sort_unstable();
        v.dedup();
        v
    }

    /// The id of the vault this PIN opens, without opening it.
    pub(crate) fn pin_owner(
        dir: &Path,
        pin: &str,
        device_key: &SecretKey,
    ) -> Result<Option<String>> {
        if !valid(pin) {
            return Ok(None);
        }
        for (vault_dir, file) in pin_files(dir) {
            if file.length as usize != pin.len() {
                continue;
            }
            let Some(id) = vault_dir
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
            else {
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
            if wrap::unwrap_key(&kek, &wrapped, &aad(&id, "pin")).is_ok() {
                return Ok(Some(id));
            }
        }
        Ok(None)
    }

    /// Open the vault with this PIN. `Ok(None)` for a wrong PIN.
    pub fn unlock_pin(dir: &Path, pin: &str, device_key: &SecretKey) -> Result<Option<OpenVault>> {
        if !valid(pin) {
            return Ok(None);
        }
        for (vault_dir, file) in pin_files(dir) {
            if file.length as usize != pin.len() {
                continue;
            }
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
    fn vaults_start_with_a_pin_and_each_pin_picks_its_vault() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let d = SecretKey::generate();
        let a = l
            .create_vault_with_pin("home", "green", "2468", &d, FAST)
            .unwrap();
        let b = l
            .create_vault_with_pin("work", "blue", "135790", &d, FAST)
            .unwrap();
        assert!(matches!(
            l.create_vault_with_pin("car", "red", "2468", &d, FAST),
            Err(Error::PinInUse)
        ));
        assert_eq!(Library::pin_lengths(tmp.path()), vec![4, 6]);
        let oa = Library::unlock_pin(tmp.path(), "2468", &d)
            .unwrap()
            .unwrap();
        assert_eq!(
            (oa.id.as_str(), oa.icon.as_str(), oa.color.as_str()),
            (a.id.as_str(), "home", "green")
        );
        assert_eq!(
            Library::unlock_pin(tmp.path(), "135790", &d)
                .unwrap()
                .unwrap()
                .id,
            b.id
        );
        // Changing B's PIN to A's is refused; to a new one is fine.
        assert!(matches!(
            b.enable_pin("2468", &d, FAST),
            Err(Error::PinInUse)
        ));
        b.enable_pin("1111", &d, FAST).unwrap();
        assert_eq!(
            Library::unlock_pin(tmp.path(), "1111", &d)
                .unwrap()
                .unwrap()
                .id,
            b.id
        );

        // No password yet: no password opens anything, and backups leave the vault out.
        assert!(!a.has_password());
        assert!(!Library::any_password(tmp.path()));
        assert!(l.unlock(PW).unwrap().is_none());
        let mut out = Vec::new();
        assert_eq!(crate::backup::export(tmp.path(), &mut out).unwrap(), 1); // library.json only

        // Set a password later: it opens the vault; the same password for B is refused.
        l.set_password(&a, PW).unwrap();
        assert!(a.has_password() && Library::any_password(tmp.path()));
        assert_eq!(l.unlock(PW).unwrap().unwrap().id, a.id);
        assert!(matches!(l.set_password(&b, PW), Err(Error::PasswordInUse)));
        // Changing it is just a re-wrap: the old one stops working.
        l.set_password(&a, "mây tháng mười rơi trên phố cổ")
            .unwrap();
        assert!(l.unlock(PW).unwrap().is_none());
        assert_eq!(
            l.unlock("mây tháng mười rơi trên phố cổ")
                .unwrap()
                .unwrap()
                .id,
            a.id
        );
    }

    #[test]
    fn identity_can_change() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let d = SecretKey::generate();
        let mut v = l
            .create_vault_with_pin("home", "green", "2468", &d, FAST)
            .unwrap();
        v.set_identity("star", "plum").unwrap();
        let o = Library::unlock_pin(tmp.path(), "2468", &d)
            .unwrap()
            .unwrap();
        assert_eq!((o.icon.as_str(), o.color.as_str()), ("star", "plum"));
        let header =
            fs::read_to_string(tmp.path().join("vaults").join(&v.id).join("header.json")).unwrap();
        assert!(!header.contains("star") && !header.contains("plum"));
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
