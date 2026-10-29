# UI

> **Start with `docs/design-language.md`**: the short rules, numbers and shared pieces
> every new screen must use. This file keeps the history and the reasons.

One design, light and dark only (see `requirements.md`, Theming). Brand colours:
vault green `#165B4C` (deep `#0F3D33`, night `#0B2B24`), gold index `#F3D08E` /
`#D9A53F`, neutrals from the app theme (`app/lib/theme.dart`).

The brand mark is the combination dial reduced to three shapes: one thick ring,
a solid knob, the gold index (`branding/icon.svg`). Use it at every size; no tick
marks or extra detail.

## Mockups (rule, 2026-10-20)

Mockups are the app's own screens, never redrawn by hand: a hand-drawn page drifted
from the app (lock screen, unlock animation, date formats, menus, sizes) and from itself.

1. Change the code on a local branch; do not push before the proposal is approved.
2. Run `app/tool/mockup.sh "Title"`: it renders every screen listed in
   `app/test/preview_test.dart` at 430×932 (iPhone 15 Pro Max) in dark and light,
   and builds `app/test/preview/index.html` (each screen dark | light, with its caption).
3. Publish that page with the PNGs next to it, and list what changed. Mark it in the
   harness too (`change:` and `marks:` on `_screen`): the page lists the changed screens
   first and outlines the changed parts.
5. The renders must look like the owner's iPhone, or reviewers chase ghosts: Face ID (not
   a fingerprint), every font the app uses loaded (the Secret Key's mono font), real states
   (biometrics on, thumbnails in Recently deleted), sample data of the right kind.
6. Optional persona review before showing the owner: reviewers each play one user (an
   older person, a privacy-minded one, a first-time user) and walk the shots through real
   tasks. Every finding is checked against the code before it counts; findings that go
   against an approved decision go to the owner, not straight into the code.
4. A new screen or state is added to the list in `preview_test.dart` (`_screen(...)`),
   so every later mockup shows it too. Animations are captured by freezing the real
   animation at fixed moments (see the unlock frames), not imitated.

Changed screens are marked for review: `_screen(..., change: 'what changed', marks: [finders])`
in `test/preview_test.dart`; the page lists them at the top and outlines the marked parts.

## Unlock screen (chosen 2026-10-19: "B2")

- **Launch** (2026-10-21): the system launch screen stays the page colour with the dial in
  the middle (120 pt; Android 12+ draws its own icon splash). The app's first frame looks
  the same, then the dial flies onto the lock screen's dial while the background and the
  PIN card show through (`LaunchHandoff`, 0.56 s, cold start only). Other first screens
  (new vault, restore): the dial shrinks away.

- Background: a collage of protected items (photo, ID card, receipt, note, PDF,
  passport) tilted about −8°, **always blurred** so nothing is readable, drawn in the
  theme's own greys (2026-10-21: light shapes on the dark theme showed as bright
  patches) under an even veil, so it shows over the whole page.
- The collage is a **fixed illustration bundled with the app**, never thumbnails
  of the user's data: the screen runs while every vault is locked. Ship it as a
  pre-blurred image, not a live blur.
- No motion on this screen. Floating/appearing items were tried and dropped as
  too playful for a vault.
- The one exception is the moment it opens (approved 2026-10-19): a vault-green
  overlay, the brand dial large in the centre turns half a turn (overshoots to
  ~192°, settles at 180°) and scales out to reveal the vault, about 1.1 s.
  With reduced motion: fade only.
- Centre: a frosted card with the brand mark on its top edge and the title, no
  subtitle and no item counts.
- Unlock order (approved 2026-10-19, mockup
  (internal mockup)): biometrics are asked for
  as soon as the screen shows; then the **password** (type to unlock, no Enter
  needed). No PIN since 2026-10-28 (decisions); the PIN pad shows only for a vault
  made with a PIN and never given a password. On a computer the password field has
  the blinking caret from the start, and again after Touch ID is cancelled, so it is
  clear that typing works (owner 2026-10-28).
- Spacing: at least 32 px between the card (with its "Use password" link) and the
  top row of keys, so the link is never hit instead of 1·2·3 (user report on 0.1.0).
- The **add dock** (below) fills the bottom, identical to the one inside a
  vault. Left slot: a closed lock (state, not a button). Right slot: Face ID or
  fingerprint. Picking an add action while locked unlocks first, then runs it.
- Light: white card, green accents. Dark: green-black card, gold accents.
- Closing plays the opening moment backwards: the dial comes in from large,
  turns back half a turn, and the lock screen appears.
  (Previously: biometrics as an outlined button under Unlock; moved into the
  dock with the PIN pad.)

## Inside a vault

Mockup: (internal mockup) (v3, learned from
Apple Photos iOS 26, Google Photos, Files, Proton Drive, Ente Photos).

- Header: the vault's coloured icon (tap: change icon and colour), no text, and a
  menu: icon and colour · vault password · Face ID · back up ·
  Recovery Key · new vault. Settings and Delete vault join it (review below).
