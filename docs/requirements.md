# Requirements and roadmap

## Product

Cozy Safe is an encrypted vault for notes, files and photos. It is a product of
[Cozy Pi](https://cozypi.com) and is fully open source.

### Core promises

- **Encrypted on device.** Everything is encrypted before it touches disk, a
  cloud folder, a peer or a server. Sync transports only ever see ciphertext.
- **Multiple vaults, one password each.** Every vault has its own password and
  its own encryption keys. Knowing one password gives no access to another vault.
- **No recovery.** There is no password reset, no recovery e-mail, no escrow.
  Losing the password means losing the data. The app says this plainly when a
  vault is created and makes backups easy.
- **One codebase, five platforms.** Android, iOS, macOS, Windows, Linux.
- **Open source, reproducible, audited.** GPL-3.0 with an app-store
  exception, reproducible builds, an independent security audit before 1.0.

### What the app does *not* promise

- It does not hide that Cozy Safe is installed or that it holds several
  vaults. Anyone who can inspect the device's storage can see the vault
  containers. Protection comes from cryptography, not concealment.
- It cannot protect data on a device that is already compromised (malware,
  rooted/jailbroken with a hostile party in control).
- It cannot protect against someone who knows the password.

These limits are stated in the app and on the store listing so that users do
not assume more protection than they have.

## Threat model (summary)

| Adversary | Protected? | How |
|---|---|---|
| Someone who picks up the unlocked device | Partly | Auto-lock on inactivity and on backgrounding; screenshots and task-switcher previews blocked |
| Someone who picks up the locked device | Yes | Vault keys are derived from the password (Argon2id) and never stored in plaintext |
| Cloud provider / sync relay / self-hosted server operator | Yes | Sees only ciphertext and coarse sizes |
| Attacker with a copy of the vault files | Yes, given a strong password | Argon2id + XChaCha20-Poly1305; password strength meter at creation |
| Malware on the device | No | Out of scope |
| Someone who coerces the user into unlocking | No | Out of scope; the app does not attempt deniability |

A full threat model lives in `docs/threat-model.md` (to be written with the
first code).

## Functional requirements

### Vaults

- Create a vault with a name and a password; show a strength meter and
  require an explicit "I understand there is no recovery" confirmation.
- Unlock screen shows **one password field and no vault list**. The password
  entered determines which vault opens. Only that vault's contents are shown
  while it is open; switching vaults means locking first.
- Change a vault's password (re-wraps the vault key; data is not re-encrypted).
- Delete a vault with a strong confirmation.

### Content

- Notes: plain text / Markdown, with title, created and modified times.
- Files: any file, stored in encrypted chunks; large files stream, never load
  fully into memory.
- Photos: imported from the system picker or camera; thumbnails are generated
  inside the vault and are themselves encrypted.
- In-app viewers for images and PDF; other files open via the OS with a
  temporary decrypted copy that is wiped afterwards.
- Search by title and note body within the open vault.

### Locking

- Auto-lock after a configurable idle timeout (default 1 minute) and
  immediately when the app goes to the background (configurable).
- Manual lock button always visible inside a vault.
- Optional biometric unlock. The vault key is derived from the password; the
  biometric path only unwraps a copy held in Secure Enclave / StrongBox /
  platform keystore. Turning biometrics off deletes that copy.

### Leak prevention

- Block screenshots and task-switcher previews (`FLAG_SECURE` on Android,
  cover view on iOS, best-effort on desktop).
- Clipboard: anything copied from the vault is cleared after a short delay.
- Password fields disable autocorrect, suggestions and keyboard learning.
- No analytics, no crash reporting that could carry vault data. Diagnostics
  are opt-in and reviewed by the user before sending.

### Backup and export

- Export a vault as a single encrypted file (same format as the vault itself),
  importable on any platform.
- Export plaintext (notes as Markdown, files as-is) with a loud warning.
- Reminder when the last backup is older than a configurable threshold.

### Sync (see `architecture.md`)

- v0.2: cloud folder (iCloud Drive, Google Drive, Dropbox, Syncthing — any
  folder the OS syncs) and LAN peer-to-peer.
- Later: self-hosted server, internet peer-to-peer.
- Concurrent edits merge without data loss (CRDT).

### Theming

- Light / dark / follow system.
- User-adjustable theme: preset (warm, professional, night), accent colour,
  corner radius, type scale. Implemented as design tokens, see `ui.md`.

### Localisation

- Vietnamese and English at launch. All user-visible strings go through the
  localisation layer from day one.

## Non-functional requirements

- Vault open on a mid-range phone: under 1.5 s with Argon2id parameters that
  still cost an attacker meaningfully (tuned per platform, floor defined in
  `architecture.md`).
- No plaintext secret ever crosses into Dart. See `architecture.md`.
- Accessibility: screen readers, dynamic type, WCAG AA contrast.
- Touch targets ≥ 44 px.

## Roadmap

### v0.1 — single device

Android + macOS + Windows + Linux. Vaults, notes, files, photos, auto-lock,
leak prevention, encrypted backup/restore, change password, theming, vi/en.

### v0.2 — sync

Cloud-folder sync, LAN P2P sync, CRDT merge, biometric unlock, iOS.

### v1.0 — public release

Independent security audit, reproducible builds, SBOM, signed releases,
App Store, Google Play, F-Droid, signed desktop installers, website at
<https://safe.cozypi.com>.

### After 1.0

Self-hosted sync server, internet P2P (iroh), structured records (passwords,
cards), shared vaults between people.
