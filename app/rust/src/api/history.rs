//! Version history (cs_vault::history): older versions of an item, kept on this device.

use cs_vault::history::HistoryLimits;

use super::vault::{with_open, ItemInfo, VaultError};

/// One older version of an item.
pub struct HistoryVersion {
    pub rev: String,
    /// When a newer version replaced it.
    pub replaced_ms: i64,
    /// The item as it was then (name, size, groups…).
    pub item: ItemInfo,
    /// Made on this device; otherwise it came from another one by sync.
    pub this_device: bool,
    /// Its content can still be opened (it may have been removed to save space).
    pub has_content: bool,
    /// Its content is the same as now (only the name, groups… differ).
    pub same_content: bool,
}

/// The item's older versions, newest first.
pub fn item_history(id: String) -> Result<Vec<HistoryVersion>, VaultError> {
    with_open(|v| {
        Ok(v.history(&id)?
            .into_iter()
            .map(|e| HistoryVersion {
                rev: e.rev,
                replaced_ms: e.replaced_ms,
                item: e.item.into(),
                this_device: e.this_device,
                has_content: e.has_content,
                same_content: e.same_content,
            })
            .collect())
    })
}

/// An older version's content, decrypted in memory. Never a secure item's, nor one of a
/// kind from a newer version: see [`history_entry_json`].
pub fn history_content(id: String, rev: String) -> Result<Vec<u8>, VaultError> {
    with_open(|v| {
        let kind = v.record(&id)?.kind;
        if cs_vault::items::kind::is_entry(&kind) || !cs_vault::items::kind::is_known(&kind) {
            return Err(VaultError::Storage);
        }
        let mut out = Vec::new();
        v.read_history_item(&id, &rev, &mut out)?;
        Ok(out)
    })
}

/// An older version of a secure item's document, for its own page (masked like the
/// item itself, ADR 0009). Wiped when dropped on this side.
pub fn history_entry_json(id: String, rev: String) -> Result<String, VaultError> {
    with_open(|v| {
        if !cs_vault::items::kind::is_entry(&v.record(&id)?.kind) {
            return Err(VaultError::Storage);
        }
        let mut out = zeroize::Zeroizing::new(Vec::new());
        v.read_history_item(&id, &rev, &mut *out)?;
        String::from_utf8(out.to_vec()).map_err(|_| VaultError::Storage)
    })
}

/// Make an older version the current one (itself a new version, so it can be undone).
pub fn restore_version(id: String, rev: String) -> Result<ItemInfo, VaultError> {
    with_open(|v| {
        let restored = v.restore_history(&id, &rev)?;
        if !cs_vault::items::kind::is_entry(&restored.kind) {
            return Ok(restored.into());
        }
        // A secure item's list line follows the content it got back.
        let _ = v.restore_summaries();
        let fresh = v.items()?.into_iter().find(|m| m.id == id);
        Ok(fresh.unwrap_or(restored).into())
    })
}

/// Forget one item's history.
pub fn clear_item_history(id: String) -> Result<(), VaultError> {
    with_open(|v| Ok(v.clear_history(&id)?))
}

/// Forget all history in the open vault.
pub fn clear_all_history() -> Result<(), VaultError> {
    with_open(|v| Ok(v.clear_all_history()?))
}

/// Space history takes, in bytes.
pub fn history_bytes() -> Result<u64, VaultError> {
    with_open(|v| Ok(v.history_bytes()?))
}

/// This device's limits: days kept (0 = off) and most space (0 = no limit).
pub struct HistorySettings {
    pub days: u32,
    pub max_bytes: u64,
}

pub fn history_settings() -> Result<HistorySettings, VaultError> {
    with_open(|v| {
        let l = v.history_limits()?;
        Ok(HistorySettings {
            days: l.days,
            max_bytes: l.max_bytes,
        })
    })
}

/// Change the limits; what falls outside goes at once.
pub fn set_history_settings(days: u32, max_bytes: u64, now_ms: i64) -> Result<(), VaultError> {
    with_open(|v| Ok(v.set_history_limits(HistoryLimits { days, max_bytes }, now_ms)?))
}
