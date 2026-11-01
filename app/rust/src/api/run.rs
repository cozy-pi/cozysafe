//! The mode of an app run (ADR 0006): everyday or Top Secret Mode. Dart reads the mode
//! from the start file and hands it over once, with the library folder, before any vault
//! call. Every call naming a library folder must name that one.
//!
//! Top Secret Mode changes what the app does with what is inside the vault, never how
//! the vault is locked: the password and the 24 words are the same in both modes. In Top
//! Secret Mode this side refuses to hand out anything the app would have to decode (a
//! photo, a video, a PDF, a thumbnail) and to take a thumbnail made from outside data, so
//! a screen that forgot to ask the mode still cannot show one. Notes (text) are read as
//! always; files leave only by export, to another app.
//!
//! Each vault has its own mode (ADR 0007), sealed in its meta. A run starts in Top
//! Secret Mode (nothing decoded before a vault opens) and takes the mode of the first
//! vault that opens. A later vault may open in the same mode, or in the everyday mode after
//! a Top secret one (nothing was decoded); a Top secret vault after an everyday one needs a
//! fresh run ([`VaultError::RestartForMode`]): something decoded may have touched the app.
//! Turning a vault's mode on or off ends the run ([`end_run`]).

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::vault::{debug_line, VaultError};

/// The two modes of a run (ADR 0006).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunMode {
    /// Photos, videos and files shown in the app; import from anywhere.
    Everyday,
    /// Nothing from inside the vault is decoded; nothing taken from the photo library or
    /// other apps.
    TopSecret,
}

#[derive(Debug, PartialEq)]
enum Run {
    NotStarted,
    Started {
        mode: RunMode,
        dir: PathBuf,
        opened: bool,
    },
    Ended,
}

static RUN: Mutex<Run> = Mutex::new(Run::NotStarted);

fn run() -> std::sync::MutexGuard<'static, Run> {
    RUN.lock().unwrap_or_else(|p| p.into_inner())
}

/// Fix this run's mode and library folder. The first call sets them; a later call with
/// the same folder is accepted (a hot restart in development) and may change the mode
/// only while no vault has opened ([`choose_mode`]). Any other call is refused.
#[flutter_rust_bridge::frb(sync)]
pub fn start_run(mode: RunMode, library_dir: String) -> bool {
    start(&mut run(), mode, PathBuf::from(library_dir))
}

/// Change the mode before any vault has opened in this run (the first vault's maker asks
/// for it). False once a vault has opened.
#[flutter_rust_bridge::frb(sync)]
pub fn choose_mode(mode: RunMode) -> bool {
    choose(&mut run(), mode)
}

/// This run's mode; None before [`start_run`] and after [`end_run`].
#[flutter_rust_bridge::frb(sync)]
pub fn run_mode() -> Option<RunMode> {
    match &*run() {
        Run::Started { mode, .. } => Some(*mode),
        _ => None,
    }
}

/// Turning Top Secret Mode on or off: lock the open vault, forget the Secret Key and
/// refuse every library call until the app starts again.
#[flutter_rust_bridge::frb(sync)]
pub fn end_run() {
    *run() = Run::Ended;
    super::vault::lock();
    super::vault::forget_secret_key();
}

/// Whether this run is in Top Secret Mode. A run not started (or ended) counts as Top
/// Secret: refusing is the safe answer.
pub(crate) fn top_secret() -> bool {
    !matches!(
        &*run(),
        Run::Started {
            mode: RunMode::Everyday,
            ..
        }
    )
}

/// Called when a vault opens, with its mode: the run takes it, or refuses when the vault
/// is Top secret and this run already opened an everyday one.
pub(crate) fn vault_opening(top_secret: bool) -> Result<(), VaultError> {
    if opening(&mut run(), top_secret) {
        Ok(())
    } else {
        debug_line(|| "vault refused: Top secret after an everyday vault".into());
        Err(VaultError::RestartForMode)
    }
}

