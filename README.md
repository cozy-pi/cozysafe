# Cozy Safe

An open-source, cross-platform encrypted vault for photos, documents, files and
notes. Everything is encrypted on your device before it is saved.

> **Status: preview.** It works on one device; sync between devices is not built
> yet. Don't keep your only copy of something important in it yet, and use
> **Back up to a file** often. Decisions and what is next: [`docs/decisions.md`](docs/decisions.md).

Website and downloads: <https://safe.cozypi.com>

## No library can send your data out

Cozy Safe works fully offline and does not need the network for anything. A vault app
is only as safe as every library inside it, and libraries do get hijacked, so this is
checked on every build, in layers (details and limits: [supply chain](docs/supply-chain.md)):

- **Android:** the app has no internet permission at all; CI reads the built APK and
  fails if one sneaks back in. Android then refuses every connection, native code included.
- **macOS:** the app runs in Apple's sandbox with no network permission.
- **Inside the app:** Dart's HTTP client and sockets are switched off when the app
  starts, and the compiled Rust core must not import any network function.
- **Every library is reviewed before it gets in.** CI keeps a list of every Dart and Rust
  package, direct or indirect; a new one fails the build until someone reviews it. The
  sources of every package are scanned for network code, and each exception is written
  down with its reason. Rust crates are also checked by cackle and cargo-deny.
- **Honest limits:** iPhone, Windows and Linux have no system switch that takes the
  network away from one app, so there the protection is the checks above, not the OS.
  The PDF engine (PDFium) is a prebuilt binary downloaded at build time.

## What works today

- **Several vaults on one device**, each with its own PIN. A vault is told apart by its
  icon and colour; nothing on disk says what is inside or how it is used.
- Unlock with Face ID or fingerprint, the vault's PIN, or its password. Wrong PINs
  make you wait longer each time.
- **Photos and videos:** take them inside the app (never in the photo library, no
  location data) or add them from the device. **Notes**, **voice memos** and **any
  file**, with a PDF viewer inside the app.
- **Groups:** put anything in one or more groups ("Passport": the photo, the scan and the
  note) and open a group from any section.
- Search, Recently deleted (30 days), auto-lock, blocked screenshots.
- **Private on screen:** note lists and search show titles only, the Secret Key and
  passwords stay masked until you tap Show, and every security setting asks for Face ID,
  fingerprint or the phone's passcode first ([security rules](docs/security.md)).
- **Simple to start:** an empty vault offers big tiles to add the first thing; only the
  sections you use appear at the bottom; buttons are large enough for any thumb.
- **Back up to one encrypted file** and restore it on a new device with the Emergency
  Kit (your Secret Key on paper).
- English and Vietnamese, light and dark.

Not yet: sync between devices. Until then, use **Back up to a file** often.

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

- **Two secrets open a vault:** your password and a 128-bit **Secret Key** made on
  your device and kept in its keystore (Keychain, Android Keystore, Windows
  credential store, libsecret). Someone with your backup file but not your Secret
  Key cannot even start guessing your password.
- **Argon2id** stretches the password (128 MiB on phones, 512 MiB on computers);
  **XChaCha20-Poly1305** encrypts everything, file content in 64 KiB chunks so
  multi-gigabyte files need little memory. Each item has its own random key.
- **Face ID, fingerprint and PIN** only unwrap a copy of the vault key held for this
  device. The PIN is combined with a random key in the device keystore, so vault
  files copied elsewhere can't be brute-forced with the PIN. From the fifth wrong PIN
  you wait longer each time (1, 5, 15, then 60 minutes); nothing is wiped.
- **No recovery.** Lose the password, or both the device and the Emergency Kit, and
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
| `core/cs-crypto` | Key derivation, key wrapping, streaming encryption, Secret Key text form |
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
| [Security rules](docs/security.md) | Owner check on security settings; secrets and note text hidden on screen |
| [UI](docs/ui.md) | Design language (sizes, colours, layout), approved designs, how mockups are made |
| [Naming](docs/naming.md) | One name per concept; how stored names may change |
| [Decision records](docs/adr/) | Why each technical choice was made |
| [Changelog](CHANGELOG.md) | What changed in each build |

## License

[GPL-3.0-only](LICENSE).

A project of [Cozy Pi](https://cozypi.com).
