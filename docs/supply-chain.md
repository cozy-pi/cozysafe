# Supply chain: no library may send data out

Cozy Safe uses no server. The only network use is syncing with the person's other device
on the same Wi‑Fi, started and allowed by hand each time, all of it in one crate
(`core/cs-net`, decisions 2026-10-24). The goal: **no third-party library (Dart package,
Flutter plugin, Rust crate) can send data out of the device**, whether by accident,
through a feature we do not use, or on purpose after a compromised update; and our own
network code can only reach a local address the person allowed.

No single check can promise that. Several layers, each catching what another misses:

| Layer | Where | What it stops |
|---|---|---|
| OS: Android | `app/android/app/src/main/AndroidManifest.xml`, CI `build.yml` | Only `INTERNET` (any socket needs it, even a local one); no network-state, Wi‑Fi or nearby-device permission |
| OS: macOS | `app/macos/Runner/Release.entitlements`, `tools/check-entitlements` | App Sandbox on; of the network entitlements only `network.client` / `network.server` (sync) |
| Compiled Rust | `tools/check-rust-symbols` (CI `ci.yml` on Linux, `build.yml` on the APK's library) | The linked Rust library imports only the socket calls cs-net needs, and `getaddrinfo` (Google's two fixed hosts); no reverse or legacy lookups |
| cackle | `app/rust/cackle.toml`, CI `ci.yml` | No crate but `cs-net` uses the `net` API (std::net, Unix sockets, libc socket calls, tokio::net) |
| cargo-deny | `deny.toml`, CI `ci.yml` | Known-vulnerable or yanked crates, any source but crates.io, known networking crates |
| Dart runtime guard | `app/lib/offline.dart` (installed first thing in `main`) | `HttpClient()` throws; `Socket.connect`, `Socket.startConnect`, `ServerSocket.bind` fail |
| Allowlists | `tools/check-deps`, `tools/allow/*.txt` | Any new Dart package or Rust crate, direct or transitive, until someone reviews it |
| Source scan | `tools/check-deps`, `tools/allow/network-ok.txt` | Network APIs in the Dart, Kotlin/Java, Swift/Objective-C and C/C++ sources of every pub package that ships |
| cargo-vet | `supply-chain/`, `app/rust/supply-chain/`, CI `ci.yml` | A new or updated crate nobody has read: each version must be audited (by us or an imported auditor) or exempted |
| Age | `tools/check-age`, `tools/allow/young.txt`, CI `security.yml` | Any version published less than 14 days ago (most hijacked releases are pulled within days) |
| Dependency page | `tools/deps-report`, [dependencies.md](dependencies.md), CI `ci.yml`, `security.yml`, `deps-review.yml` | A package nobody looks at again: every package listed by risk, a monthly review of what changed, and a weekly check that no package changed owners |

## Top secret means top secret (owner 2026-10-30, absolute)

The core of a Top secret vault depends on **independently audited cryptography and
SQLite, and nothing else**. No other crate, however small or popular, is allowed on its
path: what it needs beyond those is written here, in our own code.

- **Allowed:** the RustCrypto crates, the small crates they are made of, and SQLite
  (`rusqlite`, built from the bundled source). The cryptography is all Rust: no C
  cryptography library (owner 2026-10-31, for memory safety). SQLite is the only C.
- **Not allowed:** everything else. The vault core, `core/cs-core` (the library, the
  vaults, their items, PINs, version history and index), is built without `serde`,
  `serde_json`, `hex`, `thiserror` and `zxcvbn`, which it used before: its own small
  JSON (byte for byte what serde wrote, `tests/format_serde.rs`), its own errors, its own
  hex, its own password check (length plus a list of common passwords). `cs-vault`
  (sync, backups, joining) still uses `serde` for the sync journal, until sync per kind
  (ADR 0005, step 5).
