# Requirements and roadmap

## Product

Cozy Safe is an encrypted vault for notes, files and photos. It is a product of
[Cozy Pi](https://cozypi.com) and is fully open source.

### Core promises

- **Encrypted on device.** Everything is encrypted before it touches disk, a
  cloud folder, a peer or a server. Sync transports only ever see ciphertext.
- **Multiple vaults, separate keys.** Every vault has its own encryption keys and
  its own PIN on the device; the backup password, once set, is per vault too.
  Knowing one gives no access to another vault.
- **No recovery.** There is no password reset, no recovery e-mail, no escrow.
  A vault without a backup password lives only on this device behind its PIN:
  forget the PIN or lose the phone and it is gone. The app says this where the PIN
  is set and keeps nudging until a backup password exists, and makes backups easy.
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
| Someone who picks up the locked device | Yes | Vault keys are wrapped by the password (Argon2id) or by the PIN plus a device key held in the platform keystore; never stored in plaintext |
| Someone who guesses PINs on the device | Slowed | Growing waits after the 5th wrong PIN (1, 5, 15, 60 min), shared by every path that can tell whether a PIN exists (unlock, create a vault, change PIN). 4 digits is the minimum; the app suggests 6 or more |
| Cloud provider / sync relay / self-hosted server operator | Yes | Sees only ciphertext and padded sizes; cannot guess the password without the Secret Key |
| Attacker with a copy of the vault files | Yes | Password + 128-bit Secret Key, Argon2id + XChaCha20-Poly1305. See `adr/0001-encryption.md` |
| Malware on the device | No | Out of scope |
| Someone who coerces the user into unlocking | Partly | Each vault opens only with its own PIN, so the user can open a harmless one. Not true deniability: the storage shows how many vault containers exist |

A full threat model lives in `docs/threat-model.md` (to be written with the
first code).

## Functional requirements

### Vaults

- First run: generate the Secret Key and the Emergency Kit (printable PDF).
  Setup finishes only after the user types the last 4 characters of the key
  from the saved kit; the app re-checks every few months.
- Secret Key sync through iCloud Keychain / Google Password Manager is on by
  default and can be turned off (Settings → Security), see
  `adr/0001-encryption.md`.
- First run also asks where vaults live: **a cloud folder** (default,
  recommended; the cloud only ever sees ciphertext), **a folder the user
  picks** (survives uninstalling the app), or **this device only** (opt-in,
  red warning: uninstalling the app deletes the vault).
- A device-only vault that has never been backed up shows a persistent
  warning inside the vault.
- Add a device: scan a QR code from an unlocked device, or type the Secret
  Key from the Emergency Kit.
- Create a vault with a name and a password; refuse weak passwords (zxcvbn
  score < 3) and require an explicit "I understand there is no recovery"
  confirmation.
- Unlock screen shows **one password field and no vault list**. The password
  entered determines which vault opens. Only that vault's contents are shown
  while it is open; switching vaults means locking first.
- Change a vault's password from inside the vault: current password, new
  password, done in under 2 s whatever the vault size (re-wraps the vault
  key). Biometric unlock keeps working. The screen says that earlier
  exported backups keep the old password.
- "I think it was exposed" offers **Rotate all keys**: new keys, everything
  re-encrypted in the background, resumable.
- Delete a vault with a strong confirmation.
- **v0.1 (single device), as built (0.1.1):**
  - No storage-location choice yet (vaults live in app storage); the backup file
    is the way to keep a copy elsewhere. Key sync and "add a device" come with
    sync in v0.2.
  - Create a vault in steps: icon, colour, PIN, PIN again, Face ID (first vault).
    No name and no password at creation (see `ui.md`, First run).
  - The backup password and the Emergency Kit are set later on one screen:
    required before the first backup, nudged from inside the vault, changeable
    any time (re-wraps the vault key, instant).
  - Each vault has its own PIN; a PIN already used by another vault is refused.
  - **Still missing** (from the user review of 2026-10-19, `plan-v0.1.md`):
    delete a vault; choose which vault Face ID opens; set a PIN after restoring
    a backup on a new device.

### Content

- Notes: plain text / Markdown, with title, created and modified times.
- Files: any file, stored in encrypted chunks; large files stream, never load
  fully into memory.
- Photos: imported from the system picker or taken with the in-app camera;
  thumbnails are generated inside the vault and are themselves encrypted.

### Adding content from outside the vault

One "Add" button (the + inside a vault) opens every source:

| Source | Mobile | Desktop | Notes |
|---|---|---|---|
| Take photo | in-app camera | — | see below |
| Photos from library | Android Photo Picker, iOS PHPicker | — | system pickers, **no library permission** |
| Files | Android Storage Access Framework, iOS document picker | native open dialog | includes cloud drives the OS exposes (iCloud, Google Drive, Dropbox, OneDrive) |
| Whole folder | Android SAF tree, iOS folder picker | native folder dialog | keeps the folder structure |
| Paste | text and images | text, images, files | |
| Drag and drop / share sheet | see "Drag and drop, share, copy" | | |

- Imports stream and encrypt; large or many files show progress, run in the
  background, can be cancelled, and resume after the app is killed. Nothing
  is half-imported: an item appears only once fully encrypted.
- Duplicates (same content hash inside the vault) are detected and offered
  as skip / keep both.
- After import the app offers to **delete the originals**: photos through
  the system delete prompt (MediaStore delete request, PHPhotoLibrary), files
  where the source allows it. It states that deleting on a phone or SSD is
  not a guaranteed wipe.
- Original file name, type and dates are kept inside encrypted metadata;
  location metadata follows the same rule as the camera.

### In-app camera (mobile)

- Photos go straight into the open vault: the frame is captured to memory
  and encrypted while it streams to storage. It never reaches the system
  gallery, a shared folder or a plaintext temporary file. (Flutter's
  `camera` plugin writes `takePicture` output to a cache file, so we never call
  it: the shot is the next frame of the preview stream, which stays in memory,
  and `core/cs-photo` encodes it to JPEG in Rust before it is encrypted. Frames
  are 1080p (`ResolutionPreset.veryHigh`); full sensor resolution needs our own
  native capture layer later.)
- Only the camera permission is requested; no photo-library permission.
- Location is stripped from photos by default (EXIF GPS); a per-vault setting
  keeps it.
- Burst of several shots in one session, then review and delete before
  saving.
- **Quick capture while locked**: an app shortcut / home-screen quick action
  opens the camera without unlocking; shots are encrypted to the inbox key
  (same mechanism as the share inbox, see `adr/0001-encryption.md`) and
  imported on next unlock. Locked mode cannot show earlier shots.
- Document scanning (edge detection, perspective fix, multi-page PDF) after
  v0.1; must run on-device without Google Play Services so F-Droid builds
  keep it.
- Video after v0.1 (chunked streaming encryption is already in the format).
- In-app viewers for images and PDF; other files open via the OS with a
  temporary decrypted copy that is wiped afterwards.
- Search by title and note body within the open vault.

### Locking

- Auto-lock after a configurable idle timeout (default 1 minute) and
  immediately when the app goes to the background (configurable).
- Manual lock button always visible inside a vault: in the add dock, bottom
  left (thumb reach), not the top corner.
- Biometric unlock: on by default for the first vault, asked for as soon as the
  lock screen shows; one vault per device. The biometric path only unwraps a copy
  of the vault key held behind the platform keystore; turning it off deletes that
  copy.
- PIN unlock: at least 4 digits (no practical maximum), one per vault, this
  device only. Wrong PINs make you wait longer each time (from the 5th: 1, 5, 15,
  60 min) and never turn the PIN off, because a vault may have no password yet.
  The dots show only the digits typed, never the length. See
  `adr/0001-encryption.md`.
- **v0.1 as built:** idle lock after 2 minutes without a touch or keystroke,
  anywhere in the app (also on the note editor and viewers); leaving the app locks
  at once, except 60 s when the app itself opened a picker or the share sheet.
  Locking first saves any note being typed. A configurable timeout comes with
  Settings.
- Password unlock opens as soon as the typed password is right (tried quietly
  after a short pause), no Enter needed; Enter still reports a wrong password.
- Adding while locked: the lock screen shows the same add dock. Until the
  share-inbox keys exist, picking an action unlocks first and then runs it;
  with the inbox, photos and notes can be added without unlocking and without
  showing anything already in the vault.

### Leak prevention

- Block screenshots and task-switcher previews (`FLAG_SECURE` on Android,
  cover view on iOS, best-effort on desktop). **Not built yet; v0.1 must have it**:
  today the app switcher shows what was on screen. iOS: add the cover in the
  scene's `willResignActive` natively (a Flutter overlay arrives too late for the
  snapshot). Android: `FLAG_SECURE` also blocks the user's own screenshots, so it
  is a setting (on by default) that testers can turn off.
