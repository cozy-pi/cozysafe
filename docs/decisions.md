# Decisions

What was decided, when, and what is still open. Newest first. Update this page in the
same change as the decision (or right after the conversation that made it), so nothing
depends on memory. Details live in the linked docs; this page is the index.
How a vault stores data and how it is protected, as built: [data-model.md](data-model.md),
[cryptography.md](cryptography.md).

## 2026-11-14 — A review of the whole app: sync with three devices, password tries, quiet losses

A read of the core, sync, the app's platform layer, the journeys and the docs. What
mattered is fixed in the same change; the rest is in [backlog.md](backlog.md).

- **Sync never lets an older revision or deletion replace a newer edit**, and never
  passes over a journal entry it could not read ([ADR 0003](adr/0003-sync.md), "Read in
  sequence, applied by age"). With three devices the first happened with an honest
  place too. The lock a joining device reads is capped while read.
- **Password tries**: a try made while typing counts even when the app is closed on it;
  Check your 24 words and password counts like every other page; the wait shows on the
  lock screen while it lasts ([security.md](security.md)).
- **Deleting a vault keeps the cloud copy of its 24 words unless its copy in Google
  Drive is deleted too.** It went with the vault before: someone who never wrote the
  words down could not restore the Drive copy they chose to keep. The words alone open
  nothing. (The 2026-10-24 decision stands for this device: its own copy of the words
  goes with its last vault.)
- **The 24 words are copied as a password is** (sensitive, this device only, 60 s).
- **Hostile files**: a file that is not an item no longer keeps a vault from opening;
  backup names must be ids exactly as the app writes them; Argon2 is refused above
  1 GiB or 8 passes (was 4 GiB, 32: more than a phone has).
- **iPhone**: the app's `tmp/` folder is swept with its Caches.
- **Nothing lost quietly**: an import says how many files did not go in, and how far it
  got when the lock cut it short; reading failures say "couldn't open", not "couldn't
  save"; Google Drive failures no longer say "same Wi-Fi"; Recently deleted and Earlier
  versions say when they could not be read; an error with its code stays 8 s.
- **A forgotten password**: from the second wrong one, with Face ID or a fingerprint
  set, the lock screen says the way back in. Said where it is needed, not before.
- **The public APK never has Test sign-in**; only the Play bundle for closed testing may.
- Not changed, for the owner: Android 12 and older may show the vault in Recents with
  screenshots allowed (to check on a device); `website/.wrangler/` was tracked with the
  Cloudflare account's id and name, now untracked and ignored (still in history).

## 2026-11-06 — Passwords and two-factor codes; a post-quantum rule; technical docs

**Owner (2026-11-06):** a password and 2FA store, the storage format agreed first;
readable docs of the data and the encryption, kept current; everything resistant to
quantum computers, written down as a rule. As built:
- [ADR 0009](adr/0009-secure-items.md): kinds `login`, `otp`, `codes`, each an ordinary
  item; a `summary` (account, hosts) in the record for lists, rebuilt from the content
  when an older app drops it; the content a JSON document with a version `v`, unknown
  fields kept; password history is the version history.
- Copying a secret: the system forgets it after 90 s (owner: 30 s too short), choice of
  30 s / 90 s / 3 min / never; Top Secret fixed at 90 s.
- Post-quantum rule (docs/security.md): 256-bit symmetric keys; every public-key step
  hybrid. Gap found while writing docs/cryptography.md: adding a device used X25519
  alone; owner approved making it X-Wing next.
- docs/data-model.md and docs/cryptography.md, checked against the code by
  `cs-core` tests (`docs_current`).
- Older apps cannot be stopped from seeing new kinds (they check no version when
  syncing); from 0.2.28 an unknown kind shows "needs a newer version" and is never
  opened or shared.

## 2026-11-06 (later) — Adding a device is post-quantum

**Owner (2026-11-06):** every public-key step is hybrid, classical and post-quantum
together, both must hold; X-Wing preferred. As built:
- [ADR 0010](adr/0010-post-quantum-device-add.md): adding a device on the Wi-Fi makes
  its key with X-Wing (ML-KEM-768 + X25519) instead of X25519 alone, so a recorded
  session (the password and the 24 words cross it) cannot be opened later by a quantum
  computer. Same commitment and 8-digit code; mode 10, labels `p2p-add/v2/…`. Older apps
  are refused at once on both sides, no fallback.

## 2026-11-06 — A vault in a few taps; its identity; words and password kept by the system

**Owner (2026-11-05 to 11-06):** security first, not to the extreme: a balance with
convenience. Making a vault should be taps only. The 24 words and the password may be
kept by the system so a vault is not lost; the word check may be skipped, with a
warning. What is kept outside needs an identity that cannot change, and later vaults
and devices will exchange data: an identity with keys, resistant to quantum computers.
As built:
- [ADR 0008](adr/0008-vault-identity.md): every vault has hybrid identity keys from its
  Master Key (Ed25519 + ML-DSA-65 signing, X-Wing sealing) and a code `7F3A-9K2Q` from
  their fingerprint. 18 crates added to the Top secret core, each a reviewed copy with
  standard vectors (docs/supply-chain.md).
- New vault: mode → (words) the 24 words with the cloud copy on by default → (no copy)
  four words back, skippable after a warning, reminded once later → the password
  (system password manager, under `Cozy Safe <code>`) → Face ID → in. No intro, no
  look steps. The vault is drafted before the password so its code is known.
- The cloud copy is one item per set of words, named by its fingerprint, labelled with
  the vaults' codes; restore screens fill in the set that fits. Never for a Top secret
  vault (docs/security.md).
- Needs, outside the repo: Associated Domains on the App ID and a new provisioning
  profile (owner), and `/.well-known/apple-app-site-association` on cozypi.com (the
  cozypi-site Worker). Until both, iOS shows no strong-password suggestion and does not
  save the password; Android works without them.

## 2026-11-05 — Note format bar fits the phone; trash gets the summary line

**Owner:** the note's format bar was cut off at the right on an iPhone (nine buttons,
scrolled sideways; mockups were 430 wide and hid it). Now six buttons at most, sized to
fit: Undo · Redo · Bold · Italic · Checklist · Aa. Aa swaps the bar in place for
Heading · List · Link · Hide keyboard (as iPhone Notes); a menu would take the focus
and drop the keyboard. Hide keyboard stays, in the second set: the note fills the
screen, so there is no "outside" to tap. Notes capitalise sentences (a Flutter field
gets no capitals unless it asks). Recently deleted shows `N items · size` on top, both
parts together; no Drive cloud, since the part kept only on this device does not sync.