- **"Audited" means one of two things, with the evidence kept here** (owner
  2026-10-31):
  1. a public, independent audit report, linked below; or
  2. our own review: every line of the copy kept in the repo read, recorded in the
     cargo-vet audits (who, which version, when), and the standard test vectors passing
     in every test run, plus a one-off cross-check against libsodium done outside the
     repo (same input, same output; only the result is kept).

  | Crate | Evidence |
  |---|---|
  | `chacha20poly1305` (and `chacha20`, `poly1305`) | NCC Group, 2020: [report](https://web.archive.org/web/20200606025324/https://research.nccgroup.com/2020/02/26/public-report-rustcrypto-aes-gcm-and-chacha20poly1305-implementation-review/) (no significant findings) |
  | `argon2`, `blake2` | RFC 9106 vectors pass; own review recorded in `supply-chain/audits.toml` (2026-10-31) |
  | `sha2` (and `digest`, `block-buffer`, `cpufeatures`) | NIST FIPS 180-4 examples pass; own review, plus a differential test of every length 0-599 against OpenSSL |
  | `hmac` (and `ctutils`, `cmov`, `hybrid-array`, `crypto-common`) | RFC 4231 vectors pass; own review |
  | `hkdf` | RFC 5869 vectors pass; own review |
  | `zeroize` | cargo-vet audits imported from Mozilla and Bytecode Alliance |
  | `subtle` | cargo-vet audits imported from Mozilla and ISRG |
  | `rusqlite`, `libsqlite3-sys` (SQLite) | own review of the Rust layer; SQLite's own test suite (to do) |

  The reviews were machine-assisted (every `src/` file read, each `unsafe` block
  checked for soundness, the algorithm compared with its standard); their notes, with
  what was not read, are in the audits file. What they found and what was done:
  `argon2` frees its working memory (up to 512 MiB derived from the password) without
  wiping it, so `cs-crypto` hands it memory of its own and wipes it (about 20 ms);
  `hmac`/`hkdf` keep no wiped copy of the key (the keys they see are derived, short-lived
  and held only during unlock); `sha2`'s SHA-512 detection on Android ARM accepts the
  SHA3 flag alone (no known phone has one without the other).

  The vectors are in `core/cs-crypto/tests/vectors.rs` and run with every `cargo test`
  (RFC 8439 and the XChaCha draft cover the cipher as well). The SHA-2, HMAC and HKDF
  values were also checked against OpenSSL before they were written in.

- **Nothing fetched from the internet at build time** (owner 2026-10-31): the Top secret
  core builds offline from source copied into the repo (`third_party/`), each copy kept
  exactly as published with its upstream checksum or signature, so it can be checked
  again at any time. A change we need goes in a separate patch file, never into the
  copy. Only the compilers (Rust, Xcode, the Android NDK) come from outside, pinned by
  version. How: the copies are wired in with `[patch.crates-io]` (`Cargo.toml`,
  `app/rust/Cargo.toml`), so the app is built from them too; CI builds
  `tools/core-offline` from an empty cargo home and fails if a single crate is downloaded
  (cargo still reads the crates.io index, the list of versions, but no source). Two
  copies are never compiled (`password-hash`, `phc`): cargo downloads a weak optional
  dependency of `argon2` even when it stays off, so they are kept to download nothing.
  The core no longer takes `rayon` (Argon2 runs its lanes one after another; a computer
  unlocks in about 0.9 s instead of 0.3 s, same key) nor any derive macro.
- **Checked on every build:** `tools/check-vendor` recomputes the sha256 of every file in
  `third_party/rust/` and compares it with the published crate's list
  (`.cargo-checksum.json`) and `third_party/rust/RECORD`; one changed byte, an added or
  missing file, a crate reaching the core that is not a copy, or a copy no longer used
  stops the build and names it. cargo-vet treats the copies as crates.io crates
  (`audit-as-crates-io`).
- **Upstream watched every week and before each release** (a separate CI job, since the
  build itself is offline): `tools/vendor-watch` compares every copy with crates.io (same
  sha256, not yanked, newer versions) and RustSec (an advisory on our version) and gives
  one recommendation per crate: 🔴 update now (fails security.yml, so the release
  waits), 🟡 should update, ⚪ no need. `vendor-watch.yml` keeps one open issue with the
  latest report every Monday.
  Updating is always done by hand: fetch, check the signature, read the diff, record
  the review.
- **Kept that way by CI:** a check fails the build when any crate outside this list
  reaches the Top secret core (`cargo tree -e normal`), direct or transitive. Adding one
  needs the owner's approval and a line here first.
- The app around it (Flutter) is held to the same idea: a Top secret vault decodes no
  picture, video or PDF. It keeps text, files and photos taken with the app's own camera
  (no import from the photo library); files and photos are sealed as they are, with no
  preview and no thumbnail (a name, a size, a plain icon). To open one, it is exported
  (written out decrypted for another app) after a warning that it then leaves the vault.

## The layers

**Android.** The main manifest declares INTERNET: Android needs it for any socket, even
one to a device on the same Wi‑Fi, and it cannot be limited to the local network. CI
dumps the permissions of the built APK (`aapt2 dump permissions`) and of the Play bundle,
and fails if a network permission beyond it appears (network or Wi‑Fi state, changing
them, multicast, nearby devices). The protection against a library using INTERNET is
the other layers. The other permissions in the manifest give no network access:
USE_BIOMETRIC, RECORD_AUDIO, and FOREGROUND_SERVICE, FOREGROUND_SERVICE_DATA_SYNC and
POST_NOTIFICATIONS, which keep a running sync alive with the phone locked (a dataSync
foreground service, `SyncService.kt`, showing its progress in a quiet notification, only
while a sync runs).

**macOS.** The release build runs in the App Sandbox with `network.client` and
`network.server` (sync: one device listens, the other connects). `tools/check-entitlements`
fails if the sandbox is turned off, if any other `com.apple.security.network.*` key
appears, or if a sandbox temporary exception is added. It runs in CI on every push and before the release is signed.
`DebugProfile.entitlements` has the same two, so debug builds can reach Google Drive and
listen on 127.0.0.1 for the Google sign-in on computers.

**Compiled Rust.** `tools/check-rust-symbols` reads the undefined (imported) symbols
of the built `librust_lib_cozysafe` shared library and fails on name lookups
(`getaddrinfo`, `getnameinfo`, `gethostbyname` and similar). The plain socket calls
(`socket`, `connect`, `bind`, `listen`, `accept`, `send*`, `recv*`) are allowed for
cs-net, which works with IP addresses only: without a name lookup nothing in the Rust
core can reach a host on the internet by name. It checks the linked library, not the
static archive: the linker keeps only reachable code, so an import there means
something really calls it.

**cackle** (`cargo acl`) builds the app's Rust library and attributes every API use
to the crate it comes from. The policy forbids the `net` API to every crate but
`cs-net`; the
config records which crates may use `unsafe`, the file system, or start processes
(build scripts). Linux only. The CI job blocks; when it fails it uploads the config
cackle suggests, and still fails outright if that config would hand `net` to another crate.
The core crates (`cs-core`, `cs-vault`, `cs-crypto`, `cs-photo`) also carry
`#![forbid(unsafe_code)]`: the compiler refuses unsafe Rust there.

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

**cargo-vet** checks every crate version in both workspaces against audits: our own
(`supply-chain/audits.toml`), and those of Google, Mozilla, the Bytecode Alliance,
ISRG, Zcash and Embark (imported, `imports.lock`). The crates already in use on
2026-10-28 are exempted at those versions. A new crate, or a new version of one, fails
CI until someone reads it and certifies it: `tools/sandbox/run --net --rw supply-chain
cargo vet` suggests what to read, `cargo vet diff` shows the change from a version
already trusted, `cargo vet certify` records it (the same in `app/rust`, with
`--rw app/rust/supply-chain -C app/rust`). It covers Rust only; nothing like it exists
for pub.dev.

**Dependency page.** `tools/deps-report` writes [dependencies.md](dependencies.md) from
the lock files: every Rust crate, Dart package and Swift package (and the Gradle groups),
in four tiers: (1) code that parses data from outside (files the person adds, camera
frames, Drive and sync data; listed by hand in `tools/deps/outside-data.txt`), (2) other
native code, (3) other code that ships, (4) build and test only. Each row shows the
release date, how it comes in, its owners (crates.io) or publisher (pub.dev), its cackle
grants and network-ok reason. Data from crates.io, pub.dev and the Flutter repository is
fetched only by `--refresh` and kept in `tools/deps/meta.json`, so CI rebuilds the page
offline and fails when it is out of date with a lock file. The weekly security run
fetches every owner again and fails on any change (a new maintainer is how the xz
backdoor began). On the 1st of each month `deps-review.yml` opens an issue: what changed
since the last review (`tools/deps/baseline.json`), and tiers 1 and 2 to look at again;
`tools/deps-report --mark-reviewed` closes the round. pub.dev does not publish who can
upload a package without a verified publisher, so for those only a new publisher shows.

## Bundled data

**Common passwords** (2026-10-25), for the new-password check (docs/security.md,
passwords). Source: SecLists,
`Passwords/Common-Credentials/xato-net-10-million-passwords-100000.txt` at commit
`c205c36a445bff37f8e58a9ec829105cd4975c58`; the downloaded file's SHA-256 is
`1472aafa2561df5e3293aee252aee3ca660c12b399a283cf808bb01b39be388b`. The list is not
kept as text: `core/cs-core/data/common-passwords.bin` is a sorted table of the first
4 bytes of the SHA-256 of each normalised entry, built by the ignored test
`make_blocklist` in `core/cs-core` from that file at that commit (its SHA-256 checked
first). The app ships only the table.

Attribution: SecLists is MIT licensed, Copyright (c) 2018 Daniel Miessler (the MIT
notice is in the SecLists repository, `LICENSE`). The underlying list is Mark
Burnett's "10 million passwords" set, which he released into the public domain.

## Builds on a person's computer

Flutter, Gradle, CocoaPods and Xcode builds run only on CI. Rust is built and tested
locally too, and a crate's build script or proc macro runs with every right of whoever
builds: it could read SSH keys, tokens or other projects. `tools/sandbox/run` runs
cargo in a Docker container (`tools/sandbox/Dockerfile`: the official Rust image at the
pinned toolchain, by digest) that sees only this repository, read-only and without
`.git`, as an unprivileged user, with no network unless `--net` is given:

    tools/sandbox/run --net cargo fetch --locked            # downloads only, no package code runs
    tools/sandbox/run cargo test --locked                   # offline
    tools/sandbox/run cargo clippy --locked --all-targets -- -D warnings

The app's own crate (`app/rust`) needs the bindings `flutter_rust_bridge_codegen`
generates, which needs Flutter, so it builds on CI only. Downloaded crates and build output stay in two Docker volumes (`cozysafe-cargo`,
`cozysafe-target`). Formatting (`cargo fmt`) runs no package code and writes files, so
it runs outside.

## Signing and store keys stay out of build jobs

The machines that build the apps run thousands of lines of other people's code (Gradle,
Flutter plugins, CocoaPods, package build scripts) with network access. A hijacked package
there could read any key in the same job. So keys live in jobs that run only the
platforms' own tools, and each platform still ships as soon as it is ready:

