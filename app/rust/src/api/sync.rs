//! Sync with a nearby device over the Wi-Fi (docs/adr/0003-sync.md). Dart asks the
//! person first, every time, naming the address; only then does it call these, and each
//! call makes the one [`Permit`] it needs. Nothing here runs unless called.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use cs_net::drive::{DrivePhase, DriveRemote, DriveSetup, GoogleDrive};
use cs_net::p2p::{self, PairCode};
use cs_net::Permit;
use cs_vault::sync::SyncReport;

use super::vault::{hold_for_sync, with_open, SyncHold, VaultError};
use crate::frb_generated::StreamSink;

/// What a session tells the screen as it goes (a flat struct: no generated Dart
/// classes needed).
pub struct SyncEvent {
    pub kind: SyncStep,
    /// [`SyncStep::Confirm`], [`SyncStep::AskRestore`], [`SyncStep::Connected`]: the
    /// number to compare on both screens.
    pub check: u16,
    /// [`SyncStep::Confirm`], [`SyncStep::AskRestore`], [`SyncStep::Connected`]: the other
    /// device's name, as it said it once proven (may be empty).
    pub name: String,
    /// [`SyncStep::Found`]: the devices with this vault seen on the Wi-Fi: their names
    /// (empty until known, only when there are several) and ids for [`p2p_pick`].
    pub peers: Vec<String>,
    pub peer_ids: Vec<String>,
    /// [`SyncStep::Done`]: items brought in, sent, deleted here, notes kept as copies.
    pub received: u32,
    pub sent: u32,
    pub removed: u32,
    pub copies: u32,
    /// While under way: items done so far and in all.
    pub done: u32,
    pub total: u32,
    /// While under way: bytes moved in this step so far, and (sending) in all, or 0.
    pub bytes: u64,
    pub bytes_total: u64,
    /// [`SyncStep::Done`] of a Google Drive sync: files of an earlier layout moved into
    /// place in Drive first (0 elsewhere).
    pub moved: u32,
}

#[derive(Debug)]
pub enum SyncStep {
    /// Restoring: the other device proved it takes these words (its person allows next).
    Connected,
    /// Waiting: the devices with this vault seen on the Wi-Fi changed (see `peers`).
    Found,
    /// Connected to `name`, which proved this vault: ask "Sync with …?" next to `check`.
    /// Answer with [`p2p_answer`]; both devices must say yes.
    Confirm,
    /// The person on the other device tapped Cancel.
    PeerCancelled,
    Done,
    /// By Cancel.
    Cancelled,
    /// The wait ran out before the devices paired.
    Expired,
    /// The other side is not this vault, or the connection broke (no details that
    /// could help someone guess).
    Failed,
    /// The vault locked meanwhile.
    Locked,
    /// The other device holds a different vault (it could not prove this one, or this
    /// device could not prove it to the other).
    OtherVault,
    /// The other device could not be reached (another network, gone, code closed).
    Unreachable,
    /// Host only, not the end: a device with a different vault tried and was turned away.
    Rejected,
    /// Host only, not the end: a device has just connected and is proving the vault.
    Knock,
    /// Waiting, not the end: a new device restoring with the 24 words (`name`) asks to be
    /// let in; `check` is the number its screen shows. Answer with [`p2p_answer`].
    AskRestore,
    /// Google Drive refused the sign-in (expired or withdrawn): sign in again.
    SignIn,
    /// Under way: reading the place, bringing items in, sending (see `done`, `total`).
    Checking,
    Receiving,
    Sending,
    /// Taking the files of items deleted for good off the place.
    Removing,
    /// The connection dropped mid-way (the phone slept, the network went): what was
    /// done is kept, the next sync goes on from there.
    Interrupted,
    /// Restoring: the other device does not take these 24 words.
    WrongWords,
    /// Restoring: the words are right, the vault password is not.
    WrongPassword,
    /// Host: the phone restoring typed 24 words that are not this vault's.
    PeerWrongWords,
    /// Host: the phone restoring typed the wrong vault password.
    PeerWrongPassword,
    /// Host: the other phone stopped (an error or Cancel there).
    PeerStopped,
    /// Google Drive, before the sync: listing what is there (`done` so far, no total).
    DriveListing,
    /// Google Drive, before the sync: making the folders files move into (`done`,
    /// `total`).
    DriveFolders,
    /// Google Drive, before the sync: moving files of an earlier layout into their
    /// folders (`done`, `total`).
    DriveMoving,
}

