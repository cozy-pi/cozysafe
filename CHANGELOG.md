# Changelog

Preview builds. Each release has one version name on every platform (iPhone,
Android, macOS, Windows, Linux); the build number only matters to the stores.
Dates are UTC.

## 0.1.65 (2026-10-25)

### Added
- Items your other device deleted for good are no longer gone here at once: a sync
  moves them to Recently deleted, marked "Deleted on another device", kept for 30 days
  and not synced. Restore one and it comes back on every device. The sync result says
  how many were moved. Deleting for good now says your other devices keep the item for
  30 days.

### Changed
- Syncing shows small sealed packets travelling between the two devices along an arch;
  the receiving one lights up as each lands.
- Enter a code, when nothing is found: says to check the 24 words when restoring, and on
  iPhone where to allow Local Network access.

### Fixed
- A device waiting with a code can no longer be held up by someone on the Wi‑Fi who
  connects and stays silent.

## 0.1.64 (2026-10-25)

### Changed
- Google Drive's first sync after the move to folders shows what it does: reading the
  files, making folders (n of m), moving files into them (n of m); folders are made only
  for files that need them, up to 4 at once. The result says how many files were
  rearranged, or that there was nothing new to send or receive.
- Google Drive sync works on Android: sign-in with a Google account (no Google Drive app
  needed).
- Sync with a nearby device is simpler: one device taps Show a code and shows six
  digits; the other taps Enter a code, finds it on the same Wi‑Fi by itself and takes
  the six digits. A wrong code is caught at once, without bothering the other device.
  The QR code stays for networks where the device cannot be found. Restoring from
  another device works the same way. The code works for 5 minutes (was 2).

## 0.1.63 (2026-10-25)

### Changed
- Messages show at the top of the screen and slide down; a swipe up closes them. They no
  longer cover the bottom bar.
- With + in the middle (the default), all six ways fit on one row; a screen too narrow
  for them fades at the right edge and the row nudges sideways on opening.
- Deleting a vault: a red button, then a 10-second countdown with Cancel.
- Debug → Vaults on this device shows the size of each vault.
- A sync counts only what will change here: items already on this device, items deleted
  for good and deletions of items no longer here are not counted (it showed 848 for a
  vault of about 90 items).
- Google sign-in that fails says so, with a code, instead of the nearby-sync message; on
  Android, where Google Drive is not ready yet, the app says so before trying.

### Fixed
- With + on the left or right, the column of ways to add scrolls again: with all six
  ways a small screen hid the top ones.

## 0.1.62 (2026-10-25)

### Added
- Sync with a nearby phone shows progress on both phones, like Google Drive: items,
  MB, speed and time left on the phone that scanned; items, MB and speed on the phone
  that showed the code.

### Fixed
- When the other phone fails (wrong 24 words, wrong password) or stops, the phone that
  showed the code says why and stops, instead of waiting.

## 0.1.61 (2026-10-25)

