# Security rules for the app

Rules every screen follows, so that someone who picks up an unlocked phone, or a person
or camera looking over a shoulder, gets as little as possible. Check this page when
adding a screen, a setting or anything that shows a secret. Encryption itself is in
[ADR 0001](adr/0001-encryption.md); libraries and the network in
[supply-chain.md](supply-chain.md).

## Security settings ask for the owner

Anything that weakens or reveals the vault's protection asks for Face ID, fingerprint or
the phone's passcode first (`confirmOwnerForSetting` in `app/lib/biometric.dart`), every
time, wherever it is opened from:

| Setting | Where the check is |
|---|---|
| Face ID / fingerprint on or off | `vault_home.dart` `_toggleBiometric` |
| Change PIN | `settings.dart` (`_guarded`) |
| Auto-lock time | `settings.dart` (`_guarded`) |
| Block screenshots (off only: turning it on only makes the vault safer) | `settings.dart` (`_guarded`) |
| Hide note text: turning it off (lists and search would show it) | `settings.dart` (`_guarded`) |
| Back up to a file | `vault_home.dart` `_backup` |
| Backup password (set or change) | `vault_home.dart` `_password` (also the reminder banner) |
| Recovery Key (shows the 24 words): Face ID, **then the vault password** (`KitPasswordScreen`, wrong tries share the lock screen's waits) | `vault_home.dart` `_showKit` |
| Blur thumbnails (off only) | `settings.dart` (`_guarded`) |
| Delete this vault | `settings.dart` (`_guarded`), then the vault's PIN |
| New vault | `confirmOwner` (lock screen and vault) |

A new security setting gets the same check in the same commit, and a row in this table.
Limit: on a device with no biometrics and no passcode support (`local_auth` reports it
unsupported, e.g. Linux), the system check cannot run and is skipped.

## Secrets on screen

- **Never shown by default.** The Secret Key (Emergency Kit) is masked (`SecretText`):
  always the same 16 dots (the mask does not tell the key's length), a Show button, hidden again after 30 seconds, whenever the
  app leaves the foreground and when the vault locks. The page itself stays under the
  lock screen (opening the vault comes back to it); passwords and PINs typed on such a
  page are cleared on lock (`lib/lock_resume.dart`).
- **Password and key fields are hidden while typed** (`SecretField`), with an eye to
  show them; this includes a suggested passphrase, which appears hidden.
- **Note text stays out of lists.** The notes list and search show titles and dates only;
  search says "Found in the text" instead of quoting it. Settings → Display can show it
  (owner check to turn on).
- **Text files are read in memory.** txt, md, json and other text files open inside the
  app from decrypted bytes, never written to a file; copying from them is wiped like
  any copy (`file_view.dart`, `_textView`).
- **Debug mode is hidden and harmless.** Seven taps on the version in Settings → About,
  then the owner check. It shows technical facts (build, device, biometrics, whether the
  network guard is on, item counts, temporary copies) and can clear temporary copies; it
  never shows keys, PINs, passwords or vault content, and changes no protection.
- **Big files are not loaded whole.** Text previews decrypt only their first 1 MB
  (`item_content_head`); photos decode at screen size; PDFs over 40 MB open from a private
  temporary copy deleted on close, on lock and at start.
- **Thumbnails are blurred** in lists by default, for crowded places (Settings → Display);
  opening an item shows it clearly. Turning it off asks for the owner.
- **Screen capture.** Android: screenshots and recordings show black (FLAG_SECURE, on by
  default). iOS has no official switch: the app window's layer sits inside a secure text
  field's layer (AppDelegate `applySecure`, same switch, on by default), which iOS leaves
  out of screenshots and recordings, as banking and dating apps do. It is undocumented,
  so the older guards stay: while the screen is recorded or mirrored the app is covered
  (page colour and dial), and after a screenshot the app warns that it is in Photos,
  unencrypted. Turning the switch off (owner check) allows screenshots for bug reports.
- PINs show as dots only, one per digit, no count of the remaining digits.
- **Copied secrets are wiped:** anything copied out (`LockGuard.copied`) is removed from
  the clipboard after 60 seconds and when the vault locks.
- `test/secret_test.dart` checks the hiding.

## How strong is it? Compared with a Bitcoin wallet

What an attacker needs, as the code stands (2026-10-21). "Recovery Key" is the Secret
Key as people see it (it was the Emergency Kit); "vault password" was the backup password.

| | Bitcoin, 12 words | Bitcoin, 24 words | Cozy Safe |
|---|---|---|---|
| Random key | 128 bits | 256 bits | 256 bits as 24 BIP39 words (libraries before 21 Oct 2026: 128 bits) |
| Opens with | the words alone | the words alone | Recovery Key **and** vault password **and** the files |
| Cost per guess | low (PBKDF2, 2048 rounds) | low | Argon2id, 128 MiB × 3 passes on phones (512 MiB on computers) |
| Extra password | optional ("25th word") | optional | mandatory, zxcvbn score ≥ 3 |

By case:

- **Nothing in hand:** both out of reach (2¹²⁸ or more).
- **The words / the Recovery Key leak** (someone reads the paper): a Bitcoin wallet is
  emptied at once; a Cozy Safe vault still needs the vault password, each guess costing
  an Argon2id run.
- **A backup file leaks** (from a cloud folder): without the Recovery Key it cannot be
  attacked at all (2¹²⁸).
- **Recovery Key and backup both leak:** only the password remains; a password at the
  minimum score is our estimate of weeks to years for one machine (not measured).
- **The real weak spot today is the PIN on the phone**, not the Recovery Key: wrong-PIN
  waits exist only in the app, the PIN copy is not removed after many tries (`forget_pin`
  exists but the app never calls it), and the device key is not bound to the secure
  hardware. An attacker who extracts the keychain/keystore could try all PINs offline.
  Planned: remove the PIN copy after 10 wrong tries; bind the device key to the Secure
  Enclave / StrongBox.

Compared with a hardware wallet (Ledger, Trezor): the same 24 BIP39 words once the
Recovery Key is 256-bit. A hardware wallet keeps its key inside a secure chip that never
lets it out, which a phone app cannot match; but its 24 words alone empty the wallet,
while the Recovery Key alone opens nothing without the vault password.

In short: the key alone is as strong as a 12-word wallet (24-word after the move); the whole scheme is harder to
break than a Bitcoin wallet, because two independent secrets are needed and guessing the
password is deliberately expensive.

## Quantum computers

- Shor's algorithm breaks public-key cryptography (RSA, elliptic curves: signatures, key
  exchange). **Cozy Safe uses none**: no server, no sync, no key exchange. (Bitcoin signs
  with elliptic curves, so exposed public keys are at risk; Cozy Safe has no such part.)
- Grover's algorithm halves the strength of symmetric keys. Everything here is symmetric:
  XChaCha20-Poly1305, HKDF-SHA256, Argon2id.
  - Master Keys and item keys are 256-bit: about 128-bit against a quantum attacker. Safe.
  - The Recovery Key is 256-bit (24 BIP39 words) since 2026-10-21: about 128-bit against
    Grover. Libraries made before keep a 128-bit key (about 64-bit against Grover in
    theory); there are no users yet, so the owner's test libraries are the only ones.
  - Password guessing goes through Argon2id (128 MiB per try); running that inside a
    quantum computer is not realistic.
- **When sync between devices comes (v0.2 cloud folder needs no key exchange; v0.3 server
  or P2P may):** any key exchange must be post-quantum (ML-KEM, possibly hybrid with
  X25519), never classical alone.
