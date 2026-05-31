//! # realm-reader
//!
//! Read-only parser for Realm binary database files (format version 9).
//!
//! Opens a `.realm` file and returns its tables, column schemas, and rows without
//! requiring the Realm SDK. Useful for data migration, export, and offline analysis.
//!
//! ## Example
//!
//! ```no_run
//! use realm_reader::RealmFile;
//!
//! let realm = RealmFile::open("/path/to/file.realm").unwrap();
//! for table in realm.tables() {
//!     println!("Table: {}", table.name);
//!     for row in &table.rows {
//!         println!("  {:?}", row.values);
//!     }
//! }
//! ```

pub mod format;
mod reader;

use std::path::Path;

// ── Public error type ─────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum RealmError {
    Io(std::io::Error),
    InvalidFormat(String),
    UnsupportedVersion(u32),
}

impl std::fmt::Display for RealmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RealmError::Io(e) => write!(f, "I/O error: {}", e),
            RealmError::InvalidFormat(msg) => write!(f, "invalid Realm format: {}", msg),
            RealmError::UnsupportedVersion(v) => {
                write!(f, "unsupported Realm version: {} (expected 9)", v)
            }
        }
    }
}

impl std::error::Error for RealmError {}

impl From<std::io::Error> for RealmError {
    fn from(e: std::io::Error) -> Self {
        RealmError::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, RealmError>;

// ── Column types ──────────────────────────────────────────────────────────────

/// Realm column type codes (4-bit values from the spec array).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    Int,
    Bool,
    String,
    Data,
    Float,
    Double,
    Timestamp,
    Link,
    LinkList,
    BackLink,
    Unknown(u8),
}

impl ColumnType {
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

/// A single cell value.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    /// Unix timestamp in seconds.
    Timestamp(i64),
    String(String),
    Bytes(Vec<u8>),
    /// Row index in a linked table.
    Link(usize),
}

impl Value {
    /// Convenience accessor: returns the inner string or `""`.
    pub fn as_str(&self) -> &str {
        if let Value::String(s) = self { s } else { "" }
    }

    /// Convenience accessor: returns the inner i64 or 0.
    pub fn as_int(&self) -> i64 {
        if let Value::Int(i) = self { *i } else { 0 }
    }

    /// Convenience accessor: returns the inner bool or false.
    pub fn as_bool(&self) -> bool {
        if let Value::Bool(b) = self { *b } else { false }
    }
}

// ── Row / Table ───────────────────────────────────────────────────────────────

/// A single row of values in a table.
#[derive(Debug, Clone)]
pub struct Row {
    pub values: Vec<Value>,
}

impl Row {
    /// Get the value at the given column index.
    pub fn get(&self, col_idx: usize) -> &Value {
        self.values.get(col_idx).unwrap_or(&Value::Null)
    }
}

/// A parsed Realm table with its schema and rows.
#[derive(Debug, Clone)]
pub struct RealmTable {
    pub name: String,
    /// (column_name, column_type) pairs in declaration order.
    pub columns: Vec<(String, ColumnType)>,
    pub rows: Vec<Row>,
}

impl RealmTable {
    /// Returns the column index for a given name, or `None`.
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|(n, _)| n == name)
    }

    /// Get a row's value by column name.
    pub fn get<'a>(&self, row: &'a Row, col_name: &str) -> &'a Value {
        match self.column_index(col_name) {
            Some(i) => row.get(i),
            None => &Value::Null,
        }
    }
}

// ── Public entry point ────────────────────────────────────────────────────────

/// An opened Realm file, fully parsed into memory.
pub struct RealmFile {
    tables: Vec<RealmTable>,
}