fn step(kind: SyncStep) -> SyncEvent {
    SyncEvent {
        kind,
        check: 0,
        name: String::new(),
        peers: Vec::new(),
        peer_ids: Vec::new(),
        received: 0,
        sent: 0,
        removed: 0,
        copies: 0,
        done: 0,
        total: 0,
        bytes: 0,
        bytes_total: 0,
        moved: 0,
    }
}

/// What the waiting device shows.
pub struct Hosting {
    /// The QR's text, for networks where the other device cannot find this one.
    pub qr: String,
    /// Whether the other device can find this one on the Wi-Fi (else the QR only).
    pub findable: bool,
    pub seconds: u32,
}

/// The sealed copy the waiting host serves, removed when the session ends.
static MIRROR: Mutex<Option<PathBuf>> = Mutex::new(None);
/// Set by Cancel.
static STOP: AtomicBool = AtomicBool::new(false);
/// Files a join moved into place in Drive (no screen of its own shows progress), told
/// with the result of the sync that follows it.
static JOIN_MOVED: AtomicU32 = AtomicU32::new(0);

fn report(r: SyncReport) -> SyncEvent {
    SyncEvent {
        received: r.received,
        sent: r.sent,
        removed: r.removed,
        copies: r.copies,
        ..step(SyncStep::Done)
    }
}

fn progress_event(p: cs_vault::sync::SyncProgress) -> SyncEvent {
    use cs_vault::sync::SyncPhase;
    SyncEvent {
        done: p.done,
        total: p.total,
        bytes: p.bytes,
        bytes_total: p.bytes_total,
        ..step(match p.phase {
            SyncPhase::Checking => SyncStep::Checking,
            SyncPhase::Receiving => SyncStep::Receiving,
            SyncPhase::Sending => SyncStep::Sending,
            SyncPhase::Removing => SyncStep::Removing,
        })
    }
}

fn setup_event(s: DriveSetup) -> SyncEvent {
    SyncEvent {
        done: s.done,
        total: s.total,
        ..step(match s.phase {
            DrivePhase::Listing => SyncStep::DriveListing,
            DrivePhase::Folders => SyncStep::DriveFolders,
            DrivePhase::Moving => SyncStep::DriveMoving,
        })
    }
}

fn failure(e: cs_vault::Error) -> SyncEvent {
    step(match e {
        _ if STOP.load(Ordering::Relaxed) => SyncStep::Cancelled,
        cs_vault::Error::Corrupt("p2p code expired") => SyncStep::Expired,
        cs_vault::Error::Corrupt("p2p cancelled") => SyncStep::Cancelled,
        cs_vault::Error::Corrupt("p2p peer cancelled") => SyncStep::PeerCancelled,
        cs_vault::Error::Corrupt("vault locked") => SyncStep::Locked,
        // The person turned the restoring device away.
        cs_vault::Error::Corrupt("p2p restore declined") => SyncStep::Cancelled,
        cs_vault::Error::Corrupt("drive not signed in") => SyncStep::SignIn,
        cs_vault::Error::Corrupt("p2p restore wrong words") => SyncStep::PeerWrongWords,
        cs_vault::Error::Corrupt("p2p restore wrong password") => SyncStep::PeerWrongPassword,
        cs_vault::Error::Corrupt("p2p peer stopped") => SyncStep::PeerStopped,
        cs_vault::Error::Corrupt(
            "p2p host not proven" | "p2p joiner not proven" | "p2p too many failed tries",
        ) => SyncStep::OtherVault,
        cs_vault::Error::Io(e)
            if matches!(
                e.kind(),
                std::io::ErrorKind::ConnectionRefused
                    | std::io::ErrorKind::TimedOut
                    | std::io::ErrorKind::HostUnreachable
                    | std::io::ErrorKind::NetworkUnreachable
                    | std::io::ErrorKind::WouldBlock
            ) =>
        {
            SyncStep::Unreachable
        }
        _ => SyncStep::Failed,
    })
}

