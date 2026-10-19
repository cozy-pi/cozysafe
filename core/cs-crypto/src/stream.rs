//! Chunked STREAM encryption (Hoang, Reyhanitabar, Rogaway, Vizár) for files of any
//! size in constant memory.
//!
//! Layout: `version (1) ‖ nonce prefix (19) ‖ chunk₀ ‖ chunk₁ ‖ … ‖ chunkₙ`, every chunk
//! `CHUNK_LEN` plaintext bytes + 16-byte tag, the last one shorter and flagged as last.
//! A big-endian 32-bit counter and the last-chunk flag sit in each nonce, so chunks
//! cannot be reordered, dropped, duplicated or the stream truncated. The caller's
//! associated data (vault ID, object ID) goes into every chunk, so chunks cannot be
//! moved between objects either.

use std::io::{Read, Write};

use chacha20poly1305::aead::generic_array::GenericArray;
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::stream::{DecryptorBE32, EncryptorBE32};
use chacha20poly1305::aead::{KeyInit, OsRng, Payload};
use chacha20poly1305::XChaCha20Poly1305;

use crate::{Error, Key, Result};

/// Plaintext bytes per chunk.
pub const CHUNK_LEN: usize = 64 * 1024;
const TAG_LEN: usize = 16;
const VERSION: u8 = 1;
const PREFIX_LEN: usize = 19;
/// Bytes before the first chunk.
pub const HEADER_LEN: usize = 1 + PREFIX_LEN;

/// Ciphertext length for a plaintext of `len` bytes.
pub fn ciphertext_len(len: u64) -> u64 {
    // Every chunk is full except the last; an empty plaintext still has one (empty) chunk.
    let chunks = len.div_ceil(CHUNK_LEN as u64).max(1);
    HEADER_LEN as u64 + len + chunks * TAG_LEN as u64
}

/// Encrypt everything from `reader` into `writer`. Returns plaintext bytes processed.
pub fn encrypt<R: Read, W: Write>(
    key: &Key,
    aad: &[u8],
    mut reader: R,
    mut writer: W,
) -> Result<u64> {
    let mut prefix = [0u8; PREFIX_LEN];
    OsRng.fill_bytes(&mut prefix);
    writer.write_all(&[VERSION])?;
    writer.write_all(&prefix)?;

    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    let mut enc = EncryptorBE32::from_aead(cipher, GenericArray::from_slice(&prefix));
    let aad = with_version(aad);

    let mut cur = vec![0u8; CHUNK_LEN];
    let mut next = vec![0u8; CHUNK_LEN];
    let mut cur_len = read_full(&mut reader, &mut cur)?;
    let mut total = 0u64;
    loop {
        // Look one chunk ahead: the only way to know whether `cur` is the last one.
        let next_len = if cur_len == CHUNK_LEN {
            read_full(&mut reader, &mut next)?
        } else {
            0
        };
        total += cur_len as u64;
        if next_len == 0 {
            let ct = enc
                .encrypt_last(Payload {
                    msg: &cur[..cur_len],
                    aad: &aad,
                })
                .map_err(|_| Error::Format("chunk encryption failed"))?;
            writer.write_all(&ct)?;
            break;
        }
        let ct = enc
            .encrypt_next(Payload {
                msg: &cur[..cur_len],
                aad: &aad,
            })
            .map_err(|_| Error::Format("too many chunks"))?;
        writer.write_all(&ct)?;
        std::mem::swap(&mut cur, &mut next);
        cur_len = next_len;
    }
    wipe(&mut cur);
    wipe(&mut next);
    writer.flush()?;
    Ok(total)
}

/// Decrypt a stream produced by [`encrypt`]. Plaintext of a chunk is written only after
/// that chunk authenticates; on error, the caller must discard what was written.
pub fn decrypt<R: Read, W: Write>(
    key: &Key,
    aad: &[u8],
    mut reader: R,
    mut writer: W,
) -> Result<u64> {
    let mut header = [0u8; HEADER_LEN];
    if read_full(&mut reader, &mut header)? != HEADER_LEN {
        return Err(Error::Format("stream header truncated"));
    }
    if header[0] != VERSION {
        return Err(Error::Version(header[0]));
    }

    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    let mut dec = DecryptorBE32::from_aead(cipher, GenericArray::from_slice(&header[1..]));
    let aad = with_version(aad);

    const CT_CHUNK: usize = CHUNK_LEN + TAG_LEN;
    let mut cur = vec![0u8; CT_CHUNK];
    let mut next = vec![0u8; CT_CHUNK];
    let mut cur_len = read_full(&mut reader, &mut cur)?;
    let mut total = 0u64;
    loop {
        if cur_len < TAG_LEN {
            return Err(Error::Decrypt);
        }
        let next_len = if cur_len == CT_CHUNK {
            read_full(&mut reader, &mut next)?
        } else {
            0
        };
        if next_len == 0 {
            let pt = dec
                .decrypt_last(Payload {
                    msg: &cur[..cur_len],
                    aad: &aad,
                })
                .map_err(|_| Error::Decrypt)?;
            writer.write_all(&pt)?;
            total += pt.len() as u64;
            let mut pt = pt;
            wipe(&mut pt);
            break;
        }
        let mut pt = dec
            .decrypt_next(Payload {
                msg: &cur[..cur_len],
                aad: &aad,
            })
            .map_err(|_| Error::Decrypt)?;
        writer.write_all(&pt)?;
        total += pt.len() as u64;
        wipe(&mut pt);
        std::mem::swap(&mut cur, &mut next);
        cur_len = next_len;
    }
    writer.flush()?;
    Ok(total)
}

