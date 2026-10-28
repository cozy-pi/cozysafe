//! Checking a sync place for junk (docs/adr/0003-sync.md, "Checking for junk"; owner
//! 2026-10-28: "is there junk on my Google Drive?").
//!
//! The place lists its files once (names, sizes, when made; nothing is read), and
//! [`classify`] sorts each one by what this device knows locally ([`PlaceKnowledge`]):
//! no network, no keys, so it is tested on its own. Only files classed
//! [`Class::Orphan`] may ever be removed, and the rules lean the other way when in doubt:
//! a file this device cannot place for sure is [`Class::Unknown`], never an orphan.

use std::collections::{HashMap, HashSet};
use std::fmt;

use crate::{OpenVault, Result};

/// Content with no record that could use it counts as an orphan only once it is this
/// old: a device sending an item puts its content first and its record a moment later,
/// and a send cut short goes on at that device's next sync (files already there are
/// skipped, missing ones sent again).
pub const ORPHAN_AGE_MS: i64 = 24 * 60 * 60 * 1000;

/// One file in the place, under the vault's folder, as listed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlaceFile {
    /// Its path in the sync layout, after `<vault>/`: `records/<item>/<rev>`,
    /// `blobs/<item>.<rev>.<ext>`, `log/<device>/<n>`, `head/<device>` or
    /// `lock/<name>`. `None`: a file in the vault's folder that is not in the layout.
    pub path: Option<String>,
    pub size_bytes: u64,
    /// When the place says the file was made (ms since the Unix epoch), if it says.
    pub created_ms: Option<i64>,
}

/// What this device knows of one item id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Known {
    /// In the vault or in Recently deleted: its current revision, the revision whose
    /// content it uses, and the other revisions of it in this place whose record was
    /// read once (`sync_rev_clock`): revision → the revision whose content it uses.
    Present {
        rev: String,
        data_rev: String,
        other_revs: HashMap<String, String>,
    },
    /// Deleted for good on another device and kept here in Recently deleted.
    Held,
    /// Deleted for good (here, or told from elsewhere): the last revision this device
    /// had before the deletion ('' when not known), and whether this place was told
    /// (its files cleaned) already.
    Gone { last_rev: String, told: bool },
}

/// Everything [`classify`] needs from the vault, taken in one short look.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PlaceKnowledge {
    pub items: HashMap<String, Known>,
    /// Items in the vault, and in Recently deleted (held ones included).
    pub items_live: u32,
    pub items_trash: u32,
}

/// What a file in the place is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    /// A record or content file of an item the vault has (live, in Recently deleted, or
    /// held), at its current revision.
    Current,
    /// A record of another revision of an item the vault has, or content only such a
    /// revision uses. Kept for 30 days after it was superseded, then the daily tidy
    /// removes it (ADR 0003, "Old revisions").
    Old,
    /// A journal entry (`log/`).
    Journal,
    /// A device's head (`head/`).
    Head,
    /// The vault's lock (`lock/`).
    Lock,
    /// Junk that nothing can use: see [`classify`].
    Orphan,
    /// Not junk for sure: see [`classify`].
    Unknown,
    /// A file of an item deleted for good here whose deletion this place has not been
    /// told yet: the next sync removes it.
    Deleting,
}

/// A number of files and their size.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Tally {
    pub files: u32,
    pub bytes: u64,
}

impl Tally {
    fn add(&mut self, bytes: u64) {
        self.files += 1;
        self.bytes += bytes;
    }
}

/// What a place holds for a vault, counted by [`Class`]; no ids or names.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PlaceAudit {
    pub items_live: u32,
    pub items_trash: u32,
    /// Folders under the vault's folder, the vault's folder included (0 where the place
    /// has no folders of its own).
    pub folders: u32,
    pub current: Tally,
    pub old: Tally,
    pub journal: Tally,
    pub heads: Tally,
    pub locks: Tally,
    pub orphans: Tally,
    pub unknown: Tally,
    pub deleting: Tally,
}

impl PlaceAudit {
    /// Count `files` (with their [`classify`] classes) and `folders`.
    pub fn count(
        files: &[PlaceFile],
        classes: &[Class],
        folders: u32,
        known: &PlaceKnowledge,
    ) -> PlaceAudit {
        let mut a = PlaceAudit {
            items_live: known.items_live,
            items_trash: known.items_trash,
            folders,
            ..PlaceAudit::default()
        };
        for (f, c) in files.iter().zip(classes) {
            let t = match c {
                Class::Current => &mut a.current,
                Class::Old => &mut a.old,
                Class::Journal => &mut a.journal,
                Class::Head => &mut a.heads,
                Class::Lock => &mut a.locks,
                Class::Orphan => &mut a.orphans,
                Class::Unknown => &mut a.unknown,
                Class::Deleting => &mut a.deleting,
            };
            t.add(f.size_bytes);
        }
        a
    }

