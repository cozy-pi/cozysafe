# Cozy Safe

An open-source, cross-platform encrypted vault for photos, documents, files and
notes. Everything is encrypted on your device before it is saved.

> **Status: preview.** Sync works (with a device on the same Wi‑Fi, or through your
> Google Drive on phones), but the app is young. Don't keep your only copy of something
> important in it yet, and use **Back up to a file** often. Decisions and what is next: [`docs/decisions.md`](docs/decisions.md).

Website and downloads: <https://safe.cozypi.com>

## Security: what we do

A vault app has to hold up against more than a stolen file. Each risk below and what
Cozy Safe does about it; the details are in the linked documents.

| If… | Cozy Safe… |
|---|---|
| **someone copies your files or your backup** | encrypts everything on the device before it is written, with a key that needs both your vault password and your Recovery Key (24 words) kept in the device's keystore ([how](#how-your-data-is-protected)) |
| **someone picks up your phone while a vault is open** | locks the vault as soon as the app leaves the screen (60 seconds of grace only when the app itself opened the share sheet or a picker), and after a few minutes without a touch (2 by default) |
| **someone looks over your shoulder, or a camera does** | shows notes by title only, in lists and in search; hides passwords as you type them; keeps the Recovery Key masked until you tap Show, and masks it again after 30 seconds; wipes anything you copy from the clipboard after 60 seconds and on lock; covers the app in the app switcher and while the screen is being recorded, and warns after a screenshot (iPhone); blocks screenshots and screen recording (Android, and iPhone through a secure layer) |
| **someone has your unlocked phone and tries to weaken the vault** | asks for Face ID, fingerprint or the phone's passcode before every security setting: turning biometrics off, changing the PIN or auto-lock, backups, the Recovery Key, showing note text, deleting a vault ([rules](docs/security.md)) |
| **someone sees the lock screen** | shows no vault names, no count and nothing of what is inside; each vault has its own PIN and only its icon and colour tell it apart |
| **something is left behind on the device** | encodes camera photos in memory (never the photo library, no location data); videos, voice memos and files being played or sent exist only as copies in the app's private temporary folder, deleted when done, on lock and at every start |
| **a library tries to send data out** | no server of ours and no analytics: only one part of the app can open a connection, only when you allow it, only to a device on your Wi‑Fi or to Google Drive's API (if you turn Drive sync on), and only encrypted files ever leave; network calls switched off everywhere else, and every library reviewed before it gets in ([below](#no-library-can-send-your-data-out)) |
| **someone tampers with a build** | builds in the open on GitHub, with every third-party action pinned to an exact commit; signing and store keys never reach the jobs that run other people's build code; every release file carries a build-provenance attestation, and the macOS app is notarized by Apple ([supply chain](docs/supply-chain.md)) |

How it stays that way:

- **Rules, not memory.** [`docs/security.md`](docs/security.md) lists every security
  setting and how secrets appear on screen; a new setting gets the owner check and a row
  there in the same change.
- **Checked on every push.** CI runs the Rust tests (encryption, vault, backup and
  restore), the app's tests (including that secrets stay hidden), and the network and
  library checks; a failure blocks the release.
- **Reviewed before it ships.** Every change to the app's screens is shown as a mockup
  rendered from the app itself and approved before release.
- **Open source** ([GPL-3.0](LICENSE)): anyone can read the code and verify a download with
  `gh attestation verify <file> -R cozy-pi/cozysafe`.

### How the code is kept secure

- **No home-made cryptography.** Only well-known, widely used Rust crates do the work:
  `chacha20poly1305` (XChaCha20-Poly1305), `argon2` (Argon2id), `hkdf` and `sha2`. Keys and
  nonces come from the operating system's secure random generator. The design and why is
  written down before the code ([ADR 0001](docs/adr/0001-encryption.md)).
- **Memory-safe languages.** The encryption, vault and photo code is Rust with
  `#![forbid(unsafe_code)]`: the compiler refuses unsafe code in those crates. The app is
  Dart. Key material is wiped from memory when it is dropped (`zeroize`).
