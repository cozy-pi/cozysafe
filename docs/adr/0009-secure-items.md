# ADR 0009: Secure items: logins, one-time codes, recovery codes

- Status: accepted (owner, 2026-11-06)
- Related: [ADR 0001](0001-encryption.md) (item keys), [ADR 0002](0002-vault-index.md)
  (index), [ADR 0003](0003-sync.md) (sync), [ADR 0006](0006-top-secret-mode.md) (Top
  Secret Mode), docs/data-model.md, docs/cryptography.md

## Context

The vault holds photos, videos, notes, recordings and files. People also keep their
passwords and two-factor codes, today in notes, where nothing can copy a password safely,
show a live code or find a login by its web site. The owner asked for a password and 2FA
store (2026-11-06), with the storage format agreed before any screen.

## Decision

### One item per secret, as every other item

Each secure item is an ordinary item with a new kind, so it gets, unchanged, what every
item has: its own random key, sync, backups, Recently deleted, groups, favourites,
version history and Top Secret Mode.

| Kind | What |
|---|---|
| `login` | A login: account, password, web sites, an optional one-time code |
| `otp` | A one-time code (TOTP) on its own |
| `codes` | A service's recovery codes |

Cards, bank accounts, documents, Wi-Fi, crypto seed phrases and keys come later as more
kinds in the same shape.

### Two layers: a summary to list, a document to open

| Layer | Where | Holds | Decrypted |
|---|---|---|---|
| Summary | `summary` in the item record (`.meta`, the index), sealed with the Master Key | account (user name or email), web sites' host names | on unlock, to list, search and later fill in |
| Document | `.data`, encrypted with the item's own key | everything, secrets included | only when that item is opened, copied or filled in |