- Without a vault password, a banner under the header says what is at stake
  (review below) with "Set it".
- **Library | Collections.** Library: everything by date (Today, Yesterday,
  This week, then months). Collections: Photos, Documents, Notes, Recently
  deleted, and the user's folders.
- Photos **edge to edge**, 2 px gaps, no corner radius; pinch to fit 3 or 5 per
  row. Documents and notes as a **list** (name, kind, date), never cropped tiles.
- Viewer: swipe sideways through photos, swipe down to close, tap to hide the
  bars; actions at the bottom.
- Delete goes to Recently deleted for 30 days (v0.1 stage 4).

### Add strip (approved 2026-10-19)

> Replaced by the vault bar (0.1.6).

Mockup: (internal mockup)

- The bottom of the vault screen is a dark green dock, like the iPhone Camera
  mode dial: a horizontal strip of modes (Note · Library · Take photo · Scan ·
  File · Paste) that the thumb drags or taps; the selected mode is gold.
- One big round action button under the strip, always in the same place; its
  icon follows the mode. In Take photo it becomes a white shutter.
- The last-used mode is remembered per device and selected on the next open.
- Round slots beside the button. Inside a vault: Lock (left), Search (right);
  the lock is here, not top right, because the top corner is the hardest place
  to reach with one hand. On the lock screen: closed lock, biometrics.
