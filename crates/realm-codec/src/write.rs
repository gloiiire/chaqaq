//! Write support: build Realm v9 binary files from scratch.
//!
//! The entry point is [`RealmBuilder`]. Tables and columns are declared via
//! [`TableBuilder`], then the whole database is serialised to bytes or written
//! to disk.

use std::path::Path;

use crate::{ColumnType, RealmError, Result, Value};

// ── Local constants (mirrors format.rs, kept local to avoid pub(crate) leakage) ─

const WTYPE_BITS: u8 = 0;
const WTYPE_MULTIPLY: u8 = 1;
const MAGIC: &[u8; 4] = b"T-DB";
const VERSION: u32 = 9;
const FILE_HEADER_SIZE: usize = 24;

// ── Public API ────────────────────────────────────────────────────────────────

/// Builder for creating a Realm v9 database file from scratch.
///
/// Use [`RealmBuilder::table`] to add tables, then serialise with
/// [`RealmBuilder::to_bytes`] or [`RealmBuilder::write`].
///
/// # Example
///
/// ```
/// use realm_codec::{RealmBuilder, RealmFile, ColumnType, Value};
///
/// let mut builder = RealmBuilder::new();
/// builder
///     .table("class_Note")
///     .column("id",      ColumnType::String)
///     .column("content", ColumnType::String)
///     .column("done",    ColumnType::Bool)
///     .row(vec![
///         Value::String("abc".into()),
///         Value::String("Hello, world!".into()),
///         Value::Bool(false),
///     ]);
///
/// let bytes = builder.to_bytes();
/// let realm = RealmFile::from_bytes(&bytes).unwrap();
/// let table = realm.table("class_Note").unwrap();
/// assert_eq!(table.rows.len(), 1);
/// assert_eq!(table.get(&table.rows[0], "id").as_str(), "abc");
/// ```
#[derive(Debug, Default)]
pub struct RealmBuilder {
    tables: Vec<TableDef>,
}

/// A table being constructed inside a [`RealmBuilder`].
///
/// Obtained from [`RealmBuilder::table`].
pub struct TableBuilder<'a> {
    def: &'a mut TableDef,
}

#[derive(Debug)]
struct TableDef {
    name: String,
    columns: Vec<(String, ColumnType)>,
    rows: Vec<Vec<Value>>,
}

impl RealmBuilder {
    /// Create an empty builder.
    pub fn new() -> Self {
        RealmBuilder::default()
    }

    /// Add a table and return a [`TableBuilder`] to define its schema and rows.
    pub fn table(&mut self, name: impl Into<String>) -> TableBuilder<'_> {
        self.tables.push(TableDef {
            name: name.into(),
            columns: Vec::new(),
            rows: Vec::new(),
        });
        TableBuilder { def: self.tables.last_mut().unwrap() }
    }

    /// Serialise the entire database to a Realm v9 binary byte vector.
    pub fn to_bytes(&self) -> Vec<u8> {
        serialize(&self.tables)
    }

    /// Write the database to a file.
    ///
    /// Creates or truncates the file at `path`.
    pub fn write<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        std::fs::write(path, self.to_bytes()).map_err(RealmError::Io)
    }
}

impl<'a> TableBuilder<'a> {
    /// Declare a column.
    ///
    /// Column names longer than 31 bytes are silently truncated (32-byte slot
    /// with one byte reserved for the tail).
    pub fn column(&mut self, name: impl Into<String>, col_type: ColumnType) -> &mut Self {
        self.def.columns.push((name.into(), col_type));
        self
    }

    /// Append a row.
    ///
    /// Values beyond the declared column count are ignored.
    /// Missing trailing values are treated as [`Value::Null`] on read.
    pub fn row(&mut self, values: Vec<Value>) -> &mut Self {
        self.def.rows.push(values);
        self
    }
}

// ── Serialiser ────────────────────────────────────────────────────────────────

struct Serializer {
    buf: Vec<u8>,
}

impl Serializer {
    fn new() -> Self {
        // Reserve 24 bytes for the file header (filled in at finalise time).
        Serializer { buf: vec![0u8; FILE_HEADER_SIZE] }
    }

    fn align(&mut self) {
        while !self.buf.len().is_multiple_of(8) {
            self.buf.push(0);
        }
    }

    /// Write an 8-byte NodeHeader; return the start offset of the node.
    fn write_header(&mut self, size: usize, wenc: u8, wtype: u8, has_refs: bool) -> usize {
        self.align();
        let start = self.buf.len();
        let mut h4 = (wtype << 3) | (wenc & 0x07);
        if has_refs { h4 |= 0x40; }
        let h5 = ((size >> 16) & 0xFF) as u8;
        let h6 = ((size >> 8) & 0xFF) as u8;
        let h7 = (size & 0xFF) as u8;
        self.buf.extend_from_slice(&[0, 0, 0, 0, h4, h5, h6, h7]);
        start
    }