A list of a thousand logins opens no content, and no password is in memory while
scrolling. The summary is always **derived from the document**
(`cs_core::entries::summary_of`) and names the content it was read from (`of`, the
content's `data_hash`). It is read again, on every unlock and after every sync
(`OpenVault::restore_summaries`), when it is missing (an older app, which does not know
the field, rewrote the record) or names other content (sync took the other device's,
a version was restored). That repair writes the record as it is, no new revision, and
never stops a vault from opening. A summary that cannot be read counts as missing.

### Edits on two devices, and stale saves

- Both devices changed the content: the later wins and the other is kept as a **copy of
  the same kind** (`Bank (iPhone)`), never as a note holding the document in plain
  view. A password changed on one device is never lost to an edit on another.
- A save names the revision it was edited from (`update_entry(…, rev)`); if sync brought
  another change meanwhile, the save is refused (`VaultError::Changed`) and the screen
  reads it again, so an edit never silently overwrites another.

### The document: JSON with a version

```json
{"v": 1, "username": "…", "password": "…", "urls": ["https://github.com"],
 "otp": {"secret": "BASE32", "algo": "SHA1", "digits": 6, "period": 30},
 "notes": "…", "fields": [{"label": "…", "value": "…", "secret": true}]}
```

- JSON, not a binary format: a few hundred bytes, already encrypted, easy to check, and
  what other password managers import and export.
- `v` is required; the core refuses content that is not an object with a version
  (`Error::BadEntry`). A newer `v` is still read.
- Fields the app does not know are kept: the app edits the document it read, so a
  newer version's fields survive an older app's edit.
- `fields` holds anything without a field of its own.
- The content's media type is `application/vnd.cozysafe.<kind>+json`. That alone does
  not protect them from an older app (below).

### Password history is version history

No `history` field: changing a password replaces the content, and the old content goes
to the item's version history (`crate::history`) like a note's. It stays on the device
that made the change: not synced, not in backups. The current password always is. The
item's own page lists its earlier versions and shows each masked, like the item
(`history_entry_json`); the generic history page and `history_content` refuse them.

### Read only through their page

Rust refuses `item_content`, `item_content_head`, `export_item` and `history_content`
for secure items and for kinds from a newer version: a viewer, a share or an export
cannot reach a password whatever a screen asks. A document whose `v` is newer than the
app's opens read-only, so an older app never rewrites what it does not fully know.

### Copying a secret

A copied password or code must outlive the vault locking, which happens as soon as the
person switches to the app that asks for it; other copied text is wiped on lock. So a
secret is copied through `SecureClipboard`:

- iOS: the pasteboard's own expiry and this device only (no Universal Clipboard);
  cleared by the system even with the app closed.
- Android: marked sensitive (hidden in the copy preview, not kept by keyboards),
  cleared on time while the process lives, even in the background (unconditionally:
  Android hides the clipboard from apps in the background, so it cannot check what is
  there), otherwise when the app comes back.
- Mac: this Mac only, marked concealed and transient for clipboard managers
  (nspasteboard.org), cleared on time unless something else was copied since.
- Windows and Linux: cleared on time while the app runs.
- Clearing after 90 seconds by default (owner: 30 s was too short; 1Password uses 90 s).
  Settings offers 30 s, 90 s, 3 minutes or never; a Top Secret vault keeps 90 s.

### Top Secret Mode

Secure items open in the app, like notes: the summary is sealed as an item's name is,
and the content is shown, never handed to another app. What could expose them outside
the app stays off there: autofill (a later round) and keeping a copy longer than 90 s.

### Adding step by step (0.2.30, owner 2026-11-07)

A new item is made in steps (`lib/screens/entry_steps.dart`), one question per screen,
mostly taps; changing an item keeps the form (`entry_editor.dart`).

- First what to add: Login, Two-factor code, Recovery codes, as three cards, each kind
  with its own icon and colour (`entryKindColor`), the same in lists and on its page.
- Login: the site (the vault's own hosts from the summaries, most used first, then a
  fixed list of common services by host name, never logos; search, Paste link, or any
  name typed), the account (the summaries' accounts, most used first), the password
  (generated, masked; Generate another, Paste, Type my own with the strength line), an
  optional two-factor code, then a review where the name (the site by default) can be
  changed.
- Two-factor code alone: Scan, a picture, or Paste (key or link), then a review with
  the service and account read from the link and the code running.
- Recovery codes: the service, then one Paste that splits and counts them.
- What the form promises holds: the vault locking saves what can be saved and empties
  the secrets from the screen (they come back from the item on unlock), a save over a
  change made elsewhere keeps both ("(unsaved)"), secret fields copy only through
  `SecureClipboard`, and what is pasted as a secret (password, key, codes) is taken off
  the clipboard. Only the summaries are read to offer sites and accounts: no other
  item's content is opened.

### QR codes (0.2.30)

- Only an `otpauth://totp/` link is taken (`Totp.parse`); any other QR code (a web
  link, Wi-Fi) is refused with "This QR code is not a two-factor setup code", and a
  picture without one says so.
- One decoder path for the camera, on every phone: a page inside the app (the `camera`
  plugin, YUV 420, a few frames a second, the luminance plane only, with its row
  stride; on iPhone the bi-planar Y plane), read by the Rust QR decoder that pairs
  devices (rqrr, `qr_read_text`). Since 0.2.31: in 0.2.30 the iPhone used a native
  AVFoundation camera page over the app, which Flutter reported as leaving the app, so
  the vault locked mid-scan; that page is gone. A picked picture: Vision on iPhone and
  on a Mac (an image file), kept because it reads the image file as picked; on Android
  the system photo picker, the picture turned to grey in memory and read by rqrr. No new
  library. Windows and Linux: paste only.
- The photo picker is the system's: the vault allows leaving for it
  (`LockGuard.allowAway`) and ends that as soon as it returns. The camera needs no such
  grace, the app never leaves.
- A pasted bare key (not a link) is shown with the code it makes before it is taken, so
  a wrong paste is caught against the site's own screen.
- In memory only: no frame or picture is written to a file, kept in the photo library,
  copied into the vault or logged; only the QR code's text comes back, and the picture
  is dropped. The photo picker shows one picture without access to the library.
- The vault locking closes the camera page and lets the camera go; every way out
  releases it.
- Top Secret Mode offers the camera and Paste only: no picture from the library.

## Rejected

- **Passwords inside notes**: no safe copy, no live codes, nothing to search by site.
- **One encrypted file for every password** (as KeePass): one change rewrites
  everything and sync merges whole files; items already solve both.
- **A summary field written once and trusted**: an older app would drop it for good.
- **A password history list inside the document**: the version history already keeps
  every earlier content.

## Consequences

- `ItemRecord` gains the optional `summary` (no format change: absent means none).
- Older apps (0.2.27 and before) cannot be stopped: they check no version when syncing.
  They show these items in no section, but search and recent items reach them, and
  their Send writes any item's decrypted content to a file and shares it, so a login's
  document, password included, could leave in plain text if someone sends it on
  purpose. The changelog asks people to update every device before keeping passwords.
  From 0.2.28 an item of an unknown kind is shown as "needs a newer version" and never
  opened, sent or exported (Rust refuses it too), so the next new kind is safe.
- Autofill (iOS AutoFill provider, Android Autofill service), CSV import and more kinds
  are later rounds on this format. QR scanning came in 0.2.30 (above).
