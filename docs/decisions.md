# Decisions

What was decided, when, and what is still open. Newest first. Update this page in the
same change as the decision (or right after the conversation that made it), so nothing
depends on memory. Details live in the linked docs; this page is the index.

## 2026-10-23 — New vault flow, one set of 24 words per device

**Owner:** creating a vault becomes: what each key is for → 24 words (back them up, then
four of them asked back) → vault password (at least 8 characters, strength shown, never
blocked) → PIN (digits only, at least 6) → Face ID → icon and colour (optional, last).
Existing vaults keep their 4–5 digit PINs. The 24 words stay **one set per device**,
shared by every vault, like 1Password's Secret Key: each vault still needs its own
password, and the password page says a weak password is only safe while the words are
kept safe. The words can be changed (every vault's password asked; old backups still
need the old words). A list of vaults, and deleting one after Face ID / the phone's
passcode when its password and PIN are forgotten (data gone for good).
Import: each file is encrypted as soon as the phone has copied it (0.1.35).

## 2026-10-21

**After 0.1.14 (owner):** remove originals after import, photos and files, both phones,
always asked first (then the system asks); the Secret Key keeps its English name in
Vietnamese too, like 1Password ("Mã bí mật" was the same thing and is gone); group chips count the whole group; blurred thumbnails option now; iOS covers
the screen while recording and warns after a screenshot (it cannot block them); short
content opens in a centred card; the unlock shows the vault's icon behind the dial,
sharpening as it opens. Remove-originals needs testing on real phones (native code).

**0.1.14: about and hidden debug, share everywhere, safer big files, clearer groups.**
Owner asked for build info and a hidden debug mode like Flip Match, Send on every item,
nicer reading, a reviewed list of text types, and no memory blow-up on heavy files.
Proposed next (owner agreed in principle): reading opens a page, few choices a menu at the
row, actions a bottom sheet.

**0.1.13: softer settings, colours per kind, text files in the app.** Owner: the white card
and buttons glared in dark mode and black ones were too strong in light mode; Settings may
use colour. Text-like files open in the app (Markdown as plain text for now; rendering it
would need a library to review).

**0.1.12: quick look and a looping add column.** Owner: a tapped photo or video should not
take the whole screen, only a little bigger than its thumbnail with the vault visible
behind, full screen on request; Close where the camera's is. The add column gets motion
(pop out, + to ×), scrolls in a loop for one hand, and + sits higher above the lock.
Settings lose the brown tiles. A framed full-page viewer was tried and dropped.

**0.1.11: the add column, and no bottom sheets on tap.** Owner found + inconsistent
(Library offered every kind, other sections one) and proposed the column: + opens every
way to add stacked above it, the current section's ways nearest; then asked for press and
slide with one hand. Tapping a voice memo opens it in place; Recently deleted selects
like the Library. Approved from the mockup.

**Pipeline: green means delivered.** 0.1.10 went green but never reached TestFlight: the
upload job read "started by hand" as "validate only", and a release is started by hand.
Now a release passes `upload: true`, only an explicit `upload=false` validates, the job
fails unless Apple's tool reports the upload, and both the TestFlight and Google Play
steps write where the build went into the run summary. 0.1.10 was uploaded again as
build 1019.

**After user testing (persona agents, skill `nguoi-dung-thu`), in the same mockup:** owner
chose round vault icons; the lock button is just a big lock (a vault icon there confused
testers and hinted at other vaults); main action mixed (Notes: new note, Files: picker,
Voice: record, Library or no Library yet: add sheet). Fixes: note text hidden from lists and
search by default (Settings → Display, owner check to turn on), rounded search field, Select
button, Recently deleted hint + red "Delete all", glass selection bar with red Delete (red
for destructive actions is a new exception to black and white), fixed-length Secret Key
mask, clipboard note in the Emergency Kit, no Settings inside a group, first-line hint in
new notes, stronger grey text. Preview now renders as an iPhone (Face ID, mono font).
Not done: blurred thumbnails mode, "Secret Key" wording in Vietnamese, chip counts.

