# Changelog

Preview builds. Each release has one version name on every platform (iPhone,
Android, macOS, Windows, Linux); the build number only matters to the stores.
Dates are UTC.

## 0.1.1 (2026-10-19)

### Changed
- Only what works is shown: the dock offers Photo (on phones), the Search button
  and the Collections tab are hidden until they exist. Computers have no add button yet.

### Fixed
- Locking by hand no longer reopens the vault with Face ID straight away. Face ID
  is asked for when the app opens or comes back from the background; after the
  Lock button, tap Face ID in the dock.

## 0.1.0 (2026-10-19)

First build with a version name, on every platform at once.

### Added
- Lock screen redesign: Face ID or fingerprint first, a PIN pad (4 to 10 digits,
  this device only, turned off after 5 wrong tries), password as the fallback.
- The vault opens with a short animation: the dial turns half a turn. Locking plays
  it backwards.
- Add dock at the bottom of both the lock screen and the vault: drag the modes like
  the iPhone Camera dial. The last mode is remembered. Today only Photo works; the
  other modes arrive in the next update.
- New vault screen: Library and Collections, photos edge to edge, pinch to fit 3 or
  5 per row, swipe between photos, swipe down to close.
- Emergency Kit: the Secret Key in a form you can write down (`CS1-…`, with check
  characters that catch typos). Shown after the first vault, and from the vault menu.
- Back up to a file (all vaults, already encrypted) and restore it on a new install.

### Changed
- The Secret Key moved from a file inside the app into the device keystore. Existing
  installs move it automatically on first start.
- Android: app data is no longer included in Google cloud backup (it could not be
  opened without this device's keystore anyway; use Back up to a file).

## 2026-10-19

### Added
- Unlock with Face ID or fingerprint; on by default for the first vault.
- Typing the right password opens the vault without pressing Enter.
- Camera inside the app (iPhone, Android): photos go straight into the vault.
- First builds on TestFlight and the Google Play closed test.
- macOS build signed with Developer ID and notarized; Android build signed.

## 2026-10-18

### Added
- First preview: create vaults, unlock with a password. Builds for macOS, Windows,
  Linux and Android.
