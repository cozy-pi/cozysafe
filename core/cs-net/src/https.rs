//! The few HTTPS requests Google Drive needs, on rustls, to two fixed hosts only. A full HTTP
//! client pulled in 44 crates (docs/supply-chain.md); this is HTTP/1.1 with
//! `Content-Length` or chunked bodies, nothing else. Up to [`POOL`] connections are kept
//! open and reused (keep-alive) while the server allows it, so a sync of many small
//! items, a few at once, pays for a few TLS handshakes, not one per request.
//!
//! The only names ever looked up are [`HOST`] and, for Google sign-in on computers,
//! [`OAUTH_HOST`] (crate::oauth): this is the one place in the app that resolves a name,
//! and it takes no name from outside (a [`Host`] is one of the two constants).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cs_vault::{Error, Result};

/// Google's API host: Drive files, uploads and downloads all live here.
pub(crate) const HOST: &str = "www.googleapis.com";
/// Google's OAuth host: the token exchange, refresh and revoke of the sign-in on
/// computers (crate::oauth). Phones sign in through Google's own SDKs instead.
pub(crate) const OAUTH_HOST: &str = "oauth2.googleapis.com";

/// Which of the two hosts a [`Client`] talks to. Not a string: nothing from outside the
/// crate can name another host.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Host {
    Api,
    OAuth,
}

impl Host {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Host::Api => HOST,
            Host::OAuth => OAUTH_HOST,
        }
    }
}
/// Largest response read into memory (listings, JSON); files are streamed instead.
pub(crate) const MAX_SMALL: usize = 8 << 20;
const MAX_HEADERS: usize = 64 << 10;
/// A connection idle longer than this is not reused (servers drop idle ones after ~60 s).
const MAX_IDLE: Duration = Duration::from_secs(50);
/// Idle connections kept, one per request a sync runs at once.
pub(crate) const POOL: usize = 4;
/// A body nobody read is read away up to this much to keep the connection; past it the
/// connection is closed instead.
const DRAIN: u64 = 64 << 10;

pub(crate) enum Body<'a> {
    None,
    Bytes(&'a str, Vec<u8>),
    /// Read once as it is sent, so a request with it is never sent twice.
    Stream(&'a str, u64, &'a mut dyn Read),
}

/// What HTTP is spoken over: TLS to a [`Host`] in the app, bytes in memory in tests.
pub(crate) trait Wire: Read + Write + Send {
    /// False once the server has closed, or written without being asked (checked
    /// before a kept connection is reused).
    fn open(&self) -> bool {
        true
    }
}

type Tls = rustls::StreamOwned<rustls::ClientConnection, TcpStream>;

impl Wire for Tls {
    fn open(&self) -> bool {
        // A peek that would block: nothing came (no close_notify, no FIN) since the
        // last answer.
        let tcp = &self.sock;
        if tcp.set_nonblocking(true).is_err() {
            return false;
        }
        let mut b = [0u8; 1];
        let quiet =
            matches!(tcp.peek(&mut b), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock);
        tcp.set_nonblocking(false).is_ok() && quiet
    }
}

type Conn = BufReader<Box<dyn Wire>>;
type Dial = Box<dyn Fn() -> Result<Box<dyn Wire>> + Send + Sync>;

/// Requests to one [`Host`], over kept connections. Shared between threads: each
/// request takes a connection of its own (a kept one, or a new one) and hands it back
/// after.
pub(crate) struct Client {
    /// Idle connections, the most recently used last.
    idle: Mutex<Vec<(Conn, Instant)>>,
    dial: Dial,
    host: Host,
}

impl Client {
    /// Google Drive's API ([`HOST`]).
    pub fn new() -> Self {
        Client::to(Host::Api)
    }

    pub fn to(host: Host) -> Self {
        Client::with_dial(
            host,
            Box::new(move || Ok(Box::new(connect(host)?) as Box<dyn Wire>)),
        )
    }

    pub(crate) fn with_dial(host: Host, dial: Dial) -> Self {
        Client {
            idle: Mutex::new(Vec::new()),
            dial,
            host,
        }
    }

