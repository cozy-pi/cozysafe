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
| Lock as soon as I leave the app (off only; on by default) | `settings.dart` (`_guarded`) |
| Block screenshots (off only: turning it on only makes the vault safer) | `settings.dart` (`_guarded`) |
| Back up to a file | `vault_home.dart` `_backup` |
| Backup password (set or change) | `vault_home.dart` `_password` (also the reminder banner) |
| Recovery Key (shows the 24 words): Face ID, **then the vault password** (`KitPasswordScreen`, wrong tries share the lock screen's waits) | `vault_home.dart` `_showKit` |
| Blur thumbnails (off only) | `settings.dart` (`_guarded`) |
| Delete this vault | `settings.dart` (`_guarded`), then the vault's PIN |
| New vault | `confirmOwner` (lock screen and vault) |

A new security setting gets the same check in the same commit, and a row in this table.
Limit: on a device with no biometrics and no passcode support (`local_auth` reports it
unsupported, e.g. Linux), the system check cannot run and is skipped.

## Leaving the app

- **Leaving locks at once** by default (`vault_home.dart`, `didChangeAppLifecycleState`),
  except for 60 s when the app itself opened a picker, the camera or the share sheet
  (`LockGuard.allowAway`).
- **"Lock as soon as I leave the app" off** (owner check to turn off): the vault stays
  open in the background and locks once it has been away for the auto-lock time, counted
  from the moment it left, not from the last touch. Time away is the longer of a
  monotonic clock (moving the phone's date and time cannot change it) and the wall clock
  (which keeps counting while the phone sleeps): setting the clock back can only make it
  lock sooner (`AwayClock`, `lib/lock_guard.dart`). If the app still runs at that mark,
  it locks then; otherwise it locks on return, before anything shows.
- **The app switcher never shows the vault**, whatever this setting: iOS covers the
  window whenever the app is not active (AppDelegate); Android hides it from Recents with
  FLAG_SECURE and, on Android 13+, `setRecentsScreenshotEnabled(false)` even when
  screenshots are allowed (MainActivity). Android 12 and older with screenshots allowed
  can still show a Recents preview.

## Secrets on screen

- **Never shown by default.** The Secret Key (Emergency Kit) is masked (`SecretText`):
  always the same 16 dots (the mask does not tell the key's length), a Show button, hidden again after 30 seconds, whenever the
  app leaves the foreground and when the vault locks. The page itself stays under the
  lock screen (opening the vault comes back to it); passwords and PINs typed on such a
  page are cleared on lock (`lib/lock_resume.dart`).
- **Password and key fields are hidden while typed** (`SecretField`), with an eye to
  show them; this includes a suggested passphrase, which appears hidden.
- **Note text is hidden in lists** ("Hide note text", on by default; turning it off asks
  for the owner): lists and search show a note's title only, so someone beside you
  cannot read it off the list. Opening a note is done on purpose, so an opened note
  always shows in full (0.1.68; 0.1.67 briefly removed the setting).
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
- **Thumbnails are blurred** in lists by default, for crowded places (Settings → Security);
  opening an item shows it clearly. Turning it off asks for the owner.
- **Screen capture.** Android: screenshots and recordings show black (FLAG_SECURE, on by
  default). iOS has no official switch: the app window's layer sits inside a secure text
  field's layer (AppDelegate `applySecure`, same switch, on by default), which iOS leaves
  out of screenshots and recordings, as banking and dating apps do. It is undocumented,
  so the older guards stay: while the screen is recorded or mirrored the app is covered
  (page colour and dial), and after a screenshot the app warns that it is in Photos,
  unencrypted. Turning the switch off (owner check) allows screenshots for bug reports.
- **Links in notes ask first, and only reach the web** (0.1.67). A web address in a
  note (`http://`, `https://`, `www.`; `lib/note_format.dart`) is underlined and does
  nothing until tapped; the tap opens a card naming the host and the full address, with
  Cancel and Open (`confirmOpenLink`). An international host is shown in its punycode
  form (`bücher.de` → `xn--bcher-kva.de`, RFC 3492 in Dart), so a look-alike with a
  Cyrillic letter cannot pass for the real site. Only http and https with a host ever
  leave the app, as plain ASCII; `javascript:`, `file:`, `intent:`, `data:` and app
  schemes are refused in Dart (`safeLink`) and again natively (`openExternal` on the
  `cozysafe/privacy` channel, `MainActivity.kt` and `AppDelegate.swift`; Android also
  limits it to browsable apps). Our own pages keep their own door (`openUrl`,
  `https://safe.cozypi.com` only). The app fetches nothing for a link (no previews, no
  network); leaving for the browser gives the same 60 seconds before the vault locks as
  the share sheet.
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
| Extra password | optional ("25th word") | optional | mandatory: 8+ characters, not a common password, zxcvbn score ≥ 3 or 4+ words |

By case:

- **Nothing in hand:** both out of reach (2¹²⁸ or more).
- **The words / the Recovery Key leak** (someone reads the paper): a Bitcoin wallet is
  emptied at once; a Cozy Safe vault still needs the vault password, each guess costing
  an Argon2id run.
- **A backup file leaks** (from a cloud folder): without the Recovery Key it cannot be
  attacked at all (2¹²⁸).
- **Recovery Key and backup both leak:** only the password remains; a password at the
  minimum score is our estimate of weeks to years for one machine (not measured).
- **The error log** (Settings → Report a problem) keeps the last 200 failures as a time,
  a place and a fixed code (`drive-full`, `io-timed-out`), in a plain file beside the
  preferences: no names, content, keys, paths or network data, so it can be copied into
  a message. The core notes its codes (`api/errors.rs`), Dart reduces every word to
  letters, digits and '-' before writing (`error_log.dart`).
- **The PIN on the phone** (since 0.1.76, owner 2026-10-26): the device key (32 random
  bytes, one per device, shared by every vault's PIN) is kept only wrapped by a key made
  inside the phone's secure hardware (`lib/hw_key.dart`: a Secure Enclave P-256 key with
  ECIES on iPhone, an Android Keystore AES-GCM key, StrongBox where there is one), so a
  copy of the keychain/keystore taken off the phone cannot be used to try PINs: every
  guess has to go through this phone's chip. Keys from before move in on first use;
  where there is no such hardware (simulators, desktops) the key stays as before. Waits
  after wrong PINs (4 free tries, then 1, 5, 15 minutes, then 1 hour each) keep the time
  left, which goes down only while the app runs and by the smaller of the wall clock and
  a monotonic one: moving the date cannot shorten them. At 10 wrong PINs in a row the PIN
  copies are removed (`forget_pin`) when the vault has a password to open with; a vault
  without one keeps its PIN and the waits. Still not like a hardware wallet: the attempt
  count is kept by the app, so someone with the unlocked phone and full control of it
  could try PINs there, slowly (each costs an Argon2id run).

Compared with a hardware wallet (Ledger, Trezor): the same 24 BIP39 words once the
Recovery Key is 256-bit. A hardware wallet keeps its key inside a secure chip that never
lets it out, which a phone app cannot match; but its 24 words alone empty the wallet,
while the Recovery Key alone opens nothing without the vault password.

In short: the key alone is as strong as a 12-word wallet (24-word after the move); the whole scheme is harder to
break than a Bitcoin wallet, because two independent secrets are needed and guessing the
password is deliberately expensive.

## Passwords (2026-10-25)

A new password (new vault, setting or changing one) is checked as NIST SP 800-63B rev 4
(section 3.1.1.2) asks: at least 8 characters; not one of the 100,000 most common
passwords (a bundled list, compared case-insensitively, also after removing a short run
of digits or symbols at the end and undoing simple leetspeak such as 0→o, 3→e, @→a,
$→s); and either zxcvbn score 3 or a passphrase of at least 4 different words of 3 or
more characters. The app says why a password is refused and suggests 4 random words
("Suggest a password" fills 5). A password already in use is never checked when
unlocking: no vault gets locked out. Details in [ADR 0001](adr/0001-encryption.md).

## What is on disk, and what is not

- **Sealed:** item names, kinds, tags, note text and file contents (each item's record
  and blobs, XChaCha20-Poly1305).
- **In the clear in `vault.db`** (the SQLite index, `core/cs-vault/src/db.rs`): each
  item's id, when it was created, modified and deleted (ms), and its size. The files on
  disk show times and sizes anyway.
- **Not built:** size padding (Padmé), so sizes are exact within a few bytes; a
  monotonic header revision against rollback; locked memory (`mlock`). Keys are wiped
  from memory when dropped (`zeroize`), but may be paged out before that.
- **Key changes:** changing the password or the Recovery Key re-wraps only the vault's
  Master Key. Items are not re-encrypted; rotating item keys is planned.
- **The Secret Key fingerprint** in `library.json`, cloud locks and backups is 16 bits
  (4 hex characters; older 16-hex values are compared by their first 4). It only tells a
  wrong Recovery Key from a wrong password and is never used to unlock.
- **Argon2 cost** is fixed per library (128 MiB × 3 passes on phones, 512 MiB × 3 passes,
  4 lanes on computers). A library, sync lock or backup naming less than the phone floor
  is refused, so a tampered file cannot make guessing cheaper.

## OS backups

The library is kept out of the system's own backups (2026-10-25). iOS: the library
folder (Application Support) is marked excluded from iCloud and iTunes backup
(`NSURLIsExcludedFromBackupKey`, set at start). Android: `allowBackup="false"`, plus
`dataExtractionRules` (Android 12 and later) and `fullBackupContent` that exclude
everything, so neither cloud backup nor device-to-device transfer copies it. The files
are sealed, but a cloud copy would outlive a deleted vault and be one more place to
attack. Moving a vault is done by the app's own backup file or sync.

## Syncing with a nearby device

(Details: [ADR 0003](adr/0003-sync.md), "P2P security".)

- **Nothing connects on its own.** The person opens Sync → Sync with a nearby device and
  allows looking on this Wi-Fi, by address, each time; the wait ends after 5 minutes or
  when the page closes.
- **Both people confirm, comparing a number** (0.1.73), like Bluetooth pairing: both
  screens ask "Sync with iPhone 15 Pro Max?" next to the same 3-digit number, and nothing
  is served until both tapped Sync; Cancel on either stops both. Strangers are already
  kept out by the vault's key (they can neither find this device nor finish a
  handshake); the number makes sure the person syncs with the device they mean, when
  several hold the vault.
- **Names only after the proof.** A device's name (its model, never the name its owner
  gave it) crosses only inside the sealed channel, after both proved the vault; a probe's
  answer holds no name and no stable id. Names from the other device are cleaned before
  they are shown or logged.
- **A new phone restoring** (24 words and password only) finds a device waiting on its
  nearby screen; nothing is sent before the person there taps Allow (same number on both
  screens). Then it gets only the vault's lock, and must prove it opened it (a key
  confirmation from the Master Key over this session) before a single item is served. A
  wrong password stops both devices with the lock alone sent.

## Quantum computers

- Shor's algorithm breaks public-key cryptography (RSA, elliptic curves: signatures, key
  exchange). **The vault uses none**: no server and no key exchange; P2P sync keys come
  from the vault's Master Key or the Recovery Key by HKDF. (Google Drive is reached over
  TLS, but what goes there is already sealed. Bitcoin signs with elliptic curves, so
  exposed public keys are at risk; Cozy Safe has no such part.)
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