## 2026-11-04 (later) — One summary line under every tab's title

**Owner:** `N items · size`, then the Drive cloud close after the size (not far right),
on every tab with the same structure; the overview's line under the search field is
gone. Each tab counts what it shows; the overview counts the whole vault.

## 2026-11-04 — Screenshots allowed by default; tips where a thing is met

**Owner:** a black screenshot looked like a fault and Android said nothing, so people
did not know why. Now:

- "Block screenshots" is **off by default** (`Settings.blockScreenshots`: no choice
  stored → off, or on in Top secret). A stored choice wins either way. People who never
  touched the switch go from blocked to allowed with this update. The 24 words, the
  Secret Key and the device code stay blocked whatever the switch (`WordsAwake`).
  This replaces the default of "2026-10-21 — Block screenshots on iPhone too" (the
  iPhone technique stays).
- After a screenshot: a card the first time ("saved outside the vault, not encrypted",
  "Don't remind me again"), a short toast after that, nothing once quieted. iOS, and
  Android 14+ (`registerScreenCaptureCallback`, `DETECT_SCREEN_CAPTURE`). Android 13
  and older cannot tell.
- The Recents preview stays hidden on every Android (13+: `setRecentsScreenshotEnabled`;
  older: FLAG_SECURE while paused).
- A test build's test vault: screenshots, clear thumbnails, the Recents preview, no
  notices. It is the test vault when opened with the test password
  (`TestLogin.noteUnlocked`), not only through the button. A vault opened with a
  fingerprint is recognised once the password has been typed on that device.
  There, "Block screenshots" and "Blur thumbnails" show off and greyed: a switch that
  says on while screenshots work made no sense (owner).
