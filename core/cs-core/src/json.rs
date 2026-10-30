//! The small JSON the vault files use, read and written without serde.
//!
//! Only what Cozy Safe writes: objects (keys in the order written), arrays, strings,
//! booleans, null and integers. A number with a fraction or an exponent is refused, as
//! is anything RFC 8259 does not allow (trailing commas, comments, single quotes, a lone
//! surrogate, a control character in a string, bytes after the value). Input is bounded
//! (size and nesting) because a header may come from a hostile copy of the library.
//!
//! Output matches serde_json byte for byte (`to_vec`, `to_vec_pretty`), so files written
//! before and after the move to this module look the same; the tests compare the two.

use std::fmt::Write as _;

/// Deepest nesting accepted (the vault files use 3).
const MAX_DEPTH: usize = 32;
/// Largest input accepted, in bytes (a record is a few hundred bytes).
pub const MAX_LEN: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Null,
    Bool(bool),
    /// Integers only; unsigned values above `i64::MAX` are kept as [`Value::UInt`].
    Int(i64),
    UInt(u64),
    String(String),
    Array(Vec<Value>),
    /// Keys in the order they were read or added. A key read twice is refused.
    Object(Vec<(String, Value)>),
}

/// Why a document was refused. Carries no input text (it may be secret).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ParseError {
    pub offset: usize,
    pub what: &'static str,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "invalid JSON at byte {}: {}", self.offset, self.what)
    }
}

impl std::error::Error for ParseError {}

