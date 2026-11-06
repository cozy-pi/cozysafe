//! X-Wing, the hybrid KEM of ML-KEM-768 and X25519 (draft-connolly-cfrg-xwing-kem-11),
//! as written there: the decapsulation key is a 32-byte seed, the combiner SHA3-256.
//! Checked against the draft's test vectors (tests/xwing.rs).

use ml_kem::kem::Decapsulate;
use ml_kem::{Ciphertext, KeyExport, MlKem768, Seed, B32};
use ml_kem::{DecapsulationKey, EncapsulationKey};
use sha3::{Digest, Sha3_256};
use shake::{ExtendableOutput, Shake256, Update, XofReader};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// ML-KEM-768 encapsulation key, then the X25519 public key.
pub const PUBLIC_LEN: usize = 1184 + 32;
/// ML-KEM-768 ciphertext, then the X25519 ephemeral public key.
pub const CIPHERTEXT_LEN: usize = 1088 + 32;
/// "\.//^\" (section 5.3).
const LABEL: &[u8; 6] = b"\\.//^\\";

struct Expanded {
    dk_m: DecapsulationKey<MlKem768>,
    sk_x: StaticSecret,
    pk_x: PublicKey,
}

/// expandDecapsulationKey (section 5.2): SHAKE256(seed, 96) gives ML-KEM's d and z, then
/// the X25519 secret.
fn expand(seed: &[u8; 32]) -> Expanded {
    let mut out = Zeroizing::new([0u8; 96]);
    let mut h = Shake256::default();
    h.update(seed);
    h.finalize_xof().read(out.as_mut());
    // Secrets here are wiped when dropped (ML-KEM takes its seed by value, a copy).
    let mut dz = Zeroizing::new(Seed::default());
    dz.copy_from_slice(&out[..64]);
    let dk_m = DecapsulationKey::<MlKem768>::from_seed(*dz);
    let mut x = Zeroizing::new([0u8; 32]);
    x.copy_from_slice(&out[64..]);
    let sk_x = StaticSecret::from(*x);
    let pk_x = PublicKey::from(&sk_x);
    Expanded { dk_m, sk_x, pk_x }
}

/// The public key of `seed`: pk_M then pk_X.
pub fn public_key(seed: &[u8; 32]) -> [u8; PUBLIC_LEN] {
    let e = expand(seed);
    let mut pk = [0u8; PUBLIC_LEN];
    pk[..1184].copy_from_slice(&e.dk_m.encapsulation_key().to_bytes());
    pk[1184..].copy_from_slice(e.pk_x.as_bytes());
    pk
}

fn ek_of(pk: &[u8]) -> Option<EncapsulationKey<MlKem768>> {
    let bytes = pk.get(..1184)?.try_into().ok()?;
    EncapsulationKey::<MlKem768>::new(bytes).ok()
}

/// Whether `pk` is a public key ML-KEM accepts (FIPS 203 encapsulation key check).
pub fn check_public(pk: &[u8]) -> Option<()> {
    (pk.len() == PUBLIC_LEN).then_some(())?;
    ek_of(pk).map(|_| ())
}

fn combiner(ss_m: &[u8], ss_x: &[u8; 32], ct_x: &[u8; 32], pk_x: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha3_256::new();
    Digest::update(&mut h, ss_m);
    Digest::update(&mut h, ss_x);
    Digest::update(&mut h, ct_x);
    Digest::update(&mut h, pk_x);
    Digest::update(&mut h, LABEL);
    h.finalize().into()
}

/// EncapsulateDerand (section 5.4.1): `eseed` is 64 uniformly random bytes, never reused.
/// None when `pk` is not a valid public key.
pub fn encapsulate_derand(
    pk: &[u8; PUBLIC_LEN],
    eseed: &[u8; 64],
) -> Option<([u8; CIPHERTEXT_LEN], [u8; 32])> {
    let ek = ek_of(pk)?;
    let mut pk_x = [0u8; 32];
    pk_x.copy_from_slice(&pk[1184..]);
    let mut e = Zeroizing::new([0u8; 32]);
    e.copy_from_slice(&eseed[32..]);
    let ek_x = StaticSecret::from(*e);
    let ct_x = PublicKey::from(&ek_x);
    let ss_x = Zeroizing::new(ek_x.diffie_hellman(&PublicKey::from(pk_x)).to_bytes());
    let mut m = Zeroizing::new(B32::default());
    m.copy_from_slice(&eseed[..32]);
    let (ct_m, ss_m) = ek.encapsulate_deterministic(&m);
    let ss_m = Zeroizing::new(ss_m);
    let ss = combiner(&ss_m, &ss_x, ct_x.as_bytes(), &pk_x);
    let mut ct = [0u8; CIPHERTEXT_LEN];
    ct[..1088].copy_from_slice(&ct_m);
    ct[1088..].copy_from_slice(ct_x.as_bytes());
    Some((ct, ss))
}

/// Decapsulate (section 5.5). ML-KEM rejects implicitly: a changed ciphertext gives an
/// unrelated secret, and the AEAD behind it fails.
pub fn decapsulate(seed: &[u8; 32], ct: &[u8; CIPHERTEXT_LEN]) -> [u8; 32] {
    let e = expand(seed);
    let ct_m: Ciphertext<MlKem768> =
        Ciphertext::<MlKem768>::try_from(&ct[..1088]).expect("1088 bytes");
    let ss_m = Zeroizing::new(e.dk_m.decapsulate(&ct_m));
    let mut ct_x = [0u8; 32];
    ct_x.copy_from_slice(&ct[1088..]);
    let ss_x = Zeroizing::new(e.sk_x.diffie_hellman(&PublicKey::from(ct_x)).to_bytes());
    combiner(&ss_m, &ss_x, &ct_x, e.pk_x.as_bytes())
}
