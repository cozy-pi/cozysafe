# ADR 0006: Top Secret Mode, one kind of vault

- Status: accepted (owner, 2026-10-31)
- Replaces: [ADR 0005](0005-two-kinds-of-vault.md) (two kinds of vault)
- Keeps: the Top secret core of ADR 0005 step 1 (`cs-core`, audited cryptography and
  SQLite only, built from copies in `third_party/`)

## Context

ADR 0005 split the app into two vaults that share nothing: Top secret (password and the
24 words, nothing decoded) and Private (a password only, photos and files shown). Built
and tried on the branch, it asked a lot of the person: two passwords, one kept inside the
other, a switch that restarts the app, two lock screens. The owner asked for one vault
with a switch, like the iPhone's Lockdown Mode, and named it Top Secret Mode.

## Decision

- **One kind of vault**, as before ADR 0005: opened with the vault password and the 24
  words (Secret Key). Everything is encrypted the same way in both modes.
- **Top Secret Mode** changes what the app does with what is inside, never how the vault
  is locked:
  - nothing inside the vault is decoded in the app: no photo, video, PDF or thumbnail;
    a file, recording, video or camera photo is a named row, opened only in another app
    after a warning (the screens of ADR 0005 step 4);
  - nothing is taken from the photo library;
  - camera photos, video, voice notes, notes and files from the Files app are kept.
- **Enforced in Rust**, not only in the screens (`app/rust/src/api/run.rs`): in Top
  Secret Mode `item_thumbnail` is refused, `item_content` / `item_content_head` are
  refused for anything but notes, and `add_file` refuses a thumbnail (one made from
  outside data means it was decoded). A run not started counts as Top Secret.
- **One mode per run.** Read at start from the file `top-secret-mode` (`on` / `off`,
  missing = off) next to the library and handed to Rust (`start_run`). It may change
  until a vault opens (`choose_mode`, the first vault's maker); after that, turning it on
  or off locks the vault, forgets the Secret Key, wipes temporary files and restarts the
  app: Android and computers quit by themselves; iPhone and iPad show a page asking the
  person to close the app (Apple asks apps not to quit by themselves).
- **Where it is chosen:** the first step of making the first vault (Private or Top
  secret, with the list of differences and "you can change this later in Settings"), and
  Settings → Top Secret Mode (a card on the main page, so people know it exists). Turning
  it on or off asks for the owner first (docs/security.md).
- **Names:** Vietnamese "Chế độ tuyệt mật", English "Top Secret Mode"; the everyday mode
  is called Private ("Riêng tư"). Marks: a red shield with a lock (Top secret), a green
  shield with a photo (Private). While the mode is on, a small red shield sits on the
  corner of the Settings button, and nowhere else (owner's choice of three places).

## What went away

The Private vault and everything that served it: its password-only key derivation
(`derive_root_password_only`, the higher Argon2 cost, the 14-character rule), the
Private library kind, the sealed Private password and its Reset, switching kinds, the
per-kind folders and keystore names, the vault-kind marks. `core/` is back to step 1.
A Private vault made by an internal test build stays on that device as files, unread.

## Not changed

Sync and backups are the same in both modes. The rule that the vault's core uses only
audited cryptography and SQLite (supply-chain.md) stands.
