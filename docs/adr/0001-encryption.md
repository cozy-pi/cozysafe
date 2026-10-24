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
through the vault transport (the cloud folder never holds it).

- A copy of the vault files alone is useless to an attacker, even with a weak
  password: they would also need to guess 128 random bits.
- **Key sync, on by default (opt-out).** The Secret Key is also saved to the
  platform's end-to-end encrypted credential sync: iCloud Keychain
  (`kSecAttrSynchronizable`) on Apple platforms, Google Password Manager via
  Credential Manager on Android. A reinstall or a new phone on the same
  account needs only the password. An attacker now needs the vault copy,
  the user's Apple/Google account and a correct guess of a strong password.
  Users who want the strictest mode turn key sync off in Settings; the
  synced copy is then deleted.
- New device without key sync (desktop, other account, sync off): scan a QR
  code from an unlocked device, or type the Secret Key from the **Emergency
  Kit** (a printable PDF made at setup, also in Settings). Setup asks the user
  to type the last 4 characters of the key from the saved kit, and the app
  asks again every few months.
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
- **Secret Key only on devices + Emergency Kit** (no key sync): strongest, but
  ordinary users lose paper kits; one lost kit plus a lost phone means lost
  data. Kept as the opt-out mode instead of the default.
- **Password only**: simplest, but a leaked cloud copy can be guessed
  offline; relies entirely on password strength.

## Consequences

- An independent audit before 1.0 covers this document and its code.
- Test vectors for every format version are committed and checked in CI on
  every platform.
- The Emergency Kit and QR device-add flows are part of v0.1, not later.

## As built for v0.1 (2026-10-19)

v0.1 is single-device (no sync), which changes three things for now:

- **Secret Key storage:** this device's keystore only (Keychain
  `first_unlock_this_device`, not synchronizable; Android Keystore; Windows
  credential store; libsecret; the legacy macOS keychain, which needs no
  provisioning profile for Developer ID builds). **Key sync is deferred to
  v0.2** with sync itself; until then the Emergency Kit is the only copy that
  leaves the device. Rust never stores the key; the app hands it over at start.
- **Text form** for the Emergency Kit: `CS1-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`,
  26 Crockford base32 characters for 128 bits plus 2 check characters (10 bits of
  SHA-256), case-insensitive, I/L read as 1 and O as 0. Kit is a screen with copy
  and share, confirmed by typing the last 4 characters (PDF and periodic re-check
  later).
- **Fingerprint:** `library.json` stores 64 bits of HKDF(Secret Key) so a wrong
  key is reported as such instead of failing every password. Not secret: it is a
  one-way function of 128 random bits.
- First-preview installs kept the key in a `secret-key` file; the app reads it
  once, stores it in the keystore, reads it back, and only then overwrites and
  deletes the file.

### Biometric unlock (built)
Rust wraps the vault's Master Key with a random key K (`vaults/<id>/biometric`).
K lives in the keystore behind biometrics: Keychain with `biometryCurrentSet`
(a changed enrolment invalidates it), Android Keystore with strong biometrics
and a fresh check per read. Neither half opens the vault alone. One vault per
device; on by default for the first vault. A lost K (biometrics changed) removes
the wrapped copies and falls back to the PIN or password.

### PIN unlock (built)
4 to 10 digits, this device only. `vaults/<id>/pin` holds the Master Key wrapped
by HKDF(Argon2id(PIN, device key, salt)), where the device key is 128 random bits
in the keystore, replaced every time a PIN is set. Copying vault files elsewhere
makes the PIN useless; the device key without the PIN is useless too. The app
counts wrong tries in the keystore and forgets the PIN after 5. Weakness, accepted
for a consumer app: the count is enforced by the app, not by secure hardware, so
someone with the unlocked phone and a jailbreak could try all PINs on that phone
(about 1–2 hours for 4 digits, days for 6, at ~0.5 s per Argon2id run). Users can
turn the PIN off and use only the password and biometrics.

### Backup file (built)
One streaming file: `COZYSAFE-BACKUP1`, then per file a 16-bit path length, the
path, a 64-bit size and the bytes, ended by a zero length and the file count.
It carries `library.json`, vault headers and items (all already encrypted or
public) and leaves out device-only data (biometric and PIN copies, the
first-preview key file). Restore accepts only the exact path shapes a library
has, writes into a staging folder, and moves it into place only when the whole
file checked out.


## Since v0.1 (2026-10-21 to 2026-10-24)

What changed after the text above; the sections above are kept as decided.

- **Recovery Key** (the Secret Key as people see it, was the Emergency Kit): 256 random
  bits shown as 24 BIP39 words (`cs-crypto/src/secret_key_text.rs`). Libraries made before
  2026-10-21 keep their 128-bit `CS1-` key, which still reads. It still stays in this
  device's keystore only (`synchronizable: false`); key sync through iCloud Keychain or
  Google Password Manager is not built.
- **The Recovery Key can be changed** (`Library::change_secret_key`, `finish_key_change`):
  only the vault's Master Key wrap changes; no item is re-encrypted. Crash-safe order:
  the vault keeps its old wrap beside the new one and the library accepts both keys, then
  the keystore takes the new key, then opening with it drops the old ones. Backups made
  before keep needing the old key. Deleting the last vault forgets the key on the device
  (`reset_if_empty`), so the next vault starts with a new one.
- **PIN:** new PINs have at least 6 digits (4–5 digit PINs from before keep working). The
  app does not forget the PIN after 5 wrong tries: from the fifth it makes you wait 1, 5,
  15, then 60 minutes (`secret_key_store.dart`); `forget_pin` exists but the app does not
  call it (see `docs/security.md`, "How strong is it?").
- **Vault password:** at least 8 characters; its zxcvbn strength is shown, a weak one is
  allowed (no longer refused below score 3).
- **Sync** (ADR 0003) carries only sealed files. The place keeps the vault's newest lock
  (header, library salt, Argon2 cost, key fingerprint), which with the Recovery Key and
  the vault password lets a new device join; an older lock is removed, so an old password
  or key stops opening the copy there. P2P keys are derived from the Master Key; there is
  no key exchange.