- **One component** (`app/lib/widgets/add_dock.dart`) for both screens, same
  colour (#0A2A23), height, button size (72 px), so they cannot drift apart.
- Everything you add with lives in the bottom third of the screen (one hand).

Mockup v2 covers the vault home (quick add: camera, photos, files, note;
recent items with thumbnails; photo and document grid; bottom navigation and a
+ button), the add sheet, note editor, file viewer, in-app camera, settings,
Recovery Key, and a three-column desktop layout, each in light and dark.

### Folders (decided 2026-10-19)

> Replaced by groups (0.1.7, below).

- Nested folders, like Files or a desktop: a folder holds items and folders,
  and every item lives in exactly one place. Move by drag and drop or "Move to".
- Importing a whole folder from the computer keeps its structure.
- The Library tab still shows every photo by date regardless of folder;
  Collections shows types (Photos, Documents, Notes, Recently deleted) and
  the user's folders.
- Folder names are encrypted like everything else (never plain file names on disk).

## First run and vault identity (approved 2026-10-19)

Mockups: first run (internal mockup) ·
flows (internal mockup)

- **Fewest possible steps, one thing per step**, progress bar on top, back button.
  Tapping a choice moves on (no "Next" on choice steps).
  1. "Create your first vault": pick an icon (11 common ones + a "⋯" tile that opens
     the full set of 35). **No text on icons or colours anywhere**: the picture is
     enough and nothing needs translating; names exist only for screen readers.
  2. Pick a colour (11 + "⋯" for the full set of 20, hand-picked so no two look
     alike; generated hue steps looked the same). The whole screen background
     takes the colour.
  (Since 2026-10-28 the order is: what each key is for → 24 words → vault password,
  which makes the vault → "Open with Face ID?" Turn on / Not now, whenever the device
  has biometrics → icon and colour. No PIN step.)
- **No vault names.** Icon + colour (35 × 20 = 700 combinations) identify a vault;
  inside the vault only the coloured icon is shown, no text. A new vault (the first one too) starts with a random
  icon and colour from the 11 shown on each grid (grid order stays fixed, only the
  preselection changes), avoiding the open vault's own when created from inside it.
  Combinations are not checked against other vaults: the app cannot see them
  while locked, and a readable list would show how many vaults exist.
- (History, replaced: no PIN since 2026-10-28.) **No password at the start.** Each vault opens with its own PIN on this device
  (a PIN picks its vault, like the password does) and the default vault also
  with Face ID. The **vault password** and the **Recovery Key** are set later, on
  one screen ("Suggest a password", type it again, then the kit with a QR code):
  required before the first backup, gently suggested from inside the vault.
- Wrong PINs: waits that grow (1, 5, 15, 60 min), never a lockout, since a vault
  may have no password yet.
- Splash: vault green with the dial where the lock screen has it.
- Locking: by hand (animation), on leaving the app (immediately, 60 s grace when
  the app itself opened the camera, a picker or the share sheet), after 2 minutes
  without a touch. Face ID is not asked again right after locking by hand.
  Settings → Security → "Lock as soon as I leave the app" (on by default; 2026-10-26):
  off, leaving does not lock; the auto-lock time runs from the moment the app left
  (`AwayClock`, lib/lock_guard.dart) and the vault locks at that mark if the app still
  runs, or on return before anything shows.
- Opening the same vault again comes back to exactly the page the person was on (owner
  2026-10-25), the Recovery Key and password pages too: every page stays under the lock
  screen; only dialogs, sheets, cards and menus close, as Cancel. On lock, shown words
  are masked again, typed passwords and PINs are cleared, players and cameras stop (and
  start again after), a Google Drive sync stops and continues after; a sync with another
  device ends and says so (`lib/lock_resume.dart`). Face ID is asked on return only when
  the lock screen is on top, never under New vault or Restore opened from it.
- With a vault password, the lock screen asks for it once every 14 days instead
  of Face ID, so it is not forgotten.

## User review, 2026-10-19 (what changes next)

We used 0.1.1 as a careful user who knows 1Password and Proton Pass would.
Fixed in 0.1.1 already: a vault could be created from the lock screen to test
whether a PIN belongs to another vault without any wait; typing a note could be
lost when the vault locked (idle or leaving the app); touches on the note editor
and viewers did not count as activity; the PIN card sat too close to the keys.

What a user stumbles on, in order of harm. Screens marked *mockup* are approved
before they are built (the usual rule).

1. **"Forget the PIN and it's gone" is never said.** The PIN step says it under the
   dots ("Without a vault password, a forgotten PIN can't be recovered."), and the
   banner in the vault says the stake, not the mechanism: "Only on this phone. Lose
   it or forget the PIN and this vault is gone." with "Set vault password".
2. **The app switcher shows the vault.** A plain vault-green cover with the dial (the
   splash) whenever the app is not active. No setting on iOS.
3. **Imported photos stay in Photos.** After importing from the library: "Delete the
   originals from Photos?" through the system's own prompt; never automatic. Files
   from a folder: same offer when the source allows deleting. *mockup*
4. **Delete is forever.** Recently deleted for 30 days (already in Stage 4); the
   viewer's Delete moves there and says "Moved to Recently deleted". *mockup*
5. **Files only open in other apps.** Built-in viewers for PDF, images and video;
   "Open in another app" stays as a secondary action with its warning. *mockup*
6. **No Settings.** One screen from the vault menu: auto-lock (1, 2, 5, 10 min;
   leaving the app always locks at once, so "immediately" would add nothing), Face ID for this vault, change PIN, vault password, Recovery Key, last
   backup date, storage used, block screenshots (Android), language, theme. *mockup*
7. **Which vault does Face ID open?** The menu says "Face ID opens this vault";
   turning it on here moves it from the other vault (one per device).
8. **Backups leave some vaults out silently.** The backup step says, always in the
   same words, that vaults without a vault password are not included.
9. **No way to delete a vault.** Menu → Delete vault, confirmed by typing its PIN;
   locks and returns to the lock screen.
10. **After restoring on a new phone there is no PIN.** After the first password
    unlock of a restored vault, offer "Set a PIN for this phone" (same pad).
11. **Copied note text stays on the clipboard.** Marked sensitive (no Universal
    Clipboard, hidden from Android's clipboard preview) and cleared after 60 s and
    on lock.
12. **Big imports show only "Encrypting…".** A progress bar with a count (3 of 12)
    and Cancel; nothing half-imported appears.
13. **Last backup is unknown.** Shown in the menu and Settings; a nudge after 30 days
    with new items.

Worth saying, not changing: photos taken with the in-app camera never touch the
photo library (one line on the camera screen the first time); a second vault with
its own PIN is a practical decoy (one line in the help, without promising
deniability).

## Lock screen, vault colour, Settings (approved 2026-10-20, 0.1.2)

- **The lock screen only opens vaults.** No add dock there any more. The bottom row
  has a ⋯ button under the left thumb (Use password / Use PIN, Create a new vault,
  Restore from a backup) and Face ID or fingerprint in the middle. Nothing under the
  PIN card.
- **Creating another vault needs the phone's owner**: Face ID, fingerprint or the
  phone's passcode (the system's own check), from the lock screen and from inside a
  vault. The first vault on a device does not ask.
- **Turned off 2026-10-20** (the owner found it often looked wrong; the app keeps the
  brand green/gold theme; the vault colour stays on its icon, the Settings card and the
  opening animation). `VaultPalette` and `_tintApp` in `vault_home.dart` bring it back.
- **Design B: the open vault's colour is the whole app's colour.** Light: the colour
  mixed pale with dark text; dark: the colour deepened with light text; the dock is
  the colour, darker. Rules that keep content readable:
  1. Notes, files and Settings rows sit on neutral cards; the photo viewer is black.
  2. Every text colour is computed per vault colour to reach 4.5:1 on what it sits on
     (`VaultPalette` in `app/lib/theme.dart`; `test/theme_test.dart` checks all 20
     colours in light and dark).
  3. Red and warning colours only ever sit on neutral cards.
  The lock screen keeps the brand green, so it never shows which vault colours exist.
- **Settings** looks like the system's own: the vault card on top (its icon on its
  colour, size split by photos / files / notes, last backup), then grouped rows with a
  white symbol on its own colour. Order since 2026-10-26: Backup & Sync (Sync with its last
  time, Back up to a file with its button; one group since 2026-10-26) · Help & guide (User guide,
  Feedback) · This vault · **Security, every protection in one group** (Face ID, PIN,
  auto-lock, lock as soon as I leave, hold Home to lock, block screenshots, blur
  thumbnails, hide note text, Recovery Key, vault password, how the vault is protected) ·
  Display (appearance, language, add button side: nothing that
  protects) · Delete this vault alone · About. Little text (owner 2026-10-26): titles,
  labels and values; no row notes or group footers; a sentence only where a mistake would
  cost the vault (the 24 words and password, the 30-day trash rule, deleting a vault).
