//! The few HTTPS requests Google Drive needs, on rustls, to one host only. A full HTTP
//! client pulled in 44 crates (docs/supply-chain.md); this is HTTP/1.1 with one request
//! per connection, `Content-Length` or chunked bodies, nothing else.
//!
//! The only name ever looked up is [`HOST`]: this is the one place in the app that
//! resolves a name, and it takes no name from outside.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use cs_vault::{Error, Result};

/// Google's API host: Drive files, uploads and downloads all live here.
pub(crate) const HOST: &str = "www.googleapis.com";
/// Largest response read into memory (listings, JSON); files are streamed instead.
pub(crate) const MAX_SMALL: usize = 8 << 20;
const MAX_HEADERS: usize = 64 << 10;

pub(crate) enum Body<'a> {
    None,
    Bytes(&'a str, Vec<u8>),
    Stream(&'a str, u64, &'a mut dyn Read),
}

pub(crate) struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    reader: BodyReader,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// The whole body, refused past [`MAX_SMALL`].
    pub fn bytes(mut self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        (&mut self.reader)
            .take(MAX_SMALL as u64 + 1)
            .read_to_end(&mut out)?;
        if out.len() > MAX_SMALL {
            return Err(Error::Corrupt("drive response too large"));
        }
        Ok(out)
    }

    pub fn copy_to(mut self, out: &mut dyn Write) -> Result<u64> {
        Ok(std::io::copy(&mut self.reader, out)?)
    }
}

type Tls = rustls::StreamOwned<rustls::ClientConnection, TcpStream>;

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

fn connect() -> Result<Tls> {
    let addr = (HOST, 443)
        .to_socket_addrs()?
        .next()
        .ok_or(Error::Corrupt("drive host not found"))?;
    let tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(15))?;
    tcp.set_read_timeout(Some(Duration::from_secs(60)))?;
    tcp.set_write_timeout(Some(Duration::from_secs(60)))?;
    let name = rustls::pki_types::ServerName::try_from(HOST).expect("valid host");
    let conn = rustls::ClientConnection::new(tls_config(), name)
        .map_err(|_| Error::Corrupt("drive tls"))?;
    Ok(rustls::StreamOwned::new(conn, tcp))
}

/// One request to [`HOST`]. `path` starts with `/` and is sent as it is.
pub(crate) fn request(
    method: &str,
    path: &str,
    token: &str,
    extra: &[(&str, String)],
    body: Body,
) -> Result<Response> {
    if !path.starts_with('/') || path.contains(['\r', '\n', ' ']) {
        return Err(Error::Corrupt("drive path"));
    }
    let mut tls = connect()?;
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {token}\r\nConnection: close\r\nUser-Agent: CozySafe\r\nAccept-Encoding: identity\r\n"
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
    tls.write_all(head.as_bytes())?;
    match body {
        Body::None => {}
        Body::Bytes(_, b) => tls.write_all(&b)?,
        Body::Stream(_, len, src) => {
            let sent = std::io::copy(&mut src.take(len), &mut tls)?;
            if sent != len {
                return Err(Error::Corrupt("drive upload short"));
            }
        }
    }
    tls.flush()?;
    read_response(BufReader::new(tls))
}

fn read_response<R: Read + Send + 'static>(mut r: BufReader<R>) -> Result<Response> {
    let mut seen = 0usize;
    let mut line = String::new();
    let mut next = |r: &mut BufReader<R>, line: &mut String| -> Result<()> {
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
    let status: u16 = line
        .split_whitespace()
        .nth(1)
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
    let get = |n: &str| {
        headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(n))
            .map(|(_, v)| v.clone())
    };
    let reader = if get("Transfer-Encoding").is_some_and(|v| v.eq_ignore_ascii_case("chunked")) {
        BodyReader::Chunked(Chunked {
            inner: Box::new(r),
            left: 0,
            done: false,
        })
    } else if let Some(len) = get("Content-Length") {
        let len: u64 = len
            .parse()
            .map_err(|_| Error::Corrupt("drive content length"))?;
        BodyReader::Plain(Box::new(r.take(len)))
    } else {
        BodyReader::Plain(Box::new(r))
    };
    Ok(Response {
        status,
        headers,
        reader,
    })
}

enum BodyReader {
    Plain(Box<dyn Read + Send>),
    Chunked(Chunked),
}

impl Read for BodyReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            BodyReader::Plain(r) => r.read(buf),
            BodyReader::Chunked(c) => c.read(buf),
        }
    }
}

/// `Transfer-Encoding: chunked`, decoded as it is read.
struct Chunked {
    inner: Box<dyn BufRead + Send>,
    left: u64,
    done: bool,
}

impl Chunked {
    fn size_line(&mut self) -> std::io::Result<u64> {
        let mut line = String::new();
        (&mut self.inner).take(1024).read_line(&mut line)?;
        let hex = line
            .trim_end_matches(['\r', '\n'])
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        u64::from_str_radix(hex, 16).map_err(|_| std::io::Error::other("bad chunk size"))
    }
}

impl Read for Chunked {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.done || buf.is_empty() {
            return Ok(0);
        }
        if self.left == 0 {
            self.left = self.size_line()?;
            if self.left == 0 {
                self.done = true;
                return Ok(0);
            }
        }
        let want = (buf.len() as u64).min(self.left) as usize;
        let n = self.inner.read(&mut buf[..want])?;
        if n == 0 {
            return Err(std::io::Error::other("chunk cut short"));
        }
        self.left -= n as u64;
        if self.left == 0 {
            let mut crlf = [0u8; 2];
            self.inner.read_exact(&mut crlf)?;
        }
        Ok(n)
    }
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

    #[test]
    fn chunked_bodies_and_lengths_are_read_exactly() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;x=1\r\n world\r\n0\r\n\r\n";
        let r = read_response(BufReader::new(std::io::Cursor::new(raw.to_vec()))).unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.bytes().unwrap(), b"hello world");
        let raw = b"HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabcEXTRA";
        let r = read_response(BufReader::new(std::io::Cursor::new(raw.to_vec()))).unwrap();
        assert_eq!(r.status, 404);
        assert_eq!(r.bytes().unwrap(), b"abc");
    }

    #[test]
    fn a_bad_answer_is_refused() {
        for raw in [
            &b"garbage"[..],
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
        ] {
            let r = read_response(BufReader::new(std::io::Cursor::new(raw.to_vec())));
            assert!(r.is_err() || r.unwrap().bytes().is_err());
        }
        // An endless header is cut off.
        let mut raw = b"HTTP/1.1 200 OK\r\nX: ".to_vec();
        raw.extend(std::iter::repeat_n(b'a', MAX_HEADERS + 10));
        assert!(read_response(BufReader::new(std::io::Cursor::new(raw))).is_err());
    }

    #[test]
    fn query_values_are_encoded() {
        assert_eq!(encode("name = 'a b'"), "name%20%3D%20%27a%20b%27");
        assert_eq!(encode("x-y_z.~"), "x-y_z.~");
    }
}