- Clipboard: anything copied from the vault is marked sensitive (Android 13+
  `EXTRA_IS_SENSITIVE`, iOS `localOnly` + expiry, so no Universal Clipboard)
  and cleared after 60 s (configurable) and on lock.
- Password fields disable autocorrect, suggestions and keyboard learning.
- No analytics, no crash reporting that could carry vault data. Diagnostics
  are opt-in and reviewed by the user before sending.

### Drag and drop, share, copy

Everything that leaves the vault leaves it decrypted. The app makes that
easy but never silent.

- **Inside the app**: drag items to reorder, into folders/collections, and
  between panes on desktop and tablets. Only one vault is open at a time, so
  there is no dragging between vaults.
- **Into the app**: drop files and photos from Finder, Explorer, file
  managers, other apps (iPad/Android split screen, desktop) onto the window
  or a folder. Items are encrypted while streaming in. Afterwards the app
  offers to delete the originals, noting that deleting from a phone or SSD is
  not a guaranteed wipe.
- **Out of the app**: drag items to other apps or the desktop. Data is
  produced lazily when dropped (macOS file promises, Windows virtual files,
  iOS/Android item providers), streamed without a temporary copy where the
  OS allows; otherwise a temporary copy is wiped on lock and on app start.
  The first drag-out per vault shows a one-time note that the copy is no
  longer protected.
