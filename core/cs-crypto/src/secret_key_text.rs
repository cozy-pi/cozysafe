//! The Secret Key as people read, write and type it (the Recovery Key).
//!
//! New keys (256 bits): 24 words from the BIP39 English list with its 8 checksum bits,
//! the form hardware wallets use, so a mistyped or swapped word is caught; any word can
//! be typed by its first four letters.
//!
//! Earlier keys (128 bits, before 2026-10-21):
//! `CS1-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`: 26 Crockford base32 characters for the
//! 128 bits plus 2 check characters, in groups of four. Crockford's alphabet has no
//! I, L, O or U, and parsing maps them to 1, 1, 0 and nothing ambiguous, ignores case,
//! spaces and dashes, so a key copied by hand still reads back. The check characters
//! catch a mistyped or swapped character before anything tries to unlock with it.

use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::{SecretKey, LEGACY_SECRET_KEY_LEN, SECRET_KEY_LEN};

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const PREFIX: &str = "CS1";
const DATA_CHARS: usize = 26; // ceil(128 / 5)
const CHECK_CHARS: usize = 2;

impl SecretKey {
    /// How people write it down: 24 BIP39 words for a 256-bit key (as hardware wallets
    /// do, 8 checksum bits), `CS1-XXXX-…` for an earlier 128-bit key.
    pub fn to_text(&self) -> Zeroizing<String> {
        if !self.is_legacy() {
            return bip39_words(self.as_bytes());
        }
        let bytes: [u8; LEGACY_SECRET_KEY_LEN] = self.as_bytes().try_into().expect("legacy length");
        let mut chars = Zeroizing::new(encode(&bytes));
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

    /// Either form back to the key; `None` for a typo (checksum) or an unknown word.
    pub fn from_text(text: &str) -> Option<SecretKey> {
        if text.chars().any(|c| c.is_ascii_lowercase() || c.is_ascii_uppercase())
            && text.split_whitespace().count() >= 12
        {
            return from_bip39(text);
        }
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
        decode(data).and_then(|b| SecretKey::from_slice(&b))
    }
}

/// The BIP-0039 English list (github.com/bitcoin/bips, bip-0039/english.txt,
/// SHA-256 2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda).
const WORDS: &str = include_str!("bip39_english.txt");

fn words() -> Vec<&'static str> {
    WORDS.lines().collect()
}

/// 256 bits + the first 8 bits of their SHA-256 = 264 bits = 24 words of 11 bits.
fn bip39_words(entropy: &[u8]) -> Zeroizing<String> {
    let list = words();
    let sum = Sha256::digest(entropy)[0];
    let mut bits = Zeroizing::new(Vec::with_capacity(264));
    for &b in entropy.iter().chain(std::iter::once(&sum)) {
        for i in (0..8).rev() {
            bits.push((b >> i) & 1);
        }
    }
    let mut out = Zeroizing::new(String::new());
    for (n, chunk) in bits.chunks(11).take(24).enumerate() {
        let idx = chunk.iter().fold(0usize, |a, &b| (a << 1) | b as usize);
        if n > 0 {
            out.push(' ');
        }
        out.push_str(list[idx]);
    }
    out
}

/// 24 words back to the key. Case, extra spaces and line breaks do not matter; every
/// BIP39 word is known by its first four letters, so those are enough.
fn from_bip39(text: &str) -> Option<SecretKey> {
    let list = words();
    let typed: Vec<String> = text.split_whitespace().map(|w| w.to_ascii_lowercase()).collect();
    if typed.len() != 24 {
        return None;
    }
    let mut bits = Zeroizing::new(Vec::with_capacity(264));
    for w in &typed {
        let idx = list
            .iter()
            .position(|x| x == w)
            .or_else(|| list.iter().position(|x| w.len() >= 4 && x.starts_with(w.as_str())))?;
        for i in (0..11).rev() {
            bits.push(((idx >> i) & 1) as u8);
        }
    }
    let mut entropy = Zeroizing::new([0u8; SECRET_KEY_LEN]);
    for (i, byte) in entropy.iter_mut().enumerate() {
        *byte = bits[i * 8..i * 8 + 8].iter().fold(0u8, |a, &b| (a << 1) | b);
    }
    let sum = bits[256..264].iter().fold(0u8, |a, &b| (a << 1) | b);
    (Sha256::digest(&entropy[..])[0] == sum).then(|| SecretKey::from_bytes(*entropy))
}

