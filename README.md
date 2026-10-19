# Cozy Safe

An open-source, cross-platform encrypted vault for photos, documents, files and
notes. Everything is encrypted on your device before it is saved.

> **Status: preview.** It works on one device; sync between devices is not built
> yet. Don't keep your only copy of something important in it until v0.1, and use
> **Back up to a file** often. Progress: [`docs/plan-v0.1.md`](docs/plan-v0.1.md).

Website and downloads: <https://safe.cozypi.com>

## What works today

- Several vaults, each opened by its own password (the password decides which vault opens).
- Unlock with Face ID or fingerprint (on by default for the first vault), a PIN of
  4 to 10 digits for this device, or the password. Typing the right password opens
  the vault without pressing Enter.
- Take photos inside the app on iPhone and Android. They go straight into the vault:
  never the photo library, never a plaintext temporary file, no location data.
- Browse photos by date, view them full screen, delete them.
- Emergency Kit: your Secret Key, written so you can copy it on paper.
- Back up the whole library to one encrypted file and restore it on a new install.
- English and Vietnamese, light and dark.

Coming for v0.1: folders, photos from the library, any file, notes, paste, recently
deleted, search, change password. See [the plan](docs/plan-v0.1.md).

## Install

| Platform | How |
|---|---|
| macOS | [CozySafe-macos.dmg](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-macos.dmg), signed and notarized |
| Windows | [CozySafe-windows-x64.zip](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-windows-x64.zip), not signed yet (SmartScreen: More info → Run anyway) |
| Linux | [CozySafe-linux-x64.tar.gz](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-linux-x64.tar.gz), needs GTK 3 and libsecret |
| Android | [CozySafe-android.apk](https://github.com/cozy-pi/cozysafe/releases/latest/download/CozySafe-android.apk), or the Google Play closed test |
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
  files copied elsewhere can't be brute-forced with the PIN. Five wrong PINs and
  the PIN is turned off.
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
everywhere at once: TestFlight, the Google Play closed test, and a GitHub release
with the desktop builds and the APK. Write the changes under that version in
[CHANGELOG.md](CHANGELOG.md) first.

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
| [UI](docs/ui.md) | Approved designs: lock screen, add dock, folders |
| [Decision records](docs/adr/) | Why each technical choice was made |
| [Changelog](CHANGELOG.md) | What changed in each build |

## License

[GPL-3.0-only](LICENSE).

A project of [Cozy Pi](https://cozypi.com).
