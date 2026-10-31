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

use crate::vault::{
    aad, decode_array, open_with, read_header, remove_if_exists, write_atomic, Library, OpenVault,
    VAULTS_DIR,
};
use crate::{Error, Result};

pub const PIN_FILE: &str = "pin";
/// For a new or changed PIN (owner 2026-10-23: at least 6). PINs set earlier with 4 or 5
/// digits still unlock: only setting one checks this.
pub const MIN_PIN_LEN: usize = 6;
/// Not a limit people meet: only a sanity cap against garbage input.
pub const MAX_PIN_LEN: usize = 256;

use crate::format::PinFile;

const PIN_FORMAT: u32 = 2;

/// PINs set before 2026-10-23 may have 4 or 5 digits: they still unlock.
const OLDEST_PIN_LEN: usize = 4;

/// A PIN that could open a vault (unlocking, "is this PIN taken").
fn valid(pin: &str) -> bool {
    (OLDEST_PIN_LEN..=MAX_PIN_LEN).contains(&pin.len()) && pin.bytes().all(|b| b.is_ascii_digit())
}

/// A PIN that may be set now.
fn valid_new(pin: &str) -> bool {
    pin.len() >= MIN_PIN_LEN && valid(pin)
}

impl OpenVault {
    /// Set (or replace) this vault's PIN on this device. Refused if the PIN already
    /// opens another vault here.
    pub fn enable_pin(&self, pin: &str, device_key: &SecretKey, params: KdfParams) -> Result<()> {
        if !valid_new(pin) {
            return Err(Error::BadPin);
        }
        self.write_pin(pin, device_key, params)
    }

    /// [enable_pin] without the length rule (tests: a PIN from before the rule).
    fn write_pin(&self, pin: &str, device_key: &SecretKey, params: KdfParams) -> Result<()> {
        if let Some(library) = self.dir.parent().and_then(|v| v.parent()) {
            if Library::pin_owner(library, pin, device_key)?.is_some_and(|id| id != self.id) {
                return Err(Error::PinInUse);
            }
        }
        let salt = generate_salt();
        let root = kdf::derive_root(pin.as_bytes(), device_key, &salt, params)?;
        let kek = kdf::vault_kek(&root, &salt);
        let file = PinFile {
            format: PIN_FORMAT,
            salt: crate::hex::encode(salt),
            length: pin.len() as u8,
            kdf: Some(params.into()),
            legacy_m_kib: None,
            legacy_t: None,
            legacy_p: None,
            wrapped_master_key: crate::hex::encode(wrap::wrap_key(
                &kek,
                &self.master_key,
                &aad(&self.id, "pin"),
            )),
        };
        write_atomic(&self.dir.join(PIN_FILE), &file.to_json())
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
    pub fn pin_owner(dir: &Path, pin: &str, device_key: &SecretKey) -> Result<Option<String>> {
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
            let Some(params) = file.kdf_params() else {
                continue;
            };
            let root = kdf::derive_root(pin.as_bytes(), device_key, &salt, params)?;
            let kek = kdf::vault_kek(&root, &salt);
            let wrapped =
                crate::hex::decode(&file.wrapped_master_key).ok_or(Error::Corrupt("pin"))?;
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
            let Some(params) = file.kdf_params() else {
                continue;
            };
            let root = kdf::derive_root(pin.as_bytes(), device_key, &salt, params)?;
            let kek = kdf::vault_kek(&root, &salt);
            let wrapped =
                crate::hex::decode(&file.wrapped_master_key).ok_or(Error::Corrupt("pin"))?;
            if let Ok(mk) = wrap::unwrap_key(&kek, &wrapped, &aad(&id, "pin")) {
                return open_with(id, vault_dir, &header, mk).map(Some);
            }
        }
        Ok(None)
    }

