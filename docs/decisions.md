# Decisions

What was decided, when, and what is still open. Newest first. Update this page in the
same change as the decision (or right after the conversation that made it), so nothing
depends on memory. Details live in the linked docs; this page is the index.

## 2026-10-29 — One design language, after the iPhone's Photos

**Owner:** the phone screens were not consistent (bottom bars in five shapes, small
buttons, headers in several styles); agree on one language before building more. Stay
black and white (approved 2026-10-20; a vault keeps its own colour). Learn from the
iPhone's own Photos app: every action its own round button (Close left, Delete red
right), icons only, iPhone sizes (header 44, action 62, title 34, margin 20). Select
and Sort in the header's ⋯. Menus use line icons. Names on one line with … .
Saving the 24 words makes a real .txt file after a reminder; no password on the file (a
third secret to forget). The rules, numbers and shared pieces are in
[design-language.md](design-language.md), which every new screen follows.

## 2026-10-28 — No PIN: Face ID, else the vault password

**Owner:** the PIN goes. Review of the PIN (6 digits, about 20 bits): the device key it
needs is wrapped by the Secure Enclave / Android Keystore, but that key has no
user-presence check, so code running on an unlocked, rooted or jailbroken phone can ask
the chip once for the device key and then try every PIN off the phone; the wait after
wrong tries and the wipe after 10 are kept by the app, not the chip. On computers there
was no chip at all. A PIN expiry was rejected: the app cannot enforce it while it is not
running. Using the phone's passcode instead was rejected: people the vault hides things
from often know it. So:

- **Everyday:** Face ID / Touch ID / fingerprint (`biometryCurrentSet`, held by the
  chip); **fallback:** the vault password, on the lock screen itself. On a computer the
  password field has the caret from the start and again after Touch ID is cancelled.
- **New vault:** intro (Face ID, password, 24 words) → 24 words → password (the vault is
  made here, `create_vault_with_password`) → **Turn on Face ID** (its own step, whenever
  the device has biometrics) → look.
- **After a restore** (file, Drive, nearby): Face ID is offered instead of a PIN.
- **Delete vault:** confirmed with the vault password (owner check first, as before).
- **Existing PINs:** removed at the lock screen for every vault that has a password
  (`forget_pins_with_password`), then the device key once none is left. A vault made
  with only a PIN and never given a password keeps its PIN pad until it gets one (or it
  would be locked out). The core keeps its PIN code for that case.
- Settings: "PIN" row gone. Docs: security.md, ADR 0001.

## 2026-10-28 — Checking Google Drive for junk

**Owner:** worried about junk in Drive (98 items, about 920 files and folders). The core
and bridge gain `drive_audit` (counts and bytes per kind: current, old revisions, journal,
heads, lock, orphans, unknown, deleting; one log line without ids) and `drive_clean`
(removes only orphans, worked out again from a fresh listing). One listing, nothing
downloaded. Conservative: anything that might be another device's item not taken here
yet, or a revision made after a deletion, is "unknown" and stays; content without a record
counts as junk only once a day old. Not in the connection log (it would read as a sync).
UI elsewhere. Details: ADR 0003, "Checking for junk".

## 2026-10-28 — Google Drive on computers (macOS, Windows, Linux)

**Owner:** Drive sync, and restoring or joining from Drive, on computers too. Google's
sign-in SDK does not run there (and on macOS needs an entitlement the Developer ID app
lacks), so computers use Google's installed-app flow: browser, loopback redirect on
127.0.0.1, PKCE, the refresh token in the system's secure store (ADR 0003, "Sign-in on
computers"; docs/security.md). The network parts are in cs-net (`oauth.rs`), which now
looks up a second fixed host, `oauth2.googleapis.com`. Needs a "Desktop app" OAuth client
in the `cozy-safe` project and two repository secrets; until they exist, computers hide
Google Drive as before. Open: a "finish signing in in your browser" screen with Cancel
(today the tap waits silently, up to 5 minutes) needs a mockup first.

## 2026-10-28 — Touch ID unlocks the vault on a Mac

