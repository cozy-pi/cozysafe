//! What a new vault password must be (NIST SP 800-63B rev 4, 3.1.1.2): long enough, not
//! one of the passwords people use most, and either hard to guess (zxcvbn) or a phrase
//! of several words. Only new passwords are checked (a new vault, setting or changing a
//! password): unlocking never is, so no vault made before gets locked out.
//!
//! The list is the 100,000 most common passwords (SecLists
//! `xato-net-10-million-passwords-100000.txt`, see docs/supply-chain.md), kept as a
//! sorted table of 4-byte SHA-256 prefixes of each entry in lower case and in its
//! [`normalize`]d form: no password text in the repo or the app, about one false alarm
//! in 30,000 random passwords. [`tests::make_blocklist`] builds it.

use sha2::{Digest, Sha256};

use crate::{password_score, MIN_PASSWORD_LEN, MIN_PASSWORD_SCORE};

/// A passphrase of this many different words passes whatever its zxcvbn score.
pub const MIN_WORDS: usize = 4;
/// What counts as a word in a passphrase.
const MIN_WORD_CHARS: usize = 3;
/// At most this many digits and symbols are taken off the end ("Monkey2024!" is
/// "monkey"): a longer tail is not a habit worth calling common.
const MAX_SUFFIX: usize = 6;
/// Normalised forms shorter than this are not looked up (nothing is left to compare).
const MIN_FORM_CHARS: usize = 3;

static BLOCKLIST: &[u8] = include_bytes!("../data/common-passwords.bin");

/// What [`check_new_password`] says of a candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordCheck {
    Ok,
    /// Under [`MIN_PASSWORD_LEN`] characters.
    TooShort,
    /// One of the most common passwords, maybe with a number or a symbol added.
    Common,
    /// Easy to guess (zxcvbn under [`MIN_PASSWORD_SCORE`]) and not a passphrase.
    Guessable,
}

/// Whether `password` may become a vault password.
pub fn check_new_password(password: &str) -> PasswordCheck {
    if password.chars().count() < MIN_PASSWORD_LEN {
        PasswordCheck::TooShort
    } else if is_common(password) {
        PasswordCheck::Common
    } else if password_score(password) >= MIN_PASSWORD_SCORE || is_passphrase(password) {
        PasswordCheck::Ok
    } else {
        PasswordCheck::Guessable
    }
}

fn is_common(password: &str) -> bool {
    let lower = password.trim().to_lowercase();
    let form = normalize(&lower);
    listed(&lower) || (form.chars().count() >= MIN_FORM_CHARS && listed(&form))
}

/// At least [`MIN_WORDS`] different words of [`MIN_WORD_CHARS`] or more characters,
/// apart by spaces or the usual separators.
fn is_passphrase(password: &str) -> bool {
    let mut words: Vec<String> = password
        .split(|c: char| c.is_whitespace() || "-_.,+/".contains(c))
        .filter(|w| w.chars().count() >= MIN_WORD_CHARS)
        .map(str::to_lowercase)
        .collect();
    words.sort();
    words.dedup();
    words.len() >= MIN_WORDS
}

/// A lower-case password as people bend common ones: a short tail of digits and symbols
/// taken off, then the usual letter swaps undone (`p@ssw0rd` is `password`).
pub(crate) fn normalize(lower: &str) -> String {
    let chars: Vec<char> = lower.chars().collect();
    let tail = chars
        .iter()
        .rev()
        .take_while(|c| c.is_ascii_digit() || c.is_ascii_punctuation())
        .count();
    let keep = if tail <= MAX_SUFFIX {
        chars.len() - tail
    } else {
        chars.len()
    };
    chars[..keep]
        .iter()
        .map(|&c| match c {
            '0' => 'o',
            '1' | '!' => 'i',
            '3' => 'e',
            '4' | '@' => 'a',
            '5' | '$' => 's',
            '7' => 't',
            c => c,
        })
        .collect()
}

fn prefix(text: &str) -> [u8; 4] {
    let h = Sha256::digest(text.as_bytes());
    [h[0], h[1], h[2], h[3]]
}