impl RealmFile {
    /// Read and parse a `.realm` file from disk.
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        let data = std::fs::read(path)?;
        Self::from_bytes(&data)
    }

    /// Parse from an in-memory byte slice (useful for tests).
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        let tables = reader::read_tables(data)?;
        Ok(RealmFile { tables })
    }

    /// All tables in the file.
    pub fn tables(&self) -> &[RealmTable] {
        &self.tables
    }

    /// Find a table by name (e.g. `"class_BlockDataModel"`).
    pub fn table(&self, name: &str) -> Option<&RealmTable> {
        self.tables.iter().find(|t| t.name == name)
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::format::*;

    #[test]
    fn node_header_parse_bits_width8() {
        // Construct a header: capacity=0, wtype=WTYPE_BITS, width=8 (enc=4), size=5
        let mut h = [0u8; 8];
        h[4] = 4; // wtype=0 (bits), width_enc=4 → actual width=8
        h[7] = 5; // size=5
        let hdr = NodeHeader::parse(&h);
        assert_eq!(hdr.width, 8);
        assert_eq!(hdr.wtype, WTYPE_BITS);
        assert_eq!(hdr.size, 5);
        assert!(!hdr.is_inner);
    }

    #[test]
    fn node_header_parse_multiply_width64() {
        let mut h = [0u8; 8];
        // wtype=1 (multiply) → bits 4-3: 0b_0_1000 = 0x08; width_enc=7 → 64 bits
        h[4] = (WTYPE_MULTIPLY << 3) | 7; // 0x0f
        h[7] = 3;
        let hdr = NodeHeader::parse(&h);
        assert_eq!(hdr.wtype, WTYPE_MULTIPLY);
        assert_eq!(hdr.width, 64);
        assert_eq!(hdr.size, 3);
    }

    #[test]
    fn node_header_inner_flag() {
        let mut h = [0u8; 8];
        h[4] = 0x80; // is_inner flag
        let hdr = NodeHeader::parse(&h);
        assert!(hdr.is_inner);
    }

    #[test]
    fn decode_short_string_basic() {
        // slot width=32, "hello" (5 bytes), tail = 32 - 5 - 1 = 26
        let mut slot = [0u8; 32];
        slot[..5].copy_from_slice(b"hello");
        slot[31] = 26; // tail
        assert_eq!(decode_short_string(&slot), "hello");
    }

    #[test]
    fn decode_short_string_empty() {
        // empty string: tail = width - 1
        let mut slot = [0u8; 8];
        slot[7] = 7; // tail = 8 - 0 - 1 = 7
        assert_eq!(decode_short_string(&slot), "");
    }

    #[test]
    fn decode_short_string_full() {
        // string fills all but last byte, tail=0
        let mut slot = [b'x'; 8];
        slot[7] = 0; // tail=0 → len = 8 - 1 - 0 = 7
        let s = decode_short_string(&slot);
        assert_eq!(s.len(), 7);
        assert!(s.chars().all(|c| c == 'x'));
    }

    #[test]
    fn read_bits_elem_8bit() {
        let data: Vec<u8> = vec![10, 20, 30];
        assert_eq!(super::format::read_bits_elem(&data, 0, 8), 10);
        assert_eq!(super::format::read_bits_elem(&data, 2, 8), 30);
    }

    #[test]
    fn read_bits_elem_4bit() {
        // two 4-bit values per byte: byte 0xAB → elem[0]=0xB, elem[1]=0xA
        let data: Vec<u8> = vec![0xAB];
        assert_eq!(super::format::read_bits_elem(&data, 0, 4), 0xB);
        assert_eq!(super::format::read_bits_elem(&data, 1, 4), 0xA);
    }

    #[test]
    fn column_type_from_u8_roundtrip() {
        use super::ColumnType;
        assert_eq!(ColumnType::from_u8(0), ColumnType::Int);
        assert_eq!(ColumnType::from_u8(2), ColumnType::String);
        assert_eq!(ColumnType::from_u8(7), ColumnType::Timestamp);
        assert!(matches!(ColumnType::from_u8(99), ColumnType::Unknown(99)));
    }

    #[test]
    fn value_accessors() {
        use super::Value;
        assert_eq!(Value::String("hi".into()).as_str(), "hi");
        assert_eq!(Value::Int(42).as_int(), 42);
        assert_eq!(Value::Bool(true).as_bool(), true);
        assert_eq!(Value::Null.as_str(), "");
        assert_eq!(Value::Null.as_int(), 0);
    }

    #[test]
    fn invalid_magic_rejected() {
        let mut data = vec![0u8; 24];
        data[16..20].copy_from_slice(b"XXXX");
        data[20..24].copy_from_slice(&9u32.to_le_bytes());
        let result = crate::RealmFile::from_bytes(&data);
        assert!(matches!(result, Err(crate::RealmError::InvalidFormat(_))));
    }

    #[test]
    fn unsupported_version_rejected() {
        let mut data = vec![0u8; 24];
        data[16..20].copy_from_slice(b"T-DB");
        data[20..24].copy_from_slice(&5u32.to_le_bytes()); // version 5, not 9
        let result = crate::RealmFile::from_bytes(&data);
        assert!(matches!(result, Err(crate::RealmError::UnsupportedVersion(5))));
    }
}