### Added
- Debug → Vaults on this device: every vault here (names sealed until opened), and a
  way to delete one whose password and PIN are forgotten, without opening it (the
  phone's owner confirms, then types DELETE). Everyday use still never lists vaults.

## 0.1.60 (2026-10-25)

### Fixed
- Changing the Recovery Key works on a device with several vaults: it asks the password
  of each other vault that shares the key and moves them all at once.
- A failed key change says why, with a code (Settings → Debug has the details).
- Back on the key change and on the "enter the PIN again" step goes one step back
  instead of leaving.
- Locking during a key change keeps the page and its new words; the password it held is
  forgotten at once and asked again.

## 0.1.59 (2026-10-25)

### Changed
- Google Drive keeps each vault in its own folder inside "Cozy Safe", its files in up to
  256 small folders; files on the device are split the same way. Earlier files are moved
  on the next sync or open (nothing is uploaded again). Old revisions are removed from
  Google Drive after 30 days.

## 0.1.58 (2026-10-25)

### Changed
- The first screen says: "A secure vault for your world."
- Android: syncing on with the phone locked is off for now (Google Play asks for a
  declaration first); as on iPhone, a sync stopped by locking continues when you come
  back, and the screen says to keep the app open.

### Fixed
- iPhone: with "Block screenshots" off, screen recording works too (it used to show the
  lock picture whatever the setting).

## 0.1.57 (2026-10-24)

### Changed
- Google Drive sync sends up to 4 items at once and removes deleted items in batches:
  much faster with many photos.
- + lists the ways to add in this order: add photos, record video, take photo, note,
  voice, files.
- + ignores a finger passing over it (a swipe back from the edge no longer opens it).
- The blurred background shows everything a vault keeps: photos, videos, passwords,
  keys and codes, notes, documents, cards, voice; no more rows of mountains.

### Security
- Every input a build downloads is pinned by hash: the PDFium library (SHA-256 of each
  archive), every Gradle dependency (dependency verification), the Swift packages
  (committed Package.resolved, checked after each Apple build), Dart packages
  (lockfile enforced) and the Semgrep scanner (hashed packages, none newer than 14
  days). A changed byte stops the build; both checks were tried with a wrong hash.
- Code vendored into third_party/ is scanned for network APIs like any package.

### Fixed
- Locking and coming back returns to the page you were on in Settings (and its pages),
  not the home page. Pages that show vault content still close when the vault locks,
  and Back on the lock screen cannot reveal what is under it.
- Restoring from Google Drive when it holds several vaults opens the one your password
  belongs to (it used to try only the first).

## 0.1.56 (2026-10-24)

### Added
- Restore from another device: type or paste the 24 words and the password on the new
  device, scan the code the old one shows, and the vault comes over Wi‑Fi with all its
  items. No cloud, no backup file.
- Restore asks the 24 words and the password once, then where the vault is (another
  device, Google Drive or a backup file). If it is nowhere else, the app says so.
- A Paste button on every 24-word field; the clipboard is emptied after pasting.
- Home says when the vault is only on this device, with a way to keep a second copy.
- Android: locking the phone no longer stops a sync; a notification shows its progress.
- iPhone: a sync stopped by locking the phone continues by itself when you come back.

### Changed
- Google Drive sync reuses one secure connection, so many small items go up much faster.
- The sync screen shows this phone and the other end, says what goes where, and shows
  items, MB, speed and time left.

### Fixed
- Items deleted for good no longer stay in Google Drive: their encrypted files are
  removed there too, including ones left by earlier versions. Deletions are counted apart
  from items going up.

### Security
- Leaving the making of a first vault half-way and coming back shows new 24 words: words
  that may have been seen are never used.

## 0.1.55 (2026-10-24)

### Added
- A first screen with two choices: Create a new vault, or Restore a vault (from Google
  Drive or from a backup file).
- Sync with Google Drive shows what it is doing (checking, bringing in n of m, sending
  n of m), keeps the screen on, and offers Continue if the phone sleeps or the network
  drops.

### Changed
- Making a vault is one thing per step: the 24 words, the password, the PIN (quick
  open on this phone), then Face ID or fingerprint as its own step. Shorter text.
- Notes and files have clearly different icons (pen and paper, folder).

## 0.1.54 (2026-10-24)

### Added
- "I have a vault on Google Drive" on the first screen: sign in with Google, type the 24
  words and the vault password, and the vault comes down encrypted and opens on this
  device; no backup file needed.

### Changed
- + shows every way to add in one row, scrolling sideways when needed.
- Turning on debug mode no longer shows a message over the Debug row.

### Security
- New independent scanners on every change: Google's OSV-Scanner (Rust and Dart),
  GitHub CodeQL, Semgrep, gitleaks (secrets in the whole history), and a rule that no
  library version younger than 14 days gets in.

## 0.1.53 (2026-10-24)

### Added
- Sync with Google Drive (Settings, Sync): sign in with Google, allow the connection,
  and the vault syncs item by item through a "Cozy Safe" folder in your Drive. Google
  sees only encrypted files; the app sees nothing else in your Drive. iPhone first;
  Android once its sign-in is registered.

### Security
- After a password or Recovery Key change, the old ones no longer open the copy kept in a
  sync place: only the newest lock stays there.

## 0.1.52 (2026-10-24)

### Fixed
- New vault: "I wrote them down" is pinned at the bottom, next to Back, so a small phone
  no longer has to scroll to find it.
- Recovery Key page: the Save button no longer wraps on two lines, and a key from before
  the 24 words gets its own explanation.

## 0.1.51 (2026-10-24)

### Changed
- Bottom bar: overview, library, +, files, notes. Voice memos have no tab any more; they
  open from the overview and from +.
- + always offers every way to add (add photos, take a photo, record a video, note,
  voice memo, file), three to a row; it is a little smaller and filled, so it stands out.
- Deleting the last vault now also forgets its 24 words on this device: the next vault
  starts with new ones.

## 0.1.50 (2026-10-24)

### Added
- Change the Recovery Key (Settings, Security, Recovery Key): new 24 words for this
  device, also from a key made before the 24 words. Everything in the vault stays; the
  PIN and Face ID keep working. Stopping half-way never locks the vault out. Backups made
  before still need the old key, so the app offers a new backup at the end.

## 0.1.49 (2026-10-24)

### Fixed
- After deleting the last vault on a device set up before the 24 words, Start on the
  new-vault screen stayed greyed out. The device now makes a new 24-word Recovery Key.

## 0.1.48 (2026-10-24)

### Changed
- Showing the Recovery Key again (Settings, Security) now needs the vault password after
  Face ID. Wrong tries wait like on the lock screen.

### Security
- More checks on the 24 words: the official BIP39 word list (by its checksum), the
  reference test vectors, and that new keys come from the system's random generator.

## 0.1.47 (2026-10-24)

### Changed
- Sync: the question to allow the connection comes up the moment a code is read, the
  camera reads codes on a screen better, the device showing the code says as soon as
  another device connects, and the joining device says where it is connecting.

## 0.1.46 (2026-10-24)

### Changed
- Sync says what went wrong: the other device holds a different vault (and how to fix
  it), it cannot be reached on the Wi‑Fi, or the code ran out. The device showing the
  code says when a device with another vault tried to join.
- Turning on screenshot blocking no longer asks for Face ID (turning it off still does).

## 0.1.45 (2026-10-24)

### Changed
- Sync: the question before connecting, and iPhone's local network prompt, now say that
  the other device needs this vault and the one-time code.

## 0.1.44 (2026-10-24)

### Added
- Sync with a nearby device (Settings, Sync): one device shows a QR code or an 18-character
  code, the other scans or types it, and both bring the vault up to date over the Wi‑Fi.
  Both must hold the same vault. Nothing connects on its own: each time the app asks,
  naming the address, and the code works once, for 2 minutes. Both screens show the same
  number to compare. A note edited on both devices keeps both texts. A log lists every
  connection (kept encrypted in the vault).

### Changed
- The app now asks for network access (Android internet permission, macOS network
  sandbox rights, iPhone local network) for sync only. All network code sits in one part
  of the app, which can only reach addresses on your local network and does no name
  lookups.
- Lock screen and new vault: number keys, fields and buttons are solid, so the picture
  behind no longer shows through them.

## 0.1.43 (2026-10-24)

### Changed
- The add button now sits in the bottom bar by default, right after the overview tab
  (left and right floating buttons are still in Settings).
- Middle bar: the vault's badge is a tab inside the bar, like the others, and every
  tab gets the same space.
- In the library, + offers Add photos, Take photo and Record video side by side, just
  above the button.

### Fixed
- Linux build (a JPEG library the runner no longer had).

## 0.1.42 (2026-10-24)

### Changed
- Bottom bar: the lit pill slides to the section tapped.
- Add button "Middle": icons only, the vault's badge on its own on the left, and the
  four sections two on each side of the +, evenly spaced (the words overflowed).

## 0.1.41 (2026-10-24)

### Fixed
- With the add button on the right, its choices showed a repeat and slid one under the
  ×. The few choices now sit in a plain column, nothing rolls.

## 0.1.40 (2026-10-24)

### Changed
- Add button "Middle": the + now sits inside the bottom bar, with the sections as icons
  and small words on both sides; its choices fan out above the bar.
- Photo and video preview: Close, Full screen, Send, More and Delete sit at the bottom,
  just above the bottom bar, which stays on screen; tapping a section closes the preview
  and goes there.
- One vault in the app: "New vault" only shows in debug mode, for testing.

## 0.1.39 (2026-10-24)

### Changed
- The + button is back on the left by default. Settings → Add button position offers
  Left, Middle or Right. On an edge, its choices stack up above it; in the middle they
  fan out around it.
- Swiping sideways over the + button no longer opens its choices; only a tap, or
  sliding up from it, does.

## 0.1.38 (2026-10-24)

### Changed
- The + button shows what it does. In Notes it opens a new note, in Voice it starts
  recording (a red microphone), in Files it picks files, all at once, with no menu. In
  the Library and on the overview, + opens a short row of choices just above it:
  Photos, Camera (the camera takes both photos and videos), Note, Recording, Files.
- A new note no longer shows the red delete button next to Done.

## 0.1.37 (2026-10-24)

### Changed
- The + button sits in the middle, just above the bottom bar (it was on the left or right
  edge, in the way of a thumb swiping the library). The setting for its side is gone.
- The bottom bar is only as wide as its tabs and centred: with one kind of item it no
  longer stretches across the screen.
- Creating a vault and setting a PIN fade in over the page instead of sliding, so the
  two backgrounds never show side by side.

## 0.1.36 (2026-10-23)

### Changed
- Creating a vault: first a page on what the PIN, the vault password and the 24-word
  Recovery Key are each for; then (first vault on this phone) the 24 words, with four of
  them typed back; then the vault password; then the PIN; icon and colour come last and
  can be skipped. Later vaults use the same 24 words and skip those steps.
- Vault password: at least 8 characters. Its strength is shown but a weak one is
  allowed.
- New PINs have at least 6 digits. Vaults with a 4- or 5-digit PIN keep it.

### Security
- Many wrong vault passwords in a row on this phone make you wait before trying again,
  as wrong PINs already did.

## 0.1.35 (2026-10-23)

### Changed
- Importing photos, videos and files: each one is encrypted as soon as the phone has
  copied it, instead of waiting for the whole selection to be copied first.
- Swiping between photos is smoother: the photos beside the one shown are prepared
  ahead, the thumbnail shows at once instead of a spinner, and only the photos near the
  one shown stay in memory.

### Fixed
- Videos in Recently Deleted can be played from their preview.

## 0.1.34 (2026-10-23)

### Added
- Debug: a log of technical timings (each imported item: thumbnail, waiting for the vault,
  encrypting, writing to disk; listing the vault) with Copy and Clear. Kept only while
  debug mode is on, in memory, the last 500 lines; never names or contents.

## 0.1.33 (2026-10-22)

### Added
- Debug: timings of the last import (copy from Photos, thumbnails, encrypt and save,
  total). Numbers only, kept in memory.

## 0.1.32 (2026-10-22)

### Changed
- Adding many photos at once is about three times faster: the phone makes each thumbnail
  at its small size directly (iOS ImageIO, Android ImageDecoder) instead of decoding the
  whole photo, and three photos are prepared at a time.

## 0.1.31 (2026-10-22)

### Added
- Favourites: long press → Favorite. Favourites come first with a gold star, and have
  their own section on the home page.
- Sort (⇅) in every section: newest, oldest, name, largest, and recently edited for notes.
  Files can be shown as a grid.
- Pictures added from Files open as pictures; music and recordings added from Files play.
- ⋯ in the full-screen photo, video and file viewers, with the same menu as a long press.
  The photo viewer swipes through videos too; the library remembers its columns.
- Recently deleted: tap to look at an item, with Restore and Delete for good; Select picks
  several.

### Changed
- Vaults keep an index (SQLite) of their items, sealed like everything else: a vault with
  10,000 items lists in a few hundredths of a second instead of seconds. Built the first
  time a vault opens on this version; nothing is removed, old backups still restore.

## 0.1.30 (2026-10-22)

### Changed
- iPhone: after a screenshot, a card in the middle of the screen stays until you close
  it. With screenshots blocked it says why the picture came out black and how to allow
  one (Settings → Display), with a button to Settings; otherwise it reminds you the
  screenshot sits in Photos unencrypted.

## 0.1.29 (2026-10-22)

### Added
- A long press on anything opens its menu, right where your finger is, like the
  iPhone's Files app: Open, Select, Rename, Group, Info, Send, Delete. It works on the
  home page, in every list and in the photo grid, in search, and in Recently deleted
  (Restore, Delete for good).
- A long press on a group: Open, Rename, Delete.
- Info: name, kind, size, when it was added, length, groups.
- ⋯ in the photo and video preview opens the same menu.
- Delete a note from inside it, with Undo.

### Changed
- Select starts empty, with Select All and Done.

## 0.1.28 (2026-10-22)

### Changed
- One way for every kind of item: a tap opens it (a recording plays), a long press
  selects. With one item selected, the bar at the bottom has Rename next to Send, Group
  and Delete. Rename keeps the file's extension. Notes take their name from their first
  line, so they have no Rename.
- Tapping a photo or video opens it big, over a dark, soft background, with its name and
  date under it and one small glass bar: Close, Full screen, Send, Delete. Swipe down to
  close.

## 0.1.27 (2026-10-22)

### Fixed
- iPhone's own bottom bar (Debug, iOS 26): the glass bubble under your finger is no
  longer cut at the bar's edge, and no longer stays after you lift your finger.

## 0.1.26 (2026-10-22)

### Changed
- No lock button by default: hold the home tab to lock the vault. Settings → Display →
  "Hold Home to Lock" brings the lock button back.
- The bottom bar is the app's own again. The iPhone's own bar (iOS 26) is in Debug, to
  try; it now stacks each icon above its word.
- The ⋯ menu on the lock screen takes the page's colour instead of a white box.

## 0.1.25 (2026-10-21)

### Added
- Recovery Key: 24 words (the BIP39 list, as hardware wallets use), 256 bits. New vaults
  get one; you confirm a word picked at random. Older vaults keep their key and still open.
- iPhone with iOS 26: the bottom bar is the iPhone's own, with Liquid Glass. It can be
  turned off in Debug to compare.
- Settings → Display → "Hold + to lock": no lock button; hold the + to lock the vault.

### Changed
- New names: "Recovery Key" (was Emergency Kit) and "Vault password" (was backup password).
- Settings: one Security group (Face ID, PIN, auto-lock, Recovery Key, vault password,
  how the vault is protected); "Block screenshots" moved next to the blur switches in
  Display; the notes under each setting are gone.
- "How the vault is protected": simpler, five parts, each picture under its title; the
  technical details are shown open.
- The + button is glass like the other round buttons, and as big as the lock button.
- "Delete this vault" is red.

### Fixed
- Tapping a recording on the home page or in search plays it right there, in a card,
  instead of jumping to Voice.

## 0.1.24 (2026-10-21)

### Added
- iPhone: "Block screenshots" (Settings → Security, on by default) now works on iPhone
  too: screenshots and screen recordings come out black. Turn it off when you need a
  screenshot for a bug report.
- Settings → About → Feedback opens safe.cozypi.com/feedback in your browser, in the
  app's language.

## 0.1.23 (2026-10-21)

### Changed
- Opening the app: the lock appears without a jump. The dial from the launch screen
  glides onto the lock screen's dial while the background and the PIN pad fade in.

## 0.1.22 (2026-10-21)

### Changed
- The bottom bar never cuts a word: Overview stays on the left and the other tabs scroll
  sideways when the words are long (French, German, Russian…) or the phone is small.
- Voice has the same + as every other section, Record nearest your thumb; while
  recording the button is the red stop.
- "How the vault is protected": clearer words on why guessing the password is slow.

### Fixed
- The add column no longer shows a dark band across a row at its top edge.

## 0.1.21 (2026-10-21)

### Added
- Overview: a first tab, drawn as your vault's badge, with search, how much the vault
  holds, each section with its count, your groups and what was added last.
- Settings → Display → Appearance: Automatic, Light or Dark.

### Changed
- Search shows the vault at a glance before you type; results are grouped by kind with
  filters, matched words in bold and photos as a grid. Groups can be found by name.
- The lock screen background is more detailed and follows the theme: no more bright
  patches in dark mode, and it shows over the whole page.

## 0.1.20 (2026-10-21)

### Changed
- "Show note text" is now "Hide note text", on by default. Your choice is kept; turning
  it off still asks for Face ID, fingerprint or the phone's passcode.

### Fixed
- Swipe back works wherever there is a Back button: the note editor, Recently deleted,
  the steps of a new vault and an open group. A note swiped away is still saved.

## 0.1.19 (2026-10-21)

### Changed
- Thumbnails are blurred by default (Settings → Display → Blur thumbnails). If you had
  turned it off, it stays off.

## 0.1.18 (2026-10-21)

### Added
- 15 languages (English, Spanish, Portuguese, French, German, Italian, Turkish, Russian,
  Indonesian, Thai, Japanese, Korean, Simplified and Traditional Chinese, Vietnamese).
  Settings → Language, or the system's language setting for the app on iPhone and
  Android 13+; both stay the same.

### Changed
- One way to select in every list: long press (or Select), and every row shows a circle
  while selecting. Voice recordings can now be selected too.
- Unlock: the Face ID / fingerprint button now says what it does, so it is not mistaken
  for the system's own prompt.
- Full-screen photos and videos: every control sits on dark glass and is larger, so it
  stays readable on bright pictures.

## 0.1.17 (2026-10-21)

### Changed
- "How the vault is protected" is now a full page: six short sections, each with a
  picture, saying what protects the vault and what the limits are; technical details
  fold away at the end. It now says plainly that nothing goes to the internet.

## 0.1.16 (2026-10-21)

### Fixed
- iPhone: 0.1.15 did not build (a comment cut a line of the photo picker short), so it
  never reached TestFlight. Same features as 0.1.15.

## 0.1.15 (2026-10-21)

### Added
- After putting photos, videos or files in the vault, you can remove the originals from
  the phone (asked first, then the phone asks again; photos go to Recently Deleted).
- Blur thumbnails in lists for crowded places (Settings → Display).
- iPhone: the screen is covered while it is being recorded or mirrored, and a screenshot
  brings a reminder that it is in Photos, unencrypted (iOS cannot block either).

### Changed
- Unlocking: the dial turns with the vault's colour glowing around it, then swings open
  like a safe's door onto the vault's icon; a little quicker than before.
- Short things to read or pick open in a card in the middle of the screen; changing the
  vault's icon and colour is one card with a live preview.
- Group chips count everything in the group, the same in every section.
- The add column marks where its loop starts with a plain line only.
- Vietnamese: the Secret Key is called "Secret Key" everywhere (it was also called
  "Mã bí mật" in one place).

## 0.1.14 (2026-10-21)

### Added
- Settings → About: version, build date and source commit. Seven taps on the version turn
  on a hidden debug page (after Face ID): technical facts only, never keys or vault content.
- Every opened item can be sent: photos (card and full screen) and notes (as a .txt file).
- Many more files read as text inside the app (Markdown drawn, JSON highlighted, keys and
  certificates, code); any other file can be viewed as text.
- Settings: switch off the vault's icon after unlocking; add button position Left | Right
  right on the row.

### Changed
- Reading text looks like a page;### Changed
- Things to read or long lists open as a page, not a sheet at the bottom of the screen
  (how the vault is protected, all groups, groups for a selection, icons and colours);
  auto-lock is a menu right at its row.
- Reading text looks like a page; a note's first line (its title) is large and bold.
- An open group is clearly marked (filled chip with ✓ and ×, "Group · section" above its
  name); when it has nothing in this section, buttons lead to where it does.
- The add column shows where its loop starts (↻) and dims the repeats; the first few times
  it nudges to show it can be dragged.

### Fixed
- Large files no longer have to fit in memory to be viewed: text decrypts only its first
  1 MB, photos decode at screen size, big PDFs open from a private temporary copy.
- Sending a file kept the vault open only for some items; now for all.

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
