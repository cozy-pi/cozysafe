//! Sync with a nearby device over the Wi-Fi (docs/adr/0003-sync.md). Dart asks the
//! person first, every time, naming the address; only then does it call these, and each
//! call makes the one [`Permit`] it needs. Nothing here runs unless called.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Condvar, Mutex};

use cs_net::drive::{DrivePhase, DriveRemote, DriveSetup, GoogleDrive};
use cs_net::p2p::{self, PairCode};
use cs_net::Permit;
use cs_vault::sync::SyncReport;

use super::vault::{with_open, VaultError};
use crate::frb_generated::StreamSink;

/// What a session tells the screen as it goes (a flat struct: no generated Dart
/// classes needed).
pub struct SyncEvent {
    pub kind: SyncStep,
    /// [`SyncStep::Connected`]: the number to compare on both screens.
    pub check: u16,
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
    /// The other device proved it holds this vault.
    Connected,
    Done,
    /// By Cancel.
    Cancelled,
    /// The code ran out before anyone joined.
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
    /// Host only, not the end: a new device restoring with the 24 words asks to be let
    /// in; `check` is the number its screen shows. Answer with [`p2p_host_answer`].
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

/// What the host shows.
pub struct Hosting {
    /// To type: three groups of six.
    pub typed: String,
    /// The QR's text.
    pub qr: String,
    /// The digits to type on the other device (three).
    pub digits: String,
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
        kind: SyncStep::Done,
        check: 0,
        received: r.received,
        sent: r.sent,
        removed: r.removed,
        copies: r.copies,
        done: 0,
        total: 0,
        bytes: 0,
        bytes_total: 0,
        moved: 0,
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

fn record(line: String) {
    let _ = with_open(|v| v.log_connection(&line).map_err(Into::into));
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

/// The person allowed waiting for a nearby device on `ip`. Copies the vault, sealed,
/// into `mirror` (a private folder, emptied first) and opens the listener. A new device
/// restoring with the 24 words may ask to join only when `help_restore` (the person
/// turned it on, off by default).
pub fn p2p_host_start(ip: String, mirror: String, help_restore: bool) -> Result<Hosting, VaultError> {
    STOP.store(false, Ordering::Relaxed);
    let permit = Permit::listen_on(&ip).ok_or(VaultError::Storage)?;
    let dir = Path::new(&mirror);
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).map_err(|_| VaultError::Storage)?;
    // With the library's words, a device restoring this vault may ask to join as well,
    // while the person has "Help a new device restore" on ([`p2p_host_help_restore`]).
    let secret = super::vault::secret().ok();
    let shown = with_open(|v| Ok(p2p::host_open(v, secret.as_ref(), help_restore, permit, dir)?))?;
    *MIRROR.lock().unwrap_or_else(|p| p.into_inner()) = Some(dir.to_path_buf());
    Ok(Hosting {
        typed: shown.typed,
        qr: shown.qr,
        digits: shown.digits,
        findable: shown.findable,
        seconds: p2p::CODE_LIFETIME.as_secs() as u32,
    })
}

fn forget_mirror() {
    if let Some(dir) = MIRROR.lock().unwrap_or_else(|p| p.into_inner()).take() {
        // The copy was sealed, but it has done its job.
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// "Help a new device restore" turned on or off while waiting (off by default).
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_host_help_restore(on: bool) {
    p2p::host_help_restore(on);
}

/// The person's answer to [`SyncStep::AskRestore`], waited for by [`p2p_host_run`].
static ANSWER: Mutex<Option<bool>> = Mutex::new(None);
static ANSWERED: Condvar = Condvar::new();

/// Allow (true) or turn away (false) the new device that asked to restore.
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_host_answer(allow: bool) {
    *ANSWER.lock().unwrap_or_else(|p| p.into_inner()) = Some(allow);
    ANSWERED.notify_all();
}

/// Ask the screen whether the restoring device showing `check` may come in, and wait for
/// the answer (no answer in [`p2p::ALLOW_WAIT`], or Cancel, is no).
fn ask_restore(sink: &StreamSink<SyncEvent>, check: u16) -> bool {
    let mut answer = ANSWER.lock().unwrap_or_else(|p| p.into_inner());
    *answer = None;
    let _ = sink.add(SyncEvent {
        check,
        ..step(SyncStep::AskRestore)
    });
    let until = std::time::Instant::now() + p2p::ALLOW_WAIT;
    loop {
        if let Some(a) = answer.take() {
            return a;
        }
        if STOP.load(Ordering::Relaxed) || std::time::Instant::now() > until {
            return false;
        }
        answer = ANSWERED
            .wait_timeout(answer, std::time::Duration::from_millis(200))
            .unwrap_or_else(|p| p.into_inner())
            .0;
    }
}

/// Wait for the joiner, serve it, then take its changes in. The vault stays free while
/// waiting, asking and serving.
pub fn p2p_host_run(sink: StreamSink<SyncEvent>) {
    let served = p2p::host_session_with(
        &STOP,
        &|check| {
            let _ = sink.add(SyncEvent {
                check,
                ..step(SyncStep::Connected)
            });
        },
        &|seen| {
            let _ = sink.add(step(match seen {
                p2p::Seen::Knock => SyncStep::Knock,
                p2p::Seen::Rejected => SyncStep::Rejected,
            }));
        },
        &|check| ask_restore(&sink, check),
        &|p| {
            let _ = sink.add(progress_event(p));
        },
    );
    let event = match served {
        Ok(served) => match with_open(|v| {
            Ok(p2p::host_finish_with(v, served, &|p| {
                let _ = sink.add(progress_event(p));
            })?)
        }) {
            Ok(r) => report(r),
            Err(_) => step(SyncStep::Locked),
        },
        Err(e) => failure(e),
    };
    forget_mirror();
    log_event("host", None, &event);
    let _ = sink.add(event);
}

/// What the last look on the Wi-Fi found, and the key it proved, for [`p2p_find`].
static LOOK: Mutex<Option<(p2p::Looker, Vec<p2p::Found>)>> = Mutex::new(None);

fn look(ip: &str, looker: p2p::Looker) -> Result<u32, VaultError> {
    let permit = Permit::scan_on(ip).ok_or(VaultError::Storage)?;
    let found = looker.scan(permit).map_err(|_| VaultError::Storage)?;
    let n = found.len() as u32;
    *LOOK.lock().unwrap_or_else(|p| p.into_inner()) = Some((looker, found));
    Ok(n)
}

/// The person allowed looking for their other device on the Wi-Fi where this device has
/// `ip`. How many devices holding this vault are waiting there (a few seconds; the vault
/// is only held for a moment).
pub fn p2p_scan(ip: String) -> Result<u32, VaultError> {
    let looker = with_open(|v| Ok(p2p::Looker::for_vault(v)))?;
    look(&ip, looker)
}

/// [`p2p_scan`] for a new device restoring with the 24 words.
pub fn p2p_scan_restore(ip: String, words: String) -> Result<u32, VaultError> {
    let words = zeroize::Zeroizing::new(words);
    let key = cs_crypto::SecretKey::from_text(&words).ok_or(VaultError::Storage)?;
    look(&ip, p2p::Looker::for_words(&key))
}

/// The code of the device found that shows these digits (to pass to [`p2p_join`] or
/// [`p2p_restore`]), or none: wrong digits, or that device is not found (yet).
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_find(digits: String) -> Option<String> {
    let guard = LOOK.lock().unwrap_or_else(|p| p.into_inner());
    let (looker, found) = guard.as_ref()?;
    looker.find(found, &digits).map(|c| c.qr())
}

/// Forget the last look (the page closed).
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_look_done() {
    LOOK.lock().unwrap_or_else(|p| p.into_inner()).take();
}

/// The address a typed or scanned code points at (for the question to the person), or
/// none if it is not a code for a device on a local network.
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_code_address(code: String) -> Option<String> {
    let c = PairCode::parse(&code)?;
    c.is_local().then(|| c.ip_text())
}

/// The person allowed connecting to the device showing `code`.
pub fn p2p_join(code: String, sink: StreamSink<SyncEvent>) {
    STOP.store(false, Ordering::Relaxed);
    let Some(c) = PairCode::parse(&code) else {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    };
    let peer = c.ip_text();
    let joined = with_open(|v| {
        Ok(p2p::join_with(
            v,
            Permit::connect_for(&c),
            &c,
            &|check| {
                let _ = sink.add(SyncEvent {
                    check,
                    ..step(SyncStep::Connected)
                });
            },
            &|p| {
                let _ = sink.add(progress_event(p));
            },
        ))
    });
    let event = match joined {
        Ok(Ok(r)) => report(r),
        Ok(Err(e)) => failure(e),
        Err(_) => step(SyncStep::Locked),
    };
    log_event("join", Some(&peer), &event);
    let _ = sink.add(event);
}

/// A new device with no vault: restore the vault of the device showing `code` with
/// the 24 words and the vault password, then sync its items in. The person allowed the
/// connection. On Done the vault is open here (`open_vault_info`) and the key in use;
/// Dart then keeps it in the keystore.
pub fn p2p_restore(dir: String, code: String, words: String, password: String, sink: StreamSink<SyncEvent>) {
    STOP.store(false, Ordering::Relaxed);
    let password = zeroize::Zeroizing::new(password);
    let words = zeroize::Zeroizing::new(words);
    let (Some(c), Some(key)) = (PairCode::parse(&code), cs_crypto::SecretKey::from_text(&words)) else {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    };
    let peer = c.ip_text();
    let dir = Path::new(&dir);
    if cs_vault::Library::reset_if_empty(dir).is_err() {
        let _ = sink.add(step(SyncStep::Failed));
        return;
    }
    let restored = p2p::restore(
        dir,
        Permit::connect_for(&c),
        &c,
        key.clone(),
        &password,
        &|check| {
            let _ = sink.add(SyncEvent {
                check,
                ..step(SyncStep::Connected)
            });
        },
        &|p| {
            let _ = sink.add(progress_event(p));
        },
    );
    let event = match restored {
        // Opened the usual way, from this device's folder with the two secrets.
        Ok(true) => {
            super::vault::use_secret(key);
            match super::vault::unlock(dir.to_string_lossy().into_owned(), password.to_string()) {
                Ok(Some(_)) => step(SyncStep::Done),
                _ => step(SyncStep::Failed),
            }
        }
        Ok(false) => step(SyncStep::WrongPassword),
        Err(cs_vault::Error::WrongSecretKey) => step(SyncStep::WrongWords),
        Err(e) => failure(e),
    };
    // Half a restore (lock opened, items cut short) is still a vault here; the next sync
    // goes on. Nothing is left when the words or password were wrong.
    log_event("restore", Some(&peer), &event);
    let _ = sink.add(event);
}

/// The person allowed syncing with their Google Drive; `token` is the access token from
/// their sign-in on this device (scope `drive.file`). Listing Drive happens before the
/// vault is held; the sync itself holds it.
pub fn drive_sync(token: String, sink: StreamSink<SyncEvent>) {
    STOP.store(false, Ordering::Relaxed);
    let token = zeroize::Zeroizing::new(token);
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
        Ok(remote) => match with_open(|v| {
            Ok(v.sync_with(&remote, &|p| {
                let e = progress_event(p);
                mark(format!("{:?}", e.kind));
                let _ = sink.add(e);
            }))
        }) {
            Ok(Ok(r)) => SyncEvent {
                moved: remote.moved() + JOIN_MOVED.swap(0, Ordering::Relaxed),
                ..report(r)
            },
            Ok(Err(e)) => drive_failure(e),
            Err(_) => step(SyncStep::Locked),
        },
    };
    mark(format!("end {:?}", event.kind));
    log_event("drive", Some("Google Drive"), &event);
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
    p2p::host_close();
    forget_mirror();
    p2p::cancel_live();
}

/// One log line: `<ms>|<host|join|restore|drive>|<address or ->|<ok|cancelled|expired|failed>|<received>|<sent>`.
fn log_event(side: &str, peer: Option<&str>, event: &SyncEvent) {
    let peer = peer.unwrap_or("-");
    let outcome = match event.kind {
        SyncStep::Done => "ok",
        SyncStep::Cancelled => "cancelled",
        SyncStep::Expired => "expired",
        SyncStep::Connected
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
    record(format!(
        "{}|{side}|{peer}|{outcome}|{received}|{sent}",
        now_ms()
    ));
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
