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
  scan) would need a record field (now safe to add: unknown fields are kept since 0.2.28).
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
- **QR scanning on Windows and Linux**: none (paste only). A picked image could be read
  with a small decoder if people ask.
- **The app shows no licence page**: the Apache-2.0 notices of the fonts and libraries
  it ships (Material Symbols, ZXing) are in the repository only.

## Tooling

- `tool/mockup.sh`: three shots fail in their setup (`mac-home-cloud`,
  `settings-security`, `bottom-delete-vault`).
- `app_ru.arb` `confirmRestoreTitle`: gen-l10n warns that `=1` is overridden by `one`.
- cackle (`cargo acl`) runs on Linux only; on a Mac it is left to CI.