| Platform | Build job (no keys) | Key jobs |
|---|---|---|
| Android | `android`: built with the debug key | `android-sign` (release key; `apksigner`, `jarsigner`, checks the signer is Cozy Pi) → `play` (Play key) |
| macOS | `macos`: built ad-hoc signed | `macos-sign` (Developer ID; `codesign`, `hdiutil`) → `macos-notarize` (App Store Connect key; `notarytool`, `stapler`) |
| iOS | `ios` (testflight.yml): distribution certificate, needed by Xcode to export | `upload` (App Store Connect key; `altool`) |

Build jobs only read the repository; attestations and the GitHub release come from the
`release` job. The iOS distribution certificate stays in its build job: re-signing an iOS
app outside the export is fragile, the certificate can be revoked, and without the App
Store Connect key nothing can be uploaded with it. Run by hand, `testflight.yml` can
validate a build with Apple instead of uploading it (`upload: false`).

## Limits

- **No OS can hold an app to the local network.** With sync, Android has the INTERNET
  permission and macOS the network entitlements, like iOS, Windows and Linux always
  could. The protection is the Dart guard, the compiled-binary check, cackle and the
  source scan; none of them stops native code that is determined to connect.
- **The source scan reads text.** A deliberately malicious plugin can reach the
  network without any of the scanned names: FFI into a system library, reflection,
  string-built class names, or a binary it downloads. The allowlist (every new
  package is reviewed) and the OS layers are the answer to that, not the scan.
