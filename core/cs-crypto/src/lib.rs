//! Cryptographic core of Cozy Safe. See `docs/adr/0001-encryption.md`.
//!
//! - [`kdf`]: password + Secret Key → root key (Argon2id), root → per-vault KEK (HKDF).
//! - [`wrap`]: small sealed values (wrapped keys, headers, metadata).
//! - [`stream`]: chunked STREAM encryption for files of any size in constant memory.
//!
//! This crate does no I/O of its own beyond the `Read`/`Write` it is handed,
//! and every key type wipes itself on drop.

pub mod kdf;
mod secret_key_text;
pub mod stream;
pub mod wrap;

use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::OsRng;
use zeroize::{Zeroize, ZeroizeOnDrop};

/// Length of every symmetric key, in bytes.
pub const KEY_LEN: usize = 32;
/// Length of the Secret Key, in bytes (128 bits).
pub const SECRET_KEY_LEN: usize = 16;
/// Length of every salt, in bytes.
pub const SALT_LEN: usize = 16;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Wrong key, wrong password, or data that was modified, truncated or reordered.
    /// Deliberately carries no detail.
    #[error("decryption failed")]
    Decrypt,
    #[error("invalid format: {0}")]
    Format(&'static str),
    #[error("unsupported format version {0}")]
    Version(u8),
    #[error("key derivation parameters out of range")]
    KdfParams,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

/// A 256-bit symmetric key. Never printed, wiped on drop.
#[derive(Clone, Zeroize, ZeroizeOnDrop, PartialEq, Eq)]
pub struct Key([u8; KEY_LEN]);

impl Key {
    /// A fresh random key from the OS CSPRNG.
    pub fn generate() -> Self {
        let mut k = [0u8; KEY_LEN];
        OsRng.fill_bytes(&mut k);
        Key(k)
    }

    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Key(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Key(<redacted>)")
    }
}

/// The 128-bit Secret Key mixed into every unlock. Never printed, wiped on drop.
#[derive(Clone, Zeroize, ZeroizeOnDrop, PartialEq, Eq)]
pub struct SecretKey([u8; SECRET_KEY_LEN]);

impl SecretKey {
    pub fn generate() -> Self {
        let mut k = [0u8; SECRET_KEY_LEN];
        OsRng.fill_bytes(&mut k);
        SecretKey(k)
    }

    pub fn from_bytes(bytes: [u8; SECRET_KEY_LEN]) -> Self {
        SecretKey(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; SECRET_KEY_LEN] {
        &self.0
    }

    /// A short public fingerprint stored beside the library, so a wrong Secret Key
    /// (typed from an Emergency Kit, or a mix-up between libraries) is told apart from
    /// a wrong password. 64 bits of a one-way function of a 128-bit random key.
    pub fn fingerprint(&self) -> String {
        let hk = hkdf::Hkdf::<sha2::Sha256>::new(None, &self.0);
        let mut out = [0u8; 8];
        hk.expand(b"cozysafe/v1/secret-key-fingerprint", &mut out)
            .expect("8 bytes is a valid HKDF output length");
        out.iter().map(|b| format!("{b:02x}")).collect()
    }
}

impl std::fmt::Debug for SecretKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SecretKey(<redacted>)")
    }
}

/// A random u32 from the OS CSPRNG.
pub fn rand_u32() -> u32 {
    OsRng.next_u32()
}

/// A fresh random salt.
pub fn generate_salt() -> [u8; SALT_LEN] {
    let mut s = [0u8; SALT_LEN];
    OsRng.fill_bytes(&mut s);
    s
}
