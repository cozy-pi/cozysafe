//! Standard test vectors for the Ed25519 and X25519 code the identity uses
//! (ed25519-dalek, x25519-dalek, curve25519-dalek; docs/supply-chain.md), run with every
//! `cargo test`. Copied from the RFC text (rfc-editor.org), checked once against an
//! independent implementation of each RFC before being written in.
//!
//! - RFC 8032 section 7.1: every Ed25519 vector (TEST 1, 2, 3, 1024, SHA(abc)).
//! - RFC 7748 section 5.2: the two X25519 scalar/u-coordinate cases, and the results after
//!   1 and 1,000 iterations (1,000,000 is left out: too slow for every run).
//! - RFC 7748 section 6.1: the Diffie-Hellman example.

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use x25519_dalek::{PublicKey, StaticSecret};

fn hex(s: &str) -> Vec<u8> {
    assert!(s.len().is_multiple_of(2), "odd hex length");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex digit"))
        .collect()
}

fn hex32(s: &str) -> [u8; 32] {
    hex(s).try_into().expect("32 bytes")
}

/// (name, secret key, public key, message, signature)
const ED25519: &[(&str, &str, &str, &str, &str)] = &[
    (
        "1",
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "",
        "\
        e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155\
        5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ),
    (
        "2",
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "\
        92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da\
        085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    ),
    (
        "3",
        "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        "af82",
        "\
        6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac\
        18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
    ),
    (
        "1024",
        "f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5",
        "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
        "\
        08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98\
        fa6e264bf09efe12ee50f8f54e9f77b1e355f6c50544e23fb1433ddf73be84d8\
        79de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d\
        658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc\
        1a858efcb8550ee3a5e1998bd177e93a7363c344fe6b199ee5d02e82d522c4fe\
        ba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e\
        06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbef\
        efd75499da96bd68a8a97b928a8bbc103b6621fcde2beca1231d206be6cd9ec7\
        aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1\
        85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2\
        d17ba70eb6248e594e1a2297acbbb39d502f1a8c6eb6f1ce22b3de1a1f40cc24\
        554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270\
        88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc\
        2732e69485bbc9c90bfbd62481d9089beccf80cfe2df16a2cf65bd92dd597b07\
        07e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba\
        b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51a\
        ddd3b75a2b1ae0784504df543af8969be3ea7082ff7fc9888c144da2af58429e\
        c96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7\
        51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c\
        42f58c30c04aafdb038dda0847dd988dcda6f3bfd15c4b4c4525004aa06eeff8\
        ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df\
        f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08\
        d78ff4ef5d63653a65040cf9bfd4aca7984a74d37145986780fc0b16ac451649\
        de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4\
        88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a3\
        2ef5b52a1ecc820e308aa342721aac0943bf6686b64b2579376504ccc493d97e\
        6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f\
        b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b5\
        0d334ba77c225bc307ba537152f3f1610e4eafe595f6d9d90d11faa933a15ef1\
        369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d\
        b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c\
        0618983f8741c5ef68d3a101e8a3b8cac60c905c15fc910840b94c00a0b9d0",
        "\
        0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350\
        aa5371b1508f9f4528ecea23c436d94b5e8fcd4f681e30a6ac00a9704a188a03",
    ),
    (
        "SHA(abc)",
        "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
        "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
        "\
        ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a\
        2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        "\
        dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b589\
        09351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
    ),
];

/// The group order l, little-endian.
const L: [u8; 32] = [
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
];

#[test]
fn rfc8032_ed25519() {
    assert_eq!(ED25519.len(), 5);
    for &(name, sk, pk, msg, sig) in ED25519 {
        let (sk, pk, msg, sig) = (hex32(sk), hex32(pk), hex(msg), hex(sig));
        let key = SigningKey::from_bytes(&sk);
        assert_eq!(
            key.verifying_key().to_bytes(),
            pk,
            "TEST {name}: public key"
        );
        let made = key.sign(&msg).to_bytes();
        assert_eq!(made.as_slice(), sig.as_slice(), "TEST {name}: signature");

        let vk = VerifyingKey::from_bytes(&pk).expect("valid key");
        let s = Signature::from_slice(&sig).expect("64 bytes");
        assert!(
            vk.verify_strict(&msg, &s).is_ok(),
            "TEST {name}: verify_strict"
        );

        // One changed bit anywhere in the signature or the message fails.
        for i in [0, 31, 32, 63] {
            let mut bad = sig.clone();
            bad[i] ^= 1;
            let bad = Signature::from_slice(&bad).expect("64 bytes");
            assert!(
                vk.verify_strict(&msg, &bad).is_err(),
                "TEST {name}: signature byte {i}"
            );
        }
        let mut other = msg.clone();
        other.push(0);
        assert!(
            vk.verify_strict(&other, &s).is_err(),
            "TEST {name}: longer message"
        );

        // S + l (same value mod l, not canonical) is refused: RFC 8032 5.1.7 asks S < l.
        let mut big = sig.clone();
        let mut carry = 0u16;
        for i in 0..32 {
            let t = big[32 + i] as u16 + L[i] as u16 + carry;
            big[32 + i] = t as u8;
            carry = t >> 8;
        }
        assert_eq!(carry, 0);
        let big = Signature::from_slice(&big).expect("64 bytes");
        assert!(vk.verify_strict(&msg, &big).is_err(), "TEST {name}: S >= l");
    }
}

#[test]
fn ed25519_strict_rejects_small_order() {
    // The identity (y = 1), a point of order 1, as R or as the public key.
    let mut identity = [0u8; 32];
    identity[0] = 1;
    let (_, _, pk, msg, sig) = ED25519[0];
    let (pk, msg, sig) = (hex32(pk), hex(msg), hex(sig));
    let mut r_small = sig.clone();
    r_small[..32].copy_from_slice(&identity);
    let vk = VerifyingKey::from_bytes(&pk).expect("valid key");
    let r_small = Signature::from_slice(&r_small).expect("64 bytes");
    assert!(vk.verify_strict(&msg, &r_small).is_err(), "small-order R");

    let weak = VerifyingKey::from_bytes(&identity).expect("decodes");
    assert!(weak.is_weak());
    // With A = identity, [S]B = R holds for S = 0 and R = identity, for any message.
    let mut forged = [0u8; 64];
    forged[..32].copy_from_slice(&identity);
    let forged = Signature::from_slice(&forged).expect("64 bytes");
    assert!(
        weak.verify_strict(b"any message", &forged).is_err(),
        "small-order A"
    );
}

fn x25519(k: [u8; 32], u: [u8; 32]) -> [u8; 32] {
    // The same path as xwing.rs: StaticSecret, then diffie_hellman.
    StaticSecret::from(k)
        .diffie_hellman(&PublicKey::from(u))
        .to_bytes()
}

#[test]
fn rfc7748_x25519() {
    assert_eq!(
        x25519(
            hex32("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
            hex32("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
        ),
        hex32("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"),
    );
    assert_eq!(
        x25519(
            hex32("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
            hex32("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"),
        ),
        hex32("95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"),
    );
}

#[test]
fn rfc7748_x25519_iterated() {
    let mut k = [0u8; 32];
    k[0] = 9;
    let mut u = k;
    for i in 1..=1000 {
        let r = x25519(k, u);
        u = k;
        k = r;
        if i == 1 {
            assert_eq!(
                k,
                hex32("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079"),
                "after 1 iteration"
            );
        }
    }
    assert_eq!(
        k,
        hex32("684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"),
        "after 1,000 iterations"
    );
}

#[test]
fn rfc7748_diffie_hellman() {
    let a = StaticSecret::from(hex32(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a",
    ));
    let b = StaticSecret::from(hex32(
        "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb",
    ));
    let ka = PublicKey::from(&a);
    let kb = PublicKey::from(&b);
    assert_eq!(
        ka.to_bytes(),
        hex32("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"),
        "Alice's public key"
    );
    assert_eq!(
        kb.to_bytes(),
        hex32("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"),
        "Bob's public key"
    );
    let k = hex32("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
    assert_eq!(a.diffie_hellman(&kb).to_bytes(), k, "shared secret, Alice");
    assert_eq!(b.diffie_hellman(&ka).to_bytes(), k, "shared secret, Bob");
}
