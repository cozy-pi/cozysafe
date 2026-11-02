# Threat model

Who Cozy Safe protects against, and who it does not, as the code stands for the beta
(2026-11-02). The details and the reasons live in the linked pages; this page is the
summary to check a change against. `docs/security.md` says what is built, the ADRs say
why.

## What is protected

- **The vault's contents:** notes, photos, videos, recordings, files, their names and
  tags. Sealed with XChaCha20-Poly1305 under per-item keys, wrapped by the vault's Master
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
| Someone on the same Wi-Fi while a new device is added | Yes | X25519 with the new device committing first, and an 8-digit code typed on the new device: someone in the middle gets codes that do not match (one chance in 10^8 per try, and a failed session ends). Nothing crosses before the code and the vault password are right (ADR 0003, point 11). Accepted: they can learn that a device is being added, and can make the attempt fail. |
| Someone who guesses the password on an unlocked app | Slowed | Growing waits after wrong passwords; adding a device allows 3 tries per session. |
| A screenshot, a screen recording or the app switcher | Mostly | Screenshots and recordings come out black (on by default, Settings); the app switcher shows a cover. The 24 words are blocked from capture and from leaving the app. |
| A Top secret vault's contents leaking through the phone | Yes | In Top Secret Mode nothing in the vault is decoded in the app (no thumbnails, no previews); files leave only when exported, after a warning ([ADR 0006](adr/0006-top-secret-mode.md), [ADR 0007](adr/0007-mode-per-vault.md)). |
| A tampered library, lock or backup that makes guessing cheaper | Yes | An Argon2 cost below the phone floor is refused. |
| A hostile sync place rolling content back or exhausting memory | Yes | Records seal their content's hash; sizes are capped (ADR 0003, point 10). |
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
recordings are allowed (testers send them); every other vault stays protected. Builds for
everyone are made without it
(`release.yml`, `test_login`).

## When this page changes

A change that adds a way in or out of a vault (a new sync place, a new export, a new
unlock method) updates the table above in the same change.
