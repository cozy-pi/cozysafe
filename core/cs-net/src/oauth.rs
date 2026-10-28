//! Google sign-in on computers (macOS, Windows, Linux), where Google's sign-in SDKs do
//! not run: the "installed app" flow (RFC 8252). The app (Dart) builds the sign-in
//! address with PKCE and a random state and opens the browser; this module does only the
//! network parts, so Dart keeps no network code (docs/supply-chain.md):
//!
//! - [`Loopback`]: listen on `127.0.0.1` (never another address) at a port the system
//!   picks, for the browser's one redirect back from Google, answer it with a short
//!   "you can close this tab" page, and hand the query (`code`, `state`) to the app.
//!   Other requests (a favicon, a speculative connection with nothing sent) get a 404 or
//!   are dropped; the listener closes after the redirect, at the deadline, or on cancel.
//! - [`post`]: one form POST to Google's OAuth host ([`crate::https::OAUTH_HOST`], fixed), to
//!   exchange the code, refresh the access token or revoke the grant. The answer goes
//!   back to the app as it came (status and body); nothing is logged.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cs_vault::{Error, Result};

use crate::https::{Body, Client, Host};
use crate::Permit;

/// The request head the browser sends is read up to this much (the redirect carries a
/// code and a state, well under 2 KiB).
const MAX_REQUEST: usize = 8 << 10;
/// A connection that sends no request within this time is dropped (browsers open
/// speculative connections and may never use them).
const READ_WAIT: Duration = Duration::from_secs(3);
/// Connections read at once; more wait in the listen queue.
const MAX_READING: usize = 8;
/// Google's answers are small JSON objects.
const MAX_ANSWER: usize = 64 << 10;

const PAGE: &str = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Cozy Safe</title></head><body style=\"font-family:system-ui,sans-serif;text-align:center;padding:48px 16px\"><h1 style=\"font-size:22px\">Cozy Safe</h1><p>Google answered. You can close this tab and go back to Cozy Safe.</p></body></html>";

/// Waiting for the browser's redirect, on `127.0.0.1` only.
pub struct Loopback {
    listener: TcpListener,
    port: u16,
}

impl Loopback {
    /// Listen on `127.0.0.1` at a free port. Needs [`Permit::google_sign_in`].
    pub fn open(permit: Permit) -> Result<Loopback> {
        if !permit.is_google_sign_in() {
            return Err(Error::Corrupt("permit is not for google sign-in"));
        }
        let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        Ok(Loopback { listener, port })
    }

    /// The port to put in the redirect address (`http://127.0.0.1:<port>/`).
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The query of the first `GET /?…` that reaches the listener (without the `?`),
    /// answered with a page saying the tab can be closed. `None` when `wait` passes or
    /// `cancel` is set first. The listener is closed when this returns, whatever happens.
    pub fn wait(self, wait: Duration, cancel: &AtomicBool) -> Result<Option<String>> {
        let deadline = Instant::now() + wait;
        // Each connection is read on a thread of its own, so an idle one (a browser's
        // speculative connection) does not hold up the redirect behind it.
        let (tx, rx) = mpsc::channel::<Option<String>>();
        let mut reading = 0usize;
        loop {
            while let Ok(got) = rx.try_recv() {
                reading -= 1;
                if got.is_some() {
                    return Ok(got);
                }
            }
            if cancel.load(Ordering::SeqCst) || Instant::now() >= deadline {
                return Ok(None);
            }
            if reading >= MAX_READING {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            match self.listener.accept() {
                Ok((stream, peer)) => {
                    // Bound to 127.0.0.1, so only this computer can reach it; checked anyway.
                    if !peer.ip().is_loopback() {
                        continue;
                    }
                    reading += 1;
                    let tx = tx.clone();
                    std::thread::spawn(move || {
                        let _ = tx.send(answer(stream));
                    });
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(e) => return Err(e.into()),
            }
        }
    }
}

/// Read one request on `stream`: the redirect's query when it is one (answered with
/// [`PAGE`]), otherwise `None` (answered 404, or dropped when nothing readable came).
fn answer(mut stream: TcpStream) -> Option<String> {
    stream.set_nonblocking(false).ok()?;
    stream.set_read_timeout(Some(READ_WAIT)).ok()?;
    stream.set_write_timeout(Some(READ_WAIT)).ok()?;
    let mut head = Vec::new();
    let mut buf = [0u8; 1024];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        head.extend_from_slice(&buf[..n]);
        if head.len() > MAX_REQUEST {
            return None;
        }
    }
    let query = redirect_query(&head);
    let reply = match &query {
        Some(_) => format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n{PAGE}",
            PAGE.len()
        ),
        None => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_owned(),
    };
    let _ = stream.write_all(reply.as_bytes());
    let _ = stream.flush();
    query
}

