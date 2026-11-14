# Backlog

Things found and judged not urgent, kept here so they are not lost (owner 2026-11-06:
"fix what matters, note the rest for later"). Each line says where it came from. Move a
line out when it is done or decided against.

## Data model

- **Merge secure items field by field.** Sync merges a whole item: two devices editing
  different fields of one login keep two logins (a conflict copy). A per-field merge of
  the JSON document would keep one. (Review of the data model, 2026-11-06.)
- **Version history is local only**: not synced, not in backups. A lost device loses
  earlier passwords. (ADR 0009.)
- **Large files re-upload whole** after any change; no block-level sync.
- **Links between items** go through groups only; a direct relation (a login and its ID
  scan) would need a record field (now safe to add: unknown fields are kept since 0.2.29).
- **Very large vaults** (100 000+ items): every list opens every record; page the list.
- **Record-level "needs version"**: a record a newer version marks as unsafe for older
  ones to edit (today only the whole place can be raised with the sync level).

## Security and cryptography

- **TLS to Google is classical** (rustls with `ring`); the hybrid X25519MLKEM768 group
  needs the `aws-lc-rs` provider. Only sealed content and OAuth tokens cross it.
  (docs/security.md, post-quantum table.)
- **ADR 0001 is out of date**: share inbox never built, password rule, Argon2 lanes,
  key sync. data-model.md and cryptography.md follow the code; refresh the ADR or mark
  its sections superseded. (Docs review, 2026-11-06.)
- **Retired PIN path**: Dart can make a 16-byte device key that Rust no longer accepts;
  only preview_main.dart reaches it. Remove or fix. (Docs review, 2026-11-06.)
- **Connection log AAD** is the bare string `connection-log`, without the vault prefix
  every other blob has. Harmless (sealed with the vault's key), but out of pattern.

From the review of 2026-11-14 (what mattered was fixed then, decisions.md; these were
judged low):

- **The count of wrong passwords is the app's**, in the keystore: the core's `unlock`
  has no throttle of its own, and the counters fail open when the keystore cannot be
  read (`catch (_) {}` in `PinStore`). On a phone under full control it can be reset.
  Moving the count into the core would not change that (same disk), a hardware counter
  would.
- **Typing on from a wrong password is free**: the lock screen does not count a miss
  while the next text starts with it, so one chain of growing guesses costs nothing.
  Narrow (each guess must extend the last), kept so a long password typed slowly does
  not lock its owner out.
- **`set_password` leaves `prev_wrapped_master_key`** when a Recovery Key change was cut
  short between `rewrap` and `accept_key`: the old password and words keep opening that
  device's copy. Clear or re-wrap it in `set_password` (`cs-core/src/vault.rs`).
- **Local reads do not check `data_hash`**: only a sync download does. The item key and
  AAD are the same across edits, so a tampered backup can pair a new record with older
  content of the same item. Check on restore, or put `data_rev` in the content's AAD (a
  format change: data-model.md, cryptography.md).
- **The JSON reader's duplicate-key check is quadratic** (`cs-core/src/json.rs`), on
  input up to 16 MiB not yet authenticated (`library.json` from a backup): a crafted
  file hangs the app. A set, or a cap on keys per object.
- **`join` writes back `format` fields unchecked** from the lock: a hostile place can
  make a join succeed and the library unreadable at the next start. Check them as
  `open` does. `join_any` runs one Argon2id per vault folder the place lists.
- **Sync downloads are not capped by the record's size**: a blob of any length is
  written to disk before its hash is checked (`fetch_blobs`, `fetch_ahead`).
- **Nearby sync**: the hello's mode byte (sync or add a device) is not in the proofs, so
  someone on the path can flip it (a failed session, nothing more); any knock on the
  port gets a fixed-size reply, so a waiting Cozy Safe device can be told from other
  software; a planted `9999999999999-x.json` in `lock/` stops the lock being refreshed.
- **`vault.db` is deleted on any open error**, a newer schema after a downgrade too:
  sync cursors, the device id and the connection log go with it.
- **Android 12 and older: the Recents picture** when "Block screenshots" is off.
  FLAG_SECURE is added in `onPause`, which may be after the system took its picture.
  Not checked on a device yet; if it shows the vault, keep the flag on below Android 13
  (no screenshots there) or cover from Dart on `inactive`.
