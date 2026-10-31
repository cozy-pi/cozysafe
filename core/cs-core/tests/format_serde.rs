//! The vault files read and written by `cs_core::format` against serde, which wrote them
//! up to now: the same bytes out, the same values in, both ways, on random records and
//! on every older form. The serde types are copied from cs-vault as they were.

use cs_core::format::{ItemRecord, KdfJson, LibraryHeader, PinFile, VaultHeader, VaultMeta};
use serde::{Deserialize, Serialize};

// ------------------------------------------------------------ serde, as it was

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
struct SKdf {
    m_kib: u32,
    t: u32,
    p: u32,
}

#[derive(Serialize, Deserialize, PartialEq, Debug)]
struct SLibraryHeader {
    format: u32,
    kdf: SKdf,
    salt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    secret_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    prev_secret_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kind: Option<String>,
}

#[derive(Serialize, Deserialize, PartialEq, Debug)]
struct SVaultHeader {
    format: u32,
    salt: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    wrapped_master_key: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    prev_wrapped_master_key: String,
    meta: String,
}

#[derive(Serialize, Deserialize, Default, PartialEq, Debug)]
struct SVaultMeta {
    #[serde(default)]
    name: String,
    #[serde(default)]
    icon: String,
    #[serde(default)]
    color: String,
}

#[derive(Serialize, Deserialize, PartialEq, Debug)]
struct SPinFile {
    format: u32,
    salt: String,
    length: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kdf: Option<SKdf>,
    #[serde(default, rename = "m_kib", skip_serializing)]
    legacy_m_kib: Option<u32>,
    #[serde(default, rename = "t", skip_serializing)]
    legacy_t: Option<u32>,
    #[serde(default, rename = "p", skip_serializing)]
    legacy_p: Option<u32>,
    wrapped_master_key: String,
}

