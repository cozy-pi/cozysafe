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
- Centre: a frosted card with the brand mark on its top edge, the title
  "Unlock", the password field, the Unlock button, then "Create a new vault".
  No subtitle and no item counts.
- Biometric unlock is **its own button** under Unlock (outlined), never an icon
  inside the password field: "Unlock with Face ID" or "Unlock with fingerprint"
  depending on the device; hidden when the device has no biometrics or the user
  has not enabled it.
- Light: white card, green Unlock button. Dark: green-black card, gold Unlock
  button, gold accents.

## Inside a vault

### Add strip (approved 2026-10-19)

Mockup: (internal mockup)

- The bottom of the vault screen is a dark green dock, like the iPhone Camera
  mode dial: a horizontal strip of modes (Note · Library · Take photo · Scan ·
  File · Paste) that the thumb drags or taps; the selected mode is gold.
- One big round action button under the strip, always in the same place; its
  icon follows the mode. In Take photo it becomes a white shutter.
- The last-used mode is remembered per device and selected on the next open.
- Left of the button: a preview of the last item added. Right: one short line
  saying what the mode does.
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