    /// `WTYPE_BITS` array of `u64` values (absolute refs or 64-bit integers).
    fn write_u64_array(&mut self, values: &[u64], has_refs: bool) -> usize {
        let start = self.write_header(values.len(), wenc(64), WTYPE_BITS, has_refs);
        for &v in values {
            self.buf.extend_from_slice(&v.to_le_bytes());
        }
        self.align();
        start
    }

    /// `WTYPE_BITS` array of `i64` values (Int / Timestamp / Link columns).
    fn write_i64_array(&mut self, values: &[i64]) -> usize {
        let start = self.write_header(values.len(), wenc(64), WTYPE_BITS, false);
        for &v in values {
            self.buf.extend_from_slice(&(v as u64).to_le_bytes());
        }
        self.align();
        start
    }

    /// `WTYPE_BITS` 1-bit packed array (Bool columns).
    fn write_bool_array(&mut self, values: &[bool]) -> usize {
        let start = self.write_header(values.len(), 1, WTYPE_BITS, false);
        let n_bytes = values.len().div_ceil(8);
        let mut bytes = vec![0u8; n_bytes];
        for (i, &b) in values.iter().enumerate() {
            if b { bytes[i / 8] |= 1u8 << (i % 8); }
        }
        self.buf.extend_from_slice(&bytes);
        self.align();
        start
    }

    /// `WTYPE_BITS` f32 array (Float columns).
    fn write_f32_array(&mut self, values: &[f32]) -> usize {
        let start = self.write_header(values.len(), wenc(32), WTYPE_BITS, false);
        for &v in values {
            self.buf.extend_from_slice(&v.to_bits().to_le_bytes());
        }
        self.align();
        start
    }

    /// `WTYPE_BITS` f64 array (Double columns).
    fn write_f64_array(&mut self, values: &[f64]) -> usize {
        let start = self.write_header(values.len(), wenc(64), WTYPE_BITS, false);
        for &v in values {
            self.buf.extend_from_slice(&v.to_bits().to_le_bytes());
        }
        self.align();
        start
    }

    /// `WTYPE_BITS` 4-bit nibble array (column type codes in the spec).
    fn write_nibble_array(&mut self, values: &[u8]) -> usize {
        let start = self.write_header(values.len(), 3, WTYPE_BITS, false);
        let n_bytes = values.len().div_ceil(2);
        let mut bytes = vec![0u8; n_bytes];
        for (i, &v) in values.iter().enumerate() {
            bytes[i / 2] |= (v & 0x0f) << ((i % 2) * 4);
        }
        self.buf.extend_from_slice(&bytes);
        self.align();
        start
    }

    /// `WTYPE_MULTIPLY` array where each slot is exactly `slot_width` bytes.
    ///
    /// Used for table names (64-byte slots) and column names (32-byte slots).
    /// Strings longer than `slot_width - 1` bytes are silently truncated.
    fn write_multiply_strings(&mut self, strings: &[&str], slot_width: u8) -> usize {
        let start = self.write_header(strings.len(), wenc(slot_width), WTYPE_MULTIPLY, false);
        let w = slot_width as usize;
        for s in strings {
            let mut slot = vec![0u8; w];
            let bytes = s.as_bytes();
            let copy_len = bytes.len().min(w.saturating_sub(1));
            slot[..copy_len].copy_from_slice(&bytes[..copy_len]);
            slot[w - 1] = (w - copy_len - 1) as u8; // tail = slot_width - len - 1
            self.buf.extend_from_slice(&slot);
        }
        self.align();
        start
    }

    /// Write a single string as a raw-bytes node (`WTYPE_BITS` width=8).
    ///
    /// The node header records `size = string.len()`. The reader reconstructs
    /// the string via its "raw bytes up to first null" fallback path.
    fn write_string_node(&mut self, s: &str) -> usize {
        let bytes = s.as_bytes();
        let start = self.write_header(bytes.len(), wenc(8), WTYPE_BITS, false);
        self.buf.extend_from_slice(bytes);
        self.align();
        start
    }

