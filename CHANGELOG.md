# Changelog

Preview builds. Each release has one version name on every platform (iPhone,
Android, macOS, Windows, Linux); the build number only matters to the stores.
Dates are UTC.

## 0.1.4 (2026-10-20)

### Added
- Folders, in Files: coloured folders that hold anything (photos, files, notes,
  folders); open one to see what's in it, rename or recolour it, delete it (what's
  inside moves up a level, nothing is lost). Select items and Move them to a folder.
  Files picked inside a folder go into it. Folders are encrypted like everything else
  and are part of backups.
- The bottom of Settings shows the version and build, e.g. "Cozy Safe 0.1.4 (1009)":
  the build is 1000 plus the GitHub release run number.

### Changed
- The mode strip fades out at both edges, so no half-cut label shows.

## 0.1.3 (2026-10-20)

### Added
- The dock's strip now picks what the vault shows: Notes, Library, Camera or Files.
  It switches while you drag, without waiting for you to let go.
- The camera works inside the vault, under the same header and dock.
- Search by name and inside notes, accents ignored.
- Long-press to select several items, then send or delete them together.
- PDFs open inside the app; videos play inside the app (iPhone, Android, Mac).
- Videos from the library keep their length, shown on their square.

### Changed
- Photos are smaller, 4 per row like Photos (pinch for 3, 5 or 7).
- Notes are a list of equal rows: title, two lines, date.
- The middle button says what it does (Pick photos, New note, Pick files); only the
  camera keeps the round shutter.
- The vault never opens on the camera.
- The vault's top-right button is Settings (a gear) and opens it directly. Change
  icon and colour, Recently deleted and New vault moved into Settings.
- The PIN card on the lock screen is shorter.
- Needs iOS 16 or macOS 13 (for video previews).
- Android builds reach internal testers within minutes (no review) and closed
  testing after Google's review.

### Fixed
- The lock screen's ⋯ menu was almost unreadable in dark mode (light text on white).

## 0.1.2 (2026-10-20)

### Changed
- The whole app takes the open vault's colour, light or dark with the phone. Notes,
  files and settings sit on plain cards so text always reads well.
- The lock screen only unlocks: adding photos or notes from it is gone. "Use password",
  "Create a new vault" and "Restore" moved into a ⋯ button under the left thumb.
- Creating another vault asks for Face ID, a fingerprint or the phone's passcode.
- Settings redone: the vault's card with its size and last backup on top, grouped
  rows, Back up now, and a page on how the vault is protected.

### Fixed
- Opening with Face ID shows the vault opening again (the app switcher cover hid it).
- Notes and files in Recently deleted sit on a card; its buttons are calmer.

## 0.1.1 (2026-10-19)

### Added
- Create a vault in short steps: icon, colour, PIN, PIN again, then Face ID. No
  name to type: a vault is its icon and colour (35 icons, 20 colours).
- "New vault" on the lock screen and in the vault menu.
- Notes, photos from the library, and files. A file opens in another app through a
  temporary decrypted copy that is removed afterwards.
- Backup password set when it is needed (before the first backup), with the
  Emergency Kit, and changeable at any time. The app asks for it every 14 days.
- Splash screen: vault green with the dial.
- Recently deleted: deleting moves an item there for 30 days (Undo right away,
  restore or delete for good later).
- Settings: auto-lock time (1, 2, 5 or 10 minutes), Face ID for this vault, PIN,
  backup, block screenshots (Android), storage used, delete this vault.
- Delete a vault, confirmed with its PIN.
- Importing several photos or files shows "Encrypting 3 of 12" with Cancel.
- Sending a file to another app warns once per vault that the copy is not protected.
- The app switcher shows the dial instead of the vault (iOS); on Android the vault
  is hidden from recent apps and screenshots.
- Text copied from a note is cleared from the clipboard after 60 seconds and when
  the vault locks.
- After opening a vault with its password on a phone with no PIN for it (a
  restored backup), the app offers to set one.
- The vault menu shows when the last backup was made and that Face ID opens this
  vault; the backup step says which vaults it holds.

### Changed
- Setting a PIN and the reminder in the vault say plainly what a forgotten PIN
  means while the vault has no backup password.
- Each vault has its own PIN (at least 4 digits, no practical upper limit). The
  dots show only the digits typed.
- Wrong PINs make you wait longer each time instead of turning the PIN off.
- The vault locks after 2 minutes without a touch; picking photos or files or
  sharing gives 60 seconds away from the app.
- New lock symbol in the dock; Apple's Face ID symbol on Face ID devices.

### Fixed
- Creating a vault (or changing a PIN) could test whether a PIN belongs to another
  vault without waiting; it now shares the wrong-PIN waits.
- A note being typed is saved as you type and before the vault locks; touches and
  typing on any screen keep the vault open.
- More room between the PIN card and the keypad.

## 0.1.0 (2026-10-19)

First build with a version name, on every platform at once.


### Changed
- Only what works is shown: the dock offers Photo (on phones), the Search button
  and the Collections tab are hidden until they exist. Computers have no add button yet.

### Fixed
- Locking by hand no longer reopens the vault with Face ID straight away. Face ID
  is asked for when the app opens or comes back from the background; after the
  Lock button, tap Face ID in the dock.

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
