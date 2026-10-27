# Changelog

Preview builds. Each release has one version name on every platform (iPhone,
Android, macOS, Windows, Linux); the build number only matters to the stores.
Dates are UTC.

## 0.1.78 (unreleased)

### Changed
- Version history puts space first, to keep versions as long as possible: until history
  fills its space nothing goes, however old; once full, the oldest versions more than 30
  days old go first, and the last 30 days always stay. Settings → Version history is one
  choice (500 MB, 1 GB, 5 GB, No limit, or Off; 1 GB unless changed) with that rule in a
  short line.

### Fixed
- A first sync with Google Drive said "Looking at Google Drive" for a long time while it
  was reading every item and sending the first files. It now says "Getting items ready
  to send" with a count, then "Sending to Google Drive" from the first byte, and the
  sizes and speed move every second while a big file goes up.
- Every step of a sync says what it does, not only the first time: bringing in is told
  from the start, files Google Drive lost are "Sending missing files again" with a count,
  the daily clean-up is "Clearing old versions", and removing deleted items is told
  before it starts. With a nearby device, the phone being synced with counts items (not
  their files) and says "Checking" while the other phone only reads lists.
- Faster sync: bringing items in now fetches several at once (it went one request after
  another), then takes them in order as before; and a first sync reads the items it
  must fingerprint several at once. Sending already went several at once.

## 0.1.77 (2026-10-27)

### Added
- Android: Settings → Keep the 24 words in your Google account (off unless turned on),
  like the iCloud Keychain option on iPhone. A new Android phone restored from that
  Google account fills in the words and asks only for the vault password. Kept only
  when Google encrypts it end to end, which needs a screen lock on the phone.

### Changed
- + opens a card that names every way to add with a line on what it does (Add photos,
  Record video, Take photo, New note, Voice, Add files); the quick buttons above + stay.
- Editing a note: Done (save and leave) sits beside the format bar while typing, and the
  back button on top is gone; every button is at the bottom, as on the other pages.
- The user guide's Skip is a real button, not grey words.
- Google Drive shows Google Drive's own logo, not a cloud.
- Waiting for a nearby device: the picture stays still (a moving light looked like
  sending), and the tips on what to check come after a minute, not 12 seconds.
- Recently deleted has two parts: what you deleted, and what another device deleted for
  good (kept only on this device, no longer synced). Restore asks first, in blue, with a
  clearer icon (out of the bin).
- Settings in a new order, most important first and like with like: Backup & Sync, the
  vault's keys, screen and auto-lock, getting things back (Recently deleted, Version
  history), the look (with the vault's icon), Help (with How the vault is protected),
  About.
- safe.cozypi.com is black like the app, only the logo green; it offers the phone and
  tablet apps only (the desktop builds stay on the GitHub release page).

### Security
- The hashing libraries move to their new versions (sha2 0.11, hkdf 0.13, argon2 0.6,
  with block-buffer 0.12.1), which fix GHSA-qwgh-2vcv-g2f7. The app was not exposed (no
  hash ever panics there), but the scanners now find nothing.

### Fixed
- Version history: changes made within the same millisecond could list in the wrong
  order.

## 0.1.76 (2026-10-27)

### Added
- Version history: every item keeps its older versions on this device (any change:
  content, name, groups, favourite). Hold an item → Version history lists them by time
  and device; open one to see it, and Restore This Version brings it back (the version
  you had is kept too, so a restore can be undone). Settings → Version history sets how
  long (Off, 7, 30 or 90 days; 30 unless changed) and how much space (500 MB, 1 GB, 5 GB
  or no limit; 1 GB unless changed); the oldest go first, the current version never.
  History stays on this device: not synced, not in backups. Renaming a photo keeps no
  second copy of it. It shows in the storage line as History.

### Changed
- A sync keeps running when the vault locks while you use the app (auto-lock, Hold Home,
  the lock button): the lock screen shows as usual, with a small line showing how far the
  sync is ("Syncing 40%", then "Up to date"), and the screen stays on until it ends. The
  vault stays locked for everything else, and its key is wiped as soon as the sync ends
  (docs/security.md). Leaving the app still locks and stops the sync, as before.
- Nearby sync starts by itself: both screens name the other device and show the same
  number, count down 5 seconds, and go. Cancel stops it. No Sync or Allow to tap.
- Restoring from a nearby device needs no switch on the old phone any more: open Sync
  with a nearby device there, and the new phone (24 words and password) finds it.
- The new phone gets only the vault's lock first. It must open it with the
  password and prove so before a single item is sent; with a wrong password it says so,
  the old phone shows "Wrong password on the other device" and stops.
- Much less text: the Sync screen, the nearby screens, Google Drive, Settings and the
  pages under it keep titles, buttons and one short line where a mistake would cost you.
  A picture says the rest: your device, a lock on the way, the other device.
- The transfer animation has a lock on the path: what travels passes behind it,
  encrypted on the way. The waiting screen shows it too.
- Settings look like the iPhone's: groups have no names, a gap sets them apart. Sync and
  Back up to a file are the first group. The vault's keys (Face ID, PIN, Recovery Key,
  password) are one group; what shields the screen (auto-lock, lock on leaving, blocking
  screenshots, blurring, hiding note text) is the next.