    /// The most recent kept connection that is still recent and open; the others met on
    /// the way are closed.
    fn take(&self) -> Option<Conn> {
        let mut idle = self.idle.lock().unwrap_or_else(|p| p.into_inner());
        while let Some((conn, at)) = idle.pop() {
            if at.elapsed() < MAX_IDLE && conn.get_ref().open() {
                return Some(conn);
            }
        }
        None
    }

    /// Keep `conn` for the next request; past [`POOL`] the oldest is closed.
    fn keep(&self, conn: Conn) {
        let mut idle = self.idle.lock().unwrap_or_else(|p| p.into_inner());
        idle.push((conn, Instant::now()));
        if idle.len() > POOL {
            idle.remove(0);
        }
    }

    /// One request to this client's host. `path` starts with `/` and is sent as it is;
    /// an empty `token` sends no Authorization header (the OAuth endpoints). The next
    /// request reuses the connection once this answer is read to its end (or dropped).
    pub fn request(
        &self,
        method: &str,
        path: &str,
        token: &str,
        extra: &[(&str, String)],
        mut body: Body,
    ) -> Result<Response<'_>> {
        if !path.starts_with('/') || path.contains(['\r', '\n', ' ']) {
            return Err(Error::Corrupt("drive path"));
        }
        if token.contains(['\r', '\n']) {
            return Err(Error::Corrupt("drive header"));
        }
        let host = self.host.name();
        let mut head = format!("{method} {path} HTTP/1.1\r\nHost: {host}\r\n");
        if !token.is_empty() {
            head.push_str(&format!("Authorization: Bearer {token}\r\n"));
        }
        head.push_str(
            "Connection: keep-alive\r\nUser-Agent: CozySafe\r\nAccept-Encoding: identity\r\n",
        );
        for (k, v) in extra {
            if v.contains(['\r', '\n']) {
                return Err(Error::Corrupt("drive header"));
            }
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        match &body {
            Body::None => head.push_str("Content-Length: 0\r\n"),
            Body::Bytes(kind, b) => head.push_str(&format!(
                "Content-Type: {kind}\r\nContent-Length: {}\r\n",
                b.len()
            )),
            Body::Stream(kind, len, _) => head.push_str(&format!(
                "Content-Type: {kind}\r\nContent-Length: {len}\r\n"
            )),
        }
        head.push_str("\r\n");
        if let Some(conn) = self.take() {
            let again = !matches!(body, Body::Stream(..));
            match self.send(conn, &head, &mut body) {
                Ok(r) => return Ok(r),
                // The server closed the kept connection before answering: once more on
                // a new one, if the body can be sent again.
                Err(Failed { quiet: true, .. }) if again => {}
                Err(f) => return Err(f.error),
            }
        }
        let conn = BufReader::new((self.dial)()?);
        self.send(conn, &head, &mut body).map_err(|f| f.error)
    }

    fn send(
        &self,
        mut conn: Conn,
        head: &str,
        body: &mut Body,
    ) -> std::result::Result<Response<'_>, Failed> {
        let quiet = |e: std::io::Error| Failed {
            quiet: true,
            error: e.into(),
        };
        let w = conn.get_mut();
        w.write_all(head.as_bytes()).map_err(quiet)?;
        match body {
            Body::None => {}
            Body::Bytes(_, b) => w.write_all(b).map_err(quiet)?,
            Body::Stream(_, len, src) => {
                let sent = std::io::copy(&mut src.take(*len), w).map_err(quiet)?;
                if sent != *len {
                    return Err(Failed {
                        quiet: false,
                        error: Error::Corrupt("drive upload short"),
                    });
                }
            }
        }
        w.flush().map_err(quiet)?;
        // Not one byte back: the connection was closed under us.
        match conn.fill_buf() {
            Ok([]) => return Err(quiet(std::io::ErrorKind::UnexpectedEof.into())),
            Ok(_) => {}
            Err(e) => return Err(quiet(e)),
        }
        read_response(conn, self).map_err(|error| Failed {
            quiet: false,
            error,
        })
    }
}

