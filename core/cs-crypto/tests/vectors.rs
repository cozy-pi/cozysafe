//! Standard test vectors for every primitive the Top secret core uses (docs/supply-chain.md:
//! "audited" means a public audit, or our own review plus these vectors). Each value is
//! copied from the document named above its test, and the SHA-2, HMAC and HKDF ones were
//! also checked against an independent implementation (OpenSSL) before they were written.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, XChaCha20Poly1305};
use hkdf::hmac::{Hmac, Mac};
use hkdf::Hkdf;
use sha2::{Digest, Sha256, Sha512};

fn hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn to_hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// FIPS 180-4 examples (NIST, "Examples with intermediate values"): SHA-256, SHA-512.
#[test]
fn sha2_nist_examples() {
    let million_a = vec![b'a'; 1_000_000];
    let cases256: [(&[u8], &str); 3] = [
        (
            b"abc",
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        ),
        (
            b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        ),
        (
            &million_a,
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        ),
    ];
    for (msg, want) in cases256 {
        assert_eq!(to_hex(&Sha256::digest(msg)), want);
    }
    let cases512: [(&[u8], &str); 3] = [
        (b"abc", "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"),
        (b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"),
        (&million_a, "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b"),
    ];
    for (msg, want) in cases512 {
        assert_eq!(to_hex(&Sha512::digest(msg)), want);
    }
}

/// RFC 4231, test cases 1 to 7 (case 5 compares the first 128 bits only).
#[test]
fn hmac_rfc4231() {
    // (key, data, HMAC-SHA-256, HMAC-SHA-512)
    let cases: [(&str, &str, &str, &str); 7] = [
        ("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", "4869205468657265", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"),
        ("4a656665", "7768617420646f2079612077616e7420666f72206e6f7468696e673f", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe", "fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb"),
        ("0102030405060708090a0b0c0d0e0f10111213141516171819", "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b", "b0ba465637458c6990e5a8c5f61d4af7e576d97ff94b872de76f8050361ee3dba91ca5c11aa25eb4d679275cc5788063a5f19741120c4f2de2adebeb10a298dd"),
        ("0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c", "546573742057697468205472756e636174696f6e", "a3b6167473100ee06e0c796c2955552b", "415fad6271580a531d4179bc891d87a6"),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "54657374205573696e67204c6172676572205468616e20426c6f636b2d53697a65204b6579202d2048617368204b6579204669727374", "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f3526b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598"),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "5468697320697320612074657374207573696e672061206c6172676572207468616e20626c6f636b2d73697a65206b657920616e642061206c6172676572207468616e20626c6f636b2d73697a6520646174612e20546865206b6579206e6565647320746f20626520686173686564206265666f7265206265696e6720757365642062792074686520484d414320616c676f726974686d2e", "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2", "e37b6a775dc87dbaa4dfa9f96e5e3ffddebd71f8867289865df5a32d20cdc944b6022cac3c4982b10d5eeb55c3e4de15134676fb6de0446065c97440fa8c6a58"),
    ];
    for (key, data, want256, want512) in cases {
        let mut m = <Hmac<Sha256> as hkdf::hmac::KeyInit>::new_from_slice(&hex(key)).unwrap();
        m.update(&hex(data));
        let got = to_hex(&m.finalize().into_bytes());
        assert_eq!(&got[..want256.len()], want256);
        let mut m = <Hmac<Sha512> as hkdf::hmac::KeyInit>::new_from_slice(&hex(key)).unwrap();
        m.update(&hex(data));
        let got = to_hex(&m.finalize().into_bytes());
        assert_eq!(&got[..want512.len()], want512);
    }
}

/// RFC 5869, appendix A: the SHA-256 cases (A.1 to A.3).
#[test]
fn hkdf_rfc5869() {
    // (IKM, salt, info, PRK, OKM)
    let cases: [(&str, &str, &str, &str, &str); 3] = [
        ("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", "000102030405060708090a0b0c", "f0f1f2f3f4f5f6f7f8f9", "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5", "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"),
        ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f", "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf", "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244", "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87"),
        ("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", "", "", "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04", "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"),
    ];
    for (ikm, salt, info, prk, okm) in cases {
        let salt = hex(salt);
        let salt = if salt.is_empty() {
            None
        } else {
            Some(&salt[..])
        };
        let (got_prk, h) = Hkdf::<Sha256>::extract(salt, &hex(ikm));
        assert_eq!(to_hex(&got_prk), prk);
        let mut got = vec![0u8; okm.len() / 2];
        h.expand(&hex(info), &mut got).unwrap();
        assert_eq!(to_hex(&got), okm);
    }
}

/// RFC 9106, section 5.3: Argon2id, version 0x13, with a secret and associated data.
#[test]
fn argon2id_rfc9106() {
    use argon2::{Algorithm, Argon2, AssociatedData, ParamsBuilder, Version};
    let ad = [4u8; 12];
    let params = ParamsBuilder::new()
        .m_cost(32)
        .t_cost(3)
        .p_cost(4)
        .output_len(32)
        .data(AssociatedData::new(&ad).unwrap())
        .build()
        .unwrap();
    let secret = [3u8; 8];
    let a = Argon2::new_with_secret(&secret, Algorithm::Argon2id, Version::V0x13, params).unwrap();
    let mut tag = [0u8; 32];
    a.hash_password_into(&[1u8; 32], &[2u8; 16], &mut tag)
        .unwrap();
    assert_eq!(
        to_hex(&tag),
        "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"
    );
}

/// RFC 8439, section 2.8.2: AEAD_CHACHA20_POLY1305.
#[test]
fn chacha20poly1305_rfc8439() {
    let key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    let nonce = hex("070000004041424344454647");
    let aad = hex("50515253c0c1c2c3c4c5c6c7");
    let plain = hex("4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e");
    let want = "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691";
    let c = ChaCha20Poly1305::new_from_slice(&key).unwrap();
    let sealed = c
        .encrypt(
            nonce[..].into(),
            Payload {
                msg: &plain,
                aad: &aad,
            },
        )
        .unwrap();
    assert_eq!(to_hex(&sealed), want);
    let opened = c
        .decrypt(
            nonce[..].into(),
            Payload {
                msg: &sealed,
                aad: &aad,
            },
        )
        .unwrap();
    assert_eq!(opened, plain);
}

/// draft-irtf-cfrg-xchacha-03, appendix A.3.1: AEAD_XCHACHA20_POLY1305, what the vault
/// seals everything with (src/wrap.rs, src/stream.rs).
#[test]
fn xchacha20poly1305_draft_irtf_cfrg_xchacha() {
    let key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    let nonce = hex("404142434445464748494a4b4c4d4e4f5051525354555657");
    let aad = hex("50515253c0c1c2c3c4c5c6c7");
    let plain = hex("4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e");
    let want = "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52ec0875924c1c7987947deafd8780acf49";
    let c = XChaCha20Poly1305::new_from_slice(&key).unwrap();
    let sealed = c
        .encrypt(
            nonce[..].into(),
            Payload {
                msg: &plain,
                aad: &aad,
            },
        )
        .unwrap();
    assert_eq!(to_hex(&sealed), want);
    let mut tampered = sealed.clone();
    tampered[0] ^= 1;
    assert!(c
        .decrypt(
            nonce[..].into(),
            Payload {
                msg: &tampered,
                aad: &aad
            }
        )
        .is_err());
}
