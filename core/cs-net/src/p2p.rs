//! Sync with another device on the same Wi-Fi, no cloud (docs/adr/0003-sync.md, "P2P
//! security").
//!
//! The host opens a listener on its Wi-Fi address and shows a code (QR or typed) with
//! that address, the port and a one-time token. The joiner connects; both prove they
//! hold the same vault (keys derived from its Master Key) before anything else, then
//! talk through sealed, numbered frames. The host serves a folder it has just synced the
//! vault into, so the sync itself is the ordinary one ([`OpenVault::sync`]); afterwards
//! the host syncs that folder back in to take the joiner's changes.
//!
//! A device with no vault yet (restoring) joins the same way with a key from the 24
//! words instead ([`kdf::restore_pairing_key`]); the host then tells it the vault's id,
//! and it opens the vault's lock with the words and the password ([`Library::join`])
//! before the ordinary sync brings the items.
//!
//! Nothing is advertised on the network: no Bonjour, no broadcast. To spare the person
//! the QR, the host listens on a fixed port ([`PORT`]) and shows three digits; the other
//! device, once the person allowed it, knocks at that port on each address of its own
//! Wi-Fi (`a.b.c.1`–`254`) with a probe ([`Looker::scan`]). Only a host holding the same vault
//! can answer a probe in a way the joiner accepts, and only one showing the digits typed
//! matches ([`Looker::find`]): a stranger on the network learns nothing from a probe, and
//! a wrong code never reaches the host. The QR stays for networks where the knock does
//! not get through.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cs_crypto::{kdf, wrap, Key, SecretKey};
use cs_vault::sync::{FolderRemote, Remote, SyncReport};
use cs_vault::sync::{SyncPhase, SyncProgress};
use cs_vault::{Error, Library, OpenVault, Result};

use crate::Permit;

const VERSION: u8 = 1;
/// What the joiner comes for, in its hello: sync a vault both hold, or restore it.
const MODE_SYNC: u8 = 1;
const MODE_RESTORE: u8 = 2;
/// Not a session: a device looking for its other device on the Wi-Fi.
const MODE_PROBE: u8 = 3;
/// Digits the host shows (owner 2026-10-25: three are enough). They are not what keeps
/// strangers out — only a device with the vault's key can pair — they pick which waiting
/// device to join, and a wrong code is caught on the joiner without reaching the host.
pub const CODE_DIGITS: usize = 3;
const CODE_SPACE: u64 = 10u64.pow(CODE_DIGITS as u32);
/// The port a host listens on when it is free, so a nearby device can find it.
pub const PORT: u16 = 47823;
/// Bytes of each tag in a probe's answer.
const TAG_LEN: usize = 16;
/// Bytes of one-time token in the code (with the vault key, it only binds the session).
pub const TOKEN_LEN: usize = 5;
const NONCE_LEN: usize = 32;
/// Largest frame on the wire, sealed (1 MiB of payload).
const MAX_FRAME: usize = (1 << 20) + 64;
const CHUNK: usize = 1 << 20;
/// How long a code works (time to pick up the other phone and type the digits).
pub const CODE_LIFETIME: Duration = Duration::from_secs(300);
/// Failed handshakes before the host stops listening.
const MAX_FAILURES: u32 = 3;
/// A session with no request for this long ends.
const IDLE: Duration = Duration::from_secs(600);
/// The place names for this device's sync state (fresh each session).
const HOST_KEY: &str = "p2p-host";
const JOIN_KEY: &str = "p2p-join";

/// What the host shows: where to connect and the one-time token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairCode {
    pub addr: SocketAddrV4,
    pub token: [u8; TOKEN_LEN],
}

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford, no I L O U

impl PairCode {
    /// The address it points at, to name it when asking the person.
    pub fn ip_text(&self) -> String {
        self.addr.ip().to_string()
    }

    /// Whether it points at a device on a local network.
    pub fn is_local(&self) -> bool {
        on_local_network(*self.addr.ip())
    }

    fn bytes(&self) -> [u8; 11] {
        let mut b = [0u8; 11];
        b[..4].copy_from_slice(&self.addr.ip().octets());
        b[4..6].copy_from_slice(&self.addr.port().to_be_bytes());
        b[6..].copy_from_slice(&self.token);
        b
    }

    /// The digits the host shows: the token is made from them ([`token_of`]).
    pub fn digits(&self) -> Option<String> {
        let mut b = [0u8; 8];
        b[3..].copy_from_slice(&self.token);
        let n = u64::from_be_bytes(b);
        (n < CODE_SPACE).then(|| format!("{n:0w$}", w = CODE_DIGITS))
    }

    /// The code to type: 18 letters and digits in three groups ("4K9M2Q-…").
    pub fn typed(&self) -> String {
        let b = self.bytes();
        let mut bits: u128 = 0;
        for x in b {
            bits = (bits << 8) | x as u128;
        }
        // 88 bits → 18 symbols of 5 bits (90 bits, top two zero).
        let mut out = String::new();
        for i in (0..18).rev() {
            out.push(ALPHABET[((bits >> (i * 5)) & 31) as usize] as char);
            if i == 12 || i == 6 {
                out.push('-');
            }
        }
        out
    }

    /// The text in the QR code.
    pub fn qr(&self) -> String {
        format!("cozysafe:p2p:{VERSION}:{}", self.typed().replace('-', ""))
    }

    /// Read a typed code or a scanned QR text. Spaces, dashes and case do not matter;
    /// O and I/L are read as 0 and 1, as Crockford base32 allows.
    pub fn parse(text: &str) -> Option<PairCode> {
        let t = text.trim();
        let t = t
            .strip_prefix(&format!("cozysafe:p2p:{VERSION}:"))
            .unwrap_or(t);
        let mut bits: u128 = 0;
        let mut n = 0;
        for c in t.chars() {
            let c = match c.to_ascii_uppercase() {
                '-' | ' ' => continue,
                'O' => '0',
                'I' | 'L' => '1',
                c => c,
            };
            let v = ALPHABET.iter().position(|&a| a as char == c)? as u128;
            bits = (bits << 5) | v;
            n += 1;
        }
        if n != 18 || bits >> 88 != 0 {
            return None;
        }
        let b: Vec<u8> = (0..11).rev().map(|i| (bits >> (i * 8)) as u8).collect();
        let ip = Ipv4Addr::new(b[0], b[1], b[2], b[3]);
        let port = u16::from_be_bytes([b[4], b[5]]);
        if port == 0 || ip.is_unspecified() {
            return None;
        }
        Some(PairCode {
            addr: SocketAddrV4::new(ip, port),
            token: b[6..].try_into().ok()?,
        })
    }
}

/// The token for the typed digits ("048"), if that is what they are.
pub fn token_of(digits: &str) -> Option<[u8; TOKEN_LEN]> {
    let d = digits.trim();
    if d.len() != CODE_DIGITS || !d.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n: u64 = d.parse().ok()?;
    n.to_be_bytes()[3..].try_into().ok()
}