fn encode(bytes: &[u8; LEGACY_SECRET_KEY_LEN]) -> String {
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

fn decode(chars: &str) -> Option<[u8; LEGACY_SECRET_KEY_LEN]> {
    let mut out = [0u8; LEGACY_SECRET_KEY_LEN];
    let (mut acc, mut bits, mut n) = (0u32, 0u32, 0usize);
    for c in chars.bytes() {
        let v = ALPHABET.iter().position(|&a| a == c)? as u32;
        acc = (acc << 5) | v;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            if n == LEGACY_SECRET_KEY_LEN {
                return None;
            }
            out[n] = (acc >> bits) as u8;
            n += 1;
        }
        acc &= (1 << bits) - 1;
    }
    // 26 × 5 = 130 bits: the last 2 padding bits must be zero.
    (n == LEGACY_SECRET_KEY_LEN && acc == 0).then_some(out)
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

    fn legacy() -> SecretKey {
        let mut b = [0u8; LEGACY_SECRET_KEY_LEN];
        for (i, x) in b.iter_mut().enumerate() {
            *x = (i * 37 + 11) as u8;
        }
        SecretKey::from_slice(&b).unwrap()
    }

    #[test]
    fn new_keys_are_24_bip39_words() {
        for _ in 0..200 {
            let k = SecretKey::generate();
            let t = k.to_text();
            assert_eq!(t.split(' ').count(), 24);
            assert_eq!(SecretKey::from_text(&t).unwrap(), k);
        }
    }

    #[test]
    fn bip39_test_vector() {
        // From the BIP39 reference vectors: 32 zero bytes.
        let k = SecretKey::from_bytes([0u8; SECRET_KEY_LEN]);
        let want = "abandon ".repeat(23) + "art";
        assert_eq!(k.to_text().as_str(), want);
        // 32 bytes of 0x7f.
        let k = SecretKey::from_bytes([0x7f; SECRET_KEY_LEN]);
        assert_eq!(
            k.to_text().as_str(),
            "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
        );
    }

    #[test]
    fn words_are_forgiving_about_case_spacing_and_four_letters() {
        let k = SecretKey::generate();
        let t = k.to_text();
        let messy = t.to_uppercase().replace(' ', "\n  ");
        assert_eq!(SecretKey::from_text(&messy).unwrap(), k);
        let short: Vec<String> = t.split(' ').map(|w| w.chars().take(4).collect()).collect();
        assert_eq!(SecretKey::from_text(&short.join(" ")).unwrap(), k);
    }

    #[test]
    fn a_wrong_or_swapped_word_is_caught() {
        let k = SecretKey::generate();
        let t = k.to_text().to_string();
        let mut w: Vec<&str> = t.split(' ').collect();
        w.swap(0, 1);
        if w[0] != w[1] {
            assert!(SecretKey::from_text(&w.join(" ")).is_none_or(|x| x != k));
        }
        let mut w: Vec<&str> = t.split(' ').collect();
        w[5] = if w[5] == "zoo" { "abandon" } else { "zoo" };
        assert!(SecretKey::from_text(&w.join(" ")).is_none_or(|x| x != k));
        assert!(SecretKey::from_text(&"notaword ".repeat(24)).is_none());
    }

    #[test]
    fn legacy_keys_still_read_and_print() {
        let k = legacy();
        let t = k.to_text();
        assert!(t.starts_with("CS1-"));
        assert_eq!(t.len(), 3 + 7 * 5);
        assert_eq!(SecretKey::from_text(&t).unwrap(), k);
        let loose = t.to_lowercase().replace('-', " ").replace('0', "o");
        assert_eq!(SecretKey::from_text(&loose).unwrap(), k);
        let bare = t.trim_start_matches("CS1-").to_string();
        assert_eq!(SecretKey::from_text(&bare).unwrap(), k);
    }

    #[test]
    fn legacy_typos_are_caught() {
        let t = legacy().to_text().to_string();
        let mut c: Vec<char> = t.chars().collect();
        c[6] = if c[6] == 'A' { 'B' } else { 'A' };
        assert!(SecretKey::from_text(&c.iter().collect::<String>()).is_none_or(|x| x != legacy()));
    }
}