fn format_1() -> u32 {
    1
}
fn is_false(b: &bool) -> bool {
    !*b
}
fn is_zero(n: &i64) -> bool {
    *n == 0
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
struct SItemRecord {
    #[serde(default = "format_1")]
    format: u32,
    kind: String,
    name: String,
    mime: String,
    created_ms: i64,
    #[serde(alias = "size")]
    size_bytes: u64,
    #[serde(alias = "has_thumb")]
    has_thumbnail: bool,
    wrapped_dek: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    deleted_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tag_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    is_favorite: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    modified_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    rev: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    base_rev: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    hlc: i64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    device: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    data_rev: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    data_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    thumb_hash: String,
    #[serde(default, rename = "folder", skip_serializing)]
    legacy_folder_id: Option<String>,
}

// ------------------------------------------------------------ conversions

fn kdf(k: SKdf) -> KdfJson {
    KdfJson {
        m_kib: k.m_kib,
        t: k.t,
        p: k.p,
    }
}

fn library(s: &SLibraryHeader) -> LibraryHeader {
    LibraryHeader {
        format: s.format,
        kdf: kdf(s.kdf),
        salt: s.salt.clone(),
        secret_key: s.secret_key.clone(),
        prev_secret_key: s.prev_secret_key.clone(),
        kind: s.kind.clone(),
    }
}

fn vault(s: &SVaultHeader) -> VaultHeader {
    VaultHeader {
        format: s.format,
        salt: s.salt.clone(),
        wrapped_master_key: s.wrapped_master_key.clone(),
        prev_wrapped_master_key: s.prev_wrapped_master_key.clone(),
        meta: s.meta.clone(),
    }
}

fn meta(s: &SVaultMeta) -> VaultMeta {
    VaultMeta {
        name: s.name.clone(),
        icon: s.icon.clone(),
        color: s.color.clone(),
    }
}

fn pin(s: &SPinFile) -> PinFile {
    PinFile {
        format: s.format,
        salt: s.salt.clone(),
        length: s.length,
        kdf: s.kdf.map(kdf),
        legacy_m_kib: s.legacy_m_kib,
        legacy_t: s.legacy_t,
        legacy_p: s.legacy_p,
        wrapped_master_key: s.wrapped_master_key.clone(),
    }
}

fn record(s: &SItemRecord) -> ItemRecord {
    ItemRecord {
        format: s.format,
        kind: s.kind.clone(),
        name: s.name.clone(),
        mime: s.mime.clone(),
        created_ms: s.created_ms,
        size_bytes: s.size_bytes,
        has_thumbnail: s.has_thumbnail,
        wrapped_dek: s.wrapped_dek.clone(),
        deleted_ms: s.deleted_ms,
        duration_ms: s.duration_ms,
        tag_ids: s.tag_ids.clone(),
        is_favorite: s.is_favorite,
        modified_ms: s.modified_ms,
        rev: s.rev.clone(),
        base_rev: s.base_rev.clone(),
        hlc: s.hlc,
        device: s.device.clone(),
        data_rev: s.data_rev.clone(),
        data_hash: s.data_hash.clone(),
        thumb_hash: s.thumb_hash.clone(),
        legacy_folder_id: s.legacy_folder_id.clone(),
    }
}

// ------------------------------------------------------------ random values

struct Rng(u64);

impl Rng {
    fn new() -> Self {
        let seed = cs_crypto::generate_salt();
        Rng(u64::from_le_bytes(seed[..8].try_into().unwrap()) | 1)
    }
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn coin(&mut self) -> bool {
        self.next() & 1 == 0
    }
    fn u32(&mut self) -> u32 {
        match self.next() % 3 {
            0 => 0,
            1 => u32::MAX,
            _ => self.next() as u32,
        }
    }
    fn i64(&mut self) -> i64 {
        match self.next() % 4 {
            0 => 0,
            1 => i64::MIN,
            2 => i64::MAX,
            _ => self.next() as i64,
        }
    }
    fn u64(&mut self) -> u64 {
        match self.next() % 3 {
            0 => 0,
            1 => u64::MAX,
            _ => self.next(),
        }
    }
    /// Empty, hex, or text with escapes, controls and characters beyond the BMP.
    fn string(&mut self) -> String {
        const CHARS: &[char] = &[
            'a',
            'Z',
            '0',
            ' ',
            '"',
            '\\',
            '/',
            '\n',
            '\r',
            '\t',
            '\u{0}',
            '\u{1f}',
            '\u{7f}',
            'é',
            'Ả',
            'ừ',
            '中',
            '\u{2028}',
            '\u{fffd}',
            '😀',
            '\u{10ffff}',
        ];
        let len = (self.next() % 12) as usize;
        if self.coin() {
            return (0..len * 2)
                .map(|_| char::from_digit((self.next() % 16) as u32, 16).unwrap())
                .collect();
        }
        (0..len)
            .map(|_| CHARS[(self.next() % CHARS.len() as u64) as usize])
            .collect()
    }
    fn opt_string(&mut self) -> Option<String> {
        self.coin().then(|| self.string())
    }
    fn opt_i64(&mut self) -> Option<i64> {
        self.coin().then(|| self.i64())
    }
    fn kdf(&mut self) -> SKdf {
        SKdf {
            m_kib: self.u32(),
            t: self.u32(),
            p: self.u32(),
        }
    }
}

const ROUNDS: usize = 2000;

// ------------------------------------------------------------ both ways

/// Ours writes serde's bytes, and each reads what the other wrote to the same value.
macro_rules! same {
    ($s:expr, $ours:expr, $to:ident, $sto:path, $ty:ty, $sty:ty) => {{
        let s = $s;
        let ours = $ours;
        let bytes = ours.$to();
        assert_eq!(
            String::from_utf8(bytes.clone()).unwrap(),
            String::from_utf8($sto(&s).unwrap()).unwrap()
        );
        assert!(<$ty>::from_json(&bytes).unwrap() == ours);
        assert_eq!(serde_json::from_slice::<$sty>(&bytes).unwrap(), s);
    }};
}

#[test]
fn library_header() {
    let mut r = Rng::new();
    for _ in 0..ROUNDS {
        let s = SLibraryHeader {
            format: r.u32(),
            kdf: r.kdf(),
            salt: r.string(),
            secret_key: r.opt_string(),
            prev_secret_key: r.opt_string(),
            kind: r.opt_string(),
        };
        let o = library(&s);
        same!(
            s,
            o,
            to_json_pretty,
            serde_json::to_vec_pretty,
            LibraryHeader,
            SLibraryHeader
        );
    }
}

#[test]
fn vault_header() {
    let mut r = Rng::new();
    for _ in 0..ROUNDS {
        let s = SVaultHeader {
            format: r.u32(),
            salt: r.string(),
            wrapped_master_key: r.string(),
            prev_wrapped_master_key: r.string(),
            meta: r.string(),
        };
        let (o, s2) = (
            vault(&s),
            serde_json::from_slice(&serde_json::to_vec(&s).unwrap()).unwrap(),
        );
        same!(
            s,
            o,
            to_json_pretty,
            serde_json::to_vec_pretty,
            VaultHeader,
            SVaultHeader
        );
        let o = vault(&s2);
        same!(
            s2,
            o,
            to_json,
            serde_json::to_vec,
            VaultHeader,
            SVaultHeader
        );
    }
}

#[test]
fn vault_meta() {
    let mut r = Rng::new();
    for _ in 0..ROUNDS {
        let s = SVaultMeta {
            name: r.string(),
            icon: r.string(),
            color: r.string(),
        };
        let o = meta(&s);
        same!(s, o, to_json, serde_json::to_vec, VaultMeta, SVaultMeta);
    }
}

#[test]
fn pin_file() {
    let mut r = Rng::new();
    for _ in 0..ROUNDS {
        // Legacy fields are read, never written: a written file has none.
        let s = SPinFile {
            format: r.u32(),
            salt: r.string(),
            length: r.next() as u8,
            kdf: r.coin().then(|| r.kdf()),
            legacy_m_kib: None,
            legacy_t: None,
            legacy_p: None,
            wrapped_master_key: r.string(),
        };
        let o = pin(&s);
        same!(s, o, to_json, serde_json::to_vec, PinFile, SPinFile);
    }
}

#[test]
fn item_record() {
    let mut r = Rng::new();
    for _ in 0..ROUNDS {
        let s = SItemRecord {
            format: r.u32(),
            kind: r.string(),
            name: r.string(),
            mime: r.string(),
            created_ms: r.i64(),
            size_bytes: r.u64(),
            has_thumbnail: r.coin(),
            wrapped_dek: r.string(),
            deleted_ms: r.opt_i64(),
            duration_ms: r.opt_i64(),
            tag_ids: (0..r.next() % 4).map(|_| r.string()).collect(),
            is_favorite: r.coin(),
            modified_ms: r.opt_i64(),
            rev: r.string(),
            base_rev: r.opt_string(),
            hlc: r.i64(),
            device: r.string(),
            data_rev: r.string(),
            data_hash: r.string(),
            thumb_hash: r.string(),
            legacy_folder_id: None,
        };
        let o = record(&s);
        same!(s, o, to_json, serde_json::to_vec, ItemRecord, SItemRecord);
    }
}

// ------------------------------------------------------------ older and odd files

/// Read by both to the same value, or refused by both.
fn read_alike<S, O>(
    doc: &str,
    ours: fn(&[u8]) -> Result<O, cs_core::format::FormatError>,
    conv: fn(&S) -> O,
) where
    S: for<'de> Deserialize<'de> + std::fmt::Debug,
    O: PartialEq,
{
    let theirs = serde_json::from_str::<S>(doc);
    let mine = ours(doc.as_bytes());
    match (&theirs, &mine) {
        (Ok(s), Ok(o)) => assert!(conv(s) == *o, "read differently: {doc}"),
        (Err(_), Err(_)) => {}
        _ => panic!(
            "serde {} and ours {} on {doc}",
            if theirs.is_ok() { "reads" } else { "refuses" },
            if mine.is_ok() { "reads" } else { "refuses" }
        ),
    }
}

#[test]
fn older_item_records() {
    for doc in [
        // Format 1 (0.1.0–0.1.6): no format, old names, a folder.
        r#"{"kind":"photo","name":"a","mime":"image/jpeg","created_ms":1,"size":5,"has_thumb":true,"wrapped_dek":"00","folder":"ff"}"#,
        // A format-1 folder: colour and space are not record fields any more.
        r#"{"kind":"folder","name":"f","mime":"","created_ms":1,"size":0,"has_thumb":false,"wrapped_dek":"00","color":"red","space":"x"}"#,
        // Format 2 from before favourites and sync.
        r#"{"format":2,"kind":"note","name":"n","mime":"text/plain","created_ms":-5,"size_bytes":0,"has_thumbnail":false,"wrapped_dek":"ab","tag_ids":["t"]}"#,
        // A newer app's record with a field this one does not know.
        r#"{"format":2,"kind":"note","name":"n","mime":"m","created_ms":1,"size_bytes":1,"has_thumbnail":false,"wrapped_dek":"ab","future":{"x":[1,2]}}"#,
        // Nulls for optional fields.
        r#"{"format":2,"kind":"k","name":"n","mime":"m","created_ms":1,"size_bytes":1,"has_thumbnail":false,"wrapped_dek":"d","deleted_ms":null,"base_rev":null}"#,
        // Refused by both: old and new name at once, a field missing, a wrong type.
        r#"{"kind":"k","name":"n","mime":"m","created_ms":1,"size":1,"size_bytes":1,"has_thumb":false,"wrapped_dek":"d"}"#,
        r#"{"kind":"k","name":"n","mime":"m","created_ms":1,"has_thumb":false,"wrapped_dek":"d"}"#,
        r#"{"kind":"k","name":"n","mime":"m","created_ms":"1","size":1,"has_thumb":false,"wrapped_dek":"d"}"#,
        r#"{"kind":"k","name":"n","mime":"m","created_ms":1,"size":-1,"has_thumb":false,"wrapped_dek":"d"}"#,
        r#"{"kind":"k","name":"n","mime":"m","created_ms":1,"size":1,"has_thumb":false,"wrapped_dek":"d","tag_ids":[1]}"#,
        r#"[]"#,
        r#"{}"#,
    ] {
        read_alike::<SItemRecord, _>(doc, ItemRecord::from_json, record);
    }
}

#[test]
fn older_pin_files() {
    for doc in [
        // Format 1: the Argon2 cost at the top level.
        r#"{"format":1,"salt":"aa","length":6,"m_kib":65536,"t":3,"p":1,"wrapped_master_key":"bb"}"#,
        r#"{"format":2,"salt":"aa","length":6,"kdf":{"m_kib":65536,"t":3,"p":1},"wrapped_master_key":"bb"}"#,
        r#"{"format":2,"salt":"aa","length":256,"wrapped_master_key":"bb"}"#,
        r#"{"format":2,"salt":"aa","length":6,"kdf":{"m_kib":1,"t":1},"wrapped_master_key":"bb"}"#,
    ] {
        read_alike::<SPinFile, _>(doc, PinFile::from_json, pin);
    }
}

#[test]
fn older_headers() {
    for doc in [
        // From the first previews: no Secret Key fingerprint.
        r#"{"format":1,"kdf":{"m_kib":131072,"t":3,"p":1},"salt":"00"}"#,
        r#"{"format":1,"kdf":{"m_kib":131072,"t":3,"p":1},"salt":"00","secret_key":"ab","prev_secret_key":"cd"}"#,
        r#"{"format":1,"kdf":{"m_kib":-1,"t":3,"p":1},"salt":"00"}"#,
        r#"{"format":1,"salt":"00"}"#,
    ] {
        read_alike::<SLibraryHeader, _>(doc, LibraryHeader::from_json, library);
    }
    for doc in [
        // A vault opened only with a PIN: no password path yet.
        r#"{"format":1,"salt":"00","meta":"ab"}"#,
        r#"{"format":1,"salt":"00","wrapped_master_key":"x","prev_wrapped_master_key":"y","meta":"ab"}"#,
        r#"{"format":1,"salt":"00"}"#,
    ] {
        read_alike::<SVaultHeader, _>(doc, VaultHeader::from_json, vault);
    }
    for doc in [
        r#"{}"#,
        r#"{"name":"Nhà"}"#,
        r#"{"name":"a","icon":"b","color":"c","x":1}"#,
    ] {
        read_alike::<SVaultMeta, _>(doc, VaultMeta::from_json, meta);
    }
}