/// Random digits as a token: with the vault key they only bind the session and pick the
/// host (the key, not the digits, keeps strangers out).
fn random_token() -> [u8; TOKEN_LEN] {
    let n = u64::from_be_bytes(random::<8>()) % CODE_SPACE;
    n.to_be_bytes()[3..].try_into().unwrap_or([0; TOKEN_LEN])
}

/// The pairing key: only a device holding this vault can have it.
fn pairing_key(vault: &OpenVault) -> Key {
    vault.p2p_key()
}

/// An authenticated channel: one key per direction, each frame numbered.
pub struct Channel {
    stream: TcpStream,
    send_key: Key,
    recv_key: Key,
    send_n: u64,
    recv_n: u64,
    send_dir: &'static str,
    recv_dir: &'static str,
    /// The 4-digit number both screens show, to compare.
    pub check: u16,
}

fn write_frame(stream: &mut TcpStream, bytes: &[u8]) -> Result<()> {
    if bytes.len() > MAX_FRAME {
        return Err(Error::Corrupt("p2p frame too large"));
    }
    stream.write_all(&(bytes.len() as u32).to_be_bytes())?;
    stream.write_all(bytes)?;
    Ok(())
}

fn read_frame(stream: &mut TcpStream) -> Result<Vec<u8>> {
    let mut len = [0u8; 4];
    stream.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(Error::Corrupt("p2p frame too large"));
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf)?;
    Ok(buf)
}

impl Channel {
    pub fn send(&mut self, msg: &[u8]) -> Result<()> {
        let aad = format!("cozysafe/p2p/v1/frame/{}/{}", self.send_dir, self.send_n);
        let sealed = wrap::seal(&self.send_key, msg, aad.as_bytes());
        self.send_n += 1;
        write_frame(&mut self.stream, &sealed)
    }

    pub fn recv(&mut self) -> Result<Vec<u8>> {
        let sealed = read_frame(&mut self.stream)?;
        let aad = format!("cozysafe/p2p/v1/frame/{}/{}", self.recv_dir, self.recv_n);
        // A replayed, reordered, cut or forged frame fails here, and ends the session.
        let plain = wrap::open(&self.recv_key, &sealed, aad.as_bytes())
            .map_err(|_| Error::Corrupt("p2p frame"))?;
        self.recv_n += 1;
        Ok(plain.to_vec())
    }
}

fn session(pk: &Key, token: &[u8], nj: &[u8], nh: &[u8], stream: TcpStream, host: bool) -> Channel {
    let tail = format!(
        "{}/{}/{}",
        hex::encode(token),
        hex::encode(nj),
        hex::encode(nh)
    );
    let to_join = kdf::subkey(pk, &format!("session/to-joiner/{tail}"));
    let to_host = kdf::subkey(pk, &format!("session/to-host/{tail}"));
    let check_key = kdf::subkey(pk, &format!("session/check/{tail}"));
    let c = check_key.as_bytes();
    let check = (u16::from_be_bytes([c[0], c[1]])) % 10000;
    if host {
        Channel {
            stream,
            send_key: to_join,
            recv_key: to_host,
            send_n: 0,
            recv_n: 0,
            send_dir: "to-joiner",
            recv_dir: "to-host",
            check,
        }
    } else {
        Channel {
            stream,
            send_key: to_host,
            recv_key: to_join,
            send_n: 0,
            recv_n: 0,
            send_dir: "to-host",
            recv_dir: "to-joiner",
            check,
        }
    }
}

fn proof_aad(who: &str, a: &[u8], b: &[u8]) -> Vec<u8> {
    format!(
        "cozysafe/p2p/v1/proof/{who}/{}/{}",
        hex::encode(a),
        hex::encode(b)
    )
    .into_bytes()
}

/// Joiner side of the handshake.
fn handshake_join(pk: &Key, mode: u8, token: &[u8], mut stream: TcpStream) -> Result<Channel> {
    let hello_key = kdf::subkey(pk, &format!("hello/{}", hex::encode(token)));
    let nj: [u8; NONCE_LEN] = random();
    let mut hello = vec![VERSION, mode];
    hello.extend_from_slice(&nj);
    write_frame(&mut stream, &hello)?;
    let reply = read_frame(&mut stream)?;
    if reply.len() < NONCE_LEN {
        return Err(Error::Corrupt("p2p handshake"));
    }
    let (nh, proof_h) = reply.split_at(NONCE_LEN);
    // The host must hold the vault: its proof covers our fresh nonce.
    wrap::open(&hello_key, proof_h, &proof_aad("host", &nj, nh))
        .map_err(|_| Error::Corrupt("p2p host not proven"))?;
    let proof_j = wrap::seal(&hello_key, b"", &proof_aad("joiner", nh, &nj));
    write_frame(&mut stream, &proof_j)?;
    Ok(session(pk, token, &nj, nh, stream, false))
}

/// Host side of the handshake: the joiner's hello says which key it proves.
fn handshake_host(
    prepared: &Prepared,
    token: &[u8],
    hello: &[u8],
    mut stream: TcpStream,
) -> Result<(Channel, u8)> {
    if hello.len() != 2 + NONCE_LEN || hello[0] != VERSION {
        return Err(Error::Corrupt("p2p hello"));
    }
    let mode = hello[1];
    let pk = match mode {
        MODE_SYNC => &prepared.key,
        MODE_RESTORE => prepared
            .restore_key
            .as_ref()
            .ok_or(Error::Corrupt("p2p hello"))?,
        _ => return Err(Error::Corrupt("p2p hello")),
    };
    let hello_key = kdf::subkey(pk, &format!("hello/{}", hex::encode(token)));
    let nj = &hello[2..];
    let nh: [u8; NONCE_LEN] = random();
    // Past the hello, a Cozy Safe device is on the other end: a failure from here says
    // who it is (its words are another library's, or it holds another vault).
    let proven = (|| {
        let mut reply = nh.to_vec();
        reply.extend(wrap::seal(&hello_key, b"", &proof_aad("host", nj, &nh)));
        write_frame(&mut stream, &reply)?;
        let proof_j = read_frame(&mut stream)?;
        wrap::open(&hello_key, &proof_j, &proof_aad("joiner", &nh, nj))
            .map_err(|_| Error::Corrupt("p2p joiner not proven"))?;
        Ok::<_, Error>(())
    })();
    if proven.is_err() {
        return Err(Error::Corrupt(if mode == MODE_RESTORE {
            "p2p restore wrong words"
        } else {
            "p2p joiner not proven"
        }));
    }
    Ok((session(pk, token, nj, &nh, stream, true), mode))
}

// ---------- finding the host on the Wi-Fi ----------

fn tag(pk: &Key, what: &str, nj: &[u8], nh: &[u8]) -> [u8; TAG_LEN] {
    let k = kdf::subkey(
        pk,
        &format!("probe/{what}/{}/{}", hex::encode(nj), hex::encode(nh)),
    );
    let mut out = [0u8; TAG_LEN];
    out.copy_from_slice(&k.as_bytes()[..TAG_LEN]);
    out
}

fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The host answers a probe: a fresh nonce, then for each key it holds (the vault's, and
/// the 24 words' for a device restoring) a tag that says "same vault" and one that says
/// "and these digits". Random bytes stand in for a key it does not hold.
fn answer_probe(keys: &ProbeKeys, nj: &[u8], stream: &mut TcpStream) -> Result<()> {
    let nh: [u8; NONCE_LEN] = random();
    let mut reply = nh.to_vec();
    let code = format!("code/{}", hex::encode(keys.token));
    for pk in [Some(&keys.key), keys.restore_key.as_ref()] {
        match pk {
            Some(pk) => {
                reply.extend(tag(pk, "vault", nj, &nh));
                reply.extend(tag(pk, &code, nj, &nh));
            }
            None => reply.extend(random::<{ 2 * TAG_LEN }>()),
        }
    }
    write_frame(stream, &reply)
}

/// What a waiting host needs to answer probes, shared with the threads that read them.
struct ProbeKeys {
    key: Key,
    restore_key: Option<Key>,
    token: [u8; TOKEN_LEN],
}

/// Connections read at once (each on its own thread, a few seconds at most): someone
/// who connects and stays silent cannot hold up the device that came to sync.
const MAX_READING: usize = 16;

/// A host on the Wi-Fi that holds the same vault (or takes the same 24 words).
#[derive(Clone, Debug)]
pub struct Found {
    pub addr: SocketAddrV4,
    nj: [u8; NONCE_LEN],
    nh: [u8; NONCE_LEN],
    code_tag: [u8; TAG_LEN],
}

/// Knock at `addr` with a probe; the host if it proves the key `pk`.
fn probe(addr: SocketAddrV4, pk: &Key, restoring: bool) -> Option<Found> {
    let mut stream =
        TcpStream::connect_timeout(&SocketAddr::V4(addr), Duration::from_millis(700)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .ok()?;
    let nj: [u8; NONCE_LEN] = random();
    let mut hello = vec![VERSION, MODE_PROBE];
    hello.extend_from_slice(&nj);
    write_frame(&mut stream, &hello).ok()?;
    let reply = read_frame(&mut stream).ok()?;
    if reply.len() != NONCE_LEN + 4 * TAG_LEN {
        return None;
    }
    let nh: [u8; NONCE_LEN] = reply[..NONCE_LEN].try_into().ok()?;
    let at = NONCE_LEN + if restoring { 2 * TAG_LEN } else { 0 };
    let (vault_tag, code_tag) = (
        &reply[at..at + TAG_LEN],
        &reply[at + TAG_LEN..at + 2 * TAG_LEN],
    );
    same(vault_tag, &tag(pk, "vault", &nj, &nh)).then(|| Found {
        addr,
        nj,
        nh,
        code_tag: code_tag.try_into().unwrap_or([0; TAG_LEN]),
    })
}

/// Knock at each of `targets` (half a network at once, each given under a second to
/// connect: a whole /24 in about two seconds); the hosts that prove `pk`.
fn probe_all(targets: &[SocketAddrV4], pk: &Key, restoring: bool) -> Vec<Found> {
    let mut found = Vec::new();
    for chunk in targets.chunks(128) {
        let got: Vec<Found> = std::thread::scope(|s| {
            let hands: Vec<_> = chunk
                .iter()
                .map(|&a| s.spawn(move || probe(a, pk, restoring)))
                .collect();
            hands
                .into_iter()
                .filter_map(|h| h.join().ok().flatten())
                .collect()
        });
        found.extend(got);
    }
    found
}

/// What a device looking for its other device proves: the vault's pairing key, or the
/// 24 words' when it has no vault yet. Made from the vault in a moment, so the vault is
/// not held while the Wi-Fi is searched.
pub struct Looker {
    pk: Key,
    restoring: bool,
}

impl Looker {
    pub fn for_vault(vault: &OpenVault) -> Looker {
        Looker {
            pk: pairing_key(vault),
            restoring: false,
        }
    }

    pub fn for_words(secret: &SecretKey) -> Looker {
        Looker {
            pk: kdf::restore_pairing_key(secret),
            restoring: true,
        }
    }

    /// Look on the permitted Wi-Fi: every address of this device's network
    /// (`a.b.c.1`–`254`, not its own) at [`PORT`]. A few seconds.
    pub fn scan(&self, permit: Permit) -> Result<Vec<Found>> {
        let own = permit
            .scan_from()
            .ok_or(Error::Corrupt("permit is not for looking"))?;
        if !on_local_network(own) || own.is_loopback() {
            return Err(Error::Corrupt("p2p address is not on a local network"));
        }
        let [a, b, c, me] = own.octets();
        let targets: Vec<SocketAddrV4> = (1..=254u8)
            .filter(|&d| d != me)
            .map(|d| SocketAddrV4::new(Ipv4Addr::new(a, b, c, d), PORT))
            .collect();
        Ok(probe_all(&targets, &self.pk, self.restoring))
    }

    /// The host among `found` that shows these digits, as a code to join with. None
    /// when they are not [`CODE_DIGITS`] digits or no host shows them (nothing is sent: a
    /// wrong code never reaches the other device).
    pub fn find(&self, found: &[Found], digits: &str) -> Option<PairCode> {
        find_with(found, &self.pk, digits)
    }
}

fn find_with(found: &[Found], pk: &Key, digits: &str) -> Option<PairCode> {
    let token = token_of(digits)?;
    let what = format!("code/{}", hex::encode(token));
    found
        .iter()
        .find(|f| same(&f.code_tag, &tag(pk, &what, &f.nj, &f.nh)))
        .map(|f| PairCode {
            addr: f.addr,
            token,
        })
}

fn random<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    let mut filled = 0;
    while filled < N {
        let salt = cs_crypto::generate_salt();
        let take = (N - filled).min(salt.len());
        out[filled..filled + take].copy_from_slice(&salt[..take]);
        filled += take;
    }
    out
}

// ---------- requests over the channel ----------

const OP_LIST: u8 = 1;
const OP_GET: u8 = 2;
const OP_PUT: u8 = 3;
const OP_EXISTS: u8 = 4;
const OP_DONE: u8 = 9;
/// The joiner stops and says why (owner 2026-10-25: the host kept waiting after the
/// other phone failed): the host ends the session and shows the reason.
const OP_ABORT: u8 = 8;
const ABORT_STOPPED: u8 = 0;
const ABORT_WRONG_PASSWORD: u8 = 1;

/// The host's folder, seen by the joiner through the channel.
pub struct ChannelRemote {
    ch: Mutex<Channel>,
}

impl ChannelRemote {
    fn ask(&self, op: u8, path: &str) -> Result<std::sync::MutexGuard<'_, Channel>> {
        let mut ch = self.ch.lock().map_err(|_| Error::Corrupt("p2p channel"))?;
        let mut msg = vec![op];
        msg.extend_from_slice(path.as_bytes());
        ch.send(&msg)?;
        Ok(ch)
    }

    /// Tell the host we stop, and why, so it ends too (best effort: the channel may be gone).
    fn abort(self, reason: u8) {
        if let Ok(mut ch) = self.ch.into_inner() {
            let _ = ch.send(&[OP_ABORT, reason]);
        }
    }

    /// Tell the host the sync is over (it then takes our changes in).
    pub fn done(self) -> Result<()> {
        let mut ch = self
            .ch
            .into_inner()
            .map_err(|_| Error::Corrupt("p2p channel"))?;
        ch.send(&[OP_DONE])?;
        ch.recv()?;
        Ok(())
    }
}