/// Fill `buf` as far as the reader allows; returns bytes read (short only at EOF).
fn read_full<R: Read>(reader: &mut R, buf: &mut [u8]) -> Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match reader.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(n)
}

fn with_version(aad: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + aad.len());
    v.push(VERSION);
    v.extend_from_slice(aad);
    v
}

fn wipe(buf: &mut Vec<u8>) {
    use zeroize::Zeroize;
    buf.zeroize();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 31 % 251) as u8).collect()
    }

    fn enc(key: &Key, aad: &[u8], pt: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        encrypt(key, aad, pt, &mut out).unwrap();
        out
    }

    fn dec(key: &Key, aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        decrypt(key, aad, ct, &mut out)?;
        Ok(out)
    }

    #[test]
    fn roundtrip_at_chunk_boundaries() {
        let k = Key::generate();
        for len in [
            0,
            1,
            CHUNK_LEN - 1,
            CHUNK_LEN,
            CHUNK_LEN + 1,
            2 * CHUNK_LEN,
            3 * CHUNK_LEN + 7,
        ] {
            let pt = data(len);
            let ct = enc(&k, b"obj", &pt);
            assert_eq!(
                ct.len() as u64,
                ciphertext_len(len as u64),
                "length formula, len {len}"
            );
            assert_eq!(dec(&k, b"obj", &ct).unwrap(), pt, "roundtrip, len {len}");
        }
    }

    #[test]
    fn truncation_is_detected() {
        let k = Key::generate();
        let ct = enc(&k, b"obj", &data(3 * CHUNK_LEN + 7));
        // Drop the final short chunk: the stream now ends on a non-last chunk.
        let cut = HEADER_LEN + 3 * (CHUNK_LEN + TAG_LEN);
        assert!(dec(&k, b"obj", &ct[..cut]).is_err());
        assert!(dec(&k, b"obj", &ct[..ct.len() - 1]).is_err());
        assert!(dec(&k, b"obj", &ct[..HEADER_LEN]).is_err());
    }

    #[test]
    fn reordering_is_detected() {
        let k = Key::generate();
        let ct = enc(&k, b"obj", &data(3 * CHUNK_LEN));
        let c = CHUNK_LEN + TAG_LEN;
        let mut swapped = ct.clone();
        swapped[HEADER_LEN..HEADER_LEN + c]
            .copy_from_slice(&ct[HEADER_LEN + c..HEADER_LEN + 2 * c]);
        swapped[HEADER_LEN + c..HEADER_LEN + 2 * c]
            .copy_from_slice(&ct[HEADER_LEN..HEADER_LEN + c]);
        assert!(dec(&k, b"obj", &swapped).is_err());
    }

    #[test]
    fn wrong_key_aad_and_bit_flips_fail() {
        let k = Key::generate();
        let ct = enc(&k, b"obj-1", &data(CHUNK_LEN + 5));
        assert!(dec(&Key::generate(), b"obj-1", &ct).is_err());
        assert!(dec(&k, b"obj-2", &ct).is_err());
        for i in [0, 5, HEADER_LEN, HEADER_LEN + 100, ct.len() - 1] {
            let mut bad = ct.clone();
            bad[i] ^= 1;
            assert!(
                dec(&k, b"obj-1", &bad).is_err(),
                "flip at byte {i} went unnoticed"
            );
        }
    }

    /// Reader that hands out one byte at a time, as slow pipes and sockets do.
    struct Trickle<'a>(&'a [u8]);
    impl Read for Trickle<'_> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.0.is_empty() || buf.is_empty() {
                return Ok(0);
            }
            buf[0] = self.0[0];
            self.0 = &self.0[1..];
            Ok(1)
        }
    }

    #[test]
    fn short_reads_are_handled() {
        let k = Key::generate();
        let pt = data(CHUNK_LEN + 3);
        let mut ct = Vec::new();
        encrypt(&k, b"", Trickle(&pt), &mut ct).unwrap();
        let mut out = Vec::new();
        decrypt(&k, b"", Trickle(&ct), &mut out).unwrap();
        assert_eq!(out, pt);
    }
}
