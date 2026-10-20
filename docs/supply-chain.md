# Supply chain: no library may send data out

Cozy Safe works fully offline. Nothing in the app needs the network, so the goal is
simple to state: **no third-party library (Dart package, Flutter plugin, Rust crate)
can send data out of the device**, whether by accident, through a feature we do not
use, or on purpose after a compromised update.

No single check can promise that. Several layers, each catching what another misses:

| Layer | Where | What it stops |
|---|---|---|
| OS: Android | `app/android/app/src/main/AndroidManifest.xml`, CI `build.yml` | The release APK has no `INTERNET` permission, so Android refuses sockets to the whole app process, native code included |
| OS: macOS | `app/macos/Runner/Release.entitlements`, `tools/check-entitlements` | App Sandbox on, no `network.client` / `network.server`: macOS refuses every socket |
| Compiled Rust | `tools/check-rust-symbols` (CI `ci.yml` on Linux, `build.yml` on the APK's library) | The linked Rust library imports no socket or name-lookup function |
| cackle | `app/rust/cackle.toml`, CI `ci.yml` | No crate uses the `net` API (std::net, Unix sockets, libc socket calls, tokio::net) |
| cargo-deny | `deny.toml`, CI `ci.yml` | Known-vulnerable or yanked crates, any source but crates.io, known networking crates |
| Dart runtime guard | `app/lib/offline.dart` (installed first thing in `main`) | `HttpClient()` throws; `Socket.connect`, `Socket.startConnect`, `ServerSocket.bind` fail |
| Allowlists | `tools/check-deps`, `tools/allow/*.txt` | Any new Dart package or Rust crate, direct or transitive, until someone reviews it |
| Source scan | `tools/check-deps`, `tools/allow/network-ok.txt` | Network APIs in the Dart, Kotlin/Java, Swift/Objective-C and C/C++ sources of every pub package that ships |

## The layers

**Android.** The main manifest declares
`<uses-permission android:name="android.permission.INTERNET" tools:node="remove"/>`.
The manifest merger then drops INTERNET even when a plugin's own manifest asks for
it. The debug and profile manifests keep it: `flutter run` talks to the app over a
socket. CI dumps the permissions of the built APK (`aapt2 dump permissions`) and of
the Play bundle, and fails if INTERNET is there.

**macOS.** The release build runs in the App Sandbox with no network entitlement.
`tools/check-entitlements` fails if the sandbox is turned off, if any
`com.apple.security.network.*` key appears, or if a sandbox temporary exception
is added. It runs in CI on every push and before the release is signed.
`DebugProfile.entitlements` keeps `network.server` for the debugger.

**Compiled Rust.** `tools/check-rust-symbols` reads the undefined (imported) symbols
of the built `librust_lib_cozysafe` shared library and fails on `socket`, `connect`,
`bind`, `listen`, `accept`, `send*`, `recv*`, `getaddrinfo` and similar. It checks
the linked library, not the static archive: the linker keeps only reachable code,
so an import there means something really calls it. No symbol needs allowing today.

**cackle** (`cargo acl`) builds the app's Rust library and attributes every API use
to the crate it comes from. The policy forbids the `net` API to every crate; the
config records which crates may use `unsafe`, the file system, or start processes
(build scripts). Linux only. The CI job is marked `continue-on-error` until it has
run green once (the config was written from a source scan, not from a cackle run);
when it fails it uploads the config cackle suggests, and still fails outright if
that config would hand `net` to any crate.

**cargo-deny** checks both lockfiles (the core workspace and `app/rust`) against the
RustSec advisory database, accepts crates only from crates.io, and bans well-known
HTTP, TLS and socket crates.

**Dart runtime guard.** `installNetworkGuard()` sets `HttpOverrides.global` and
`IOOverrides.global` before anything else runs, so Dart code (including
`package:http` and image loading from URLs) cannot open a connection. It is skipped
on the web, where the browser preview (`lib/preview_main.dart`, not part of the
app) loads sample photos over HTTP. `package:http` is a dev dependency of the app
for that preview only.

**Allowlists and source scan.** `tools/check-deps` compares every package name in
`app/pubspec.lock`, `Cargo.lock` and `app/rust/Cargo.lock` with
`tools/allow/dart.txt` and `tools/allow/rust.txt`; a new package fails CI until it
is reviewed and added. Dart packages must come from pub.dev. It then scans the
sources of every pub package in the app's dependency graph (dev dependencies
excluded), native `android/`, `ios/`, `macos/`, `linux/` and `windows/` code
included, for network APIs. A package with hits must be listed in
`tools/allow/network-ok.txt` with the reason it is acceptable (web-only code, a
feature the app does not call, build-time only).

## Limits

- **iOS, Windows and Linux have no OS switch** that takes the network away from one
  app. There the protection is the Dart guard, the compiled-binary check, cackle
  and the source scan; none of them stops native code that is determined to connect.
- **The source scan reads text.** A deliberately malicious plugin can reach the
  network without any of the scanned names: FFI into a system library, reflection,
  string-built class names, or a binary it downloads. The allowlist (every new
  package is reviewed) and the OS layers are the answer to that, not the scan.
- **Prebuilt native binaries are not inspected.** PDFium (`pdfrx`) is downloaded
  as a binary at build time: `pdfium_dart`'s build hook fetches it from GitHub over
  HTTPS with no checksum (Android, Linux, Windows); `pdfium_flutter`'s Apple
  package pins a SHA-256. The Flutter engine and the Dart VM contain socket code of their own (that
  is what the Dart guard and the OS layers are for).
- **The Dart guard covers `dart:io` only.** `RawSocket` and `RawDatagramSocket` have
  no override hook; the source scan looks for them instead.
- **Build time is not covered.** Build scripts, proc macros, Gradle and CocoaPods
  run with network access, as in any build. cackle checks what Rust build scripts
  use but does not sandbox them.
- **Sync (planned for v0.2: cloud folder, LAN peer-to-peer)** will need the
  network for a narrow, reviewed part of the app. These layers then have to be
  relaxed deliberately for that code only, not removed.
