# ADR 0007: Each vault has its own mode; managing the vaults on a device

- Status: accepted (owner, 2026-10-31)
- Changes: [ADR 0006](0006-top-secret-mode.md) (one mode for the whole device)

## Context

ADR 0006 kept Top Secret Mode in a file next to the library: one mode for every vault on
the device, chosen only while making the first vault. The owner: "the mode belongs to
each vault, not the device". Making a second vault asked nothing, Face ID moved silently
from one vault to another, and there was no place to see or delete the vaults on a
device.

## Decision

**Mode per vault.**

- The mode is sealed in the vault's meta (`top_secret` in `VaultMeta`, written only when
  on, so an everyday vault's meta is what it was), with its name, icon and colour. It
  travels with the vault (sync, backups). Nothing in the clear says which mode a vault
  is in.
- Every new vault asks for its mode (Private or Top secret) after its intro. Settings →
  Top Secret Mode turns it on or off for the open vault: the owner check, then the run
  ends and the app starts again, as before.
- A run starts in Top Secret Mode (nothing is decoded before a vault opens) and takes the
  mode of the vault that opens (`api/run.rs`, `vault_opening`). An everyday vault may
  open after a Top secret one in the same run (nothing was decoded). A Top secret vault
  after an everyday one is refused (`VaultError::RestartForMode`, its keys wiped): the
  app ends the run and asks to be started again, because something decoded may have
  touched the app. The old start file of ADR 0006 is removed at start.
- Top Secret Mode takes photos from the library again (owner): the system picker copies
  each file (`loadFileRepresentation` on iOS, a content copy on Android), the bytes are
  sealed as they are, no thumbnail is made, nothing is decoded in the app. They are kept
  as files.

**Face ID, one vault per device** (already so in the core: `enable_biometric` takes it
from the others). Making a vault or opening one with its password offers Face ID only
when no vault here has it. Turning it on in Settings while another vault has it first
says that vault will open only with its password.

**Vaults on this device** (Settings, for everyone; was a Debug page). The open vault and
the others as locked tiles with their size (names, icons and modes stay sealed).

- Deleting is on this device only. With the vault's own password it goes at once
  (`delete_other_vault` opens it only to check the password, never keeps it).
- Password forgotten: after the phone's owner (Face ID or passcode), the vault is set to
  go in seven days (`delete-at/<id>` beside the vaults, the time in the clear like its
  size). Opening it with its password, Face ID or PIN in the meantime keeps it; Keep this
  vault cancels too. Due vaults go at start and when the list opens, never the open one.
- Its copy in Google Drive goes only when the person ticks "Also delete it from Google
  Drive" (owner). Sync → Google Drive also has "Delete this vault from Google Drive" for
  the open vault: owner check, a confirmation, automatic sync off. Another device that
  still holds the vault can send it up again; the app says so. No mark is left on Drive:
  a device that synced over Wi-Fi would bring the vault back anyway (owner).

## Not changed

How a vault is locked (password and the 24 words), sync and backups, and the rule that
the vault's core uses only audited cryptography and SQLite.