- **Prebuilt native binaries are not inspected.** PDFium (`pdfrx`) is downloaded
  as a binary at build time from GitHub over HTTPS. It is pinned, not inspected: our
  copy of `pdfium_dart`'s build hook (`third_party/pdfium_dart/hook/build.dart`, used
  through `dependency_overrides`) holds the SHA-256 of every archive of release
  chromium/7811 and refuses a download that differs or has no pinned value;
  `pdfium_flutter`'s Apple package pins a SHA-256 too. The Flutter engine and the Dart VM contain socket code of their own (that
  is what the Dart guard and the OS layers are for).
- **The Dart guard covers `dart:io` only.** `RawSocket` and `RawDatagramSocket` have
  no override hook; the source scan looks for them instead.
- **Build time is not covered.** Build scripts, proc macros, Gradle and CocoaPods
  run with network access, as in any build. cackle checks what Rust build scripts
  use but does not sandbox them.
- **One known advisory is ignored, at build time only.** GHSA-qwgh-2vcv-g2f7 in
  block-buffer 0.10.4 reaches only `flutter_rust_bridge_macros` (md-5, a proc macro),
  never the app; our crates use the fixed 0.12.1. `app/rust/osv-scanner.toml` ignores it
  until 2027-01-31, with the reason; drop it once flutter_rust_bridge moves to digest 0.11.
