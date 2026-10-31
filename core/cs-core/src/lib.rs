//! The Top secret core (docs/adr/0005-two-kinds-of-vault.md): what a Top secret vault
//! needs beyond the cryptography itself, written here instead of taken from a library.
//! Its only dependencies are audited cryptography (through `cs-crypto`) and SQLite
//! (docs/supply-chain.md, "Top secret means top secret"; tools/check-vendor enforces it).
//!
//! - [`vault`], [`items`], [`pin`], [`history`]: the library, its vaults, their items,
//!   PINs and kept versions.
//! - [`db`]: the vault index, one SQLite file per vault.
//! - [`format`]: the library's files (headers, PIN files, item records).
//! - [`clock`]: the device id and logical clock sync orders changes by.
//! - [`Error`]: the vault's errors (in place of `thiserror`).
//! - [`json`]: the small JSON the vault files use (in place of serde and serde_json).
//! - [`hex`]: lower-case hex (in place of the `hex` crate).
//! - [`passwords`]: the rule for a new password (in place of `zxcvbn`).

// No unsafe Rust in the core: the compiler refuses it (docs/supply-chain.md).
#![forbid(unsafe_code)]

pub mod clock;
pub mod db;
mod error;
pub mod format;
pub mod hex;
pub mod history;
pub mod items;
pub mod json;
pub mod passwords;
pub mod pin;
pub mod vault;

pub use error::{Error, Result};
