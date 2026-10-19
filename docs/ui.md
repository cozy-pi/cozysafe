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
  (dots = PIN length, digits only, no letters, checks itself on the last digit,
  shakes on a wrong PIN, 5 wrong turns the PIN off); then the **password** (type
  to unlock, no Enter needed). "Use password" / "Use PIN" switch between them;
  "Create a new vault" sits under the password.
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

- Title (vault name) and a menu (PIN, biometrics, back up, Emergency Kit).
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
