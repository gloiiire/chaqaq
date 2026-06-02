//! # realm-codec
//!
//! Parser and writer for [Realm](https://github.com/realm/realm-core) binary database
//! files (format version 9).
//!
//! - **Read** an existing `.realm` file with [`RealmFile::open`] — no Realm SDK required.
//! - **Write** a new `.realm` file from scratch with [`RealmBuilder`].
//!
//! ## Reading
//!
//! ```no_run
//! use realm_codec::{RealmFile, Value};
//!
//! let realm = RealmFile::open("/path/to/file.realm")?;
//!
//! if let Some(table) = realm.table("class_BlockDataModel") {
//!     for row in &table.rows {
//!         println!("{}", table.get(row, "content").as_str());
//!     }
//! }
//! # Ok::<(), realm_codec::RealmError>(())
//! ```
//!
//! ## Writing
//!
//! ```no_run
//! use realm_codec::{RealmBuilder, ColumnType, Value};
//!
//! let mut builder = RealmBuilder::new();
//! builder
//!     .table("class_Note")
//!     .column("id",   ColumnType::String)
//!     .column("body", ColumnType::String)
//!     .row(vec![Value::String("1".into()), Value::String("Hello".into())]);
//!
//! builder.write("/path/to/out.realm")?;
//! # Ok::<(), realm_codec::RealmError>(())
//! ```

#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub(crate) mod format;
mod reader;
pub mod write;

pub use write::{RealmBuilder, TableBuilder};

use std::path::Path;

// ── Error ─────────────────────────────────────────────────────────────────────

/// Errors that can occur while opening or parsing a Realm file.
#[derive(Debug)]
#[non_exhaustive]
pub enum RealmError {
    /// An I/O error while reading the file from disk.
    Io(std::io::Error),
    /// The file does not conform to the expected Realm binary layout.
    InvalidFormat(String),
    /// The file uses a Realm format version other than 9.
    UnsupportedVersion(u32),
}

impl std::fmt::Display for RealmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RealmError::Io(e) => write!(f, "I/O error: {e}"),
            RealmError::InvalidFormat(msg) => write!(f, "invalid Realm format: {msg}"),
            RealmError::UnsupportedVersion(v) => {
                write!(f, "unsupported Realm version {v} (only v9 is supported)")
            }
        }
    }
}

impl std::error::Error for RealmError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        if let RealmError::Io(e) = self {
            Some(e)
        } else {
            None
        }
    }
}

impl From<std::io::Error> for RealmError {
    fn from(e: std::io::Error) -> Self {
        RealmError::Io(e)
    }
}

/// Convenience `Result` alias for this crate.
pub type Result<T> = std::result::Result<T, RealmError>;

// ── Column type ───────────────────────────────────────────────────────────────

/// The declared type of a Realm column.
///
/// Decoded from the 4-bit type codes stored in the table spec array.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum ColumnType {
    /// 64-bit signed integer.
    Int,
    /// Boolean (1-bit).
    Bool,
    /// UTF-8 string.
    String,
    /// Arbitrary binary data.
    Data,
    /// 32-bit IEEE 754 float.
    Float,
    /// 64-bit IEEE 754 double.
    Double,
    /// Unix timestamp (seconds).
    Timestamp,
    /// Reference to a row in another table.
    Link,
    /// List of references to rows in another table.
    LinkList,
    /// Inverse link (back-link).
    BackLink,
    /// A type code not recognised by this parser version.
    Unknown(u8),
}

impl ColumnType {
    /// Decode a raw 4-bit type code from the Realm spec array.
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => ColumnType::Int,
            1 => ColumnType::Bool,
            2 => ColumnType::String,
            3 => ColumnType::Data,
            4 => ColumnType::Float,
            5 => ColumnType::Double,
            7 => ColumnType::Timestamp,
            8 | 12 => ColumnType::Link,
            9 | 13 => ColumnType::LinkList,
            14 => ColumnType::BackLink,
            other => ColumnType::Unknown(other),
        }
    }
}

// ── Value ─────────────────────────────────────────────────────────────────────

/// A single parsed cell value.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum Value {
    /// The cell is absent or could not be decoded.
    Null,
    /// Boolean cell.
    Bool(bool),
    /// Integer cell (i64).
    Int(i64),
    /// Float or double cell (stored as f64).
    Float(f64),
    /// Unix timestamp in seconds.
    Timestamp(i64),
    /// UTF-8 string or binary data column.
    String(String),
    /// Row index in a linked table.
    Link(usize),
    /// Ordered list of row indices in a linked table.
    LinkList(Vec<u32>),
}

