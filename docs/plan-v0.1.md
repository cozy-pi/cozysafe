# v0.1: usable on one device, no cloud sync

Goal: someone can keep real documents and photos in Cozy Safe on one phone or
computer without risk of losing them. Sync comes after v0.1.

Without sync, uninstalling the app deletes the vault files (they live in the
app's own storage). So v0.1 must have an encrypted backup file the user keeps
elsewhere, and the Emergency Kit to open it.

## Stage 1: data safety (done 2026-10-19)
- Secret Key moves from the `secret-key` file into the platform keystore
  (Keychain this-device-only, Android Keystore, Windows DPAPI, macOS Keychain,
  libsecret). Existing installs migrate on first launch, then the file is wiped.
- Emergency Kit after the first vault: the Secret Key in a readable format,
  saved or shared by the user; confirm by typing its last 4 characters.
- Backup: one file with the whole library (already encrypted; no biometric or
  PIN wrappers, no Secret Key). Restore: pick the file, enter the Secret Key from
  the Emergency Kit, then unlock with the password.

## Stage 2: approved UI (done 2026-10-19, 0.1.1)
- Lock screen B2 with a PIN per vault (at least 4 digits, growing waits, no
  lockout) and biometrics; splash screen.
- First run in steps (icon, colour, PIN, PIN again, Face ID), no names; backup
  password and Emergency Kit set later.
- Vault screen: Library | Collections, edge-to-edge photo grid, list for
  documents and notes, viewer with swipe.
- One shared add dock (lock screen and vault): mode strip + big button.

## Stage 3: content
- Done in 0.1.1: notes (saved as you type), photos from the system picker, any
  file, open a file in another app (temporary copy, removed after).
- To do: nested folders, paste, desktop drag and drop in.

## Stage 3b: from the user review (`ui.md`, User review 2026-10-19)
Before calling it v0.1, in this order:
- 0.1.2, no new screens: say what a forgotten PIN means (PIN step and vault
  banner); cover the app switcher (iOS) and `FLAG_SECURE` (Android); clipboard
  sensitive + cleared; backup says which vaults are left out; "Face ID opens this
  vault"; set a PIN after a restore.
- 0.1.3, mockups first: delete originals after import, Recently deleted, built-in
  viewers (PDF, video), Settings, delete a vault, import progress, last backup.

## Stage 4: finish
- Search by name (and note text). Recently deleted and Settings moved up to
  Stage 3b.

## Testing (before calling it v0.1)

Done now: Rust unit tests for every core module (crypto, vault, items, PIN,
biometric copies, backup and restore, camera frames) run in CI; Dart analysis;
screenshot tests of the main screens.

Still to do, before v0.1:
- Widget tests for the lock screen flows (PIN tries, PIN locked, password fallback,
  pending dock action) with the bridge mocked.
- Integration tests on a real device or emulator in CI: create vault, Emergency
  Kit, set PIN, lock, unlock with PIN, take a photo, back up, restore on a clean
  install.
- A manual checklist per platform for what CI can't drive (Face ID, fingerprint,
  share sheet, file pickers).

## Later
Sync, document scanning, quick capture while locked, key rotation.
