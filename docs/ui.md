# UI

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

- Background: a collage of protected items (photos, ID card, receipt, PDF,
  notes) tilted about −8°, **always blurred** so nothing is readable, under a
  vault-green veil: deep green at the top fading to pale mint (light) or to
  night green (dark).
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
  as soon as the screen shows; then the **PIN pad** if this device has a PIN
  (a dot per digit typed, no empty placeholders, digits only, checks itself at
  every PIN length in use, shakes on a wrong PIN, waits grow from the 5th wrong
  one); then the **password** (type to unlock, no Enter needed), offered only when
  some vault has one. "Use password" / "Use PIN" switch between them; "Create a
  new vault" sits under them.
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
  menu: icon and colour · backup password · change PIN · Face ID · back up ·
  Emergency Kit · new vault. Settings and Delete vault join it (review below).
- Without a backup password, a banner under the header says what is at stake
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
Emergency Kit, and a three-column desktop layout, each in light and dark.

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
  3. Set a PIN (4–10 digits). 4. Type it again (checks itself).
  5. "Unlock with Face ID?" Turn on / Not now. Then the dial turns, into the vault.
- **No vault names.** Icon + colour (35 × 20 = 700 combinations) identify a vault;
  inside the vault only the coloured icon is shown, no text. A new vault (the first one too) starts with a random
  icon and colour from the 11 shown on each grid (grid order stays fixed, only the
  preselection changes), avoiding the open vault's own when created from inside it.
  Combinations are not checked against other vaults: the app cannot see them
  while locked, and a readable list would show how many vaults exist.
- **No password at the start.** Each vault opens with its own PIN on this device
  (a PIN picks its vault, like the password does) and the default vault also
  with Face ID. The **backup password** and the **Emergency Kit** are set later, on
  one screen ("Suggest a password", type it again, then the kit with a QR code):
  required before the first backup, gently suggested from inside the vault.
- Wrong PINs: waits that grow (1, 5, 15, 60 min), never a lockout, since a vault
  may have no password yet.
- Splash: vault green with the dial where the lock screen has it.
- Locking: by hand (animation), on leaving the app (immediately, 60 s grace when
  the app itself opened the camera, a picker or the share sheet), after 2 minutes
  without a touch. Face ID is not asked again right after locking by hand.
- With a backup password, the lock screen asks for it once every 14 days instead
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
   dots ("Without a backup password, a forgotten PIN can't be recovered."), and the
   banner in the vault says the stake, not the mechanism: "Only on this phone. Lose
   it or forget the PIN and this vault is gone." with "Set backup password".
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
   leaving the app always locks at once, so "immediately" would add nothing), Face ID for this vault, change PIN, backup password, Emergency Kit, last
   backup date, storage used, block screenshots (Android), language, theme. *mockup*
7. **Which vault does Face ID open?** The menu says "Face ID opens this vault";
   turning it on here moves it from the other vault (one per device).
8. **Backups leave some vaults out silently.** The backup step says, always in the
   same words, that vaults without a backup password are not included.
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
  white symbol on its own colour: Unlock (Face ID for this vault, PIN, auto-lock as a
  pick list), Backup (Back up now, backup password, Emergency Kit), Security (how the
  vault is protected, block screenshots on Android), and Delete this vault alone at the
  end.
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
  date). The first words show only with Settings → Display → Show note text (0.1.10;
  `docs/security.md`). Sections and groups change with a short fade.
- **Settings may use colour, softly** (owner 2026-10-21): the storage bar in one colour per
  kind (photos blue, videos purple, notes yellow, voice orange, files green), the storage
  card on the groups' surface, Back up now a soft blue tint, switches iOS green when on.
  No black slab in light mode, no white slab in dark mode; dark-mode filled buttons
  elsewhere are a soft grey.
- **Destructive actions are red** (owner 2026-10-21): Delete in the selection bar and
  "Delete all" in Recently deleted use the system red, apart from the safe choice.
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
- **Selection bar**: frosted glass like the bottom bar (no bright slab in dark mode); Delete
  in the system's destructive red, like "Delete all" in Recently deleted (exception to
  black and white, owner 2026-10-21).
- **Only what the vault holds.** The bottom capsule offers just the sections that have
  items, in the fixed order Notes · Library · Voice · Files; with one, no capsule. An empty
  vault shows its icon, one line, and big add tiles.
- **The main action: + opens the add column** (owner's design, 2026-10-21, 0.1.11). Every
  way to add stacks above the button (note, photos from device, take photo, record video,
  voice, file); the current section's ways sit nearest the thumb and are filled, the rest
  follow in a fixed order. The page dims and + turns into ×. One hand: put the finger on
  +, slide up to a way (it grows and gets a backdrop, a light tick on each) and let go.
  Voice keeps its red mic, which records at once. The section a way fills opens.
- **The add column moves and loops** (0.1.12): ways pop out of + one after another with
  a small overshoot, + turns into ×, closing plays it backwards. Dragging the column down
  rolls it in a loop, so any way comes to the thumb. + sits `Ui.actionLift` above the
  safe area (30 clear of the bottom bar) so a big thumb does not hit the lock.
- **Quick look, not full screen** (owner 2026-10-21, 0.1.12): a tapped photo or video
  opens as a card a little bigger than its thumbnail, over the vault, which stays visible
  under a light dim and blur; videos play in the card (tap to pause, a line shows where).
  Under it: Close bottom left (as in the camera), Full screen, then Send (videos) and
  Delete in red. Full screen is the old black viewer; its corner button returns to the card.
- **Every opened item can be sent** (owner 2026-10-21): one `shareItem` for all kinds.
- **Reading text** (0.1.14): book-like body (17.5, line height 1.6); Markdown drawn by the
  app (`MarkdownLite`, no library); JSON and code in a soft card, JSON keys strong; a
  note's first line large and bold as it is typed (`NoteTextController`).
- **Open group**: filled chip with ✓ and ×, "Group · section" above the title; empty in
  this section → buttons to the sections where it has something.
- **Settings**: About group (version, build date, commit, licence); hidden debug (seven
  taps on the version, owner check); add button position as an inline Left | Right.
- **Tapping an item does it, in place; no sheets popping up from the bottom.** Sheets are
  only for making or choosing something (groups, settings values). A voice memo opens in
  its row with Send · Rename · Delete; Recently deleted selects on tap, with Restore and
  Delete for good (red) in a glass bar, acting on everything when nothing is selected.
- **Close where the thumb is.** The camera's close sits in the bottom row with the shutter
  and flip; swiping down closes too; the last shot is a small thumbnail in the
  viewfinder's corner.
- **Editors use the same header**: a round glass back on the left, Done as the one filled
  button on the right, both `Ui.circle` tall. A new note's hint says the first line is its
  title. Search uses the same back and a rounded field with a magnifier.
- **Select** is a glass pill at the top of any section with items (long press still works);
  inside a group the header drops Settings to make room.
- **Recently deleted** says that tapping an item restores or deletes it.
- Persona review that led to these (2026-10-21) and what is left: `docs/decisions.md`.
