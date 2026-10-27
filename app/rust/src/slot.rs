//! Where the open vault lives in memory, and the handle a sync keeps on it through a
//! lock (owner 2026-10-26: "even if the vault locks, the sync must keep running").
//!
//! The UI reaches the vault only through the slot. Locking empties the slot at once,
//! even while a sync works with the vault: the sync keeps its own [`Hold`], which no UI
//! call can reach, and the vault is dropped (its keys wiped) the moment that hold ends.
//! Opening the same vault again while the sync still runs puts the held one back, so
//! there is never a second copy writing the same index.

use std::sync::{Arc, Mutex, MutexGuard, Weak};

/// What the slot needs to know of the vault it keeps.
pub(crate) trait Kept {
    /// What the UI reads without waiting for a sync to let go: plain facts, no secrets.
    type Glance: Clone;
    fn id(&self) -> &str;
    fn glance(&self) -> Self::Glance;
}

struct Entry<V: Kept> {
    id: String,
    vault: Arc<Mutex<V>>,
    glance: V::Glance,
}

pub(crate) struct Slot<V: Kept> {
    /// The vault the UI may use; empty while locked.
    open: Mutex<Option<Entry<V>>>,
    /// The vault a running sync holds (its id), to hand back if it opens again meanwhile.
    held: Mutex<Option<(String, Weak<Mutex<V>>)>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

impl<V: Kept> Slot<V> {
    pub(crate) const fn new() -> Self {
        Slot {
            open: Mutex::new(None),
            held: Mutex::new(None),
        }
    }

    /// Put a vault just opened in the UI's reach. If a sync still running behind the lock
    /// holds this same vault, that one comes back instead and `vault` is dropped.
    pub(crate) fn put(&self, vault: V) -> V::Glance {
        let glance = vault.glance();
        let id = vault.id().to_owned();
        let held = lock(&self.held)
            .as_ref()
            .filter(|(held_id, _)| *held_id == id)
            .and_then(|(_, w)| w.upgrade());
        let vault = match held {
            Some(shared) => {
                drop(vault);
                shared
            }
            None => Arc::new(Mutex::new(vault)),
        };
        let old = lock(&self.open).replace(Entry {
            id,
            vault,
            glance: glance.clone(),
        });
        drop(old);
        glance
    }

    /// Lock: the UI can no longer reach the vault. Nobody else holding it, it is dropped
    /// now; a running sync's [`Hold`] keeps it until the sync ends.
    pub(crate) fn clear(&self) {
        let old = lock(&self.open).take();
        drop(old);
    }

    /// The id of the vault open now.
    pub(crate) fn open_id(&self) -> Option<String> {
        lock(&self.open).as_ref().map(|e| e.id.clone())
    }

    fn current(&self) -> Option<Arc<Mutex<V>>> {
        lock(&self.open).as_ref().map(|e| e.vault.clone())
    }

    fn is_current(&self, shared: &Arc<Mutex<V>>) -> bool {
        lock(&self.open)
            .as_ref()
            .is_some_and(|e| Arc::ptr_eq(&e.vault, shared))
    }

    /// Run `f` with the open vault; None when locked. A call that waited for a sync to
    /// let go and finds the vault locked meanwhile gets None too.
    pub(crate) fn with<T>(&self, f: impl FnOnce(&V) -> T) -> Option<T> {
        let shared = self.current()?;
        let v = lock(&shared);
        if !self.is_current(&shared) {
            return None;
        }
        Some(f(&v))
    }

    /// [`Slot::with`] for a change to what [`Kept::glance`] shows (PIN, Face ID, name…).
    pub(crate) fn change<T>(&self, f: impl FnOnce(&mut V) -> T) -> Option<T> {
        let shared = self.current()?;
        let mut v = lock(&shared);
        if !self.is_current(&shared) {
            return None;
        }
        let out = f(&mut v);
        let glance = v.glance();
        if let Some(e) = lock(&self.open)
            .as_mut()
            .filter(|e| Arc::ptr_eq(&e.vault, &shared))
        {
            e.glance = glance;
        }
        Some(out)
    }

