//! All of Cozy Safe's network code (decisions 2026-10-24: network only by hand, in one
//! crate). The vault core (`cs-vault`) has none and cackle keeps it that way; this crate
//! is the only one allowed `net`.
//!
//! **Every connection needs a [`Permit`].** The app makes one only after the person has
//! been asked, by name, whether to connect there, and tapped Allow. A permit names one
//! destination and is used up by the connection it opens: nothing here can open a
//! socket without one, and nothing runs in the background.

// No unsafe Rust here either (docs/supply-chain.md).
#![forbid(unsafe_code)]

use std::net::{Ipv4Addr, SocketAddrV4};

pub mod drive;
mod https;
pub mod p2p;

/// The person's yes to one connection. Not `Clone`: each one opens one thing.
#[derive(Debug)]
pub struct Permit {
    kind: Kind,
}

#[derive(Debug)]
enum Kind {
    /// Listen on this address (this device's Wi-Fi), for one pairing.
    Listen(Ipv4Addr),
    /// Connect to exactly this address.
    Connect(SocketAddrV4),
    /// Talk to Google Drive's API ([`https::HOST`]) and nothing else, for one session.
    Drive,
}

impl Permit {
    /// Granted after the person allowed waiting for a nearby device on `ip`.
    pub fn listen(ip: Ipv4Addr) -> Permit {
        Permit {
            kind: Kind::Listen(ip),
        }
    }

    /// Granted after the person allowed connecting to `addr`.
    pub fn connect(addr: SocketAddrV4) -> Permit {
        Permit {
            kind: Kind::Connect(addr),
        }
    }

    /// [`Permit::listen`] from the address as text, if it is one on a local network.
    pub fn listen_on(ip: &str) -> Option<Permit> {
        let ip: Ipv4Addr = ip.parse().ok()?;
        p2p::on_local_network(ip).then(|| Permit::listen(ip))
    }

    /// [`Permit::connect`] to the device showing `code`.
    pub fn connect_for(code: &p2p::PairCode) -> Permit {
        Permit::connect(code.addr)
    }

    /// Granted after the person allowed syncing with their Google Drive.
    pub fn google_drive() -> Permit {
        Permit { kind: Kind::Drive }
    }

    pub(crate) fn is_drive(&self) -> bool {
        matches!(self.kind, Kind::Drive)
    }

    pub(crate) fn listen_ip(&self) -> Option<Ipv4Addr> {
        match self.kind {
            Kind::Listen(ip) => Some(ip),
            Kind::Connect(_) | Kind::Drive => None,
        }
    }

    pub(crate) fn connect_to(&self) -> Option<SocketAddrV4> {
        match self.kind {
            Kind::Connect(a) => Some(a),
            Kind::Listen(_) | Kind::Drive => None,
        }
    }
}

/// Two devices holding the same vault, from public APIs only.
#[cfg(test)]
pub(crate) mod testkit {
    use std::fs;
    use std::path::Path;

    use cs_crypto::kdf::KdfParams;
    use cs_crypto::SecretKey;
    use cs_vault::items::{kind, NewItem};
    use cs_vault::{Library, OpenVault};

    const FAST: KdfParams = KdfParams {
        m_kib: 64,
        t: 1,
        p: 1,
    };

    pub(crate) struct Two {
        pub(crate) dirs: (tempfile::TempDir, tempfile::TempDir),
        pub(crate) a: OpenVault,
        pub(crate) b: OpenVault,
        /// The library's Recovery Key.
        pub(crate) sk: SecretKey,
        /// The vault password (random each run: no password is written in the code).
        pub(crate) pw: String,
    }

    fn copy_dir(from: &Path, to: &Path) {
        fs::create_dir_all(to).unwrap();
        for e in fs::read_dir(from).unwrap().flatten() {
            let p = e.path();
            if e.file_name().to_string_lossy().starts_with("vault.db") {
                continue; // per device
            }
            if p.is_dir() {
                copy_dir(&p, &to.join(e.file_name()));
            } else {
                fs::copy(&p, to.join(e.file_name())).unwrap();
            }
        }
    }

    pub(crate) fn two() -> Two {
        let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let pw = hex::encode(cs_crypto::generate_salt());
        let pw = pw.as_str();
        let sk = SecretKey::from_bytes([cs_crypto::rand_u32() as u8; cs_crypto::SECRET_KEY_LEN]);
        Library::open_or_create(da.path(), FAST, sk.clone())
            .unwrap()
            .create_vault("V", pw)
            .unwrap();
        copy_dir(da.path(), db.path());
        let a = Library::open_or_create(da.path(), FAST, sk.clone())
            .unwrap()
            .unlock(pw)
            .unwrap()
            .unwrap();
        let b = Library::open_or_create(db.path(), FAST, sk.clone())
            .unwrap()
            .unlock(pw)
            .unwrap()
            .unwrap();
        Two {
            dirs: (da, db),
            a,
            b,
            sk,
            pw: pw.to_owned(),
        }
    }

    pub(crate) fn note(v: &OpenVault, name: &str, text: &str) -> String {
        v.add_item(NewItem {
            kind: kind::NOTE,
            name,
            mime: "text/plain",
            created_ms: 1,
            content: text.as_bytes(),
            thumbnail: None,
        })
        .unwrap()
        .id
    }

    pub(crate) fn text(v: &OpenVault, id: &str) -> String {
        let mut out = Vec::new();
        v.read_item(id, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }
}
