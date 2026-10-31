//! The files a library keeps on disk, read and written with [`crate::json`].
//!
//! Each type writes exactly the bytes serde_json wrote for it before (same field order,
//! same fields left out), and reads every form written before: older formats, the old
//! field names, fields added later. A field it does not know is ignored, so a file
//! written by a newer app still opens. The tests compare both directions with serde.
//!
//! Nothing here is secret in clear: salts, wrapped keys and sealed metadata, in hex.

use cs_crypto::kdf::KdfParams;

use crate::json::{self, Fields, Object, Value};

/// Why a file was refused: which file, and what in it. Carries no file content.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FormatError(pub &'static str);

impl std::fmt::Display for FormatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for FormatError {}

type Result<T> = std::result::Result<T, FormatError>;

fn object(bytes: &[u8], what: &'static str) -> Result<Value> {
    let v = json::parse(bytes).map_err(|_| FormatError(what))?;
    match v {
        Value::Object(_) => Ok(v),
        _ => Err(FormatError(what)),
    }
}

/// A field that must be there.
fn need<T>(v: std::result::Result<Option<T>, &'static str>, what: &'static str) -> Result<T> {
    v.map_err(|_| FormatError(what))?.ok_or(FormatError(what))
}

/// A field that may be missing.
fn may<T>(
    v: std::result::Result<Option<T>, &'static str>,
    what: &'static str,
) -> Result<Option<T>> {
    v.map_err(|_| FormatError(what))
}

/// One of two names for the same field (serde's `alias`): the one present, the new name
/// when neither is; both at once is refused.
fn alias<'k>(f: &Fields, name: &'k str, old: &'k str, what: &'static str) -> Result<&'k str> {
    match (f.get(name).is_some(), f.get(old).is_some()) {
        (true, true) => Err(FormatError(what)),
        (false, true) => Ok(old),
        _ => Ok(name),
    }
}

fn opt_str(o: Object, key: &str, v: &Option<String>) -> Object {
    match v {
        Some(s) => o.str(key, s),
        None => o,
    }
}

fn opt_int(o: Object, key: &str, v: Option<i64>) -> Object {
    match v {
        Some(n) => o.int(key, n),
        None => o,
    }
}

fn str_if(o: Object, key: &str, s: &str) -> Object {
    if s.is_empty() {
        o
    } else {
        o.str(key, s)
    }
}

// ----------------------------------------------------------------------------- Argon2

/// Argon2id cost, named as in RFC 9106: memory in KiB, passes (t), lanes (p).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct KdfJson {
    pub m_kib: u32,
    pub t: u32,
    pub p: u32,
}

impl From<KdfParams> for KdfJson {
    fn from(k: KdfParams) -> Self {
        Self {
            m_kib: k.m_kib,
            t: k.t,
            p: k.p,
        }
    }
}

impl From<KdfJson> for KdfParams {
    fn from(k: KdfJson) -> Self {
        Self {
            m_kib: k.m_kib,
            t: k.t,
            p: k.p,
        }
    }
}

impl KdfJson {
    fn value(&self) -> Value {
        Object::new()
            .uint("m_kib", self.m_kib.into())
            .uint("t", self.t.into())
            .uint("p", self.p.into())
            .build()
    }

    fn read(f: &Fields, what: &'static str) -> Result<Self> {
        Ok(Self {
            m_kib: need(f.u32("m_kib"), what)?,
            t: need(f.u32("t"), what)?,
            p: need(f.u32("p"), what)?,
        })
    }
}

// ---------------------------------------------------------------------- library.json

/// `library.json`: what every vault in the library shares.
#[derive(Clone, PartialEq, Eq)]
pub struct LibraryHeader {
    pub format: u32,
    pub kdf: KdfJson,
    pub salt: String,
    /// The Secret Key's fingerprint; absent in libraries from the first previews.
    pub secret_key: Option<String>,
    /// During a Secret Key change: the old key's fingerprint.
    pub prev_secret_key: Option<String>,
}

impl LibraryHeader {
    const WHAT: &'static str = "library.json";