pub fn parse(input: &[u8]) -> Result<Value, ParseError> {
    if input.len() > MAX_LEN {
        return Err(ParseError {
            offset: 0,
            what: "too long",
        });
    }
    let mut p = Parser { s: input, i: 0 };
    p.ws();
    let v = p.value(0)?;
    p.ws();
    if p.i != p.s.len() {
        return p.err("data after the value");
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn err<T>(&self, what: &'static str) -> Result<T, ParseError> {
        Err(ParseError {
            offset: self.i,
            what,
        })
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    fn eat(&mut self, lit: &[u8]) -> bool {
        if self.s[self.i..].starts_with(lit) {
            self.i += lit.len();
            true
        } else {
            false
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value, ParseError> {
        if depth > MAX_DEPTH {
            return self.err("nested too deeply");
        }
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b't') if self.eat(b"true") => Ok(Value::Bool(true)),
            Some(b'f') if self.eat(b"false") => Ok(Value::Bool(false)),
            Some(b'n') if self.eat(b"null") => Ok(Value::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => self.err("unexpected character"),
            None => self.err("unexpected end"),
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value, ParseError> {
        self.i += 1;
        let mut fields: Vec<(String, Value)> = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Value::Object(fields));
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return self.err("expected a key");
            }
            let at = self.i;
            let key = self.string()?;
            if fields.iter().any(|(k, _)| *k == key) {
                return Err(ParseError {
                    offset: at,
                    what: "key repeated",
                });
            }
            self.ws();
            if !self.eat(b":") {
                return self.err("expected ':'");
            }
            self.ws();
            let v = self.value(depth + 1)?;
            fields.push((key, v));
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    return Ok(Value::Object(fields));
                }
                _ => return self.err("expected ',' or '}'"),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value, ParseError> {
        self.i += 1;
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Value::Array(items));
        }
        loop {
            self.ws();
            items.push(self.value(depth + 1)?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    return Ok(Value::Array(items));
                }
                _ => return self.err("expected ',' or ']'"),
            }
        }
    }

    fn number(&mut self) -> Result<Value, ParseError> {
        let start = self.i;
        let neg = self.eat(b"-");
        let digits = self.i;
        match self.peek() {
            Some(b'0') => self.i += 1,
            Some(b'1'..=b'9') => {
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.i += 1;
                }
            }
            _ => return self.err("expected a digit"),
        }
        if matches!(self.peek(), Some(b'.' | b'e' | b'E')) {
            return self.err("only whole numbers are used");
        }
        // ASCII digits only, checked above.
        let text = std::str::from_utf8(&self.s[digits..self.i]).expect("ASCII digits");
        let n: u64 = match text.parse() {
            Ok(n) => n,
            Err(_) => {
                return Err(ParseError {
                    offset: start,
                    what: "number out of range",
                })
            }
        };
        if !neg {
            return Ok(match i64::try_from(n) {
                Ok(v) => Value::Int(v),
                Err(_) => Value::UInt(n),
            });
        }
        if n <= i64::MAX as u64 {
            Ok(Value::Int(-(n as i64)))
        } else if n == i64::MAX as u64 + 1 {
            Ok(Value::Int(i64::MIN))
        } else {
            Err(ParseError {
                offset: start,
                what: "number out of range",
            })
        }
    }

    fn hex4(&mut self) -> Result<u32, ParseError> {
        let Some(chunk) = self.s.get(self.i..self.i + 4) else {
            return self.err("short \\u escape");
        };
        let mut v = 0u32;
        for &c in chunk {
            let d = match c {
                b'0'..=b'9' => c - b'0',
                b'a'..=b'f' => c - b'a' + 10,
                b'A'..=b'F' => c - b'A' + 10,
                _ => return self.err("bad \\u escape"),
            };
            v = v * 16 + u32::from(d);
        }
        self.i += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, ParseError> {
        self.i += 1; // opening quote
        let mut out: Vec<u8> = Vec::new();
        loop {
            let Some(c) = self.peek() else {
                return self.err("unterminated string");
            };
            match c {
                b'"' => {
                    self.i += 1;
                    break;
                }
                b'\\' => {
                    self.i += 1;
                    let Some(e) = self.peek() else {
                        return self.err("unterminated escape");
                    };
                    self.i += 1;
                    match e {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'b' => out.push(0x08),
                        b'f' => out.push(0x0c),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let code = if (0xD800..0xDC00).contains(&hi) {
                                if !self.eat(b"\\u") {
                                    return self.err("lone surrogate");
                                }
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return self.err("lone surrogate");
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else if (0xDC00..0xE000).contains(&hi) {
                                return self.err("lone surrogate");
                            } else {
                                hi
                            };
                            let ch = char::from_u32(code).expect("valid scalar value");
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        _ => return self.err("bad escape"),
                    }
                }
                0x00..=0x1f => return self.err("control character in a string"),
                _ => {
                    out.push(c);
                    self.i += 1;
                }
            }
        }
        String::from_utf8(out).map_err(|_| ParseError {
            offset: self.i,
            what: "not UTF-8",
        })
    }
}

// ------------------------------------------------------------------------------ writing

/// Compact, like `serde_json::to_vec`.
pub fn to_vec(v: &Value) -> Vec<u8> {
    let mut s = String::new();
    write(&mut s, v, None, 0);
    s.into_bytes()
}

/// Two-space indent, like `serde_json::to_vec_pretty`.
pub fn to_vec_pretty(v: &Value) -> Vec<u8> {
    let mut s = String::new();
    write(&mut s, v, Some(2), 0);
    s.into_bytes()
}

fn newline(out: &mut String, indent: Option<usize>, level: usize) {
    if let Some(n) = indent {
        out.push('\n');
        for _ in 0..n * level {
            out.push(' ');
        }
    }
}

fn write(out: &mut String, v: &Value, indent: Option<usize>, level: usize) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Int(n) => {
            let _ = write!(out, "{n}");
        }
        Value::UInt(n) => {
            let _ = write!(out, "{n}");
        }
        Value::String(s) => write_str(out, s),
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                newline(out, indent, level + 1);
                write(out, item, indent, level + 1);
            }
            newline(out, indent, level);
            out.push(']');
        }
        Value::Object(fields) => {
            if fields.is_empty() {
                out.push_str("{}");
                return;
            }
            out.push('{');
            for (i, (k, item)) in fields.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                newline(out, indent, level + 1);
                write_str(out, k);
                out.push_str(if indent.is_some() { ": " } else { ":" });
                write(out, item, indent, level + 1);
            }
            newline(out, indent, level);
            out.push('}');
        }
    }
}