struct Failed {
    /// No byte of an answer came.
    quiet: bool,
    error: Error,
}

pub(crate) struct Response<'a> {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    /// None once the body is over (the connection is back in the client, or closed).
    conn: Option<Conn>,
    left: Left,
    /// The server lets the connection carry another request.
    reuse: bool,
    client: &'a Client,
}

/// How much of the body is still to come.
#[derive(Debug, PartialEq)]
enum Left {
    Length(u64),
    Chunked {
        left: u64,
        done: bool,
    },
    /// No length given: the body ends when the server closes.
    ToEnd,
}

impl Response<'_> {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// The whole body, refused past [`MAX_SMALL`].
    pub fn bytes(self) -> Result<Vec<u8>> {
        self.bytes_max(MAX_SMALL)
    }

    /// The whole body, refused past `cap` bytes.
    pub fn bytes_max(mut self, cap: usize) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        (&mut self).take(cap as u64 + 1).read_to_end(&mut out)?;
        if out.len() > cap {
            self.reuse = false;
            return Err(Error::Corrupt("drive response too large"));
        }
        Ok(out)
    }

    pub fn copy_to(mut self, out: &mut dyn Write) -> Result<u64> {
        Ok(std::io::copy(&mut self, out)?)
    }

    fn done(&self) -> bool {
        matches!(
            self.left,
            Left::Length(0) | Left::Chunked { done: true, .. }
        )
    }

    /// The body is over: the connection goes back to the client if it may be reused
    /// and nothing past this answer came with it.
    fn finish(&mut self) {
        if let Some(conn) = self.conn.take() {
            if self.reuse && self.done() && conn.buffer().is_empty() {
                self.client.keep(conn);
            }
        }
    }

    fn read_body(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let Some(conn) = self.conn.as_mut() else {
            return Ok(0);
        };
        match &mut self.left {
            Left::Length(0) | Left::Chunked { done: true, .. } => Ok(0),
            Left::Length(left) => {
                let want = (buf.len() as u64).min(*left) as usize;
                let n = conn.read(&mut buf[..want])?;
                if n == 0 {
                    return Err(std::io::Error::other("body cut short"));
                }
                *left -= n as u64;
                Ok(n)
            }
            Left::Chunked { left, done } => {
                if *left == 0 {
                    *left = size_line(conn)?;
                    if *left == 0 {
                        // Trailers (none expected), up to the empty line.
                        for _ in 0..64 {
                            if short_line(conn)?.is_empty() {
                                *done = true;
                                return Ok(0);
                            }
                        }
                        return Err(std::io::Error::other("chunk trailers"));
                    }
                }
                let want = (buf.len() as u64).min(*left) as usize;
                let n = conn.read(&mut buf[..want])?;
                if n == 0 {
                    return Err(std::io::Error::other("chunk cut short"));
                }
                *left -= n as u64;
                if *left == 0 {
                    let mut crlf = [0u8; 2];
                    conn.read_exact(&mut crlf)?;
                }
                Ok(n)
            }
            Left::ToEnd => conn.read(buf),
        }
    }
}

impl Read for Response<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        match self.read_body(buf) {
            Ok(n) => {
                if n == 0 || self.done() {
                    self.finish();
                }
                Ok(n)
            }
            Err(e) => {
                // Out of step with the server now: closed, never reused.
                self.conn = None;
                Err(e)
            }
        }
    }
}

impl Drop for Response<'_> {
    fn drop(&mut self) {
        // A body nobody read (an error's text, say): read it away to keep the
        // connection, unless it is long or only ends when the server closes.
        if self.conn.is_some() && self.reuse {
            let _ = std::io::copy(&mut (&mut *self).take(DRAIN), &mut std::io::sink());
        }
    }
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    let roots = rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    Arc::new(
        rustls::ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .expect("TLS 1.3 with ring")
            .with_root_certificates(roots)
            .with_no_client_auth(),
    )
}

/// How long all tries at a TCP connection take at most, and each but the last.
const CONNECT_WAIT: Duration = Duration::from_secs(15);
const CONNECT_TRY: Duration = Duration::from_secs(4);