/// One line in the vault's connection log: through the sync's own hold when it has one
/// (the vault may have locked meanwhile), else through the open vault.
fn record(hold: Option<&SyncHold>, line: String) {
    match hold {
        Some(h) => {
            let _ = h.with(|v| v.log_connection(&line));
        }
        None => {
            let _ = with_open(|v| v.log_connection(&line).map_err(Into::into));
        }
    }
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// Whether this device may wait on `ip` (a home or office network address).
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_local_address(ip: String) -> bool {
    p2p::local_address(&ip)
}

/// The vault for the moments a session needs it, through the session's own hold: the
/// vault locking on this device does not stop a session under way.
#[flutter_rust_bridge::frb(ignore)]
struct Held<'a>(&'a SyncHold);

impl p2p::Access for Held<'_> {
    fn with(
        &self,
        f: &mut dyn FnMut(&cs_vault::OpenVault) -> cs_vault::Result<()>,
    ) -> cs_vault::Result<()> {
        self.0.with(|v| f(v))
    }
}

/// The device waiting now, from [`p2p_wait_start`] to [`p2p_wait_run`].
static PENDING: Mutex<Option<p2p::Waiting>> = Mutex::new(None);
/// "Help a new device restore" of the device waiting now.
static HELP: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);

/// The person allowed looking for their other device on the Wi-Fi where this device has
/// `ip`. Copies the vault, sealed, into `mirror` (a private folder, emptied first) and
/// opens the listener; [`p2p_wait_run`] then waits and looks. `name` is this device's
/// ("iPhone 15 Pro Max"), told to the other only once it proved the vault. A new device
/// restoring with the 24 words may ask to join only while `help_restore` (off by
/// default, [`p2p_wait_help_restore`]).
pub fn p2p_wait_start(
    ip: String,
    mirror: String,
    help_restore: bool,
    name: String,
) -> Result<Hosting, VaultError> {
    STOP.store(false, Ordering::Relaxed);
    let permit = Permit::listen_on(&ip).ok_or(VaultError::Storage)?;
    let dir = Path::new(&mirror);
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).map_err(|_| VaultError::Storage)?;
    // With the library's words, a device restoring this vault may ask to join as well.
    let secret = super::vault::secret().ok();
    let prepared = with_open(|v| Ok(p2p::host_prepare(v, secret.as_ref(), &name, dir)?))?;
    *MIRROR.lock().unwrap_or_else(|p| p.into_inner()) = Some(dir.to_path_buf());
    let waiting = p2p::wait(prepared, permit, p2p::PORT)?;
    let help = waiting.help_restore();
    help.store(help_restore && secret.is_some(), Ordering::Relaxed);
    *HELP.lock().unwrap_or_else(|p| p.into_inner()) = Some(help);
    let shown = Hosting {
        qr: waiting.code.qr(),
        findable: waiting.findable(),
        seconds: p2p::WAIT_LIFETIME.as_secs() as u32,
    };
    *PENDING.lock().unwrap_or_else(|p| p.into_inner()) = Some(waiting);
    Ok(shown)
}

