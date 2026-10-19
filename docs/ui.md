# UI

One design, light and dark only (see `requirements.md`, Theming). Brand colours:
vault green `#165B4C` (deep `#0F3D33`, night `#0B2B24`), gold index `#F3D08E` /
`#D9A53F`, neutrals from the app theme (`app/lib/theme.dart`).

The brand mark is the combination dial reduced to three shapes: one thick ring,
a solid knob, the gold index (`branding/icon.svg`). Use it at every size; no tick
marks or extra detail.

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
6. **No Settings.** One screen from the vault menu: auto-lock (immediately, 1, 2, 5
   min), Face ID for this vault, change PIN, backup password, Emergency Kit, last
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