/// serde_json's escaping: `"` `\` and the control characters; the short forms where JSON
/// has one, `\u00XX` (lower-case hex) otherwise; everything else as UTF-8.
fn write_str(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

// ------------------------------------------------------------------------------ reading

/// Typed access to an object, for the readers of each file. A missing optional field is
/// `None`; a field of the wrong type is an error (`what` names it).
pub struct Fields<'a>(&'a [(String, Value)]);

impl<'a> Fields<'a> {
    pub fn of(v: &'a Value) -> Option<Self> {
        match v {
            Value::Object(f) => Some(Fields(f)),
            _ => None,
        }
    }

    pub fn get(&self, key: &str) -> Option<&'a Value> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    /// The field, or None when absent or null.
    fn present(&self, key: &str) -> Option<&'a Value> {
        self.get(key).filter(|v| **v != Value::Null)
    }

    pub fn str(&self, key: &str) -> Result<Option<&'a str>, &'static str> {
        match self.present(key) {
            None => Ok(None),
            Some(Value::String(s)) => Ok(Some(s)),
            Some(_) => Err("expected a string"),
        }
    }

    pub fn bool(&self, key: &str) -> Result<Option<bool>, &'static str> {
        match self.present(key) {
            None => Ok(None),
            Some(Value::Bool(b)) => Ok(Some(*b)),
            Some(_) => Err("expected true or false"),
        }
    }

    pub fn i64(&self, key: &str) -> Result<Option<i64>, &'static str> {
        match self.present(key) {
            None => Ok(None),
            Some(Value::Int(n)) => Ok(Some(*n)),
            Some(_) => Err("expected a whole number"),
        }
    }

    pub fn u64(&self, key: &str) -> Result<Option<u64>, &'static str> {
        match self.present(key) {
            None => Ok(None),
            Some(Value::Int(n)) => u64::try_from(*n).map(Some).map_err(|_| "negative number"),
            Some(Value::UInt(n)) => Ok(Some(*n)),
            Some(_) => Err("expected a whole number"),
        }
    }

    pub fn u32(&self, key: &str) -> Result<Option<u32>, &'static str> {
        match self.u64(key)? {
            None => Ok(None),
            Some(n) => u32::try_from(n)
                .map(Some)
                .map_err(|_| "number out of range"),
        }
    }

    pub fn strings(&self, key: &str) -> Result<Option<Vec<String>>, &'static str> {
        match self.present(key) {
            None => Ok(None),
            Some(Value::Array(items)) => items
                .iter()
                .map(|v| match v {
                    Value::String(s) => Ok(s.clone()),
                    _ => Err("expected a list of strings"),
                })
                .collect::<Result<Vec<_>, _>>()
                .map(Some),
            Some(_) => Err("expected a list"),
        }
    }

    pub fn object(&self, key: &str) -> Result<Option<Fields<'a>>, &'static str> {
        match self.present(key) {
            None => Ok(None),
            Some(v) => Fields::of(v).map(Some).ok_or("expected an object"),
        }
    }
}

/// Builds an object in the order fields are added, for the writers of each file.
#[derive(Default)]
pub struct Object(Vec<(String, Value)>);

impl Object {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn put(mut self, key: &str, v: Value) -> Self {
        self.0.push((key.to_string(), v));
        self
    }

    pub fn str(self, key: &str, s: &str) -> Self {
        self.put(key, Value::String(s.to_string()))
    }

    pub fn int(self, key: &str, n: i64) -> Self {
        self.put(key, Value::Int(n))
    }

    pub fn uint(self, key: &str, n: u64) -> Self {
        self.put(
            key,
            i64::try_from(n).map(Value::Int).unwrap_or(Value::UInt(n)),
        )
    }

    pub fn bool(self, key: &str, b: bool) -> Self {
        self.put(key, Value::Bool(b))
    }

