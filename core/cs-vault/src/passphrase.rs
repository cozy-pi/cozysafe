//! "Suggest a password": words picked by the OS CSPRNG from the EFF large wordlist
//! (7,776 words, CC BY 3.0 US, Electronic Frontier Foundation,
//! https://www.eff.org/dice). Five words carry 5 × log2(7776) ≈ 64.6 bits, so with the
//! Argon2id cost even a large GPU farm needs on the order of a million years.

use cs_crypto::rand_u32;

const WORDS: &str = include_str!("eff_large_wordlist.txt");

/// Words in a suggestion.
pub const SUGGESTED_WORDS: usize = 5;

fn words() -> Vec<&'static str> {
    WORDS
        .lines()
        .map(str::trim)
        .filter(|w| !w.is_empty())
        .collect()
}

/// A random passphrase of `n` words separated by spaces.
pub fn suggest(n: usize) -> String {
    let list = words();
    // Rejection sampling: no modulo bias.
    let bound = u32::MAX - u32::MAX % list.len() as u32;
    (0..n)
        .map(|_| loop {
            let r = rand_u32();
            if r < bound {
                break list[(r % list.len() as u32) as usize];
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_is_the_full_eff_list() {
        let w = words();
        assert_eq!(w.len(), 7776);
        assert_eq!(
            w.iter().collect::<std::collections::HashSet<_>>().len(),
            7776
        );
    }

    #[test]
    fn suggestions_are_strong_and_vary() {
        let a = suggest(SUGGESTED_WORDS);
        let b = suggest(SUGGESTED_WORDS);
        assert_eq!(a.split(' ').count(), 5);
        assert_ne!(a, b);
        assert!(crate::password_score(&a) >= crate::MIN_PASSWORD_SCORE);
    }
}