    fn value(&self) -> Value {
        let o = Object::new()
            .uint("format", self.format.into())
            .put("kdf", self.kdf.value())
            .str("salt", &self.salt);
        let o = opt_str(o, "secret_key", &self.secret_key);
        opt_str(o, "prev_secret_key", &self.prev_secret_key).build()
    }

    pub fn to_json_pretty(&self) -> Vec<u8> {
        json::to_vec_pretty(&self.value())
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        Self::from_value(&object(bytes, Self::WHAT)?)
    }

    /// From a value already read (the two headers inside a vault's sync lock).
    pub fn from_value(v: &Value) -> Result<Self> {
        let w = Self::WHAT;
        let f = Fields::of(v).ok_or(FormatError(w))?;
        Ok(Self {
            format: need(f.u32("format"), w)?,
            kdf: KdfJson::read(&need(f.object("kdf"), w)?, w)?,
            salt: need(f.str("salt"), w)?.to_owned(),
            secret_key: may(f.str("secret_key"), w)?.map(str::to_owned),
            prev_secret_key: may(f.str("prev_secret_key"), w)?.map(str::to_owned),
        })
    }
}

// ------------------------------------------------------------------- vault header

/// A vault's `header.json`.
#[derive(Clone, PartialEq, Eq)]
pub struct VaultHeader {
    pub format: u32,
    pub salt: String,
    /// Master Key wrapped by the password path; empty until a password is set.
    pub wrapped_master_key: String,
    /// During a Secret Key change: the Master Key wrapped with the old key.
    pub prev_wrapped_master_key: String,
    /// [`VaultMeta`], sealed with the Master Key.
    pub meta: String,
}

impl VaultHeader {
    const WHAT: &'static str = "vault header";

    pub fn has_password(&self) -> bool {
        !self.wrapped_master_key.is_empty()
    }

    fn value(&self) -> Value {
        let o = Object::new()
            .uint("format", self.format.into())
            .str("salt", &self.salt);
        let o = str_if(o, "wrapped_master_key", &self.wrapped_master_key);
        let o = str_if(o, "prev_wrapped_master_key", &self.prev_wrapped_master_key);
        o.str("meta", &self.meta).build()
    }

    pub fn to_json(&self) -> Vec<u8> {
        json::to_vec(&self.value())
    }

    pub fn to_json_pretty(&self) -> Vec<u8> {
        json::to_vec_pretty(&self.value())
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        Self::from_value(&object(bytes, Self::WHAT)?)
    }

    /// From a value already read (the two headers inside a vault's sync lock).
    pub fn from_value(v: &Value) -> Result<Self> {
        let w = Self::WHAT;
        let f = Fields::of(v).ok_or(FormatError(w))?;
        Ok(Self {
            format: need(f.u32("format"), w)?,
            salt: need(f.str("salt"), w)?.to_owned(),
            wrapped_master_key: may(f.str("wrapped_master_key"), w)?
                .unwrap_or_default()
                .to_owned(),
            prev_wrapped_master_key: may(f.str("prev_wrapped_master_key"), w)?
                .unwrap_or_default()
                .to_owned(),
            meta: need(f.str("meta"), w)?.to_owned(),
        })
    }
}

/// A vault's name, look and mode, sealed with its Master Key (nothing on disk says what a
/// vault is).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct VaultMeta {
    pub name: String,
    pub icon: String,
    pub color: String,
    /// Top Secret Mode (ADR 0007): nothing in this vault is decoded in the app. Written
    /// only when on, so an everyday vault's meta is what it was before modes.
    pub top_secret: bool,
}

impl VaultMeta {
    const WHAT: &'static str = "vault meta";

    pub fn to_json(&self) -> Vec<u8> {
        let o = Object::new()
            .str("name", &self.name)
            .str("icon", &self.icon)
            .str("color", &self.color);
        let o = if self.top_secret {
            o.bool("top_secret", true)
        } else {
            o
        };
        json::to_vec(&o.build())
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        let w = Self::WHAT;
        let v = object(bytes, w)?;
        let f = Fields::of(&v).ok_or(FormatError(w))?;
        let s = |k| may(f.str(k), w).map(|s| s.unwrap_or_default().to_owned());
        Ok(Self {
            name: s("name")?,
            icon: s("icon")?,
            color: s("color")?,
            top_secret: may(f.bool("top_secret"), w)?.unwrap_or(false),
        })
    }
}

