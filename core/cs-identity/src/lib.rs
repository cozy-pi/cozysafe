//! A vault's identity (docs/adr/0008-vault-identity.md): the keys another vault or
//! device checks it by, derived from the vault's Master Key, so the 24 words and the
//! password bring them back and every device holding the vault has the same ones.
//!
//! Hybrid, classical and post-quantum together (docs/security.md, quantum computers):
//! - signing: Ed25519 **and** ML-DSA-65 (FIPS 204); a signature holds only when both do;
//! - sealing to the vault: X-Wing (ML-KEM-768, FIPS 203, with X25519;
//!   draft-connolly-cfrg-xwing-kem-11), then XChaCha20-Poly1305 as everywhere else.
//!
//! A break of either family alone (a flaw in the new lattice schemes, or a quantum
//! computer for the curves) leaves the other standing.
//!
//! The vault's code (`7F3A-9K2Q`) names the identity to people: the first 40 bits of the
//! fingerprint, SHA-256 over every public key. It is a label, not a check: comparing two
//! identities uses the whole fingerprint ([`PublicIdentity::fingerprint`]).

use cs_crypto::{wrap, Key};
use ed25519_dalek::{Signer, SigningKey as EdSigningKey, VerifyingKey as EdVerifyingKey};
use hkdf::Hkdf;
use ml_dsa::{
    EncodedSignature, EncodedVerifyingKey, Keypair, MlDsa65, Signature as DsaSignature,
    SigningKey as DsaSigningKey, VerifyingKey as DsaVerifyingKey,
};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub mod xwing;

// curve25519-dalek takes a derive macro for its SIMD backend on x86_64, which the Top
// secret core does not take; .cargo/config.toml picks the serial backend. A build that
// misses that file stops here instead of fetching the macro.
#[cfg(all(target_arch = "x86_64", not(curve25519_dalek_backend = "serial")))]
compile_error!("build with --cfg curve25519_dalek_backend=\"serial\" (.cargo/config.toml)");

/// Bytes of an Ed25519 public key.
pub const ED25519_LEN: usize = 32;
/// Bytes of an ML-DSA-65 public key.
pub const ML_DSA_LEN: usize = 1952;
/// Bytes of an ML-DSA-65 signature.
pub const ML_DSA_SIG_LEN: usize = 3309;
/// Bytes of a public identity: Ed25519, ML-DSA-65, then X-Wing.
pub const PUBLIC_LEN: usize = ED25519_LEN + ML_DSA_LEN + xwing::PUBLIC_LEN;
/// Bytes of a signature: Ed25519 (64), then ML-DSA-65.
pub const SIGNATURE_LEN: usize = 64 + ML_DSA_SIG_LEN;

const INFO_ED25519: &[u8] = b"cozysafe/v1/identity/ed25519";
const INFO_ML_DSA: &[u8] = b"cozysafe/v1/identity/ml-dsa-65";
const INFO_XWING: &[u8] = b"cozysafe/v1/identity/x-wing";
const FINGERPRINT_TAG: &[u8] = b"cozysafe/v1/identity\0";
const SIGN_TAG: &[u8] = b"cozysafe/v1/sign\0";
const SEAL_INFO: &[u8] = b"cozysafe/v1/seal/";
/// ML-DSA's own context string (FIPS 204, ctx).
const ML_DSA_CTX: &[u8] = b"cozysafe/v1";

/// Why something sealed to an identity does not open.
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// Not sealed to this identity, for this purpose, or changed on the way.
    Open,
}

/// The private side, held while the vault is open; dropped with it.
pub struct Identity {
    ed: EdSigningKey,
    dsa: DsaSigningKey<MlDsa65>,
    xwing_seed: Zeroizing<[u8; 32]>,
    public: PublicIdentity,
}

fn expand(seed: &[u8; 32], info: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut out = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(None, seed)
        .expand(info, out.as_mut())
        .expect("32 bytes is a valid HKDF-SHA256 length");
    out
}

