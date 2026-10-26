//! Sync with another device on the same Wi-Fi, no cloud (docs/adr/0003-sync.md, "P2P
//! security").
//!
//! Both devices open the same screen and wait ([`Waiting::run`]): each listens on its
//! Wi-Fi address and, every few seconds, knocks at [`PORT`] on each address of its own
//! network (`a.b.c.1`–`254`) with a probe. Only a device holding the same vault can answer
//! a probe in a way the other accepts; a stranger on the network learns nothing from one.
//! Each waiting device has a random id (its token); of two that found each other, the one
//! with the lower id connects and the other serves, so there is never a second session.
//!
//! Once connected, both prove they hold the vault (keys derived from its Master Key),
//! then talk through sealed, numbered frames. Only then does each tell the other its name
//! ("iPhone 15 Pro Max"), and both screens ask "Sync with …?" next to the same 3-digit
//! number, as Bluetooth pairing does; nothing is served until both people tapped Sync
//! ([`agree`]). The serving device serves a folder it has just synced the vault into, so
//! the sync itself is the ordinary one ([`OpenVault::sync`]); afterwards it syncs that
//! folder back in to take the other's changes.
//!
//! Several devices with the vault found: none connects on its own. Each learns the
//! others' names through a short handshake of the same kind (sealed, after the proof), and
//! the person picks one; if the picked device holds the lower id, it is asked to connect.
//!
//! A device with no vault yet (restoring) looks the same way with a key from the 24 words
//! instead ([`kdf::restore_pairing_key`]), but only finds devices whose person turned
//! "Help a new device restore" on, and is served only once that person allowed it,
//! comparing the number both screens show ([`Session::allow`]). It then learns the vault's
//! id, and opens the vault's lock with the words and the password ([`Library::join`])
//! before the ordinary sync brings the items.
//!
//! Nothing is advertised on the network: no Bonjour, no broadcast. A QR code (address,
//! port and token) stays for networks where the knock does not get through.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use cs_crypto::{kdf, wrap, Key, SecretKey};
use cs_vault::sync::{FolderRemote, Remote, SyncReport};
use cs_vault::sync::{SyncPhase, SyncProgress};
use cs_vault::{Error, Library, OpenVault, Result};

use crate::Permit;

/// 2 since 0.1.73 (pairing by comparing a number): earlier versions are refused.
const VERSION: u8 = 2;
/// What the joiner comes for, in its hello: sync a vault both hold, or restore it.
const MODE_SYNC: u8 = 1;
const MODE_RESTORE: u8 = 2;
/// Not a session: a device looking for its other device on the Wi-Fi.
const MODE_PROBE: u8 = 3;
/// Not a session: a short handshake that only swaps names (several devices found, the
/// list names them), and may ask the other to connect (the person picked it here).
const MODE_INTRO: u8 = 4;
/// [`MODE_INTRO`] for a device restoring (the 24 words' key).
const MODE_INTRO_RESTORE: u8 = 5;
/// Digits of the number both screens show (owner 2026-10-26: three, like the old code).
pub const CHECK_DIGITS: usize = 3;
const CHECK_SPACE: u16 = 1000;
/// The port a waiting device listens on when it is free, so a nearby device can find it.
pub const PORT: u16 = 47823;
/// Bytes of each tag in a probe's answer.
const TAG_LEN: usize = 16;
/// Bytes of a waiting device's random id. It binds the session (with the vault key) and
/// says which of two devices connects (the lower).
pub const TOKEN_LEN: usize = 5;
pub type Token = [u8; TOKEN_LEN];
const NONCE_LEN: usize = 32;
/// Largest frame on the wire, sealed (1 MiB of payload).
const MAX_FRAME: usize = (1 << 20) + 64;
const CHUNK: usize = 1 << 20;
/// How long a device waits for its other device (time to pick up the other phone).
pub const WAIT_LIFETIME: Duration = Duration::from_secs(300);
/// How long a restoring device waits for the person on the other device to allow it.
pub const ALLOW_WAIT: Duration = Duration::from_secs(180);
/// How long both people have to tap Sync once the devices are connected.
pub const CONFIRM_WAIT: Duration = Duration::from_secs(120);
/// Longest device name kept (characters); longer ones are cut.
pub const NAME_MAX: usize = 40;
/// Time between two looks on the Wi-Fi.
const LOOK_EVERY: Duration = Duration::from_secs(3);
/// Failed handshakes before the waiting device stops.
const MAX_FAILURES: u32 = 3;
/// A session with no request for this long ends.
const IDLE: Duration = Duration::from_secs(600);
/// The place names for this device's sync state (fresh each session).
const HOST_KEY: &str = "p2p-host";
const JOIN_KEY: &str = "p2p-join";
/// One person's answer to "Sync with …?", sent to the other: `[OP_CONFIRM, 1 or 0]`.
const OP_CONFIRM: u8 = 10;

/// Where a waiting device listens and its id: what the QR code carries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairCode {
    pub addr: SocketAddrV4,
    pub token: Token,
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

    /// The code as text: 18 letters and digits in three groups ("4K9M2Q-…").
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

/// A device's id as text, for the screen to name the one the person picks.
pub fn token_text(token: &Token) -> String {
    hex::encode(token)
}

/// [`token_text`] read back.
pub fn token_from_text(text: &str) -> Option<Token> {
    hex::decode(text).ok()?.try_into().ok()
}

