//! The Secret Key as people read, write and type it (the Recovery Key).
//!
//! New keys (256 bits): 24 words from the BIP39 English list with its 8 checksum bits,
//! the form hardware wallets use, so a mistyped or swapped word is caught; any word can
//! be typed by its first four letters.
//!
//! Earlier `CS1-…` keys (128 bits, before 2026-10-21) are no longer read (owner
//! 2026-11-02: nobody uses them).

use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::{SecretKey, SECRET_KEY_LEN};

impl SecretKey {
    /// How people write it down: 24 BIP39 words (as hardware wallets do, 8 checksum
    /// bits).
    pub fn to_text(&self) -> Zeroizing<String> {
        bip39_words(self.as_bytes())
    }

    /// The 24 words back to the key; `None` for a typo (checksum) or an unknown word.
    pub fn from_text(text: &str) -> Option<SecretKey> {
        from_bip39(text)
    }
}

/// The BIP-0039 English list (github.com/bitcoin/bips, bip-0039/english.txt,
/// SHA-256 2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda).
const WORDS: &str = include_str!("bip39_english.txt");

fn words() -> Vec<&'static str> {
    WORDS.lines().collect()
}

/// The 2048 words a Recovery Key is made of, in order: the typing grid checks each word
/// as it is typed and completes it from its first four letters.
pub fn recovery_word_list() -> Vec<&'static str> {
    words()
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
    let typed: Vec<String> = text
        .split_whitespace()
        .map(|w| w.to_ascii_lowercase())
        .collect();
    if typed.len() != 24 {
        return None;
    }
    let mut bits = Zeroizing::new(Vec::with_capacity(264));
    for w in &typed {
        let idx = list.iter().position(|x| x == w).or_else(|| {
            list.iter()
                .position(|x| w.len() >= 4 && x.starts_with(w.as_str()))
        })?;
        for i in (0..11).rev() {
            bits.push(((idx >> i) & 1) as u8);
        }
    }
    let mut entropy = Zeroizing::new([0u8; SECRET_KEY_LEN]);
    for (i, byte) in entropy.iter_mut().enumerate() {
        *byte = bits[i * 8..i * 8 + 8]
            .iter()
            .fold(0u8, |a, &b| (a << 1) | b);
    }
    let sum = bits[256..264].iter().fold(0u8, |a, &b| (a << 1) | b);
    (Sha256::digest(&entropy[..])[0] == sum).then(|| SecretKey::from_bytes(*entropy))
}

#[cfg(test)]
mod tests {
    use super::*;

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
        // More reference vectors (256-bit entropy), including an irregular one.
        let k = SecretKey::from_bytes([0x80; SECRET_KEY_LEN]);
        assert_eq!(
            k.to_text().as_str(),
            "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
        );
        let k = SecretKey::from_bytes([0xff; SECRET_KEY_LEN]);
        assert_eq!(k.to_text().as_str(), "zoo ".repeat(23) + "vote");
        let hex = "68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c";
        let mut e = [0u8; SECRET_KEY_LEN];
        for (i, b) in e.iter_mut().enumerate() {
            *b = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap();
        }
        let k = SecretKey::from_bytes(e);
        assert_eq!(
            k.to_text().as_str(),
            "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length"
        );
        assert_eq!(SecretKey::from_text(&k.to_text()), Some(k));
    }

    /// The Secret Key comes from the OS generator, never from anything the app seeds
    /// (wallets were emptied when theirs came from a 32-bit seed: "Milk Sad", 2023). A
    /// sanity check only: no repeats, and about half the bits set.
    #[test]
    fn secret_keys_are_random() {
        let n = 2000;
        let keys: std::collections::HashSet<Vec<u8>> = (0..n)
            .map(|_| SecretKey::generate().as_bytes().to_vec())
            .collect();
        assert_eq!(keys.len(), n);
        let ones: u32 = keys.iter().flatten().map(|b| b.count_ones()).sum();
        let share = ones as f64 / (n * SECRET_KEY_LEN * 8) as f64;
        assert!((0.49..0.51).contains(&share), "{share}");
    }

    #[test]
    fn the_word_list_is_the_official_one() {
        use sha2::Digest;
        // SHA-256 of bitcoin/bips bip-0039/english.txt.
        let sum = sha2::Sha256::digest(WORDS.as_bytes());
        let sum: String = sum.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            sum,
            "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"
        );
        assert_eq!(words().len(), 2048);
    }

    #[test]
    fn the_word_list_is_2048_words_known_by_four_letters() {
        let list = recovery_word_list();
        assert_eq!(list.len(), 2048);
        let mut heads: Vec<String> = list.iter().map(|w| w.chars().take(4).collect()).collect();
        heads.sort();
        heads.dedup();
        assert_eq!(heads.len(), 2048);
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
    fn earlier_cs1_keys_and_128_bit_keys_are_refused() {
        assert!(SecretKey::from_text("CS1-0B8N-4RAS-N5C3-MF2V-8VNB-8EEA-R6DV").is_none());
        assert!(SecretKey::from_slice(&[7u8; 16]).is_none());
    }
}
