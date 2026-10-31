//! Lower-case hex, as the vault files write salts, keys and hashes (in place of the
//! `hex` crate).

const DIGITS: &[u8; 16] = b"0123456789abcdef";

pub fn encode(bytes: impl AsRef<[u8]>) -> String {
    let bytes = bytes.as_ref();
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(DIGITS[usize::from(b >> 4)] as char);
        s.push(DIGITS[usize::from(b & 0x0f)] as char);
    }
    s
}

/// Upper- or lower-case; `None` for an odd length or any other character.
pub fn decode(text: impl AsRef<[u8]>) -> Option<Vec<u8>> {
    let t = text.as_ref();
    if t.len() % 2 != 0 {
        return None;
    }
    fn nibble(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    }
    t.chunks(2)
        .map(|p| Some(nibble(p[0])? << 4 | nibble(p[1])?))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_refusals() {
        let all: Vec<u8> = (0..=255).collect();
        let text = encode(&all);
        assert_eq!(&text[..8], "00010203");
        assert_eq!(&text[text.len() - 4..], "feff");
        assert_eq!(decode(&text).unwrap(), all);
        assert_eq!(decode("ABcd").unwrap(), vec![0xab, 0xcd]);
        assert_eq!(decode(""), Some(vec![]));
        assert_eq!(decode("abc"), None);
        assert_eq!(decode("zz"), None);
        assert_eq!(decode("0x"), None);
        assert_eq!(decode("é1"), None);
    }
}
