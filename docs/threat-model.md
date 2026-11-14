# Threat model

Who Cozy Safe protects against, and who it does not, as the code stands for the beta
(reviewed 2026-11-14). The details and the reasons live in the linked pages; this page is the
summary to check a change against. `docs/security.md` says what is built, the ADRs say
why.

## What is protected

- **The vault's contents:** notes, photos, videos, recordings, files, logins, two-factor
  keys and recovery codes ([ADR 0009](adr/0009-secure-items.md)), their names and tags,
  and the earlier versions the device keeps of them. Sealed with XChaCha20-Poly1305 under per-item keys, wrapped by the vault's Master
  Key ([ADR 0001](adr/0001-encryption.md)).
- **The keys:** the Master Key is wrapped by the vault password **and** the 24-word
  Recovery Key (Argon2id, 128 MiB × 3 passes on phones). Neither alone opens anything.
- **Not protected, by design:** that the app is installed, how many vaults a device holds
  and their sizes, when items were made and changed, and their sizes (the clear columns of
  the index, `docs/security.md`, "What is on disk").

## Who, and what stops them

| Who | Protected | How |
|---|---|---|
| Someone holding the locked phone | Yes | Nothing opens without the vault password, or Face ID / fingerprint set for one vault on that phone (the key behind biometrics is useless off the device). The lock screen shows nothing of the vault. |
| Someone who learns the 24 words | Yes | The vault password is still needed, each guess costing an Argon2id run. |
| Someone with a copy of the files (stolen phone backup, a cloud folder, a backup file) | Yes | Needs the 24 words and the password. Vaults are kept out of iCloud and computer backups; on iPhone, iOS Data Protection also locks the files while the phone is locked (`docs/security.md`, "Files at rest on an iPhone"). |
| Google Drive (or anyone with the Drive account) | Yes | Sees sealed files only, their sizes and times. The app's Drive access (`drive.file`) reaches only what the app itself wrote. |
| Someone on the same Wi-Fi during a sync between two devices of the vault | Yes | Only a device holding the vault can pair; every frame is sealed and numbered ([ADR 0003](adr/0003-sync.md), P2P security). |
| Someone on the same Wi-Fi while a new device is added | Yes | X-Wing (ML-KEM-768 with X25519: a recording cannot be opened later by a quantum computer) with the new device committing first, and an 8-digit code typed on the new device: someone in the middle gets codes that do not match (one chance in 10^8 per try, and a failed session ends). Nothing crosses before the code and the vault password are right (ADR 0003, point 11; [ADR 0010](adr/0010-post-quantum-device-add.md)). Accepted: they can learn that a device is being added, and can make the attempt fail. |
| Someone who guesses the password on the lock screen or in an open vault | Slowed | 9 wrong passwords are free, then growing waits (1, 5, 15, 60 minutes) on a clock the phone's date cannot move, counted in one place for every page that takes the password (lock screen, Recovery Key, Check your words, Delete vault). A password tried while it is typed counts too, even when the app is closed on it. Adding a device allows 3 tries per session. The count is the app's: on a phone under full control (root, jailbreak) it can be reset, and each guess then costs only its Argon2id run. |
| A screenshot, a screen recording or the app switcher | Mostly | The app switcher always shows a cover. Screenshots and recordings are allowed by default, with a warning after one (owner 2026-11-04); they come out black in a Top secret vault, or when "Block screenshots" is on (Settings). The 24 words are blocked from capture whatever the setting. |
| Another app reading the clipboard | Mostly | A copied password, code or the 24 words is marked sensitive on Android (not in the preview, not kept by keyboards), stays on this device and expires by itself on iPhone and Mac; the words go after 60 s and on lock. Other copied text is wiped after 60 s and on lock. Until then, an app in front can read it: the clipboard is the system's. |
| Someone with the Apple or Google account | Partly | By default the 24 words of an everyday vault are also kept in iCloud Keychain or Google Block Store, and its password can be saved in the system's password manager: both under the account's own protection, both optional, neither for a Top secret vault. Each alone opens nothing; someone holding the account **and** a copy of the vault's files (the same account's Google Drive, a backup file) has everything. Turn both off, or use a Top secret vault, when the account itself is not trusted. |
| A Top secret vault's contents leaking through the phone | Yes | In Top Secret Mode nothing in the vault is decoded in the app (no thumbnails, no previews); files leave only when exported, after a warning ([ADR 0006](adr/0006-top-secret-mode.md), [ADR 0007](adr/0007-mode-per-vault.md)). |
| A tampered library, lock or backup that makes guessing cheaper | Yes | An Argon2 cost below the phone floor is refused. |
| A hostile sync place rolling content back or exhausting memory | Yes | Records seal their content's hash; an older revision or deletion read late never replaces a newer one; a journal entry held back stops that journal until it shows, and is never passed over; sizes are capped while read (ADR 0003, point 10). Accepted: it can stall a sync by withholding. |
| A compromised dependency | Partly | The core and the network's cryptography are built from copies checked byte for byte; every crate is audited or exempted in cargo-vet; scanners run on every release (`docs/supply-chain.md`). |

## Out of scope

- **Malware on the device**, or an operating system that is compromised (it sees what
  the app shows and what is typed).
- **Someone who forces the owner to unlock.** There is no hidden vault: the device shows
  how many vaults it holds.
- **Losing both the 24 words and the password.** No one, not even us, can open the vault
  then.
- **Memory attacks on an unlocked phone.** Keys are wiped when dropped, but memory is not
  locked and may be paged out.

## Test builds

Android builds for testers have **Test sign-in**: a test vault whose password is fixed
(`123456789`), for trying the app only. Anyone holding that phone opens the test vault;
its note says never to keep anything real in it. While it is open, screenshots and
recordings are allowed (testers send them); every other vault stays protected. Only the
Google Play bundle for closed testing can carry it (`release.yml`, `test_login`); the APK
on the release page, the public download, is always built without it (`build.yml`). A
bundle promoted to production must come from a run with `test_login` off.

## When this page changes

A change that adds a way in or out of a vault (a new sync place, a new export, a new
unlock method) updates the table above in the same change.