    /// Write a String/Data column as a ref array.
    ///
    /// Each non-empty string gets its own node; the column array stores absolute
    /// byte offsets (`WTYPE_BITS` u64, `has_refs = true`). Empty strings use
    /// ref = 0 (the special-cased value in the reader).
    fn write_string_column(&mut self, strings: &[&str]) -> usize {
        // Write individual string nodes first, collect their offsets.
        let refs: Vec<u64> = strings
            .iter()
            .map(|&s| {
                if s.is_empty() { 0 } else { self.write_string_node(s) as u64 }
            })
            .collect();
        self.write_u64_array(&refs, true)
    }

    fn finalize(mut self, group_ref: usize) -> Vec<u8> {
        self.buf[0..8].copy_from_slice(&(group_ref as u64).to_le_bytes());
        self.buf[8..16].copy_from_slice(&0u64.to_le_bytes());
        self.buf[16..20].copy_from_slice(MAGIC);
        self.buf[20..24].copy_from_slice(&VERSION.to_le_bytes());
        self.buf
    }
}

// ── Width encoding ────────────────────────────────────────────────────────────

/// Encode a width value to a 3-bit `width_enc` field.
///
/// For `WTYPE_BITS`: `w` is bits per element.
/// For `WTYPE_MULTIPLY`: `w` is bytes per slot.
/// Both use the same encoding table: 0→0, 1→1, 2→2, 4→3, 8→4, 16→5, 32→6, 64→7.
#[inline]
fn wenc(w: u8) -> u8 {
    match w { 0 => 0, 1 => 1, 2 => 2, 4 => 3, 8 => 4, 16 => 5, 32 => 6, 64 => 7, _ => 0 }
}

// ── Serialisation helpers ─────────────────────────────────────────────────────

fn col_type_code(ct: ColumnType) -> u8 {
    match ct {
        ColumnType::Int => 0,
        ColumnType::Bool => 1,
        ColumnType::String => 2,
        ColumnType::Data => 3,
        ColumnType::Float => 4,
        ColumnType::Double => 5,
        ColumnType::Timestamp => 7,
        ColumnType::Link | ColumnType::BackLink => 8,
        ColumnType::LinkList => 9,
        ColumnType::Unknown(v) => v,
    }
}

fn row_val(row: &[Value], col_idx: usize) -> &Value {
    row.get(col_idx).unwrap_or(&Value::Null)
}

fn serialize(tables: &[TableDef]) -> Vec<u8> {
    let mut s = Serializer::new();

    // Write all tables bottom-up; collect their refs.
    let table_refs: Vec<u64> = tables
        .iter()
        .map(|t| serialize_table(&mut s, t) as u64)
        .collect();

    // Group: names array (64-byte multiply slots) + table refs array.
    let names: Vec<&str> = tables.iter().map(|t| t.name.as_str()).collect();
    let names_ref = s.write_multiply_strings(&names, 64) as u64;
    let refs_ref = s.write_u64_array(&table_refs, true) as u64;

    let group_ref = s.write_u64_array(&[names_ref, refs_ref], true);

    s.finalize(group_ref)
}

fn serialize_table(s: &mut Serializer, table: &TableDef) -> usize {
    // Write column data arrays first (leaves), then spec, then table array.
    let col_refs: Vec<u64> = table
        .columns
        .iter()
        .enumerate()
        .map(|(ci, (_, ct))| serialize_column(s, &table.rows, ci, *ct) as u64)
        .collect();

    let spec_ref = serialize_spec(s, &table.columns) as u64;

    let mut arr = vec![spec_ref];
    arr.extend_from_slice(&col_refs);
    s.write_u64_array(&arr, true)
}

fn serialize_spec(s: &mut Serializer, columns: &[(String, ColumnType)]) -> usize {
    let type_codes: Vec<u8> = columns.iter().map(|(_, ct)| col_type_code(*ct)).collect();
    let types_ref = s.write_nibble_array(&type_codes) as u64;

    let names: Vec<&str> = columns.iter().map(|(n, _)| n.as_str()).collect();
    let names_ref = s.write_multiply_strings(&names, 32) as u64;

    s.write_u64_array(&[types_ref, names_ref], true)
}