/// The name's addresses, the two families taken in turn, the first one DNS gave first.
fn try_order(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    let first_v6 = addrs.first().is_some_and(SocketAddr::is_ipv6);
    let (v6, v4): (Vec<_>, Vec<_>) = addrs.into_iter().partition(SocketAddr::is_ipv6);
    let (mut a, mut b) = if first_v6 {
        (v6.into_iter(), v4.into_iter())
    } else {
        (v4.into_iter(), v6.into_iter())
    };
    let mut out = Vec::new();
    loop {
        match (a.next(), b.next()) {
            (None, None) => return out,
            (x, y) => out.extend(x.into_iter().chain(y)),
        }
    }
}

/// Every address in [`try_order`], a short wait for each but the last: only the first
/// was tried before, and on a Wi-Fi with broken IPv6 every sync hung the whole wait on
/// it and gave up, silently (owner 2026-10-29), while browsers just went over IPv4.
fn tcp_to(host: &str) -> Result<TcpStream> {
    let addrs = try_order((host, 443).to_socket_addrs()?.collect());
    connect_any(&addrs, CONNECT_WAIT, CONNECT_TRY)
}

/// The first of `addrs` that answers, within `total` in all and `each` for each but the last.
fn connect_any(addrs: &[SocketAddr], total: Duration, each: Duration) -> Result<TcpStream> {
    let started = Instant::now();
    let mut last = None;
    for (i, addr) in addrs.iter().enumerate() {
        let left = total.saturating_sub(started.elapsed());
        if left.is_zero() {
            break;
        }
        let wait = if i + 1 == addrs.len() {
            left
        } else {
            left.min(each)
        };
        match TcpStream::connect_timeout(addr, wait) {
            Ok(tcp) => return Ok(tcp),
            Err(e) => last = Some(e),
        }
    }
    match last {
        Some(e) => Err(e.into()),
        None => Err(Error::Corrupt("drive host not found")),
    }
}

fn connect(host: Host) -> Result<Tls> {
    let host = host.name();
    let tcp = tcp_to(host)?;
    tcp.set_read_timeout(Some(Duration::from_secs(60)))?;
    tcp.set_write_timeout(Some(Duration::from_secs(60)))?;
    let name = rustls::pki_types::ServerName::try_from(host).expect("valid host");
    let conn = rustls::ClientConnection::new(tls_config(), name)
        .map_err(|_| Error::Corrupt("drive tls"))?;
    Ok(rustls::StreamOwned::new(conn, tcp))
}

fn read_response(mut r: Conn, client: &Client) -> Result<Response<'_>> {
    let mut seen = 0usize;
    let mut line = String::new();
    let mut next = |r: &mut Conn, line: &mut String| -> Result<()> {
        line.clear();
        let n = (&mut *r)
            .take((MAX_HEADERS - seen.min(MAX_HEADERS)) as u64)
            .read_line(line)?;
        seen += n;
        if n == 0 || seen >= MAX_HEADERS {
            return Err(Error::Corrupt("drive response head"));
        }
        Ok(())
    };
    next(&mut r, &mut line)?;
    let mut words = line.split_whitespace();
    let version = words.next().unwrap_or("").to_owned();
    let status: u16 = words
        .next()
        .and_then(|s| s.parse().ok())
        .ok_or(Error::Corrupt("drive status line"))?;
    let mut headers = Vec::new();
    loop {
        next(&mut r, &mut line)?;
        let l = line.trim_end_matches(['\r', '\n']);
        if l.is_empty() {
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            headers.push((k.trim().to_owned(), v.trim().to_owned()));
        }
    }
    let (left, reuse) = framing(&version, status, &headers)?;
    let mut response = Response {
        status,
        headers,
        conn: Some(r),
        left,
        reuse,
        client,
    };
    if response.done() {
        response.finish();
    }
    Ok(response)
}

