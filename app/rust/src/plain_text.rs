//! Plain text files read inside the app in Top Secret Mode (owner 2026-11-01, "careful,
//! no risk"): the same exposure as a note, and nothing more. A file is handed over as
//! text only when every check here passes; otherwise the call is refused, as for any
//! other file in that mode. The screen draws what comes back as plain characters: no
//! Markdown, no colouring, no links.
//!
//! The checks, in order: the item is a file, its name ends in one of [`EXTENSIONS`]
//! (a name is only a label, so the bytes are checked as well), it is at most [`MAX`]
//! bytes, it is valid UTF-8, and it holds no control characters but tab, line feed and
//! carriage return (no NUL, no escape sequences, nothing a renderer might act on).

/// The largest file read as text.
pub(crate) const MAX: usize = 1 << 20;

/// Extensions of plain text kept in a vault: notes, data, settings, keys and certificates.
pub(crate) const EXTENSIONS: &[&str] = &[
    "txt", "text", "md", "markdown", "log", "csv", "tsv", "json", "yaml", "yml", "ini", "conf",
    "cfg", "env", "pem", "pub", "crt", "cer", "csr", "asc",
];

/// Whether `name` ends in one of [`EXTENSIONS`] (any case).
pub(crate) fn allowed_name(name: &str) -> bool {
    let Some((_, ext)) = name.rsplit_once('.') else {
        return false;
    };
    let ext = ext.to_ascii_lowercase();
    EXTENSIONS.contains(&ext.as_str())
}

/// `bytes` as text when they pass every check, a leading byte order mark dropped.
pub(crate) fn checked(bytes: &[u8]) -> Option<String> {
    if bytes.len() > MAX {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let clean = text
        .chars()
        .all(|c| !c.is_control() || matches!(c, '\t' | '\n' | '\r'));
    clean.then(|| text.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_listed_extensions_pass() {
        for ok in ["a.txt", "B.MD", "keys.pub", "x.y.json", "notes.Log"] {
            assert!(allowed_name(ok), "{ok}");
        }
        for no in [
            "a",
            "a.pdf",
            "a.html",
            "a.svg",
            "a.key",
            "txt",
            "a.txt.exe",
            "a.docx",
        ] {
            assert!(!allowed_name(no), "{no}");
        }
    }

    #[test]
    fn text_passes_and_anything_else_is_refused() {
        assert_eq!(
            checked(b"hello\tworld\r\nline 2").as_deref(),
            Some("hello\tworld\r\nline 2")
        );
        assert_eq!(
            checked("Tiếng Việt, 日本語".as_bytes()).as_deref(),
            Some("Tiếng Việt, 日本語")
        );
        assert_eq!(checked("\u{feff}bom".as_bytes()).as_deref(), Some("bom"));
        assert_eq!(checked(b"").as_deref(), Some(""));
        // Not UTF-8, a NUL, an escape sequence, a C1 control.
        assert!(checked(&[0xff, 0xfe, 0x00]).is_none());
        assert!(checked(b"a\0b").is_none());
        assert!(checked(b"\x1b[31mred").is_none());
        assert!(checked("a\u{0085}b".as_bytes()).is_none());
        // Past the size limit.
        assert!(checked(&vec![b'a'; MAX + 1]).is_none());
        assert!(checked(&vec![b'a'; MAX]).is_some());
    }
}
