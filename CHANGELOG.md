# Changelog

Preview builds. Each release has one version name on every platform (iPhone,
Android, macOS, Windows, Linux); the build number only matters to the stores.
Dates are UTC.

## 0.1.13 (2026-10-21)

### Changed
- Settings: the storage bar shows every kind in its own colour (photos, videos, notes,
  voice memos, files) with each one's size; videos and voice memos were missing before.
- Settings is easier on the eyes in both modes: the storage card sits on the same surface
  as the groups, Back up now is a soft blue, switches are green when on.
- Dark mode: filled buttons are a soft grey instead of a white slab.

### Added
- Text files (txt, md, json, csv, xml, yaml, log, code…) open inside the app, decrypted
  in memory only; JSON is laid out, copied text is cleared from the clipboard.

## 0.1.12 (2026-10-21)

### Changed
- Tapping a photo or video opens it as a card a little bigger than its thumbnail, with the
  vault still visible behind; videos play right in the card. Close sits bottom left as in
  the camera, Full screen next to it; full screen goes back to the card.
- The add column pops out of the + one way after another, + turns into ×, and the column
  scrolls in a loop: drag it down to bring any way to your thumb.
- The + button sits higher above the lock, so a thumb does not hit the wrong one.
- Settings: no more brown tiles (backup password amber, note text mint).

## 0.1.11 (2026-10-21)

### Changed
- The + button works the same everywhere: it opens a column of every way to add (note,
  photos from the phone, photo, video, voice memo, file), with the ones for the section
  you are in closest to your thumb. One hand: hold +, slide up to what you want, let go.
- Voice memos: tapping one opens it right in the list, with Send, Rename and Delete.
- Recently deleted: tap to select, then Restore or Delete for good in the bar at the
  bottom (with nothing selected they apply to everything).

## 0.1.10 (2026-10-21)

### Changed
- Bigger buttons everywhere, from one shared set of sizes: round buttons 48, bottom bar
  and lock 56, main button 64.
- The vault icon is a round badge with its colour, shown when the vault opens, on the
  empty vault and in Settings. The lock button is just a big lock.
- Only the sections that hold something are offered at the bottom; an empty vault shows
  big tiles to add a note, photo, video, photos from the phone, voice memo or file.
- The main button: in Notes it writes a new note, in Files it picks files, in Voice it
  records; in the Library (or before there is one) it opens "Add to vault".
- Camera: Close is in the bottom row next to the shutter, swiping down closes, the last
  shot sits in the corner of the viewfinder.
- Note editor: a round Back and a big Done; the hint says the first line is the title.
- Search: a rounded field with a magnifier.
- Selecting: a Select button at the top; the Send · Group · Delete bar is frosted glass,
  Delete in red.

### Privacy
- The notes list and search show titles only, so people nearby cannot read your notes;
  Settings → Display can show the text (asks for Face ID to turn on).
- The Emergency Kit's mask no longer shows how long the key is, and says that a copy is
  cleared from the clipboard after 60 seconds.

### Fixed
- Recently deleted says that tapping an item restores or deletes it; "Delete all" is red
  and away from "Restore all".
- Grey text is easier to read; month headings start with a capital letter.

## 0.1.9 (2026-10-20)

### Changed
- Unlocking: after the dial, the vault's icon shows alone on a plain screen and fades,
  and only then does the vault's content appear.
- The launch screen is black and white too (white or black, following the phone).
- Recording and video are red again, as on any phone; Settings icons have colours; the
  biometrics row shows the real Face ID symbol (or a fingerprint, with matching words).
- Messages ("Moved to Recently deleted · Undo") float as glass beside the main button,
  never over the bottom bar.
- Notes list: one line with when the note was made and its first words, like iPhone Notes.
- A short fade when switching sections or groups; softer shadows.

### Added
- Settings → Display → Add button: put the main button on the left (default) or right.

## 0.1.8 (2026-10-20)

### Changed
- Black and white: the whole app is one ink on the page colour, light or dark, following
  the phone. The one colour left is your vault's own icon.
- After unlocking, the vault's icon shows in the middle for a moment, so you know which
  vault opened. The icon is no longer in the corner of the vault.
- Recording and video are no longer red; deleting a vault uses the opposite brightness
  instead of red.

