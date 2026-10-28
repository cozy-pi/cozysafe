//! Google sign-in on computers (`lib/sync/desktop_oauth.dart`): the network parts of the
//! installed-app flow, in cs-net, so Dart keeps no network code. Dart builds the sign-in
//! address (PKCE, state), opens the browser and reads Google's answers; these calls only
//! listen on 127.0.0.1 for the redirect and post forms to Google's OAuth host. Nothing
//! here runs unless called, and nothing is logged (codes and tokens pass through).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cs_net::oauth::{self, Endpoint, Loopback};
use cs_net::Permit;

/// The listener opened by [`google_loopback_open`], until [`google_loopback_wait`] takes
/// it, and the switch that stops that wait.
static WAITING: Mutex<Option<(Loopback, Arc<AtomicBool>)>> = Mutex::new(None);
static CANCEL: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

/// Listen on 127.0.0.1 at a free port for the browser's redirect; the port, or 0 when
/// it could not listen. Stops any sign-in still waiting.
pub fn google_loopback_open() -> u16 {
    google_loopback_cancel();
    let Ok(lb) = Loopback::open(Permit::google_sign_in()) else {
        return 0;
    };
    let port = lb.port();
    let stop = Arc::new(AtomicBool::new(false));
    *lock(&CANCEL) = Some(stop.clone());
    *lock(&WAITING) = Some((lb, stop));
    port
}

/// The redirect's query (`state=…&code=…`, or `…&error=…`) once the browser comes back
/// to `port`; `None` after `seconds`, on [`google_loopback_cancel`], or when `port` is
/// not the listener opened last. The listener is closed when this returns.
pub fn google_loopback_wait(port: u16, seconds: u32) -> Option<String> {
    let (lb, stop) = {
        let mut w = lock(&WAITING);
        match w.take() {
            Some((lb, stop)) if lb.port() == port => (lb, stop),
            other => {
                *w = other;
                return None;
            }
        }
    };
    lb.wait(Duration::from_secs(seconds.into()), &stop)
        .ok()
        .flatten()
}

/// Stop waiting for the browser (the person cancelled, or a new sign-in started).
#[flutter_rust_bridge::frb(sync)]
pub fn google_loopback_cancel() {
    if let Some(stop) = lock(&CANCEL).take() {
        stop.store(true, Ordering::SeqCst);
    }
    lock(&WAITING).take();
}

/// Which OAuth endpoint [`google_oauth_post`] calls.
pub enum GoogleEndpoint {
    Token,
    Revoke,
}

/// Google's answer: the HTTP status (0 when the network failed) and the body.
pub struct GoogleAnswer {
    pub status: u16,
    pub body: String,
}

/// POST `form` (`application/x-www-form-urlencoded`) to Google's OAuth host:
/// `/token` (exchange the code, refresh) or `/revoke`.
pub fn google_oauth_post(endpoint: GoogleEndpoint, form: String) -> GoogleAnswer {
    let form = zeroize::Zeroizing::new(form);
    let endpoint = match endpoint {
        GoogleEndpoint::Token => Endpoint::Token,
        GoogleEndpoint::Revoke => Endpoint::Revoke,
    };
    match oauth::post(Permit::google_sign_in(), endpoint, &form) {
        Ok(a) => GoogleAnswer {
            status: a.status,
            body: a.body,
        },
        Err(_) => GoogleAnswer {
            status: 0,
            body: String::new(),
        },
    }
}