fn forget_mirror() {
    if let Some(dir) = MIRROR.lock().unwrap_or_else(|p| p.into_inner()).take() {
        // The copy was sealed, but it has done its job.
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// "Help a new device restore" turned on or off while waiting (off by default).
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_wait_help_restore(on: bool) {
    if let Some(flag) = HELP.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
        flag.store(on, Ordering::Relaxed);
    }
}

/// The person's answer to [`SyncStep::Confirm`] or [`SyncStep::AskRestore`].
static ANSWER: Mutex<Option<bool>> = Mutex::new(None);
static ANSWERED: Condvar = Condvar::new();
/// The device the person picked among several ([`SyncStep::Found`]).
static PICK: Mutex<Option<p2p::Token>> = Mutex::new(None);

/// Sync (true) or Cancel (false); for a restoring device, Allow or Don't allow.
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_answer(yes: bool) {
    *ANSWER.lock().unwrap_or_else(|p| p.into_inner()) = Some(yes);
    ANSWERED.notify_all();
}

/// The person picked this device (an id from [`SyncEvent::peer_ids`]).
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_pick(id: String) {
    *PICK.lock().unwrap_or_else(|p| p.into_inner()) = p2p::token_from_text(&id);
}

fn picked() -> Option<p2p::Token> {
    PICK.lock().unwrap_or_else(|p| p.into_inner()).take()
}

/// Show `event` and wait for the person's answer: no answer in `limit`, Cancel, or the
/// other device saying no (`gone`) is no.
fn ask(
    sink: &StreamSink<SyncEvent>,
    event: SyncEvent,
    limit: Duration,
    gone: &dyn Fn() -> bool,
) -> bool {
    let mut answer = ANSWER.lock().unwrap_or_else(|p| p.into_inner());
    *answer = None;
    let _ = sink.add(event);
    let until = Instant::now() + limit;
    loop {
        if let Some(a) = answer.take() {
            return a;
        }
        if STOP.load(Ordering::Relaxed) || Instant::now() > until || gone() {
            return false;
        }
        answer = ANSWERED
            .wait_timeout(answer, Duration::from_millis(200))
            .unwrap_or_else(|p| p.into_inner())
            .0;
    }
}

fn found_event(peers: &[p2p::Peer]) -> SyncEvent {
    SyncEvent {
        peers: peers
            .iter()
            .map(|p| p.name.clone().unwrap_or_default())
            .collect(),
        peer_ids: peers.iter().map(|p| p2p::token_text(&p.token)).collect(),
        ..step(SyncStep::Found)
    }
}

fn named(kind: SyncStep, name: &str, check: u16) -> SyncEvent {
    SyncEvent {
        name: name.to_owned(),
        check,
        ..step(kind)
    }
}

/// Run `f` with the questions and news of a pairing going to `sink`; the other device's
/// name, once known, goes to the log.
fn with_ask<T>(
    sink: &StreamSink<SyncEvent>,
    peer: &Mutex<String>,
    f: impl FnOnce(&p2p::Ask) -> T,
) -> T {
    let remember = |name: &str| *peer.lock().unwrap_or_else(|p| p.into_inner()) = name.to_owned();
    let confirm = |name: &str, check: u16, gone: &dyn Fn() -> bool| {
        remember(name);
        ask(
            sink,
            named(SyncStep::Confirm, name, check),
            p2p::CONFIRM_WAIT,
            gone,
        )
    };
    let allow = |name: &str, check: u16| {
        remember(name);
        ask(
            sink,
            named(SyncStep::AskRestore, name, check),
            p2p::ALLOW_WAIT,
            &|| false,
        )
    };
    let a = p2p::Ask {
        seen: &|seen| {
            let _ = sink.add(step(match seen {
                p2p::Seen::Knock => SyncStep::Knock,
                p2p::Seen::Rejected => SyncStep::Rejected,
            }));
        },
        found: &|peers| {
            let _ = sink.add(found_event(peers));
        },
        picked: &picked,
        confirm: &confirm,
        allow: &allow,
        progress: &|p| {
            let _ = sink.add(progress_event(p));
        },
    };
    f(&a)
}

/// Wait for the other device and look for it on the Wi-Fi where this device has `ip`,
/// then (both people said Sync) sync with it. The vault stays free while waiting, asking
/// and serving; the session holds it to the end, so a lock meanwhile does not cut it.
pub fn p2p_wait_run(ip: String, sink: StreamSink<SyncEvent>) {
    *PICK.lock().unwrap_or_else(|p| p.into_inner()) = None;
    let waiting = PENDING.lock().unwrap_or_else(|p| p.into_inner()).take();
    let hold = hold_for_sync();
    let peer = Mutex::new(String::new());
    let event = match (waiting, &hold) {
        (None, _) => step(SyncStep::Expired),
        (Some(_), None) => step(SyncStep::Locked),
        (Some(w), Some(h)) => {
            let paired = with_ask(&sink, &peer, |a| {
                w.run(&Held(h), &|| Permit::scan_on(&ip), a, &STOP)
            });
            match paired {
                Ok(p) => {
                    *peer.lock().unwrap_or_else(|p| p.into_inner()) = p.name.clone();
                    report(p.report)
                }
                Err(e) => failure(e),
            }
        }
    };
    forget_mirror();
    HELP.lock().unwrap_or_else(|p| p.into_inner()).take();
    let name = peer.into_inner().unwrap_or_else(|p| p.into_inner());
    log_event(hold.as_ref(), "nearby", Some(&name), &event);
    // Locked meanwhile: the vault goes now, before the screen hears the end.
    drop(hold);
    let _ = sink.add(event);
}

/// The address a scanned code points at (for the question to the person), or none if
/// it is not a code for a device on a local network.
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_code_address(code: String) -> Option<String> {
    let c = PairCode::parse(&code)?;
    c.is_local().then(|| c.ip_text())
}

/// The person allowed connecting to the device whose QR they scanned (`name`: this
/// device's). Both people then say Sync, as when the devices find each other.
pub fn p2p_join(code: String, name: String, sink: StreamSink<SyncEvent>) {
    STOP.store(false, Ordering::Relaxed);
    let Some(c) = PairCode::parse(&code) else {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    };
    let Some(hold) = hold_for_sync() else {
        let _ = sink.add(step(SyncStep::Locked));
        return;
    };
    let peer = Mutex::new(String::new());
    let joined = with_ask(&sink, &peer, |a| {
        p2p::join_code(&Held(&hold), Permit::connect_for(&c), &c, &name, a, &STOP)
    });
    let event = match joined {
        Ok(p) => {
            *peer.lock().unwrap_or_else(|p| p.into_inner()) = p.name.clone();
            report(p.report)
        }
        Err(e) => failure(e),
    };
    let name = peer.into_inner().unwrap_or_else(|p| p.into_inner());
    log_event(Some(&hold), "nearby", Some(&name), &event);
    drop(hold);
    let _ = sink.add(event);
}

/// What came of a restore: the vault opened here the usual way, or why not.
fn restored(
    dir: &Path,
    key: cs_crypto::SecretKey,
    password: &str,
    r: cs_vault::Result<bool>,
) -> SyncEvent {
    match r {
        // Opened the usual way, from this device's folder with the two secrets.
        Ok(true) => {
            super::vault::use_secret(key);
            match super::vault::unlock(dir.to_string_lossy().into_owned(), password.to_owned()) {
                Ok(Some(_)) => step(SyncStep::Done),
                _ => step(SyncStep::Failed),
            }
        }
        Ok(false) => step(SyncStep::WrongPassword),
        Err(cs_vault::Error::WrongSecretKey) => step(SyncStep::WrongWords),
        Err(e) => failure(e),
    }
}

/// A new device with no vault: look on the Wi-Fi where it has `ip` (the person allowed
/// it) for a device that takes these 24 words and whose person turned "Help a new device
/// restore" on; restore its vault with the words and the vault password, once that
/// person allowed it, then sync the items in. On Done the vault is open here
/// (`open_vault_info`) and the key in use; Dart then keeps it in the keystore.
pub fn p2p_restore_nearby(
    dir: String,
    ip: String,
    words: String,
    password: String,
    name: String,
    sink: StreamSink<SyncEvent>,
) {
    STOP.store(false, Ordering::Relaxed);
    *PICK.lock().unwrap_or_else(|p| p.into_inner()) = None;
    let password = zeroize::Zeroizing::new(password);
    let words = zeroize::Zeroizing::new(words);
    let Some(key) = cs_crypto::SecretKey::from_text(&words) else {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    };
    let dir = Path::new(&dir);
    if cs_vault::Library::reset_if_empty(dir).is_err() {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    }
    let peer = Mutex::new(String::new());
    let connected = |n: &str, check: u16| {
        *peer.lock().unwrap_or_else(|p| p.into_inner()) = n.to_owned();
        let _ = sink.add(named(SyncStep::Connected, n, check));
    };
    let ask = p2p::RestoreAsk {
        found: &|peers| {
            let _ = sink.add(found_event(peers));
        },
        picked: &picked,
        connected: &connected,
        progress: &|p| {
            let _ = sink.add(progress_event(p));
        },
    };
    let r = p2p::restore_nearby(
        dir,
        &|| Permit::scan_on(&ip),
        key.clone(),
        &password,
        &name,
        &ask,
        &STOP,
    );
    let event = restored(dir, key, &password, r);
    // Half a restore (lock opened, items cut short) is still a vault here; the next sync
    // goes on. Nothing is left when the words or password were wrong.
    let name = peer.into_inner().unwrap_or_else(|p| p.into_inner());
    log_event(None, "restore", Some(&name), &event);
    let _ = sink.add(event);
}

/// [`p2p_restore_nearby`] with the QR of the old device (the person allowed connecting
/// to the address it names).
pub fn p2p_restore(
    dir: String,
    code: String,
    words: String,
    password: String,
    name: String,
    sink: StreamSink<SyncEvent>,
) {
    STOP.store(false, Ordering::Relaxed);
    let password = zeroize::Zeroizing::new(password);
    let words = zeroize::Zeroizing::new(words);
    let (Some(c), Some(key)) = (
        PairCode::parse(&code),
        cs_crypto::SecretKey::from_text(&words),
    ) else {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    };
    let dir = Path::new(&dir);
    if cs_vault::Library::reset_if_empty(dir).is_err() {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    }
    let peer = Mutex::new(String::new());
    let r = p2p::restore(
        dir,
        Permit::connect_for(&c),
        &c,
        key.clone(),
        &password,
        &name,
        &|n, check| {
            *peer.lock().unwrap_or_else(|p| p.into_inner()) = n.to_owned();
            let _ = sink.add(named(SyncStep::Connected, n, check));
        },
        &|p| {
            let _ = sink.add(progress_event(p));
        },
    );
    let event = restored(dir, key, &password, r);
    let name = peer.into_inner().unwrap_or_else(|p| p.into_inner());
    log_event(None, "restore", Some(&name), &event);
    let _ = sink.add(event);
}

/// The person allowed syncing with their Google Drive; `token` is the access token from
/// their sign-in on this device (scope `drive.file`). The run keeps its own hold on the
/// vault from start to end, so the vault locking meanwhile does not stop it; the vault
/// itself stays free while Drive is listed.
pub fn drive_sync(token: String, sink: StreamSink<SyncEvent>) {
    STOP.store(false, Ordering::Relaxed);
    let token = zeroize::Zeroizing::new(token);
    let Some(hold) = hold_for_sync() else {
        let _ = sink.add(step(SyncStep::Locked));
        return;
    };
    let _ = sink.add(step(SyncStep::Checking));
    // How long each step takes, in Debug's log (owner 2026-10-26: "Looking at Google
    // Drive" was slow after a while without syncing; the log says where the time goes).
    let started = std::time::Instant::now();
    let last = Mutex::new(String::new());
    let mark = |what: String| {
        let mut l = last.lock().unwrap_or_else(|p| p.into_inner());
        if *l != what {
            let ms = started.elapsed().as_millis();
            super::vault::debug_line(|| format!("drive: {what} from {ms} ms"));
            *l = what;
        }
    };
    let remote = GoogleDrive::new(Permit::google_drive(), token.to_string())
        .and_then(|api| {
            DriveRemote::open_with(api, &|s| {
                let e = setup_event(s);
                mark(format!("{:?}", e.kind));
                let _ = sink.add(e);
            })
        })
        .map(|r| r.stop_on(&STOP));
    mark("opened".into());
    let event = match remote {
        Err(e) => drive_failure(e),
        Ok(remote) => match hold.with(|v| {
            v.sync_with(&remote, &|p| {
                let e = progress_event(p);
                mark(format!("{:?}", e.kind));
                let _ = sink.add(e);
            })
        }) {
            Ok(r) => SyncEvent {
                moved: remote.moved() + JOIN_MOVED.swap(0, Ordering::Relaxed),
                ..report(r)
            },
            Err(e) => drive_failure(e),
        },
    };
    mark(format!("end {:?}", event.kind));
    log_event(Some(&hold), "drive", Some("Google Drive"), &event);
    // Locked meanwhile: the vault goes now, before the screen hears the end.
    drop(hold);
    let _ = sink.add(event);
}

/// A dropped connection mid-way is an interruption (nothing lost), not a failure.
fn drive_failure(e: cs_vault::Error) -> SyncEvent {
    match e {
        cs_vault::Error::Corrupt("drive cancelled") => step(SyncStep::Cancelled),
        cs_vault::Error::Io(_) => step(SyncStep::Interrupted),
        e => failure(e),
    }
}

/// What came of joining a vault from Google Drive on this device.
pub enum JoinOutcome {
    /// The vault is open here, its items synced in.
    Joined,
    /// Nothing of Cozy Safe in this Google account's Drive.
    NoVault,
    /// The 24 words are not this vault's (or are not 24 valid words).
    WrongWords,
    WrongPassword,
    /// Google asks to sign in again.
    SignIn,
    /// The network or Drive failed.
    Failed,
}

pub struct JoinResult {
    pub outcome: JoinOutcome,
    pub vault: Option<super::vault::VaultInfo>,
}

fn join_result(outcome: JoinOutcome) -> JoinResult {
    JoinResult {
        outcome,
        vault: None,
    }
}

/// A new device with no vault: open the one kept in this Google account's Drive with
/// the 24 words and the vault password (no backup file), then sync its items in. The
/// person allowed the connection; `token` comes from their sign-in. On success the key
/// is in use here; Dart then keeps it in the keystore.
pub fn drive_join(dir: String, token: String, words: String, password: String) -> JoinResult {
    let password = zeroize::Zeroizing::new(password);
    let words = zeroize::Zeroizing::new(words);
    let token = zeroize::Zeroizing::new(token);
    let Some(key) = cs_crypto::SecretKey::from_text(&words) else {
        return join_result(JoinOutcome::WrongWords);
    };
    // Its screen shows a busy button, not steps: what opening moved is told with the
    // result of the sync that follows.
    JOIN_MOVED.store(0, Ordering::Relaxed);
    let remote = match GoogleDrive::new(Permit::google_drive(), token.to_string())
        .and_then(|api| DriveRemote::open_with(api, &|_| {}))
    {
        Ok(r) => r,
        Err(cs_vault::Error::Corrupt("drive not signed in")) => {
            return join_result(JoinOutcome::SignIn)
        }
        Err(_) => return join_result(JoinOutcome::Failed),
    };
    let ids = remote.vault_ids();
    if ids.is_empty() {
        return join_result(JoinOutcome::NoVault);
    }
    let dir = Path::new(&dir);
    if cs_vault::Library::reset_if_empty(dir).is_err() {
        return join_result(JoinOutcome::Failed);
    }
    // Several vaults may share the Drive folder: the two secrets say which one.
    match cs_vault::Library::join_any(dir, &remote, &ids, key.clone(), &password) {
        Ok(Some(_)) => {}
        Ok(None) => return join_result(JoinOutcome::WrongPassword),
        Err(cs_vault::Error::WrongSecretKey) => return join_result(JoinOutcome::WrongWords),
        Err(_) => return join_result(JoinOutcome::Failed),
    }
    // Opened the usual way, from this device's folder with the two secrets; the items
    // come next, through drive_sync, with progress on screen.
    super::vault::use_secret(key);
    match super::vault::unlock(dir.to_string_lossy().into_owned(), password.to_string()) {
        Ok(Some(vault)) => {
            JOIN_MOVED.store(remote.moved(), Ordering::Relaxed);
            JoinResult {
                outcome: JoinOutcome::Joined,
                vault: Some(vault),
            }
        }
        _ => join_result(JoinOutcome::Failed),
    }
}

/// Stop waiting, or end the session under way.
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_cancel() {
    STOP.store(true, Ordering::Relaxed);
    PENDING.lock().unwrap_or_else(|p| p.into_inner()).take();
    forget_mirror();
    p2p::cancel_live();
}

/// One log line: `<ms>|<nearby|restore|drive>|<the other device's name, or ->|<ok|cancelled|expired|failed|…>|<received>|<sent>`.
/// Lines from before 0.1.73 say `host` or `join` and an address.
fn log_event(hold: Option<&SyncHold>, side: &str, peer: Option<&str>, event: &SyncEvent) {
    // A name from the other device: cleaned (no `|`, no control characters) again here.
    let peer = peer.map(p2p::clean_name).filter(|p| !p.is_empty());
    let peer = peer.as_deref().unwrap_or("-");
    let outcome = match event.kind {
        SyncStep::Done => "ok",
        SyncStep::Cancelled => "cancelled",
        SyncStep::Expired => "expired",
        SyncStep::PeerCancelled => "cancelled",
        SyncStep::Connected
        | SyncStep::Found
        | SyncStep::Confirm
        | SyncStep::Rejected
        | SyncStep::Knock
        | SyncStep::AskRestore
        | SyncStep::Checking
        | SyncStep::Receiving
        | SyncStep::Sending
        | SyncStep::Removing
        | SyncStep::DriveListing
        | SyncStep::DriveFolders
        | SyncStep::DriveMoving => return,
        SyncStep::Interrupted => "interrupted",
        SyncStep::OtherVault => "othervault",
        SyncStep::Unreachable => "unreachable",
        SyncStep::SignIn
        | SyncStep::Failed
        | SyncStep::Locked
        | SyncStep::WrongWords
        | SyncStep::WrongPassword
        | SyncStep::PeerWrongWords
        | SyncStep::PeerWrongPassword
        | SyncStep::PeerStopped => "failed",
    };
    let (received, sent) = (event.received, event.sent);
    record(
        hold,
        format!("{}|{side}|{peer}|{outcome}|{received}|{sent}", now_ms()),
    );
}

/// The connections this vault made, newest first, in [`log_event`]'s format.
pub fn connection_log() -> Result<Vec<String>, VaultError> {
    with_open(|v| Ok(v.connection_log()?))
}

/// A QR code as rows of dark (true) and light modules, `size` × `size`.
pub struct QrMatrix {
    pub size: u32,
    pub dark: Vec<bool>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn qr_matrix(text: String) -> Option<QrMatrix> {
    let code =
        qrcode::QrCode::with_error_correction_level(text.as_bytes(), qrcode::EcLevel::M).ok()?;
    let size = code.width() as u32;
    let dark = code
        .to_colors()
        .into_iter()
        .map(|c| c == qrcode::Color::Dark)
        .collect();
    Some(QrMatrix { size, dark })
}

/// Read a QR from a camera frame's brightness plane (`width` × `height`, `stride` bytes
/// a row). Only Cozy Safe pairing codes come back.
pub fn qr_read(luma: Vec<u8>, width: u32, height: u32, stride: u32) -> Option<String> {
    let (w, h, stride) = (width as usize, height as usize, stride as usize);
    if luma.len() < stride * h.saturating_sub(1) + w {
        return None;
    }
    let mut img = rqrr::PreparedImage::prepare_from_greyscale(w, h, |x, y| luma[y * stride + x]);
    img.detect_grids()
        .into_iter()
        .filter_map(|g| g.decode().ok().map(|(_, text)| text))
        .find(|t| PairCode::parse(t).is_some())
}