impl Remote for ChannelRemote {
    fn key(&self) -> String {
        JOIN_KEY.to_owned()
    }

    fn list(&self, dir: &str) -> Result<Vec<String>> {
        let mut ch = self.ask(OP_LIST, dir)?;
        let reply = ch.recv()?;
        serde_json::from_slice(&reply).map_err(|_| Error::Corrupt("p2p list"))
    }

    fn get(&self, path: &str, out: &mut dyn Write) -> Result<bool> {
        let mut ch = self.ask(OP_GET, path)?;
        if ch.recv()? != [1] {
            return Ok(false);
        }
        loop {
            let chunk = ch.recv()?;
            if chunk.is_empty() {
                return Ok(true);
            }
            out.write_all(&chunk)?;
        }
    }

    fn put(&self, path: &str, src: &mut dyn Read) -> Result<()> {
        let mut ch = self.ask(OP_PUT, path)?;
        let mut buf = vec![0u8; CHUNK];
        loop {
            let n = src.read(&mut buf)?;
            if n == 0 {
                break;
            }
            ch.send(&buf[..n])?;
        }
        ch.send(&[])?;
        if ch.recv()? != [1] {
            return Err(Error::Corrupt("p2p put"));
        }
        Ok(())
    }

    fn exists(&self, path: &str) -> Result<bool> {
        let mut ch = self.ask(OP_EXISTS, path)?;
        Ok(ch.recv()? == [1])
    }
}

/// Answer the joiner's requests from `folder`, only inside this vault's part of it,
/// until it says it is done.
fn serve(
    ch: &mut Channel,
    folder: &FolderRemote,
    vault_id: &str,
    progress: &dyn Fn(SyncProgress),
) -> Result<()> {
    let prefix = format!("{vault_id}/");
    // Files and bytes that crossed, for the speed on the host's screen (the total is
    // the other phone's to know).
    let (mut done, mut bytes) = (0u32, 0u64);
    let mut tell = |phase, n: u64| {
        done += 1;
        bytes += n;
        progress(SyncProgress {
            phase,
            done,
            total: 0,
            bytes,
            bytes_total: 0,
        });
    };
    loop {
        let msg = ch.recv()?;
        let (&op, path) = msg.split_first().ok_or(Error::Corrupt("p2p request"))?;
        if op == OP_DONE {
            ch.send(&[1])?;
            return Ok(());
        }
        if op == OP_ABORT {
            return Err(Error::Corrupt(match path.first() {
                Some(&ABORT_WRONG_PASSWORD) => "p2p restore wrong password",
                _ => "p2p peer stopped",
            }));
        }
        let path = std::str::from_utf8(path).map_err(|_| Error::Corrupt("p2p path"))?;
        if path != vault_id && !path.starts_with(&prefix) {
            return Err(Error::Corrupt("p2p path outside the vault"));
        }
        match op {
            OP_LIST => {
                let names = folder.list(path)?;
                ch.send(&serde_json::to_vec(&names).expect("serialisable"))?;
            }
            OP_EXISTS => ch.send(&[folder.exists(path)? as u8])?,
            OP_GET => match folder.open(path)? {
                // In frames straight from the file: a 2 GB video never sits in memory.
                Some(mut f) => {
                    ch.send(&[1])?;
                    let mut buf = vec![0u8; CHUNK];
                    let mut sent = 0u64;
                    loop {
                        let n = f.read(&mut buf)?;
                        if n == 0 {
                            break;
                        }
                        ch.send(&buf[..n])?;
                        sent += n as u64;
                    }
                    ch.send(&[])?;
                    tell(SyncPhase::Sending, sent);
                }
                None => ch.send(&[0])?,
            },
            OP_PUT => {
                // Into a temporary file as it comes, then into place.
                let tmp = folder.scratch()?;
                let mut got = 0u64;
                {
                    let mut f = std::fs::File::create(&tmp)?;
                    loop {
                        let chunk = ch.recv()?;
                        if chunk.is_empty() {
                            break;
                        }
                        f.write_all(&chunk)?;
                        got += chunk.len() as u64;
                    }
                    f.sync_all()?;
                }
                tell(SyncPhase::Receiving, got);
                // Never overwrite (the folder only ever gains immutable files).
                if !folder.exists(path)? {
                    let mut f = std::fs::File::open(&tmp)?;
                    folder.put(path, &mut f)?;
                }
                let _ = std::fs::remove_file(&tmp);
                ch.send(&[1])?;
            }
            _ => return Err(Error::Corrupt("p2p request")),
        }
    }
}

// ---------- the two sides ----------

/// A host waiting for one device to join.
pub struct Host {
    listener: TcpListener,
    pub code: PairCode,
    deadline: Instant,
}

/// Whether `ip` (as text) is an address on a home or office network.
pub fn local_address(ip: &str) -> bool {
    ip.parse::<Ipv4Addr>().is_ok_and(on_local_network)
}

/// The socket of the session under way, so [`cancel_live`] can end it from another
/// thread. One session at a time.
static LIVE: Mutex<Option<TcpStream>> = Mutex::new(None);

fn set_live(stream: Option<TcpStream>) {
    *LIVE.lock().unwrap_or_else(|p| p.into_inner()) = stream;
}

/// End the session under way, if any (the person tapped Cancel).
pub fn cancel_live() {
    if let Some(s) = LIVE.lock().unwrap_or_else(|p| p.into_inner()).take() {
        let _ = s.shutdown(std::net::Shutdown::Both);
    }
}

/// Only addresses of a home or office network, never one on the open internet: a code
/// (or a QR someone shows you) cannot make this device listen or connect out there.
pub fn on_local_network(ip: Ipv4Addr) -> bool {
    ip.is_private() || ip.is_link_local() || ip.is_loopback()
}

/// Start listening on the permitted Wi-Fi address, on a random port, for
/// [`CODE_LIFETIME`]. Show [`Host::code`] to the other device.
pub fn host(permit: Permit) -> Result<Host> {
    let ip = permit
        .listen_ip()
        .ok_or(Error::Corrupt("permit is not for listening"))?;
    if !on_local_network(ip) {
        return Err(Error::Corrupt("p2p address is not on a local network"));
    }
    // The fixed port lets a nearby device find this one; if something else has it, any
    // port (the QR still works).
    let listener = TcpListener::bind(SocketAddrV4::new(ip, PORT))
        .or_else(|_| TcpListener::bind(SocketAddrV4::new(ip, 0)))?;
    let port = listener.local_addr()?.port();
    Ok(Host {
        listener,
        code: PairCode {
            addr: SocketAddrV4::new(ip, port),
            token: random_token(),
        },
        deadline: Instant::now() + CODE_LIFETIME,
    })
}

