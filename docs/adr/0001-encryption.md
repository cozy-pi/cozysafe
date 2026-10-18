# ADR 0001: Encryption scheme

- Status: accepted
- Date: 2026-10-18

## Context

Cozy Safe must give high security against anyone who obtains a copy of the
vault files (stolen device storage, cloud folder, sync relay, backup), make
changing a password easy, open the right vault from a single password field,
and run on five platforms from one Rust core.

## Decision

### Primitives

| Purpose | Choice | Crate |
|---|---|---|
| Password stretching | Argon2id (RFC 9106) | `argon2` |
| Authenticated encryption | XChaCha20-Poly1305 | `chacha20poly1305` (NCC Group audit, 2020) |
| Key derivation / domain separation | HKDF-SHA256 | `hkdf`, `sha2` |
| Share inbox (see below) | X25519 + HKDF + XChaCha20-Poly1305 | `x25519-dalek` |
| Randomness | OS CSPRNG | `getrandom` |
| Secret hygiene | zeroize on drop, `mlock` where the OS allows | `zeroize`, `region` |

Pure Rust, no C dependencies (cross-compiling libsodium/OpenSSL for five
platforms is the main thing we avoid). XChaCha20 over AES-GCM: 192-bit nonces
are safe to pick at random, and it is constant-time in software on CPUs
without AES instructions.

### Secret Key (mandatory)

Each library (the set of vaults on a user's devices) has a **Secret Key**:
128 random bits generated on the first device, stored in the platform
keystore (Keychain / Android Keystore / DPAPI / libsecret), never synced
through the vault transport.

- A copy of the vault files alone is useless to an attacker, even with a weak
  password: they would also need to guess 128 random bits.
- New device: scan a QR code from an unlocked device, or type the Secret Key
  from the **Emergency Kit** (a printable PDF made at setup, also shown in
  Settings). Setup does not finish until the user confirms the kit is saved.
- Losing every copy of the Secret Key **and** the password loses the data.
  The app says so at setup, as it does for the password.

### Key hierarchy

```
password ─┐
          ├─ Argon2id(salt_lib, params) ─► S ── HKDF(salt_vault) ─► KEK_vault
SecretKey ┘   (input: HKDF(SecretKey) ‖ password)                    │
                                                              wraps  ▼
                                    Master Key (MK, random 256 bit, one per vault)
                                      ├─ HKDF "index"  ─► metadata / search index key
                                      ├─ HKDF "sync"   ─► sync authentication key
                                      └─ wraps ─► Data Encryption Key per object (random)
biometrics ─ platform keystore (Secure Enclave / StrongBox) ─► wrapped copy of MK
```

- **Two-stage unlock.** Argon2id runs once per unlock with the library salt;
  each vault then costs one HKDF and one header decryption (microseconds).
  The whole time budget therefore goes into a single, stronger Argon2id run,
  whatever the number of vaults. Cost: an attacker holding the whole library
  tests one guess against all vaults at once (≤ log2(vault count) bits).
- **Argon2id parameters** are measured on the device at vault creation,
  targeting 1–1.5 s, with floors: phones m = 128 MiB, t = 3, p = 1; desktop
  m = 512 MiB, t = 3, p = 4. Parameters are stored in the header, so a slower
  device can still open the vault, only more slowly.
- **Imported vault** (from another library): unlocked once with its own salt,
  parameters and Secret Key, then MK is re-wrapped under this library.

### Content format

- Every object (note, file, photo, thumbnail, CRDT log segment) is a blob
  named by a random 128-bit ID. Names, types and timestamps live only inside
  encrypted metadata.
- Blobs are encrypted with their own DEK in **STREAM** mode (64 KiB chunks,
  nonce prefix + chunk counter + last-chunk flag). AAD binds vault ID, object
  ID and format version, so chunks cannot be reordered, truncated or moved
  between objects. Large files stream and allow random-access reads.
- Blob sizes are padded to buckets (Padmé), so storage and sync see only
  approximate sizes.
- The vault header carries a format version. Changing algorithms means a new
  version and a migration, never runtime negotiation.

### Password change

- **Change password** (default): verify the current password, check the new
  one, re-wrap MK under a new KEK. Takes under 2 s regardless of vault size.
  Biometric unlock keeps working (it holds MK, not the password).
- The header has a monotonically increasing revision. Other devices see the
  new header, ask for the new password once. Concurrent changes: the higher
  revision wins, the other device is told.
- **Rotate all keys** (when the user picks "I think it was exposed"): new MK
  and new DEKs, all objects re-encrypted in the background, resumable, old
  blobs deleted after the new ones sync. Changing only the password cannot
  stop someone who already has an old copy of the files and the old password,
  and the screen says so.
- Exported backups keep the password they were made with; the change screen
  says so.

### Password strength

Vault creation and password change refuse passwords below zxcvbn score 3. The
Secret Key protects stolen copies; the password still protects a stolen
device, where the Secret Key sits in the keystore.

### Share inbox (receiving content while locked)

Share extensions run in a separate process with tight memory (iOS: about
120 MB), too little for Argon2id and against the rule that nothing is
decrypted outside the app. Each vault therefore has an **inbox key pair**
(X25519). The public key is readable by the extension; the private key is
wrapped by MK. The extension encrypts incoming items to the public key
(ephemeral X25519 + HKDF + XChaCha20-Poly1305) and drops them in an inbox;
the app imports them on the next unlock. The extension never sees a vault
key or any vault content. A hybrid with ML-KEM can be added later through a
format version bump.

## Rejected

- **age / rage**: good for single files, but uses scrypt and has no model
  for notes, indexes or sync.
- **SQLCipher**: C dependency; a single database file conflicts badly under
  cloud-folder sync.
- **Cryptomator vault format**: file-only, no notes or records.
- **Per-vault Argon2id at unlock**: unlock time grows with the number of
  vaults, forcing weaker parameters.
- **Optional Secret Key**: most users would leave it off and stay exposed to
  offline guessing of the cloud copy.

## Consequences

- An independent audit before 1.0 covers this document and its code.
- Test vectors for every format version are committed and checked in CI on
  every platform.
- The Emergency Kit and QR device-add flows are part of v0.1, not later.