- **Keyboards may learn from notes and search**: `enableIMEPersonalizedLearning` is on
  for the note editor, search and the account fields. Turn it off at least in Top Secret
  Mode.
- **The cloud copy of the 24 words can stay after its vault is deleted** (kept on
  purpose when the vault's copy in Google Drive is kept; it opens nothing alone). There
  is no place to remove it once the vault is gone from the device.
- **iCloud Keychain off**: the copy of the words is written and read back locally, so it
  reports success and the four-word check is skipped, with nothing in the cloud. Not
  confirmed on a device.
- **Wiping gaps** (memory attacks are out of scope): error paths in `stream.rs` return
  before the chunk buffers are wiped; stack copies of keys in `kdf.rs` and `seal_key`;
  a login parsed to a JSON tree holds its secrets in plain `String`s.

## Passwords and 2FA (after 0.2.28)

- Import from other password managers (CSV: Chrome, Bitwarden, 1Password, Apple).
- Autofill: iOS AutoFill credential provider, Android Autofill service (off in Top
  Secret).
- More kinds: bank cards, bank accounts, IDs with expiry reminders, Wi-Fi, crypto seed
  phrases, SSH and API keys, passkeys.
- The 2FA key field's error shows in ink, not red (the theme's error colour); the
  editor's form is centred, leaving a gap above short kinds.

## Interface

- **Move the whole app to Material Symbols.** The pieces added in 0.2.30 (the add card,
  the kinds of password, the steps) use `Sym` (Material Symbols Rounded, a vendored
  subset); the rest still uses `Icons.*` (the older Material Icons). Moving means adding
  each glyph to the subset (assets/fonts/README.md) and swapping the names. (Owner
  2026-11-07: modern icons.)
- **The password steps drop what was typed on Back from the first step**, without
  asking; the editor asks. (Review 2026-11-14.)
- **Import does not notice a file already in the vault**: adding the same photos twice
  keeps both. (Review 2026-11-14.)
- **An import stops when the vault locks** (leaving the app with "Lock as soon as I
  leave" on). It now says how far it got at the next unlock; holding the vault open for
  the import, as a sync is, would finish it. (Review 2026-11-14.)
- **QR scanning on Windows and Linux**: none (paste only). A picked image could be read
  with a small decoder if people ask.
- **The app shows no licence page**: the Apache-2.0 notices of the fonts and libraries
  it ships (Material Symbols) are in the repository only.

## Tooling

- **Android compiles Rust twice** in a release (the APK for GitHub, then the Play bundle
  for every ABI): about 4-5 minutes. Take the APK from the bundle instead, or build the
  native library once and reuse it. (Build timing, 2026-11-07.)
- **The Rust build caches barely help**: vendored crates are path dependencies, which
  cargo rebuilds whenever their files' times change (always, after a checkout). A
  directory source (`[source]` replacement) would be fingerprinted by version instead;
  a supply-chain change, so through tools/check-vendor and docs/supply-chain.md.
  (Build timing, 2026-11-07.)
- The security job is bounded by CodeQL Rust (about 5 minutes) and `owners` (about 4,
  the crates.io API at one request a second): builds could start beside them, with only
  the publishing jobs waiting for them (needs the publish jobs moved out of the reusable
  workflows).

- `tool/mockup.sh`: shots that fail in their setup (`settings-security`,
  `bottom-delete-vault`; run it again to see which still do).
- `app_ru.arb` `confirmRestoreTitle`: gen-l10n warns that `=1` is overridden by `one`.
- cackle (`cargo acl`) runs on Linux only; on a Mac it is left to CI.
- **Android foreground sync service**: written, off (`SYNC_SERVICE`, the manifest's
  commented permissions) until Google Play's foreground service declaration is filed.
- **SQLite's own test suite** is not run on the vendored copy (supply-chain.md).
- **Export compliance**: the answer of 2026-10-22 holds only while France is left out of
  App Store availability (untick it when availability is set up), and the BIS yearly
  report is due in January 2027 (export-compliance.md).
- **Test sign-in is compiled into the core** (`create_test_vault`) in every build; only
  the button is left out. A feature flag would leave it out of public builds.
- **ADR 0004** (PDFs outside the app's process) is still proposed, not built.