/// The host's side, in steps, so the vault is only needed at the start and the end
/// (the app keeps it free while waiting and while the other device works).
pub struct Prepared {
    key: Key,
    /// From the Recovery Key, to let a device with no vault restore this one.
    restore_key: Option<Key>,
    vault_id: String,
    mirror: PathBuf,
}

/// Step 1 (vault): sync the vault into `mirror` (an empty private folder). With the
/// library's Recovery Key, a device restoring with the 24 words may join too.
pub fn host_prepare(
    vault: &OpenVault,
    secret: Option<&SecretKey>,
    mirror: &Path,
) -> Result<Prepared> {
    let folder = FolderRemote::with_key(mirror, HOST_KEY);
    // Fresh folder, fresh state: everything goes into it.
    vault.forget_sync_place(HOST_KEY)?;
    vault.sync(&folder)?;
    Ok(Prepared {
        key: pairing_key(vault),
        restore_key: secret.map(kdf::restore_pairing_key),
        vault_id: vault.id.clone(),
        mirror: mirror.to_path_buf(),
    })
}

/// A joiner proven to hold the vault.
pub struct Session {
    ch: Channel,
    vault_id: String,
    mirror: PathBuf,
    /// The number both screens show.
    pub check: u16,
}

/// Step 2 (no vault): wait for the joiner until the code expires, three failed tries,
/// or `stop` is set (the person tapped Cancel).
/// What the waiting host sees before a session starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Seen {
    /// A device connected; it is proving it holds the vault.
    Knock,
    /// It could not, and was turned away (the host keeps waiting).
    Rejected,
}

/// `on_seen` is told as devices come and are turned away.
pub fn host_accept(
    host: Host,
    prepared: Prepared,
    stop: &AtomicBool,
    on_seen: &dyn Fn(Seen),
) -> Result<Session> {
    host.listener.set_nonblocking(true)?;
    let mut failures = 0;
    let keys = std::sync::Arc::new(ProbeKeys {
        key: prepared.key.clone(),
        restore_key: prepared.restore_key.clone(),
        token: host.code.token,
    });
    let reading = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    // Hellos read on their own threads come back here; probes are answered there.
    let (hellos, came) = std::sync::mpsc::channel::<(TcpStream, Vec<u8>)>();
    let ch = loop {
        if stop.load(Ordering::Relaxed) {
            return Err(Error::Corrupt("p2p cancelled"));
        }
        if Instant::now() > host.deadline {
            return Err(Error::Corrupt("p2p code expired"));
        }
        match host.listener.accept() {
            Ok((stream, _)) => {
                if reading.load(Ordering::Relaxed) >= MAX_READING {
                    continue; // too many at once: this one is dropped
                }
                reading.fetch_add(1, Ordering::Relaxed);
                let (keys, reading, hellos) = (keys.clone(), reading.clone(), hellos.clone());
                std::thread::spawn(move || {
                    let mut stream = stream;
                    let hello = stream
                        .set_nonblocking(false)
                        .and_then(|_| stream.set_read_timeout(Some(Duration::from_secs(3))))
                        .map_err(Error::from)
                        .and_then(|_| read_frame(&mut stream));
                    match hello {
                        // A device looking for its other device: answer here. Probes do
                        // not count as tries (a scan knocks every few seconds).
                        Ok(h) if h.len() == 2 + NONCE_LEN && h[..2] == [VERSION, MODE_PROBE] => {
                            let _ = answer_probe(&keys, &h[2..], &mut stream);
                        }
                        Ok(h) => {
                            let _ = hellos.send((stream, h));
                        }
                        Err(_) => {} // not a Cozy Safe device, or gone
                    }
                    reading.fetch_sub(1, Ordering::Relaxed);
                });
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e.into()),
        }
        match came.try_recv() {
            Ok((stream, hello)) => {
                on_seen(Seen::Knock);
                stream.set_read_timeout(Some(Duration::from_secs(20)))?;
                match handshake_host(&prepared, &host.code.token, &hello, stream) {
                    Ok((mut ch, mode)) => {
                        // A restoring device does not know which vault yet.
                        if mode == MODE_RESTORE {
                            ch.send(prepared.vault_id.as_bytes())?;
                        }
                        break ch;
                    }
                    // A Cozy Safe device that could not prove itself: stop and say so
                    // (the person sees why on both phones). Anything else that connects
                    // (not a Cozy Safe hello) is ignored, up to a few times.
                    Err(
                        e @ Error::Corrupt("p2p restore wrong words" | "p2p joiner not proven"),
                    ) => {
                        on_seen(Seen::Rejected);
                        return Err(e);
                    }
                    Err(_) => {
                        failures += 1;
                        if failures >= MAX_FAILURES {
                            return Err(Error::Corrupt("p2p too many failed tries"));
                        }
                    }
                }
            }
            Err(_) => std::thread::sleep(Duration::from_millis(50)),
        }
    };
    drop(host.listener); // one session per code
    ch.stream.set_read_timeout(Some(IDLE))?;
    Ok(Session {
        check: ch.check,
        ch,
        vault_id: prepared.vault_id,
        mirror: prepared.mirror,
    })
}

impl Session {
    /// Step 3 (no vault): answer the joiner until it is done.
    pub fn serve(self) -> Result<Served> {
        self.serve_with(&|_| ())
    }

    /// [`Session::serve`], telling `progress` the files and bytes that crossed.
    pub fn serve_with(mut self, progress: &dyn Fn(SyncProgress)) -> Result<Served> {
        let folder = FolderRemote::with_key(&self.mirror, HOST_KEY);
        set_live(self.ch.stream.try_clone().ok());
        let served = serve(&mut self.ch, &folder, &self.vault_id, progress);
        set_live(None);
        served?;
        Ok(Served {
            mirror: self.mirror,
        })
    }
}

/// The joiner is done; its changes wait in the mirror.
pub struct Served {
    mirror: PathBuf,
}

/// Step 4 (vault): take the joiner's changes in.
pub fn host_finish(vault: &OpenVault, served: Served) -> Result<SyncReport> {
    host_finish_with(vault, served, &|_| ())
}

/// [`host_finish`], with progress.
pub fn host_finish_with(
    vault: &OpenVault,
    served: Served,
    progress: &dyn Fn(SyncProgress),
) -> Result<SyncReport> {
    vault.sync_with(&FolderRemote::with_key(&served.mirror, HOST_KEY), progress)
}

/// The waiting host for an app that must not hold sockets itself (cackle allows `net`
/// to this crate only): [`host_open`], then [`host_session`] on a worker thread.
static PENDING: Mutex<Option<(Host, Prepared)>> = Mutex::new(None);

/// What the host shows.
pub struct Shown {
    pub typed: String,
    pub qr: String,
    /// The digits to type on the other device ([`CODE_DIGITS`]).
    pub digits: String,
    /// Whether the host has [`PORT`], so a nearby device can find it (else QR only).
    pub findable: bool,
}