- **Checking the build against the mockups**: `flutter test test/preview_test.dart
  --update-goldens --dart-define=PREVIEW=true` renders the real screens (fake vault
  data) to `app/test/preview/*.png` in a few seconds.

## Vault content (approved 2026-10-20, 0.1.3)

- **The dock's mode strip is the content filter.** Notes · Library · Camera · Files.
  Dragging switches the moment a label crosses the middle (a light tick each time),
  not on release; tapping a label switches too. No tabs at the top.
  - Library: photos and videos only, by date, 4 per row with 1 px gaps (pinch for
    3 / 5 / 7). Videos show a play mark and their length.
  - Notes: one card of equal-height rows: title, two lines of what follows, date.
  - Files: one card of rows: the file type, name, size, date.
  - Camera: the preview takes the whole area above the dock (the header steps
    aside); the dock's round button shoots; the last shot sits bottom left, switch
    camera bottom right.
- **The middle button follows the mode.** Only Camera is a round shutter. The others
  are a gold button that says what it does: Pick photos, New note, Pick files.
- The vault opens in the mode used last, **never in Camera** (that opens Library).
- Every mode has an empty state that says how to add the first item.
- **Search** (dock, right): names of everything plus the text of notes, ignoring case
  and Vietnamese accents ("thuoc" finds "Thuốc"). Note text is decrypted in memory for
  the search screen only.
- **Select several**: long-press any square or row; tap to add more; the dock becomes
  Send · Delete; the header shows the count and Cancel.
- **PDF** opens inside the app from the decrypted bytes in memory (pdfrx). **Video**
  plays inside the app on iOS, Android and macOS; the player needs a file, so a copy is
  decrypted into the app's private temp folder and deleted on close, on lock and at
  every start. Elsewhere, videos open in another app with the warning.

## Folders (approved 2026-10-20, 0.1.4)

> Replaced by groups (0.1.7, below).

- Folders live in Files mode, like the Files app: coloured folder tiles first (name and
  item count), a dashed "New folder" tile, then the loose files. Inside a folder: a back
  arrow and the path (Files › Papers › Passport), its subfolders, then everything in it
  (photos with their preview, notes, files). ⋯ renames, recolours or deletes it.
- A folder is an encrypted item of kind "folder"; items record the folder they are in.
  Deleting a folder moves what it holds up one level. A folder cannot go inside itself.
- Long-press to select, then Move: the folder tree (indented), "Files (no folder)", or
  "New folder…". Library still shows every photo by date, whatever folder it is in.

## Voice memos (approved 2026-10-20, 0.1.5)

- A "Voice" mode in the dock strip (Notes · Library · Camera · Voice · Files), phones
  only. The middle button: white ring, red core, white microphone; Stop while recording.
- The list: name, date, length; ▶ plays in place with a progress bar; tapping a row
  offers Rename, Send, Delete. Recording: level bars and a large timer.
- The recorder writes to the app's private temp folder; the file is encrypted into the
  vault and deleted as soon as recording stops, and before the vault locks.

## Vault bar (approved 2026-10-20, 0.1.6)

Replaces the dock and the add strip. **Partly superseded** by the design language (0.1.10):
no vault icon in the header, folders became groups, only sections with items are offered,
and the main action works as described there.

- Content runs edge to edge; it fades out under the floating controls, and every list
  ends with room for them so the last row is never covered.
- Top: the vault icon (tap: change icon), a large title (the kind, or the open folder's
  name with Back and a ⋯ menu for Rename / Delete), then Search and Settings as glass
  circles.
- Under the title: the folders of the kind on show, as chips (colour, name, count), then
  "New folder" ("New album" in the Library). Long press a chip to select it. Folder
  creation stays here, not in the + button.
- Bottom row, floating glass: the lock circle, then a capsule with Notes · Library ·
  Voice (phones) · Files. Tap or slide to switch; the last kind is remembered.
- The main action floats above the lock, for the left thumb:
  Notes: pen in a square (new note) · Library: + with Add photos from device · Take
  photo · Record video (desktop: + picks photos) · Voice: red button, white mic, Stop
  while recording · Files: + opens the file picker.
- The camera opens full screen from the Library with a Photo | Video switch, a shutter,
  the last shot and flip. What it takes goes into the open album.
- Glass: blur only behind the small controls (grouped backdrop); with Increase contrast
  on it is a solid fill. A setting for left/right hand may come later.