**Proposed, mockup awaiting approval: one design language.** Owner reported: the camera's
close was out of reach at the top, the vault icon after unlocking looked plain, the note
editor's buttons were small (bigger buttons everywhere), and every section showed even when
empty. Proposal (docs/ui.md, design language): shared sizes (`Ui` in theme.dart), vault icon
as an app-icon squircle everywhere (round variant drawn for comparison), only sections with
items, an empty vault with big add tiles, one + opening an add sheet, camera close in the
bottom row plus swipe down, editors with a glass back and a filled Done. Branch `ux-round2`,
not pushed.

## 2026-10-20

**0.1.9: exceptions to black and white, and unlocking in order.** Owner: recording and video
controls stay red, Settings icons keep colours, the biometrics row shows the real Face ID
symbol (wording follows Face ID or fingerprint). Unlocking: dial, then the vault's icon alone
on a plain screen, it fades, then the content. Launch screen black and white. Main action on
the left or right (Settings → Display). Removing originals from the phone's photo library
after adding them: wanted, always with the user's confirmation. Open: iOS can do it with
the system's own confirmation (a picker that returns photo-library ids); Android's photo
picker cannot delete what it returns, so it would need the broad "read all photos and
videos" permission and a Google Play declaration. Recommended: iPhone only, and on Android
a hint to delete the originals in the Photos app.

**Commit messages may name the assistant.** Two commits were pushed with an assistant
trailer; the owner chose not to rewrite history ("cứ để Claude cũng được"). Personal names
and emails stay out of the repository.

**Releases: each platform ships as soon as it is built, and store keys stay out of build
jobs.** Owner: Android and iOS wait for nobody; after weighing the risk (a hijacked build
package could read a key in the same job), uploads go in separate jobs. Play: a `play` job
that needs only `android`. Build jobs only read the repository; attesting and publishing
happen in the release job. Done 2026-10-21 for every platform (`docs/supply-chain.md`,
"Signing and store keys"): Android signed in its own job, macOS signed and notarized in two
jobs of their own, TestFlight upload apart from the iOS build; all tried end to end (Apple
validation, notarization, release-key fingerprint) before merging.

**Security settings ask for the owner; secrets are hidden until asked for.** Owner,
after finding loose settings: every security setting needs Face ID, fingerprint or the
passcode; passwords and the Secret Key never appear on screen by default (a person or a
camera could see them), only with a Show button. Rules and the list of settings:
`docs/security.md`. Also fixed: copying the Secret Key now wipes the clipboard after 60 s.

**Black and white look (approved for building).** Everything in ink and page colour,
except the vault's own icon, which keeps its colour (shown big after unlocking, in
Settings, when creating a vault). The delete screen uses the opposite brightness instead
of red.