### Security
- Every security setting asks for Face ID, fingerprint or the phone's passcode first:
  biometrics on/off, PIN, auto-lock, blocked screenshots, backup, backup password,
  Emergency Kit, delete vault.
- Passwords and the Secret Key are hidden until you tap Show (the Secret Key hides again
  after 30 seconds or when you leave the app), so nobody nearby, and no camera, sees them
  by chance. Copying the Secret Key now clears the clipboard after 60 seconds.

## 0.1.7 (2026-10-20)

### Changed
- Groups replace folders: an item can be in several groups, and a group shows its notes,
  photos, recordings and files in every section. Old folders become groups of the same
  name. Selecting items now offers Group (tick the groups) instead of Move.
- The camera keeps the app's frame: title, close button, a rounded viewfinder, the
  Photo | Video switch, shutter, last shot and flip.
- Photos, videos and recordings get readable names from when they were made
  ("Ảnh 20-10-2026 21.40.12.jpg") instead of "Photo.jpg", numbers or picker names.

### Security
- No library can send data out: the Android app has no internet permission (checked on
  the built APK), macOS runs sandboxed without network access, Dart's HTTP client and
  sockets are switched off at start, the compiled Rust core may not import network
  functions, and every Dart and Rust package is on a reviewed list with its sources
  scanned (docs/supply-chain.md).

### Internal
- Stored names cleaned up (docs/naming.md): item records and PIN files are now format 2;
  older records still read.

## 0.1.6 (2026-10-20)

### Changed
- The vault screen is redesigned: a large title, content edge to edge, and floating
  frosted glass at the bottom: the lock, then Notes · Library · Voice · Files. Tap a
  kind or slide along the bar to switch.
- The main action floats above the lock (left thumb): a pen for a new note, a red mic
  for recording (Stop while recording), + for files, and + for the library with a short
  menu: add photos from the device, take a photo, record a video.
- Search and Settings are round buttons at the top right; the vault icon stays at the
  top left (tap it to change the icon).
- Camera is no longer a mode: it opens from the Library's + menu, full screen, with a
  Photo | Video switch.

### Added
- Every kind has its own folders (albums in the Library), shown as a row under the
  title with "New folder" / "New album". New notes, recordings, photos and files go
  into the folder that is open. Folders made before this release belong to Files.
- Video recording in the vault camera. The clip is encrypted into the vault as soon as
  recording stops (and before the vault locks), and the plain file is deleted.

## 0.1.5 (2026-10-20)

### Added
- Voice memos: a Voice mode in the dock. The middle button is a microphone (Stop while
  recording) with a live level meter and timer; the recording is encrypted into the
  vault the moment it stops (and before the vault locks). Recordings play in place;
  tap one to rename, send or delete it. iPhone and Android.

### Changed
- The dock's add button (Pick photos, New note, Pick files) is white like the camera's
  shutter, with the same ring around it.

## 0.1.4 (2026-10-20)

### Added
- Folders, in Files: coloured folders that hold anything (photos, files, notes,
  folders); open one to see what's in it, rename or recolour it, delete it (what's
  inside moves up a level, nothing is lost). Select items and Move them to a folder.
  Files picked inside a folder go into it. Folders are encrypted like everything else
  and are part of backups.
- The bottom of Settings shows the version and build, e.g. "Cozy Safe 0.1.4 (1009)":
  the build is 1000 plus the GitHub release run number.
- On Android the version name carries the build (0.1.4.1009), so every Play
  release has its own name. iPhone keeps three numbers, as Apple requires.

### Changed
- The app no longer takes the vault's colour as its background; it keeps Cozy Safe's
  green. The colour stays on the vault's icon and its card in Settings.
- The mode strip fades out at both edges, so no half-cut label shows.
- The mode strip is easier to hit: it is 48 points tall to touch, a tap in the gap
  between two labels picks the nearer one, and a sideways swipe anywhere on the dock
  (also on the buttons) moves it.
- Messages (Undo…) float above the dock instead of covering its buttons; the
  "N items added" message is gone (the items simply appear).
- Creating a vault has large Back and Cancel buttons at the bottom, within thumb
  reach; Cancel returns to the lock screen, also when started from inside a vault.

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