- Each kind has its own folder tree (`space` on the folder). Folders from before have
  none and belong to Files. At a kind's top level it shows items not in one of its own
  folders.

## Groups (approved 2026-10-20, 0.1.7)

Groups ("nhóm"; tags in the code, `docs/naming.md`) replace folders.

- One set of groups for the whole vault. An item can be in several groups ("Passport":
  the photo, the PDF scan and the note). A group has a name only, no colour.
- The chip row under the title: first a group button (always visible) that opens
  **All groups** (every group with its count, and New group); then the groups that have
  something in this section, with the count for this section; last **New group**.
- Tapping a chip opens the group: the title becomes its name with Back and ⋯ (Rename,
  Delete group). The group stays open while switching sections, so you see its notes,
  photos, recordings and files in turn. Its chip moves to the front of the row.
- Deleting a group never deletes items.
- Anything added while a group is open (note, photo, video, recording, file) is put in it.
- Selecting items: the bar offers Send · Group · Delete. **Group** opens a sheet with a
  checkbox per group: on, off, or a dash when only part of the selection is in it; and
  New group.
- Old folders become groups of the same name; nested folders become separate groups.

## Camera (approved 2026-10-20, 0.1.7)

**Since 0.1.10** close sits in the bottom row (swipe down closes too) and the last shot is
in the viewfinder's corner; see the design language. Opened from the Library's + menu (Take photo / Record video). It keeps the app's frame:
the page background, a glass close button and the large title ("Take photo" / "Record
video", with a red timer while recording), the viewfinder as a rounded card, then the
Photo | Video switch in a glass capsule, and last shot · shutter · flip. The shutter is
the ink colour for photos and red for video; it turns into a square while recording.

## Names of photos, videos and recordings (0.1.7)

Made in the vault, or picked with a name the picker made up (`image_picker_…`, a UUID, a
bare number): the kind and the moment, `Ảnh 20-10-2026 21.40.12.jpg`, `Video …mp4`,
`Ghi âm …m4a` (English: Photo / Video / Recording). No `/` or `:`, so the name also works
as a file name when sent out. Names a person or camera gave (`IMG_4810.HEIC`, a PDF's
name) are kept.


## Black and white (approved 2026-10-20)

- One ink (white in dark mode, black in light) on the page colour (black / white);
  everything else is that ink at an opacity: cards, chips, glass, muted text. The
  selection bar is glass like the bottom bar (since 0.1.10). Light and dark follow the system.
- The one colour left: **a vault's own icon and colour** (`VaultBadge`), so you know
  which vault is open; in Settings; when creating a vault (the colour step stays). No vault
  icon in the vault's header any more.
- **Unlocking, in order** (owner 2026-10-20): the dial effect (its motion, in ink) → on the
  plain page colour, the vault's icon comes in, holds, fades → only then does the content
  show. Nothing of the vault is visible or tappable before the icon has gone.
- **Splash** (Android, iOS) and the app-switcher cover (iOS): the page colour with the dial
  in ink, white/black following the phone's light or dark mode.
- Users' photos and videos keep their colours, of course.
- **Recording is red** (owner 2026-10-20, replaces "recording and video are not red"): the
  voice button (white mic on red), the video shutter, the running timers and the level meter
  use the system red (`recordRed`, theme.dart), as on every phone. Taking a photo stays ink.
  The video shutter is still a smaller disc than the photo one and turns into a square while
  recording.
- **Settings tiles have colour** (owner 2026-10-20): each row's symbol is white on its own iOS
  system colour. Biometrics show the device's real symbol (Face ID glyph, or a fingerprint).
- Messages float as a glass capsule (`showToast`, widgets/toast.dart); in a vault they sit on
  the row of the main action, beside it, never over the bottom bar.
- **Main action on the left or right** (Settings → Display → Add button; left by default,
  under the left thumb). Messages move to the other side of it.
- Notes list: title, then when it was made (time today, weekday this week, else the
  date). The first words show only with Settings → Security → Hide note text turned off (0.1.10;
  `docs/security.md`). Sections and groups change with a short fade.
- **Settings may use colour, softly** (owner 2026-10-21): the storage bar in one colour per
  kind (photos blue, videos purple, notes yellow, voice orange, files green), the storage
  card on the groups' surface, Back up now a soft blue tint, switches iOS green when on.
  No black slab in light mode, no white slab in dark mode; dark-mode filled buttons
  elsewhere are a soft grey.
- **Destructive actions are red** (owner 2026-10-21): Delete in the selection bar and
  Delete for good in Recently deleted use the system red, apart from the safe choice.
- Deleting a vault uses the opposite brightness (light when the app is dark, and the
  reverse) instead of red, so it is never taken for the lock screen.
- Security rules (owner check, hidden secrets): `docs/security.md`.

## Design language (approved 2026-10-21, 0.1.10)

One set of sizes for every screen, in `Ui` (`app/lib/theme.dart`); a new control takes
its size from there, never a number of its own. The owner asked for bigger buttons
everywhere, easy to hit with a thumb.

| Token | Size | Used for |
|---|---|---|
| `Ui.circle` | 48 | round glass buttons (back, search, settings, close in sheets) |
| `Ui.bar` | 56 | bottom bar height, lock, camera close and flip |
| `Ui.primary` | 64 | the one main action on a screen (+, record) |
| `Ui.chip` | 40 | group chips, Photo / Video switch |
| `Ui.tile` / `Ui.radius` | 96 / 18 | add tiles, cards |
| `Ui.edge` | 10 | gap from the screen's edge to floating controls |

- **Vault icon: a circle** in the vault's colour (owner chose round over a squircle,
  2026-10-21), a little light from above and a soft coloured shadow when large; no white
  ring. Same shape at every size (unlock reveal 120, welcome 84, Settings 56).