// ------------------------------------------------------------------------------- PIN

/// A vault's PIN file on this device. Format 2 keeps the Argon2 cost in `kdf`; format 1
/// (0.1.0–0.1.6) had `m_kib`, `t`, `p` at the top level, still read, never written.
#[derive(Clone, PartialEq, Eq)]
pub struct PinFile {
    pub format: u32,
    pub salt: String,
    /// Number of digits, so unlocking only tries PINs of the typed length.
    pub length: u8,
    pub kdf: Option<KdfJson>,
    pub legacy_m_kib: Option<u32>,
    pub legacy_t: Option<u32>,
    pub legacy_p: Option<u32>,
    pub wrapped_master_key: String,
}

impl PinFile {
    const WHAT: &'static str = "pin";

    /// The Argon2 cost, from `kdf` or the format-1 fields.
    pub fn kdf_params(&self) -> Option<KdfParams> {
        match (self.kdf, self.legacy_m_kib, self.legacy_t, self.legacy_p) {
            (Some(k), ..) => Some(k.into()),
            (None, Some(m_kib), Some(t), Some(p)) => Some(KdfParams { m_kib, t, p }),
            _ => None,
        }
    }

    pub fn to_json(&self) -> Vec<u8> {
        let mut o = Object::new()
            .uint("format", self.format.into())
            .str("salt", &self.salt)
            .uint("length", self.length.into());
        if let Some(k) = &self.kdf {
            o = o.put("kdf", k.value());
        }
        json::to_vec(
            &o.str("wrapped_master_key", &self.wrapped_master_key)
                .build(),
        )
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        let w = Self::WHAT;
        let v = object(bytes, w)?;
        let f = Fields::of(&v).ok_or(FormatError(w))?;
        let length = need(f.u64("length"), w)?;
        Ok(Self {
            format: need(f.u32("format"), w)?,
            salt: need(f.str("salt"), w)?.to_owned(),
            length: u8::try_from(length).map_err(|_| FormatError(w))?,
            kdf: match may(f.object("kdf"), w)? {
                Some(k) => Some(KdfJson::read(&k, w)?),
                None => None,
            },
            legacy_m_kib: may(f.u32("m_kib"), w)?,
            legacy_t: may(f.u32("t"), w)?,
            legacy_p: may(f.u32("p"), w)?,
            wrapped_master_key: need(f.str("wrapped_master_key"), w)?.to_owned(),
        })
    }
}

// ------------------------------------------------------------------------------ items

/// One item's metadata, sealed in `<item>.meta` (and copied into the index).
///
/// Format 1 (0.1.0–0.1.6) wrote `size`, `has_thumb` and `folder`; they are read (the
/// first two as the new names, `folder` into `legacy_folder_id`) and never written. A
/// record without `format` is format 1. The fields after `tag_ids` were added later
/// without raising the format: absent means the default, and older apps ignore them.
#[derive(Clone, PartialEq, Eq)]
pub struct ItemRecord {
    pub format: u32,
    pub kind: String,
    pub name: String,
    pub mime: String,
    pub created_ms: i64,
    pub size_bytes: u64,
    pub has_thumbnail: bool,
    pub wrapped_dek: String,
    pub deleted_ms: Option<i64>,
    pub duration_ms: Option<i64>,
    pub tag_ids: Vec<String>,
    pub is_favorite: bool,
    pub modified_ms: Option<i64>,
    /// Sync (docs/adr/0003-sync.md): this revision, the one it was made from, the hybrid
    /// logical clock, the device that wrote it and the revision whose content it has.
    pub rev: String,
    pub base_rev: Option<String>,
    pub hlc: i64,
    pub device: String,
    pub data_rev: String,
    /// SHA-256 of the encrypted `.data` and `.thumb` files.
    pub data_hash: String,
    pub thumb_hash: String,
    /// Format 1: the folder the item was in. Read, never written.
    pub legacy_folder_id: Option<String>,
}