- **Google Drive sync** (cs-net `drive.rs` on `https.rs`): HTTPS to one host,
  `www.googleapis.com`, a constant; with the sign-in on computers (cs-net `oauth.rs`:
  token exchange, refresh, revoke) also `oauth2.googleapis.com`, a constant too. These
  two are the only names the app ever looks up, so the compiled-library check allows
  `getaddrinfo`. The sign-in's loopback listener (127.0.0.1 only) is in `oauth.rs` too;
  Dart opens the browser and parses Google's answers but opens no connection itself,
  so the Dart guard stays as it is. TLS is rustls with ring and Mozilla's roots
  bundled (6 crates; a ready-made HTTP client pulled in 44, so the few HTTP/1.1 requests
  are written in cs-net, with tests for chunked bodies and size caps). Up to four
  connections are kept and reused (HTTP/1.1 keep-alive), one per item a sync sends at
  once, each while the server allows it and it has been idle under 50 s; past four the
  oldest is closed. A request that finds its kept connection closed is sent once more on
  a new one only if its body is in memory. An upload URL Drive hands back must be on the
  same host. Deleted items leave Drive through Google's batch endpoint
  (`POST /batch/drive/v3`, same host, up to 100 `DELETE`s in one `multipart/mixed`
  request): the answer is capped at 1 MiB and read strictly (its boundary checked, every
  part answered once with 204 or 404, or the batch fails). Each vault has its own folder
  inside "Cozy Safe", its files in up to 256 small folders: listed in one paged query
  (`trashed = false`, only the app's own files under `drive.file`), folders made one
  request each when first needed, ids checked to letters, digits, `-` and `_` before they
  go into a query, a path or a batch part. Files of earlier versions are moved into place
  by renaming (`PATCH /drive/v3/files/<id>` with `addParents`/`removeParents`, through the
  same batch endpoint, each part answered with 200 or 404), never sent again. Sign-in is Google's own plugin (`google_sign_in`,
  published by the Flutter team) and its native SDKs, which talk to Google's sign-in
  servers themselves: that part is reviewed, not sandboxed.
