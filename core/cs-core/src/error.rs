//! The vault's errors, written out (no `thiserror`): each says what went wrong without
//! any secret or file content in it.

use std::fmt;

#[derive(Debug)]
pub enum Error {
    /// A new password that [`crate::passwords::check_new_password`] refuses.
    WeakPassword,
    PasswordInUse,
    EmptyName,
    BadPin,
    PinInUse,
    NoSuchItem,
    WrongSecretKey,
    BadBackup,
    LibraryExists,
    /// A library of the other kind (ADR 0005): a Top secret call found a Private
    /// library, or the other way round.
    WrongKind,
    Corrupt(&'static str),
    Index(String),
    Crypto(cs_crypto::Error),
    Io(std::io::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::WeakPassword => f.write_str("password too short or too easy to guess"),
            Error::PasswordInUse => f.write_str("another vault already uses this password"),
            Error::EmptyName => f.write_str("vault name is empty"),
            Error::BadPin => f.write_str("a PIN has at least 4 digits"),
            Error::PinInUse => f.write_str("another vault already opens with this PIN"),
            Error::NoSuchItem => f.write_str("no such item"),
            Error::WrongSecretKey => f.write_str("this Secret Key belongs to another library"),
            Error::BadBackup => f.write_str("not a Cozy Safe backup, or the file is damaged"),
            Error::LibraryExists => f.write_str("a library already exists here"),
            Error::WrongKind => f.write_str("this library is of the other kind"),
            Error::Corrupt(what) => write!(f, "library data is damaged: {what}"),
            Error::Index(e) => write!(f, "vault index: {e}"),
            // Transparent, as before: the inner error's own words.
            Error::Crypto(e) => fmt::Display::fmt(e, f),
            Error::Io(e) => fmt::Display::fmt(e, f),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Crypto(e) => e.source(),
            Error::Io(e) => e.source(),
            _ => None,
        }
    }
}

impl From<cs_crypto::Error> for Error {
    fn from(e: cs_crypto::Error) -> Self {
        Error::Crypto(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}
