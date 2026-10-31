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

/// The one exception to one kind per run (ADR 0005, owner 2026-10-31): a Top secret run
/// makes the Private vault when its password is saved, so the first Private start is an
/// ordinary unlock. Only where there is no Private vault yet, only into the Private
/// folder beside this run's library, and nothing is opened: the vault is made and
/// dropped at once, its keys wiped with it. False when a Private vault is already there.
/// Runs Argon2id at the Private cost: call it off the UI thread.
pub fn create_private_vault(
    dir: String,
    icon: String,
    color: String,
    password: String,
) -> Result<bool, VaultError> {
    let password = zeroize::Zeroizing::new(password);
    let path = PathBuf::from(&dir);
    if !private_beside(&run(), &path) {
        debug_line(|| "create private vault refused: not from a Top secret run".into());
        return Err(VaultError::Storage);
    }
    if cs_vault::Library::has_vaults(&path) {
        return Ok(false);
    }
    // A start left half-way (a library file, no vault) is made again.
    cs_vault::Library::reset_if_empty(&path)?;
    let library = cs_vault::Library::open_or_create_private(
        &path,
        super::vault::private_params_for_this_device(),
    )?;
    let vault = library.create_vault_with_password(&icon, &color, &password)?;
    drop(vault); // wipes its Master Key; nothing of it stays in this run
    Ok(true)
}

/// Whether `dir` is the Private library beside a Top secret run's own:
/// `<support>/library` and `<support>/private/library`.
fn private_beside(run: &Run, dir: &Path) -> bool {
    match run {
        Run::Started(VaultKind::TopSecret, top) => top
            .parent()
            .is_some_and(|support| dir == support.join("private").join("library")),
        _ => false,
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
    fn only_a_top_secret_run_may_make_the_private_vault_beside_it() {
        let top = PathBuf::from("/support/library");
        let private = PathBuf::from("/support/private/library");
        let mut r = Run::NotStarted;
        assert!(!private_beside(&r, &private));
        assert!(start(&mut r, VaultKind::TopSecret, top.clone()));
        assert!(private_beside(&r, &private));
        assert!(!private_beside(&r, &top));
        assert!(!private_beside(&r, Path::new("/elsewhere/private/library")));
        // A Private run, or a run that ended, makes nothing.
        let mut p = Run::NotStarted;
        assert!(start(&mut p, VaultKind::Private, private.clone()));
        assert!(!private_beside(&p, &private));
        assert!(!private_beside(&Run::Ended, &private));
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