- **Explaining a feature:** a lone tip, once, where the person first meets it (blurred
  thumbnails: the first time the Library shows them). A header eye button and a status
  line were both turned down as clutter; a tour at the start is skipped and forgotten.
  Rule in design-language.md.
- **Text that sends someone to a setting** names it with `settingsPath()` and offers a
  Settings button that opens on the lit row (`_openSettings(focus:)`). Two texts named
  "Settings → Display", a page that no longer exists; `test/settings_path_test.dart`
  now checks every spot is on the page its path names.

## 2026-11-03 (evening) — The bar shows the three kinds held most

**Owner:** the bottom bar shows the three kinds of item the vault holds most of, most on
the left (1 → 2 → 3); the quick buttons above + add those three, in the order 2 → 1 → 3
(the most in the middle, over +).

- Ranked by number of items; a tie keeps the old order Library, Files, Notes, Voice.
  Voice gets a tab when it is among the three (it had none since 2026-10-24).
- A kind with no items gets no tab; the quick buttons are always three (an empty vault
  ranks every kind equal). The fourth kind is reached from the overview; the card above
  + still lists every way.
- Library's quick button takes a photo (owner); with no camera, add photos. Record video
  is no longer a quick button, only in the card.
- The order changes as soon as the counts do (owner asked whether that is heavy: the
  counts are taken once per change of the item list, not on every frame).

## 2026-11-03 (afternoon) — Top secret "Don't ask again"; words file name; backdrop clipped

**Owner:**

- **A sync tap is the allowing; no card after it** ("they tapped it already, too many
  questions"). Google Drive's Sync now, Sync with your vault on another device and Set up a new device
  start at once, and so does Restore → From another device on the new device. Only
  adding the Google account still shows the card (it names the account and carries
  "Sync automatically"); a scanned QR code (Use QR code, when the network keeps two
  devices from finding each other) still names its address and asks. This changes 2026-10-24's "each time, the app asks": the person's
  tap on a named sync is the by-hand step. Nothing else changes: still one permit per
  run in `cs-net`, bound to that destination, logged, local addresses only.

- **Top secret files can skip the card.** Quick Look on iPhone works well, and the card
  before every open was too much. The card a Top secret file shows (what it is, why it
  does not open in the app, Open in another app) now has "Don't ask again for this
  vault"; once ticked, a tap opens the file at once (Quick Look on iPhone, the system's
  Open with on Android). This replaces 2026-10-31's "the same warning every time".
  The choice is its own (`sealed-open-ok-<vault>`), apart from the everyday vault's
  ask-once (`share-ok-<vault>`), so a vault turned Top secret asks again. Nothing else
  changes: the app still decodes nothing.