    /// What the UI shows of the open vault, without waiting: fresh when the vault is
    /// free, as of its last change while a sync works with it.
    pub(crate) fn glance(&self) -> Option<V::Glance> {
        let (shared, cached) = {
            let g = lock(&self.open);
            let e = g.as_ref()?;
            (e.vault.clone(), e.glance.clone())
        };
        let fresh = shared.try_lock().ok().map(|v| v.glance());
        Some(fresh.unwrap_or(cached))
    }

    /// A handle on the open vault for a sync, from its start to its end, that the lock
    /// does not take away. None when locked.
    pub(crate) fn hold(&self) -> Option<Hold<'_, V>> {
        let (id, vault) = {
            let g = lock(&self.open);
            let e = g.as_ref()?;
            (e.id.clone(), e.vault.clone())
        };
        *lock(&self.held) = Some((id, Arc::downgrade(&vault)));
        Some(Hold { slot: self, vault })
    }
}

/// A running sync's own handle on the vault (see the module). Dropping it ends the hold;
/// the vault goes with it unless it is open in the UI.
pub(crate) struct Hold<'a, V: Kept> {
    slot: &'a Slot<V>,
    vault: Arc<Mutex<V>>,
}

impl<V: Kept> Hold<'_, V> {
    /// Run `f` with the held vault, locked or not.
    pub(crate) fn with<T>(&self, f: impl FnOnce(&V) -> T) -> T {
        f(&lock(&self.vault))
    }
}

