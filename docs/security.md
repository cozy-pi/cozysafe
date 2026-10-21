# Security rules for the app

Rules every screen follows, so that someone who picks up an unlocked phone, or a person
or camera looking over a shoulder, gets as little as possible. Check this page when
adding a screen, a setting or anything that shows a secret. Encryption itself is in
[ADR 0001](adr/0001-encryption.md); libraries and the network in
[supply-chain.md](supply-chain.md).

## Security settings ask for the owner

Anything that weakens or reveals the vault's protection asks for Face ID, fingerprint or
the phone's passcode first (`confirmOwnerForSetting` in `app/lib/biometric.dart`), every
time, wherever it is opened from:

| Setting | Where the check is |
|---|---|
| Face ID / fingerprint on or off | `vault_home.dart` `_toggleBiometric` |
| Change PIN | `settings.dart` (`_guarded`) |
| Auto-lock time | `settings.dart` (`_guarded`) |
| Block screenshots | `settings.dart` (`_guarded`) |
| Show note text in lists and search (on only) | `settings.dart` (`_guarded`) |
| Back up to a file | `vault_home.dart` `_backup` |
| Backup password (set or change) | `vault_home.dart` `_password` (also the reminder banner) |
| Emergency Kit (shows the Secret Key) | `vault_home.dart` `_showKit` |
| Delete this vault | `settings.dart` (`_guarded`), then the vault's PIN |
| New vault | `confirmOwner` (lock screen and vault) |

A new security setting gets the same check in the same commit, and a row in this table.
Limit: on a device with no biometrics and no passcode support (`local_auth` reports it
unsupported, e.g. Linux), the system check cannot run and is skipped.

## Secrets on screen

- **Never shown by default.** The Secret Key (Emergency Kit) is masked (`SecretText`):
  always the same 16 dots (the mask does not tell the key's length), a Show button, hidden again after 30 seconds and whenever the
  app leaves the foreground.
- **Password and key fields are hidden while typed** (`SecretField`), with an eye to
  show them; this includes a suggested passphrase, which appears hidden.
- **Note text stays out of lists.** The notes list and search show titles and dates only;
  search says "Found in the text" instead of quoting it. Settings → Display can show it
  (owner check to turn on).
- **Text files are read in memory.** txt, md, json and other text files open inside the
  app from decrypted bytes, never written to a file; copying from them is wiped like
  any copy (`file_view.dart`, `_textView`).
- **Debug mode is hidden and harmless.** Seven taps on the version in Settings → About,
  then the owner check. It shows technical facts (build, device, biometrics, whether the
  network guard is on, item counts, temporary copies) and can clear temporary copies; it
  never shows keys, PINs, passwords or vault content, and changes no protection.
- **Big files are not loaded whole.** Text previews decrypt only their first 1 MB
  (`item_content_head`); photos decode at screen size; PDFs over 40 MB open from a private
  temporary copy deleted on close, on lock and at start.
- PINs show as dots only, one per digit, no count of the remaining digits.
- **Copied secrets are wiped:** anything copied out (`LockGuard.copied`) is removed from
  the clipboard after 60 seconds and when the vault locks.
- `test/secret_test.dart` checks the hiding.