/// How the body ends, and whether the connection may carry another request after it.
fn framing(version: &str, status: u16, headers: &[(String, String)]) -> Result<(Left, bool)> {
    let get = |n: &str| {
        headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(n))
            .map(|(_, v)| v.as_str())
    };
    let left = if matches!(status, 100..=199 | 204 | 304) {
        Left::Length(0)
    } else if get("Transfer-Encoding").is_some_and(|v| v.eq_ignore_ascii_case("chunked")) {
        Left::Chunked {
            left: 0,
            done: false,
        }
    } else if let Some(len) = get("Content-Length") {
        Left::Length(
            len.parse()
                .map_err(|_| Error::Corrupt("drive content length"))?,
        )
    } else {
        Left::ToEnd
    };
    let close = get("Connection")
        .is_some_and(|v| v.split(',').any(|t| t.trim().eq_ignore_ascii_case("close")));
    let reuse = version == "HTTP/1.1" && !close && left != Left::ToEnd;
    Ok((left, reuse))
}

/// One line of a chunked body (size or trailer), without its line end.
fn short_line(r: &mut Conn) -> std::io::Result<String> {
    let mut line = String::new();
    if (&mut *r).take(1024).read_line(&mut line)? == 0 {
        return Err(std::io::Error::other("chunk cut short"));
    }
    Ok(line.trim_end_matches(['\r', '\n']).to_owned())
}

/// The size line of a `Transfer-Encoding: chunked` part.
fn size_line(r: &mut Conn) -> std::io::Result<u64> {
    let line = short_line(r)?;
    let hex = line.split(';').next().unwrap_or("").trim();
    u64::from_str_radix(hex, 16).map_err(|_| std::io::Error::other("bad chunk size"))
}

