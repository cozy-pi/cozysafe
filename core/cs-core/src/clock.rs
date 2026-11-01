//! The vault's clock for sync (docs/adr/0003-sync.md): this device's id and a hybrid
//! logical clock, both kept in the vault index.

use crate::db::Index;
use crate::Result;

/// This device's id in the vault's sync, made the first time it is asked for.
pub fn device_id(index: &Index) -> Result<String> {
    if let Some(id) = index.meta_get("device")? {
        return Ok(id);
    }
    let id = crate::hex::encode(&cs_crypto::generate_salt()[..8]);
    index.meta_set("device", &id)?;
    Ok(id)
}

/// The next hybrid-logical-clock reading: after the wall clock, after everything this
/// device has written or seen, and after `seen` (a record being changed or merged), so a
/// phone whose clock is wrong cannot make its edits always win or always lose.
pub fn next_hlc(index: &Index, seen: i64) -> Result<i64> {
    let last: i64 = index
        .meta_get("hlc")?
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let next = now_ms().max(last + 1).max(seen + 1);
    index.meta_set("hlc", &next.to_string())?;
    Ok(next)
}

/// Move the clock past `seen` (a record read from another device).
pub fn observe_hlc(index: &Index, seen: i64) -> Result<()> {
    let last: i64 = index
        .meta_get("hlc")?
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if seen > last {
        index.meta_set("hlc", &seen.to_string())?;
    }
    Ok(())
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
