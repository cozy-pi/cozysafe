//! One kind of vault per app run (ADR 0005, "Nothing shared"). Dart reads the kind from
//! the start file and hands it over once, with that kind's library folder, before any
//! vault call. From then on every call naming a library folder must name that one: a
//! call for the other kind's folder is refused, so a Top secret run never opens, lists
//! or writes the Private library, and the other way round. Switching kinds ends the run
//! ([`end_run`]): nothing opens again until the app starts anew.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::vault::{debug_line, VaultError};

/// The two kinds of vault (ADR 0005).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaultKind {
    /// Password and the 24 words; text, stored files and the app's own photos.
    TopSecret,
    /// A strong password only; photos, videos and files from anywhere.
    Private,
}

#[derive(Debug, PartialEq)]
enum Run {
    NotStarted,
    Started(VaultKind, PathBuf),
    Ended,
}

static RUN: Mutex<Run> = Mutex::new(Run::NotStarted);

fn run() -> std::sync::MutexGuard<'static, Run> {
    RUN.lock().unwrap_or_else(|p| p.into_inner())
}

/// Fix this run's kind and library folder. Only the first call sets them; a later call
/// with the same pair is accepted (a hot restart in development), any other is refused.
#[flutter_rust_bridge::frb(sync)]
pub fn start_run(kind: VaultKind, library_dir: String) -> bool {
    start(&mut run(), kind, PathBuf::from(library_dir))
}

/// The kind this run was started with; None before [`start_run`] and after [`end_run`].
#[flutter_rust_bridge::frb(sync)]
pub fn run_kind() -> Option<VaultKind> {
    match &*run() {
        Run::Started(kind, _) => Some(*kind),
        _ => None,
    }
}

/// Switching kinds: lock the open vault, forget the Secret Key and refuse every library
/// call until the app starts again.
#[flutter_rust_bridge::frb(sync)]
pub fn end_run() {
    *run() = Run::Ended;
    super::vault::lock();
    super::vault::forget_secret_key();
}

/// `dir` as a path when it is this run's library folder; refused otherwise.
pub(crate) fn library_dir(dir: &str) -> Result<&Path, VaultError> {
    if allowed(&run(), Path::new(dir)) {
        Ok(Path::new(dir))
    } else {
        debug_line(|| "library call refused: not this run's kind".into());
        Err(VaultError::Storage)
    }
}

fn start(run: &mut Run, kind: VaultKind, dir: PathBuf) -> bool {
    match run {
        Run::NotStarted => {
            *run = Run::Started(kind, dir);
            true
        }
        Run::Started(k, d) => *k == kind && *d == dir,
        Run::Ended => false,
    }
}

fn allowed(run: &Run, dir: &Path) -> bool {
    matches!(run, Run::Started(_, d) if d == dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_runs_own_folder_is_allowed() {
        let top = PathBuf::from("/support/library");
        let private = PathBuf::from("/support/private/library");
        let mut r = Run::NotStarted;
        assert!(!allowed(&r, &top), "nothing before the run starts");
        assert!(start(&mut r, VaultKind::TopSecret, top.clone()));
        assert!(allowed(&r, &top));
        assert!(!allowed(&r, &private));
        // The same start again is fine; another kind or folder is not.
        assert!(start(&mut r, VaultKind::TopSecret, top.clone()));
        assert!(!start(&mut r, VaultKind::Private, private.clone()));
        assert!(!start(&mut r, VaultKind::TopSecret, private.clone()));
        assert!(allowed(&r, &top));
        assert!(!allowed(&r, &private));
    }

    #[test]
    fn nothing_is_allowed_after_the_run_ends() {
        let top = PathBuf::from("/support/library");
        let mut r = Run::NotStarted;
        assert!(start(&mut r, VaultKind::TopSecret, top.clone()));
        r = Run::Ended;
        assert!(!allowed(&r, &top));
        assert!(!start(&mut r, VaultKind::TopSecret, top));
    }
}