**Deleting forgotten vaults: deferred** by the owner. The work (Settings → Vaults on this
device, delete with the open vault's PIN) is kept on a local branch; open question when it
returns: who may see the list (decoy vaults).

**0.1.7 released** (TestFlight, Play internal + Alpha, GitHub). After it: cackle's
config is complete and its CI job now blocks (no crate may use the network; ~20 crates
lost permissions they did not need); the core crates forbid unsafe Rust. A repo file
meant for the maintainer's tools was public and is removed from the tree; the owner
chose to leave the published history as it is (no force-push).

**Camera keeps the app frame; readable media names.** Owner feedback on 0.1.6: the
full-screen black camera looked out of place, and photo/video names were odd
("Photo.jpg", "VID_1792…", picker names). Camera: app header, rounded viewfinder, glass
Photo | Video switch (`docs/ui.md`, Camera). Names: kind + moment
(`docs/ui.md`, Names). Released in 0.1.7.

**Groups row: the all-groups button sits first.** At the end of the row it was off
screen and nobody would find it (seen in the rendered mockup). New group stays last.

**Go to push and release** everything agreed (groups, naming, supply-chain controls,
mockup tool, camera, names) — owner, 2026-10-20. Not included: black/white look and
"Vaults on this device" (proposals), pinning the PDFium checksum (not decided).

**Vaults have no name.** A vault is told apart by its icon and colour only. No screen
shows or asks for a name. `VaultMeta.name` is a leftover from the first previews: it is
never filled or shown (keep reading it; remove it with the next vault-header format).

**Groups (tags) replace folders.** Approved. One set of groups for the whole vault; an
item can be in several; a group shows its items in every section (Notes, Library, Voice,
Files). The chip row under the title stays; "New group" stays in the chip row, not in the
+ button. Opening a group keeps it while switching sections. Adding something while a group
is open puts it in that group. Old folders become groups of the same name (nested ones
flatten). Code: item records format 2 (`docs/naming.md`, History). Status: released in 0.1.7.

**Naming rules.** `docs/naming.md`: one concept, one name; units in names; ids `_id`;
no abbreviations outside a short list; stored renames read the old name forever (format
bump + alias + test). Applied together with groups.

**Mockups come from the app.** `docs/ui.md`, Mockups: change the code locally, run
`app/tool/mockup.sh`, publish the framed dark/light page. No hand-drawn screens: a
hand-drawn mockup showed a lock screen, an unlock dial and a vault name the app does not
have.

**Black and white look (first proposal, superseded below).** Main UI in black and white with
opacity only, light and dark (system setting). Unlock keeps the current effect
(`playVaultSpin`: dial grows, turns 192° back to 180°, zooms out) in black/white; then the
vault's icon shows in the middle and fades, so you know which vault opened. Next step:
build it locally and render with `mockup.sh`.

**Forgotten vaults (first proposal, deferred above).** Settings → Vaults on this device: every
vault container with created date and size (the count is already visible from storage);
the open one shows its icon; others can be deleted without their PIN after confirming with
the open vault (biometrics/PIN) and typing a word. Whether a "last opened" date can be
known without decrypting: not checked yet.

**Supply chain: no library can send data out.** Approved. Android build drops the
INTERNET permission and CI checks the APK; macOS sandbox without network entitlements;
the compiled Rust library must import no socket functions; cackle and cargo-deny; Dart
blocks HttpClient/Socket at start; allowlists of every Dart/Rust package plus a scan of
their sources (`docs/supply-chain.md`). Open: `pdfium_dart` downloads `libpdfium` at build
time with no checksum. Status: released in 0.1.7.

**Do not push without the owner's go.** Work stays local (branches, commits) until the
owner says to push or release.

**0.1.6 released:** glass layout (large title, lock + four sections at the bottom, main
action above the lock), per-section folders (superseded by groups above), camera with
video from the Library.

## 2026-10-21 — "Nothing goes to the internet" on the security page

The security info page (`SecurityInfoScreen`, strings `sec4Title`/`sec4Body`) states
that this version never connects to the network: no account, ads, analytics or crash
reports; on Android and macOS the OS grants no network permission (no INTERNET
permission, sandbox without network entitlements, both checked in CI); on iOS,
Windows and Linux the app blocks connections itself (`lib/offline.dart`) and CI scans
dependencies. **When sync ships (v0.2), rewrite this section in every language**: LAN
sync needs the Android INTERNET permission back, and server/P2P sync (v0.3) uses the
network. Sync must be a switch the person turns on, and the page must then say that
only encrypted data leaves the device.

## 2026-10-21 — 15 languages, one setting shared with the system

The app now has the website's 15 languages. Settings → Language offers "Same as device"
and each language in its own name. On iPhone and Android 13+ the choice is the system's
per-app language (iOS `AppleLanguages` for the app, Android `LocaleManager`), so changing
it in either place changes both; on computers and older Android it is a pref. iOS applies
the system value from the next start, so the app switches the running session itself.
Translations were made from the English strings, reusing the website's terms; they have
not been reviewed by native speakers yet.

## 2026-10-21 — Thumbnails blurred by default

"Blur thumbnails" (Settings → Display) is on unless the person turns it off; turning it
off asks for the owner check, as before. A pref already set to off stays off.

## 2026-10-21 — Overview tab, search, appearance

An Overview tab comes first (the vault's badge in the bottom bar), even though the lock
button dropped the vault icon earlier: the owner chose it knowing that trade-off. Search
was rebuilt around the same overview. Appearance (automatic / light / dark) is a pref.
The lock-screen collage stays (owner wants it, even more detailed) but is drawn in the
theme's greys.

## 2026-10-21 — Block screenshots on iPhone too

Owner's choice after looking at Tinder's documented iOS capture blocking and the Flutter
plugins that do the same (screen_security, screen_guard): the window's layer goes inside
a secure text field's layer. Written in AppDelegate (no new dependency), behind the
existing "Block screenshots" switch, on by default, off with the owner check. Undocumented
by Apple: if a future iOS breaks it, or App Review objects, remove `applySecure` and keep
the capture cover and the screenshot warning. Tested on a real iPhone via TestFlight
before relying on it.

## 2026-10-21 — Names, two kinds of key, 256-bit Recovery Key

- Emergency Kit → **Recovery Key** ("Khoá khôi phục"); backup password → **vault
  password** ("Mật khẩu két": it opens the vault without PIN/Face ID and opens backups).
  "Secret Key" leaves the user-facing text (technical details only).
- Explain the vault as two kinds of key: everyday (PIN / Face ID, this phone) and
  recovery (Recovery Key + vault password + the backup file).
- Settings: Backup holds only the backup; the Recovery Key and the vault password sit
  under Security. The backup sheet reminds what opens it.
- Recovery Key moves to 256 bits shown as 24 words (own round, with migration).
- Option to keep the Recovery Key in iCloud Keychain / Google Password Manager (opt-in),
  so a new phone needs only the vault password. Passkey PRF considered for later.
- docs/security.md compares the strength with a Bitcoin wallet and covers quantum.


## 2026-10-21 — iPhone's own bottom bar, Settings without notes

- On iOS 26 the vault's bottom bar (lock + sections) is a UIKit tab bar and a glass
  button in a platform view (`TabBarView` in AppDelegate, `lib/widgets/native_bar.dart`),
  so it is Apple's own Liquid Glass. Written in the app, no package
  (`liquid_glass_renderer` rejected: experimental, needs a preview GPU flag, eight
  dependencies). Older iOS and Android keep the app's bar. A Debug switch turns it off
  to compare. Not visible in the mockups (UIKit draws it): checked on TestFlight.
- "Hold + to lock" (Settings, off by default): no lock button, the sections take the row.
- Settings rows carry a name only, no note under it; Security holds everything about
  opening the vault; "Block screenshots" sits with the blur switches in Display.
- A recording tapped outside Voice plays in a card where you are; no tab change.

## 2026-10-22 — Hold home to lock; system bar only in Debug

- Holding the home tab locks; no lock button by default (Settings brings it back). Where
  the bar has no home tab (one kind of item, an empty vault) the lock button stays.
  Replaces "hold + to lock".
- The iOS 26 system bar is off by default (Debug turns it on): on a real iPhone the
  standalone UITabBar laid icon and word side by side and overlapped. Fixed by forcing
  compact size classes and letting the bar report its height; to be checked again.

## 2026-10-22 — Long press opens a menu (iPhone Files), Select for many

- Audit against iPhone Files, Files by Google and Photos. Round 1: long press menu on
  every item and group (home, search and trash too), Select mode with Select All, item
  Info, ⋯ in the photo/video preview, Delete inside a note. Later rounds: sort and list/grid
  view, favourites, receive files from other apps (share extension), preview imported
  images/audio, move to another vault, note edit time, trash preview.

