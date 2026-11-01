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

/// Extensions of plain text kept in a vault, the same as the app reads as text in the
/// everyday mode (`textExtensions` in lib/screens/file_view.dart; a test keeps the two
/// lists equal). The name is only a label: the bytes are checked too ([`checked`]).
pub(crate) const EXTENSIONS: &[&str] = &[
    "adoc",
    "ahk",
    "arb",
    "asc",
    "asm",
    "ass",
    "atom",
    "bash",
    "bat",
    "bib",
    "c",
    "cc",
    "cer",
    "cfg",
    "cjs",
    "clj",
    "cls",
    "cmake",
    "cmd",
    "conf",
    "cpp",
    "crt",
    "cs",
    "csr",
    "css",
    "csv",
    "cue",
    "dart",
    "desktop",
    "diff",
    "dockerignore",
    "editorconfig",
    "el",
    "eml",
    "env",
    "erl",
    "ex",
    "exs",
    "f90",
    "fish",
    "fs",
    "geojson",
    "gitignore",
    "go",
    "gpg",
    "gpx",
    "gql",
    "gradle",
    "graphql",
    "groovy",
    "h",
    "hcl",
    "hpp",
    "hs",
    "htaccess",
    "htm",
    "html",
    "ics",
    "ini",
    "java",
    "jl",
    "js",
    "json",
    "jsonl",
    "jsx",
    "key",
    "kml",
    "kt",
    "kts",
    "less",
    "lisp",
    "lock",
    "log",
    "lrc",
    "lua",
    "m",
    "m3u",
    "m3u8",
    "markdown",
    "md",
    "mdx",
    "mjs",
    "mk",
    "ml",
    "mm",
    "ndjson",
    "nfo",
    "nim",
    "nix",
    "npmrc",
    "opml",
    "org",
    "ovpn",
    "pas",
    "patch",
    "pem",
    "php",
    "pl",
    "plist",
    "pls",
    "po",
    "pot",
    "prisma",
    "properties",
    "proto",
    "ps1",
    "psql",
    "pub",
    "py",
    "r",
    "rb",
    "reg",
    "resx",
    "rkt",
    "rs",
    "rss",
    "rst",
    "s",
    "scala",
    "scm",
    "scss",
    "service",
    "sh",
    "sol",
    "sql",
    "srt",
    "ssa",
    "strings",
    "sty",
    "sub",
    "svelte",
    "svg",
    "swift",
    "tcl",
    "tex",
    "text",
    "textile",
    "tf",
    "toml",
    "ts",
    "tsv",
    "tsx",
    "txt",
    "url",
    "vbs",
    "vcf",
    "vim",
    "vtt",
    "vue",
    "webloc",
    "webmanifest",
    "wg",
    "wiki",
    "xhtml",
    "xlf",
    "xml",
    "yaml",
    "yml",
    "zig",
    "zsh",
];

/// Names read as text without an extension (README, LICENSE…), any case.
pub(crate) const NAMES: &[&str] = &[
    "authors",
    "changelog",
    "dockerfile",
    "licence",
    "license",
    "makefile",
    "notice",
    "readme",
];

/// Whether `name` ends in one of [`EXTENSIONS`] (any case).
pub(crate) fn allowed_name(name: &str) -> bool {
    let Some((_, ext)) = name.rsplit_once('.') else {
        return NAMES.contains(&name.to_ascii_lowercase().as_str());
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
        .all(|c| (!c.is_control() || matches!(c, '\t' | '\n' | '\r')) && !reorders(c));
    clean.then(|| text.to_owned())
}

/// Characters that change the order text is drawn in, so what shows is not what the file
/// says (a key, a setting): bidi embeddings, overrides, isolates and marks.
fn reorders(c: char) -> bool {
    matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_listed_extensions_pass() {
        for ok in ["a.txt", "B.MD", "keys.pub", "x.y.json", "notes.Log"] {
            assert!(allowed_name(ok), "{ok}");
        }
        assert!(allowed_name("README") && allowed_name("Makefile") && allowed_name(".gitignore"));
        for no in [
            "a",
            "a.pdf",
            "txt",
            "a.txt.exe",
            "a.docx",
            "a.png",
            "a.zip",
            "a.mp4",
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
        // Text drawn in another order than it is written.
        assert!(checked("key = abc\u{202e}fed".as_bytes()).is_none());
        assert!(checked("a\u{2067}b".as_bytes()).is_none());
        // Past the size limit.
        assert!(checked(&vec![b'a'; MAX + 1]).is_none());
        assert!(checked(&vec![b'a'; MAX]).is_some());
    }
}
