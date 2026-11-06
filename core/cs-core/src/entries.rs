//! Secure items (docs/adr/0009-secure-items.md): logins, one-time codes (2FA) and
//! recovery codes. Each is an ordinary item whose content is a small JSON document:
//!
//! ```text
//! login  {"v":1, "username", "password", "urls":[…], "otp":{…}, "notes", "fields":[…]}
//! otp    {"v":1, "issuer", "account", "secret", "algo", "digits", "period", "notes"}
//! codes  {"v":1, "account", "codes":[{"code", "used"}], "notes"}
//! ```
//!
//! The app owns the fields; the core checks only that the content is a JSON object with
//! a version `v`, and reads from it the [`Summary`] kept in the item's record (the
//! account and the web sites' host names), so lists and search never open the content.
//! Unknown fields are kept as they are: the app edits the document it read.

use crate::format::Summary;
use crate::json::{self, Fields, Value};
use crate::{Error, Result};

/// The content version this app writes. A newer one is still read.
pub const VERSION: u32 = 1;

/// What lists show of a secure item's content, or [`Error::BadEntry`] when the content is
/// not an entry document.
pub fn summary_of(kind: &str, content: &[u8]) -> Result<Summary> {
    let doc = json::parse(content).map_err(|_| Error::BadEntry)?;
    let f = Fields::of(&doc).ok_or(Error::BadEntry)?;
    match f.u32("v") {
        Ok(Some(v)) if v >= 1 => {}
        _ => return Err(Error::BadEntry),
    }
    let text = |key| {
        f.str(key)
            .ok()
            .flatten()
            .unwrap_or_default()
            .trim()
            .to_owned()
    };
    let account = match kind {
        crate::items::kind::LOGIN => text("username"),
        _ => text("account"),
    };
    let mut hosts = Vec::new();
    if kind == crate::items::kind::LOGIN {
        if let Some(Value::Array(urls)) = f.get("urls") {
            for url in urls {
                if let Value::String(url) = url {
                    if let Some(h) = host_of(url) {
                        if !hosts.contains(&h) {
                            hosts.push(h);
                        }
                    }
                }
            }
        }
    }
    Ok(Summary {
        account,
        hosts,
        of: String::new(),
    })
}

/// The host name of a web address as a person types it: `https://www.GitHub.com/login`,
/// `github.com:443` and `github.com` all give `github.com`. None when nothing is left.
pub fn host_of(url: &str) -> Option<String> {
    let mut s = url.trim();
    if let Some(i) = s.find("://") {
        s = &s[i + 3..];
    }
    let end = s.find(['/', '?', '#']).unwrap_or(s.len());
    s = &s[..end];
    if let Some(i) = s.rfind('@') {
        s = &s[i + 1..];
    }
    // A port, but not inside an IPv6 address in brackets.
    if let Some(i) = s.rfind(':') {
        if !s[i..].contains(']') {
            s = &s[..i];
        }
    }
    let s = s.trim_end_matches('.').to_ascii_lowercase();
    let s = s.strip_prefix("www.").map(str::to_owned).unwrap_or(s);
    (!s.is_empty() && !s.contains(char::is_whitespace)).then_some(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::items::kind;

    #[test]
    fn hosts_as_people_type_them() {
        for (url, host) in [
            ("https://www.GitHub.com/login?x=1", "github.com"),
            ("github.com", "github.com"),
            ("github.com:443/path", "github.com"),
            ("http://user:pw@mail.example.org", "mail.example.org"),
            ("accounts.google.com.", "accounts.google.com"),
            ("[::1]:8080", "[::1]"),
            ("androidapp://com.example.app", "com.example.app"),
        ] {
            assert_eq!(host_of(url).as_deref(), Some(host), "{url}");
        }
        assert_eq!(host_of("  "), None);
        assert_eq!(host_of("https:///x"), None);
        assert_eq!(host_of("not a host"), None);
    }

    #[test]
    fn a_login_shows_its_user_name_and_sites() {
        let doc = br#"{"v":1,"username":" kien@example.com ","password":"s3cret",
            "urls":["https://github.com/login","www.github.com","gist.github.com",7],
            "later_field":{"kept":true}}"#;
        let s = summary_of(kind::LOGIN, doc).unwrap();
        assert_eq!(s.account, "kien@example.com");
        assert_eq!(s.hosts, ["github.com", "gist.github.com"]);
    }

    #[test]
    fn codes_show_their_account_and_no_site() {
        let doc = br#"{"v":2,"issuer":"GitHub","account":"kien","secret":"JBSWY3DP"}"#;
        let s = summary_of(kind::OTP, doc).unwrap();
        assert_eq!((s.account.as_str(), s.hosts.len()), ("kien", 0));
        let s = summary_of(kind::CODES, br#"{"v":1}"#).unwrap();
        assert_eq!(s, Summary::default());
    }

    #[test]
    fn anything_else_is_refused() {
        for doc in [
            &b"[]"[..],
            b"{}",
            b"{\"v\":0}",
            b"{\"v\":\"1\"}",
            b"not json",
            b"",
        ] {
            assert!(matches!(summary_of(kind::LOGIN, doc), Err(Error::BadEntry)));
        }
    }
}