fn opening(run: &mut Run, top_secret: bool) -> bool {
    let next = if top_secret {
        RunMode::TopSecret
    } else {
        RunMode::Everyday
    };
    match run {
        Run::Started { mode, opened, .. }
            if !*opened || *mode == next || next == RunMode::Everyday =>
        {
            *mode = next;
            *opened = true;
            true
        }
        _ => false,
    }
}

/// `dir` as a path when it is this run's library folder; refused otherwise.
pub(crate) fn library_dir(dir: &str) -> Result<&Path, VaultError> {
    if allowed(&run(), Path::new(dir)) {
        Ok(Path::new(dir))
    } else {
        debug_line(|| "library call refused: not this run's folder".into());
        Err(VaultError::Storage)
    }
}

/// Refused in Top Secret Mode: anything that would be decoded in the app.
pub(crate) fn refuse_in_top_secret(what: &str) -> Result<(), VaultError> {
    if top_secret() {
        debug_line(|| format!("{what} refused: Top Secret Mode"));
        Err(VaultError::Storage)
    } else {
        Ok(())
    }
}

fn start(run: &mut Run, mode: RunMode, dir: PathBuf) -> bool {
    match run {
        Run::NotStarted => {
            *run = Run::Started {
                mode,
                dir,
                opened: false,
            };
            true
        }
        Run::Started { dir: d, .. } if *d == dir => choose(run, mode),
        _ => false,
    }
}

fn choose(run: &mut Run, next: RunMode) -> bool {
    match run {
        Run::Started { mode, opened, .. } if !*opened || *mode == next => {
            *mode = next;
            true
        }
        _ => false,
    }
}

fn allowed(run: &Run, dir: &Path) -> bool {
    matches!(run, Run::Started { dir: d, .. } if d == dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_runs_own_folder_is_allowed() {
        let lib = PathBuf::from("/support/library");
        let other = PathBuf::from("/support/private/library");
        let mut r = Run::NotStarted;
        assert!(!allowed(&r, &lib), "nothing before the run starts");
        assert!(start(&mut r, RunMode::Everyday, lib.clone()));
        assert!(allowed(&r, &lib));
        assert!(!allowed(&r, &other));
        assert!(!start(&mut r, RunMode::Everyday, other.clone()));
        assert!(!allowed(&r, &other));
    }

    #[test]
    fn the_mode_changes_only_until_a_vault_opens() {
        let lib = PathBuf::from("/support/library");
        let mut r = Run::NotStarted;
        assert!(start(&mut r, RunMode::Everyday, lib.clone()));
        assert!(choose(&mut r, RunMode::TopSecret));
        assert!(choose(&mut r, RunMode::Everyday));
        if let Run::Started { opened, .. } = &mut r {
            *opened = true;
        }
        assert!(
            !choose(&mut r, RunMode::TopSecret),
            "fixed once a vault opened"
        );
        assert!(
            choose(&mut r, RunMode::Everyday),
            "the same mode again is fine"
        );
        assert!(!start(&mut r, RunMode::TopSecret, lib.clone()));
    }

    #[test]
    fn a_top_secret_vault_after_an_everyday_one_needs_a_new_run() {
        let lib = PathBuf::from("/support/library");
        let mut r = Run::NotStarted;
        assert!(!opening(&mut r, false), "not before the run starts");
        assert!(start(&mut r, RunMode::TopSecret, lib));
        assert!(opening(&mut r, true));
        assert!(opening(&mut r, false), "Top secret, then everyday: fine");
        assert!(matches!(
            r,
            Run::Started {
                mode: RunMode::Everyday,
                ..
            }
        ));
        assert!(opening(&mut r, false));
        assert!(!opening(&mut r, true), "everyday, then Top secret: restart");
        r = Run::Ended;
        assert!(!opening(&mut r, false));
    }

    #[test]
    fn nothing_is_allowed_after_the_run_ends() {
        let lib = PathBuf::from("/support/library");
        let mut r = Run::NotStarted;
        assert!(start(&mut r, RunMode::TopSecret, lib.clone()));
        r = Run::Ended;
        assert!(!allowed(&r, &lib));
        assert!(!start(&mut r, RunMode::TopSecret, lib));
        assert!(!choose(&mut r, RunMode::Everyday));
    }
}