- **OS share sheet, in**: "Save to Cozy Safe" share target (iOS share
  extension, Android `ACTION_SEND`/`SEND_MULTIPLE`, macOS share extension).
  Works while locked: items are encrypted to the vault's inbox key and
  imported on next unlock. The share target asks which vault only after
  unlock, so the locked screen still lists no vaults; until then items wait
  in a library-level inbox encrypted to every vault's inbox key.
- **OS share sheet, out**: share notes as text, files and photos as files,
  same lazy/temporary-copy rules as drag-out.
- **Copy and paste**: copy note text and, on desktop, copy items as files
  (Ctrl/Cmd+C → paste in Finder/Explorer) and paste files in. Clipboard rules
  under Leak prevention apply.
- **Per-vault policy "Keep data inside"**: disables drag-out, share-out and
  copy for that vault.
- Implementation note: evaluate `super_drag_and_drop` / `super_clipboard`
  under the supply-chain policy (`supply-chain.md`); share extensions are native code.

### Backup and export

- Back up the whole library as a single encrypted file and restore it on a fresh
  install with the Emergency Kit and the password (built for v0.1; desktop saves
  where the user picks, phones use the share sheet). Device-only unlock copies
  (biometrics, PIN) are not in the backup.
- Export plaintext (notes as Markdown, files as-is) with a loud warning.
- Reminder when the last backup is older than a configurable threshold; the
  menu shows "Last backup: 12 days ago".
- Only vaults with a backup password are in the backup. The backup screen says
  so every time, in the same words whatever vaults exist (it must not reveal how
  many vaults there are).

### Sync (see `architecture.md`)

- v0.2: cloud folder (iCloud Drive, Google Drive, Dropbox, Syncthing — any
  folder the OS syncs) and LAN peer-to-peer.
- Later: self-hosted server, internet peer-to-peer.
- Concurrent edits merge without data loss (CRDT).

### Theming

- One design, done well. The only user choice is light / dark / follow
  system (default: follow system).
- No theme presets, accent colours, layout options or special effects
  (e.g. glass/blur). Fewer variants means each screen gets polished and
  tested in both modes.
- Colours, spacing, radii and type still live in design tokens so the
  look can be refined in one place, see `ui.md`.

### Localisation

- Vietnamese and English at launch; more languages are added as translation
  files only, with no code changes.
- All user-visible strings go through the localisation layer from day one
  (Flutter `gen_l10n` / ARB files). A test fails on hard-coded UI strings
  and on missing or empty keys in any language.
- Settings → Language: "Follow system" (default), then each language by its
  own name (Tiếng Việt, English). Follow system picks the first device
  language the app supports, else English.
- The choice applies immediately, without restarting, and is stored in app
  settings (outside any vault, so the unlock screen uses it too).
- Dates, numbers and file sizes are formatted per language
  (2,4 MB / 2.4 MB).

## Non-functional requirements

- Vault open on a mid-range phone: under 1.5 s with Argon2id floors of
  128 MiB (phones) / 512 MiB (desktop), t = 3 (`adr/0001-encryption.md`).
- No plaintext secret ever crosses into Dart. See `architecture.md`.
- Accessibility: screen readers, dynamic type, WCAG AA contrast.
- Touch targets ≥ 44 px.

## Roadmap

### v0.1 — single device

Usable on one device, no sync. Android, iOS (TestFlight), macOS, Windows,
Linux. Vaults, biometric and PIN unlock, Emergency Kit, encrypted backup and
restore, in-app camera, the approved lock screen and vault screen with the add
dock, nested folders, photos from the library, any file, notes, paste,
recently deleted, search, change password, settings, vi/en, light/dark.
Stages and progress: `plan-v0.1.md`.

### v0.2 — sync

Cloud-folder sync, LAN P2P sync, CRDT merge, Secret Key sync through
iCloud Keychain / Google Password Manager, add a device by QR code, adding while
locked (share inbox), document scanning, key rotation.

### v1.0 — public release

Independent security audit, reproducible builds, SBOM, signed releases,
App Store, Google Play, F-Droid, signed desktop installers, website at
<https://safe.cozypi.com>.

### After 1.0

Self-hosted sync server, internet P2P (iroh), structured records (passwords,
cards), shared vaults between people.
