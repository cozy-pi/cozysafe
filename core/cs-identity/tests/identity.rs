//! The vault identity: same seed, same keys; both signature halves must hold; sealed
//! data opens only for its identity and purpose.

use cs_identity::{Identity, PublicIdentity, PUBLIC_LEN, SIGNATURE_LEN};

#[test]
fn the_same_seed_gives_the_same_identity() {
    let a = Identity::from_seed(&[1u8; 32]);
    let b = Identity::from_seed(&[1u8; 32]);
    let c = Identity::from_seed(&[2u8; 32]);
    assert_eq!(a.public(), b.public());
    assert_ne!(a.public(), c.public());
    assert_eq!(a.public().as_bytes().len(), PUBLIC_LEN);
    assert_eq!(a.public().code(), b.public().code());
    let code = a.public().code();
    assert_eq!(code.len(), 9);
    assert_eq!(&code[4..5], "-");
}

/// The derivation never changes: a vault keeps its code across versions of the app.
#[test]
fn the_derivation_is_fixed() {
    let id = Identity::from_seed(&[0u8; 32]);
    let fp: String = id
        .public()
        .fingerprint()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    assert_eq!(
        fp, FIXED_FINGERPRINT,
        "the identity derivation changed: every vault's code would change"
    );
}

const FIXED_FINGERPRINT: &str = "84272627096c5a09f5675e6e10b8908d06d8a0b8327e0c79426daffb9ff4ea70";

#[test]
fn signatures_need_both_halves() {
    let id = Identity::from_seed(&[3u8; 32]);
    let pk = id.public();
    let sig = id.sign("test/v1", b"hello");
    assert_eq!(sig.len(), SIGNATURE_LEN);
    assert!(pk.verify("test/v1", b"hello", &sig));
    assert!(!pk.verify("test/v1", b"hellp", &sig));
    assert!(!pk.verify("test/v2", b"hello", &sig), "another purpose");
    let other = Identity::from_seed(&[4u8; 32]);
    assert!(
        !other.public().verify("test/v1", b"hello", &sig),
        "another identity"
    );
    // Break the Ed25519 half only, then the ML-DSA half only.
    let mut s = sig.clone();
    s[3] ^= 1;
    assert!(!pk.verify("test/v1", b"hello", &s));
    let mut s = sig.clone();
    s[200] ^= 1;
    assert!(!pk.verify("test/v1", b"hello", &s));
    // One identity's Ed25519 half with another's ML-DSA half.
    let mixed = [&sig[..64], &other.sign("test/v1", b"hello")[64..]].concat();
    assert!(!pk.verify("test/v1", b"hello", &mixed));
}

#[test]
fn sealed_opens_only_for_its_identity_and_purpose() {
    let id = Identity::from_seed(&[5u8; 32]);
    let sealed = id.public().seal("share/v1", b"a secret");
    assert_eq!(&**id.open("share/v1", &sealed).unwrap(), b"a secret");
    assert!(id.open("share/v2", &sealed).is_err());
    assert!(Identity::from_seed(&[6u8; 32])
        .open("share/v1", &sealed)
        .is_err());
    let mut bad = sealed.clone();
    bad[10] ^= 1;
    assert!(id.open("share/v1", &bad).is_err());
    let mut bad = sealed.clone();
    *bad.last_mut().unwrap() ^= 1;
    assert!(id.open("share/v1", &bad).is_err());
    // Two seals of the same message differ (fresh randomness each time).
    assert_ne!(id.public().seal("share/v1", b"a secret"), sealed);
}

#[test]
fn reading_a_public_identity_checks_it() {
    let id = Identity::from_seed(&[8u8; 32]);
    let bytes = id.public().as_bytes().to_vec();
    assert_eq!(
        PublicIdentity::from_bytes(&bytes).as_ref(),
        Some(id.public())
    );
    assert!(PublicIdentity::from_bytes(&bytes[..PUBLIC_LEN - 1]).is_none());
    // A non-canonical Ed25519 encoding: y = p + 3, a point of large order once reduced,
    // which dalek takes (and verify_strict does not refuse); we refuse it.
    let mut y = [0xffu8; 32];
    y[0] = 0xf0;
    y[31] = 0x7f;
    assert!(
        ed25519_dalek::VerifyingKey::from_bytes(&y).is_ok(),
        "dalek reads it"
    );
    let mut bad = bytes.clone();
    bad[..32].copy_from_slice(&y);
    assert!(PublicIdentity::from_bytes(&bad).is_none());
    // An ML-KEM key with a coefficient out of range is refused (FIPS 203 key check).
    let mut bad = bytes.clone();
    let kem = 32 + 1952;
    bad[kem] = 0xff;
    bad[kem + 1] = 0xff;
    assert!(PublicIdentity::from_bytes(&bad).is_none());
}