- The storage line in Settings shows the kinds by name only, like the iPhone's Storage,
  and comes at once when Settings opens again (it is measured again behind).
- Google Drive: Sign in again (with the account it uses) and Remove account. Removing
  asks first, takes back Cozy Safe's access at Google and leaves your files on Drive.
- No network addresses on screen any more: the other device is named.
- Recently deleted: one left edge for everything; the photo grid sits inside it with
  rounded corners, like the cards below.
- Recent connections are behind one row in Sync, one short line each.
- Google Drive errors say what happened: Drive full, too many requests, Google's servers.
  "Too many requests" and server faults are tried again by themselves after a pause
  (up to 4 times) before the sync stops. A 403 is no longer always "sign in again".
- Every Google Drive sync checks that Drive still holds every file it relies on, from
  the SHA-256 Google lists with each file (no extra request). A file lost or damaged
  there is sent again from this phone, and the end of the sync says how many. An item
  whose copy here is not right either is counted apart: sync it from a device that has it.
- The PIN is much harder to attack: its device key is kept inside the phone's secure
  chip (Secure Enclave on iPhone, the Android Keystore), so a copy of the phone's storage
  is useless for guessing PINs elsewhere. Waits after wrong PINs cannot be shortened by
  changing the date and time. After 10 wrong PINs in a row the PIN is removed and the
  vault opens with its password (a vault without a password keeps its PIN).
- Settings → Check your 24 words and password: type them back to know they still open
  this vault. They are only compared, never shown or kept.
- iPhone: Settings → Keep the 24 words in iCloud Keychain, off unless you turn it on (it
  asks for Face ID and says the trade). A new iPhone with your Apple account then fills
  the words in by itself and asks only for the password. Android comes later.
- Notes: Undo and Redo at the start of the format bar while you type (also Cmd+Z and
  Shift+Cmd+Z on a keyboard); they step back through formatting too.
- An error log, always on: every failure is kept as a short code and a time (never
  names, content, keys or addresses), the last 200. Settings → Report a problem lists
  them, with Copy details and Feedback. A failed sync shows its code and Copy details.

## 0.1.75 (2026-10-26)

### Fixed
- A sync no longer gets cut because the vault locked itself for lack of touches: while a
  sync waits or runs, the auto-lock waits too, and the screen stays on (also while waiting
  for a nearby device). Leaving the app still locks as set.

## 0.1.74 (2026-10-26)

### Added
- A quick tour right after you create a vault, shown as tips on the vault itself: the
  page dims, the button being explained stays lit, and a small bubble says what it does.
  It shows where to add things, how to open them (tap, hold for the menu, hold and drag
  to pick many), the tabs, Settings, how the vault locks itself, and why to keep a second
  copy, with a "Set up sync now" button and a reminder that your 24 words and password are
  the only way back on a new phone. Next and Skip are in the bubble.
