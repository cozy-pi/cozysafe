//! docs/data-model.md and docs/cryptography.md say what the code does (owner
//! 2026-11-06: readable docs, kept current). These tests fail when a storage constant,
//! an item kind, an `ItemRecord` field, a `vault.db` table or column, or a key constant
//! changes and the docs do not.

use crate::format::{ItemRecord, Summary};
use crate::json::{self, Value};

const DATA_MODEL: &str = include_str!("../../../docs/data-model.md");
const CRYPTOGRAPHY: &str = include_str!("../../../docs/cryptography.md");

/// The value cell of the row whose first cell is `name` in a doc's constants table (the
/// last table of each doc; an earlier table may name the same constant).
fn row<'d>(doc: &'d str, name: &str) -> &'d str {
    let first = format!("| {name} |");
    let line = doc
        .lines()
        .rev()
        .find(|l| l.starts_with(&first))
        .unwrap_or_else(|| panic!("no row {name} in the constants table"));
    line[first.len()..].split('|').next().unwrap().trim()
}

fn says(doc: &str, name: &str, value: &str) {
    assert_eq!(row(doc, name), value, "{name} in the docs");
}

#[test]
fn data_model_constants() {
    let d = DATA_MODEL;
    says(
        d,
        "`SCHEMA_VERSION`",
        &format!("`{}`", crate::db::SCHEMA_VERSION),
    );
    says(
        d,
        "`RECORD_FORMAT`",
        &format!("`{}`", crate::items::RECORD_FORMAT),
    );
    says(
        d,
        "`entries::VERSION`",
        &format!("`{}`", crate::entries::VERSION),
    );
    says(
        d,
        "`TRASH_DAYS`",
        &format!("`{}`", crate::items::TRASH_DAYS),
    );
    says(
        d,
        "`INDEX_FILE`",
        &format!("`\"{}\"`", crate::db::INDEX_FILE),
    );
    says(
        d,
        "`HISTORY_DIR`",
        &format!("`\"{}\"`", crate::history::HISTORY_DIR),
    );
}

#[test]
fn every_kind_is_in_the_data_model() {
    use crate::items::kind::*;
    let kinds = row(DATA_MODEL, "Kinds");
    for k in [
        PHOTO,
        VIDEO,
        NOTE,
        AUDIO,
        FILE,
        TAG,
        LOGIN,
        OTP,
        CODES,
        LEGACY_FOLDER,
    ] {
        assert!(
            kinds.contains(&format!("`\"{k}\"`")),
            "kind {k} missing from data-model.md"
        );
    }
}

#[test]
fn every_table_and_column_is_in_the_data_model() {
    let tables = row(DATA_MODEL, "Tables");
    let mut table = None;
    for line in crate::db::SCHEMA.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("CREATE TABLE IF NOT EXISTS ") {
            let name = rest.split_whitespace().next().unwrap();
            assert!(
                tables.contains(&format!("`{name}`")),
                "table {name} missing from data-model.md"
            );
            table = Some(name);
        } else if let Some(name) = line.split_whitespace().next().filter(|_| table.is_some()) {
            let typed = ["TEXT", "INTEGER", "BLOB"]
                .iter()
                .any(|t| line.split_whitespace().nth(1) == Some(t));
            if typed {
                assert!(
                    DATA_MODEL.contains(&format!("`{name}`")),
                    "column {}.{name} missing from data-model.md",
                    table.unwrap()
                );
            }
        }
    }
}

#[test]
fn every_item_record_field_is_in_the_data_model() {
    let full = ItemRecord {
        format: 2,
        kind: "k".into(),
        name: "n".into(),
        mime: "m".into(),
        created_ms: 1,
        size_bytes: 1,
        has_thumbnail: true,
        wrapped_dek: "w".into(),
        deleted_ms: Some(1),
        duration_ms: Some(1),
        tag_ids: vec!["t".into()],
        is_favorite: true,
        modified_ms: Some(1),
        rev: "r".into(),
        base_rev: Some("b".into()),
        hlc: 1,
        device: "d".into(),
        data_rev: "x".into(),
        data_hash: "h".into(),
        thumb_hash: "h".into(),
        summary: Some(Summary {
            account: "a".into(),
            hosts: vec!["h".into()],
            of: "o".into(),
        }),
        legacy_folder_id: None,
    };
    let Ok(Value::Object(fields)) = json::parse(&full.to_json()) else {
        panic!("a record is a JSON object");
    };
    for (key, _) in fields {
        assert!(
            DATA_MODEL.contains(&format!("`{key}`")),
            "record field {key} missing from data-model.md"
        );
    }
}

#[test]
fn cryptography_constants() {
    use cs_crypto::kdf::KdfParams;
    let c = CRYPTOGRAPHY;
    says(c, "`KEY_LEN`", &format!("`{}`", cs_crypto::KEY_LEN));
    says(
        c,
        "`SECRET_KEY_LEN`",
        &format!("`{}`", cs_crypto::SECRET_KEY_LEN),
    );
    says(c, "`SALT_LEN`", &format!("`{}`", cs_crypto::SALT_LEN));
    says(
        c,
        "`FINGERPRINT_HEX`",
        &format!("`{}`", cs_crypto::FINGERPRINT_HEX),
    );
    says(
        c,
        "`MIN_PASSWORD_LEN`",
        &format!("`{}`", crate::passwords::MIN_PASSWORD_LEN),
    );
    assert_eq!(cs_crypto::stream::CHUNK_LEN, 64 * 1024);
    assert!(row(c, "`CHUNK_LEN`").contains("`64 * 1024`"));
    assert!(
        row(c, "`HEADER_LEN` (stream)").ends_with(&format!("= {}", cs_crypto::stream::HEADER_LEN))
    );
    for (name, p) in [
        ("`PHONE_FLOOR`", KdfParams::PHONE_FLOOR),
        ("`DESKTOP_FLOOR`", KdfParams::DESKTOP_FLOOR),
    ] {
        let cell = row(c, name);
        let kib = cell
            .split(',')
            .next()
            .unwrap()
            .trim_start_matches("`m_kib: ");
        let kib: u32 = kib
            .split(" * ")
            .map(|n| n.trim().parse::<u32>().unwrap())
            .product();
        assert_eq!(kib, p.m_kib, "{name} memory");
        assert!(
            cell.contains(&format!("t: {}, p: {}`", p.t, p.p)),
            "{name} t and p"
        );
    }
}