impl Value {
    /// Returns `true` if the value is [`Value::Null`].
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// Returns the inner `&str` if this is a [`Value::String`], otherwise `""`.
    pub fn as_str(&self) -> &str {
        if let Value::String(s) = self {
            s
        } else {
            ""
        }
    }

    /// Returns the inner `i64` if this is a [`Value::Int`], otherwise `0`.
    pub fn as_int(&self) -> i64 {
        if let Value::Int(i) = self {
            *i
        } else {
            0
        }
    }

    /// Returns the inner `bool` if this is a [`Value::Bool`], otherwise `false`.
    pub fn as_bool(&self) -> bool {
        if let Value::Bool(b) = self {
            *b
        } else {
            false
        }
    }

    /// Returns the inner Unix timestamp if this is a [`Value::Timestamp`], otherwise `0`.
    pub fn as_timestamp(&self) -> i64 {
        if let Value::Timestamp(t) = self {
            *t
        } else {
            0
        }
    }

    /// Returns the inner `f64` if this is a [`Value::Float`], otherwise `0.0`.
    pub fn as_float(&self) -> f64 {
        if let Value::Float(f) = self {
            *f
        } else {
            0.0
        }
    }

    /// Returns the row indices if this is a [`Value::LinkList`], otherwise `&[]`.
    pub fn as_link_list(&self) -> &[u32] {
        if let Value::LinkList(v) = self {
            v
        } else {
            &[]
        }
    }
}

// ── Row ───────────────────────────────────────────────────────────────────────

/// A single row of cell values in a table.
///
/// Column order matches [`RealmTable::columns`].
#[derive(Debug, Clone)]
pub struct Row {
    /// Cell values in column-declaration order.
    pub values: Vec<Value>,
}

impl Row {
    /// Get the value at column index `col_idx`, or [`Value::Null`] if out of range.
    pub fn get(&self, col_idx: usize) -> &Value {
        self.values.get(col_idx).unwrap_or(&Value::Null)
    }
}

// ── Table ─────────────────────────────────────────────────────────────────────

/// A parsed Realm table: schema + rows.
#[derive(Debug, Clone)]
pub struct RealmTable {
    /// Table name as stored in the Realm file (e.g. `"class_BlockDataModel"`).
    pub name: String,
    /// Column definitions in declaration order: `(column_name, column_type)`.
    pub columns: Vec<(String, ColumnType)>,
    /// All rows in the table.
    pub rows: Vec<Row>,
}

impl RealmTable {
    /// Return the column index for `name`, or `None` if not found.
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|(n, _)| n == name)
    }

    /// Return the value in `row` for the column named `col_name`.
    ///
    /// Returns [`Value::Null`] if the column does not exist.
    pub fn get<'a>(&self, row: &'a Row, col_name: &str) -> &'a Value {
        match self.column_index(col_name) {
            Some(i) => row.get(i),
            None => &Value::Null,
        }
    }
}

// ── RealmFile ─────────────────────────────────────────────────────────────────

/// An opened and fully-parsed Realm database file.
///
/// Constructed via [`RealmFile::open`] or [`RealmFile::from_bytes`].
pub struct RealmFile {
    tables: Vec<RealmTable>,
}