    /// One line for a log, counts and sizes only: "items 98 (3 in trash) · folders 170
    /// · current 290 (1.2 GB) · old 210 (4.1 MB) · journal 140 · heads 2 · locks 1 ·
    /// orphans 37 (80.0 MB) · unknown 0 · deleting 0".
    pub fn summary(&self) -> String {
        self.to_string()
    }
}

/// A size for people: B, KB, MB or GB (1000 each), one decimal above bytes.
fn size(bytes: u64) -> String {
    const UNITS: [&str; 3] = ["KB", "MB", "GB"];
    if bytes < 1000 {
        return format!("{bytes} B");
    }
    let mut v = bytes as f64 / 1000.0;
    let mut unit = 0;
    while v >= 1000.0 && unit + 1 < UNITS.len() {
        v /= 1000.0;
        unit += 1;
    }
    format!("{v:.1} {}", UNITS[unit])
}

impl fmt::Display for PlaceAudit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let sized = |t: &Tally| {
            if t.files == 0 {
                "0".to_owned()
            } else {
                format!("{} ({})", t.files, size(t.bytes))
            }
        };
        write!(
            f,
            "items {} ({} in trash) · folders {} · current {} · old {} · journal {} · \
             heads {} · locks {} · orphans {} · unknown {} · deleting {}",
            self.items_live + self.items_trash,
            self.items_trash,
            self.folders,
            sized(&self.current),
            sized(&self.old),
            self.journal.files,
            self.heads.files,
            self.locks.files,
            sized(&self.orphans),
            sized(&self.unknown),
            sized(&self.deleting),
        )
    }
}

/// A file's path, taken apart.
enum Parsed<'a> {
    Record {
        id: &'a str,
        rev: &'a str,
    },
    Content {
        id: &'a str,
        data_rev: &'a str,
        role: bool,
    },
    Journal,
    Head,
    Lock,
    Stray,
}

fn is_item_id(s: &str) -> bool {
    crate::id_name(s).is_some()
}

fn one(s: &str) -> bool {
    !s.is_empty() && !s.contains('/')
}

fn parse(path: Option<&str>) -> Parsed<'_> {
    let Some((top, tail)) = path.and_then(|p| p.split_once('/')) else {
        return Parsed::Stray;
    };
    match top {
        "records" => match tail.split_once('/') {
            Some((id, rev)) if is_item_id(id) && one(rev) => Parsed::Record { id, rev },
            _ => Parsed::Stray,
        },
        "blobs" if one(tail) => {
            let Some((id, rest)) = tail.split_once('.') else {
                return Parsed::Stray;
            };
            if !is_item_id(id) {
                return Parsed::Stray;
            }
            match rest.rsplit_once('.') {
                Some((data_rev, ext)) if !data_rev.is_empty() => Parsed::Content {
                    id,
                    data_rev,
                    role: ext == "data" || ext == "thumb",
                },
                _ => Parsed::Content {
                    id,
                    data_rev: rest,
                    role: false,
                },
            }
        }
        "log" => match tail.split_once('/') {
            Some((device, n)) if one(device) && one(n) => Parsed::Journal,
            _ => Parsed::Stray,
        },
        "head" if one(tail) => Parsed::Head,
        "lock" if one(tail) => Parsed::Lock,
        _ => Parsed::Stray,
    }
}