- **The saved 24 words have a technical file name:** `cozysafe-recovery-key-YYYY-MM-DD.txt`,
  the same in every language: ASCII, lower case, no spaces (was "Khoá khôi phục - Cozy
  Safe.txt", accents and spaces, the same name every time). The text inside stays in
  the app's language. 0.2.19.
- **The lock-screen backdrop is clipped to its page.** Trap: the tilted collage is
  drawn far past the page's edges (`half = 0.8 × the longer side`). On the iPhone back
  swipe from a new vault, the page sliding away drew its collage over the first screen,
  logo and buttons included. 0.2.19 only took the blur layer away (wrong guess, and it
  got worse: that layer had been bounding the drawing). 0.2.20 adds a `ClipRect`;
  `test/backdrop_test.dart` paints it in a small box and checks nothing lands outside.

## 2026-11-03 — One password per vault on a device; kinds and chips

**Owner:** three restores of one vault left three copies, and only the first ever opened
(the password picks the vault, library after library). Now no two vaults on a device
share a password: a restore that would add one stops with "already on this device", a
new vault or a password change is refused. Kinds: the overview is a 3-column grid
(Photos, Videos, Notes, Voice, Documents, Other files; empty kinds hidden); Files always
has the chips All, Photos, Videos, Documents, Other, the Library All, Photos, Videos. A
count is what the tap shows: in an everyday vault a photo file imported as a file is
counted with Other files (it lives in Files). Quick Look on iPhone sits in a card with a
bar that never hides (name, Close).

## 2026-11-03 — Mode never chosen for the person; copied words numbered

**Owner:** when a vault is made, neither Private nor Top Secret is picked by default: the
person must choose (Next stays off until then). The comparison table under the choices
is gone (five of seven rows were the same); each choice says what it does and what it
suits. Copied words are numbered one per line like the saved file, and Paste reads that
back. The new-vault steps' edge swipe follows the finger.

## 2026-11-02 (night) — The 24 words can be copied and saved again; old keys gone

**Owner:** writing 24 words down by hand is too much; the old kind of key is not used.
Decided:

- Copy, Save to a file and Open file for the 24 words are back (`WORDS_EXPORT` now on by
  default; this replaces 2026-10-30's "never written to disk"). Open file sits beside
  Paste wherever the words are typed back. The iCloud Keychain / Google Block Store copy
  stays off. The risks are written in [security.md](security.md#how-the-24-words-leave-the-app-2026-10-30-changed-2026-11-02).
- The check after the words still asks four of them, typed; going back and forth picks
  four other cells each time (they stayed the same).
- `CS1-…` keys and 128-bit Secret Keys (libraries before 2026-10-21) are no longer read,
  in the app or the core, and the first-preview `secret-key` file is no longer moved.

## 2026-11-02 (later) — Ready for beta: file protection, ring copied, formats frozen

**Owner:** before the beta: iOS Data Protection on (vaults *complete unless open*,
temporary copies *complete*); the website drops "PIN"; restoring a Top secret vault in an
everyday run shows the restart page; ring and untrusted are copies in `third_party/rust/`
like the core; `docs/threat-model.md` written. Test sign-in stays on Android test builds.
From the beta on, the storage formats are frozen: every later version opens the vaults
and backups made by the beta builds. A 0.1.x app can drop a vault's Top secret mode from
its lock (ADR 0007, known limit); not fixable in old apps.

## 2026-11-02 — Vault facts; Manage vaults in Settings again; ask before stopping a sync

**Owner:** Settings has Manage vaults again, beside the lock screen's. No ⋯ on a vault: a
tap shows all that is known of it (mode, items, size, created on this device, what opens
it, its 24-word set, Google Drive, ID; a locked vault only what the device knows without
opening it), with Close and Delete on one row; a vault set to be deleted shows when that
was asked and when it goes. The delete page shows the same facts. Vaults have no name
(icon and colour only). Cancel or Back during a sync asks first. Android: a fingerprint
prompt closed with its Cancel button never answers (flutter_secure_storage 11.2.0), so
the lock screen no longer waits on it.

## 2026-11-01 (evening) — Add a device by an 8-digit code, no QR; Local network page

**Owner:** the QR invite was often not read, so it goes: the old device (Sync → Local
network → Set up a new device) waits on the Wi-Fi, the new one (Restore → From another
device) finds it, the two make a key (X25519, the new device committing first) and the old
device shows 8 digits from it, typed on the new device; then the vault password. Three
tries for the code, three for the password; nothing crosses before both are right, and
no device name before the code. Someone in the middle gets codes that do not match
([ADR 0003](adr/0003-sync.md) point 11). Sync's two Wi-Fi rows become one, Local network,
with Sync with your vault on another device and Set up a new device; the two devices
joined by a lock head every sync page. Reading items no longer waits for a sync (a
read-only SQLite connection), and debug mode turns on without the owner check.

## 2026-11-01 — Open with is not Share; on iPhone it is Quick Look

**Owner:** "open is open, share is share": tapping an item in Top Secret Mode, or a file
the app cannot show, opens it; the Share button stays the full share sheet. Android keeps
its own "Open with". iPhone has no list of apps that open a file (every way out is the
share sheet), so the file opens in Quick Look, as the Files app opens it; its
own share button reaches other apps. It opens as a card, not full screen (owner
2026-11-02: full screen hid its bar until a tap and did not show the app was still
there); a swipe down closes it. Quick Look draws in a system extension, not in the
app, so ADR 0006 holds (the app decodes nothing; the decrypted copy is removed when the
viewer closes). A kind Quick Look cannot show gets the share sheet without AirDrop,
Messages, Mail, copy, print and save. Copies leave with an extension from their kind.

## 2026-11-01 — A vault may have its own 24 words; restore by QR; test sign-in

**Owner:** making a vault asks which 24 words it uses: the device's set, or a new set of
its own. Each set is a library of its own (`<library>-<16 hex>` beside the first, its key
under its own keystore name; formats unchanged); unlocking tries each, Face ID still opens
one vault per device, and a library goes with its last vault. Restoring onto a device that
has vaults goes into a new library. Restore starts with the source (Google Drive, a
backup file: then the words and the password; another device: scan its QR code, then the
password only, [ADR 0003](adr/0003-sync.md) point 11 — nothing in the middle can read or
join, the old device checks the password before the words cross). Android test builds
show "Test sign-in". Not yet: the source-first restore screens and the QR restore.

## 2026-10-31 (night) — Each vault has its own mode; Vaults on this device

**Owner:** the mode belongs to each vault, chosen when any vault is made
([ADR 0007](adr/0007-mode-per-vault.md)). Top Secret Mode takes photos from the library
as sealed files (no thumbnail). Face ID opens one vault per device: it is offered only
when no vault has it, and moving it in Settings warns that the other vault loses it.
Settings → Vaults on this device: delete a vault with its password, or, password
forgotten, after the owner check it goes in seven days unless opened with its password.
Deleting is on this device; Google Drive only when ticked, and Sync → Google Drive can
delete the open vault's copy there. No "deleted" mark on Drive (a device synced over
Wi-Fi would send the vault back anyway). Drive syncs 5 seconds after the last change.
Settings' sub-pages open as pages of their own.

## 2026-10-31 (evening) — Top Secret Mode replaces the two kinds of vault

**Owner:** one vault (password and the 24 words, as always) with a switch, **Top Secret
Mode** ("Chế độ tuyệt mật"), like the iPhone's Lockdown Mode; the Private vault is gone.
[ADR 0006](adr/0006-top-secret-mode.md) replaces ADR 0005.

- The mode changes only what the app does with what is inside: in it nothing is decoded
  (photos, videos, PDFs, thumbnails), files open in another app, nothing comes from the
  photo library. Encryption is the same in both modes; the comparison list says so first.
- Enforced in Rust as well as in the screens. Turning it on or off restarts the app and
  asks for the owner first.
- Chosen when the first vault is made (Private · Top secret, with the differences and
  "you can change this later in Settings"); a card for it near the top of Settings.
- The everyday mode is called **Private** ("Riêng tư"). Marks: red shield with a lock,
  green shield with a photo. While on, a small red shield on the Settings button's
  corner, nowhere else.
- Settings' sub-pages go back with an edge swipe (iPhone; they are shown in place).
- Test build from the branch only; merge into `main` once tried.

## 2026-10-30 (later) — Two kinds of vault: what is decided

Replaced 2026-10-31 by Top Secret Mode (above).


**Owner:**
- **Top secret syncs**, over Google Drive and with a device nearby. Only the vault core
  (keys, decryption) is held to "audited cryptography and SQLite only"; the sync layer
  carries data already sealed by the core and never sees a key or a plain byte. It uses
  `rustls` (audited) and a small JSON reader of our own for Google Drive's answers.
- **A Private vault's backup key is kept in the Top secret vault**, as an ordinary text
  item. The app does not link the two: someone who forgot the Private password opens
  Top secret, reads the key, restarts into Private and types it. The two are never open
  at the same time.
- **Top secret keeps text, files and photos taken with the app's camera** (no import
  from the photo library). Files and photos are sealed as they are and never opened in
  the app: no preview, no thumbnail. Opening one means exporting it, after a warning.
- **The first vault on a device is Top secret.** Right after it is made, the app offers
  a Private vault for photos and files.
- Still to design and approve before building: the screens, the code split, and what
  happens to vaults made before (they hold photos today).

## 2026-10-31 (later) — Top secret vault: the rest on the branch

**Owner:** finish the Top secret vault (ADR 0005 steps 2–6) on the branch, then merge.
Each step: mockup, approval, an internal test build from the branch (no public
release). Top secret keeps version history. `webpki-roots` is allowed for Top secret
sync. New passwords also need 5 different characters.

## 2026-10-31 — Top secret core, step 1: built from copies, a simpler password rule

**Owner:** the cryptography stays RustCrypto (memory safe, no C); "audited" means a
public audit, or our own review plus the standard test vectors. The Top secret core is
built from copies kept in the repo and nothing is downloaded for it; every build checks
the copies byte for byte, and a weekly job compares them with upstream and recommends
what to update (supply-chain.md). New passwords: at least 12 characters (or 4 words,
which always are), at least 5 different characters, and not among the most common; zxcvbn is gone (security.md,
"Passwords"). Passwords already in use keep working. On a computer unlocking takes
about 0.9 s (no threading library in the core). The vault core moved into `cs-core`
(library, vaults, items, PINs, history, index) and reads and writes the same files as
before; sync, backups and joining stay in `cs-vault` on top of it.

## 2026-10-30 (later) — Top secret is top secret

**Owner, absolute:** the core of a Top secret vault uses only independently audited
cryptography and SQLite, nothing else. Always remember that top secret means top secret.
Top secret and Private have nothing to do with each other: switching between them, either
way, restarts the app and wipes every temporary file; nothing is shared. The rule, what it removes (`serde`, `serde_json`, `hex`, `thiserror`, `zxcvbn`) and how
CI keeps it: [supply-chain.md](supply-chain.md#top-secret-means-top-secret-owner-2026-10-30-absolute).

## 2026-10-30 (later) — Sync sooner; the lock card taller

**Owner:** sync was not fast enough. Decided: a sync 15 seconds after the last change
(each change starts the wait again). A change made during a run is followed by another
run, and changes waiting for Wi-Fi or a connection are retried every minute (both used to
wait for the 30-minute full sync). While syncing, the home cloud is the "changes waiting"
cloud with its arrow moving up (in place of the cloud filling up). The unlock card gets
more room under the password field (option 2 of four shown).

## 2026-10-30 — The 24 words never leave the screen; temporary files swept

**Owner:** opening files from outside is dangerous for a security app, and the 24 words
must never be written to disk, absolutely. Decided:

- A build switch, `WORDS_EXPORT` (off by default): no Copy, Save to a file, share or Open
  file for the words. This replaces 2026-10-29's "save the words as a .txt". The pages
  showing the words stay on for 3 minutes after the last touch (each touch starts again).
- The temporary folder is emptied at start and on lock; Windows and Linux get a private one.
- Memory kept tight (owner: the app has been killed; no crash report on Play or
  TestFlight, which fits the system killing it for memory): photos at screen size,
  fewer read ahead, caches capped. Memory in use shows in Debug.
- The words are typed back in a numbered grid like the page they were written from (all
  six places: restore, joining from Drive, the check in Settings, the four words asked
  when a vault is made, when the key changes and after the first backup password, which
  asked only one). A word turns to dots once its cell is left; four letters are enough
  and the cell moves on; a word not on the list is marked red; 24 real words that make
  no key are said at once (the checksum); Paste spreads a numbered list over the cells
  (it used to fail on the numbers) and empties the clipboard. A `CS1-…` key keeps one field.
- With the switch off, the iCloud Keychain / Google Block Store copy of the words is off
  too, and a copy kept before is taken out at start.
- Google Drive's cloud on the home page has one picture per state (mockup approved): grey
  crossed out only while sync is not set up; blue with an arrow up for changes waiting
  (it used to turn grey right after adding photos); blue filling up while items move;
  green tick; amber with Wi-Fi or with three dots while it waits for Wi-Fi or a
  connection; red "!" when something is to be done. A full Drive is now red (it stayed
  grey), and the Drive page says why in one line.
- Next, to discuss: two kinds of vault in one app. **Top secret** (24 words; text only,
  no decoder ever runs) and **Private** (a strong password; photos and files, input
  checked). From Private to Top secret the app must restart (a flag in memory blocks it;
  a Quit button). Details in [security.md](security.md#things-from-outside-and-temporary-files-2026-10-30).

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

## 2026-10-28 — Third-party code: hijacked packages, not only bugs

**Owner:** worried that a library could be malicious or hijacked (xz, tj-actions, the
npm worms), not only buggy; there are about 350 packages. No mechanism can stop code
running inside the app's process, so the aim is: hard to get in, little it can reach,
quick to notice. Agreed, in this order of value:

1. **No builds on the owner's own computer** (it holds the secrets vault, SSH keys,
   tokens): build scripts, Gradle and CocoaPods run with full access wherever they run.
   *Done for Rust:* `tools/sandbox/run` runs cargo in a container that sees only the
   repository, read-only, without network (docs/supply-chain.md). Flutter, Gradle and
   Xcode builds already run only on CI.
2. **Slow, reviewed updates.** The 14-day age rule is already in place
   (`tools/check-age`). *Done:* `cargo-vet` in CI; audits imported from Google, Mozilla,
   Bytecode Alliance, ISRG, Zcash and Embark; the rest exempted at today's versions, so
   every new or updated crate needs its diff read and certified. Dart has no such tool.
3. **Fewer packages.** *Proposed, owner to choose:* replace with our own small platform
   code, no visible change: `fc_native_video_thumbnail` (tier 1, small publisher),
   `flutter_secure_storage` (a community package holding our keys; existing entries
   must still be read), `share_plus`, `record` (two more community publishers),
   `package_info_plus` (version passed in at build time). About 22 packages; with
   `pdfrx` (point 4) about 37 of 364. Kept: the Flutter team's plugins, `intl`, and
   `crypto` / `hex` (removing them removes nothing else).
4. **PDFium.** *Proposed:* [ADR 0004](adr/0004-pdf-rendering.md): the system's PDF
   renderer on every platform (Android's in an isolated process), `pdfrx` and our own
   PDFium copy gone; Linux without an in-app PDF preview.

Done now: **[dependencies.md](dependencies.md)**, a page of every package by risk tier,
generated from the lock files (`tools/deps-report`, kept current by CI), with a weekly
owner-change check and a monthly review issue ([supply-chain.md](supply-chain.md)).
Baseline 2026-10-28: the packages already passed the allowlist review when they came in.

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
(`core/cs-core/src/history.rs`, docs/security.md). The note editor's Undo/Redo is the
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
types the marks (since 2026-11-05 Heading, List and Link sit behind Aa). Markdown files in the vault use the same links.

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

**Commit trailers.** Two commits were pushed with a tool's trailer; the owner chose not
to rewrite history for them. Personal names and emails stay out of the repository.

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