- After restoring a vault on a new device, a shorter tour: adding, opening, the tabs and
  Settings.
- Settings → Help & guide → User guide, near the top of Settings: runs the tips on the
  vault again, then goes on in Settings with Sync, Security, Back up your data and where to
  find the guide. Feedback moved to the same group.
- Settings → Security → "Lock as soon as I leave the app", on by default. Turned off
  (asks for Face ID or the passcode), leaving the app no longer locks the vault at once:
  it locks after the auto-lock time, counted from when you left, on a clock that changing
  the phone's time cannot hold back. The app switcher still shows a cover, not the vault.

### Changed
- Settings: every security switch is in one Security group (Face ID, PIN, auto-lock, lock
  on leaving, hold Home to lock, block screenshots, blur thumbnails, hide note text,
  Recovery Key, vault password). Display keeps appearance, language and the add button.
- Android 13 and later: Recent apps never show the vault, even with screenshots allowed.

## 0.1.73 (2026-10-26)

### Fixed
- Syncing after a while without it is much faster: the other devices' change lists are
  read several at once, and items already up to date here are no longer fetched again.
  "Looking at Google Drive" now counts what it has read.
- Debug's log notes how long each step of a Google Drive sync takes.

## 0.1.72 (2026-10-26)

### Changed
- Syncing with a nearby device works like pairing Bluetooth: open Sync, Sync with a
  nearby device on both devices and wait. They find each other on the Wi‑Fi by
  themselves; no code to type.
