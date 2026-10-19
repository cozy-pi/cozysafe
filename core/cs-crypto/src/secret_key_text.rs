//! The Secret Key as people read, write and type it (Emergency Kit).
//!
//! `CS1-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`: 26 Crockford base32 characters for the
//! 128 bits plus 2 check characters, in groups of four. Crockford's alphabet has no
//! I, L, O or U, and parsing maps them to 1, 1, 0 and nothing ambiguous, ignores case,
//! spaces and dashes, so a key copied by hand still reads back. The check characters
//! catch a mistyped or swapped character before anything tries to unlock with it.

use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::{SecretKey, SECRET_KEY_LEN};

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const PREFIX: &str = "CS1";
const DATA_CHARS: usize = 26; // ceil(128 / 5)
const CHECK_CHARS: usize = 2;

impl SecretKey {
    /// Human-readable form for the Emergency Kit.
    pub fn to_text(&self) -> Zeroizing<String> {
        let mut chars = Zeroizing::new(encode(self.as_bytes()));
        let sum = check(chars.as_str());
        chars.push_str(&sum);
        let mut out = Zeroizing::new(String::from(PREFIX));
        for (i, c) in chars.chars().enumerate() {
            if i % 4 == 0 {
                out.push('-');
            }
            out.push(c);
        }
        out
    }

    /// Read a key typed or pasted by a person. `None` if it is not a valid key.
    pub fn from_text(text: &str) -> Option<SecretKey> {
        let mut norm = Zeroizing::new(String::new());
        for c in text.chars() {
            match c.to_ascii_uppercase() {
                ' ' | '-' | '\t' | '\n' => {}
                'I' | 'L' => norm.push('1'),
                'O' => norm.push('0'),
                c if ALPHABET.contains(&(c as u8)) && c.is_ascii() => norm.push(c),
                _ => return None,
            }
        }
        let body = norm.strip_prefix(PREFIX).unwrap_or(&norm);
        if body.len() != DATA_CHARS + CHECK_CHARS {
            return None;
        }
        let (data, sum) = body.split_at(DATA_CHARS);
        if check(data) != sum {
            return None;
        }
        decode(data).map(SecretKey::from_bytes)
    }
}

fn encode(bytes: &[u8; SECRET_KEY_LEN]) -> String {
    let mut out = String::with_capacity(DATA_CHARS);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &b in bytes {
        acc = (acc << 8) | b as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(ALPHABET[((acc >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        out.push(ALPHABET[((acc << (5 - bits)) & 31) as usize] as char);
    }
    out
}

fn decode(chars: &str) -> Option<[u8; SECRET_KEY_LEN]> {
    let mut out = [0u8; SECRET_KEY_LEN];
    let (mut acc, mut bits, mut n) = (0u32, 0u32, 0usize);
    for c in chars.bytes() {
        let v = ALPHABET.iter().position(|&a| a == c)? as u32;
        acc = (acc << 5) | v;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            if n == SECRET_KEY_LEN {
                return None;
            }
            out[n] = (acc >> bits) as u8;
            n += 1;
        }
        acc &= (1 << bits) - 1;
    }
    // 26 × 5 = 130 bits: the last 2 padding bits must be zero.
    (n == SECRET_KEY_LEN && acc == 0).then_some(out)
}

fn check(data: &str) -> String {
    let h = Sha256::digest(data.as_bytes());
    let v = ((h[0] as u16) << 8 | h[1] as u16) >> 6; // 10 bits
    [
        ALPHABET[(v >> 5) as usize] as char,
        ALPHABET[(v & 31) as usize] as char,
    ]
    .iter()
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_format() {
        for _ in 0..200 {
            let k = SecretKey::generate();
            let t = k.to_text();
            assert!(t.starts_with("CS1-"));
            assert_eq!(t.len(), 3 + 7 * 5); // CS1 + 7 × "-XXXX"
            assert_eq!(SecretKey::from_text(&t).unwrap(), k);
        }
    }

    #[test]
    fn forgiving_about_case_spaces_and_lookalikes() {
        let k = SecretKey::from_bytes([0u8; 16]);
        let t = k
            .to_text()
            .to_lowercase()
            .replace('-', " ")
            .replace('0', "o");
        assert_eq!(SecretKey::from_text(&t).unwrap(), k);
        // Without the prefix too.
        let bare = k.to_text().trim_start_matches("CS1-").to_string();
        assert_eq!(SecretKey::from_text(&bare).unwrap(), k);
    }

    #[test]
    fn typos_are_caught() {
        let k = SecretKey::generate();
        let t = k.to_text().to_string();
        let mut caught = 0;
        for i in 4..t.len() {
            if t.as_bytes()[i] == b'-' {
                continue;
            }
            let mut b = t.clone().into_bytes();
            b[i] = if b[i] == b'7' { b'8' } else { b'7' };
            if SecretKey::from_text(std::str::from_utf8(&b).unwrap()).is_none() {
                caught += 1;
            }
        }
        // 10 check bits: nearly every single-character typo is rejected.
        assert!(caught >= 26, "{caught}");
        assert!(SecretKey::from_text("CS1-ABCD").is_none());
        assert!(SecretKey::from_text("hello world").is_none());
    }
}