impl Identity {
    /// The identity of the vault whose Master Key gave `seed` (cs-core
    /// `Vault::identity_seed`). The same seed always gives the same keys.
    pub fn from_seed(seed: &[u8; 32]) -> Self {
        let ed = EdSigningKey::from_bytes(&expand(seed, INFO_ED25519));
        let dsa_seed = expand(seed, INFO_ML_DSA);
        let dsa = DsaSigningKey::<MlDsa65>::from_seed(&(*dsa_seed).into());
        let xwing_seed = expand(seed, INFO_XWING);
        let mut bytes = Vec::with_capacity(PUBLIC_LEN);
        bytes.extend_from_slice(ed.verifying_key().as_bytes());
        bytes.extend_from_slice(&dsa.verifying_key().encode());
        bytes.extend_from_slice(&xwing::public_key(&xwing_seed));
        Self {
            ed,
            dsa,
            xwing_seed,
            public: PublicIdentity { bytes },
        }
    }

    /// What others keep and check against.
    pub fn public(&self) -> &PublicIdentity {
        &self.public
    }

    /// Sign `msg` for `purpose` (a short fixed name, "share/v1"): a signature made for one
    /// purpose never verifies for another, nor for another identity.
    pub fn sign(&self, purpose: &str, msg: &[u8]) -> Vec<u8> {
        let framed = framed(&self.public, purpose, msg);
        let mut out = Vec::with_capacity(SIGNATURE_LEN);
        out.extend_from_slice(&self.ed.sign(&framed).to_bytes());
        let dsa = self
            .dsa
            .expanded_key()
            .sign_deterministic(&framed, ML_DSA_CTX)
            .expect("the context is shorter than 255 bytes");
        out.extend_from_slice(&dsa.encode());
        out
    }

    /// Open what [`PublicIdentity::seal`] sealed to this identity for `purpose`.
    pub fn open(&self, purpose: &str, sealed: &[u8]) -> Result<Zeroizing<Vec<u8>>, Error> {
        if sealed.len() < xwing::CIPHERTEXT_LEN {
            return Err(Error::Open);
        }
        let (ct, body) = sealed.split_at(xwing::CIPHERTEXT_LEN);
        let ss = xwing::decapsulate(&self.xwing_seed, ct.try_into().map_err(|_| Error::Open)?);
        let key = seal_key(&ss, purpose);
        wrap::open(&key, body, &seal_aad(&self.public, ct)).map_err(|_| Error::Open)
    }
}

/// The public side: what a vault shows of itself.
#[derive(Clone, PartialEq, Eq)]
pub struct PublicIdentity {
    bytes: Vec<u8>,
}

impl std::fmt::Debug for PublicIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PublicIdentity({})", self.code())
    }
}

impl PublicIdentity {
    /// Read one sent by another vault; None when any of its keys is not a valid key.
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != PUBLIC_LEN {
            return None;
        }
        let id = Self {
            bytes: bytes.to_vec(),
        };
        id.ed()?;
        id.dsa()?;
        xwing::check_public(id.xwing())?;
        Some(id)
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// Only the canonical encoding (dalek accepts y >= p too, and verify_strict does not
    /// refuse those points): one key, one way to write it.
    fn ed(&self) -> Option<EdVerifyingKey> {
        let bytes: &[u8; ED25519_LEN] = self.bytes[..ED25519_LEN].try_into().ok()?;
        let key = EdVerifyingKey::from_bytes(bytes).ok()?;
        (key.to_edwards().compress().as_bytes() == bytes).then_some(key)
    }

    fn dsa(&self) -> Option<DsaVerifyingKey<MlDsa65>> {
        let enc = EncodedVerifyingKey::<MlDsa65>::try_from(
            &self.bytes[ED25519_LEN..ED25519_LEN + ML_DSA_LEN],
        )
        .ok()?;
        Some(DsaVerifyingKey::decode(&enc))
    }

    fn xwing(&self) -> &[u8] {
        &self.bytes[ED25519_LEN + ML_DSA_LEN..]
    }

    /// SHA-256 over every public key: two identities are the same when this is.
    pub fn fingerprint(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(FINGERPRINT_TAG);
        h.update(&self.bytes);
        h.finalize().into()
    }