/// Sort each of `files` (one class per file, in order), by what this device knows.
///
/// The rules, first match wins:
///
/// - **Not in the layout** (a file in the vault's folder at no path the sync writes, or
///   with a malformed item id, like the `header.json` of the first syncs): orphan.
/// - **The same path a second time** (two copies of one file, which the next sync's
///   opening tidies itself): unknown.
/// - `log/`, `head/`, `lock/`: journal, head, lock. Never removed here.
/// - A **record** (`records/<item>/<rev>`) of an item the vault has: current when it is
///   the item's revision, otherwise old (this also counts a newer revision another device
///   made and this one has not taken yet). Of a held item: current.
/// - **Content** (`blobs/<item>.<rev>.<ext>`) of an item the vault has: current when it
///   is the content the item's revision uses; old when another revision uses it (a
///   record named `<rev>` is in the place, or a revision whose record was read uses it);
///   orphan when every record of the item in the place is one this device has read and
///   none uses it, and the file is older than [`ORPHAN_AGE_MS`]; otherwise unknown. Of a
///   held item: current. An unexpected `<ext>`: unknown.
/// - Files of an item **deleted for good here, the place not told yet**: deleting (the
///   next sync removes them).
/// - Files of an item **deleted for good, the place told**: its record at the last
///   revision this device had (older than the deletion; the same one the sync drops
///   unread) is an orphan; any other record may be a revision made after the deletion,
///   which brings the item back: unknown. Content is an orphan when no record but such
///   orphans is left for the item and the file is older than [`ORPHAN_AGE_MS`];
///   otherwise unknown.
/// - Files of an item **this device has never heard of** (made on another device and
///   not taken here yet, or sent by a device whose journal entry is still to come): a
///   record is unknown, always. Content is an orphan only when the place holds no record
///   of that item at all and the file is older than [`ORPHAN_AGE_MS`] (records go up
///   after their content, so no device can use it; the device that sent it still has it
///   and sends it again should it ever send the record); otherwise unknown.
pub fn classify(files: &[PlaceFile], known: &PlaceKnowledge, now_ms: i64) -> Vec<Class> {
    let parsed: Vec<Parsed<'_>> = files.iter().map(|f| parse(f.path.as_deref())).collect();
    // Every record in the place, by item.
    let mut records: HashMap<&str, HashSet<&str>> = HashMap::new();
    for p in &parsed {
        if let Parsed::Record { id, rev } = p {
            records.entry(id).or_default().insert(rev);
        }
    }
    let aged = |f: &PlaceFile| f.created_ms.is_some_and(|t| now_ms - t >= ORPHAN_AGE_MS);
    let mut seen: HashSet<&str> = HashSet::new();
    files
        .iter()
        .zip(&parsed)
        .map(|(f, p)| {
            if let Some(path) = f.path.as_deref() {
                if !matches!(p, Parsed::Stray) && !seen.insert(path) {
                    return Class::Unknown;
                }
            }
            match *p {
                Parsed::Stray => Class::Orphan,
                Parsed::Journal => Class::Journal,
                Parsed::Head => Class::Head,
                Parsed::Lock => Class::Lock,
                Parsed::Record { id, rev } => match known.items.get(id) {
                    Some(Known::Present { rev: current, .. }) if current == rev => Class::Current,
                    Some(Known::Present { .. }) => Class::Old,
                    Some(Known::Held) => Class::Current,
                    Some(Known::Gone { told: false, .. }) => Class::Deleting,
                    Some(Known::Gone { last_rev, .. })
                        if !last_rev.is_empty() && last_rev == rev =>
                    {
                        Class::Orphan
                    }
                    Some(Known::Gone { .. }) | None => Class::Unknown,
                },
                Parsed::Content { id, data_rev, role } => {
                    let theirs = records.get(id);
                    match known.items.get(id) {
                        Some(Known::Held) => Class::Current,
                        Some(Known::Gone { told: false, .. }) => Class::Deleting,
                        _ if !role => Class::Unknown,
                        Some(Known::Present {
                            rev,
                            data_rev: current,
                            other_revs,
                        }) => {
                            if current == data_rev {
                                Class::Current
                            } else if theirs.is_some_and(|r| r.contains(data_rev))
                                || other_revs.values().any(|d| d == data_rev)
                            {
                                Class::Old
                            } else if theirs
                                .into_iter()
                                .flatten()
                                .all(|r| *r == rev.as_str() || other_revs.contains_key(*r))
                                && aged(f)
                            {
                                Class::Orphan
                            } else {
                                Class::Unknown
                            }
                        }
                        Some(Known::Gone { last_rev, .. }) => {
                            let only_orphans = theirs
                                .into_iter()
                                .flatten()
                                .all(|r| !last_rev.is_empty() && *r == last_rev.as_str());
                            if only_orphans && aged(f) {
                                Class::Orphan
                            } else {
                                Class::Unknown
                            }
                        }
                        None => {
                            if theirs.is_none() && aged(f) {
                                Class::Orphan
                            } else {
                                Class::Unknown
                            }
                        }
                    }
                }
            }
        })
        .collect()
}

