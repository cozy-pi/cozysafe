//! Two-stage unlock (ADR 0001):
//!
//! 1. [`derive_root`]: Argon2id over `HKDF(SecretKey) ‖ password` with the library salt.
//!    Runs once per unlock; this is where the whole time budget goes.
//! 2. [`vault_kek`]: HKDF of the root with each vault's own salt. Microseconds per vault.

use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::{Error, Key, Result, SecretKey, KEY_LEN, SALT_LEN};

const INFO_SECRET_KEY: &[u8] = b"cozysafe/v1/secret-key";
const INFO_VAULT_KEK: &[u8] = b"cozysafe/v1/vault-kek";
const INFO_SUBKEY: &[u8] = b"cozysafe/v1/subkey/";

/// Argon2id cost parameters, stored in the clear in the library header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KdfParams {
    /// Memory in KiB.
    pub m_kib: u32,
    /// Iterations.
    pub t: u32,
    /// Parallel lanes.
    pub p: u32,
}

impl KdfParams {
    /// Minimum accepted when a phone creates a library: 128 MiB, t = 3, p = 1.
    pub const PHONE_FLOOR: KdfParams = KdfParams {
        m_kib: 128 * 1024,
        t: 3,
        p: 1,
    };
    /// Minimum accepted when a desktop creates a library: 512 MiB, t = 3, p = 4.
    pub const DESKTOP_FLOOR: KdfParams = KdfParams {
        m_kib: 512 * 1024,
        t: 3,
        p: 4,
    };

    /// Upper bounds when *opening*, so a hostile header cannot make the app
    /// allocate unbounded memory or spin for minutes.
    const MAX_M_KIB: u32 = 4 * 1024 * 1024;
    const MAX_T: u32 = 32;
    const MAX_P: u32 = 16;

    /// True when these parameters are at least as strong as `floor` in every dimension
    /// that adds cost (memory and iterations).
    pub fn meets(&self, floor: &KdfParams) -> bool {
        self.m_kib >= floor.m_kib && self.t >= floor.t
    }

    fn to_argon2(self) -> Result<Params> {
        if self.m_kib > Self::MAX_M_KIB
            || self.t == 0
            || self.t > Self::MAX_T
            || self.p == 0
            || self.p > Self::MAX_P
        {
            return Err(Error::KdfParams);
        }
        Params::new(self.m_kib, self.t, self.p, Some(KEY_LEN)).map_err(|_| Error::KdfParams)
    }
}

/// Stage 1: password + Secret Key → root key.
///
/// The Secret Key is stretched to a fixed 32 bytes first, so the concatenation
/// with the variable-length password is unambiguous.
pub fn derive_root(
    password: &[u8],
    secret_key: &SecretKey,
    library_salt: &[u8; SALT_LEN],
    params: KdfParams,
) -> Result<Key> {
    let mut input = Zeroizing::new(Vec::with_capacity(KEY_LEN + password.len()));
    input.extend_from_slice(hkdf_expand(secret_key.as_bytes(), None, INFO_SECRET_KEY).as_bytes());
    input.extend_from_slice(password);

    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params.to_argon2()?);
    let mut out = Zeroizing::new([0u8; KEY_LEN]);
    argon
        .hash_password_into(&input, library_salt, out.as_mut())
        .map_err(|_| Error::KdfParams)?;
    Ok(Key::from_bytes(*out))
}

/// Stage 2: root key + a vault's salt → that vault's key-encryption key.
pub fn vault_kek(root: &Key, vault_salt: &[u8; SALT_LEN]) -> Key {
    hkdf_expand(root.as_bytes(), Some(vault_salt), INFO_VAULT_KEK)
}

/// Domain-separated subkey of a vault's Master Key, e.g. `"index"`, `"sync"`.
pub fn subkey(master: &Key, label: &str) -> Key {
    let mut info = Vec::with_capacity(INFO_SUBKEY.len() + label.len());
    info.extend_from_slice(INFO_SUBKEY);
    info.extend_from_slice(label.as_bytes());
    hkdf_expand(master.as_bytes(), None, &info)
}

fn hkdf_expand(ikm: &[u8], salt: Option<&[u8]>, info: &[u8]) -> Key {
    let mut out = [0u8; KEY_LEN];
    Hkdf::<Sha256>::new(salt, ikm)
        .expand(info, &mut out)
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    Key::from_bytes(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tiny parameters keep tests fast; production floors are checked separately.
    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };

    fn sk(b: u8) -> SecretKey {
        SecretKey::from_slice(&[b; 16]).unwrap() // a 128-bit (earlier) key: their roots must not change
    }

    #[test]
    fn root_is_deterministic() {
        let a = derive_root(b"correct horse", &sk(1), &[7; 16], FAST).unwrap();
        let b = derive_root(b"correct horse", &sk(1), &[7; 16], FAST).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn every_input_changes_the_root() {
        let base = derive_root(b"correct horse", &sk(1), &[7; 16], FAST).unwrap();
        assert_ne!(
            base,
            derive_root(b"correct horsf", &sk(1), &[7; 16], FAST).unwrap()
        );
        assert_ne!(
            base,
            derive_root(b"correct horse", &sk(2), &[7; 16], FAST).unwrap()
        );
        assert_ne!(
            base,
            derive_root(b"correct horse", &sk(1), &[8; 16], FAST).unwrap()
        );
        assert_ne!(
            base,
            derive_root(
                b"correct horse",
                &sk(1),
                &[7; 16],
                KdfParams { t: 2, ..FAST }
            )
            .unwrap()
        );
    }

    #[test]
    fn vaults_get_independent_keks() {
        let root = derive_root(b"pw", &sk(1), &[7; 16], FAST).unwrap();
        assert_ne!(vault_kek(&root, &[1; 16]), vault_kek(&root, &[2; 16]));
        assert_eq!(vault_kek(&root, &[1; 16]), vault_kek(&root, &[1; 16]));
    }

    #[test]
    fn subkeys_are_separated() {
        let mk = Key::from_bytes([9; 32]);
        assert_ne!(subkey(&mk, "index"), subkey(&mk, "sync"));
    }

    #[test]
    fn hostile_params_are_rejected() {
        let huge = KdfParams {
            m_kib: u32::MAX,
            t: 3,
            p: 1,
        };
        assert!(matches!(
            derive_root(b"pw", &sk(1), &[0; 16], huge),
            Err(Error::KdfParams)
        ));
        let zero = KdfParams {
            m_kib: 64,
            t: 0,
            p: 1,
        };
        assert!(matches!(
            derive_root(b"pw", &sk(1), &[0; 16], zero),
            Err(Error::KdfParams)
        ));
    }

    #[test]
    fn floors() {
        assert!(KdfParams::DESKTOP_FLOOR.meets(&KdfParams::PHONE_FLOOR));
        assert!(!FAST.meets(&KdfParams::PHONE_FLOOR));
    }
}