    pub fn build(self) -> Value {
        Value::Object(self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Our reading and writing against serde_json's, on the shapes the vault files use.
    /// Keys are in alphabetical order here only because serde_json's `Value` sorts them;
    /// we keep the order written, as serde does for a struct.
    #[test]
    fn same_bytes_as_serde_json() {
        let docs = [
            r#"{"format":2,"kdf":{"m_kib":131072,"p":1,"t":3},"salt":"00ff","secret_key":"ab"}"#,
            r#"{"a":[],"b":{},"c":[1,-2,9223372036854775807,18446744073709551615],"d":null}"#,
            r#"{"f":false,"name":"Ảnh \"thẻ\" \\ / tab\t nl\n cr\r bs\u0008 ff\u000c nul\u0000 esc\u001b 😀","t":true}"#,
            r#"{"nested":{"deep":{"deeper":[{"k":"v"}]}},"tag_ids":["x","y"]}"#,
            r#"[]"#,
            r#""just a string""#,
            r#"-9223372036854775808"#,
        ];
        for doc in docs {
            let ours = parse(doc.as_bytes()).unwrap();
            let theirs: serde_json::Value = serde_json::from_str(doc).unwrap();
            assert_eq!(to_vec(&ours), serde_json::to_vec(&theirs).unwrap(), "{doc}");
            assert_eq!(
                to_vec_pretty(&ours),
                serde_json::to_vec_pretty(&theirs).unwrap(),
                "{doc}"
            );
            assert_eq!(parse(&to_vec(&ours)).unwrap(), ours);
        }
    }

    #[test]
    fn escapes_read_back() {
        let v = parse(br#""\u00e9\ud83d\ude00\/""#).unwrap();
        assert_eq!(v, Value::String("é😀/".into()));
    }

    #[test]
    fn refuses_what_rfc_8259_or_we_do_not_allow() {
        let bad: &[&[u8]] = &[
            b"",
            b"{",
            b"{\"a\":1,}",
            b"[1,]",
            b"{'a':1}",
            b"{\"a\":1} x",
            b"01",
            b"1.5",
            b"1e3",
            b"-",
            b"18446744073709551616",
            b"-9223372036854775809",
            b"\"\\ud800\"",
            b"\"\\udc00\"",
            b"\"\\ud800\\u0041\"",
            b"\"\\x\"",
            b"\"a\nb\"",
            b"\"\xff\"",
            b"{\"a\":1,\"a\":2}",
            b"tru",
            b"nul",
            b"// comment\n{}",
            b"NaN",
        ];
        for doc in bad {
            assert!(parse(doc).is_err(), "{:?}", String::from_utf8_lossy(doc));
        }
    }

    #[test]
    fn bounded() {
        let deep = "[".repeat(MAX_DEPTH + 2) + &"]".repeat(MAX_DEPTH + 2);
        assert!(parse(deep.as_bytes()).is_err());
        let ok = "[".repeat(MAX_DEPTH) + &"]".repeat(MAX_DEPTH);
        assert!(parse(ok.as_bytes()).is_ok());
        assert!(parse(&vec![b' '; MAX_LEN + 1]).is_err());
    }

    #[test]
    fn typed_fields() {
        let v =
            parse(br#"{"s":"x","n":-3,"u":5,"b":true,"l":["a"],"o":{"k":1},"z":null}"#).unwrap();
        let f = Fields::of(&v).unwrap();
        assert_eq!(f.str("s"), Ok(Some("x")));
        assert_eq!(f.i64("n"), Ok(Some(-3)));
        assert_eq!(f.u64("n"), Err("negative number"));
        assert_eq!(f.u32("u"), Ok(Some(5)));
        assert_eq!(f.bool("b"), Ok(Some(true)));
        assert_eq!(f.strings("l"), Ok(Some(vec!["a".to_string()])));
        assert_eq!(f.object("o").unwrap().unwrap().i64("k"), Ok(Some(1)));
        assert_eq!(f.str("z"), Ok(None));
        assert_eq!(f.str("missing"), Ok(None));
        assert_eq!(f.str("n"), Err("expected a string"));
    }

    /// Arbitrary bytes never panic (a header can come from a hostile copy).
    #[test]
    fn never_panics_on_noise() {
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
        let alphabet = b"{}[]\":,\\u0123456789abcdefABCDEF-+.eEtrufalsn \t\n\x00\xff\xc3\xa9";
        for len in 0..400 {
            let doc: Vec<u8> = (0..len % 64)
                .map(|_| {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    alphabet[(x % alphabet.len() as u64) as usize]
                })
                .collect();
            let _ = parse(&doc);
        }
    }
}
