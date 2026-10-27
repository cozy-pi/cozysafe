//! The error log (owner 2026-10-26: "Drive failed and nobody could tell why"): every
//! error the core hands to the app is noted here as a short fixed code, always on, so a
//! person can copy what happened. Only codes and times: never names, paths, content,
//! keys or network data. Dart takes them ([`take_errors`]) into its own small file.

use std::collections::VecDeque;
use std::sync::Mutex;

/// The last codes since Dart last took them (a few is plenty: Dart takes them often).
static RECENT: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
const KEEP: usize = 100;

/// Note a failure: `place` and `code` are fixed words from this crate (see
/// [`super::sync::error_code`]).
pub(crate) fn note(place: &str, code: &str) {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let mut q = RECENT.lock().unwrap_or_else(|p| p.into_inner());
    if q.len() >= KEEP {
        q.pop_front();
    }
    q.push_back(format!("{ms}|{place}|{code}"));
}

/// The errors noted since the last call, oldest first, as `<ms>|<place>|<code>`.
#[flutter_rust_bridge::frb(sync)]
pub fn take_errors() -> Vec<String> {
    RECENT
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .drain(..)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noted_codes_are_taken_once_and_kept_few() {
        take_errors();
        for _ in 0..KEEP + 5 {
            note("sync", "drive-full");
        }
        let got = take_errors();
        assert_eq!(got.len(), KEEP);
        assert!(got[0].ends_with("|sync|drive-full"));
        assert!(take_errors().is_empty());
    }
}
