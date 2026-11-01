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
| Secret hygiene | zeroize on drop (no `mlock`: keys are not held in locked memory) | `zeroize` |

Pure Rust, no C dependencies (cross-compiling libsodium/OpenSSL for five
platforms is the main thing we avoid). XChaCha20 over AES-GCM: 192-bit nonces
are safe to pick at random, and it is constant-time in software on CPUs
without AES instructions.

### Secret Key (mandatory)

Each library (the set of vaults on a user's devices) has a **Secret Key**:
256 random bits generated on the first device (128 bits for libraries made before
2026-10-21), stored in the platform
keystore (Keychain / Android Keystore / DPAPI / libsecret), never synced
through the vault transport (the cloud folder never holds it).

- A copy of the vault files alone is useless to an attacker, even with a weak
  password: they would also need to guess 256 random bits.
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
- **Argon2id parameters** are fixed, not measured: a library made on a phone
  (iOS, Android) uses `KdfParams::PHONE_FLOOR`, m = 128 MiB, t = 3, p = 1; one
  made on a computer uses `DESKTOP_FLOOR`, m = 512 MiB, t = 3, p = 4
  (`params_for_this_device` in `app/rust/src/api/vault.rs`, `cs-crypto/src/kdf.rs`).
  They are chosen when the library is created and stored in `library.json`, so a
  slower device can still open it, only more slowly. There is one set per library:
  every vault shares the root derivation, so a new or changed wrap uses the library's
  stored parameters. Raising a phone-made library to the desktop floor would need
  per-vault parameters (not built).
- **Lanes on threads, computers only (2026-10-28).** On macOS, Windows and Linux the
  `argon2` crate's `parallel` feature (rayon, five more crates) runs the p = 4 lanes of
  `DESKTOP_FLOOR` on separate threads; before, they ran one after another on one core.
  The output is defined by p, not by the thread count, so no key changes (known-answer
  test `lanes_on_threads_give_the_same_root`). Release build, Apple M1: one
  `DESKTOP_FLOOR` derivation 850 ms → 280 ms; `PHONE_FLOOR` unchanged at ~190 ms.
  iOS and Android do not take the feature (p = 1 there gains nothing). The app's FFI
  crate also builds its dependencies optimised in debug builds, as the core does.
- **Lowest accepted cost (2026-10-25).** Opening a library, joining from a sync
  place (its lock file) and restoring a backup refuse parameters below `PHONE_FLOOR`
  with a clear error (`KdfTooWeak`): a tampered `library.json`, lock or backup could
  otherwise make each password guess cheaper. Upper bounds (4 GiB, t ≤ 32, p ≤ 16)
  were already checked, so a hostile file cannot exhaust memory either. Every library
  made by a released build used these floors, so no one is locked out. Tests use tiny
  parameters only through the `test-kdf` feature of cs-crypto, enabled from
  dev-dependencies; the app crate asserts at compile time that it has the real floor.
  Planned for format v2: bind the parameters into the associated data of the wraps,
  so changing them fails decryption instead of relying on this check. The on-disk
  format does not change for now.
- **Imported vault** (from another library): unlocked once with its own salt,
  parameters and Secret Key, then MK is re-wrapped under this library.

### Content format

- Every object (note, file, photo, thumbnail, CRDT log segment) is a blob
  named by a random 128-bit ID. Names, types, tags and contents live only inside
  sealed records and blobs. As built, the vault index (`vault.db`, SQLite) keeps
  each item's id, `created_ms`, `modified_ms`, `deleted_ms` and `size_bytes` in
  the clear, next to the sealed record (`core/cs-core/src/db.rs`); the files on
  disk show times and sizes anyway.
- Blobs are encrypted with their own DEK in **STREAM** mode (64 KiB chunks,
  nonce prefix + chunk counter + last-chunk flag). AAD binds vault ID, object
  ID and format version, so chunks cannot be reordered, truncated or moved
  between objects. Large files stream and allow random-access reads.
- Planned, not built: pad blob sizes to buckets (Padmé), so storage and sync see
  only approximate sizes. Today they see encrypted sizes within a few bytes.
- The vault header carries a format version. Changing algorithms means a new
  version and a migration, never runtime negotiation.

### Password change

- **Change password** (default): verify the current password, check the new
  one, re-wrap MK under a new KEK. Takes under 2 s regardless of vault size.
  Biometric unlock keeps working (it holds MK, not the password).
- As built, changing the password or the Recovery Key re-wraps only the vault's
  Master Key; no item is re-encrypted and item keys stay the same.
- Planned, not built: a monotonically increasing header revision (rollback
  protection). Other devices would see the new header and ask for the new password
  once; on concurrent changes the higher revision wins. Today a sync place keeps
  only the newest lock and never puts an older one back (ADR 0003), but nothing in
  the header itself stops an old copy from being shown again.
- **Rotate all keys**, planned (when the user picks "I think it was exposed"): new MK
  and new DEKs, all objects re-encrypted in the background, resumable, old
  blobs deleted after the new ones sync. Changing only the password cannot
  stop someone who already has an old copy of the files and the old password,
  and the screen says so.
- Exported backups keep the password they were made with; the change screen
  says so.

### Password strength

The Secret Key protects stolen copies; the password still protects a stolen
device, where the Secret Key sits in the keystore.

As built (2026-10-25, after NIST SP 800-63B rev 4, section 3.1.1.2), a **new**
password (new vault, setting or changing a password) must:

- have at least 8 characters;
- not be in a bundled list of the 100,000 most common passwords, checked
  case-insensitively, also after removing a short run of digits or symbols at the
  end and undoing simple leetspeak (0→o, 3→e, @→a, $→s and the like). The list is
  kept as truncated hashes only (docs/supply-chain.md, bundled data);
- and either reach zxcvbn score 3, or be a passphrase of at least 4 different words
  of 3 or more characters.

The app says why a password is refused and suggests 4 random words; "Suggest a
password" fills 5. Existing passwords are never checked on unlock, so no vault is
locked out.

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
- **Text form now** (2026-10-21): new keys are 256 bits, written as 24 BIP39 English
  words with their 8 checksum bits; `CS1-…` keys still read.
- **Fingerprint:** `library.json`, cloud locks and backups store 16 bits (4 hex
  characters) of HKDF(Secret Key), so a wrong Recovery Key is told apart from a wrong
  password. Libraries before 0.1.68 stored 64 bits (16 hex): they are still accepted
  by comparing their first 4 characters, and shortened the next time the library
  opens. It is a hint, never authentication: opening is the AEAD unwrap, and a wrong
  key that matches by chance still fails to unwrap. 16 bits also tell an attacker
  too little to confirm a guessed key.
- First-preview installs kept the key in a `secret-key` file; the app reads it
  once, stores it in the keystore, reads it back, and only then overwrites and
  deletes the file.

### Biometric unlock (built)
Rust wraps the vault's Master Key with a random key K (`vaults/<id>/biometric`).
K lives in the keystore behind biometrics: Keychain with `biometryCurrentSet`
(a changed enrolment invalidates it), Android Keystore with strong biometrics
and a fresh check per read. Neither half opens the vault alone. One vault per
device; on by default for the first vault. A lost K (biometrics changed) removes
the wrapped copies and falls back to the password.

**Touch ID on a Mac (2026-10-28).** The keychain item above would need the
data-protection keychain and a provisioning profile on macOS. Instead K is wrapped by a
CryptoKit Secure Enclave P-256 key (`privateKeyUsage` + `biometryCurrentSet`, this
device only): ECDH with a one-off key, HKDF-SHA256, AES-GCM. The enclave key is kept as
CryptoKit's opaque blob, usable only by this Mac's enclave, inside the wrapped blob, and
the whole blob sits in the legacy keychain. No entitlement or profile. Unwrapping needs
Touch ID; a changed enrolment makes the enclave key unusable and the app falls back as
on a phone. Details: docs/security.md, "Touch ID on a Mac".

### PIN unlock (built, then retired 2026-10-28)
**Retired:** the app no longer offers a PIN (decisions 2026-10-28; docs/security.md, "No
PIN"). The chip key wrapping the device key has no user-presence check, so on an
unlocked phone under full control the device key can be taken once and 6-digit PINs
tried off the phone. Vaults now open with biometrics or the password; PIN files of
vaults with a password are removed (`Library::forget_pins_with_password`). The core
keeps what follows for vaults made with only a PIN.

Digits only, this device only: at least 6 for a new PIN (4 or 5 digits set before
2026-10-23 still unlock). `vaults/<id>/pin` holds the Master Key wrapped by
HKDF(Argon2id(PIN, device key, salt)) with the device's floor parameters. The device
key is one per device (`PinStore.deviceKeyOrCreate`, keystore item `pin-device-key`,
this device only): 32 random bytes, made the first time any PIN is set and reused by
every vault's PIN after that, never replaced (devices that set a PIN before
2026-10-21 keep a 16-byte one). Copying vault files elsewhere makes the PIN useless;
the device key without the PIN is useless too.

Wrong tries are counted by the app in the keystore (`PinStore.addFail`): 4 free, then
the pad waits 1 minute after the 5th, 5 after the 6th, 15 after the 7th and 1 hour
after each one beyond, on a clock the phone's date cannot move (`TryWait`: the time
left, spent only while the app runs, by the smaller of wall and monotonic time). A
right PIN resets the count. At 10 in a row the PIN copies are removed
(`Library::forget_pin`) if the vault has a password; otherwise only the waits apply.
Since 0.1.76 the device key is kept wrapped by a key in the secure hardware (Secure
Enclave, Android Keystore/StrongBox; `lib/hw_key.dart`), so extracting the keystore no
longer allows trying PINs offline (before: about 1–2 hours for 4 digits, days for 6).
The count itself is still enforced by the app, not by the hardware. Users can turn the
PIN off and use only the password and biometrics.

### Backup file (built)
One streaming file: `COZYSAFE-BACKUP1`, then per file a 16-bit path length, the
path, a 64-bit size and the bytes, ended by a zero length and the file count.
It carries `library.json`, vault headers and items (all already encrypted or
public) and leaves out device-only data (biometric and PIN copies, the
first-preview key file). Restore accepts only the exact path shapes a library
has, writes into a staging folder, and moves it into place only when the whole
file checked out.