/// A device name as it may be shown and logged: no control or direction characters (a
/// name must not make the text around it read otherwise), no `|` (the log's separator),
/// at most [`NAME_MAX`] characters. Names come from the other device: never trusted.
pub fn clean_name(text: &str) -> String {
    let kept: String = text
        .chars()
        .filter(|&c| {
            !c.is_control()
                && c != '|'
                && !matches!(c, '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        .take(NAME_MAX)
        .collect();
    kept.trim().to_owned()
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
    /// The 3-digit number both screens show, to compare.
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

/// Open frame number `n` coming in `dir`. A replayed, reordered, cut or forged frame
/// fails here, and ends the session.
fn open_frame(key: &Key, dir: &str, n: u64, sealed: &[u8]) -> Result<Vec<u8>> {
    let aad = format!("cozysafe/p2p/v1/frame/{dir}/{n}");
    wrap::open(key, sealed, aad.as_bytes())
        .map(|p| p.to_vec())
        .map_err(|_| Error::Corrupt("p2p frame"))
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
        let plain = open_frame(&self.recv_key, self.recv_dir, self.recv_n, &sealed)?;
        self.recv_n += 1;
        Ok(plain)
    }

    /// The receiving side on its own (another handle on the same socket), to read on
    /// another thread while this one sends; [`Channel::rejoin`] takes it back.
    fn split_recv(&self) -> Result<RecvHalf> {
        Ok(RecvHalf {
            stream: self.stream.try_clone()?,
            key: self.recv_key.clone(),
            n: self.recv_n,
            dir: self.recv_dir,
        })
    }

    fn rejoin(&mut self, half: RecvHalf) {
        self.recv_n = half.n;
    }
}

struct RecvHalf {
    stream: TcpStream,
    key: Key,
    n: u64,
    dir: &'static str,
}

impl RecvHalf {
    fn recv(&mut self) -> Result<Vec<u8>> {
        let sealed = read_frame(&mut self.stream)?;
        let plain = open_frame(&self.key, self.dir, self.n, &sealed)?;
        self.n += 1;
        Ok(plain)
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
    let check = (u16::from_be_bytes([c[0], c[1]])) % CHECK_SPACE;
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
    keys: &Keys,
    token: &[u8],
    hello: &[u8],
    mut stream: TcpStream,
) -> Result<(Channel, u8)> {
    if hello.len() != 2 + NONCE_LEN || hello[0] != VERSION {
        return Err(Error::Corrupt("p2p hello"));
    }
    let mode = hello[1];
    let restoring = matches!(mode, MODE_RESTORE | MODE_INTRO_RESTORE);
    let pk = match mode {
        MODE_SYNC | MODE_INTRO => &keys.key,
        // Only while the person has "Help a new device restore" on.
        MODE_RESTORE | MODE_INTRO_RESTORE => keys
            .restore_key
            .as_ref()
            .filter(|_| keys.restore_on.load(Ordering::Relaxed))
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
        return Err(Error::Corrupt(if restoring {
            "p2p restore wrong words"
        } else {
            "p2p joiner not proven"
        }));
    }
    Ok((session(pk, token, nj, &nh, stream, true), mode))
}

/// After the handshake, the joiner says its name and hears the other's: inside the
/// sealed channel only, never in a probe's answer.
fn swap_names_join(ch: &mut Channel, mine: &str) -> Result<String> {
    ch.send(mine.as_bytes())?;
    Ok(clean_name(&String::from_utf8_lossy(&ch.recv()?)))
}

fn swap_names_host(ch: &mut Channel, mine: &str) -> Result<String> {
    let theirs = clean_name(&String::from_utf8_lossy(&ch.recv()?));
    ch.send(mine.as_bytes())?;
    Ok(theirs)
}

/// Both people must say yes. `decide` asks the person on this device ("Sync with …?") and
/// returns their answer; it gets a function that turns true once the other device said
/// no (or went), to stop asking. This device's answer goes to the other either way; the
/// session goes on only when both said yes. Read on a thread meanwhile, so a Cancel
/// there shows here at once.
fn agree(ch: &mut Channel, decide: &dyn Fn(&dyn Fn() -> bool) -> bool) -> Result<()> {
    let mut half = ch.split_recv()?;
    half.stream
        .set_read_timeout(Some(CONFIRM_WAIT + Duration::from_secs(15)))?;
    // None: not yet; Some(None): the other end went; Some(Some(yes)): its answer.
    let said: Arc<Mutex<Option<Option<bool>>>> = Arc::new(Mutex::new(None));
    let reader = {
        let said = said.clone();
        std::thread::spawn(move || {
            let answer = match half.recv() {
                Ok(m) if m == [OP_CONFIRM, 1] => Some(true),
                Ok(m) if m == [OP_CONFIRM, 0] => Some(false),
                _ => None,
            };
            *said.lock().unwrap_or_else(|p| p.into_inner()) = Some(answer);
            half
        })
    };
    let theirs = || *said.lock().unwrap_or_else(|p| p.into_inner());
    let mine = decide(&|| matches!(theirs(), Some(None | Some(false))));
    // What the other had said when this person answered: whose "no" came first.
    let before = theirs();
    let told = ch.send(&[OP_CONFIRM, mine as u8]);
    if !mine {
        // The other answers or closes soon after hearing no; read that first (closing
        // with its answer unread would reset the connection and lose our "no" there),
        // then unblock the reader. The session ends here.
        let until = Instant::now() + Duration::from_secs(3);
        while theirs().is_none() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = ch.stream.shutdown(std::net::Shutdown::Both);
        let _ = reader.join();
        return Err(Error::Corrupt(match before {
            Some(Some(false)) => "p2p peer cancelled",
            Some(None) => "p2p peer stopped",
            _ => "p2p cancelled",
        }));
    }
    told?;
    let half = reader.join().map_err(|_| Error::Corrupt("p2p channel"))?;
    match theirs() {
        Some(Some(true)) => {
            ch.rejoin(half);
            Ok(())
        }
        Some(Some(false)) => Err(Error::Corrupt("p2p peer cancelled")),
        _ => Err(Error::Corrupt("p2p peer stopped")),
    }
}

// ---------- finding the other device on the Wi-Fi ----------

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

fn xor(a: &[u8; TAG_LEN], b: &[u8; TAG_LEN]) -> [u8; TAG_LEN] {
    let mut out = [0u8; TAG_LEN];
    for i in 0..TAG_LEN {
        out[i] = a[i] ^ b[i];
    }
    out
}

/// The token in a 16-byte block, the rest zero (checked on the way back).
fn token_block(token: &Token) -> [u8; TAG_LEN] {
    let mut b = [0u8; TAG_LEN];
    b[..TOKEN_LEN].copy_from_slice(token);
    b
}

/// A waiting device answers a probe: a fresh nonce, then for each key it holds (the
/// vault's, and the 24 words' for a device restoring, while the person allows that) a
/// tag that says "same vault" and its token hidden under a second tag. Random bytes stand
/// in for a key it does not hold or use. No name: names only cross a sealed channel.
fn answer_probe(keys: &Keys, nj: &[u8], stream: &mut TcpStream) -> Result<()> {
    let nh: [u8; NONCE_LEN] = random();
    let mut reply = nh.to_vec();
    let restore = keys
        .restore_key
        .as_ref()
        .filter(|_| keys.restore_on.load(Ordering::Relaxed));
    for pk in [Some(&keys.key), restore] {
        match pk {
            Some(pk) => {
                reply.extend(tag(pk, "vault", nj, &nh));
                reply.extend(xor(&tag(pk, "token", nj, &nh), &token_block(&keys.token)));
            }
            None => reply.extend(random::<{ 2 * TAG_LEN }>()),
        }
    }
    write_frame(stream, &reply)
}

/// What a waiting device needs to answer probes and short handshakes, shared with the
/// threads that read them.
struct Keys {
    key: Key,
    /// From the Recovery Key, to let a device with no vault restore this one.
    restore_key: Option<Key>,
    /// Whether it may, now: the person turns "Help a new device restore" on and off
    /// while the device waits.
    restore_on: Arc<AtomicBool>,
    token: Token,
    name: String,
    /// Devices that asked to be connected to (their person picked this one), by token.
    calls: Mutex<Vec<Token>>,
}

/// Connections read at once (each on its own thread, a few seconds at most): someone
/// who connects and stays silent cannot hold up the device that came to sync.
const MAX_READING: usize = 16;

/// A device on the Wi-Fi that holds the same vault (or takes the same 24 words). Its
/// name is known only after a sealed handshake with it ([`Looker::round`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub addr: SocketAddrV4,
    pub token: Token,
    pub name: Option<String>,
}

/// Knock at `addr` with a probe; the device there if it proves the key `pk`.
fn probe(addr: SocketAddrV4, pk: &Key, restoring: bool) -> Option<Peer> {
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
    let vault_tag = &reply[at..at + TAG_LEN];
    let hidden: [u8; TAG_LEN] = reply[at + TAG_LEN..at + 2 * TAG_LEN].try_into().ok()?;
    if !same(vault_tag, &tag(pk, "vault", &nj, &nh)) {
        return None;
    }
    let block = xor(&tag(pk, "token", &nj, &nh), &hidden);
    if block[TOKEN_LEN..].iter().any(|&b| b != 0) {
        return None;
    }
    Some(Peer {
        addr,
        token: block[..TOKEN_LEN].try_into().ok()?,
        name: None,
    })
}

/// Knock at each of `targets` (half a network at once, each given under a second to
/// connect: a whole /24 in about two seconds); the devices that prove `pk`.
fn probe_all(targets: &[SocketAddrV4], pk: &Key, restoring: bool) -> Vec<Peer> {
    let mut found = Vec::new();
    for chunk in targets.chunks(128) {
        let got: Vec<Peer> = std::thread::scope(|s| {
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

/// The short handshake with a device found: prove the key both ways, then swap names
/// (sealed). With `call`, also ask it to connect to us (`me`): the person picked it here
/// and it holds the lower id. Its name, or none if it did not prove the key.
fn intro(
    peer: &Peer,
    pk: &Key,
    restoring: bool,
    me: Token,
    call: bool,
    name: &str,
) -> Option<String> {
    let stream =
        TcpStream::connect_timeout(&SocketAddr::V4(peer.addr), Duration::from_millis(1500)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(3))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(3)))
        .ok()?;
    let mode = if restoring {
        MODE_INTRO_RESTORE
    } else {
        MODE_INTRO
    };
    let mut ch = handshake_join(pk, mode, &peer.token, stream).ok()?;
    let mut msg = vec![call as u8];
    msg.extend_from_slice(&me);
    msg.extend_from_slice(name.as_bytes());
    ch.send(&msg).ok()?;
    let theirs = ch.recv().ok()?;
    Some(clean_name(&String::from_utf8_lossy(&theirs)))
}

/// The other side of [`intro`], on the thread that read its hello.
fn answer_intro(keys: &Keys, hello: &[u8], stream: TcpStream) -> Result<()> {
    let (mut ch, mode) = handshake_host(keys, &keys.token, hello, stream)?;
    let msg = ch.recv()?;
    ch.send(keys.name.as_bytes())?;
    if mode == MODE_INTRO && msg.len() > TOKEN_LEN && msg[0] == 1 {
        let caller: Token = msg[1..1 + TOKEN_LEN]
            .try_into()
            .map_err(|_| Error::Corrupt("p2p intro"))?;
        let mut calls = keys.calls.lock().unwrap_or_else(|p| p.into_inner());
        if calls.len() < 16 && !calls.contains(&caller) {
            calls.push(caller);
        }
    }
    Ok(())
}

/// The addresses a look may knock at: every address of this device's network
/// (`a.b.c.1`–`254`, not its own) at [`PORT`].
fn targets(permit: &Permit) -> Result<Vec<SocketAddrV4>> {
    #[cfg(test)]
    if let Some(list) = permit.scan_list() {
        return Ok(list.to_vec());
    }
    let own = permit
        .scan_from()
        .ok_or(Error::Corrupt("permit is not for looking"))?;
    if !on_local_network(own) || own.is_loopback() {
        return Err(Error::Corrupt("p2p address is not on a local network"));
    }
    let [a, b, c, me] = own.octets();
    Ok((1..=254u8)
        .filter(|&d| d != me)
        .map(|d| SocketAddrV4::new(Ipv4Addr::new(a, b, c, d), PORT))
        .collect())
}

/// Whether a look under `permit` may also connect to `addr` (a device it found there).
fn covers(permit: &Permit, addr: SocketAddrV4) -> bool {
    targets(permit).is_ok_and(|t| t.contains(&addr))
}

/// What a device looking for its other device proves: the vault's pairing key, or the
/// 24 words' when it has no vault yet. Made from the vault in a moment, so the vault is
/// not held while the Wi-Fi is searched.
#[derive(Clone)]
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

    /// Look on the permitted Wi-Fi. A few seconds.
    pub fn scan(&self, permit: Permit) -> Result<Vec<Peer>> {
        Ok(probe_all(&targets(&permit)?, &self.pk, self.restoring))
    }

    /// One look, never finding `me` (this device's own listener), and, when there are
    /// several, the names of those not in `known` (one short handshake each).
    fn round(
        &self,
        permit: Permit,
        me: Option<Token>,
        known: &HashMap<Token, String>,
        name: &str,
    ) -> Vec<Peer> {
        let mut peers = self.scan(permit).unwrap_or_default();
        peers.retain(|p| Some(p.token) != me);
        peers.sort_by_key(|p| p.token);
        peers.dedup_by_key(|p| p.token);
        for p in &mut peers {
            p.name = known.get(&p.token).cloned();
        }
        if peers.len() >= 2 {
            for p in peers.iter_mut().filter(|p| p.name.is_none()) {
                p.name = intro(
                    p,
                    &self.pk,
                    self.restoring,
                    me.unwrap_or_default(),
                    false,
                    name,
                );
            }
        }
        peers
    }
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

/// The open vault, only for the moments it is needed: the app keeps it free while
/// waiting, while the people decide and while the other device works.
pub trait Access {
    fn with(&self, f: &mut dyn FnMut(&OpenVault) -> Result<()>) -> Result<()>;
}

impl Access for OpenVault {
    fn with(&self, f: &mut dyn FnMut(&OpenVault) -> Result<()>) -> Result<()> {
        f(self)
    }
}

/// What the waiting device sees before a session starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Seen {
    /// A device connected; it is proving it holds the vault.
    Knock,
    /// It could not, and was turned away.
    Rejected,
}

/// "Sync with `name`?" next to the number; the third argument turns true once the other
/// person said no. True for Sync.
pub type Confirm<'a> = dyn Fn(&str, u16, &dyn Fn() -> bool) -> bool + 'a;

/// What the person sees and says while two devices pair.
pub struct Ask<'a> {
    pub seen: &'a dyn Fn(Seen),
    /// The devices with this vault found on the Wi-Fi, each time that changes (with
    /// names when there are several: the person picks one).
    pub found: &'a dyn Fn(&[Peer]),
    /// Several found: the token of the one the person picked, if they did (asked again
    /// until it answers).
    pub picked: &'a dyn Fn() -> Option<Token>,
    /// Connected to the device named so, which proved the vault: "Sync with …?", with
    /// the number both screens show. True for Sync. The function it gets turns true once
    /// the other person said no (or the other device went): stop asking then.
    pub confirm: &'a Confirm<'a>,
    /// A new device (named so) restoring with the 24 words asks to come in: allow it?
    pub allow: &'a dyn Fn(&str, u16) -> bool,
    pub progress: &'a dyn Fn(SyncProgress),
}

/// Two devices paired and synced.
#[derive(Debug)]
pub struct Paired {
    /// The other device's name, as it said it (cleaned).
    pub name: String,
    pub report: SyncReport,
    /// Whether this device served (the other connected to it).
    pub hosted: bool,
}

/// The waiting device's side, prepared from the vault in a moment.
pub struct Prepared {
    keys: Arc<Keys>,
    vault_id: String,
    mirror: PathBuf,
}

/// Sync the vault into `mirror` (an empty private folder) for the other device to read,
/// and make the keys a waiting device answers with. `name` is this device's, told to the
/// other only inside a sealed channel. With the library's Recovery Key, a device
/// restoring with the 24 words may come too, while the person has that on.
pub fn host_prepare(
    vault: &OpenVault,
    secret: Option<&SecretKey>,
    name: &str,
    mirror: &Path,
) -> Result<Prepared> {
    let folder = FolderRemote::with_key(mirror, HOST_KEY);
    // Fresh folder, fresh state: everything goes into it.
    vault.forget_sync_place(HOST_KEY)?;
    vault.sync(&folder)?;
    Ok(Prepared {
        keys: Arc::new(Keys {
            key: pairing_key(vault),
            restore_key: secret.map(kdf::restore_pairing_key),
            restore_on: Arc::new(AtomicBool::new(secret.is_some())),
            token: random(),
            name: clean_name(name),
            calls: Mutex::new(Vec::new()),
        }),
        vault_id: vault.id.clone(),
        mirror: mirror.to_path_buf(),
    })
}

/// A device waiting on the local network for its other device.
pub struct Waiting {
    listener: TcpListener,
    /// Where it listens and its id: the QR code.
    pub code: PairCode,
    deadline: Instant,
    prepared: Prepared,
}

/// Start listening on the permitted Wi-Fi address at `port` ([`PORT`] in the app, so the
/// other device can find this one; any port if it is taken, and then only the QR works).
pub fn wait(prepared: Prepared, permit: Permit, port: u16) -> Result<Waiting> {
    let ip = permit
        .listen_ip()
        .ok_or(Error::Corrupt("permit is not for listening"))?;
    if !on_local_network(ip) {
        return Err(Error::Corrupt("p2p address is not on a local network"));
    }
    let listener = TcpListener::bind(SocketAddrV4::new(ip, port))
        .or_else(|_| TcpListener::bind(SocketAddrV4::new(ip, 0)))?;
    let port = listener.local_addr()?.port();
    Ok(Waiting {
        listener,
        code: PairCode {
            addr: SocketAddrV4::new(ip, port),
            token: prepared.keys.token,
        },
        deadline: Instant::now() + WAIT_LIFETIME,
        prepared,
    })
}

/// Read one waiting connection's first frame, on its own thread: a probe or an intro is
/// answered there; a session's hello goes back to the waiting loop.
fn accept_some(
    listener: &TcpListener,
    keys: &Arc<Keys>,
    reading: &Arc<AtomicUsize>,
    hellos: &mpsc::Sender<(TcpStream, Vec<u8>)>,
) -> Result<bool> {
    let stream = match listener.accept() {
        Ok((stream, _)) => stream,
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(false),
        Err(e) => return Err(e.into()),
    };
    if reading.load(Ordering::Relaxed) >= MAX_READING {
        return Ok(true); // too many at once: this one is dropped
    }
    reading.fetch_add(1, Ordering::Relaxed);
    let (keys, reading, hellos) = (keys.clone(), reading.clone(), hellos.clone());
    std::thread::spawn(move || {
        let mut stream = stream;
        let hello = stream
            .set_nonblocking(false)
            .and_then(|_| stream.set_read_timeout(Some(Duration::from_secs(3))))
            .and_then(|_| stream.set_write_timeout(Some(Duration::from_secs(3))))
            .map_err(Error::from)
            .and_then(|_| read_frame(&mut stream));
        match hello {
            // A device looking for its other device: answer here. Probes and intros do
            // not count as tries (a look knocks every few seconds).
            Ok(h) if h.len() == 2 + NONCE_LEN && h[0] == VERSION && h[1] == MODE_PROBE => {
                let _ = answer_probe(&keys, &h[2..], &mut stream);
            }
            Ok(h)
                if h.len() == 2 + NONCE_LEN
                    && h[0] == VERSION
                    && matches!(h[1], MODE_INTRO | MODE_INTRO_RESTORE) =>
            {
                let _ = answer_intro(&keys, &h, stream);
            }
            Ok(h) => {
                let _ = hellos.send((stream, h));
            }
            Err(_) => {} // not a Cozy Safe device, or gone
        }
        reading.fetch_sub(1, Ordering::Relaxed);
    });
    Ok(true)
}

/// Whom to connect to now, if anyone: the device the person picked, one that asked
/// (its person picked this one), or the only one found when this device holds the lower
/// id. The other, with the higher id, waits to be connected to: never two sessions.
fn target(
    me: Token,
    peers: &[Peer],
    picked: Option<Token>,
    calls: &mut Vec<Token>,
) -> Option<Peer> {
    let find = |t: &Token| peers.iter().find(|p| &p.token == t).cloned();
    if let Some(p) = picked.as_ref().and_then(find) {
        return Some(p);
    }
    if let Some(i) = calls
        .iter()
        .position(|t| find(t).is_some_and(|p| me < p.token))
    {
        return find(&calls.remove(i));
    }
    match peers {
        [only] if me < only.token => Some(only.clone()),
        _ => None,
    }
}

impl Waiting {
    /// Whether the device has [`PORT`], so the other can find it (else the QR only).
    pub fn findable(&self) -> bool {
        self.code.addr.port() == PORT
    }

    /// "Help a new device restore", to turn on and off while waiting (no effect without
    /// the Recovery Key). A device already let in is not affected.
    pub fn help_restore(&self) -> Arc<AtomicBool> {
        self.prepared.keys.restore_on.clone()
    }

    /// Wait for the other device and look for it (`look` gives a permit for each look,
    /// or none to skip it), until the two pair and sync, the wait runs out, three failed
    /// tries, or `stop` is set (the person tapped Cancel).
    pub fn run(
        self,
        vault: &dyn Access,
        look: &dyn Fn() -> Option<Permit>,
        ask: &Ask,
        stop: &AtomicBool,
    ) -> Result<Paired> {
        let Waiting {
            listener,
            code: _,
            deadline,
            prepared,
        } = self;
        listener.set_nonblocking(true)?;
        let keys = prepared.keys.clone();
        let me = keys.token;
        let looker = Arc::new(Looker {
            pk: keys.key.clone(),
            restoring: false,
        });
        let reading = Arc::new(AtomicUsize::new(0));
        // Hellos read on their own threads come back here.
        let (hellos, came) = mpsc::channel::<(TcpStream, Vec<u8>)>();
        let mut round: Option<std::thread::JoinHandle<Vec<Peer>>> = None;
        let mut next_look = Instant::now();
        let mut peers: Vec<Peer> = Vec::new();
        let mut names: HashMap<Token, String> = HashMap::new();
        let mut calls: Vec<Token> = Vec::new();
        let mut failures = 0;
        loop {
            if stop.load(Ordering::Relaxed) {
                return Err(Error::Corrupt("p2p cancelled"));
            }
            if Instant::now() > deadline {
                return Err(Error::Corrupt("p2p code expired"));
            }
            let mut busy = accept_some(&listener, &keys, &reading, &hellos)?;
            // A device came to sync (or to restore).
            if let Ok((stream, hello)) = came.try_recv() {
                (ask.seen)(Seen::Knock);
                stream.set_read_timeout(Some(Duration::from_secs(20)))?;
                match handshake_host(&keys, &me, &hello, stream) {
                    Ok((ch, mode)) => {
                        drop(listener); // one session
                        return host_side(ch, mode, prepared, vault, ask, stop);
                    }
                    // A Cozy Safe device that could not prove itself (it came by the QR,
                    // since a look never finds this one for it): stop and say so.
                    Err(
                        e @ Error::Corrupt("p2p restore wrong words" | "p2p joiner not proven"),
                    ) => {
                        (ask.seen)(Seen::Rejected);
                        return Err(e);
                    }
                    Err(_) => {
                        failures += 1;
                        if failures >= MAX_FAILURES {
                            return Err(Error::Corrupt("p2p too many failed tries"));
                        }
                    }
                }
                busy = true;
            }
            // A look finished: who is there now.
            if round.as_ref().is_some_and(|h| h.is_finished()) {
                let got = round.take().and_then(|h| h.join().ok()).unwrap_or_default();
                for p in &got {
                    if let Some(n) = &p.name {
                        names.insert(p.token, n.clone());
                    }
                }
                if got != peers {
                    (ask.found)(&got);
                }
                peers = got;
            }
            if round.is_none() && Instant::now() >= next_look {
                next_look = Instant::now() + LOOK_EVERY;
                if let Some(permit) = look() {
                    let (looker, known, name) = (looker.clone(), names.clone(), keys.name.clone());
                    round = Some(std::thread::spawn(move || {
                        looker.round(permit, Some(me), &known, &name)
                    }));
                }
            }
            for t in std::mem::take(&mut *keys.calls.lock().unwrap_or_else(|p| p.into_inner())) {
                if !calls.contains(&t) {
                    calls.push(t);
                }
            }
            let picked = if peers.len() >= 2 {
                (ask.picked)()
            } else {
                None
            };
            if let Some(p) = target(me, &peers, picked, &mut calls) {
                // Only where the person allowed looking.
                if look().is_some_and(|permit| covers(&permit, p.addr)) {
                    if me < p.token {
                        match connect_join(&looker.pk, p.addr, &p.token) {
                            Ok(ch) => {
                                drop(listener);
                                return join_side(ch, &keys.name, vault, ask, stop);
                            }
                            // Gone meanwhile: the next look tells.
                            Err(_) => peers.retain(|x| x.token != p.token),
                        }
                    } else {
                        // It holds the lower id: ask it to connect to this one.
                        let _ = intro(&p, &looker.pk, false, me, true, &keys.name);
                    }
                }
                busy = true;
            }
            if !busy {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

/// Connect to the device at `addr` and prove the vault (`pk`).
fn connect_join(pk: &Key, addr: SocketAddrV4, token: &Token) -> Result<Channel> {
    let stream = TcpStream::connect_timeout(&SocketAddr::V4(addr), Duration::from_secs(10))?;
    stream.set_read_timeout(Some(Duration::from_secs(60)))?;
    handshake_join(pk, MODE_SYNC, token, stream)
}

/// Ask both people ("Sync with `name`?"); Cancel ends the wait.
fn confirm(ch: &mut Channel, name: &str, ask: &Ask, stop: &AtomicBool) -> Result<()> {
    let check = ch.check;
    agree(ch, &|peer_no| {
        !stop.load(Ordering::Relaxed) && (ask.confirm)(name, check, peer_no)
    })
}

/// The device that connected: names, both people say yes, then the sync (the vault held
/// only for that).
fn join_side(
    ch: Channel,
    name: &str,
    vault: &dyn Access,
    ask: &Ask,
    stop: &AtomicBool,
) -> Result<Paired> {
    set_live(ch.stream.try_clone().ok());
    let paired = (|| {
        let mut ch = ch;
        let theirs = swap_names_join(&mut ch, name)?;
        confirm(&mut ch, &theirs, ask, stop)?;
        ch.stream.set_read_timeout(Some(Duration::from_secs(60)))?;
        let mut ch = Some(ch);
        let mut report = None;
        vault.with(&mut |v| {
            let ch = ch.take().ok_or(Error::Corrupt("p2p channel"))?;
            report = Some(sync_over(v, ch, ask.progress)?);
            Ok(())
        })?;
        Ok(Paired {
            name: theirs,
            report: report.ok_or(Error::Corrupt("p2p channel"))?,
            hosted: false,
        })
    })();
    set_live(None);
    paired
}

/// The device connected to: names, then both people say yes (or, for a new device
/// restoring, this person allows it), then it serves, then takes the other's changes in.
fn host_side(
    ch: Channel,
    mode: u8,
    prepared: Prepared,
    vault: &dyn Access,
    ask: &Ask,
    stop: &AtomicBool,
) -> Result<Paired> {
    set_live(ch.stream.try_clone().ok());
    let paired = (|| {
        let mut ch = ch;
        let theirs = swap_names_host(&mut ch, &prepared.keys.name)?;
        let restoring = mode == MODE_RESTORE;
        if !restoring {
            confirm(&mut ch, &theirs, ask, stop)?;
        }
        ch.stream.set_read_timeout(Some(IDLE))?;
        let session = Session {
            check: ch.check,
            ch,
            vault_id: prepared.vault_id,
            mirror: prepared.mirror,
            restoring,
            allowed: !restoring,
        };
        let session = allowed(session, &|check| (ask.allow)(&theirs, check))?;
        let mut served = Some(session.serve_with(ask.progress)?);
        let mut report = None;
        vault.with(&mut |v| {
            let served = served.take().ok_or(Error::Corrupt("p2p channel"))?;
            report = Some(host_finish_with(v, served, ask.progress)?);
            Ok(())
        })?;
        Ok(Paired {
            name: theirs,
            report: report.ok_or(Error::Corrupt("p2p channel"))?,
            hosted: true,
        })
    })();
    set_live(None);
    paired
}

/// The connecting device syncs with the other's folder through the channel, then says
/// done (or why it stopped).
fn sync_over(v: &OpenVault, ch: Channel, progress: &dyn Fn(SyncProgress)) -> Result<SyncReport> {
    v.forget_sync_place(JOIN_KEY)?;
    let remote = ChannelRemote { ch: Mutex::new(ch) };
    match v.sync_with(&remote, progress) {
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

/// A device proven to hold the vault (or the 24 words), connected to this one.
pub struct Session {
    ch: Channel,
    vault_id: String,
    mirror: PathBuf,
    /// The number both screens show.
    pub check: u16,
    restoring: bool,
    /// Served only once true: after both said yes for the same vault, after
    /// [`Session::allow`] for a restoring device.
    allowed: bool,
}

impl Session {
    /// A restoring device (24 words, no vault): the person allows it ([`Session::allow`])
    /// or not ([`Session::refuse`]) before anything is served.
    pub fn restoring(&self) -> bool {
        self.restoring
    }

    /// The person allowed the restoring device: tell it which vault (it does not know
    /// yet), then [`Session::serve`].
    pub fn allow(&mut self) -> Result<()> {
        if self.restoring && !self.allowed {
            self.ch.send(self.vault_id.as_bytes())?;
            self.allowed = true;
        }
        Ok(())
    }

    /// The person did not allow it: tell it we stopped (it shows so), serve nothing.
    pub fn refuse(mut self) {
        let _ = self.ch.send(&[OP_ABORT, ABORT_STOPPED]);
    }

    /// Answer the other device until it is done.
    pub fn serve(self) -> Result<Served> {
        self.serve_with(&|_| ())
    }

    /// [`Session::serve`], telling `progress` the files and bytes that crossed.
    pub fn serve_with(mut self, progress: &dyn Fn(SyncProgress)) -> Result<Served> {
        if !self.allowed {
            return Err(Error::Corrupt("p2p restore not allowed"));
        }
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

/// The other device is done; its changes wait in the mirror.
pub struct Served {
    mirror: PathBuf,
}

/// Take the other device's changes in.
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

/// A restoring device goes on only if the person allows it; the same vault at once.
fn allowed(mut session: Session, allow: &dyn Fn(u16) -> bool) -> Result<Session> {
    if session.restoring() {
        // The socket is live meanwhile, so Cancel can end the wait.
        set_live(session.ch.stream.try_clone().ok());
        let yes = allow(session.check);
        set_live(None);
        if !yes {
            session.refuse();
            return Err(Error::Corrupt("p2p restore declined"));
        }
        session.allow()?;
    }
    Ok(session)
}

/// Join the device whose QR was read (the permit must be for that address): prove we
/// hold the vault, both people say yes, then sync. For networks where looking does not
/// get through.
pub fn join_code(
    vault: &dyn Access,
    permit: Permit,
    code: &PairCode,
    name: &str,
    ask: &Ask,
    stop: &AtomicBool,
) -> Result<Paired> {
    if permit.connect_to() != Some(code.addr) {
        return Err(Error::Corrupt("permit is for another address"));
    }
    if !on_local_network(*code.addr.ip()) {
        return Err(Error::Corrupt("p2p address is not on a local network"));
    }
    let mut pk = None;
    vault.with(&mut |v| {
        pk = Some(pairing_key(v));
        Ok(())
    })?;
    let pk = pk.ok_or(Error::Corrupt("p2p key"))?;
    let ch = connect_join(&pk, code.addr, &code.token)?;
    join_side(ch, &clean_name(name), vault, ask, stop)
}

/// Restore onto this device (`dir`, no vault in it) the vault of the device whose QR was
/// read, with only the 24 words and the password: pair with a key from the words, open
/// the vault's lock, then sync its items in. False for a wrong password;
/// [`Error::WrongSecretKey`] when the other device does not take these words.
/// `connected` gets the other's name and the number to compare. The vault is then
/// opened the usual way, from `dir` with the two secrets: nothing that came over the
/// network is handed back.
#[allow(clippy::too_many_arguments)]
pub fn restore(
    dir: &Path,
    permit: Permit,
    code: &PairCode,
    secret: SecretKey,
    password: &str,
    name: &str,
    connected: &dyn Fn(&str, u16),
    progress: &dyn Fn(SyncProgress),
) -> Result<bool> {
    if permit.connect_to() != Some(code.addr) {
        return Err(Error::Corrupt("permit is for another address"));
    }
    restore_at(dir, code, secret, password, name, connected, progress)
}

fn restore_at(
    dir: &Path,
    code: &PairCode,
    secret: SecretKey,
    password: &str,
    name: &str,
    connected: &dyn Fn(&str, u16),
    progress: &dyn Fn(SyncProgress),
) -> Result<bool> {
    set_live(None);
    let out = restore_inner(dir, code, secret, password, name, connected, progress);
    set_live(None);
    out
}

fn restore_inner(
    dir: &Path,
    code: &PairCode,
    secret: SecretKey,
    password: &str,
    name: &str,
    connected: &dyn Fn(&str, u16),
    progress: &dyn Fn(SyncProgress),
) -> Result<bool> {
    if !on_local_network(*code.addr.ip()) {
        return Err(Error::Corrupt("p2p address is not on a local network"));
    }
    let stream = TcpStream::connect_timeout(&SocketAddr::V4(code.addr), Duration::from_secs(10))?;
    stream.set_read_timeout(Some(Duration::from_secs(60)))?;
    set_live(stream.try_clone().ok());
    let pk = kdf::restore_pairing_key(&secret);
    let mut ch = match handshake_join(&pk, MODE_RESTORE, &code.token, stream) {
        Ok(ch) => ch,
        // The other could not prove the same words: these are another library's.
        Err(Error::Corrupt("p2p host not proven")) => return Err(Error::WrongSecretKey),
        Err(e) => return Err(e),
    };
    let theirs = swap_names_join(&mut ch, &clean_name(name))?;
    connected(&theirs, ch.check);
    // The person on the other device allows this one first (or not): wait for them.
    ch.stream.set_read_timeout(Some(ALLOW_WAIT))?;
    let first = ch.recv()?;
    ch.stream.set_read_timeout(Some(Duration::from_secs(60)))?;
    if first.first() == Some(&OP_ABORT) && first.len() == 2 {
        return Err(Error::Corrupt("p2p peer stopped"));
    }
    let id = String::from_utf8(first).map_err(|_| Error::Corrupt("p2p vault id"))?;
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

/// What the person on a new device sees and says while it looks for the old one.
pub struct RestoreAsk<'a> {
    /// The devices that take these words, each time that changes (named when several).
    pub found: &'a dyn Fn(&[Peer]),
    /// Several found: the one the person picked.
    pub picked: &'a dyn Fn() -> Option<Token>,
    /// Connected: the other's name and the number to compare (its person allows next).
    pub connected: &'a dyn Fn(&str, u16),
    pub progress: &'a dyn Fn(SyncProgress),
}

/// Look on the Wi-Fi (`look` gives a permit for each look) for a device that takes these
/// 24 words, whose person turned "Help a new device restore" on, and restore from it
/// ([`restore`]): at once when there is one, the one the person picks when several.
#[allow(clippy::too_many_arguments)]
pub fn restore_nearby(
    dir: &Path,
    look: &dyn Fn() -> Option<Permit>,
    secret: SecretKey,
    password: &str,
    name: &str,
    ask: &RestoreAsk,
    stop: &AtomicBool,
) -> Result<bool> {
    let looker = Looker::for_words(&secret);
    let name = clean_name(name);
    let deadline = Instant::now() + WAIT_LIFETIME;
    let mut peers: Vec<Peer> = Vec::new();
    let mut names: HashMap<Token, String> = HashMap::new();
    let mut told = false;
    let mut next_look = Instant::now();
    loop {
        if stop.load(Ordering::Relaxed) {
            return Err(Error::Corrupt("p2p cancelled"));
        }
        if Instant::now() > deadline {
            return Err(Error::Corrupt("p2p code expired"));
        }
        let picked = if peers.len() >= 2 {
            (ask.picked)()
        } else {
            None
        };
        let to = match (picked, peers.as_slice()) {
            (Some(t), _) => peers.iter().find(|p| p.token == t).cloned(),
            (None, [only]) => Some(only.clone()),
            _ => None,
        };
        if let Some(p) = to {
            if look().is_some_and(|permit| covers(&permit, p.addr)) {
                let code = PairCode {
                    addr: p.addr,
                    token: p.token,
                };
                return restore_at(
                    dir,
                    &code,
                    secret,
                    password,
                    &name,
                    ask.connected,
                    ask.progress,
                );
            }
        }
        if Instant::now() >= next_look {
            next_look = Instant::now() + LOOK_EVERY;
            if let Some(permit) = look() {
                let got = looker.round(permit, None, &names, &name);
                for p in &got {
                    if let Some(n) = &p.name {
                        names.insert(p.token, n.clone());
                    }
                }
                if got != peers || !told {
                    (ask.found)(&got);
                    told = true;
                }
                peers = got;
                if peers.len() == 1 {
                    continue; // go at once
                }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{note, text, two, Two};

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

    #[test]
    fn names_are_cleaned_before_they_are_shown_or_logged() {
        assert_eq!(clean_name("  iPhone 15 Pro Max "), "iPhone 15 Pro Max");
        assert_eq!(clean_name("Pix\u{202e}el|9\n\u{2066}"), "Pixel9");
        assert_eq!(clean_name(&"x".repeat(100)).chars().count(), NAME_MAX);
        assert_eq!(clean_name("\u{1}\u{7f}"), "");
    }

    /// A device waiting on this computer, at a random port (tests run side by side).
    fn waiting(v: &OpenVault, secret: Option<&SecretKey>, name: &str, mirror: &Path) -> Waiting {
        let prepared = host_prepare(v, secret, name, mirror).unwrap();
        wait(prepared, Permit::listen(Ipv4Addr::LOCALHOST), 0).unwrap()
    }

    /// What the person does in a test, and what they were shown.
    #[derive(Default)]
    struct Person {
        /// Their answer to "Sync with …?" (None: wait until the other says no).
        sync: Option<bool>,
        allow: bool,
        pick: Mutex<Option<Token>>,
        found: Mutex<Vec<Vec<Peer>>>,
        asked: Mutex<Vec<(String, u16)>>,
    }

    impl Person {
        fn says(yes: bool) -> Person {
            Person {
                sync: Some(yes),
                allow: true,
                ..Person::default()
            }
        }
    }

    fn run_as(
        w: Waiting,
        v: &OpenVault,
        others: Vec<SocketAddrV4>,
        me: &Person,
        stop: &AtomicBool,
    ) -> Result<Paired> {
        let look = || Some(Permit::scan_at(others.clone()));
        let confirm = |name: &str, check: u16, peer_no: &dyn Fn() -> bool| {
            me.asked.lock().unwrap().push((name.to_owned(), check));
            match me.sync {
                Some(yes) => yes,
                None => {
                    let until = Instant::now() + Duration::from_secs(10);
                    while !peer_no() && Instant::now() < until {
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    false
                }
            }
        };
        let ask = Ask {
            seen: &|_| (),
            found: &|p| me.found.lock().unwrap().push(p.to_vec()),
            picked: &|| me.pick.lock().unwrap().take(),
            confirm: &confirm,
            allow: &|_, _| me.allow,
            progress: &|_| (),
        };
        w.run(v, &look, &ask, stop)
    }

    #[test]
    fn two_devices_find_each_other_and_sync_once_both_say_yes() {
        let t = two();
        let from_a = note(&t.a, "From A", "aaa");
        let from_b = note(&t.b, "From B", "bbb");
        let (ma, mb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let wa = waiting(&t.a, None, "Phone A", ma.path());
        let wb = waiting(&t.b, None, "Tablet B", mb.path());
        let (ca, cb) = (wa.code.clone(), wb.code.clone());
        let Two { dirs, a, b, .. } = t;
        let side = |w: Waiting, v: OpenVault, other: SocketAddrV4| {
            std::thread::spawn(move || {
                let me = Person::says(true);
                let r = run_as(w, &v, vec![other], &me, &AtomicBool::new(false));
                (v, r, me)
            })
        };
        let (ha, hb) = (side(wa, a, cb.addr), side(wb, b, ca.addr));
        let (a, ra, pa) = ha.join().unwrap();
        let (b, rb, pb) = hb.join().unwrap();
        let (ra, rb) = (ra.unwrap(), rb.unwrap());
        // Each learned the other's name, inside the session.
        assert_eq!(
            (ra.name.as_str(), rb.name.as_str()),
            ("Tablet B", "Phone A")
        );
        // The lower id connected, the other served: one session, not two.
        assert_ne!(ra.hosted, rb.hosted);
        assert_eq!(ra.hosted, ca.token > cb.token);
        // Both were asked once, with the same 3-digit number.
        let (qa, qb) = (
            pa.asked.lock().unwrap().clone(),
            pb.asked.lock().unwrap().clone(),
        );
        assert_eq!((qa.len(), qb.len()), (1, 1));
        assert_eq!(qa[0].1, qb[0].1);
        assert!(qa[0].1 < 1000);
        assert_eq!(text(&b, &from_a), "aaa");
        assert_eq!(text(&a, &from_b), "bbb");
        drop(dirs);
    }

    /// Pair two devices where the people answer `a` and `b`; what each run ended with.
    fn pair_answering(
        a_says: Person,
        b_says: Person,
    ) -> (Result<Paired>, Result<Paired>, Two, String) {
        let t = two();
        let from_a = note(&t.a, "From A", "aaa");
        let (ma, mb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let wa = waiting(&t.a, None, "A", ma.path());
        let wb = waiting(&t.b, None, "B", mb.path());
        let (aa, ab) = (wa.code.addr, wb.code.addr);
        let Two { dirs, a, b, sk, pw } = t;
        let hb = std::thread::spawn(move || {
            let r = run_as(wb, &b, vec![aa], &b_says, &AtomicBool::new(false));
            (b, r)
        });
        let ra = run_as(wa, &a, vec![ab], &a_says, &AtomicBool::new(false));
        let (b, rb) = hb.join().unwrap();
        (ra, rb, Two { dirs, a, b, sk, pw }, from_a)
    }

    #[test]
    fn nothing_is_served_unless_both_say_yes() {
        let (ra, rb, t, from_a) = pair_answering(Person::says(true), Person::says(false));
        assert!(
            matches!(ra, Err(Error::Corrupt("p2p peer cancelled"))),
            "{ra:?}"
        );
        assert!(matches!(rb, Err(Error::Corrupt("p2p cancelled"))), "{rb:?}");
        // No session reached the sync: B has nothing of A's.
        assert!(t.b.read_item(&from_a, &mut Vec::new()).is_err());
    }

    #[test]
    fn a_cancel_on_one_device_stops_the_other_at_once() {
        let waiting_one = Person {
            sync: None,
            ..Person::default()
        };
        let started = Instant::now();
        let (ra, rb, _t, _) = pair_answering(Person::says(false), waiting_one);
        assert!(matches!(ra, Err(Error::Corrupt("p2p cancelled"))), "{ra:?}");
        // The other stopped asking as soon as the "no" came (not after its 10 s wait).
        assert!(
            matches!(rb, Err(Error::Corrupt("p2p peer cancelled"))),
            "{rb:?}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(8),
            "{:?}",
            started.elapsed()
        );
    }

    /// Stop `flag` after `secs` (the person leaves the screen).
    fn stop_after(flag: &Arc<AtomicBool>, secs: u64) {
        let flag = flag.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(secs));
            flag.store(true, Ordering::Relaxed);
        });
    }

    #[test]
    fn a_device_with_another_vault_is_never_found() {
        let t = two();
        let other = two();
        let (ma, mo) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let wa = waiting(&t.a, Some(&t.sk), "Mine", ma.path());
        let wo = waiting(&other.a, None, "Stranger", mo.path());
        let (aa, ao) = (wa.code.addr, wo.code.addr);
        let Two { a, dirs, .. } = t;
        let stop = Arc::new(AtomicBool::new(false));
        stop_after(&stop, 4);
        let s2 = stop.clone();
        let Two {
            a: oa, dirs: odirs, ..
        } = other;
        let ho = std::thread::spawn(move || {
            let me = Person::says(true);
            let r = run_as(wo, &oa, vec![aa], &me, &s2);
            (r, me)
        });
        let me = Person::says(true);
        let ra = run_as(wa, &a, vec![ao], &me, &stop);
        let (ro, them) = ho.join().unwrap();
        assert!(matches!(ra, Err(Error::Corrupt("p2p cancelled"))));
        assert!(matches!(ro, Err(Error::Corrupt("p2p cancelled"))));
        // Nobody listed, nobody asked.
        for p in [&me, &them] {
            assert!(p.found.lock().unwrap().iter().all(|f| f.is_empty()));
            assert!(p.asked.lock().unwrap().is_empty());
        }
        drop((dirs, odirs));
    }

    #[test]
    fn names_cross_only_after_the_handshake() {
        let t = two();
        let other = two();
        let mirror = tempfile::tempdir().unwrap();
        let name = "Kitchen iPad";
        let w = waiting(&t.a, None, name, mirror.path());
        let code = w.code.clone();
        let Two { a, b, dirs, .. } = t;
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = stop.clone();
        let host = std::thread::spawn(move || run_as(w, &a, vec![], &Person::says(true), &s2));
        // A probe's answer holds neither the name nor the id in the clear.
        let mut s = TcpStream::connect(code.addr).unwrap();
        let mut hello = vec![VERSION, MODE_PROBE];
        hello.extend_from_slice(&random::<NONCE_LEN>());
        write_frame(&mut s, &hello).unwrap();
        let reply = read_frame(&mut s).unwrap();
        assert!(!reply.windows(name.len()).any(|w| w == name.as_bytes()));
        assert!(!reply.windows(TOKEN_LEN).any(|w| w == code.token));
        // The same vault reads the id from it, and gets the name through the handshake.
        let found = probe_all(&[code.addr], &pairing_key(&b), false);
        assert_eq!(found.len(), 1);
        assert_eq!((found[0].token, found[0].name.clone()), (code.token, None));
        let me: Token = random();
        assert_eq!(
            intro(&found[0], &pairing_key(&b), false, me, false, "B").as_deref(),
            Some(name)
        );
        // Another vault finds nothing, and cannot get the name either.
        assert!(probe_all(&[code.addr], &pairing_key(&other.a), false).is_empty());
        assert_eq!(
            intro(&found[0], &pairing_key(&other.a), false, me, false, "X"),
            None
        );
        stop.store(true, Ordering::Relaxed);
        assert!(host.join().unwrap().is_err());
        drop(dirs);
    }

    #[test]
    fn several_devices_wait_until_the_person_picks_one() {
        let t = two();
        let (dc, c) = crate::testkit::third(&t);
        let from_a = note(&t.a, "From A", "aaa");
        let mirrors: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
        let wa = waiting(&t.a, None, "Phone A", mirrors[0].path());
        let wb = waiting(&t.b, None, "Tablet B", mirrors[1].path());
        let wc = waiting(&c, None, "Laptop C", mirrors[2].path());
        let (ca, cb, cc) = (wa.code.clone(), wb.code.clone(), wc.code.clone());
        let Two { a, b, dirs, .. } = t;
        let stop_c = Arc::new(AtomicBool::new(false));
        let sc = stop_c.clone();
        let pick_b = Person::says(true);
        *pick_b.pick.lock().unwrap() = Some(cb.token);
        let side = |w: Waiting,
                    v: OpenVault,
                    others: Vec<SocketAddrV4>,
                    me: Person,
                    stop: Arc<AtomicBool>| {
            std::thread::spawn(move || {
                let r = run_as(w, &v, others, &me, &stop);
                (v, r, me)
            })
        };
        let never = Arc::new(AtomicBool::new(false));
        let ha = side(wa, a, vec![cb.addr, cc.addr], pick_b, never.clone());
        let hb = side(wb, b, vec![ca.addr, cc.addr], Person::says(true), never);
        let hc = side(wc, c, vec![ca.addr, cb.addr], Person::says(true), sc);
        let (_a, ra, pa) = ha.join().unwrap();
        let (b, rb, _pb) = hb.join().unwrap();
        stop_c.store(true, Ordering::Relaxed);
        let (_c, rc, pc) = hc.join().unwrap();
        // A and B paired (whoever connected), C was never asked and kept waiting.
        assert_eq!(ra.unwrap().name, "Tablet B");
        assert_eq!(rb.unwrap().name, "Phone A");
        assert!(matches!(rc, Err(Error::Corrupt("p2p cancelled"))));
        assert!(pc.asked.lock().unwrap().is_empty());
        // The list on A named both others before the pick.
        let lists = pa.found.lock().unwrap();
        let named: Vec<Vec<Option<String>>> = lists
            .iter()
            .map(|l| l.iter().map(|p| p.name.clone()).collect())
            .collect();
        assert!(
            named.iter().any(|l| {
                l.len() == 2
                    && l.contains(&Some("Tablet B".into()))
                    && l.contains(&Some("Laptop C".into()))
            }),
            "{named:?}"
        );
        assert_eq!(text(&b, &from_a), "aaa");
        drop((dirs, dc));
    }

    #[test]
    fn a_scan_needs_its_permit_and_a_local_network() {
        let t = two();
        let look = Looker::for_vault(&t.a);
        assert!(look.scan(Permit::listen(Ipv4Addr::LOCALHOST)).is_err());
        assert!(Permit::scan_on("8.8.8.8").is_none());
        assert!(look.scan(Permit::scan_on("127.0.0.1").unwrap()).is_err());
        assert!(!covers(
            &Permit::scan_on("192.168.1.5").unwrap(),
            SocketAddrV4::new(Ipv4Addr::new(192, 168, 2, 9), PORT)
        ));
        assert!(covers(
            &Permit::scan_on("192.168.1.5").unwrap(),
            SocketAddrV4::new(Ipv4Addr::new(192, 168, 1, 9), PORT)
        ));
    }

    #[test]
    fn the_qr_still_pairs_and_both_still_say_yes() {
        let t = two();
        let from_a = note(&t.a, "From A", "aaa");
        let mirror = tempfile::tempdir().unwrap();
        let w = waiting(&t.a, None, "Phone A", mirror.path());
        let code = PairCode::parse(&w.code.qr()).unwrap();
        let Two { a, b, dirs, .. } = t;
        let host = std::thread::spawn(move || {
            let r = run_as(w, &a, vec![], &Person::says(true), &AtomicBool::new(false));
            (a, r)
        });
        let asked = Mutex::new(Vec::new());
        let confirm = |n: &str, c: u16, _: &dyn Fn() -> bool| {
            asked.lock().unwrap().push((n.to_owned(), c));
            true
        };
        let ask = Ask {
            seen: &|_| (),
            found: &|_| (),
            picked: &|| None,
            confirm: &confirm,
            allow: &|_, _| false,
            progress: &|_| (),
        };
        let joined = join_code(
            &b,
            Permit::connect(code.addr),
            &code,
            "Tablet B",
            &ask,
            &AtomicBool::new(false),
        )
        .unwrap();
        let (_a, hosted) = host.join().unwrap();
        assert_eq!((joined.name.as_str(), joined.hosted), ("Phone A", false));
        assert_eq!(hosted.unwrap().name, "Tablet B");
        assert_eq!(asked.lock().unwrap().len(), 1);
        assert_eq!(text(&b, &from_a), "aaa");
        drop(dirs);
    }

    #[test]
    fn a_device_without_the_vault_cannot_join_by_the_qr() {
        let t = two();
        let other = two(); // a different vault: another Master Key
        let mirror = tempfile::tempdir().unwrap();
        let w = waiting(&t.a, None, "A", mirror.path());
        let code = w.code.clone();
        let Two { dirs, a, .. } = t;
        let host = std::thread::spawn(move || {
            let me = Person::says(true);
            let r = run_as(w, &a, vec![], &me, &AtomicBool::new(false));
            assert!(
                me.asked.lock().unwrap().is_empty(),
                "no question for strangers"
            );
            r.err()
        });
        let ask = Ask {
            seen: &|_| (),
            found: &|_| (),
            picked: &|| None,
            confirm: &|_, _, _| panic!("not proven"),
            allow: &|_, _| false,
            progress: &|_| (),
        };
        // The app tells the person it is another vault, not a network problem.
        let e = join_code(
            &other.a,
            Permit::connect(code.addr),
            &code,
            "X",
            &ask,
            &AtomicBool::new(false),
        )
        .unwrap_err();
        assert!(matches!(e, Error::Corrupt("p2p host not proven")), "{e:?}");
        // The waiting device stops at once and says why.
        let e = host.join().unwrap().expect("it stops");
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
        let ask = Ask {
            seen: &|_| (),
            found: &|_| (),
            picked: &|| None,
            confirm: &|_, _, _| true,
            allow: &|_, _| false,
            progress: &|_| (),
        };
        assert!(join_code(&t.a, wrong, &code, "", &ask, &AtomicBool::new(false)).is_err());
        let mirror = tempfile::tempdir().unwrap();
        let prepared = host_prepare(&t.a, None, "", mirror.path()).unwrap();
        assert!(wait(prepared, Permit::connect(code.addr), 0).is_err());
    }

    fn pair() -> (Channel, Channel) {
        let t = two();
        let pk = pairing_key(&t.a);
        drop(t.b);
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let token = [9u8; TOKEN_LEN];
        let keys = Keys {
            key: pk.clone(),
            restore_key: None,
            restore_on: Arc::new(AtomicBool::new(false)),
            token,
            name: String::new(),
            calls: Mutex::new(Vec::new()),
        };
        let h = std::thread::spawn(move || {
            let mut s = l.accept().unwrap().0;
            let hello = read_frame(&mut s).unwrap();
            handshake_host(&keys, &token, &hello, s).unwrap().0
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
    fn a_session_not_yet_agreed_is_not_served() {
        let (h, _j) = pair();
        let mirror = tempfile::tempdir().unwrap();
        let s = Session {
            check: h.check,
            ch: h,
            vault_id: "abcd".into(),
            mirror: mirror.path().to_path_buf(),
            restoring: true,
            allowed: false,
        };
        assert!(matches!(
            s.serve(),
            Err(Error::Corrupt("p2p restore not allowed"))
        ));
    }

    #[test]
    fn never_listens_or_connects_outside_the_local_network() {
        let public = Ipv4Addr::new(8, 8, 8, 8);
        let t = two();
        let mirror = tempfile::tempdir().unwrap();
        let prepared = host_prepare(&t.a, None, "", mirror.path()).unwrap();
        assert!(wait(prepared, Permit::listen(public), 0).is_err());
        let code = PairCode {
            addr: SocketAddrV4::new(public, 443),
            token: [0; TOKEN_LEN],
        };
        let ask = Ask {
            seen: &|_| (),
            found: &|_| (),
            picked: &|| None,
            confirm: &|_, _, _| true,
            allow: &|_, _| false,
            progress: &|_| (),
        };
        assert!(join_code(
            &t.b,
            Permit::connect(code.addr),
            &code,
            "",
            &ask,
            &AtomicBool::new(false)
        )
        .is_err());
        assert!(on_local_network(Ipv4Addr::new(192, 168, 1, 7)));
        assert!(on_local_network(Ipv4Addr::new(10, 0, 0, 2)));
        assert!(on_local_network(Ipv4Addr::new(172, 20, 0, 2)));
        assert!(!on_local_network(Ipv4Addr::new(172, 32, 0, 2)));
    }

    /// What the new device got, what the old one ended with, the new device's folder, and
    /// what the old one was asked (the new device's name and the number).
    type Restored = (
        Result<bool>,
        Result<Paired>,
        tempfile::TempDir,
        Option<(String, u16)>,
    );

    /// The old device waits with "Help a new device restore" `help` and answers `allow`;
    /// a new one restores into a fresh folder with `words` and `password`, by the QR or
    /// (`look`) by looking on the Wi-Fi.
    fn restore_asking(
        t: &Two,
        words: SecretKey,
        password: &str,
        help: bool,
        allow: bool,
        look: bool,
    ) -> Restored {
        let mirror = tempfile::tempdir().unwrap();
        let fresh = tempfile::tempdir().unwrap();
        let w = waiting(&t.a, Some(&t.sk), "Old phone", mirror.path());
        w.help_restore().store(help, Ordering::Relaxed);
        let code = w.code.clone();
        let stop = Arc::new(AtomicBool::new(false));
        // The new device on its own thread; it stops the old one's wait when it is done.
        let (dir, pw, s2) = (
            fresh.path().to_path_buf(),
            password.to_owned(),
            stop.clone(),
        );
        let new_device = std::thread::spawn(move || {
            let shown = Mutex::new(None);
            let connected = |n: &str, c: u16| *shown.lock().unwrap() = Some((n.to_owned(), c));
            let got = if look {
                let mine = Arc::new(AtomicBool::new(false));
                stop_after(&mine, 5);
                let ask = RestoreAsk {
                    found: &|_| (),
                    picked: &|| None,
                    connected: &connected,
                    progress: &|_| (),
                };
                restore_nearby(
                    &dir,
                    &|| Some(Permit::scan_at(vec![code.addr])),
                    words,
                    &pw,
                    "New phone",
                    &ask,
                    &mine,
                )
            } else {
                restore(
                    &dir,
                    Permit::connect(code.addr),
                    &code,
                    words,
                    &pw,
                    "New phone",
                    &connected,
                    &|_| (),
                )
            };
            s2.store(true, Ordering::Relaxed);
            (got, shown.into_inner().unwrap())
        });
        let asked = Mutex::new(None);
        let ask = Ask {
            seen: &|_| (),
            found: &|_| (),
            picked: &|| None,
            confirm: &|_, _, _| true,
            allow: &|n, c| {
                *asked.lock().unwrap() = Some((n.to_owned(), c));
                allow
            },
            progress: &|_| (),
        };
        // The old device always ends: served, told why the other stopped, or Cancel.
        let hosted = w.run(&t.a, &|| None, &ask, &stop);
        let (got, shown) = new_device.join().unwrap();
        let asked = asked.into_inner().unwrap();
        // Both screens showed the same number, each naming the other.
        if let (Some((n, c)), Some((m, d))) = (&shown, &asked) {
            assert_eq!((n.as_str(), m.as_str(), c), ("Old phone", "New phone", d));
        }
        (got, hosted, fresh, asked)
    }

    #[test]
    fn a_new_device_restores_with_only_the_words_and_the_password() {
        let t = two();
        let id = note(&t.a, "bank", "PIN 4821");
        let sk = t.sk.clone();
        for look in [false, true] {
            let (got, hosted, dir, asked) = restore_asking(&t, sk.clone(), &t.pw, true, true, look);
            assert!(got.unwrap());
            assert!(hosted.unwrap().hosted);
            assert!(asked.is_some());
            let v = crate::testkit::open(dir.path(), &sk, &t.pw);
            assert_eq!(v.id, t.a.id);
            assert_eq!(text(&v, &id), "PIN 4821");
        }
    }

    #[test]
    fn a_wrong_password_or_other_words_restore_nothing() {
        let t = two();
        let sk = t.sk.clone();
        let wrong: String = t.pw.chars().rev().collect();
        let (got, hosted, dir, _) = restore_asking(&t, sk.clone(), &wrong, true, true, false);
        assert!(!got.unwrap());
        assert!(!Library::has_vaults(dir.path()));
        // The old phone is told, and stops: it does not keep waiting.
        assert!(
            matches!(hosted, Err(Error::Corrupt("p2p restore wrong password"))),
            "{hosted:?}"
        );
        let other = crate::testkit::other_words(&sk);
        let (got, hosted, dir, _) = restore_asking(&t, other, &t.pw, true, true, false);
        assert!(matches!(got, Err(Error::WrongSecretKey)));
        assert!(!Library::has_vaults(dir.path()));
        assert!(
            matches!(hosted, Err(Error::Corrupt("p2p restore wrong words"))),
            "{hosted:?}"
        );
    }

    #[test]
    fn a_restoring_device_waits_for_the_old_one_to_allow_it() {
        let t = two();
        let sk = t.sk.clone();
        let (got, hosted, dir, asked) = restore_asking(&t, sk.clone(), &t.pw, true, false, false);
        // Turned down: the new phone is told the other stopped, and gets nothing.
        assert!(
            matches!(got, Err(Error::Corrupt("p2p peer stopped"))),
            "{got:?}"
        );
        assert!(
            matches!(hosted, Err(Error::Corrupt("p2p restore declined"))),
            "{hosted:?}"
        );
        assert!(asked.is_some());
        assert!(!Library::has_vaults(dir.path()));
    }

    #[test]
    fn with_restore_off_a_new_device_finds_nothing_and_is_refused() {
        let t = two();
        let sk = t.sk.clone();
        // Looking: nothing answers to the words.
        let (got, hosted, dir, asked) = restore_asking(&t, sk.clone(), &t.pw, false, true, true);
        assert!(
            matches!(got, Err(Error::Corrupt("p2p cancelled"))),
            "{got:?}"
        );
        assert!(
            matches!(hosted, Err(Error::Corrupt("p2p cancelled"))),
            "{hosted:?}"
        );
        assert!(asked.is_none());
        assert!(!Library::has_vaults(dir.path()));
        // With the QR anyway: refused.
        let (got, _hosted, dir, asked) = restore_asking(&t, sk, &t.pw, false, true, false);
        assert!(got.is_err());
        assert!(asked.is_none());
        assert!(!Library::has_vaults(dir.path()));
    }

    #[test]
    fn probes_from_restoring_devices_follow_the_switch() {
        let t = two();
        let mirror = tempfile::tempdir().unwrap();
        let w = waiting(&t.a, Some(&t.sk), "A", mirror.path());
        let flag = w.help_restore();
        flag.store(false, Ordering::Relaxed);
        let addr = w.code.addr;
        let Two { a, b, sk, dirs, .. } = t;
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = stop.clone();
        let host = std::thread::spawn(move || run_as(w, &a, vec![], &Person::says(true), &s2));
        // Someone who connects and says nothing holds up no one.
        let _silent: Vec<_> = (0..4).map(|_| TcpStream::connect(addr).unwrap()).collect();
        let started = Instant::now();
        assert!(probe_all(&[addr], &kdf::restore_pairing_key(&sk), true).is_empty());
        assert_eq!(probe_all(&[addr], &pairing_key(&b), false).len(), 1);
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
        flag.store(true, Ordering::Relaxed);
        assert_eq!(
            probe_all(&[addr], &kdf::restore_pairing_key(&sk), true).len(),
            1
        );
        let stranger = crate::testkit::other_words(&sk);
        assert!(probe_all(&[addr], &kdf::restore_pairing_key(&stranger), true).is_empty());
        stop.store(true, Ordering::Relaxed);
        assert!(host.join().unwrap().is_err());
        drop(dirs);
    }

    #[test]
    fn cancel_stops_the_wait() {
        let t = two();
        let mirror = tempfile::tempdir().unwrap();
        let w = waiting(&t.a, None, "A", mirror.path());
        let started = Instant::now();
        let r = run_as(w, &t.a, vec![], &Person::says(true), &AtomicBool::new(true));
        assert!(r.is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
