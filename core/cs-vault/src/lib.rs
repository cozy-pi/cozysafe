//! What a vault does beyond the Top secret core (`cs-core`): sync, the audit of sync
//! places, backups, joining a vault from a sync place, suggested passwords. The library,
//! the vaults, their items, PINs and version history are `cs-core`'s, re-exported here
//! so the app reaches everything through this crate.
//!
//! Sync, the audit and joining add methods to [`OpenVault`] and [`Library`] through
//! traits ([`VaultSync`], [`VaultAudit`], [`LibraryJoin`]): import the trait to call them.

// No unsafe Rust in the core: the compiler refuses it (docs/supply-chain.md).
#![forbid(unsafe_code)]

pub mod audit;
pub mod backup;
pub mod join;
pub mod passphrase;
pub mod sync;

pub use audit::VaultAudit;
pub use cs_core::passwords::{self, check_new_password, PasswordCheck};
pub use cs_core::passwords::{MIN_PASSWORD_LEN, MIN_PASSWORD_SCORE, OLDEST_MIN_PASSWORD_LEN};
pub use cs_core::vault::{bucket_of, KeyChange, Library, OpenVault, VaultSlot, CONNECTION_LOG_LEN};
pub use cs_core::{db, history, items, pin, Error, Result};
pub use items::ItemMeta;
pub use join::LibraryJoin;
pub use sync::VaultSync;

// What sync, backup and join take from the core.
pub(crate) use cs_core::format::{KdfJson, LibraryHeader, VaultHeader};
pub(crate) use cs_core::vault::{
    aad, decode_array, id_name, open_with, read_header, read_library_header, write_atomic,
    HEADER_FILE, LIBRARY_FILE, VAULTS_DIR,
};
pub(crate) use cs_crypto::SALT_LEN;

/// Strength of a candidate password for the bars, 0 to 4 ([`passwords::strength`]).
pub fn password_score(password: &str) -> u8 {
    passwords::strength(password)
}

#[cfg(test)]
pub(crate) mod tests {
    use cs_crypto::{SecretKey, SECRET_KEY_LEN};

    pub(crate) fn sk() -> SecretKey {
        SecretKey::from_bytes([7; SECRET_KEY_LEN])
    }
}