impl ItemRecord {
    const WHAT: &'static str = "item record";

    pub fn to_json(&self) -> Vec<u8> {
        let mut o = Object::new()
            .uint("format", self.format.into())
            .str("kind", &self.kind)
            .str("name", &self.name)
            .str("mime", &self.mime)
            .int("created_ms", self.created_ms)
            .uint("size_bytes", self.size_bytes)
            .bool("has_thumbnail", self.has_thumbnail)
            .str("wrapped_dek", &self.wrapped_dek);
        o = opt_int(o, "deleted_ms", self.deleted_ms);
        o = opt_int(o, "duration_ms", self.duration_ms);
        if !self.tag_ids.is_empty() {
            let tags = self.tag_ids.iter().cloned().map(Value::String).collect();
            o = o.put("tag_ids", Value::Array(tags));
        }
        if self.is_favorite {
            o = o.bool("is_favorite", true);
        }
        o = opt_int(o, "modified_ms", self.modified_ms);
        o = str_if(o, "rev", &self.rev);
        o = opt_str(o, "base_rev", &self.base_rev);
        if self.hlc != 0 {
            o = o.int("hlc", self.hlc);
        }
        o = str_if(o, "device", &self.device);
        o = str_if(o, "data_rev", &self.data_rev);
        o = str_if(o, "data_hash", &self.data_hash);
        o = str_if(o, "thumb_hash", &self.thumb_hash);
        json::to_vec(&o.build())
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        let w = Self::WHAT;
        let v = object(bytes, w)?;
        let f = Fields::of(&v).ok_or(FormatError(w))?;
        let s = |k| need(f.str(k), w).map(str::to_owned);
        let s_or = |k| may(f.str(k), w).map(|s| s.unwrap_or_default().to_owned());
        Ok(Self {
            format: may(f.u32("format"), w)?.unwrap_or(1),
            kind: s("kind")?,
            name: s("name")?,
            mime: s("mime")?,
            created_ms: need(f.i64("created_ms"), w)?,
            size_bytes: need(f.u64(alias(&f, "size_bytes", "size", w)?), w)?,
            has_thumbnail: need(f.bool(alias(&f, "has_thumbnail", "has_thumb", w)?), w)?,
            wrapped_dek: s("wrapped_dek")?,
            deleted_ms: may(f.i64("deleted_ms"), w)?,
            duration_ms: may(f.i64("duration_ms"), w)?,
            tag_ids: may(f.strings("tag_ids"), w)?.unwrap_or_default(),
            is_favorite: may(f.bool("is_favorite"), w)?.unwrap_or(false),
            modified_ms: may(f.i64("modified_ms"), w)?,
            rev: s_or("rev")?,
            base_rev: may(f.str("base_rev"), w)?.map(str::to_owned),
            hlc: may(f.i64("hlc"), w)?.unwrap_or(0),
            device: s_or("device")?,
            data_rev: s_or("data_rev")?,
            data_hash: s_or("data_hash")?,
            thumb_hash: s_or("thumb_hash")?,
            legacy_folder_id: may(f.str("folder"), w)?.map(str::to_owned),
        })
    }
}

// ------------------------------------------------------------------- string lists

/// A list of strings as a JSON array (the vault's sealed connection log).
pub fn strings_to_json(items: &[String]) -> Vec<u8> {
    json::to_vec(&Value::Array(
        items.iter().cloned().map(Value::String).collect(),
    ))
}

pub fn strings_from_json(bytes: &[u8]) -> Result<Vec<String>> {
    match json::parse(bytes).map_err(|_| FormatError("list"))? {
        Value::Array(items) => items
            .into_iter()
            .map(|v| match v {
                Value::String(s) => Ok(s),
                _ => Err(FormatError("list")),
            })
            .collect(),
        _ => Err(FormatError("list")),
    }
}