/// `code=…&state=…` from a request head `GET /?code=…&state=… HTTP/1.1`; `None` for any
/// other request (another method or path, no query, no state).
fn redirect_query(head: &[u8]) -> Option<String> {
    let line = head.split(|&b| b == b'\n').next()?;
    let line = std::str::from_utf8(line).ok()?.trim_end_matches('\r');
    let mut words = line.split(' ');
    let (method, target, version) = (words.next()?, words.next()?, words.next()?);
    if method != "GET" || !version.starts_with("HTTP/1.") || words.next().is_some() {
        return None;
    }
    let query = target.strip_prefix("/?")?;
    let has_state = query.split('&').any(|p| p.starts_with("state="));
    has_state.then(|| query.to_owned())
}

/// Google's OAuth endpoints this app uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Endpoint {
    /// `/token`: exchange the code, or refresh the access token.
    Token,
    /// `/revoke`: take back the app's access ("Remove account").
    Revoke,
}

impl Endpoint {
    fn path(self) -> &'static str {
        match self {
            Endpoint::Token => "/token",
            Endpoint::Revoke => "/revoke",
        }
    }
}

/// Google's answer: the HTTP status and the body as text (JSON for `/token`).
#[derive(Debug, PartialEq, Eq)]
pub struct Answer {
    pub status: u16,
    pub body: String,
}

/// POST `form` (already `application/x-www-form-urlencoded`) to `endpoint` on
/// [`crate::https::OAUTH_HOST`]. Needs [`Permit::google_sign_in`].
pub fn post(permit: Permit, endpoint: Endpoint, form: &str) -> Result<Answer> {
    if !permit.is_google_sign_in() {
        return Err(Error::Corrupt("permit is not for google sign-in"));
    }
    post_with(&Client::to(Host::OAuth), endpoint, form)
}