/// Percent-encode a query value (RFC 3986 unreserved characters kept).
pub(crate) fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::io::Cursor;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn tries_both_families_in_turn() {
        let a = |s: &str| s.parse::<SocketAddr>().unwrap();
        let got = try_order(vec![
            a("[::1]:443"),
            a("[::2]:443"),
            a("1.1.1.1:443"),
            a("2.2.2.2:443"),
            a("3.3.3.3:443"),
        ]);
        assert_eq!(
            got,
            vec![
                a("[::1]:443"),
                a("1.1.1.1:443"),
                a("[::2]:443"),
                a("2.2.2.2:443"),
                a("3.3.3.3:443")
            ]
        );
        let got = try_order(vec![a("1.1.1.1:443"), a("[::1]:443")]);
        assert_eq!(got, vec![a("1.1.1.1:443"), a("[::1]:443")]);
        assert!(try_order(vec![]).is_empty());
    }

    /// The bug of 2026-10-29: the first address never answered (broken IPv6 on a Wi-Fi)
    /// and nothing else was tried. One that is refused, one that goes nowhere (TEST-NET,
    /// it hangs or fails at once depending on the machine), then one that answers.
    #[test]
    fn an_address_that_does_not_answer_is_passed_over() {
        let closed = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap();
        let open = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let nowhere: SocketAddr = "192.0.2.1:443".parse().unwrap();
        let addrs = [closed, nowhere, open.local_addr().unwrap()];
        let started = Instant::now();
        let tcp = connect_any(&addrs, Duration::from_secs(5), Duration::from_millis(300)).unwrap();
        assert_eq!(tcp.peer_addr().unwrap(), open.local_addr().unwrap());
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "took {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn no_address_answering_ends_within_the_wait() {
        let nowhere: SocketAddr = "192.0.2.1:443".parse().unwrap();
        let started = Instant::now();
        assert!(connect_any(
            &[nowhere, nowhere],
            Duration::from_millis(600),
            Duration::from_millis(300)
        )
        .is_err());
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "took {:?}",
            started.elapsed()
        );
        assert!(connect_any(&[], Duration::from_secs(1), Duration::from_secs(1)).is_err());
    }

    /// A server in memory: each connection answers its next scripted reply once a
    /// request has been written, and closes when the script runs out.
    struct Fake {
        replies: VecDeque<Vec<u8>>,
        now: Cursor<Vec<u8>>,
        asked: bool,
        sent: Arc<Mutex<Vec<u8>>>,
    }

    impl Read for Fake {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.now.position() == self.now.get_ref().len() as u64 && self.asked {
                self.asked = false;
                if let Some(next) = self.replies.pop_front() {
                    self.now = Cursor::new(next);
                }
            }
            self.now.read(buf)
        }
    }

    impl Write for Fake {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.asked = true;
            self.sent.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl Wire for Fake {}

    struct Server {
        client: Client,
        dials: Arc<AtomicUsize>,
        sent: Arc<Mutex<Vec<u8>>>,
    }

    /// One script of replies per connection, in the order they are opened.
    fn server(conns: Vec<Vec<&[u8]>>) -> Server {
        let dials = Arc::new(AtomicUsize::new(0));
        let sent = Arc::new(Mutex::new(Vec::new()));
        let scripts: VecDeque<Vec<Vec<u8>>> = conns
            .into_iter()
            .map(|c| c.into_iter().map(<[u8]>::to_vec).collect())
            .collect();
        let scripts = Mutex::new(scripts);
        let (d, s) = (dials.clone(), sent.clone());
        let client = Client::with_dial(
            Host::Api,
            Box::new(move || {
                let replies = scripts
                    .lock()
                    .unwrap()
                    .pop_front()
                    .ok_or(Error::Corrupt("no more connections"))?;
                d.fetch_add(1, Ordering::SeqCst);
                Ok(Box::new(Fake {
                    replies: replies.into(),
                    now: Cursor::new(Vec::new()),
                    asked: false,
                    sent: s.clone(),
                }) as Box<dyn Wire>)
            }),
        );
        Server {
            client,
            dials,
            sent,
        }
    }

    fn get(c: &Client) -> Result<Vec<u8>> {
        c.request("GET", "/x", "t", &[], Body::None)?.bytes()
    }

    /// The reply in `raw` to one request on a new connection.
    fn reply(raw: &[u8]) -> Result<Vec<u8>> {
        get(&server(vec![vec![raw]]).client)
    }

    const OK: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
    const CHUNKED: &[u8] =
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;x=1\r\n world\r\n0\r\n\r\n";

    #[test]
    fn chunked_bodies_and_lengths_are_read_exactly() {
        assert_eq!(reply(CHUNKED).unwrap(), b"hello world");
        let s = server(vec![vec![
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabc",
        ]]);
        let r = s.client.request("GET", "/x", "t", &[], Body::None).unwrap();
        assert_eq!(r.status, 404);
        assert_eq!(r.bytes().unwrap(), b"abc");
    }

    #[test]
    fn a_bad_answer_is_refused() {
        for raw in [
            &b"garbage"[..],
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
            b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort",
        ] {
            assert!(reply(raw).is_err());
        }
        // An endless header is cut off.
        let mut raw = b"HTTP/1.1 200 OK\r\nX: ".to_vec();
        raw.extend(std::iter::repeat_n(b'a', MAX_HEADERS + 10));
        assert!(reply(&raw).is_err());
    }

    #[test]
    fn one_connection_carries_many_requests() {
        let s = server(vec![vec![
            OK,
            CHUNKED,
            b"HTTP/1.1 204 No Content\r\n\r\n",
            OK,
        ]]);
        assert_eq!(get(&s.client).unwrap(), b"hi");
        assert_eq!(get(&s.client).unwrap(), b"hello world");
        // No body, no length: nothing to wait for.
        let r = s
            .client
            .request("DELETE", "/x", "t", &[], Body::None)
            .unwrap();
        assert_eq!(r.status, 204);
        drop(r);
        assert_eq!(get(&s.client).unwrap(), b"hi");
        assert_eq!(s.dials.load(Ordering::SeqCst), 1);
        let sent = String::from_utf8(s.sent.lock().unwrap().clone()).unwrap();
        assert_eq!(sent.matches("Connection: keep-alive\r\n").count(), 4);
    }

    #[test]
    fn an_unread_body_is_read_away_and_the_connection_kept() {
        let s = server(vec![vec![
            b"HTTP/1.1 500 Oops\r\nContent-Length: 4\r\n\r\nfail",
            OK,
        ]]);
        let r = s.client.request("GET", "/x", "t", &[], Body::None).unwrap();
        assert_eq!(r.status, 500);
        drop(r);
        assert_eq!(get(&s.client).unwrap(), b"hi");
        assert_eq!(s.dials.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn the_server_decides_when_a_connection_ends() {
        for first in [
            &b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nhi"[..],
            b"HTTP/1.1 200 OK\r\nConnection: keep-alive, Close\r\nContent-Length: 2\r\n\r\nhi",
            b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nhi",
            // No length: read to the end, then closed.
            b"HTTP/1.1 200 OK\r\n\r\nhi",
        ] {
            let s = server(vec![vec![first, OK], vec![OK]]);
            assert_eq!(get(&s.client).unwrap(), b"hi");
            assert_eq!(get(&s.client).unwrap(), b"hi");
            assert_eq!(s.dials.load(Ordering::SeqCst), 2);
        }
    }

    #[test]
    fn a_connection_idle_too_long_is_not_reused() {
        let s = server(vec![vec![OK, OK], vec![OK]]);
        get(&s.client).unwrap();
        for (_, at) in s.client.idle.lock().unwrap().iter_mut() {
            *at = Instant::now()
                .checked_sub(MAX_IDLE + Duration::from_secs(1))
                .unwrap();
        }
        get(&s.client).unwrap();
        assert_eq!(s.dials.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn requests_at_once_each_get_a_connection_and_up_to_four_are_kept() {
        let s = server(vec![vec![OK, OK]; POOL + 1]);
        // Bodies not read yet: each request holds its connection.
        let held: Vec<_> = (0..=POOL)
            .map(|_| s.client.request("GET", "/x", "t", &[], Body::None).unwrap())
            .collect();
        assert_eq!(s.dials.load(Ordering::SeqCst), POOL + 1);
        for r in held {
            assert_eq!(r.bytes().unwrap(), b"hi");
        }
        assert_eq!(s.client.idle.lock().unwrap().len(), POOL);
        // Four more at once reuse the four kept; none dials.
        let again: Vec<_> = (0..POOL)
            .map(|_| s.client.request("GET", "/x", "t", &[], Body::None).unwrap())
            .collect();
        assert_eq!(s.dials.load(Ordering::SeqCst), POOL + 1);
        for r in again {
            assert_eq!(r.bytes().unwrap(), b"hi");
        }
    }

    #[test]
    fn a_body_past_its_cap_is_refused() {
        let s = server(vec![vec![
            b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
        ]]);
        let r = s.client.request("GET", "/x", "t", &[], Body::None).unwrap();
        assert!(r.bytes_max(4).is_err());
    }

    #[test]
    fn a_request_on_a_closed_kept_connection_is_sent_once_more() {
        // The first connection answers once, then the server closes it.
        let s = server(vec![vec![OK], vec![OK]]);
        get(&s.client).unwrap();
        let r = s
            .client
            .request("POST", "/x", "t", &[], Body::Bytes("a/b", b"x".to_vec()))
            .unwrap();
        assert_eq!(r.bytes().unwrap(), b"hi");
        assert_eq!(s.dials.load(Ordering::SeqCst), 2);
        // A body read as it is sent cannot be sent again.
        let s = server(vec![vec![OK], vec![OK]]);
        get(&s.client).unwrap();
        let mut src: &[u8] = b"x";
        let r = s
            .client
            .request("PUT", "/x", "t", &[], Body::Stream("a/b", 1, &mut src));
        assert!(r.is_err());
        assert_eq!(s.dials.load(Ordering::SeqCst), 1);
        // A new connection that fails is not tried again.
        let s = server(vec![vec![]]);
        assert!(get(&s.client).is_err());
        assert_eq!(s.dials.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn query_values_are_encoded() {
        assert_eq!(encode("name = 'a b'"), "name%20%3D%20%27a%20b%27");
        assert_eq!(encode("x-y_z.~"), "x-y_z.~");
    }
}
