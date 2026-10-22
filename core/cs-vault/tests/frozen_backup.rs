//! A backup made by Cozy Safe on 2026-10-22 (0.1.30, record format 2), kept in the repo.
//! Every later version must still restore it and read every item exactly: people's
//! backups are files we never see again (docs/decisions.md, before the public beta).
//!
//! Never regenerate the fixture to make this pass. A new format gets a new fixture
//! next to this one; this one stays. `make_fixture` wrote it once:
//! `cargo test -p cs-vault --test frozen_backup -- --ignored make_fixture`.

use std::path::PathBuf;

use cs_crypto::kdf::KdfParams;
use cs_crypto::SecretKey;
use cs_vault::backup::{export, import};
use cs_vault::items::NewItem;
use cs_vault::Library;

const FIXTURE: &str = "tests/fixtures/backup-2026-10-22.bin";
const PASSWORD: &str = "orange kettle whispers at dawn 77";
/// Test-only parameters so the test runs fast; they are stored in the backup.
const FAST: KdfParams = KdfParams {
    m_kib: 64,
    t: 1,
    p: 1,
};

fn key() -> SecretKey {
    SecretKey::from_bytes([7; 32])
}

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE)
}

const PHOTO: &[u8] = b"\xff\xd8 not really a jpeg, but fixed bytes";
const NOTE: &str = "Wifi\npassword: correct horse battery staple";
const AUDIO: &[u8] = b"m4a bytes";
const FILE: &[u8] = b"%PDF-1.4 fixed bytes";

#[test]
#[ignore]
fn make_fixture() {
    let dir = tempfile::tempdir().unwrap();
    let lib = Library::open_or_create(dir.path(), FAST, key()).unwrap();
    let v = lib.create_vault("Home", PASSWORD).unwrap();
    let add = |kind, name, mime, created_ms, content: &[u8], thumb: Option<&[u8]>| {
        v.add_item(NewItem {
            kind,
            name,
            mime,
            created_ms,
            content,
            thumbnail: thumb,
        })
        .unwrap()
    };
    let tag = v.create_tag("Travel", 1_000).unwrap();
    let photo = add(
        "photo",
        "IMG_0001.HEIC",
        "image/heic",
        2_000,
        PHOTO,
        Some(b"thumb"),
    );
    add("note", "Wifi", "text/plain", 3_000, NOTE.as_bytes(), None);
    let audio = add("audio", "Meeting.m4a", "audio/mp4", 4_000, AUDIO, None);
    add("file", "passport.pdf", "application/pdf", 5_000, FILE, None);
    let gone = add("file", "old.txt", "text/plain", 6_000, b"old", None);
    v.set_tag(&photo.id, &tag.id, true).unwrap();
    v.set_duration(&audio.id, 768_000).unwrap();
    v.trash_item(&gone.id, 7_000).unwrap();
    let mut out = Vec::new();
    export(dir.path(), &mut out).unwrap();
    std::fs::write(fixture(), out).unwrap();
}

#[test]
fn a_backup_from_2026_10_22_still_restores() {
    let bytes = std::fs::read(fixture()).expect("fixture missing");
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("library");
    import(&bytes[..], &target).unwrap();
    let v = Library::open_or_create(&target, FAST, key())
        .unwrap()
        .unlock(PASSWORD)
        .unwrap()
        .expect("the password opens it");

    let items = v.items().unwrap();
    let by = |name: &str| {
        items
            .iter()
            .find(|i| i.name == name)
            .unwrap_or_else(|| panic!("{name} missing"))
            .clone()
    };
    let read = |id: &str| {
        let mut out = Vec::new();
        v.read_item(id, &mut out).unwrap();
        out
    };

    let tag = by("Travel");
    assert_eq!(tag.kind, "tag");
    let photo = by("IMG_0001.HEIC");
    assert_eq!(
        (photo.kind.as_str(), photo.mime.as_str(), photo.created_ms),
        ("photo", "image/heic", 2_000)
    );
    assert_eq!(read(&photo.id), PHOTO);
    assert_eq!(
        v.read_thumbnail(&photo.id).unwrap().as_deref(),
        Some(&b"thumb"[..])
    );
    assert_eq!(photo.tag_ids, vec![tag.id.clone()]);
    assert_eq!(read(&by("Wifi").id), NOTE.as_bytes());
    let audio = by("Meeting.m4a");
    assert_eq!(audio.duration_ms, Some(768_000));
    assert_eq!(read(&audio.id), AUDIO);
    assert_eq!(read(&by("passport.pdf").id), FILE);
    assert_eq!(items.len(), 5, "the trashed file is not among the items");
    let trash = v.trashed().unwrap();
    assert_eq!(trash.len(), 1);
    assert_eq!(
        (trash[0].name.as_str(), trash[0].deleted_ms),
        ("old.txt", Some(7_000))
    );
}