- **Tests that attack the format.** Besides round trips, the Rust tests check that a
  flipped bit, a wrong key, a truncated file or reordered chunks are all rejected, that a
  copied vault cannot be opened with the PIN on another device, and that a damaged or
  crafted backup is refused and leaves nothing behind.
- **Strict checks on every push** ([CI](.github/workflows/ci.yml)): formatting, Clippy with
  warnings as errors, all Rust and Flutter tests, Flutter's analyzer, cargo-deny against
  the RustSec advisory database, cackle, and the library and network checks. Exact tool
  versions are pinned (Rust 1.99.1, Flutter 3.47.7) and lockfiles are enforced
  (`--locked`), so a build uses exactly the code that was reviewed.
- **Least privilege in CI.** Build jobs can only read the repository; only the release job
  can publish, and only the key jobs see a key.

Honest limits: there is **no recovery** if you lose your password, or both the device and
the Recovery Key. iPhone, Windows and Linux cannot take the network away from one app,
so there the "local only" guarantee rests on the app's own checks. On iPhone, blocking
screenshots relies on an unofficial iOS technique (a secure text field's layer) that
Apple could change. The code has not had an independent security audit yet, there is no
fuzzing yet, and one maintainer reviews the changes; reports are welcome at
support@cozypi.com.

## No library can send your data out

Cozy Safe has no server of its own: no account with us, no ads, no analytics, no crash
reports. Only two things touch the network, and only when you start them (or turn on
automatic sync with Google Drive): **syncing with
your other device on the same Wi‑Fi** (one address on your local network) and **syncing
through your Google Drive** (`www.googleapis.com`, and `oauth2.googleapis.com` for the
sign-in on computers, over TLS 1.3 with the
`drive.file` scope, so the app sees only the files it made). You allow each connection
by hand, or once for automatic sync, which runs only while the vault is open and can be
limited to Wi-Fi; everything sent is already encrypted with your vault's keys. A link in a
note opens in your browser only after you confirm it. A vault app is only as safe as every library inside it, and libraries do
get hijacked, so this is checked on every build, in layers (details and limits:
[supply chain](docs/supply-chain.md)):

- **One crate holds all network code** (`core/cs-net`). Every connection needs a permit the
  app only makes after you tap Allow, and it refuses any address outside your local network.
  cackle forbids the network to every other Rust crate.
- **No other hosts:** the only internet host the Rust core can reach is Google Drive's
  API, fixed in the code with its own bundled root certificates; local sync reaches only
  addresses on your own network.
- **Inside the app:** Dart's HTTP client and sockets are switched off when the app starts.
- **Android:** the app needs the internet permission for any socket, even a local one;
  CI fails if any other network permission (network state, Wi‑Fi control) sneaks in.
  The screen stays on while a sync runs; a background service that would keep it going
  with the phone locked waits for Google Play's approval.
- **macOS:** the app runs in Apple's sandbox; only the client and server network
  permissions sync needs are allowed.
- **Every library is reviewed before it gets in.** CI keeps a list of every Dart and Rust
  package, direct or indirect; a new one fails the build until someone reviews it. The
  sources of every package are scanned for network code, and each exception is written
  down with its reason. Rust crates are also checked by cackle and cargo-deny.
- **Honest limits:** no phone or computer can limit an app to the local network, so a
  native library determined to connect out is stopped by the checks above, not by the OS.
  The PDF engine (PDFium) is a prebuilt binary downloaded at build time, checked against
  a pinned SHA-256.

## What works today

- **One vault per device**, with its own icon and colour; nothing on disk says what is
  inside or how it is used. (The core supports several; the app shows one.)
- Unlock with Face ID or fingerprint, the vault's PIN, or its password. Wrong PINs
  make you wait longer each time.
- **Photos and videos:** take them inside the app (never in the photo library, no
  location data) or add them from the device. **Notes**, **voice memos** and **any
  file**, with a PDF viewer inside the app.
- **Groups:** put anything in one or more groups ("Passport": the photo, the scan and the
  note) and open a group from any section.
- **One way to open anything:** tap any item (photo, video, note, recording, PDF, file) and
  it opens over the page, centred, with one bar of buttons where the bottom bar is:
  Close, Open, Send, More, Delete. Every action button in the app sits at the bottom,
  within thumb reach. **Share** any item (a temporary copy, deleted right after).
- **Notes with formatting:** headings, bold, italic, lists and to-do boxes you can tick in
  the preview, links that ask before opening; a format bar over the keyboard. Notes stay
  plain text.
- **Leave and come back:** switching apps locks the vault at once, and after unlocking you
  are back on the page you were on; revealed words are hidden again and a Google Drive
  sync carries on.
- **Text files open as text:** Markdown, JSON and code files are shown formatted.
- **Remove the originals:** after adding photos or files from the device, the app offers
  to delete the unencrypted originals (the system asks first).
- **Overview:** the first tab shows the whole vault at a glance: each section with its
  count, the groups, what was added last, and search.
- Search (names and note text, grouped by kind), Recently deleted (30 days), auto-lock,
  blocked screenshots, light / dark / automatic appearance.
- **How the vault is protected:** a page in Settings explains the protection in plain
  words, with pictures, and the technical details folded at the end.
- **Private on screen:** note lists and search show titles only, the Recovery Key and
  passwords stay masked until you tap Show, and every security setting asks for Face ID,
  fingerprint or the phone's passcode first ([security rules](docs/security.md)).
- **Simple to start:** an empty vault offers big tiles to add the first thing; the bottom
  bar shows the overview, library, +, files and notes, and + always offers every way to
  add (photos, camera, video, note, voice memo, file).
- **Sync with your other device on the same Wi‑Fi:** one shows a 3-digit code, the other
  finds it on the network by itself and takes the code (a QR works too). Only a device
  holding the same vault can answer; the code works once, for 5 minutes. Both devices end
  up the same; notes edited on both keep both texts.
- **Sync through Google Drive** (iPhone, Android): a sealed copy in a "Cozy Safe" folder,
  only encrypted files, with progress in MB and time left.
- **Nothing lost by mistake:** an item deleted for good on another device is kept here in
  Recently deleted for 30 days, not synced back; restore it and it returns everywhere.
- **A new device from the 24 words and password alone:** from Google Drive or from your
  other device nearby, no backup file needed. A sealed log lists every connection.
- **Back up to one encrypted file** (every vault with a vault password) and restore it
  on a new device with your **Recovery Key** (24 words) and the **vault password**.
- **See or change the Recovery Key:** behind Face ID **and** the vault password. Change it
  to new 24 words (also from the older `CS1-` key) without touching any item; earlier
  backups keep needing the old key. Deleting the last vault forgets its words too.
- **15 languages**, light and dark. Pick one in Settings → Language, or in the
  system's settings for the app (iPhone, Android 13+); the two stay the same.

Not yet: Google Drive on computers, keeping a sync going with an Android phone locked
(waiting for Google Play), and the security work listed in
[`docs/decisions.md`](docs/decisions.md).

## Install

| Platform | How |
|---|---|
| macOS | [CozySafe-macos.dmg](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-macos.dmg), signed and notarized |
| Windows | [CozySafe-windows-x64.zip](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-windows-x64.zip), not signed yet (SmartScreen: More info → Run anyway) |
| Linux | [CozySafe-linux-x64.tar.gz](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-linux-x64.tar.gz), needs GTK 3 and libsecret |
| Android | [CozySafe-android.apk](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-android.apk), or Google Play testing (internal and Alpha) |
| iPhone | TestFlight (invite only for now) |

Every file has a GitHub build-provenance attestation:
`gh attestation verify <file> -R cozy-pi/cozysafe`.

## How your data is protected

- **Two kinds of key.** Every day: PIN or Face ID, on this device only. On a new or
  lost device: the **Recovery Key** plus the **vault password**, both needed.
- **The Recovery Key** is a 256-bit secret made on your device, shown as 24 BIP39
  words like a hardware wallet's, and kept in its keystore (Keychain, Android Keystore,
  Windows credential store, libsecret). Someone with your backup file but not the
  Recovery Key cannot even start guessing your password. (Libraries made before
  21 October 2026 have a 128-bit key in the earlier `CS1-` form; it still works.)
  How this compares with a Bitcoin wallet, and why it resists quantum computers:
  [security](docs/security.md#how-strong-is-it-compared-with-a-bitcoin-wallet).
  It comes from the system's random generator, never from anything the app seeds; tests
  pin the official BIP39 word list (by checksum) and its reference vectors.
- **Argon2id** stretches the password (128 MiB on phones, 512 MiB on computers);
  **XChaCha20-Poly1305** encrypts everything, file content in 64 KiB chunks so
  multi-gigabyte files need little memory. Each item has its own random key.
- **Face ID, fingerprint and PIN** only unwrap a copy of the vault key held for this
  device. The PIN is combined with a random key in the device keystore, so vault
  files copied elsewhere can't be brute-forced with the PIN. From the fifth wrong PIN
  you wait longer each time (1, 5, 15, then 60 minutes); nothing is wiped.
- **No recovery.** Lose the vault password, or both the device and the Recovery Key, and
  the data is gone. Nobody, including us, can open it.

Details: [ADR 0001: encryption](docs/adr/0001-encryption.md).

## Build from source

```sh
# Rust core: tests run anywhere
cargo test

# App: Flutter 3.47.7 and flutter_rust_bridge_codegen 2.13.0
cd app
flutter pub get
flutter_rust_bridge_codegen generate   # Dart bindings (not committed)
flutter gen-l10n                       # translations (not committed)
flutter run
```

Releases are one button: `gh workflow run release.yml -R cozy-pi/cozysafe` picks
the next version name (0.1.0, 0.1.1, …; `-f bump=minor` for 0.2.0) and publishes it
everywhere at once: TestFlight, Google Play (internal and Alpha), and a GitHub release
with the desktop builds and the APK. Each platform ships as soon as its build is done;
signing and store keys never reach the build jobs ([supply chain](docs/supply-chain.md)).
Write the changes under that version in [CHANGELOG.md](CHANGELOG.md) first.

UI changes start as a mockup made from the app itself: `app/tool/mockup.sh` renders every
screen in dark and light inside an iPhone frame, with the changed parts outlined
([UI](docs/ui.md), mockups). Nothing ships before the mockup is approved.

## Repository

| Path | What |
|---|---|
| `core/cs-crypto` | Key derivation, key wrapping, streaming encryption, Recovery Key words (BIP39) |
| `core/cs-vault` | Library and vaults on disk: items, biometric and PIN copies, backup |
| `core/cs-photo` | Camera frames to JPEG in memory (no temp files, no EXIF) |
| `app/` | Flutter app; `app/rust` is the bridge crate |
| `website/` | safe.cozypi.com (Cloudflare Worker) |
| `docs/` | Requirements, plan, UI decisions, decision records |

## Documents

| Document | Contents |
|---|---|
| [Requirements](docs/requirements.md) | What Cozy Safe must do, and why |
| [Plan for v0.1](docs/plan-v0.1.md) | Stages and progress |
| [Decisions](docs/decisions.md) | What was decided, when, and what is still open |
| [Supply chain](docs/supply-chain.md) | How no library can send data out, and the limits |
| [Dependencies](docs/dependencies.md) | Every third-party package, grouped by risk, and what changed since the last review |
| [Security rules](docs/security.md) | Owner check on security settings; secrets and note text hidden on screen |
| [UI](docs/ui.md) | Design language (sizes, colours, layout), approved designs, how mockups are made |
| [Naming](docs/naming.md) | One name per concept; how stored names may change |
| [Decision records](docs/adr/) | Why each technical choice was made |
| [Changelog](CHANGELOG.md) | What changed in each build |

## License

[GPL-3.0-only](LICENSE).

A project of [Cozy Pi](https://cozypi.com).
