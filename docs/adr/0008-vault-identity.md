# ADR 0008: A vault identity, hybrid and post-quantum

- Status: accepted (owner, 2026-11-06)
- Related: [ADR 0001](0001-encryption.md) (keys), [ADR 0003](0003-sync.md) (devices),
  docs/security.md (quantum computers)

## Context

A vault had no identity of its own. Its id is 128 random bits, fine for file names and
sync, but anyone who knows it can claim it: it proves nothing. Two needs came together
(owner, 2026-11-05 and 2026-11-06):

1. **Naming what is kept outside the app.** The vault password goes to the system's
   password manager and the 24 words to the iCloud Keychain / Google Block Store, and
   each must say which vault it belongs to. Something the person can change (a name,
   the icon) is not an identity: the copy outside would stop matching it.
2. **Vaults and devices that talk to each other later** (sharing an item with another
   vault, devices exchanging data). That needs keys: one to sign with, so "this came
   from vault 7F3A-9K2Q" can be checked, and one to seal to, so only that vault opens it.

Everything in the vault so far is symmetric (XChaCha20-Poly1305, HKDF-SHA256, Argon2id),
so quantum computers do not threaten it (docs/security.md). Public keys change that:
Shor's algorithm breaks elliptic curves, and data sealed today can be kept until then
("harvest now, decrypt later"). docs/security.md already said any key exchange must be
post-quantum, never classical alone.

## Decision

**Every vault has an identity: hybrid signing and sealing keys, derived from its Master
Key.** Crate `core/cs-identity`.

- **Seed.** `Vault::identity_seed` = HKDF-SHA256 subkey of the Master Key, label
  `identity/v1/<vault id>`. The Master Key is made once and only rewrapped (new password,
  new Recovery Key), so the identity never changes, every device holding the vault
  derives the same one, and the 24 words with the password bring it back. Nothing new
  is stored.
- **Keys** (each from its own HKDF-SHA256 expansion of the seed,
  `cozysafe/v1/identity/<scheme>`):
  - signing: **Ed25519** (RFC 8032) **and ML-DSA-65** (FIPS 204, from its 32-byte seed);
  - sealing: **X-Wing** (draft-connolly-cfrg-xwing-kem-11): ML-KEM-768 (FIPS 203) with
    X25519, combined with SHA3-256 as the draft writes it, its 32-byte seed as the
    decapsulation key. A named, reviewed combiner rather than one of our own; the
    draft's test vectors pass (`tests/xwing.rs`).
- **Public identity:** Ed25519 key (32) ‖ ML-DSA-65 key (1952) ‖ X-Wing key (1216) =
  3200 bytes. Reading one checks every key (Ed25519 point, ML-KEM modulus check).
- **Fingerprint:** SHA-256 over `cozysafe/v1/identity\0` and the public identity. Two
  identities are the same when their fingerprints are.
- **Code:** the first 40 bits of the fingerprint in Crockford's base 32, `7F3A-9K2Q`. It
  names the vault to people: in Settings, as the user name in the password manager, in
  the label of the cloud copy of the words. **A label, not a check:** 40 bits can be
  matched by an attacker grinding keys (about 2⁴⁰ tries), so anything that decides trust
  (pairing two vaults) compares the whole fingerprint (QR or a longer safety number),
  never the code alone.
- **Signatures:** Ed25519 signature (64) ‖ ML-DSA-65 signature (3309). Both cover the
  same framed message: `cozysafe/v1/sign\0`, the signer's fingerprint, the purpose
  (length-prefixed, such as `share/v1`), then the message. A signature holds only when
  **both** halves verify (Ed25519 `verify_strict`), so a break of one family is not
  enough, and a signature never carries over to another purpose or another identity.
  ML-DSA signs with its deterministic variant (FIPS 204 allows it; no randomness to get
  wrong), context string `cozysafe/v1`.
- **Sealing to a vault:** X-Wing encapsulation (64 fresh random bytes) ‖
  XChaCha20-Poly1305 of the message under HKDF-SHA256(shared secret,
  `cozysafe/v1/seal/<purpose>`), the recipient's fingerprint and the encapsulation as
  associated data.
- **x86_64 builds use dalek's serial backend.** curve25519-dalek takes a derive macro
  (syn, quote) for its SIMD backend on x86_64; the Top secret core takes none.
  `.cargo/config.toml` sets `curve25519_dalek_backend="serial"` (the same constant-time
  arithmetic in plain Rust); cs-identity refuses to compile on x86_64 without it, so a
  build that misses the file fails instead of fetching the macro. Phones and Apple
  Silicon use serial anyway.
- **New crates on the Top secret core,** each a copy in `third_party/rust/`, reviewed
  and recorded (docs/supply-chain.md): ml-kem, ml-dsa, module-lattice, kem, signature,
  num-traits (no_std, used for integer traits), sha3, shake, keccak, sponge-cursor,
  rand_core 0.10 (traits only), curve25519-dalek, ed25519-dalek, ed25519, x25519-dalek;
  ctutils moved from 0.4.4 to 0.4.8; build scripts: autocfg, rustc_version, semver.

## Consequences

- The identity costs nothing to keep and a few hundred microseconds to derive (ML-DSA
  key generation); the app works out the code once per vault per run.
- **The derivation is frozen.** `tests/identity.rs` pins the fingerprint of a fixed
  seed; changing any label, key order or scheme fails it, because every vault's code
  would change. A new scheme gets a new version (`identity/v2`) beside the old one.
- The X-Wing draft is not final (its vectors are marked to be replaced). If the final
  text differs, v1 keeps what it is (it is pinned by our own test) and the final one
  becomes v2.
- A locked vault cannot show its code (the Master Key is needed); the app remembers it
  on this device after the first open.

## Not decided here

- What signing and sealing are used for first (sharing between vaults, pairing devices),
  and how two vaults exchange and confirm their identities.
- Device identities (a device has an id for sync; no keys yet).
- Turning a vault's identity over (a new identity after a suspected leak of the Master
  Key) and how the old one is revoked.

## Alternatives considered

- **Ed25519 / X25519 only:** simpler and audited, but breaks against a quantum computer,
  and docs/security.md rules classical-only key exchange out.
- **ML-DSA / ML-KEM only:** fewer crates, but the lattice schemes are young; a flaw found
  in them would leave nothing behind.
- **The random vault id as the identity:** no keys, proves nothing, cannot carry signing
  or sealing later.
- **A name the person chooses:** can change, so it is not an identity.