- Both screens then ask "Sync with iPhone 15 Pro Max?" (the other device's name) next to
  the same 3-digit number. Check the numbers match and tap Sync on both; the sync starts
  only when both said yes. Cancel on either device stops both, and the other says so.
- Several of your devices waiting at once: the screen lists them by name, and you pick
  one.
- Restoring a new phone from your old one: open the same screen on the old phone and
  turn on "Help a new device restore"; the new phone finds it by itself, and the old
  phone asks "Let iPhone 16 restore this vault?" with the number.
- A QR code stays for networks where the devices cannot find each other ("Use a QR code
  instead").
- Recent connections name the other device instead of its address.

## 0.1.71 (2026-10-26)

### Changed
- Every delete now asks first, in the same card at the bottom of the screen: deleting an
  item (from its menu, the preview, the photo, video or file page, the note editor or the
  selection bar), deleting a group, and deleting for good. The card says how many items
  ("Move 3 items to Recently deleted?") or which one. Undo still appears after.
- Recently deleted is laid out like the vault: photos and videos as thumbnails, then notes,
  recordings and files, each with the days it has left. Items deleted on another device are
  marked. An empty page says what it is for.
- Recently deleted no longer has "Restore all" or "Delete all". Tap Select, pick what you
  want, then Restore or Delete for good; Select all is in the same bar.
- In Recently deleted, holding an item and its preview offer the same three actions, in
  the same order: Restore, Info, Delete for good. Info shows when it was deleted and until
  when it is kept.

### Added
- Hold an item, then drag across others to select them all at once, as in Photos on
  iPhone. Drag back to unselect. Works in the vault's photos, notes, recordings and files,
  and in Recently deleted. Holding still and letting go still opens the item's menu.

### Fixed
- Videos in Recently deleted show their thumbnail instead of a plain icon.

## 0.1.70 (2026-10-26)

### Fixed
- Android: syncing with Google Drive no longer shows a Google sign-in box every time;
  after the first time it signs in quietly, as on iPhone.

## 0.1.69 (2026-10-25)

### Security
- New passwords must be harder to guess: not one of the 100,000 most used passwords
  (also with a number or symbol added), and either strong enough or four different
  words. The screen says why a password is refused and how to fix it ("Suggest a
  password" always works). Passwords you already use keep working.
- A vault whose files were changed to make the password easier to crack (lower
  password-hashing cost) no longer opens; the same goes for a backup or a Google Drive
  copy changed that way.
- Restoring a new phone from your other phone now needs your OK there: turn on "Help a
  new device restore" on the waiting screen (off by default), then tap Allow when the
  same number shows on both phones.
- The short key fingerprint stored next to your vault (it tells a wrong Recovery Key
  from a wrong password) is now 4 characters instead of 16, so it says less about your
  key. Older ones still work and are shortened the next time the vault opens.
- Your vaults are kept out of iCloud and computer backups on iPhone, and out of Google
  backups and phone-to-phone transfers on Android.
- Changing the password or the Recovery Key now says plainly that items already in the
  vault are not encrypted again (only the key that opens the vault changes).

## 0.1.68 (2026-10-25)

### Changed
- "Hide note text" is back (on by default) for the lists and search only: someone beside
  you sees a note's title, not its lines. An opened note always shows in full.

## 0.1.67 (2026-10-25)

### Added
- Notes show their formatting in the preview: headings (`# `), **bold**, *italic*, lists
  (`- `) and to-do lists (`- [ ] task`, `- [x] done`). What you type is kept as plain text.
- Tick a to-do box right in the preview; the note is saved at once.
- Web addresses in notes (https://…, www.…) are underlined. Tapping one first asks
  "Open … in the browser?" with the real site name; names with foreign letters show in
  their xn-- form so a fake look-alike site stands out. Only web pages open.
- While editing a note, a small bar over the keyboard adds Bold, Italic, Heading, List,
  To-do and Link marks for you; the marks show lightly as you type.

### Changed
- The page behind an opened item is lighter and less blurred, so you can still see where
  you are.
- An opened note always shows in full ("Tap to show" is gone).
- An opened item's buttons now sit in the bottom bar's place, the same size and shape,
  instead of a second row above it.
- Buttons moved to the bottom of the screen, where your thumb reaches: Done, Send and
  Delete in a note (while typing, the format bar gets a button that hides the keyboard),
  Send, Delete and More on an opened file, Select and Done in Recently deleted and when
  choosing items, the search box, Close on info cards, and the main button of every
  form (Next, Save, Unlock, Delete vault…), which stays just above the keyboard.
- The code for syncing with a nearby device is 3 digits instead of 6. It was never what
  keeps others out (only a device with this vault can pair); it picks which device.
- Syncing says simply "Sending data" or "Receiving data".
- While syncing, your device is blue and the other end (device or Google Drive) green;
  the data travelling takes the colour of the side sending it.

## 0.1.66 (2026-10-25)

### Changed
- Settings: Sync is first, with when this vault last synced. The Sync page has two
  blocks: Local network (Show a code, Enter a code) and Google Drive (Sync now).
- Every item now opens the same way: big, over the page you are on, with its name, date
  and size underneath and one row of buttons: Close, Open, Send, More and Delete (in red).
  Open goes further: full screen for a photo or video, Edit for a note, the reader for a
  PDF or text file, another app for any other file.
- A note shows its first lines on a page (only its title when "Hide note text" is on), a
  PDF its first page, a text file its first lines, any other file its icon, kind and size.
- A recording opens the same way, also in Voice, and plays inside with a big play button.
- A photo shows its thumbnail at once and turns sharp when the full photo is ready; a video
  shows its still with a spinning ring while it gets ready to play.
- Recently deleted uses the same view, with Close, Restore and Delete for good, and how
  many days are left.
- Delete is red everywhere, also in full screen and in the PDF, picture and file pages.

### Fixed
- A photo, PDF or file still loading when the vault locked loads again after opening
  the vault, instead of a read error.
- iPhone photos (HEIC) open on Android (Android 9 and later).

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
- Leaving the app for a moment no longer loses your place: after opening the vault
  again you are back on the page you were on (a note being written, a photo or video,
  Recently deleted, search, tags, sync, the Recovery Key and password pages). Shown
  words are hidden again and typed passwords and PINs are cleared when the vault locks.
- A Google Drive sync stopped by the vault locking continues by itself once the vault
  is open again. A sync with another device says the vault locked and can be started
  again.
- Face ID no longer pops up over New vault or Restore opened from the lock screen after
  switching apps, wiping what was half done.
- A long import stopped by the vault locking could leave the vault screen without the
  lock screen.

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