Biometric unlock on Macs with Touch ID, as on phones (button "Unlock with Touch ID",
setting "Touch ID opens this vault"). No provisioning profile: the key that opens the
vault is wrapped by a Secure Enclave key that only Touch ID can use (CryptoKit,
`biometryCurrentSet`), and the wrapped blob lives in the legacy keychain the Mac build
already uses. A finger added or removed turns it off; the PIN or password still opens
the vault. Phones are unchanged. Details: docs/security.md, "Touch ID on a Mac".

## 2026-10-27 — A small head per device, so a quiet Drive costs one request

**Owner (approved design):** every automatic look at Google Drive used to list the whole
tree. Each device now keeps one sealed head file on the sync place, `<vault>/head/<device>`
(its last journal entry and how far it read the others'), written after its journal
entries and rewritten in place on Drive (same file id). `drive_changed` lists only the
`head` folder with Drive's per-file `version` and says whether another device wrote since
the last full sync that worked; any doubt or error says "changed". Devices on 0.1.80 and
older write no head and are seen only by the full syncs on open, unlock and every so often
(Dart side). The cursors in the head are kept for a later clean-up of old journal entries.
Details: ADR 0003, "Heads".

## 2026-10-27 — Automatic sync with Google Drive (changes "Network only by hand")

**Owner:** Google Drive may sync without a tap. A switch, "Sync automatically", set on
when the Google account is added (the card that allows the connection carries it, so it
can be turned off right there) and in Settings → Sync; accounts added before this stay
by hand until turned on. A second switch, "Only on Wi-Fi", keeps it off mobile data.
It runs only while a vault is open and unlocked: when it opens or unlocks, about 30 s
after something changes in it (many changes, one sync), and every 5 minutes for the
other devices' changes; never with the app closed, never alongside a sync started by
hand. It signs in to Google quietly and never shows a sign-in screen; when Google needs
the person, it waits for a tap. Nearby-device sync stays by hand (both devices must be
open). Still one host, the same `cs-net` permit per run, everything encrypted; turning
the switch on is the allowing. Code: `app/lib/sync/auto_sync.dart`.

## 2026-10-27 — Owner feedback round (0.1.77, mockup v14 approved)

**Owner:** + opens a card that explains every way to add (the quick buttons stay); a
note has Done while typing and no back on top; the guide's Skip is a real button; Google
Drive's own logo; waiting for a nearby device shows no moving light and its tips wait a
minute; Recently deleted in two parts (yours / deleted for good on another device, kept
only here) and Restore asks first; Settings reordered (most important first, like with
like, groups still unnamed); the website black like the app, phones and tablets only.

## 2026-10-27 — The 24 words in the Google account on Android (0.1.77)

**Owner:** the Android twin of the iCloud Keychain option ("do it first, fix later").
Google Block Store with cloud backup, kept only when it is end-to-end encrypted (needs a
screen lock); off by default, same owner check and same trade as on iPhone. The library
was already in the build (Credential Manager pulls it), so no new download to verify.
Released 0.1.76 (#31–#37) the same day after the owner approved mockup v13.

## 2026-10-27 — Version history, on each device (0.1.76, mockup)

**Owner:** keep older versions of every item "like git", so any change can be undone,
30 days. Settings for how long (Off · 7 · 30 · 90 days, default 30) and how much
(500 MB · 1 GB · 5 GB · no limit, default 1 GB). Asked whether the setting syncs: no,
each device has its own (choice a, simpler and less risk). History is local, sealed like
the items, not synced and not in backups; pruning never touches the current version
(`core/cs-vault/src/history.rs`, docs/security.md). The note editor's Undo/Redo is the
in-session half of the same request.

## 2026-10-27 — Drive errors named, an error log, Drive checked each sync (0.1.76)

**Owner 2026-10-26:** Drive sync failed "and we don't know why": errors need logs. A 403
is split by Google's reason (rate limit, full, sign-in); rate limits and server faults
are tried again (4 tries, from 0.6 s, doubling). Every failure is kept as a fixed code in
an always-on log (Settings → Report a problem, Copy details). Each Drive sync checks the
files it relies on against the SHA-256 Google lists and sends lost or damaged ones again,
saying how many (ADR 0003, "Checking what the place holds").

## 2026-10-27 — Nearby sync goes by itself; Settings like the iPhone's (0.1.76, mockup)

**Owner:** after the two names and the same number, a nearby sync (and a restore) counts
5 seconds and starts; Cancel stops it. A restoring phone that holds the 24 words and the
password has the same rights as the old one, so a tap there added nothing (ADR 0003,
points 8 and 9). No network address is shown anywhere. Settings and Sync have groups
without names, set apart by a gap; the vault's keys apart from what shields the screen.
Google Drive gains Sign in again and Remove account (revokes at Google, files stay).

## 2026-10-26 — User guide, one Security group, lock on leaving optional (0.1.72, mockup)

Owner requests, rendered for approval before release. A "Help & guide" group sits under
Sync near the top of Settings (User guide, Feedback); the User guide runs the vault-page
tips, then goes on in Settings (Sync, Security, Back up, the guide row), counting on. No
"?" in the vault header (crowded in sections; the tour points at Settings). Opening
Settings alone shows no tips. Every protection is in one Security group; Display keeps
appearance, language and the add button side. New "Lock as soon as I leave the app" (on
by default; off asks for the owner): off, the vault locks after the auto-lock time
counted from leaving, on the longer of a monotonic and the wall clock (docs/security.md,
Leaving the app). Android 13+ hides the app from Recents always.

## 2026-10-26 — Every delete asks; Recently deleted redone; hold and drag to select (0.1.71, mockup)

Owner requests, built and rendered for approval before release. Every delete asks first
in one bottom card (count in the title, red button, Cancel); Undo after moving to Recently
deleted stays. Recently deleted drops "Restore all" and "Delete all", groups items by kind
like the vault (videos now in the grid with their thumbnail), and its long-press menu and
preview bar are the same: Restore · Info · Delete for good (trash items are read-only: no
Send). Hold, then drag selects a run of items in the vault and in Recently deleted; the
item menu then opens on lift (or after 0.65 s held still), since a menu opened at once ends
the touch. Details: docs/ui.md, "Deleting and Recently deleted".

## 2026-10-25 — Security round (0.1.68)

New passwords follow NIST SP 800-63B rev 4: 8+ characters, not among the 100,000 most
common (bundled as truncated hashes), and zxcvbn score 3 or 4+ different words; this
replaces "strength shown, never blocked" (2026-10-23). Passwords in use are never
checked on unlock. Opening, joining and restoring refuse an Argon2 cost below the phone
floor. The Secret Key fingerprint is cut to 16 bits (a hint, never a check). A P2P host
serves a restoring device only after Allow is tapped (same number on both screens; no
switch to turn on since 2026-10-26), and only the vault's lock until it proves the Master
Key. The library is kept out of iOS and Android system backups. Still planned:
binding the Argon2 cost into the wraps (format v2), size padding, a header revision
against rollback, PIN wipe after wrong tries, rotating item keys. Details:
docs/security.md, ADR 0001, ADR 0003, docs/supply-chain.md (bundled data).

## 2026-10-25 — Note formatting, links that ask first

**Owner:** notes stay plain text on disk; formatting is only how they are read. The item
preview draws the app's own Markdown (headings, bold, italic, lists) plus checklist boxes
(`- [ ]`, `- [x]`), which can be ticked there and are saved like an edit, and web
addresses. A tapped address opens nothing by itself: a card names the real host
(international names as `xn--…`) and the full address, Cancel or Open. Only http and
https go to the browser, through a new native door next to the one for our own pages
(docs/security.md, links in notes); no link previews, no network. The editor gets a
small format bar over the keyboard (Bold, Italic, Heading, List, Checklist, Link) that
types the marks. Markdown files in the vault use the same links.

## 2026-10-24 — Google Drive sync, item by item, newest lock only

**Owner:** sync with Google Drive like P2P (same engine, item by item: only what changed
travels). As built: one "Cozy Safe" folder the app makes (scope `drive.file`, the app
sees nothing else), each sealed file named by its path in the sync layout. Every sync is
started by hand and allowed after a question naming Google Drive and the account; the
access token comes from Google's sign-in on the device, is used for that sync and kept
nowhere by the app. HTTPS is written in cs-net on rustls (one host, `www.googleapis.com`).

The vault's lock (header + library salt and fingerprint) is kept in the place as
`<vault>/lock/<ms>-<sha256>.json`: a newer lock replaces the others, an older one is
never put back, so after a password or Recovery Key change the old ones stop opening the
copy there (they found the earlier single `header.json` never changed). Passwords and the
24 words stay per device: another device keeps its own until changed there.

Next: join on a new device from Drive (or P2P) with the 24 words and the password alone.

## 2026-10-24 — The Recovery Key can be changed

**Owner:** let people change their Recovery Key, including from a key made before the 24
words. Behind Face ID and the vault password (like viewing it). Only the vault's Master Key
wrap changes (password + new key); no item is re-encrypted. Crash-safe order: the vault
keeps its old wrap beside the new one and the library accepts both keys, then the
keystore takes the new key, then opening with it drops the old ones
(`Library::change_secret_key`, `finish_key_change`). Earlier backups keep needing the old
key; the app offers a backup at the end. Refused while another vault opens by password
(the app has one vault; debug builds can have more).

## 2026-10-24 — Network only by hand, in one crate

**Owner:** sync (Google Drive, P2P) may use the network, but **every connection is
allowed by hand**: no automatic or background sync. Each time, the app asks, naming
where it will connect (Google Drive, or the other device's address); only then is a
one-time permit made, bound to that one destination and that session. In code, no
socket can be opened without such a permit. All network code lives in one small crate,
`cs-net` (the only crate cackle lets use `net`); the vault core stays network-free.
Platforms get their network permission (Android INTERNET, macOS sandbox network
entitlement, iOS local network usage text). Every permitted connection is logged
(when, where) and shown under Settings → Security. Sync is off until set up. The
security page, website and store privacy answers change to: nothing leaves the phone
unless you start a sync, and then only encrypted, to your Google Drive or your device.

As built (P2P, 0.1.44): the log sits on the Sync page, sealed in the vault index. cs-net
refuses any address outside the local network (private, link-local) both for listening
and connecting, and the compiled Rust library may import no name-lookup function, so it
can only reach an address that was scanned or typed. QR codes are drawn and read in Rust
(`qrcode`, `rqrr`), no camera-scanning plugin. While the host waits and while the other
device works, the vault is not held (it stays usable).

## 2026-10-24 — One vault in the app; the core keeps many

**Owner:** the app offers **one vault**: no "New vault" button, no vault list. Settings
gets "Delete vault" (after Face ID / the phone's passcode, also when the PIN and
password are forgotten), then a fresh start. **The core (`cs-vault`) keeps multi-vault
support unchanged** (library with several `vaults/<id>/`, PIN and password picking the
vault, backups) so that several vaults can come back later by changing only the UI.
A phone that already has several vaults keeps opening each with its PIN.
Why: simpler (one PIN, one password, one set of 24 words), and a vault list would show
how many vaults exist — which the files on disk show anyway, so hiding it was never real.
Groups (tags) cover "family / work". Also: the + sits in the middle; its menu is to be
redone (horizontal, fewer choices) — under discussion.

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

"Blur thumbnails" (Settings → Security since 0.1.72) is on unless the person turns it off; turning it
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


## 2026-10-24 — Restore from anywhere, cleaner sync

- Restore asks the 24 words and the vault password once, then where the vault is:
  another device over Wi‑Fi (the main way; no cloud, no file), Google Drive, or a backup
  file. A device with no vault pairs with a key from the 24 words (docs/adr/0003-sync.md,
  P2P security 8). With no copy left anywhere the app says so plainly: the words alone
  cannot bring a vault back, since its Master Key is random and lives only in the vault.
- A first vault always shows fresh 24 words: a start left half-way never shows its words
  again.
- Paste button on every 24-word field; the clipboard is emptied after.
- Home says when the vault is only on this device (no sync, no backup yet); closing the
  note hides it for 30 days.
- Items deleted for good are removed from the sync place too (they used to stay in
  Google Drive); counted apart from the items going up.
- The sync screen draws this phone and the other end, says what goes where, and shows
  items, MB, speed and time left. Android keeps syncing with the phone locked (a
  foreground service with a notification); iPhone continues by itself on return.
- Google Drive reuses one HTTPS connection (keep-alive).