- **The lock button is just a big lock** on glass. A vault icon there (tried 2026-10-21)
  confused testers and would hint that the phone holds other vaults; the vault shows once
  when it opens, and in Settings.
- **Back button and swipe back go together** (owner 2026-10-21): every page with a back
  button can also be swiped back (iOS edge swipe, Android back gesture). Never block the pop
  (`canPop: false`) to save or to return a result: that switches the swipe off. Save behind
  the pop instead (the note editor writes its last words after the swipe, `NoteScreen.lastSave`)
  and let the caller reload on a null result. `test/swipe_back_test.dart` checks. Steps inside
  one page (new vault steps, an open group) have no route for the system swipe: wrap them in
  `EdgeSwipeBack`, which runs the same Back from a left-edge swipe.
- **One way to select, in every list** (owner 2026-10-21): the photo grid, notes, files,
  recordings and any kind added later. A long press selects, the "Select" button in the
  header starts selecting, and while anything is selected every item shows a circle
  (empty ring, or filled with a tick), so a tap visibly selects. Lists build their rows
  on `SelectableRow` (`lib/widgets/selectable_row.dart`), never their own `InkWell`;
  `test/selection_test.dart` fails on a list row that handles a long press itself.
- **Selection bar**: frosted glass like the bottom bar (no bright slab in dark mode); Delete
  in the system's destructive red, like Delete for good in Recently deleted (exception to
  black and white, owner 2026-10-21). One component for both (`SelectionBar`,
  `lib/widgets/selection_bar.dart`): Done · Select all · the actions.
- **Only what the vault holds.** The bottom capsule offers the home tab and the sections
  that have items, in the fixed order Overview · Library · (+) · Files · Notes (owner
  2026-10-24). Voice has no tab: it opens from the overview and from +. An empty vault
  shows its icon, one line, and big add tiles.
- **The + sits in the middle of the bar by default** (Settings can float it left or
  right): a little smaller than the bar, filled with the ink, so it stands out. It always
  offers every way to add, three to a row (add photos, take a photo, record a video,
  note, voice memo, file); it never does one thing at once.
- **Bottom bar: the app's own by default**; on iOS 26 Debug can switch to the system's
  (`NativeVaultBar`, UIKit tab bar + glass lock). Change one, change the other.
- **Hold the home tab to lock** (owner 2026-10-22), no lock button by default.
- **Photo/video preview** (owner 2026-10-22): big (width less 16 a side, up to 62% of the
  height), the page dark and blurred behind, name + date under it, one glass bar of four
  icons; swipe down closes.
