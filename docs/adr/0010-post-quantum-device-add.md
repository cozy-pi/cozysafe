# ADR 0010: Adding a device, post-quantum

- Status: accepted (owner, 2026-11-06)
- Related: [ADR 0003](0003-sync.md) (point 11, adding a device by an 8-digit code),
  [ADR 0008](0008-vault-identity.md) (X-Wing), docs/security.md (quantum computers)

## Context

Adding a device on the Wi-Fi (ADR 0003, point 11) made its key with X25519 alone. The
vault password and the 24 words cross the channel that key protects. Someone who records
the session can keep it until a quantum computer breaks X25519 (Shor's algorithm), then
work out the key and read both: "harvest now, decrypt later". The 8-digit code stops
someone in the middle today; it does nothing against a recording opened later.

Project rule (owner, 2026-11-06): **every public-key step is hybrid, classical and
post-quantum together, and both must hold.** X-Wing preferred.

## Decision

**The two devices make the key with X-Wing** (ML-KEM-768, FIPS 203, with X25519;
draft-connolly-cfrg-xwing-kem-11): a key encapsulation instead of a Diffie-Hellman
exchange. The implementation is the vault identity's (`cs_identity::xwing`, ADR 0008,
checked against the draft's vectors); no new crate.

- **New device** (mode 10): a fresh X-Wing key pair (32-byte seed from the system's
  generator, wiped after use) and a nonce `nj`. It sends its public key and a commitment
  `SHA-256("cozysafe/p2p/v2/add-commit" ‖ public key ‖ nj)`, keeping `nj` back.
- **Old device:** checks the key (ML-KEM's modulus check), encapsulates to it (64 fresh
  random bytes, wiped), sends the ciphertext and its nonce `nh`.
- **New device:** decapsulates, then reveals `nj`; the old device checks it against the
  commitment (refused, and the wait ends, if it does not open).
- **Keys.** Transcript `T = SHA-256("cozysafe/p2p/v2/add-transcript" ‖ token ‖ public
  key ‖ ciphertext ‖ nj ‖ nh)`, each part length-prefixed. From the X-Wing shared secret,
  HKDF (`kdf::subkey`) gives the pairing key `p2p-add/v2/key/<T>` and the code
  `p2p-add/v2/code/<T>` (first 8 bytes as a number, mod 10^8). Everything after (the
  sealed, numbered frames, the code typed on the new device, the password, the words) is
  as in ADR 0003.
- **Hybrid inside.** X-Wing's shared secret is SHA3-256 over both the ML-KEM and the
  X25519 secrets (and the X25519 keys), so the key holds while either one does: a flaw in
  the young lattice scheme still leaves X25519, and a quantum computer still leaves
  ML-KEM.
- **Why the code still stops someone in the middle.** The code covers the whole
  transcript, so it binds both sides' messages. Towards the new device, whatever someone
  in the middle sends (ciphertext, nonce) is fixed before they learn `nj`, which only the
  commitment shows; towards the old device, their key and `nj` are fixed (sent and
  committed to) before the old device's fresh ciphertext and `nh`. Neither code can be
  steered: one chance in 10^8 per session, as before. A changed ciphertext gives the new
  device another secret (ML-KEM rejects implicitly), so the codes differ and no frame
  opens; a swapped public key no longer opens the commitment.

### Wire changes

| Message | Before (mode 8, X25519) | Now (mode 10, X-Wing) |
|---|---|---|
| New → old (hello) | `[2, 8]` ‖ commitment (32) = 34 bytes | `[2, 10]` ‖ public key (1216) ‖ commitment (32) = 1250 bytes |
| Old → new | X25519 key (32) ‖ `nh` (32) = 64 bytes | ciphertext (1120) ‖ `nh` (32) = 1152 bytes |
| New → old (open) | X25519 key (32) ‖ `nj` (32) = 64 bytes | `nj` (32) |
| Labels | `cozysafe/p2p/v1/add-commit`, `p2p-add/key/…`, `p2p-add/code/…` | `cozysafe/p2p/v2/add-commit`, `p2p-add/v2/key/<T>`, `p2p-add/v2/code/<T>` |

All well under the 1 MiB frame limit. The protocol version byte stays 2 (sync between
devices of the vault is unchanged); the mode and the labels say which exchange it is,
so the two can never mix. The probe (mode 9) and its answer (the token) are unchanged.

### Compatibility

Both devices need this version; there is no fallback to X25519 alone.

- **Old app on the new device, new app adding it:** it still finds the old device (the
  probe did not change) and sends its mode 8 hello. The new app answers `[2, 10]` and
  ends the wait ("p2p add old version"); the old app, not getting its 64 bytes, ends at
  once too. Both screens show that it did not work, and neither waits for the 2 minutes
  to run out.
- **New app on the new device, old app adding it:** the old app does not know the hello
  and closes; the new app reads that as "p2p add old version" and ends at once. The old
  app counts it as a failed try and keeps waiting (as it does for any stranger).
- Both cases show the app's ordinary "could not" screen; there is no screen yet that says
  "update the app".

## Consequences

- About 2.4 KB more on the Wi-Fi per add, and ML-KEM's work (well under a millisecond on
  a phone).
- cs-net now depends on cs-identity (already in the app). ring stays, for TLS and the
  SHA-256 of the commitment and the transcript; its X25519 is no longer used.
- Forward secrecy as before: the X-Wing seed and the encapsulation randomness are thrown
  away after the session.

## Alternatives considered

- **The old device sends the public key, the new device encapsulates.** The new device
  would choose its ciphertext after seeing the old device's key and nonce, so someone in
  the middle could try ciphertexts until the code matched: the commitment would have to
  come before something the new device cannot know yet. The new device holding the key
  pair keeps one commitment and three messages.
- **X25519 and ML-KEM side by side, combined by our own HKDF.** Same strength in
  principle, but a combiner of our own; X-Wing's is named, analysed and already in the
  tree with its test vectors.
- **ML-KEM alone.** Rules out quantum computers, but leaves everything on a scheme a few
  years old; the project rule wants both families.
- **Keeping X25519 as a fallback for older apps.** A fallback is what an attacker in the
  middle would force; the window is short (both devices are in the person's hands and the
  app updates), so older apps are refused instead.
