//! A vault onto a new device from a sync place (Google Drive, another device) with only
//! the Recovery Key and the vault password: no backup file. The place keeps the vault's
//! newest lock (`<vault>/lock/<ms>-<sha256>.json`: header, library salt, Argon2 cost, the
//! key's fingerprint), which opens nothing alone; with the two secrets it gives back the
//! Master Key, and the items follow by an ordinary sync.

use std::fs;
use std::path::Path;

use cs_crypto::{kdf, wrap, SecretKey};

use crate::sync::Remote;
use crate::{
    aad, decode_array, id_name, open_with, write_atomic, Error, KdfJson, Library, LibraryHeader,
    OpenVault, Result, VaultHeader, HEADER_FILE, LIBRARY_FILE, SALT_LEN, VAULTS_DIR,
};

/// A lock is a few kilobytes.
const MAX_LOCK: u64 = 1 << 20;

/// A vault's lock as the sync place keeps it: `{"library": …, "vault": …}`.
struct Lock {
    vault: VaultHeader,
    library: LibraryHeader,
}

impl Lock {
    fn from_json(bytes: &[u8]) -> Option<Self> {
        let v = cs_core::json::parse(bytes).ok()?;
        let f = cs_core::json::Fields::of(&v)?;
        Some(Self {
            vault: VaultHeader::from_value(f.get("vault")?).ok()?,
            library: LibraryHeader::from_value(f.get("library")?).ok()?,
        })
    }
}

/// A vault onto a new device from a sync place.
pub trait LibraryJoin {
    /// Make `dir` (no vault in it yet) hold the vault `vault_id` kept in `remote`, if
    /// `secret_key` and `password` open its newest lock: `None` for a wrong password,
    /// [`Error::WrongSecretKey`] for other 24 words. Then sync it from `remote` to bring
    /// its items.
    fn join(
        dir: &Path,
        remote: &dyn Remote,
        vault_id: &str,
        secret_key: SecretKey,
        password: &str,
    ) -> Result<Option<OpenVault>>;

    /// [`Library::join`] for a place that holds several vaults (one Google Drive folder
    /// serves them all): the two secrets say which one. `None` when the words belong to
    /// one of them but the password opens none; [`Error::WrongSecretKey`] when none has
    /// these words. A lock that fails to read does not stop the others being tried.
    fn join_any(
        dir: &Path,
        remote: &dyn Remote,
        vault_ids: &[String],
        secret_key: SecretKey,
        password: &str,
    ) -> Result<Option<OpenVault>>;
}

impl LibraryJoin for Library {
    fn join(
        dir: &Path,
        remote: &dyn Remote,
        vault_id: &str,
        secret_key: SecretKey,
        password: &str,
    ) -> Result<Option<OpenVault>> {
        let Some(vault_id) = id_name(vault_id) else {
            return Err(Error::Corrupt("vault id"));
        };
        let vault_id = vault_id.as_str();
        if Library::has_vaults(dir) {
            return Err(Error::LibraryExists);
        }
        let newest = remote
            .list(&format!("{vault_id}/lock"))?
            .into_iter()
            .filter(|n| n.ends_with(".json"))
            .max()
            .ok_or(Error::Corrupt("no vault lock there"))?;
        let mut bytes = Vec::new();
        remote.get(&format!("{vault_id}/lock/{newest}"), &mut bytes)?;
        if bytes.len() as u64 > MAX_LOCK {
            return Err(Error::Corrupt("vault lock too large"));
        }
        let lock = Lock::from_json(&bytes).ok_or(Error::Corrupt("vault lock"))?;
        let lib = &lock.library;
        let fits = |f: &Option<String>| {
            f.as_deref()
                .is_some_and(|f| secret_key.fingerprint_matches(f))
        };
        if !fits(&lib.secret_key) && !fits(&lib.prev_secret_key) {
            return Err(Error::WrongSecretKey);
        }
        let lib_salt = decode_array::<SALT_LEN>(&lib.salt, "library salt")?;
        // The cost comes from the sync place: one under the floor was tampered with.
        let params = kdf::KdfParams::from(lib.kdf);
        params.check()?;
        let fp = secret_key.fingerprint();
        let root = kdf::derive_root(password.as_bytes(), &secret_key, &lib_salt, params)?;
        let salt = decode_array::<SALT_LEN>(&lock.vault.salt, "vault salt")?;
        let kek = kdf::vault_kek(&root, &salt);
        let opened = [
            &lock.vault.wrapped_master_key,
            &lock.vault.prev_wrapped_master_key,
        ]
        .into_iter()
        .filter(|w| !w.is_empty())
        .filter_map(cs_core::hex::decode)
        .find_map(|w| wrap::unwrap_key(&kek, &w, &aad(vault_id, "master-key")).ok());
        let Some(master_key) = opened else {
            return Ok(None);
        };
        // Write this device's library and vault header (no half-done change carried over).
        fs::create_dir_all(dir.join(VAULTS_DIR))?;
        let header = LibraryHeader {
            format: lib.format,
            kdf: KdfJson::from(params),
            salt: lib.salt.clone(),
            secret_key: Some(fp),
            prev_secret_key: None,
        };
        write_atomic(&dir.join(LIBRARY_FILE), &header.to_json_pretty())?;
        let vault_dir = dir.join(VAULTS_DIR).join(vault_id);
        fs::create_dir_all(&vault_dir)?;
        let mut vh = lock.vault;
        // The wrap that opened becomes the only one.
        let new_wrap = cs_core::hex::encode(wrap::wrap_key(
            &kek,
            &master_key,
            &aad(vault_id, "master-key"),
        ));
        vh.wrapped_master_key = new_wrap;
        vh.prev_wrapped_master_key.clear();
        write_atomic(&vault_dir.join(HEADER_FILE), &vh.to_json_pretty())?;
        open_with(vault_id.to_owned(), vault_dir, &vh, master_key).map(Some)
    }