    /// Remove the PIN of every vault that opens with a password. The app no longer
    /// offers a PIN (decisions 2026-10-28: a 6-digit PIN was the weakest way in); a
    /// vault made with only a PIN keeps it until it gets a password, or it would be
    /// locked out. Returns how many PINs were removed.
    pub fn forget_pins_with_password(dir: &Path) -> Result<usize> {
        let mut removed = 0;
        for (vault_dir, _) in pin_files(dir) {
            if read_header(&vault_dir).is_some_and(|h| h.has_password()) {
                remove_if_exists(&vault_dir.join(PIN_FILE))?;
                removed += 1;
            }
        }
        Ok(removed)
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
            let f = PinFile::from_json(&bytes).ok()?;
            (f.format == 1 || f.format == PIN_FORMAT).then(|| (e.path(), f))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::tests::{digits, pins, sk};

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };
    /// A vault password, random each run: none is written in the code.
    /// A second password, random each run.
    fn pw2() -> &'static str {
        static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        P.get_or_init(|| crate::hex::encode(cs_crypto::generate_salt()))
    }

    fn pw() -> &'static str {
        static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        P.get_or_init(|| crate::hex::encode(cs_crypto::generate_salt()))
    }

    #[test]
    fn pin_opens_its_vault_only_with_the_device_key() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let v = l.create_vault("A", pw()).unwrap();
        let device = SecretKey::generate();
        assert!(Library::pin_length(tmp.path()).is_none());
        v.enable_pin(&pins()[0], &device, FAST).unwrap();
        assert_eq!(Library::pin_length(tmp.path()), Some(6));

        let opened = Library::unlock_pin(tmp.path(), &pins()[0], &device)
            .unwrap()
            .unwrap();
        assert_eq!(opened.id, v.id);
        assert!(Library::unlock_pin(tmp.path(), &pins()[5], &device)
            .unwrap()
            .is_none());
        // Same PIN, files copied to a device without the device key: nothing.
        assert!(
            Library::unlock_pin(tmp.path(), &pins()[0], &SecretKey::generate())
                .unwrap()
                .is_none()
        );

        Library::forget_pin(tmp.path()).unwrap();
        assert!(Library::unlock_pin(tmp.path(), &pins()[0], &device)
            .unwrap()
            .is_none());
    }

    /// Only vaults with a password lose their PIN; a PIN-only vault keeps it.
    #[test]
    fn forgets_pins_only_where_a_password_opens() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let device = SecretKey::generate();
        let with_pw = l.create_vault("A", pw()).unwrap();
        with_pw.enable_pin(&pins()[0], &device, FAST).unwrap();
        let pin_only = l
            .create_vault_with_pin("lock", "teal", &pins()[1], &device, FAST)
            .unwrap();

        assert_eq!(Library::forget_pins_with_password(tmp.path()).unwrap(), 1);
        assert!(Library::unlock_pin(tmp.path(), &pins()[0], &device)
            .unwrap()
            .is_none());
        let still = Library::unlock_pin(tmp.path(), &pins()[1], &device)
            .unwrap()
            .unwrap();
        assert_eq!(still.id, pin_only.id);
        assert_eq!(Library::forget_pins_with_password(tmp.path()).unwrap(), 0);
    }

    /// A PIN file from 0.1.0–0.1.6 (format 1, cost at the top level) still unlocks,
    /// and new ones are written in format 2.
    #[test]
    fn reads_format_1_pin_files() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let v = l.create_vault("A", pw()).unwrap();
        let device = SecretKey::generate();
        v.enable_pin(&pins()[0], &device, FAST).unwrap();
        let path = tmp.path().join(VAULTS_DIR).join(&v.id).join(PIN_FILE);
        let mut json: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(json["format"], 2);
        let kdf = json["kdf"].take();
        let o = json.as_object_mut().unwrap();
        o.remove("kdf");
        o.insert("format".into(), 1.into());
        for k in ["m_kib", "t", "p"] {
            o.insert(k.into(), kdf[k].clone());
        }
        fs::write(&path, serde_json::to_vec(&json).unwrap()).unwrap();
        let opened = Library::unlock_pin(tmp.path(), &pins()[0], &device)
            .unwrap()
            .unwrap();
        assert_eq!(opened.id, v.id);
    }

    #[test]
    fn vaults_start_with_a_pin_and_each_pin_picks_its_vault() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let d = SecretKey::generate();
        let a = l
            .create_vault_with_pin("home", "green", &pins()[0], &d, FAST)
            .unwrap();
        let b = l
            .create_vault_with_pin("work", "blue", &pins()[2], &d, FAST)
            .unwrap();
        assert!(matches!(
            l.create_vault_with_pin("car", "red", &pins()[0], &d, FAST),
            Err(Error::PinInUse)
        ));
        assert_eq!(Library::pin_lengths(tmp.path()), vec![6]);
        let oa = Library::unlock_pin(tmp.path(), &pins()[0], &d)
            .unwrap()
            .unwrap();
        assert_eq!(
            (oa.id.as_str(), oa.icon.as_str(), oa.color.as_str()),
            (a.id.as_str(), "home", "green")
        );
        assert_eq!(
            Library::unlock_pin(tmp.path(), &pins()[2], &d)
                .unwrap()
                .unwrap()
                .id,
            b.id
        );
        // Changing B's PIN to A's is refused; to a new one is fine.
        assert!(matches!(
            b.enable_pin(&pins()[0], &d, FAST),
            Err(Error::PinInUse)
        ));
        b.enable_pin(&pins()[3], &d, FAST).unwrap();
        assert_eq!(
            Library::unlock_pin(tmp.path(), &pins()[3], &d)
                .unwrap()
                .unwrap()
                .id,
            b.id
        );

        // No password yet: no password opens anything (backups leave the vault out:
        // cs-vault's backup tests).
        assert!(!a.has_password());
        assert!(!Library::any_password(tmp.path()));
        assert!(l.unlock(pw()).unwrap().is_none());

        // Set a password later: it opens the vault; the same password for B is refused.
        l.set_password(&a, pw()).unwrap();
        assert!(a.has_password() && Library::any_password(tmp.path()));
        assert_eq!(l.unlock(pw()).unwrap().unwrap().id, a.id);
        assert!(matches!(
            l.set_password(&b, pw()),
            Err(Error::PasswordInUse)
        ));
        // Changing it is just a re-wrap: the old one stops working.
        l.set_password(&a, pw2()).unwrap();
        assert!(l.unlock(pw()).unwrap().is_none());
        assert_eq!(l.unlock(pw2()).unwrap().unwrap().id, a.id);
    }

    #[test]
    fn identity_can_change() {
        let tmp = tempfile::tempdir().unwrap();
        let l = Library::open_or_create(tmp.path(), FAST, sk()).unwrap();
        let d = SecretKey::generate();
        let mut v = l
            .create_vault_with_pin("home", "green", &pins()[0], &d, FAST)
            .unwrap();
        v.set_identity("star", "plum").unwrap();
        let o = Library::unlock_pin(tmp.path(), &pins()[0], &d)
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
            .create_vault("A", pw())
            .unwrap();
        let d = SecretKey::generate();
        let bad_pins = [
            digits(3),
            digits(5),
            digits(257),
            format!("{}a{}", digits(2), digits(3)),
            String::new(),
        ];
        for bad in &bad_pins {
            assert!(
                matches!(v.enable_pin(bad, &d, FAST), Err(Error::BadPin)),
                "{bad}"
            );
        }
        v.enable_pin(&"7".repeat(30), &d, FAST).unwrap();
        assert_eq!(Library::pin_length(tmp.path()), Some(30));
    }

    #[test]
    fn a_four_digit_pin_from_before_still_unlocks() {
        let tmp = tempfile::tempdir().unwrap();
        let v = Library::open_or_create(tmp.path(), FAST, sk())
            .unwrap()
            .create_vault("A", pw())
            .unwrap();
        let d = SecretKey::generate();
        v.write_pin(&pins()[4], &d, FAST).unwrap();
        assert!(matches!(
            v.enable_pin(&pins()[4], &d, FAST),
            Err(Error::BadPin)
        ));
        let opened = Library::unlock_pin(tmp.path(), &pins()[4], &d)
            .unwrap()
            .unwrap();
        assert_eq!(opened.id, v.id);
    }
}