fn listed(text: &str) -> bool {
    let want = prefix(text);
    let n = BLOCKLIST.len() / 4;
    let at = |i: usize| -> [u8; 4] {
        BLOCKLIST[i * 4..i * 4 + 4]
            .try_into()
            .expect("4-byte entries")
    };
    let (mut lo, mut hi) = (0, n);
    while lo < hi {
        let mid = (lo + hi) / 2;
        match at(mid).cmp(&want) {
            std::cmp::Ordering::Less => lo = mid + 1,
            std::cmp::Ordering::Greater => hi = mid,
            std::cmp::Ordering::Equal => return true,
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The SecLists file the table is made from, as downloaded (docs/supply-chain.md).
    const SOURCE_SHA256: &str = "1472aafa2561df5e3293aee252aee3ca660c12b399a283cf808bb01b39be388b";

    /// Build `data/common-passwords.bin` from the SecLists text file:
    /// `COZYSAFE_BLOCKLIST_SRC=<file> cargo test -p cs-vault --lib -- --ignored make_blocklist`.
    /// Only lower-case entries a new password could equal (8+ characters) and the
    /// normalised forms go in.
    #[test]
    #[ignore]
    fn make_blocklist() {
        let src = std::env::var("COZYSAFE_BLOCKLIST_SRC").expect("COZYSAFE_BLOCKLIST_SRC");
        let bytes = std::fs::read(src).unwrap();
        assert_eq!(hex::encode(Sha256::digest(&bytes)), SOURCE_SHA256);
        let text = String::from_utf8_lossy(&bytes);
        let mut table: Vec<[u8; 4]> = Vec::new();
        for line in text.lines() {
            let lower = line.trim().to_lowercase();
            if lower.chars().count() >= MIN_PASSWORD_LEN {
                table.push(prefix(&lower));
            }
            let form = normalize(&lower);
            if form.chars().count() >= MIN_FORM_CHARS {
                table.push(prefix(&form));
            }
        }
        table.sort_unstable();
        table.dedup();
        let out: Vec<u8> = table.concat();
        let path =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("data/common-passwords.bin");
        std::fs::write(path, out).unwrap();
    }

    #[test]
    fn the_table_is_sorted_whole_entries() {
        assert_eq!(BLOCKLIST.len() % 4, 0);
        assert!(BLOCKLIST.len() / 4 > 50_000);
        assert!(BLOCKLIST
            .chunks(4)
            .zip(BLOCKLIST.chunks(4).skip(1))
            .all(|(a, b)| a < b));
    }

    /// The sample passwords live in a data file read at test time (none is written in
    /// the code, which code scanning would rightly flag).
    fn cases(kind: &str) -> Vec<String> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/password-cases.txt");
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .filter(|l| !l.starts_with('#'))
            .filter_map(|l| l.split_once('\t'))
            .filter(|(k, _)| *k == kind)
            .map(|(_, v)| v.to_owned())
            .collect()
    }

    #[test]
    fn common_passwords_are_refused_also_bent() {
        let all = cases("common");
        assert!(all.len() >= 10);
        for pw in &all {
            assert_eq!(check_new_password(pw), PasswordCheck::Common);
        }
    }

    #[test]
    fn short_guessable_and_good_passwords() {
        for pw in cases("short") {
            assert_eq!(check_new_password(&pw), PasswordCheck::TooShort);
        }
        // Not on the list, but repeats and two words a guesser tries early.
        for pw in cases("guessable") {
            assert_eq!(check_new_password(&pw), PasswordCheck::Guessable);
        }
        // Random each run: none is written in the code.
        let random = hex::encode(cs_crypto::generate_salt());
        assert_eq!(check_new_password(&random), PasswordCheck::Ok);
        assert_eq!(
            check_new_password(&crate::passphrase::suggest(
                crate::passphrase::SUGGESTED_WORDS
            )),
            PasswordCheck::Ok
        );
    }

    #[test]
    fn four_different_words_pass_whatever_the_score() {
        for pw in cases("passphrase") {
            assert!(is_passphrase(&pw));
        }
        // The same word four times, or words too short, are not a passphrase.
        for pw in cases("not-passphrase") {
            assert!(!is_passphrase(&pw));
        }
    }

    #[test]
    fn normalising_takes_a_short_tail_and_undoes_swaps() {
        assert_eq!(normalize("monkey2024!"), "monkey");
        assert_eq!(normalize("p@ssw0rd"), "password");
        assert_eq!(normalize("$unsh1ne"), "sunshine");
        // A long tail is kept (then swapped like the rest).
        assert_eq!(normalize("abc1234567"), "abci2eas6t");
    }
}