/// Steps 1 and the listener: copy the vault into `mirror` and start waiting at the
/// permitted address. Replaces any host still pending.
pub fn host_open(
    vault: &OpenVault,
    secret: Option<&SecretKey>,
    permit: Permit,
    mirror: &Path,
) -> Result<Shown> {
    let prepared = host_prepare(vault, secret, mirror)?;
    let host = host(permit)?;
    let shown = Shown {
        typed: host.code.typed(),
        qr: host.code.qr(),
        digits: host.code.digits().unwrap_or_default(),
        findable: host.code.addr.port() == PORT,
    };
    *PENDING.lock().unwrap_or_else(|p| p.into_inner()) = Some((host, prepared));
    Ok(shown)
}

/// Steps 2 and 3 (no vault) for the pending host; then [`host_finish`].
pub fn host_session(
    stop: &AtomicBool,
    on_check: &dyn Fn(u16),
    on_seen: &dyn Fn(Seen),
) -> Result<Served> {
    host_session_with(stop, on_check, on_seen, &|_| ())
}

/// [`host_session`], with the files and bytes served.
pub fn host_session_with(
    stop: &AtomicBool,
    on_check: &dyn Fn(u16),
    on_seen: &dyn Fn(Seen),
    progress: &dyn Fn(SyncProgress),
) -> Result<Served> {
    let (host, prepared) = PENDING
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .take()
        .ok_or(Error::Corrupt("p2p code expired"))?;
    let session = host_accept(host, prepared, stop, on_seen)?;
    on_check(session.check);
    session.serve_with(progress)
}

/// Stop listening (Cancel before anyone joined).
pub fn host_close() {
    PENDING.lock().unwrap_or_else(|p| p.into_inner()).take();
}

/// All four steps at once (tests, tools).
pub fn serve_one(
    vault: &OpenVault,
    host: Host,
    mirror: &Path,
    on_check: &dyn Fn(u16),
) -> Result<SyncReport> {
    let prepared = host_prepare(vault, None, mirror)?;
    let session = host_accept(host, prepared, &AtomicBool::new(false), &|_| ())?;
    on_check(session.check);
    let served = session.serve()?;
    host_finish(vault, served)
}

/// Join the device showing `code` (the permit must be for that address): prove we hold
/// the vault, sync, and say done. `on_check` gets the number to compare.
pub fn join(
    vault: &OpenVault,
    permit: Permit,
    code: &PairCode,
    on_check: &dyn Fn(u16),
) -> Result<SyncReport> {
    join_with(vault, permit, code, on_check, &|_| ())
}

/// [`join`], telling `progress` how far the sync is.
pub fn join_with(
    vault: &OpenVault,
    permit: Permit,
    code: &PairCode,
    on_check: &dyn Fn(u16),
    progress: &dyn Fn(SyncProgress),
) -> Result<SyncReport> {
    set_live(None);
    let report = join_inner(vault, permit, code, on_check, progress);
    set_live(None);
    report
}

fn join_inner(
    vault: &OpenVault,
    permit: Permit,
    code: &PairCode,
    on_check: &dyn Fn(u16),
    progress: &dyn Fn(SyncProgress),
) -> Result<SyncReport> {
    if permit.connect_to() != Some(code.addr) {
        return Err(Error::Corrupt("permit is for another address"));
    }
    if !on_local_network(*code.addr.ip()) {
        return Err(Error::Corrupt("p2p address is not on a local network"));
    }
    let stream = TcpStream::connect_timeout(&SocketAddr::V4(code.addr), Duration::from_secs(10))?;
    stream.set_read_timeout(Some(Duration::from_secs(60)))?;
    set_live(stream.try_clone().ok());
    let ch = handshake_join(&pairing_key(vault), MODE_SYNC, &code.token, stream)?;
    on_check(ch.check);
    vault.forget_sync_place(JOIN_KEY)?;
    let remote = ChannelRemote { ch: Mutex::new(ch) };
    match vault.sync_with(&remote, progress) {
        Ok(report) => {
            remote.done()?;
            Ok(report)
        }
        Err(e) => {
            remote.abort(ABORT_STOPPED);
            Err(e)
        }
    }
}

/// Restore onto this device (`dir`, no vault in it) the vault of the device showing
/// `code`, with only the 24 words and the password: pair with a key from the words,
/// open the vault's lock, then sync its items in. False for a wrong password;
/// [`Error::WrongSecretKey`] when the host does not take these words. The vault is then
/// opened the usual way, from `dir` with the two secrets: nothing that came over the
/// network is handed back.
pub fn restore(
    dir: &Path,
    permit: Permit,
    code: &PairCode,
    secret: SecretKey,
    password: &str,
    on_check: &dyn Fn(u16),
    progress: &dyn Fn(SyncProgress),
) -> Result<bool> {
    set_live(None);
    let out = restore_inner(dir, permit, code, secret, password, on_check, progress);
    set_live(None);
    out
}

