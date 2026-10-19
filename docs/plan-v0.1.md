# v0.1: usable on one device, no cloud sync

Goal: someone can keep real documents and photos in Cozy Safe on one phone or
computer without risk of losing them. Sync comes after v0.1.

Without sync, uninstalling the app deletes the vault files (they live in the
app's own storage). So v0.1 must have an encrypted backup file the user keeps
elsewhere, and the Emergency Kit to open it.

## Stage 1: data safety
- Secret Key moves from the `secret-key` file into the platform keystore
  (Keychain this-device-only, Android Keystore, Windows DPAPI, macOS Keychain,
  libsecret). Existing installs migrate on first launch, then the file is wiped.
- Emergency Kit after the first vault: the Secret Key in a readable format,
  saved or shared by the user; confirm by typing its last 4 characters.
- Backup: one file with the whole library (already encrypted; no biometric or
  PIN wrappers, no Secret Key). Restore: pick the file, enter the Secret Key from
  the Emergency Kit, then unlock with the password.

## Stage 2: approved UI
- Lock screen B2 with PIN (4–10 digits, device-only, 5 tries) and biometrics.
- Vault screen: Library | Collections, edge-to-edge photo grid, list for
  documents and notes, viewer with swipe.
- One shared add dock (lock screen and vault): mode strip + big button.

## Stage 3: content
- Nested folders. Photos from the system picker, any file, notes, paste.
- Open a file in another app (decrypted to a private temp file, removed after).
- Desktop: drag and drop in.

## Stage 4: finish
- Recently deleted (30 days), search by name, change password,
  settings (language, theme, PIN, biometrics, auto-lock).

## Later
Sync, document scanning, quick capture while locked, key rotation.
