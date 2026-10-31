# Naming

One concept, one name, everywhere: Rust, Dart, stored records, preference keys and
docs. Check this page before adding a field, a key or a type; when a name here is
wrong, change it here first and then in the code, in the same commit.

## Words we use

| Concept | Name in code | Said in the app | Notes |
|---|---|---|---|
| A vault | `vault` | két | |
| Anything stored in a vault | `item` | (by its kind) | |
| What an item is | `kind` on an item: `photo`, `video`, `note`, `audio`, `file`, `tag` | | Rust: `cs_vault::items::kind::*`; Dart: `ItemKind.*`. Never write the strings by hand |
| A group of items | `tag`; on an item `tag_ids` / `tagIds` | nhóm | A tag is an item of kind `tag` (encrypted like the rest). An item can carry several |
| The four tabs at the bottom | `section`: `note`, `library`, `audio`, `file` (Dart `VaultSection`) | Ghi chú · Thư viện · Ghi âm · Tệp | A section shows items of some kinds; it is not a kind |
| Small preview image | `thumbnail` | | Not `thumb`. The on-disk role tag `thumb` (file `<bucket>/<item>.thumb`, AAD `item/<id>/thumb`) stays: it is part of the encryption format |
| The second secret, kept in the device's keystore | `secret key` in code (`SecretKey`, `SecretKeyStore`) | **Recovery Key** · **Khoá khôi phục** (24 words) | Owner 2026-10-21: replaces "Emergency Kit / Bộ khẩn cấp". "Secret Key" only in technical text (security page details, docs). 256 bits as 24 BIP39 words; 128-bit `CS1-` keys from before still read |
| The app's mode (ADR 0006) | `TopSecretMode.on` (Dart); Rust `RunMode::TopSecret` / `RunMode::Everyday`; start file `top-secret-mode` holds `on` or `off` | **Chế độ tuyệt mật** · **Riêng tư** (Top Secret Mode · Private) | One mode per app run (`api/run.rs`). In code the other mode is "everyday"; people see "Private" |
| A vault's password | `password` | **vault password** · **Mật khẩu két** | Owner 2026-10-21: replaces "backup password / mật khẩu sao lưu". One per vault: opens it without PIN/Face ID, and with the Recovery Key opens a backup |
| The two ways in | — | everyday (PIN / Face ID, this phone) · recovery (Recovery Key + vault password + backup file) | How the app explains keys to people (security page, Settings) |

## Rules

- **Case.** Rust and stored JSON: `snake_case`. Dart: `lowerCamelCase` for members,
  `UpperCamelCase` for types. Preference keys: `kebab-case`.
- **Units in the name** for every quantity: `_ms` (milliseconds since the Unix epoch, or a
  length of time), `_bytes`, `_kib`, `minutes`. In Dart the same suffix in camel case:
  `createdMs`, `sizeBytes`. A stored timestamp key ends in `-ms` (`password-seen-ms`).
- **Ids** end in `_id` (`tag_id`), lists of ids in `_ids` (`tag_ids`). A field holding an
  id is never named like the thing itself (`folder` held an id: wrong).
- **Booleans** read as a yes/no question: `has_`, `is_`, `can_` (`has_thumbnail`).
- **No abbreviations** except these: `id`, `PIN`, `KDF`, `DEK` (data encryption key),
  `MIME`, `URL`, `UI`, and the Argon2 cost names from RFC 9106 (`m_kib`, `t`, `p`, kept in
  one `kdf` object). Everything else is spelled out.
- **No magic strings.** Item kinds, sections and preference keys are constants declared
  once; code compares against the constant.
- **Doc comments list the allowed values** of a string field and are updated with it. A
  comment that disagrees with the code is a bug.

## Changing a stored name

Stored records live on people's phones and in their backups, so a rename must read the
old name forever:

1. Raise the record's `format`, and write only the new name.
2. Read the old one with `#[serde(alias = "old")]`, or a `legacy_` field marked
   `skip_serializing` when the meaning changes (see `ItemRecord::upgraded`).
3. Add a test that writes a record exactly as the previous release did and reads it.
4. Note the old and new layout in the struct's doc comment.

Preference keys follow the same idea: read the old key when the new one is missing.

## Known leftovers

- `VaultMeta.name` (inside the sealed vault meta): never filled or shown; vaults have
  only an icon and a colour. Keep reading it; drop it with the next vault-header format.

## History

- Format 2 of item records and PIN files (0.1.7): `size` → `size_bytes`, `has_thumb` →
  `has_thumbnail`, folders (`folder`, `color`, `space`) → tags (`tag_ids`), PIN cost
  grouped in `kdf`. Dart: `VaultKind`/`space`/`AddMode` → `VaultSection`; string kinds →
  `ItemKind`.

## Language

Cozy Safe is a global product: everything in this repository is written in English,
including commit and merge messages, docs, the changelog, code comments and release notes
(owner, 2026-10-21). Text people see in the app goes through the translations
(`app/lib/l10n`), never hard-coded in one language.

The app speaks 15 languages (2026-10-21), the same as the website: en, es, pt (Brazil),
fr, de, it, tr, ru, id, th, ja, ko, zh (Simplified), zh_Hant (Traditional), vi. The list
lives in `app/lib/language.dart`; each language has `app/lib/l10n/app_<code>.arb`, a tag
in `ios/Runner/Info.plist` (`CFBundleLocalizations`) and in
`android/app/src/main/res/xml/locales_config.xml` — `test/language_test.dart` checks all
four agree and that every file has every key with the same placeholders. "Secret Key"
stays in English in every language. Adding a language: translate `app_en.arb` (reuse the
website's terms in `website/i18n/<code>.json`), then add it to those three lists.