fn post_with(client: &Client, endpoint: Endpoint, form: &str) -> Result<Answer> {
    let r = client.request(
        "POST",
        endpoint.path(),
        "",
        &[("Accept", "application/json".to_owned())],
        Body::Bytes(
            "application/x-www-form-urlencoded",
            form.as_bytes().to_vec(),
        ),
    )?;
    let status = r.status;
    let body = r.bytes_max(MAX_ANSWER)?;
    Ok(Answer {
        status,
        body: String::from_utf8_lossy(&body).into_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::sync::{Arc, Mutex};

    fn get(port: u16, raw: &str) -> String {
        let mut s = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        s.write_all(raw.as_bytes()).unwrap();
        let mut out = String::new();
        let _ = s.read_to_string(&mut out);
        out
    }

    #[test]
    fn only_a_sign_in_permit_opens_it() {
        assert!(Loopback::open(Permit::google_drive()).is_err());
        assert!(post(Permit::google_drive(), Endpoint::Token, "a=b").is_err());
    }

    #[test]
    fn listens_on_loopback_only_and_returns_the_redirect() {
        let lb = Loopback::open(Permit::google_sign_in()).unwrap();
        assert_eq!(
            lb.listener.local_addr().unwrap().ip(),
            std::net::IpAddr::V4(Ipv4Addr::LOCALHOST)
        );
        let port = lb.port();
        let browser = std::thread::spawn(move || {
            // A speculative connection that sends nothing, then a favicon, then the redirect.
            let idle = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            let fav = get(port, "GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n");
            let page = get(
                port,
                "GET /?state=s1&code=c1&scope=x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            );
            drop(idle);
            (fav, page)
        });
        let cancel = AtomicBool::new(false);
        let q = lb.wait(Duration::from_secs(20), &cancel).unwrap();
        assert_eq!(q.as_deref(), Some("state=s1&code=c1&scope=x"));
        let (fav, page) = browser.join().unwrap();
        assert!(fav.starts_with("HTTP/1.1 404"));
        assert!(page.starts_with("HTTP/1.1 200"));
        assert!(page.contains("close this tab"));
        // Closed after the one redirect.
        assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err());
    }

    #[test]
    fn cancel_and_deadline_end_the_wait() {
        let lb = Loopback::open(Permit::google_sign_in()).unwrap();
        let cancel = AtomicBool::new(true);
        assert_eq!(lb.wait(Duration::from_secs(60), &cancel).unwrap(), None);
        let lb = Loopback::open(Permit::google_sign_in()).unwrap();
        let cancel = AtomicBool::new(false);
        let t = Instant::now();
        assert_eq!(lb.wait(Duration::from_millis(200), &cancel).unwrap(), None);
        assert!(t.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn only_a_get_with_a_state_is_the_redirect() {
        let q = |s: &str| redirect_query(s.as_bytes());
        assert_eq!(
            q("GET /?code=a&state=b HTTP/1.1\r\n").as_deref(),
            Some("code=a&state=b")
        );
        assert_eq!(
            q("GET /?error=access_denied&state=b HTTP/1.1\r\n").as_deref(),
            Some("error=access_denied&state=b")
        );
        assert_eq!(q("GET /?code=a HTTP/1.1\r\n"), None);
        assert_eq!(q("POST /?code=a&state=b HTTP/1.1\r\n"), None);
        assert_eq!(q("GET /x?code=a&state=b HTTP/1.1\r\n"), None);
        assert_eq!(q("GET / HTTP/1.1\r\n"), None);
        assert_eq!(q(""), None);
    }

    struct Fake {
        reply: Cursor<Vec<u8>>,
        sent: Arc<Mutex<Vec<u8>>>,
    }
    impl Read for Fake {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            self.reply.read(buf)
        }
    }
    impl Write for Fake {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.sent.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    impl crate::https::Wire for Fake {}

    #[test]
    fn posts_the_form_to_the_oauth_host_without_a_bearer() {
        let sent = Arc::new(Mutex::new(Vec::new()));
        let s = sent.clone();
        let client = Client::with_dial(
            Host::OAuth,
            Box::new(move || {
                Ok(Box::new(Fake {
                    reply: Cursor::new(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 18\r\n\r\n{\"access_token\":1}"[..]
                            .to_vec(),
                    ),
                    sent: s.clone(),
                }) as Box<dyn crate::https::Wire>)
            }),
        );
        let a = post_with(&client, Endpoint::Token, "grant_type=x&code=y").unwrap();
        assert_eq!(a.status, 200);
        assert_eq!(a.body, "{\"access_token\":1}");
        let sent = String::from_utf8(sent.lock().unwrap().clone()).unwrap();
        assert!(sent.starts_with("POST /token HTTP/1.1\r\nHost: oauth2.googleapis.com\r\n"));
        assert!(!sent.contains("Authorization"));
        assert!(sent.contains("Content-Type: application/x-www-form-urlencoded\r\n"));
        assert!(sent.ends_with("\r\n\r\ngrant_type=x&code=y"));
    }
}