    /// The vault's code for people: the first 40 bits of the fingerprint in Crockford's
    /// base 32 (no I, L, O or U), as `7F3A-9K2Q`.
    pub fn code(&self) -> String {
        code_of(&self.fingerprint())
    }

    /// Whether `sig` is this identity's signature of `msg` for `purpose`: both halves
    /// must hold.
    pub fn verify(&self, purpose: &str, msg: &[u8], sig: &[u8]) -> bool {
        if sig.len() != SIGNATURE_LEN {
            return false;
        }
        let (Some(ed), Some(dsa)) = (self.ed(), self.dsa()) else {
            return false;
        };
        let framed = framed(self, purpose, msg);
        let (ed_sig, dsa_sig) = sig.split_at(64);
        let Ok(ed_sig) = ed25519_dalek::Signature::from_slice(ed_sig) else {
            return false;
        };
        let ed_ok = ed.verify_strict(&framed, &ed_sig).is_ok();
        let dsa_ok = EncodedSignature::<MlDsa65>::try_from(dsa_sig)
            .ok()
            .and_then(|e| DsaSignature::<MlDsa65>::decode(&e))
            .is_some_and(|s| dsa.verify_with_context(&framed, ML_DSA_CTX, &s));
        ed_ok & dsa_ok
    }

    /// Seal `msg` so only this identity opens it, for `purpose`.
    pub fn seal(&self, purpose: &str, msg: &[u8]) -> Vec<u8> {
        let mut eseed = Zeroizing::new([0u8; 64]);
        eseed[..32].copy_from_slice(Key::generate().as_bytes());
        eseed[32..].copy_from_slice(Key::generate().as_bytes());
        let pk: &[u8; xwing::PUBLIC_LEN] = self.xwing().try_into().expect("checked length");
        let (ct, ss) = xwing::encapsulate_derand(pk, &eseed).expect("checked on reading");
        let key = seal_key(&ss, purpose);
        let mut out = ct.to_vec();
        out.extend_from_slice(&wrap::seal(&key, msg, &seal_aad(self, &ct)));
        out
    }
}

/// What both signatures cover: who signs, for what, and the message.
fn framed(signer: &PublicIdentity, purpose: &str, msg: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(SIGN_TAG.len() + 32 + 2 + purpose.len() + msg.len());
    m.extend_from_slice(SIGN_TAG);
    m.extend_from_slice(&signer.fingerprint());
    m.extend_from_slice(&(purpose.len() as u16).to_be_bytes());
    m.extend_from_slice(purpose.as_bytes());
    m.extend_from_slice(msg);
    m
}

fn seal_key(ss: &[u8; 32], purpose: &str) -> Key {
    let mut info = SEAL_INFO.to_vec();
    info.extend_from_slice(purpose.as_bytes());
    let mut out = [0u8; 32];
    Hkdf::<Sha256>::new(None, ss)
        .expand(&info, &mut out)
        .expect("32 bytes is a valid HKDF-SHA256 length");
    Key::from_bytes(out)
}

/// The body is bound to the recipient and to the encapsulation in front of it.
fn seal_aad(to: &PublicIdentity, ct: &[u8]) -> Vec<u8> {
    let mut aad = to.fingerprint().to_vec();
    aad.extend_from_slice(ct);
    aad
}

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

fn code_of(fp: &[u8; 32]) -> String {
    let n = u64::from_be_bytes([0, 0, 0, fp[0], fp[1], fp[2], fp[3], fp[4]]);
    let mut s = String::with_capacity(9);
    for i in 0..8 {
        if i == 4 {
            s.push('-');
        }
        s.push(CROCKFORD[((n >> (35 - 5 * i)) & 31) as usize] as char);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_is_crockford_of_the_first_forty_bits() {
        let mut fp = [0u8; 32];
        assert_eq!(code_of(&fp), "0000-0000");
        fp[..5].copy_from_slice(&[0xff; 5]);
        assert_eq!(code_of(&fp), "ZZZZ-ZZZZ");
        fp[..5].copy_from_slice(&[0x08, 0x42, 0x10, 0x84, 0x21]);
        assert_eq!(code_of(&fp), "1111-1111");
    }
}
