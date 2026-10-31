# ADR 0005: Two kinds of vault, Top secret and Private

- Status: proposed (waiting for the owner's approval before any code)
- Date: 2026-10-30
- Decisions it rests on: [decisions.md](../decisions.md) (2026-10-30), the rule in
  [supply-chain.md](../supply-chain.md#top-secret-means-top-secret-owner-2026-10-30-absolute)

## Context

Reading anything from outside is where a security app breaks: picture, video and PDF
decoders, file pickers, thumbnails. Keys and passwords should not share an app session
with them. The owner decided on one app with two kinds of vault that have nothing to do
with each other.

## Decision

### What each kind is

| | Top secret | Private |
|---|---|---|
| Opened with | password + the 24 words (Secret Key), as today | a strong password only |
| Keeps | text (notes, passwords), files, photos taken with the app's camera | photos, videos, files, voice notes, text |
| Shows in the app | text only; a file or photo is a row: name, note, icon from the file name, size, date | everything, as today |
| Decodes | nothing (no preview, no thumbnail) | pictures, video, PDF, through the system and `pdfrx` |
| Import from the photo library or other apps | no | yes |
| Opens a file or photo | by exporting it, after a warning that it then leaves the vault | in the app |
| Sync | Google Drive and a device nearby | Google Drive and a device nearby |
| Core dependencies | audited cryptography and SQLite only | as today |

A photo or file saved in Top secret asks for a name at once (a camera photo: "ID card,
front"), with an optional one-line note, so it can be found without opening it.

### Nothing shared

- **Separate libraries on disk:** `library/` (Top secret, today's folder) and
  `private/` (Private), each with its own `library.json`, salt, Argon2 parameters, vault
  index and blobs.
- **Separate secrets:** keystore entries get a kind prefix (`cozysafe.secret-key` stays
  Top secret's; Private has no Secret Key). Biometric unlock keys, the Google sign-in and
  its tokens, the preferences file and the temporary folder are all per kind. Two
  different Google accounts are allowed.
- **One kind per app run.** The kind is chosen at start (the last one used, kept in a
  small file outside both libraries) and fixed in memory for the whole run; the Rust side
  refuses any call for the other kind. No screen shows both.
- **Switching** (either way): the temporary folder is wiped, every key and cache in
  memory is dropped, the next kind is written to the start file, then:
  - Android, macOS, Windows, Linux: the app quits by itself; the next start opens the
    other kind.
  - iPhone and iPad: a full-screen page says "Close Cozy Safe and open it again"; nothing
    else can be done on it. Apple's guidelines ask apps not to quit by themselves (App
    Review may treat it as a crash), so the person closes it.
- **Private's backup key lives in Top secret** as an ordinary text item ("Private vault
  key"), offered when the Private vault is made. The app never reads it on its own: a
  person who forgot the Private password opens Top secret, reads it, switches, types it.

### Private's password

No Secret Key means the password is the only barrier against a copy of the files. A
Private password must be at least 4 words or 14 characters and pass the same common-
password check; Argon2id runs with a higher cost than Top secret's (about 1 second on a
phone). Exact parameters are measured on the slowest supported phone before they are
fixed.

### Code split

- **`cs-core`** (new crate): the Top secret core: key hierarchy, sealing, the vault
  index, items as sealed records and opaque blobs. Depends only on the audited
  RustCrypto crates and `rusqlite`. Its own small encoding replaces `serde_json`, its own
  error type replaces `thiserror`, its own hex and its own password check (length and a
  bundled list of common passwords) replace `hex` and `zxcvbn`.
- **`cs-vault`** keeps what Private needs on top of `cs-core` (history, audit, imports,
  photos) and may keep its present dependencies.
- Done in step 1 (2026-10-31): the library, vaults, items, PINs, the index and version
  history are in `cs-core` (history too for now: items keep versions as they change;
  which kind keeps history is decided in steps 3–4); sync, the audit, backups and
  joining are in `cs-vault`, as traits on the core's types. The Master Key stays in
  `cs-core`: sync seals and opens through `OpenVault::sealer`.
- **Sync** carries only sealed data, for both kinds. For Top secret it uses `rustls`
  (audited) and a small JSON reader of our own for Google Drive's answers, in place of
  `serde_json`.
- **CI check:** `cargo tree -p cs-core -e normal` must list only crates on the allowlist
  in supply-chain.md (each with its audit report linked). Anything else fails the build.
- **Flutter:** the screens ask the kind before showing an action; a Top secret run never
  builds a photo viewer, a video player, a PDF view or an import button. A test renders
  every Top secret screen and fails if one of those widgets appears.

### Vaults made before

Not in a public beta yet, so the storage format may change. On the first start of the
new version:

1. Today's library becomes Top secret (same password, same 24 words).
2. If it holds photos, videos, voice notes or files imported from outside, the app asks
   for a Private password, makes the Private library, moves those items into it (sealed
   again under Private's keys) and offers to save Private's key in Top secret.
3. Only after every moved item reads back from Private are they removed from Top secret.
4. Notes, passwords and files that are only stored stay in Top secret.

## Order of work (each step: mockup, approval, release)

1. `cs-core` and the CI check, with no visible change (the app keeps working on it).
2. One kind per run: start file, separate folders, keystore names, preferences, the
   switch and the iPhone close page.
3. Private library: strong password rule, higher Argon2 cost, creation after the first
   vault, the backup key saved in Top secret.
4. Top secret screens: file and camera rows, naming, export with a warning; photo
   viewer, player, PDF and import removed from Top secret.
5. Sync per kind (own Google sign-in, own JSON reader for Top secret).
6. Moving existing vaults.

## Open

- Decided 2026-10-31: the cryptography stays RustCrypto (memory safe, no C). `argon2`,
  `sha2`, `hmac` and `hkdf` have no public audit, so they are covered by our own review
  and the standard test vectors (see supply-chain.md); the core builds offline from
  copies kept in `third_party/`.
- Decided 2026-10-31: `webpki-roots` (Mozilla's list of certificate authorities, data
  not code) is allowed on the Top secret sync path, kept as a copy in the repo like the
  rest.
- Decided 2026-10-31: Top secret keeps version history (a note or password changed by
  mistake can be brought back); the code is already in `cs-core`.
- Decided 2026-10-31: steps 2–6 are built on the branch and merged into `main` only when
  all are done; each step still gets a mockup, the owner's approval and an internal test
  build (TestFlight, Play internal) made from the branch, with no public GitHub release.
- Exporting a file writes it decrypted to the temporary folder for the other app; it is
  wiped on lock and at start, but the other app may keep its own copy. The warning says
  so.