impl RealmFile {
    /// Read and parse a `.realm` file from disk.
    ///
    /// # Errors
    ///
    /// Returns [`RealmError::Io`] if the file cannot be read, [`RealmError::InvalidFormat`]
    /// if the binary layout is unexpected, or [`RealmError::UnsupportedVersion`] if the
    /// format version is not 9.
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        let data = std::fs::read(path)?;
        Self::from_bytes(&data)
    }

    /// Parse a Realm database from an in-memory byte slice.
    ///
    /// Useful for testing or when the file is already loaded in memory.
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        let tables = reader::read_tables(data)?;
        Ok(RealmFile { tables })
    }

    /// All tables in the file, in the order they appear in the Group.
    pub fn tables(&self) -> &[RealmTable] {
        &self.tables
    }

    /// Find a table by exact name (e.g. `"class_BlockDataModel"`).
    ///
    /// Returns `None` if no table with that name exists.
    pub fn table(&self, name: &str) -> Option<&RealmTable> {
        self.tables.iter().find(|t| t.name == name)
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::format::*;
    use super::*;

    // ── NodeHeader ────────────────────────────────────────────────────────────

    #[test]
    fn node_header_bits_width8() {
        let mut h = [0u8; 8];
        // wtype=0 (bits), width_enc=4 → width=8, size=5
        h[4] = 4;
        h[7] = 5;
        let hdr = NodeHeader::parse(&h);
        assert_eq!(hdr.width, 8);
        assert_eq!(hdr.wtype, WTYPE_BITS);
        assert_eq!(hdr.size, 5);
        assert!(!hdr.is_inner);
    }

    #[test]
    fn node_header_multiply_width64() {
        let mut h = [0u8; 8];
        // wtype=1 (multiply), width_enc=7 → width=64
        h[4] = (WTYPE_MULTIPLY << 3) | 7;
        h[7] = 3;
        let hdr = NodeHeader::parse(&h);
        assert_eq!(hdr.wtype, WTYPE_MULTIPLY);
        assert_eq!(hdr.width, 64);
        assert_eq!(hdr.size, 3);
    }

    #[test]
    fn node_header_width_encoding_all_values() {
        // width_enc 0..=7 → 0, 1, 2, 4, 8, 16, 32, 64
        let expected = [0u8, 1, 2, 4, 8, 16, 32, 64];
        for (enc, &exp) in expected.iter().enumerate() {
            let mut h = [0u8; 8];
            h[4] = enc as u8;
            assert_eq!(NodeHeader::parse(&h).width, exp, "enc={enc}");
        }
    }

    #[test]
    fn node_header_size_three_bytes() {
        // size is packed in h[5..7]: (h[5]<<16)|(h[6]<<8)|h[7]
        let mut h = [0u8; 8];
        h[5] = 0x01;
        h[6] = 0x02;
        h[7] = 0x03;
        assert_eq!(NodeHeader::parse(&h).size, 0x010203);
    }

    #[test]
    fn node_header_inner_flag() {
        let mut h = [0u8; 8];
        h[4] = 0x80;
        assert!(NodeHeader::parse(&h).is_inner);
    }

    // ── String decoding ───────────────────────────────────────────────────────

    #[test]
    fn decode_short_string_normal() {
        let mut slot = [0u8; 32];
        slot[..5].copy_from_slice(b"hello");
        slot[31] = 26; // tail = 32 - 5 - 1
        assert_eq!(decode_short_string(&slot), "hello");
    }

    #[test]
    fn decode_short_string_empty() {
        let mut slot = [0u8; 8];
        slot[7] = 7; // tail = 8 - 0 - 1
        assert_eq!(decode_short_string(&slot), "");
    }

    #[test]
    fn decode_short_string_full_slot() {
        // All 7 payload bytes used, tail=0
        let mut slot = [b'x'; 8];
        slot[7] = 0;
        let s = decode_short_string(&slot);
        assert_eq!(s.len(), 7);
    }

    #[test]
    fn decode_short_string_empty_slice() {
        assert_eq!(decode_short_string(&[]), "");
    }

    // ── Bit-width element reading ─────────────────────────────────────────────

    #[test]
    fn read_bits_elem_8bit() {
        let data = [10u8, 20, 30];
        assert_eq!(read_bits_elem(&data, 0, 8), 10);
        assert_eq!(read_bits_elem(&data, 2, 8), 30);
    }

    #[test]
    fn read_bits_elem_4bit() {
        // byte 0xAB: lower nibble = 0xB (elem 0), upper nibble = 0xA (elem 1)
        let data = [0xABu8];
        assert_eq!(read_bits_elem(&data, 0, 4), 0xB);
        assert_eq!(read_bits_elem(&data, 1, 4), 0xA);
    }

    #[test]
    fn read_bits_elem_1bit() {
        let data = [0b1010_1010u8];
        assert_eq!(read_bits_elem(&data, 0, 1), 0);
        assert_eq!(read_bits_elem(&data, 1, 1), 1);
        assert_eq!(read_bits_elem(&data, 7, 1), 1);
    }

    #[test]
    fn read_bits_elem_64bit() {
        let val: u64 = 0xDEAD_BEEF_1234_5678;
        let data = val.to_le_bytes();
        assert_eq!(read_bits_elem(&data, 0, 64), val);
    }

    #[test]
    fn read_bits_elem_zero_width() {
        assert_eq!(read_bits_elem(&[0xFF], 0, 0), 0);
    }

    #[test]
    fn read_bits_elem_2bit() {
        // byte 0xE4 = 0b1110_0100 — 2-bit elems 0..3 = 0b00, 0b01, 0b10, 0b11
        let data = [0xE4u8];
        assert_eq!(read_bits_elem(&data, 0, 2), 0b00);
        assert_eq!(read_bits_elem(&data, 1, 2), 0b01);
        assert_eq!(read_bits_elem(&data, 2, 2), 0b10);
        assert_eq!(read_bits_elem(&data, 3, 2), 0b11);
    }

    #[test]
    fn read_bits_elem_16bit() {
        let data = [0x34u8, 0x12, 0x78, 0x56];
        assert_eq!(read_bits_elem(&data, 0, 16), 0x1234);
        assert_eq!(read_bits_elem(&data, 1, 16), 0x5678);
    }

    #[test]
    fn read_bits_elem_32bit() {
        let data = [0x78u8, 0x56, 0x34, 0x12, 0xAA, 0xBB, 0xCC, 0xDD];
        assert_eq!(read_bits_elem(&data, 0, 32), 0x1234_5678);
        assert_eq!(read_bits_elem(&data, 1, 32), 0xDDCC_BBAA);
    }

    #[test]
    fn read_bits_elem_unsupported_width_returns_zero() {
        // Any width not in {0, 1, 2, 4, 8, 16, 32, 64} falls to `_ => 0`.
        assert_eq!(read_bits_elem(&[0xFFu8; 8], 0, 3), 0);
        assert_eq!(read_bits_elem(&[0xFFu8; 8], 0, 127), 0);
    }

    // ── ColumnType ────────────────────────────────────────────────────────────

    #[test]
    fn column_type_known_codes() {
        assert_eq!(ColumnType::from_u8(0), ColumnType::Int);
        assert_eq!(ColumnType::from_u8(1), ColumnType::Bool);
        assert_eq!(ColumnType::from_u8(2), ColumnType::String);
        assert_eq!(ColumnType::from_u8(3), ColumnType::Data);
        assert_eq!(ColumnType::from_u8(4), ColumnType::Float);
        assert_eq!(ColumnType::from_u8(5), ColumnType::Double);
        assert_eq!(ColumnType::from_u8(7), ColumnType::Timestamp);
        assert_eq!(ColumnType::from_u8(8), ColumnType::Link);
        assert_eq!(ColumnType::from_u8(12), ColumnType::Link);
        assert_eq!(ColumnType::from_u8(9), ColumnType::LinkList);
        assert_eq!(ColumnType::from_u8(14), ColumnType::BackLink);
    }

    #[test]
    fn column_type_unknown() {
        assert!(matches!(ColumnType::from_u8(99), ColumnType::Unknown(99)));
    }

    // ── Value accessors ───────────────────────────────────────────────────────

    #[test]
    fn value_accessors_hit() {
        assert_eq!(Value::String("hi".into()).as_str(), "hi");
        assert_eq!(Value::Int(42).as_int(), 42);
        assert!(Value::Bool(true).as_bool());
        assert_eq!(Value::Timestamp(100).as_timestamp(), 100);
        assert_eq!(Value::Float(2.5).as_float(), 2.5);
        assert_eq!(Value::LinkList(vec![1, 2, 3]).as_link_list(), &[1u32, 2, 3]);
    }

    #[test]
    fn value_accessors_miss() {
        assert_eq!(Value::Null.as_str(), "");
        assert_eq!(Value::Null.as_int(), 0);
        assert!(!Value::Null.as_bool());
        assert_eq!(Value::Null.as_timestamp(), 0);
        assert_eq!(Value::Null.as_float(), 0.0);
        assert_eq!(Value::Null.as_link_list(), &[] as &[u32]);
    }

    #[test]
    fn value_link_list_empty() {
        let v = Value::LinkList(vec![]);
        assert_eq!(v.as_link_list(), &[] as &[u32]);
        assert!(!v.is_null());
    }

    #[test]
    fn value_link_list_non_empty() {
        let v = Value::LinkList(vec![0, 42, 100]);
        assert_eq!(v.as_link_list(), &[0u32, 42, 100]);
    }

    #[test]
    fn value_as_link_list_miss_returns_empty_slice() {
        assert_eq!(Value::Int(5).as_link_list(), &[] as &[u32]);
        assert_eq!(Value::String("x".into()).as_link_list(), &[] as &[u32]);
        assert_eq!(Value::Bool(true).as_link_list(), &[] as &[u32]);
    }

    #[test]
    fn value_is_null() {
        assert!(Value::Null.is_null());
        assert!(!Value::Int(1).is_null());
        assert!(!Value::String("x".into()).is_null());
        assert!(!Value::LinkList(vec![]).is_null());
    }

    // ── Row / RealmTable ──────────────────────────────────────────────────────

    #[test]
    fn row_get_in_bounds() {
        let row = Row {
            values: vec![Value::Int(1), Value::Bool(true)],
        };
        assert_eq!(row.get(0), &Value::Int(1));
        assert_eq!(row.get(1), &Value::Bool(true));
    }

    #[test]
    fn row_get_out_of_bounds() {
        let row = Row {
            values: vec![Value::Int(1)],
        };
        assert_eq!(row.get(99), &Value::Null);
    }

    #[test]
    fn realm_table_column_index() {
        let table = RealmTable {
            name: "t".into(),
            columns: vec![
                ("id".into(), ColumnType::String),
                ("age".into(), ColumnType::Int),
            ],
            rows: vec![],
        };
        assert_eq!(table.column_index("id"), Some(0));
        assert_eq!(table.column_index("age"), Some(1));
        assert_eq!(table.column_index("missing"), None);
    }

    #[test]
    fn realm_table_get_by_name() {
        let row = Row {
            values: vec![Value::String("abc".into()), Value::Int(7)],
        };
        let table = RealmTable {
            name: "t".into(),
            columns: vec![
                ("id".into(), ColumnType::String),
                ("count".into(), ColumnType::Int),
            ],
            rows: vec![],
        };
        assert_eq!(table.get(&row, "id").as_str(), "abc");
        assert_eq!(table.get(&row, "count").as_int(), 7);
        assert_eq!(table.get(&row, "missing"), &Value::Null);
    }

    // ── File-level validation ─────────────────────────────────────────────────

    #[test]
    fn file_too_small_rejected() {
        let result = RealmFile::from_bytes(&[0u8; 10]);
        assert!(matches!(result, Err(RealmError::InvalidFormat(_))));
    }

    #[test]
    fn bad_magic_rejected() {
        let mut data = vec![0u8; 24];
        data[16..20].copy_from_slice(b"XXXX");
        data[20..24].copy_from_slice(&9u32.to_le_bytes());
        assert!(matches!(
            RealmFile::from_bytes(&data),
            Err(RealmError::InvalidFormat(_))
        ));
    }

    #[test]
    fn truncated_file_no_panic() {
        // Header is valid (24 bytes, good magic, version 9, top_ref pointing into
        // the file) but the rest of the file is missing — node header reads must
        // surface as InvalidFormat, not panic.
        let mut data = vec![0u8; 24];
        // top_ref = 24 (immediately past the header — but past EOF)
        data[0..8].copy_from_slice(&24u64.to_le_bytes());
        data[16..20].copy_from_slice(b"T-DB");
        data[20] = 9;
        let result = RealmFile::from_bytes(&data);
        // Must be an Err, not a panic.
        assert!(matches!(result, Err(RealmError::InvalidFormat(_))));
    }

    #[test]
    fn unsupported_version_rejected() {
        let mut data = vec![0u8; 24];
        data[16..20].copy_from_slice(b"T-DB");
        data[20..24].copy_from_slice(&5u32.to_le_bytes());
        assert!(matches!(
            RealmFile::from_bytes(&data),
            Err(RealmError::UnsupportedVersion(5))
        ));
    }

    #[test]
    fn realm_error_display() {
        let e = RealmError::UnsupportedVersion(5);
        assert!(e.to_string().contains("v9"));
        let e = RealmError::InvalidFormat("bad".into());
        assert!(e.to_string().contains("bad"));
    }

    #[test]
    fn realm_error_source_io() {
        use std::error::Error;
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "missing");
        let e = RealmError::from(io_err);
        assert!(e.source().is_some());
    }

    #[test]
    fn realm_error_source_non_io() {
        use std::error::Error;
        let e = RealmError::InvalidFormat("x".into());
        assert!(e.source().is_none());
    }
}