fn restore_inner(
    dir: &Path,
    permit: Permit,
    code: &PairCode,
    secret: SecretKey,
    password: &str,
    on_check: &dyn Fn(u16),
    progress: &dyn Fn(SyncProgress),
) -> Result<bool> {
    if permit.connect_to() != Some(code.addr) {
        return Err(Error::Corrupt("permit is for another address"));
    }
    if !on_local_network(*code.addr.ip()) {
        return Err(Error::Corrupt("p2p address is not on a local network"));
    }
    let stream = TcpStream::connect_timeout(&SocketAddr::V4(code.addr), Duration::from_secs(10))?;
    stream.set_read_timeout(Some(Duration::from_secs(60)))?;
    set_live(stream.try_clone().ok());
    let pk = kdf::restore_pairing_key(&secret);
    let mut ch = match handshake_join(&pk, MODE_RESTORE, &code.token, stream) {
        Ok(ch) => ch,
        // The host could not prove the same words: these are another library's.
        Err(Error::Corrupt("p2p host not proven")) => return Err(Error::WrongSecretKey),
        Err(e) => return Err(e),
    };
    on_check(ch.check);
    let id = String::from_utf8(ch.recv()?).map_err(|_| Error::Corrupt("p2p vault id"))?;
    let remote = ChannelRemote { ch: Mutex::new(ch) };
    let vault = match Library::join(dir, &remote, &id, secret, password) {
        Ok(Some(vault)) => vault,
        Ok(None) => {
            remote.abort(ABORT_WRONG_PASSWORD);
            return Ok(false);
        }
        Err(e) => {
            remote.abort(ABORT_STOPPED);
            return Err(e);
        }
    };
    let synced = vault
        .forget_sync_place(JOIN_KEY)
        .and_then(|_| vault.sync_with(&remote, progress).map(|_| ()));
    if let Err(e) = synced {
        remote.abort(ABORT_STOPPED);
        return Err(e);
    }
    remote.done()?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_round_trip_and_tolerate_typing() {
        let c = PairCode {
            addr: SocketAddrV4::new(Ipv4Addr::new(192, 168, 1, 37), 51234),
            token: [1, 2, 3, 250, 99],
        };
        let typed = c.typed();
        assert_eq!(typed.len(), 20);
        assert_eq!(PairCode::parse(&typed), Some(c.clone()));
        assert_eq!(
            PairCode::parse(&typed.to_lowercase().replace('-', " ")),
            Some(c.clone())
        );
        assert_eq!(PairCode::parse(&c.qr()), Some(c.clone()));
        assert_eq!(PairCode::parse("not a code"), None);
        assert_eq!(PairCode::parse(&typed[..typed.len() - 1]), None);
    }

    use crate::testkit::{note, text, two};

    #[test]
    fn two_devices_sync_over_the_wifi() {
        let t = two();
        let from_a = note(&t.a, "From A", "aaa");
        let from_b = note(&t.b, "From B", "bbb");
        let mirror = tempfile::tempdir().unwrap();
        let h = host(Permit::listen(Ipv4Addr::LOCALHOST)).unwrap();
        let code = PairCode::parse(&h.code.typed()).unwrap();
        let crate::testkit::Two { dirs, a, b, .. } = t;
        let m = mirror.path().to_path_buf();
        // The host on its own thread, as in the app.
        let host_side = std::thread::spawn(move || {
            let seen = Mutex::new(0u16);
            let r = serve_one(&a, h, &m, &|c| *seen.lock().unwrap() = c).unwrap();
            let c = *seen.lock().unwrap();
            (a, r, c)
        });
        let seen = Mutex::new(0u16);
        let joined = join(&b, Permit::connect(code.addr), &code, &|c| {
            *seen.lock().unwrap() = c
        })
        .unwrap();
        let (a, hosted, host_check) = host_side.join().unwrap();
        assert_eq!((joined.received, hosted.received), (1, 1));
        // Both screens showed the same number.
        assert_eq!(*seen.lock().unwrap(), host_check);
        assert_eq!(text(&b, &from_a), "aaa");
        assert_eq!(text(&a, &from_b), "bbb");
        drop(dirs);
    }

    #[test]
    fn the_digits_make_the_token() {
        for _ in 0..50 {
            let t = random_token();
            let c = PairCode {
                addr: SocketAddrV4::new(Ipv4Addr::LOCALHOST, PORT),
                token: t,
            };
            let d = c.digits().unwrap();
            assert_eq!(d.len(), CODE_DIGITS);
            assert_eq!(token_of(&d), Some(t));
        }
        assert_eq!(token_of("12"), None);
        assert_eq!(token_of("1a3"), None);
        assert_eq!(token_of("1234"), None);
        assert_eq!(token_of(" 048 "), token_of("048"));
    }

    #[test]
    fn a_probe_finds_only_the_same_vault_and_only_with_the_right_digits() {
        let t = two();
        let other = two();
        let from_a = note(&t.a, "From A", "aaa");
        let mirror = tempfile::tempdir().unwrap();
        let h = host(Permit::listen(Ipv4Addr::LOCALHOST)).unwrap();
        let addr = h.code.addr;
        let digits = h.code.digits().unwrap();
        let crate::testkit::Two { dirs, a, b, sk, .. } = t;
        let m = mirror.path().to_path_buf();
        let secret = sk.clone();
        let host_side = std::thread::spawn(move || {
            let prepared = host_prepare(&a, Some(&secret), &m).unwrap();
            let seen = Mutex::new(Vec::new());
            let session = host_accept(h, prepared, &AtomicBool::new(false), &|s| {
                seen.lock().unwrap().push(s)
            })
            .unwrap();
            let served = session.serve().unwrap();
            let r = host_finish(&a, served).unwrap();
            (a, r, seen.into_inner().unwrap())
        });
        // Someone who connects and says nothing holds up no one.
        let _silent: Vec<_> = (0..4).map(|_| TcpStream::connect(addr).unwrap()).collect();
        let started = Instant::now();
        // Another vault sees nothing there; probes do not use up the host's tries.
        for _ in 0..4 {
            assert!(probe_all(&[addr], &pairing_key(&other.a), false).is_empty());
        }
        let found = probe_all(&[addr], &pairing_key(&b), false);
        assert_eq!(found.len(), 1);
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
        // The 24 words find it too (a device restoring), a stranger's words do not.
        assert_eq!(
            probe_all(&[addr], &kdf::restore_pairing_key(&sk), true).len(),
            1
        );
        let stranger = crate::testkit::other_words(&sk);
        assert!(probe_all(&[addr], &kdf::restore_pairing_key(&stranger), true).is_empty());
        // Wrong digits match nothing (and reach nobody); the right ones give the code.
        let wrong = format!("{:03}", (digits.parse::<u64>().unwrap() + 1) % CODE_SPACE);
        assert!(Looker::for_vault(&b).find(&found, &wrong).is_none());
        assert!(Looker::for_vault(&other.a).find(&found, &digits).is_none());
        let code = Looker::for_vault(&b).find(&found, &digits).unwrap();
        assert_eq!(code.addr, addr);
        let joined = join(&b, Permit::connect(code.addr), &code, &|_| ()).unwrap();
        let (a, _hosted, seen) = host_side.join().unwrap();
        assert_eq!(joined.received, 1);
        assert_eq!(text(&b, &from_a), "aaa");
        // Only the real session knocked: the probes stayed quiet.
        assert_eq!(seen, vec![Seen::Knock]);
        drop((a, dirs));
    }

    #[test]
    fn a_scan_needs_its_permit_and_a_local_network() {
        let t = two();
        let look = Looker::for_vault(&t.a);
        assert!(look.scan(Permit::listen(Ipv4Addr::LOCALHOST)).is_err());
        assert!(Permit::scan_on("8.8.8.8").is_none());
        assert!(look.scan(Permit::scan_on("127.0.0.1").unwrap()).is_err());
    }

    #[test]
    fn a_device_without_the_vault_cannot_join() {
        let t = two();
        let other = two(); // a different vault: another Master Key
        let h = host(Permit::listen(Ipv4Addr::LOCALHOST)).unwrap();
        let code = h.code.clone();
        let mirror = tempfile::tempdir().unwrap();
        let crate::testkit::Two { dirs, a, .. } = t;
        let m = mirror.path().to_path_buf();
        let host_side = std::thread::spawn(move || {
            serve_one(&a, h, &m, &|_| panic!("no check for strangers")).err()
        });
        // The app tells the person it is another vault, not a network problem.
        let e = join(&other.a, Permit::connect(code.addr), &code, &|_| {
            panic!("not proven")
        })
        .unwrap_err();
        assert!(matches!(e, Error::Corrupt("p2p host not proven")), "{e:?}");
        // The host stops at once and says why (it does not keep waiting).
        let e = host_side.join().unwrap().expect("the host stops");
        assert!(
            matches!(e, Error::Corrupt("p2p joiner not proven")),
            "{e:?}"
        );
        drop(dirs);
    }

    #[test]
    fn a_permit_for_another_address_opens_nothing() {
        let t = two();
        let code = PairCode {
            addr: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 9),
            token: [0; TOKEN_LEN],
        };
        let wrong = Permit::connect(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 10));
        assert!(join(&t.a, wrong, &code, &|_| {}).is_err());
        assert!(host(Permit::connect(code.addr)).is_err());
    }

    fn pair() -> (Channel, Channel) {
        let t = two();
        let pk = pairing_key(&t.a);
        drop(t.b);
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let token = [9u8; TOKEN_LEN];
        let prepared = Prepared {
            key: pk.clone(),
            restore_key: None,
            vault_id: String::new(),
            mirror: PathBuf::new(),
        };
        let h = std::thread::spawn(move || {
            let mut s = l.accept().unwrap().0;
            let hello = read_frame(&mut s).unwrap();
            handshake_host(&prepared, &token, &hello, s).unwrap().0
        });
        let j = handshake_join(&pk, MODE_SYNC, &token, TcpStream::connect(addr).unwrap()).unwrap();
        (h.join().unwrap(), j)
    }

    #[test]
    fn frames_cannot_be_replayed_reordered_or_forged() {
        let (mut h, mut j) = pair();
        j.send(b"one").unwrap();
        assert_eq!(h.recv().unwrap(), b"one");
        // Replay the first frame by hand: it is numbered 0, the host expects 1.
        let aad = "cozysafe/p2p/v1/frame/to-host/0";
        let replay = wrap::seal(&j.send_key, b"one", aad.as_bytes());
        write_frame(&mut j.stream, &replay).unwrap();
        assert!(h.recv().is_err());
        // A frame sealed with the wrong direction's key fails too.
        let (mut h, mut j) = pair();
        let forged = wrap::seal(&j.recv_key, b"x", b"cozysafe/p2p/v1/frame/to-host/0");
        write_frame(&mut j.stream, &forged).unwrap();
        assert!(h.recv().is_err());
    }

    #[test]
    fn requests_outside_the_vault_end_the_session() {
        let (mut h, mut j) = pair();
        let folder_dir = tempfile::tempdir().unwrap();
        let folder = FolderRemote::new(folder_dir.path());
        let server = std::thread::spawn(move || serve(&mut h, &folder, "abcd", &|_| ()));
        let mut msg = vec![OP_GET];
        msg.extend_from_slice(b"other-vault/records/x");
        j.send(&msg).unwrap();
        assert!(server.join().unwrap().is_err());
    }

    #[test]
    fn never_listens_or_connects_outside_the_local_network() {
        let public = Ipv4Addr::new(8, 8, 8, 8);
        assert!(host(Permit::listen(public)).is_err());
        let t = two();
        let code = PairCode {
            addr: SocketAddrV4::new(public, 443),
            token: [0; TOKEN_LEN],
        };
        assert!(join(&t.b, Permit::connect(code.addr), &code, &|_| ()).is_err());
        assert!(on_local_network(Ipv4Addr::new(192, 168, 1, 7)));
        assert!(on_local_network(Ipv4Addr::new(10, 0, 0, 2)));
        assert!(on_local_network(Ipv4Addr::new(172, 20, 0, 2)));
        assert!(!on_local_network(Ipv4Addr::new(172, 32, 0, 2)));
    }

    /// Host a restore for `t.a` (whose library key is `sk`), restore into a fresh folder
    /// with `words` and `password`.
    fn restore_from(
        t: &crate::testkit::Two,
        sk: &SecretKey,
        words: SecretKey,
        password: &str,
    ) -> (Result<bool>, Result<()>, tempfile::TempDir) {
        let mirror = tempfile::tempdir().unwrap();
        let fresh = tempfile::tempdir().unwrap();
        let h = host(Permit::listen(Ipv4Addr::LOCALHOST)).unwrap();
        let code = h.code.clone();
        let prepared = host_prepare(&t.a, Some(sk), mirror.path()).unwrap();
        let server = std::thread::spawn(move || {
            host_accept(h, prepared, &AtomicBool::new(false), &|_| ()).and_then(|s| s.serve())
        });
        let got = restore(
            fresh.path(),
            Permit::connect(code.addr),
            &code,
            words,
            password,
            &|_| (),
            &|_| (),
        );
        // The host always ends: served, or told why the other phone stopped.
        let hosted = server.join().unwrap().map(|_| ());
        (got, hosted, fresh)
    }

    #[test]
    fn a_new_device_restores_with_only_the_words_and_the_password() {
        let t = crate::testkit::two();
        let id = crate::testkit::note(&t.a, "bank", "PIN 4821");
        let sk = t.sk.clone();
        let (got, hosted, dir) = restore_from(&t, &sk, sk.clone(), &t.pw);
        assert!(got.unwrap());
        hosted.unwrap();
        let v = crate::testkit::open(dir.path(), &sk, &t.pw);
        assert_eq!(v.id, t.a.id);
        assert_eq!(crate::testkit::text(&v, &id), "PIN 4821");
    }

    #[test]
    fn a_wrong_password_or_other_words_restore_nothing() {
        let t = crate::testkit::two();
        let sk = t.sk.clone();
        let wrong: String = t.pw.chars().rev().collect();
        let (got, hosted, dir) = restore_from(&t, &sk, sk.clone(), &wrong);
        assert!(!got.unwrap());
        assert!(!Library::has_vaults(dir.path()));
        // The old phone is told, and stops: it does not keep waiting.
        assert!(
            matches!(hosted, Err(Error::Corrupt("p2p restore wrong password"))),
            "{hosted:?}"
        );
        let other = crate::testkit::other_words(&sk);
        let (got, hosted, dir) = restore_from(&t, &sk, other, &t.pw);
        assert!(matches!(got, Err(Error::WrongSecretKey)));
        assert!(!Library::has_vaults(dir.path()));
        assert!(
            matches!(hosted, Err(Error::Corrupt("p2p restore wrong words"))),
            "{hosted:?}"
        );
    }

    #[test]
    fn a_host_without_the_words_turns_a_restoring_device_away() {
        let t = crate::testkit::two();
        let mirror = tempfile::tempdir().unwrap();
        let fresh = tempfile::tempdir().unwrap();
        let h = host(Permit::listen(Ipv4Addr::LOCALHOST)).unwrap();
        let code = h.code.clone();
        let prepared = host_prepare(&t.a, None, mirror.path()).unwrap();
        let server = std::thread::spawn(move || {
            host_accept(h, prepared, &AtomicBool::new(false), &|_| ()).map(|_| ())
        });
        let got = restore(
            fresh.path(),
            Permit::connect(code.addr),
            &code,
            t.sk.clone(),
            &t.pw,
            &|_| (),
            &|_| (),
        );
        assert!(got.is_err());
        cancel_live();
        drop(server);
    }

    #[test]
    fn cancel_stops_the_wait() {
        let t = two();
        let mirror = tempfile::tempdir().unwrap();
        let h = host(Permit::listen(Ipv4Addr::LOCALHOST)).unwrap();
        let prepared = host_prepare(&t.a, None, mirror.path()).unwrap();
        let stop = AtomicBool::new(true);
        let started = Instant::now();
        assert!(host_accept(h, prepared, &stop, &|_| ()).is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