/// The order orphans are removed in: records before content (a device catching up then
/// finds a record gone, never a record whose content is gone), the rest last.
pub fn removal_rank(file: &PlaceFile) -> u8 {
    match parse(file.path.as_deref()) {
        Parsed::Record { .. } => 0,
        Parsed::Content { .. } => 1,
        _ => 2,
    }
}

impl OpenVault {
    /// What this device knows about the items, for checking `place` ([`classify`]):
    /// every item in the vault and in Recently deleted with its revision, held items,
    /// and deletions for good with whether `place` was told.
    pub fn place_knowledge(&self, place: &str) -> Result<PlaceKnowledge> {
        let mut k = PlaceKnowledge::default();
        for deleted in [false, true] {
            for row in self.index.rows(deleted)? {
                let r = self.open_record(&row.id, &row.sealed_record)?;
                let other_revs = self
                    .index
                    .rev_clocks(place, &row.id)?
                    .into_iter()
                    .filter(|(rev, _, _)| *rev != r.rev)
                    .map(|(rev, _, data_rev)| (rev, data_rev))
                    .collect();
                k.items.insert(
                    row.id,
                    Known::Present {
                        rev: r.rev,
                        data_rev: r.data_rev,
                        other_revs,
                    },
                );
                if deleted {
                    k.items_trash += 1;
                } else {
                    k.items_live += 1;
                }
            }
        }
        for m in self.held()? {
            if let std::collections::hash_map::Entry::Vacant(e) = k.items.entry(m.id) {
                e.insert(Known::Held);
                k.items_trash += 1;
            }
        }
        let unsent: HashSet<String> = self
            .index
            .gone_unsent(place)?
            .into_iter()
            .map(|(id, _, _)| id)
            .collect();
        for (id, _, last_rev) in self.index.all_gone()? {
            let told = !unsent.contains(&id);
            k.items.entry(id).or_insert(Known::Gone { last_rev, told });
        }
        Ok(k)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::tests::{note, two};
    use crate::sync::Remote;
    use std::path::Path;

    const OLD: Option<i64> = Some(0);
    const NOW: i64 = 100 * ORPHAN_AGE_MS;

    fn file(path: &str, size: u64, created_ms: Option<i64>) -> PlaceFile {
        PlaceFile {
            path: Some(path.to_owned()),
            size_bytes: size,
            created_ms,
        }
    }

    fn id(c: char) -> String {
        c.to_string().repeat(32)
    }

    /// Every file of the vault in a folder place, as a listing would give them, all made
    /// long ago.
    fn listing(root: &Path, vault: &str) -> Vec<PlaceFile> {
        fn walk(dir: &Path, base: &Path, out: &mut Vec<PlaceFile>) {
            for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, base, out);
                } else {
                    let rest = p
                        .strip_prefix(base)
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/");
                    out.push(PlaceFile {
                        path: Some(rest),
                        size_bytes: e.metadata().unwrap().len(),
                        created_ms: OLD,
                    });
                }
            }
        }
        let mut out = Vec::new();
        walk(&root.join(vault), &root.join(vault), &mut out);
        out.sort_by(|a, b| a.path.cmp(&b.path));
        out
    }

    fn classes_of(files: &[PlaceFile], classes: &[Class], prefix: &str) -> Vec<Class> {
        files
            .iter()
            .zip(classes)
            .filter(|(f, _)| f.path.as_deref().is_some_and(|p| p.starts_with(prefix)))
            .map(|(_, c)| *c)
            .collect()
    }

    #[test]
    fn content_of_an_item_deleted_for_good_is_an_orphan() {
        let gone = id('a');
        let mut known = PlaceKnowledge::default();
        known.items.insert(
            gone.clone(),
            Known::Gone {
                last_rev: "r1".into(),
                told: true,
            },
        );
        let files = vec![
            file(&format!("records/{gone}/r1"), 300, OLD),
            file(&format!("blobs/{gone}.r1.data"), 5000, OLD),
            file(&format!("blobs/{gone}.r1.thumb"), 700, OLD),
            // Made a moment ago: maybe a send under way; not yet.
            file(&format!("blobs/{gone}.r9.data"), 10, Some(NOW - 1000)),
        ];
        let c = classify(&files, &known, NOW);
        assert_eq!(
            c,
            [Class::Orphan, Class::Orphan, Class::Orphan, Class::Unknown]
        );
        let a = PlaceAudit::count(&files, &c, 0, &known);
        assert_eq!(
            a.orphans,
            Tally {
                files: 3,
                bytes: 6000
            }
        );
        // Another revision of it, perhaps made after the deletion: nothing of it is junk
        // for sure.
        let mut more = files.clone();
        more.push(file(&format!("records/{gone}/r2"), 300, OLD));
        let c = classify(&more, &known, NOW);
        assert_eq!(c[0], Class::Orphan);
        assert!(c[1..].iter().all(|c| *c == Class::Unknown));
        // Not told yet: the next sync cleans it, nothing here.
        known.items.insert(
            gone.clone(),
            Known::Gone {
                last_rev: "r1".into(),
                told: false,
            },
        );
        assert!(classify(&files, &known, NOW)
            .iter()
            .all(|c| *c == Class::Deleting));
    }

    #[test]
    fn an_item_not_received_yet_is_not_an_orphan() {
        let new = id('b');
        let known = PlaceKnowledge::default();
        let files = vec![
            file(&format!("records/{new}/r1"), 300, OLD),
            file(&format!("blobs/{new}.r1.data"), 5000, OLD),
        ];
        assert_eq!(
            classify(&files, &known, NOW),
            [Class::Unknown, Class::Unknown]
        );
        // Content with no record of its item anywhere, long ago: no device can use it.
        let lone = id('c');
        let files = vec![
            file(&format!("blobs/{lone}.r1.data"), 5000, OLD),
            file(&format!("blobs/{lone}.r1.thumb"), 50, Some(NOW - 60_000)),
            file(&format!("blobs/{lone}.r1.thumb"), 50, None),
        ];
        assert_eq!(
            classify(&files, &known, NOW),
            [Class::Orphan, Class::Unknown, Class::Unknown]
        );
    }

    #[test]
    fn files_out_of_the_layout_are_orphans_and_the_rest_is_kept() {
        let known = PlaceKnowledge::default();
        let files = vec![
            PlaceFile {
                path: None,
                size_bytes: 9,
                created_ms: None,
            },
            file("header.json", 9, None),
            file("records/not-an-id/r1", 9, None),
            file("log/dev1/7", 9, None),
            file("head/dev1", 9, None),
            file("lock/1-abc.json", 9, None),
            file(&format!("blobs/{}.r1.odd", id('d')), 9, OLD),
        ];
        assert_eq!(
            classify(&files, &known, NOW),
            [
                Class::Orphan,
                Class::Orphan,
                Class::Orphan,
                Class::Journal,
                Class::Head,
                Class::Lock,
                Class::Unknown,
            ]
        );
    }

    #[test]
    fn an_item_held_from_another_devices_deletion_is_current() {
        let held = id('9');
        let mut known = PlaceKnowledge::default();
        known.items.insert(held.clone(), Known::Held);
        let files = vec![
            file(&format!("records/{held}/r1"), 1, OLD),
            file(&format!("blobs/{held}.r1.data"), 1, OLD),
        ];
        assert_eq!(
            classify(&files, &known, NOW),
            [Class::Current, Class::Current]
        );
    }

    #[test]
    fn a_second_copy_of_a_file_is_unknown() {
        let it = id('e');
        let mut known = PlaceKnowledge::default();
        known.items.insert(
            it.clone(),
            Known::Present {
                rev: "r1".into(),
                data_rev: "r1".into(),
                other_revs: HashMap::new(),
            },
        );
        let f = file(&format!("blobs/{it}.r1.data"), 9, OLD);
        assert_eq!(
            classify(&[f.clone(), f], &known, NOW),
            [Class::Current, Class::Unknown]
        );
    }

    #[test]
    fn content_no_revision_uses_is_an_orphan_only_when_every_revision_is_known() {
        let it = id('f');
        let mut other_revs = HashMap::new();
        other_revs.insert("r2".to_owned(), "r1".to_owned());
        let mut known = PlaceKnowledge::default();
        known.items.insert(
            it.clone(),
            Known::Present {
                rev: "r3".into(),
                data_rev: "r3".into(),
                other_revs,
            },
        );
        let files = vec![
            file(&format!("records/{it}/r3"), 1, OLD),
            file(&format!("records/{it}/r2"), 1, OLD),
            file(&format!("blobs/{it}.r3.data"), 1, OLD),
            // r2 (old) uses r1's content, whose record went.
            file(&format!("blobs/{it}.r1.data"), 1, OLD),
            // Used by nobody the place holds.
            file(&format!("blobs/{it}.r0.data"), 1, OLD),
        ];
        assert_eq!(
            classify(&files, &known, NOW),
            [
                Class::Current,
                Class::Old,
                Class::Current,
                Class::Old,
                Class::Orphan
            ]
        );
        // A record this device never read: it may use r0's content.
        let mut more = files.clone();
        more.push(file(&format!("records/{it}/r4"), 1, OLD));
        assert_eq!(classify(&more, &known, NOW)[4], Class::Unknown);
    }

    #[test]
    fn a_vault_in_a_place_is_counted_by_what_its_files_are() {
        let t = two();
        let live = note(&t.a, "Live", "kept");
        let edited = note(&t.a, "Edited", "first");
        let trashed = note(&t.a, "Trashed", "in the bin");
        let gone = note(&t.a, "Gone", "deleted for good");
        t.a.sync(&t.cloud).unwrap();
        t.a.replace_item(&edited, "Edited", &b"second"[..]).unwrap();
        t.a.trash_item(&trashed, 1).unwrap();
        t.a.sync(&t.cloud).unwrap();
        // B has not synced: everything of A is unknown to it, never an orphan.
        let vault = t.a.id.clone();
        let root = t._dirs.2.path();
        let files = listing(root, &vault);
        let b = t.b.place_knowledge(&t.cloud.key()).unwrap();
        assert!(classify(&files, &b, NOW).iter().all(|c| matches!(
            c,
            Class::Unknown | Class::Journal | Class::Head | Class::Lock
        )));

        // A deletes one for good: until the sync, its files are being deleted.
        t.a.delete_item(&gone).unwrap();
        let k = t.a.place_knowledge(&t.cloud.key()).unwrap();
        assert_eq!((k.items_live, k.items_trash), (2, 1));
        let c = classify(&files, &k, NOW);
        assert!(classes_of(&files, &c, &format!("records/{gone}"))
            .iter()
            .all(|c| *c == Class::Deleting));
        t.a.sync(&t.cloud).unwrap();

        // Junk a cut-short clean would leave: the deleted item's content put back.
        let blobs = root.join(&vault).join("blobs");
        std::fs::write(blobs.join(format!("{gone}.zz.data")), b"left over").unwrap();
        std::fs::write(root.join(&vault).join("header.json"), b"{}").unwrap();
        let files = listing(root, &vault);
        let k = t.a.place_knowledge(&t.cloud.key()).unwrap();
        let c = classify(&files, &k, NOW);
        let a = PlaceAudit::count(&files, &c, 0, &k);
        assert_eq!(a.orphans.files, 2, "{a}");
        assert_eq!(a.unknown.files, 0, "{a}");
        // Live items are current; an item in the trash too (moving it there made a
        // revision: the one before is old); the edited one's first revision and its
        // content are old.
        assert_eq!(
            classes_of(&files, &c, &format!("records/{live}")),
            [Class::Current]
        );
        for it in [&trashed, &edited] {
            let mut both = classes_of(&files, &c, &format!("records/{it}"));
            both.sort_by_key(|c| *c == Class::Old);
            assert_eq!(both, [Class::Current, Class::Old]);
        }
        let mut contents = classes_of(&files, &c, &format!("blobs/{edited}"));
        contents.sort_by_key(|c| *c == Class::Old);
        assert_eq!(contents, [Class::Current, Class::Old]);
        assert_eq!(a.old.files, 3, "{a}"); // the trashed note's first revision too
        assert_eq!(a.journal.files, 3, "{a}");
        assert_eq!(a.heads.files, 1, "{a}");
        assert_eq!(a.locks.files, 1, "{a}");
        assert!(a
            .summary()
            .starts_with("items 3 (1 in trash) · folders 0 · current "));
    }

    #[test]
    fn the_summary_says_counts_and_sizes_only() {
        let a = PlaceAudit {
            items_live: 95,
            items_trash: 3,
            folders: 170,
            current: Tally {
                files: 290,
                bytes: 1_234_000_000,
            },
            old: Tally {
                files: 210,
                bytes: 4_100_000,
            },
            journal: Tally {
                files: 140,
                bytes: 1,
            },
            heads: Tally { files: 2, bytes: 1 },
            locks: Tally { files: 1, bytes: 1 },
            orphans: Tally {
                files: 37,
                bytes: 80_000_000,
            },
            unknown: Tally::default(),
            deleting: Tally {
                files: 1,
                bytes: 512,
            },
        };
        assert_eq!(
            a.summary(),
            "items 98 (3 in trash) · folders 170 · current 290 (1.2 GB) · old 210 (4.1 MB) · \
             journal 140 · heads 2 · locks 1 · orphans 37 (80.0 MB) · unknown 0 · deleting 1 (512 B)"
        );
    }
}