impl<V: Kept> Drop for Hold<'_, V> {
    fn drop(&mut self) {
        let mut held = lock(&self.slot.held);
        if held
            .as_ref()
            .is_some_and(|(_, w)| std::ptr::eq(w.as_ptr(), Arc::as_ptr(&self.vault)))
        {
            *held = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::thread;

    /// A stand-in vault that counts how many copies are alive and what was written.
    struct Fake {
        id: String,
        alive: Arc<AtomicUsize>,
        writes: Arc<AtomicUsize>,
    }

    impl Fake {
        fn new(id: &str, alive: &Arc<AtomicUsize>, writes: &Arc<AtomicUsize>) -> Self {
            alive.fetch_add(1, Ordering::SeqCst);
            Fake {
                id: id.to_owned(),
                alive: alive.clone(),
                writes: writes.clone(),
            }
        }
        fn write(&self) {
            self.writes.fetch_add(1, Ordering::SeqCst);
        }
    }

    impl Drop for Fake {
        fn drop(&mut self) {
            self.alive.fetch_sub(1, Ordering::SeqCst);
        }
    }

    impl Kept for Fake {
        type Glance = String;
        fn id(&self) -> &str {
            &self.id
        }
        fn glance(&self) -> String {
            self.id.clone()
        }
    }

    fn counters() -> (Arc<AtomicUsize>, Arc<AtomicUsize>) {
        (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)))
    }

    /// A sync on another thread: holds the vault, writes once, waits for `go`, writes
    /// again, ends.
    fn sync_thread(
        slot: &'static Slot<Fake>,
        started: mpsc::Sender<()>,
        go: mpsc::Receiver<()>,
    ) -> thread::JoinHandle<bool> {
        thread::spawn(move || {
            let Some(hold) = slot.hold() else {
                return false;
            };
            hold.with(Fake::write);
            started.send(()).unwrap();
            go.recv().unwrap();
            hold.with(Fake::write);
            true
        })
    }

    #[test]
    fn a_sync_finishes_behind_the_lock_and_the_vault_goes_with_it() {
        static SLOT: Slot<Fake> = Slot::new();
        let (alive, writes) = counters();
        SLOT.put(Fake::new("v1", &alive, &writes));
        let (started_tx, started) = mpsc::channel();
        let (go, go_rx) = mpsc::channel();
        let sync = sync_thread(&SLOT, started_tx, go_rx);
        started.recv().unwrap();

        SLOT.clear();
        // Locked for the UI: nothing reads, nothing changes, nothing to glance at.
        assert!(SLOT.with(|_| ()).is_none());
        assert!(SLOT.change(|_| ()).is_none());
        assert!(SLOT.glance().is_none());
        assert!(SLOT.open_id().is_none());
        assert!(SLOT.hold().is_none());
        // ...but the sync still has it.
        assert_eq!(alive.load(Ordering::SeqCst), 1);

        go.send(()).unwrap();
        assert!(sync.join().unwrap());
        assert_eq!(
            writes.load(Ordering::SeqCst),
            2,
            "the sync wrote after the lock"
        );
        assert_eq!(alive.load(Ordering::SeqCst), 0, "dropped as the sync ended");
        assert!(lock(&SLOT.held).is_none());
    }

    #[test]
    fn opening_the_same_vault_during_the_sync_reuses_the_held_one() {
        static SLOT: Slot<Fake> = Slot::new();
        let (alive, writes) = counters();
        SLOT.put(Fake::new("v1", &alive, &writes));
        let (started_tx, started) = mpsc::channel();
        let (go, go_rx) = mpsc::channel();
        let sync = sync_thread(&SLOT, started_tx, go_rx);
        started.recv().unwrap();
        SLOT.clear();

        // The person opens it again: a second copy comes from disk and is let go at once.
        assert_eq!(SLOT.put(Fake::new("v1", &alive, &writes)), "v1");
        assert_eq!(alive.load(Ordering::SeqCst), 1, "one copy, the held one");
        let held = lock(&SLOT.held)
            .as_ref()
            .and_then(|(_, w)| w.upgrade())
            .unwrap();
        assert!(SLOT.is_current(&held));
        drop(held);

        go.send(()).unwrap();
        assert!(sync.join().unwrap());
        // Open again for the UI, still the one vault.
        assert_eq!(alive.load(Ordering::SeqCst), 1);
        assert_eq!(SLOT.with(|v| v.writes.load(Ordering::SeqCst)), Some(2));
        SLOT.clear();
        assert_eq!(alive.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn another_vault_opened_during_the_sync_is_its_own() {
        static SLOT: Slot<Fake> = Slot::new();
        let (alive, writes) = counters();
        SLOT.put(Fake::new("v1", &alive, &writes));
        let (started_tx, started) = mpsc::channel();
        let (go, go_rx) = mpsc::channel();
        let sync = sync_thread(&SLOT, started_tx, go_rx);
        started.recv().unwrap();
        SLOT.clear();

        SLOT.put(Fake::new("v2", &alive, &writes));
        assert_eq!(alive.load(Ordering::SeqCst), 2);
        go.send(()).unwrap();
        assert!(sync.join().unwrap());
        assert_eq!(
            alive.load(Ordering::SeqCst),
            1,
            "the held one went, v2 stays"
        );
        assert_eq!(SLOT.open_id().as_deref(), Some("v2"));
        SLOT.clear();
    }

    #[test]
    fn a_ui_call_waiting_on_the_sync_finds_the_vault_locked() {
        static SLOT: Slot<Fake> = Slot::new();
        let (alive, writes) = counters();
        SLOT.put(Fake::new("v1", &alive, &writes));
        let hold = SLOT.hold().unwrap();
        let (busy_tx, busy) = mpsc::channel();
        let (go, go_rx) = mpsc::channel::<()>();
        let (asked_tx, asked) = mpsc::channel();
        // The sync works with the vault (its lock taken) while the UI asks for it.
        let held = &hold;
        let ui = thread::scope(|s| {
            s.spawn(move || {
                held.with(|_| {
                    busy_tx.send(()).unwrap();
                    go_rx.recv().unwrap();
                })
            });
            busy.recv().unwrap();
            let ui = s.spawn(move || {
                asked_tx.send(()).unwrap();
                SLOT.with(Fake::write)
            });
            asked.recv().unwrap();
            // While it waits, the glance does not block.
            assert_eq!(SLOT.glance().as_deref(), Some("v1"));
            SLOT.clear();
            go.send(()).unwrap();
            ui.join().unwrap()
        });
        assert!(ui.is_none());
        assert_eq!(writes.load(Ordering::SeqCst), 0);
        drop(hold);
        assert_eq!(alive.load(Ordering::SeqCst), 0);
    }
}