- **Settings rows: a name, no note** (owner 2026-10-21). Pick a name that says enough.
- **Tap opens, long press opens the item's menu, everywhere** (owner 2026-10-22, like the
  iPhone's Files app): home, lists, grid, search, groups, trash. `showItemMenu`
  (lib/widgets/item_menu.dart) at the finger: Open · Select · Rename · Group · Info · Send
  · Delete (groups: Open · Rename · Delete; trash: Restore · Info · Delete for good, the
  same entries, icons and order as the trash preview's bar). Many items:
  the Select button (empty select mode, Select All, Done) and the selection bar.
  `test/selection_test.dart` fails on a long press that does anything else.
- **A tap never changes tab by itself**: a recording opened from home or search plays in
  a card over the page you are on.
- **Bottom bar words are never cut** (owner 2026-10-21): the home tab stays put on the
  left; the other tabs get room in proportion to their words when they all fit, and
  otherwise scroll sideways (no loop) with a fade at the right edge, the chosen tab
  scrolled into view. `test/tabs_fit_test.dart` checks every language at 360 and 430 pt.
- **Home tab (Overview)** (owner 2026-10-21): first in the capsule, drawn as the vault's own
  badge. A search field, the storage line, the sections as tiles with counts (tap: that
  tab), the groups (tap: open it) and the last six items. The vault opens on it unless
  another section was used last; + there offers every way in the fixed order.
  `VaultOverview` (screens/overview.dart) is the same block search shows before typing.
- **Search** (2026-10-21): results grouped by section with filter chips and counts, matched
  words in bold, photos as a grid, a group found by name opens in the vault. Note text in
  results follows "Hide note text". No search history is kept.
- **Appearance**: Settings → Display → Automatic / Light / Dark (pref `appearance`).
- **The main action: + opens the add column** (owner's design, 2026-10-21, 0.1.11). Every
  way to add stacks above the button (note, photos from device, take photo, record video,
  voice, file); the current section's ways sit nearest the thumb and are filled, the rest
  follow in a fixed order. The page dims and + turns into ×. One hand: put the finger on
  +, slide up to a way (it grows and gets a backdrop, a light tick on each) and let go.
  Voice has the same + (Record nearest the thumb, 2026-10-21: one structure everywhere);
  while recording the button is the red stop. The section a way fills opens.
- **The add column moves and loops** (0.1.12): ways pop out of + one after another with
  a small overshoot, + turns into ×, closing plays it backwards. Dragging the column down
  rolls it in a loop, so any way comes to the thumb. + sits `Ui.actionLift` above the
  safe area (30 clear of the bottom bar) so a big thumb does not hit the lock.
- **Quick look, not full screen** (owner 2026-10-21, 0.1.12): a tapped photo or video
  opens as a card a little bigger than its thumbnail, over the vault, which stays visible
  under a light dim and blur; videos play in the card (tap to pause, a line shows where).
  Under it: Close bottom left (as in the camera), Full screen, then Send (videos) and
  Delete in red. Full screen is the old black viewer; its corner button returns to the card.
- **Short content in a card** (owner 2026-10-21: pages for a few lines felt empty):
  `showCard`, centred, the vault dimmed and blurred behind (security, change icon and
  colour in one card with a live badge, icon or colour pickers). Long scrolling lists stay
  pages; actions for the thumb stay bottom sheets (share out, remove originals).
- **Unlocking, new** (owner 2026-10-21, "safe door"): the dial stays solid and turns while
  the vault's colour glows around its edge; then it swings past the eye like a door, and
  the vault's icon comes forward from small and soft to sharp; the vault screen takes over
  with the same icon in place, holds it briefly and fades it (about 1.8 s in all). A dial
  thinning over the icon was tried and looked muddy.
- **Add column loop**: a thin line with room above and below where the loop starts; no ↻,
  no dimmed repeats.
- **Where content appears** (owner 2026-10-21, "too far from the eye"): reading, or choosing
  among many → a page (`pushPage`: security, all groups, groups for a selection, icons,
  colours); a few choices → a menu at the row (auto-lock); actions with a thumb button →
  a bottom sheet (share out, backup confirm, import progress). New UI follows this.
- **Every opened item can be sent** (owner 2026-10-21): one `shareItem` for all kinds.
- **Reading text** (0.1.14): book-like body (17.5, line height 1.6); Markdown drawn by the
  app (`MarkdownLite`, no library); JSON and code in a soft card, JSON keys strong; a
  note's first line large and bold as it is typed (`NoteTextController`).
- **Note formatting** (0.1.67, owner 2026-10-25): notes stay plain text; the preview draws
  their Markdown (headings, bold, italic, lists, checklist boxes to tick, underlined web
  addresses). While editing, a glass bar over the keyboard (Bold · Italic · Heading ·
  List · Checklist · Link, 48 px each) types the marks, and the editor shows them lightly.
  A tapped address asks first in a card (docs/security.md, links in notes).
- **Open group**: filled chip with ✓ and ×, "Group · section" above the title; empty in
  this section → buttons to the sections where it has something.
- **Settings**: About group (version, build date, commit, licence); hidden debug (seven
  taps on the version, owner check); add button position as an inline Left | Right.
- **Tapping an item does it, in place; no sheets popping up from the bottom.** Sheets are
  only for making or choosing something (groups, settings values). A voice memo opens in
  its row with Send · Rename · Delete; Recently deleted: see "Deleting" below.
- **Close where the thumb is.** The camera's close sits in the bottom row with the shutter
  and flip; swiping down closes too; the last shot is a small thumbnail in the
  viewfinder's corner.
- **Editors use the same header**: a round glass back on the left, Done as the one filled
  button on the right, both `Ui.circle` tall. A new note's hint says the first line is its
  title. Search uses the same back and a rounded field with a magnifier.
- **Select** is a glass pill at the top of any section with items (long press still works);
  inside a group the header drops Settings to make room.
- **Recently deleted** says how long items stay and how to select several.
- Persona review that led to these (2026-10-21) and what is left: `docs/decisions.md`.

## Deleting and Recently deleted (approved 2026-10-26, 0.1.71)

- **Every delete asks first**, everywhere, with one component (`confirmDelete` and its
  helpers `confirmTrash` / `confirmDeleteForGood`, `lib/widgets/confirm_delete.dart`): a card
  at the bottom, the page dimmed and blurred behind like the item menu; a red icon, the title
  with the count ("Move 3 items to Recently deleted?") or the item's name under it, one line
  on what happens, the red button that does it, Cancel under it. A tap outside cancels.
  Used by the item menu, the selection bar, the preview, the full-screen photo and video
  viewers, the file page, the note editor, Delete group, and Delete for good. Moving to
  Recently deleted still offers Undo after. Deleting a vault keeps its own PIN + countdown.
- **Recently deleted** is laid out like the vault: a line on top (items go for good after 30
  days; tap to look; hold and drag to select), then by kind with a count: photos and videos
  as a 3-column grid of thumbnails (videos with their play mark and length), notes,
  recordings and files as rows with their kind, name, size and days left. Items deleted on
  another device carry a devices mark. No "Restore all" / "Delete all" (owner: too easy to
  hit). The bottom bar has Select; while selecting, the vault's selection bar with Restore
  and Delete for good, acting on the selection only. An empty page says what it is for.
- **Hold, then drag to select a run** (`lib/widgets/drag_select.dart`), in the vault's grids
  and lists and in Recently deleted, as in the iPhone's Photos: once the finger moves after a
  long press, select mode starts and every item from the first to the one under the finger
  is selected (dragging back gives the others their old state; starting on a selected item
  deselects); the list scrolls by itself near its edges; a tick per change. Held still, the
  item gives a little under the finger and its menu opens when the finger lifts (or after
  0.65 s): a menu opened at once would end the touch, so no drag could follow.

## Quick tour (mockup 2026-10-26, waiting for the owner)

- Tips on the real vault page (coach marks, `lib/screens/tour.dart`), not picture cards
  (owner 2026-10-26). The page dims; the widget being explained stays lit in a rounded
  window with a thin light ring; a bubble with an arrow points at it: a short title, one
  line, the count (2/6) at the top right, Skip on the left and Next on the right of its
  bottom row (48 px targets). Done on the last tip, no Skip there.
- A tap on the dim does nothing (no accidental skip, no running ahead); Back skips.
- The bubble sits below the widget when it fits, else above (the side with more room when
  neither does), inside the safe area, at most 380 wide; its arrow stays under the
  widget's middle. The window slides from one widget to the next (no slide with reduced
  motion). Light: white bubble; dark: a deep bubble with a faint edge.
- After a vault is created: Add (the +; in an empty vault the add tiles) · Open and pick
  (the first item showing: tap, hold for the menu, hold and drag to pick many; an empty
  vault: the tiles, "what you add shows up here") · Sections (the tabs; left out while the
  vault is empty and the bar has none) · Settings (sync, backup, security) · Locks by
  itself (the lock button; else the home tab, "hold here to lock now"; else Settings) ·
  Keep a second copy (points at Settings, with the 24 words and password as the only way
  back on a new phone, "Set up sync now" opens Settings then Sync, and Later).
- After a restore: Add · Open and pick · Sections · Settings.
- **User guide** (owner 2026-10-26): Settings → Help & guide → User guide, the second
  group from the top (under Sync), closes Settings and runs every tip on the vault page,
  then opens Settings again and goes on there, counting on (6/9): Sync (its row) ·
  Security (the group; a tall group is scrolled so its top third shows under the bubble,
  the window cut to the list) · Back up to a file (its row) · User guide (the row: "see these tips
  again any time"), then Done. "Keep a second copy" has no button in the guide, Sync comes
  next. Skip anywhere ends the guide; opening Settings alone shows no tips (no surprise
  while someone goes there to change something). Tips on a far row bring it into view
  first (`TourTip.prepare`).
- No "?" in the vault header: it already holds Select, Sort, Search and Settings in a
  section, and a fifth round button cuts the title on small phones; the tour points at
  Settings, and the guide is the second group there.
- With "Lock as soon as I leave the app" off, the lock tip points at Settings: "locks
  after a few minutes without use, also while you are away".
- Whatever was open on the page (selection, a group, the add column) closes first.

## One look per kind of thing (owner 2026-10-28)

The app stays black and white (approved 2026-10-20); a vault's own colour stays its own.
This round makes each kind of control look the same everywhere.

- **Action bar** (`ActionBar`, `lib/widgets/bottom_bar.dart`): an open item, the photo
  and video full screen, a note being edited, selecting many. **Every button its own
  glass circle** (`Ui.action`, 62, as Photos' search; shrinking together on a narrow phone), apart, as the iPhone's own apps (owner 2026-10-29):
  the way out on the left (× to close, ✓ to save and leave or end Select, ⤡ to leave full
  screen), Delete alone on the right in red, the rest between them (Open · Send · ⋯).
  Icons only; the word is the tooltip. Over a photo or video the glass is dark
  (`onMedia`). Buttons share one glass only when they are one set to pick from (the
  section tabs).
- **iPhone measures** (owner 2026-10-29, from the Photos app): header buttons 44, big
  title 34 with the item count under it, side margin 20 (`Ui.side`), corners 24, the
  section bar 62.
- **Section header**: the big title on the left, then at most Search, ⋯ and Settings.
  Select and Sort live in the ⋯ (inside a group, also Rename and Delete the group).