fn serialize_column(s: &mut Serializer, rows: &[Vec<Value>], ci: usize, ct: ColumnType) -> usize {
    match ct {
        ColumnType::Int => {
            let v: Vec<i64> = rows.iter().map(|r| row_val(r, ci).as_int()).collect();
            s.write_i64_array(&v)
        }
        ColumnType::Bool => {
            let v: Vec<bool> = rows.iter().map(|r| row_val(r, ci).as_bool()).collect();
            s.write_bool_array(&v)
        }
        ColumnType::Float => {
            let v: Vec<f32> = rows.iter().map(|r| row_val(r, ci).as_float() as f32).collect();
            s.write_f32_array(&v)
        }
        ColumnType::Double => {
            let v: Vec<f64> = rows.iter().map(|r| row_val(r, ci).as_float()).collect();
            s.write_f64_array(&v)
        }
        ColumnType::Timestamp => {
            let v: Vec<i64> = rows.iter().map(|r| row_val(r, ci).as_timestamp()).collect();
            s.write_i64_array(&v)
        }
        ColumnType::String | ColumnType::Data => {
            let v: Vec<&str> = rows.iter().map(|r| row_val(r, ci).as_str()).collect();
            s.write_string_column(&v)
        }
        ColumnType::Link | ColumnType::LinkList | ColumnType::BackLink => {
            let v: Vec<i64> = rows
                .iter()
                .map(|r| match row_val(r, ci) {
                    Value::Link(i) => *i as i64,
                    other => other.as_int(),
                })
                .collect();
            s.write_i64_array(&v)
        }
        ColumnType::Unknown(_) => s.write_u64_array(&[], false),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RealmFile;

    fn roundtrip(builder: RealmBuilder) -> crate::RealmFile {
        let bytes = builder.to_bytes();
        RealmFile::from_bytes(&bytes).expect("round-trip parse failed")
    }

    #[test]
    fn wenc_all_values() {
        assert_eq!(wenc(0), 0);
        assert_eq!(wenc(1), 1);
        assert_eq!(wenc(2), 2);
        assert_eq!(wenc(4), 3);
        assert_eq!(wenc(8), 4);
        assert_eq!(wenc(16), 5);
        assert_eq!(wenc(32), 6);
        assert_eq!(wenc(64), 7);
    }

    #[test]
    fn empty_builder_roundtrip() {
        let realm = roundtrip(RealmBuilder::new());
        assert_eq!(realm.tables().len(), 0);
    }

    #[test]
    fn single_table_no_rows() {
        let mut b = RealmBuilder::new();
        b.table("Foo")
            .column("id", ColumnType::Int)
            .column("name", ColumnType::String);
        let realm = roundtrip(b);
        let t = realm.table("Foo").expect("table Foo not found");
        assert_eq!(t.columns.len(), 2);
        assert_eq!(t.rows.len(), 0);
        assert_eq!(t.columns[0].0, "id");
        assert_eq!(t.columns[1].0, "name");
    }

    #[test]
    fn int_column_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("T").column("n", ColumnType::Int)
            .row(vec![Value::Int(0)])
            .row(vec![Value::Int(42)])
            .row(vec![Value::Int(-1)])
            .row(vec![Value::Int(i64::MAX)]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert_eq!(t.rows.len(), 4);
        assert_eq!(t.get(&t.rows[0], "n").as_int(), 0);
        assert_eq!(t.get(&t.rows[1], "n").as_int(), 42);
        assert_eq!(t.get(&t.rows[2], "n").as_int(), -1);
        assert_eq!(t.get(&t.rows[3], "n").as_int(), i64::MAX);
    }

    #[test]
    fn bool_column_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("T").column("flag", ColumnType::Bool)
            .row(vec![Value::Bool(true)])
            .row(vec![Value::Bool(false)])
            .row(vec![Value::Bool(true)]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert_eq!(t.get(&t.rows[0], "flag").as_bool(), true);
        assert_eq!(t.get(&t.rows[1], "flag").as_bool(), false);
        assert_eq!(t.get(&t.rows[2], "flag").as_bool(), true);
    }

    #[test]
    fn string_column_short_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("T").column("s", ColumnType::String)
            .row(vec![Value::String("hello".into())])
            .row(vec![Value::String("world".into())])
            .row(vec![Value::String("".into())]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert_eq!(t.get(&t.rows[0], "s").as_str(), "hello");
        assert_eq!(t.get(&t.rows[1], "s").as_str(), "world");
        assert_eq!(t.get(&t.rows[2], "s").as_str(), "");
    }

    #[test]
    fn string_column_long_roundtrip() {
        let long = "a".repeat(500);
        let mut b = RealmBuilder::new();
        b.table("T").column("body", ColumnType::String)
            .row(vec![Value::String(long.clone())]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert_eq!(t.get(&t.rows[0], "body").as_str(), long);
    }

    #[test]
    fn timestamp_column_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("T").column("ts", ColumnType::Timestamp)
            .row(vec![Value::Timestamp(1_700_000_000)])
            .row(vec![Value::Timestamp(0)])
            .row(vec![Value::Timestamp(-1)]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert_eq!(t.get(&t.rows[0], "ts").as_timestamp(), 1_700_000_000);
        assert_eq!(t.get(&t.rows[1], "ts").as_timestamp(), 0);
        assert_eq!(t.get(&t.rows[2], "ts").as_timestamp(), -1);
    }

    #[test]
    fn float_column_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("T").column("f", ColumnType::Float)
            .row(vec![Value::Float(3.14_f32 as f64)])
            .row(vec![Value::Float(0.0)])
            .row(vec![Value::Float(-1.5_f32 as f64)]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        // stored as f32, so compare with f32 precision
        assert!((t.get(&t.rows[0], "f").as_float() - 3.14_f32 as f64).abs() < 1e-5);
        assert_eq!(t.get(&t.rows[1], "f").as_float(), 0.0);
    }

    #[test]
    fn double_column_roundtrip() {
        let pi = std::f64::consts::PI;
        let mut b = RealmBuilder::new();
        b.table("T").column("d", ColumnType::Double)
            .row(vec![Value::Float(pi)])
            .row(vec![Value::Float(f64::MAX)]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert!((t.get(&t.rows[0], "d").as_float() - pi).abs() < 1e-15);
        assert_eq!(t.get(&t.rows[1], "d").as_float(), f64::MAX);
    }

    #[test]
    fn multi_column_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("Note")
            .column("id", ColumnType::String)
            .column("body", ColumnType::String)
            .column("done", ColumnType::Bool)
            .column("score", ColumnType::Int)
            .row(vec![
                Value::String("1".into()),
                Value::String("Buy milk".into()),
                Value::Bool(true),
                Value::Int(5),
            ])
            .row(vec![
                Value::String("2".into()),
                Value::String("Write tests".into()),
                Value::Bool(false),
                Value::Int(10),
            ]);
        let realm = roundtrip(b);
        let t = realm.table("Note").unwrap();
        assert_eq!(t.rows.len(), 2);
        assert_eq!(t.get(&t.rows[0], "id").as_str(), "1");
        assert_eq!(t.get(&t.rows[0], "body").as_str(), "Buy milk");
        assert_eq!(t.get(&t.rows[0], "done").as_bool(), true);
        assert_eq!(t.get(&t.rows[0], "score").as_int(), 5);
        assert_eq!(t.get(&t.rows[1], "done").as_bool(), false);
    }

    #[test]
    fn multiple_tables_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("A").column("x", ColumnType::Int).row(vec![Value::Int(1)]);
        b.table("B").column("y", ColumnType::String).row(vec![Value::String("hi".into())]);
        let realm = roundtrip(b);
        assert_eq!(realm.tables().len(), 2);
        assert!(realm.table("A").is_some());
        assert!(realm.table("B").is_some());
        assert_eq!(realm.table("A").unwrap().get(&realm.table("A").unwrap().rows[0], "x").as_int(), 1);
        assert_eq!(realm.table("B").unwrap().get(&realm.table("B").unwrap().rows[0], "y").as_str(), "hi");
    }

    #[test]
    fn table_name_preserved() {
        let mut b = RealmBuilder::new();
        b.table("class_BlockDataModel").column("id", ColumnType::String);
        let realm = roundtrip(b);
        assert!(realm.table("class_BlockDataModel").is_some());
    }

    #[test]
    fn unicode_string_roundtrip() {
        let s = "こんにちは world 🦀";
        let mut b = RealmBuilder::new();
        b.table("T").column("s", ColumnType::String).row(vec![Value::String(s.into())]);
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert_eq!(t.get(&t.rows[0], "s").as_str(), s);
    }

    #[test]
    fn many_rows_roundtrip() {
        let n = 200usize;
        let mut b = RealmBuilder::new();
        let mut tb = b.table("T");
        tb.column("i", ColumnType::Int);
        for i in 0..n { tb.row(vec![Value::Int(i as i64)]); }
        let realm = roundtrip(b);
        let t = realm.table("T").unwrap();
        assert_eq!(t.rows.len(), n);
        for (i, row) in t.rows.iter().enumerate() {
            assert_eq!(t.get(row, "i").as_int(), i as i64, "row {i}");
        }
    }

    #[test]
    fn write_to_file_roundtrip() {
        let mut b = RealmBuilder::new();
        b.table("T").column("v", ColumnType::Int).row(vec![Value::Int(99)]);

        let path = std::env::temp_dir().join("realm_writer_test.realm");
        b.write(&path).expect("write failed");
        let realm = RealmFile::open(&path).expect("open failed");
        let _ = std::fs::remove_file(&path);

        let t = realm.table("T").unwrap();
        assert_eq!(t.get(&t.rows[0], "v").as_int(), 99);
    }
}
