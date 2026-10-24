//! Sync with a nearby device over the Wi-Fi (docs/adr/0003-sync.md). Dart asks the
//! person first, every time, naming the address; only then does it call these, and each
//! call makes the one [`Permit`] it needs. Nothing here runs unless called.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use cs_net::drive::{DriveRemote, GoogleDrive};
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
}

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
    }
}

/// What the host shows.
pub struct Hosting {
    /// To type: three groups of six.
    pub typed: String,
    /// The QR's text.
    pub qr: String,
    pub seconds: u32,
}

/// The sealed copy the waiting host serves, removed when the session ends.
static MIRROR: Mutex<Option<PathBuf>> = Mutex::new(None);
/// Set by Cancel.
static STOP: AtomicBool = AtomicBool::new(false);

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

fn failure(e: cs_vault::Error) -> SyncEvent {
    step(match e {
        _ if STOP.load(Ordering::Relaxed) => SyncStep::Cancelled,
        cs_vault::Error::Corrupt("p2p code expired") => SyncStep::Expired,
        cs_vault::Error::Corrupt("drive not signed in") => SyncStep::SignIn,
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
/// into `mirror` (a private folder, emptied first) and opens the listener.
pub fn p2p_host_start(ip: String, mirror: String) -> Result<Hosting, VaultError> {
    STOP.store(false, Ordering::Relaxed);
    let permit = Permit::listen_on(&ip).ok_or(VaultError::Storage)?;
    let dir = Path::new(&mirror);
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).map_err(|_| VaultError::Storage)?;
    // With the library's words, a device restoring this vault may join as well.
    let secret = super::vault::secret().ok();
    let shown = with_open(|v| Ok(p2p::host_open(v, secret.as_ref(), permit, dir)?))?;
    *MIRROR.lock().unwrap_or_else(|p| p.into_inner()) = Some(dir.to_path_buf());
    Ok(Hosting {
        typed: shown.typed,
        qr: shown.qr,
        seconds: p2p::CODE_LIFETIME.as_secs() as u32,
    })
}

fn forget_mirror() {
    if let Some(dir) = MIRROR.lock().unwrap_or_else(|p| p.into_inner()).take() {
        // The copy was sealed, but it has done its job.
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// Wait for the joiner, serve it, then take its changes in. The vault stays free while
/// waiting and serving.
pub fn p2p_host_run(sink: StreamSink<SyncEvent>) {
    let served = p2p::host_session(
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
    );
    let event = match served {
        Ok(served) => match with_open(|v| Ok(p2p::host_finish(v, served)?)) {
            Ok(r) => report(r),
            Err(_) => step(SyncStep::Locked),
        },
        Err(e) => failure(e),
    };
    forget_mirror();
    log_event("host", None, &event);
    let _ = sink.add(event);
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
        Ok(p2p::join(v, Permit::connect_for(&c), &c, &|check| {
            let _ = sink.add(SyncEvent {
                check,
                ..step(SyncStep::Connected)
            });
        }))
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
    let remote = GoogleDrive::new(Permit::google_drive(), token.to_string())
        .and_then(DriveRemote::open)
        .map(|r| r.stop_on(&STOP));
    let event = match remote {
        Err(e) => drive_failure(e),
        Ok(remote) => match with_open(|v| {
            Ok(v.sync_with(&remote, &|p| {
                let _ = sink.add(progress_event(p));
            }))
        }) {
            Ok(Ok(r)) => report(r),
            Ok(Err(e)) => drive_failure(e),
            Err(_) => step(SyncStep::Locked),
        },
    };
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
    let remote = match GoogleDrive::new(Permit::google_drive(), token.to_string())
        .and_then(DriveRemote::open)
    {
        Ok(r) => r,
        Err(cs_vault::Error::Corrupt("drive not signed in")) => {
            return join_result(JoinOutcome::SignIn)
        }
        Err(_) => return join_result(JoinOutcome::Failed),
    };
    let Some(id) = remote.vault_ids().into_iter().next() else {
        return join_result(JoinOutcome::NoVault);
    };
    let dir = Path::new(&dir);
    if cs_vault::Library::reset_if_empty(dir).is_err() {
        return join_result(JoinOutcome::Failed);
    }
    let vault = match cs_vault::Library::join(dir, &remote, &id, key.clone(), &password) {
        Ok(Some(v)) => v,
        Ok(None) => return join_result(JoinOutcome::WrongPassword),
        Err(cs_vault::Error::WrongSecretKey) => return join_result(JoinOutcome::WrongWords),
        Err(_) => return join_result(JoinOutcome::Failed),
    };
    // The items come next, through drive_sync, with progress on screen.
    super::vault::use_secret(key);
    JoinResult {
        outcome: JoinOutcome::Joined,
        vault: Some(super::vault::set_open(vault)),
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
        | SyncStep::Checking
        | SyncStep::Receiving
        | SyncStep::Sending
        | SyncStep::Removing => return,
        SyncStep::Interrupted => "interrupted",
        SyncStep::OtherVault => "othervault",
        SyncStep::Unreachable => "unreachable",
        SyncStep::SignIn
        | SyncStep::Failed
        | SyncStep::Locked
        | SyncStep::WrongWords
        | SyncStep::WrongPassword => "failed",
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
