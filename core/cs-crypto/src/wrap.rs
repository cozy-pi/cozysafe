//! Sealing small values: wrapped keys, headers, metadata.
//!
//! Layout: `version (1) ‖ nonce (24) ‖ ciphertext ‖ tag (16)`. The version byte is
//! authenticated together with the caller's associated data.

use chacha20poly1305::aead::{Aead, AeadCore, KeyInit, OsRng, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use zeroize::Zeroizing;

use crate::{Error, Key, Result, KEY_LEN};

const VERSION: u8 = 1;
const NONCE_LEN: usize = 24;
const TAG_LEN: usize = 16;

/// Encrypt and authenticate `plaintext`, binding it to `aad`.
pub fn seal(key: &Key, plaintext: &[u8], aad: &[u8]) -> Vec<u8> {
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
    let full_aad = with_version(aad);
    let ct = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: plaintext,
                aad: &full_aad,
            },
        )
        .expect("XChaCha20-Poly1305 encryption cannot fail for in-memory input");

    let mut out = Vec::with_capacity(1 + NONCE_LEN + ct.len());
    out.push(VERSION);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    out
}

/// Reverse of [`seal`]. Fails with [`Error::Decrypt`] on any tampering or wrong key.
pub fn open(key: &Key, sealed: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if sealed.len() < 1 + NONCE_LEN + TAG_LEN {
        return Err(Error::Format("sealed value too short"));
    }
    if sealed[0] != VERSION {
        return Err(Error::Version(sealed[0]));
    }
    let nonce = XNonce::from_slice(&sealed[1..1 + NONCE_LEN]);
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    let full_aad = with_version(aad);
    cipher
        .decrypt(
            nonce,
            Payload {
                msg: &sealed[1 + NONCE_LEN..],
                aad: &full_aad,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| Error::Decrypt)
}

/// Wrap `key` under `kek` (e.g. a vault Master Key under its KEK).
pub fn wrap_key(kek: &Key, key: &Key, aad: &[u8]) -> Vec<u8> {
    seal(kek, key.as_bytes(), aad)
}

/// Unwrap a key produced by [`wrap_key`].
pub fn unwrap_key(kek: &Key, wrapped: &[u8], aad: &[u8]) -> Result<Key> {
    let bytes = open(kek, wrapped, aad)?;
    let arr: [u8; KEY_LEN] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| Error::Format("wrapped key has wrong length"))?;
    Ok(Key::from_bytes(arr))
}

fn with_version(aad: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + aad.len());
    v.push(VERSION);
    v.extend_from_slice(aad);
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let k = Key::generate();
        let sealed = seal(&k, b"hello vault", b"ctx");
        assert_eq!(
            open(&k, &sealed, b"ctx").unwrap().as_slice(),
            b"hello vault"
        );
    }

    #[test]
    fn nonces_differ() {
        let k = Key::generate();
        assert_ne!(seal(&k, b"same", b""), seal(&k, b"same", b""));
    }

    #[test]
    fn wrong_key_aad_or_bit_flip_fail() {
        let k = Key::generate();
        let sealed = seal(&k, b"hello", b"ctx");
        assert!(matches!(
            open(&Key::generate(), &sealed, b"ctx"),
            Err(Error::Decrypt)
        ));
        assert!(matches!(open(&k, &sealed, b"other"), Err(Error::Decrypt)));
        for i in 0..sealed.len() {
            let mut bad = sealed.clone();
            bad[i] ^= 1;
            assert!(
                open(&k, &bad, b"ctx").is_err(),
                "flip at byte {i} went unnoticed"
            );
        }
    }

    #[test]
    fn key_wrapping() {
        let kek = Key::generate();
        let mk = Key::generate();
        let wrapped = wrap_key(&kek, &mk, b"vault-1");
        assert_eq!(unwrap_key(&kek, &wrapped, b"vault-1").unwrap(), mk);
        assert!(unwrap_key(&kek, &wrapped, b"vault-2").is_err());
    }
}