    fn join_any(
        dir: &Path,
        remote: &dyn Remote,
        vault_ids: &[String],
        secret_key: SecretKey,
        password: &str,
    ) -> Result<Option<OpenVault>> {
        let mut words_known = false;
        let mut failed = None;
        for id in vault_ids {
            match Library::join(dir, remote, id, secret_key.clone(), password) {
                Ok(Some(vault)) => return Ok(Some(vault)),
                Ok(None) => words_known = true,
                Err(Error::WrongSecretKey) => {}
                Err(e) => failed = Some(e),
            }
        }
        if words_known {
            return Ok(None);
        }
        Err(failed.unwrap_or(Error::WrongSecretKey))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::tests::{note, text, two};
    use crate::VaultSync;

    const FAST: kdf::KdfParams = kdf::KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };

    #[test]
    fn a_new_device_joins_from_the_place_with_the_words_and_password() {
        let t = two();
        let id = note(&t.a, "Sổ", "bí mật");
        t.a.sync(&t.cloud).unwrap();
        let fresh = tempfile::tempdir().unwrap();
        // Other words, or another password, open nothing.
        let other = SecretKey::from_bytes([1; 32]);
        assert!(matches!(
            Library::join(
                fresh.path(),
                &t.cloud,
                &t.a.id,
                other,
                crate::sync::tests::pw()
            ),
            Err(Error::WrongSecretKey)
        ));
        assert!(Library::join(
            fresh.path(),
            &t.cloud,
            &t.a.id,
            crate::tests::sk(),
            "not the password at all"
        )
        .unwrap()
        .is_none());
        assert!(!Library::has_vaults(fresh.path()));
        let v = Library::join(
            fresh.path(),
            &t.cloud,
            &t.a.id,
            crate::tests::sk(),
            crate::sync::tests::pw(),
        )
        .unwrap()
        .expect("opens");
        v.sync(&t.cloud).unwrap();
        assert_eq!(text(&v, &id), "bí mật");
        drop(v);
        // And it opens again like any vault here.
        let l = Library::open_or_create(fresh.path(), FAST, crate::tests::sk()).unwrap();
        assert!(l.unlock(crate::sync::tests::pw()).unwrap().is_some());
    }

    #[test]
    fn of_several_vaults_in_one_place_the_password_picks_its_own() {
        let t = two();
        // A second vault in the same library (same words), its own password.
        let pw2 = cs_core::hex::encode(cs_crypto::generate_salt());
        let lib = Library::open_or_create(t._dirs.0.path(), FAST, crate::tests::sk()).unwrap();
        let w = lib.create_vault("W", &pw2).unwrap();
        let id = note(&w, "W", "second");
        t.a.sync(&t.cloud).unwrap();
        w.sync(&t.cloud).unwrap();
        for ids in [
            vec![t.a.id.clone(), w.id.clone()],
            vec![w.id.clone(), t.a.id.clone()],
        ] {
            let fresh = tempfile::tempdir().unwrap();
            let v = Library::join_any(fresh.path(), &t.cloud, &ids, crate::tests::sk(), &pw2)
                .unwrap()
                .expect("the password's own vault");
            assert_eq!(v.id, w.id);
            v.sync(&t.cloud).unwrap();
            assert_eq!(text(&v, &id), "second");
        }
        let fresh = tempfile::tempdir().unwrap();
        let ids = [t.a.id.clone(), w.id.clone()];
        let wrong: String = pw2.chars().rev().collect();
        assert!(
            Library::join_any(fresh.path(), &t.cloud, &ids, crate::tests::sk(), &wrong)
                .unwrap()
                .is_none()
        );
        let other = SecretKey::from_bytes([1; 32]);
        assert!(matches!(
            Library::join_any(fresh.path(), &t.cloud, &ids, other, &pw2),
            Err(Error::WrongSecretKey)
        ));
        assert!(!Library::has_vaults(fresh.path()));
    }

    #[test]
    fn a_bad_vault_id_from_the_place_is_refused() {
        let t = two();
        let fresh = tempfile::tempdir().unwrap();
        for bad in ["../x", "", "ABCDEF", &"a".repeat(33)] {
            assert!(Library::join(fresh.path(), &t.cloud, bad, crate::tests::sk(), "x").is_err());
        }
    }

    #[test]
    fn a_lock_with_a_lowered_argon2_cost_is_refused() {
        let t = two();
        t.a.sync(&t.cloud).unwrap();
        let dir = format!("{}/lock", t.a.id);
        let newest = t.cloud.list(&dir).unwrap().into_iter().max().unwrap();
        let mut bytes = Vec::new();
        t.cloud.get(&format!("{dir}/{newest}"), &mut bytes).unwrap();
        let mut lock: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        lock["library"]["kdf"]["m_kib"] =
            serde_json::json!(kdf::KdfParams::ACCEPTED_FLOOR.m_kib / 2);
        let tampered = serde_json::to_vec(&lock).unwrap();
        t.cloud
            .put(
                &format!("{dir}/9999999999999-tampered.json"),
                &mut &tampered[..],
            )
            .unwrap();
        let fresh = tempfile::tempdir().unwrap();
        assert!(matches!(
            Library::join(
                fresh.path(),
                &t.cloud,
                &t.a.id,
                crate::tests::sk(),
                crate::sync::tests::pw()
            ),
            Err(Error::Crypto(cs_crypto::Error::KdfTooWeak))
        ));
        assert!(!Library::has_vaults(fresh.path()));
    }
}
