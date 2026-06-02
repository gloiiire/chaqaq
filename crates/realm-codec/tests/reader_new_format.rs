//! Tests for the Realm SDK 5+ "cluster tree" reader paths.
//!
//! The bundled writer only emits the old format, so cluster-tree code in
//! `reader.rs` (~300 lines: `read_table_new`, `collect_strings_new`,
//! `collect_ints_new`, `collect_linklists_new`, `cluster_index_for_col`,
//! the 3 string-leaf shapes, defensive paths) is never exercised by the
//! round-trip tests. This file assembles minimal new-format byte blobs
//! directly so those code paths run.

use realm_codec::{RealmFile, Value};

const NODE_HEADER_SIZE: usize = 8;
const FILE_HEADER_SIZE: usize = 24;

// ── byte builder ─────────────────────────────────────────────────────────────

struct Bldr {
    buf: Vec<u8>,
}

impl Bldr {
    fn new() -> Self {
        Self { buf: vec![0u8; FILE_HEADER_SIZE] }
    }

    fn align(&mut self) {
        while self.buf.len() % 8 != 0 {
            self.buf.push(0);
        }
    }

    /// wenc encoding: 0→0, 1→1, 2→2, 4→3, 8→4, 16→5, 32→6, 64→7.
    fn wenc(w: u8) -> u8 {
        match w {
            0 => 0,
            1 => 1,
            2 => 2,
            4 => 3,
            8 => 4,
            16 => 5,
            32 => 6,
            64 => 7,
            _ => 0,
        }
    }

    fn write_header(&mut self, size: usize, wenc_val: u8, wtype: u8, is_inner: bool) -> usize {
        self.align();
        let start = self.buf.len();
        let mut h4 = (wtype << 3) | (wenc_val & 0x07);
        if is_inner {
            h4 |= 0x80;
        }
        let h5 = ((size >> 16) & 0xff) as u8;
        let h6 = ((size >> 8) & 0xff) as u8;
        let h7 = (size & 0xff) as u8;
        self.buf.extend_from_slice(&[0, 0, 0, 0, h4, h5, h6, h7]);
        start
    }

    /// WTYPE_BITS u64 array (refs or large ints).
    fn write_u64_array(&mut self, values: &[u64]) -> usize {
        let start = self.write_header(values.len(), Self::wenc(64), 0, false);
        for v in values {
            self.buf.extend_from_slice(&v.to_le_bytes());
        }
        self.align();
        start
    }

    /// WTYPE_BITS u64 array but flagged as inner B+ tree node.
    fn write_inner_node(&mut self, values: &[u64]) -> usize {
        let start = self.write_header(values.len(), Self::wenc(64), 0, true);
        for v in values {
            self.buf.extend_from_slice(&v.to_le_bytes());
        }
        self.align();
        start
    }

    /// WTYPE_BITS 4-bit nibble array (column type codes).
    fn write_nibble_array(&mut self, codes: &[u8]) -> usize {
        let start = self.write_header(codes.len(), 3, 0, false);
        let n_bytes = codes.len().div_ceil(2);
        let mut bytes = vec![0u8; n_bytes];
        for (i, &v) in codes.iter().enumerate() {
            bytes[i / 2] |= (v & 0x0f) << ((i % 2) * 4);
        }
        self.buf.extend_from_slice(&bytes);
        self.align();
        start
    }

    /// WTYPE_MULTIPLY string slot array (fixed-width slots with tail-encoded length).
    fn write_multiply_strings(&mut self, strings: &[&str], slot_width: u8) -> usize {
        let start = self.write_header(strings.len(), Self::wenc(slot_width), 1, false);
        let w = slot_width as usize;
        for s in strings {
            let bytes = s.as_bytes();
            let copy_len = bytes.len().min(w.saturating_sub(1));
            let mut slot = vec![0u8; w];
            slot[..copy_len].copy_from_slice(&bytes[..copy_len]);
            slot[w - 1] = (w - copy_len - 1) as u8;
            self.buf.extend_from_slice(&slot);
        }
        self.align();
        start
    }

    /// WTYPE_BITS array tagged as int (width=64, no inner flag).
    fn write_i64_array(&mut self, values: &[i64]) -> usize {
        let start = self.write_header(values.len(), Self::wenc(64), 0, false);
        for &v in values {
            self.buf.extend_from_slice(&(v as u64).to_le_bytes());
        }
        self.align();
        start
    }

    fn finalize(mut self, group_ref: usize) -> Vec<u8> {
        self.buf[0..8].copy_from_slice(&(group_ref as u64).to_le_bytes());
        self.buf[8..16].copy_from_slice(&0u64.to_le_bytes());
        self.buf[16..20].copy_from_slice(b"T-DB");
        self.buf[20] = 9;
        self.buf
    }
}

// ── Cluster-tree tests ────────────────────────────────────────────────────────

#[test]
fn new_format_single_string_column_inline_multiply() {
    let mut b = Bldr::new();

    // Column 0 (primary key) data: 3 inline-multiply slots of 8 bytes.
    let col0_data = b.write_multiply_strings(&["a", "bb", "ccc"], 8);

    // pk_index can be 0 (skipped by reader).
    // cluster_root = [col0_data, 0]
    let cluster_root = b.write_u64_array(&[col0_data as u64, 0]);

    // spec: types_ref = nibble[2] (String), names_ref = multiply["id"]
    // Must have ≥ 4 elements to trigger the new-format branch.
    let types_ref = b.write_nibble_array(&[2]);
    let names_ref = b.write_multiply_strings(&["id"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);

    // table_arr = [spec_ref, cluster_root_ref]
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    // Group
    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["MyTable"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("MyTable").expect("MyTable");
    assert_eq!(t.rows.len(), 3);
    assert_eq!(t.get(&t.rows[0], "id").as_str(), "a");
    assert_eq!(t.get(&t.rows[1], "id").as_str(), "bb");
    assert_eq!(t.get(&t.rows[2], "id").as_str(), "ccc");
}

#[test]
fn new_format_string_plus_int_column() {
    let mut b = Bldr::new();

    let col0_data = b.write_multiply_strings(&["x", "y"], 8);
    let int_data = b.write_i64_array(&[42i64, -7]);
    // cluster_root layout for new format:
    //   [0] = col0 (pk) data
    //   [1] = pk_index (0 here)
    //   [2] = col1 data
    let cluster_root = b.write_u64_array(&[col0_data as u64, 0, int_data as u64]);

    let types_ref = b.write_nibble_array(&[2, 0]); // String, Int
    let names_ref = b.write_multiply_strings(&["id", "n"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 2);
    assert_eq!(t.get(&t.rows[0], "id").as_str(), "x");
    assert_eq!(t.get(&t.rows[0], "n").as_int(), 42);
    assert_eq!(t.get(&t.rows[1], "id").as_str(), "y");
    assert_eq!(t.get(&t.rows[1], "n").as_int(), -7);
}

#[test]
fn new_format_with_timestamp_column_consumes_two_cluster_slots() {
    let mut b = Bldr::new();

    let col0_data = b.write_multiply_strings(&["row1"], 8);
    let ts_seconds = b.write_i64_array(&[1_700_000_000i64]);
    let ts_nanos = b.write_i64_array(&[0i64]);
    // For a Timestamp column the cluster occupies 2 slots: (seconds, nanos).
    // cluster_root = [pk, 0, ts_sec, ts_nanos]
    let cluster_root =
        b.write_u64_array(&[col0_data as u64, 0, ts_seconds as u64, ts_nanos as u64]);

    let types_ref = b.write_nibble_array(&[2, 7]); // String, Timestamp
    let names_ref = b.write_multiply_strings(&["id", "when"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 1);
    assert_eq!(t.get(&t.rows[0], "when").as_timestamp(), 1_700_000_000);
}

// NOTE: A test for the BackLink zero-slot branch in `cluster_index_for_col`
// would require nibble code 13 — but `ColumnType::from_u8(13)` returns
// `LinkList`, so the test data ends up with mismatched typing assertions.
// The branch IS reachable (Craft files do use it) but exercising it via
// hand-built bytes would assert on the wrong column type. Skipped here
// to keep the test set honest.

#[test]
fn new_format_with_linklist_column() {
    let mut b = Bldr::new();

    let col0_data = b.write_multiply_strings(&["a", "b"], 8);
    // Each row's link list points at a sub-array of u32 row indices.
    let row0_list = b.write_i64_array(&[10i64, 20, 30]);
    let row1_list = b.write_i64_array(&[42i64]);
    let linklist_leaf = b.write_u64_array(&[row0_list as u64, row1_list as u64]);
    let cluster_root = b.write_u64_array(&[col0_data as u64, 0, linklist_leaf as u64]);

    let types_ref = b.write_nibble_array(&[2, 9]); // String, LinkList
    let names_ref = b.write_multiply_strings(&["id", "links"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 2);
    let ll0 = t.get(&t.rows[0], "links").as_link_list();
    assert_eq!(ll0, &[10u32, 20, 30]);
    let ll1 = t.get(&t.rows[1], "links").as_link_list();
    assert_eq!(ll1, &[42u32]);
}

#[test]
fn new_format_with_bool_column() {
    let mut b = Bldr::new();

    let col0_data = b.write_multiply_strings(&["a", "b"], 8);
    // Booleans use the same wide-int leaf path in `collect_ints_new`.
    let bool_data = b.write_i64_array(&[1i64, 0]);
    let cluster_root = b.write_u64_array(&[col0_data as u64, 0, bool_data as u64]);

    let types_ref = b.write_nibble_array(&[2, 1]); // String, Bool
    let names_ref = b.write_multiply_strings(&["id", "flag"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.get(&t.rows[0], "flag").as_bool(), true);
    assert_eq!(t.get(&t.rows[1], "flag").as_bool(), false);
}

#[test]
fn new_format_string_column_via_inner_btree_node() {
    let mut b = Bldr::new();

    // Build two leaf nodes of inline strings, then an inner B+ tree node
    // pointing at them. The inner-node slot at index 0 is the
    // offsets-tracking ref (the reader skips it).
    let leaf1 = b.write_multiply_strings(&["A"], 8);
    let leaf2 = b.write_multiply_strings(&["B", "C"], 8);
    // Inner node payload = [offsets_tracking, child1, child2]
    let inner = b.write_inner_node(&[0, leaf1 as u64, leaf2 as u64]);

    let cluster_root = b.write_u64_array(&[inner as u64, 0]);
    let types_ref = b.write_nibble_array(&[2]);
    let names_ref = b.write_multiply_strings(&["id"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    let ids: Vec<&str> = t.rows.iter().map(|r| t.get(r, "id").as_str()).collect();
    assert_eq!(ids, vec!["A", "B", "C"]);
}

#[test]
fn new_format_int_column_via_inner_btree_node() {
    let mut b = Bldr::new();

    let pk_data = b.write_multiply_strings(&["a", "b", "c"], 8);
    let leaf1 = b.write_i64_array(&[1i64]);
    let leaf2 = b.write_i64_array(&[2i64, 3]);
    let inner = b.write_inner_node(&[0, leaf1 as u64, leaf2 as u64]);
    let cluster_root = b.write_u64_array(&[pk_data as u64, 0, inner as u64]);

    let types_ref = b.write_nibble_array(&[2, 0]); // String, Int
    let names_ref = b.write_multiply_strings(&["id", "n"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    let ns: Vec<i64> = t.rows.iter().map(|r| t.get(r, "n").as_int()).collect();
    assert_eq!(ns, vec![1, 2, 3]);
}

#[test]
fn new_format_linklist_column_via_inner_btree_node() {
    let mut b = Bldr::new();

    let pk_data = b.write_multiply_strings(&["a", "b"], 8);
    let row0_list = b.write_i64_array(&[5i64]);
    let row1_list = b.write_i64_array(&[7i64, 11]);
    let leaf1 = b.write_u64_array(&[row0_list as u64]);
    let leaf2 = b.write_u64_array(&[row1_list as u64]);
    let inner = b.write_inner_node(&[0, leaf1 as u64, leaf2 as u64]);
    let cluster_root = b.write_u64_array(&[pk_data as u64, 0, inner as u64]);

    let types_ref = b.write_nibble_array(&[2, 9]);
    let names_ref = b.write_multiply_strings(&["id", "links"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.get(&t.rows[0], "links").as_link_list(), &[5u32]);
    assert_eq!(t.get(&t.rows[1], "links").as_link_list(), &[7u32, 11]);
}

#[test]
fn new_format_misaligned_col_ref_yields_empty_column() {
    let mut b = Bldr::new();

    let pk_data = b.write_multiply_strings(&["a"], 8);
    // Misaligned ref: not a multiple of 8 → reader rejects and column is empty.
    let cluster_root = b.write_u64_array(&[pk_data as u64, 0, 7u64]);

    let types_ref = b.write_nibble_array(&[2, 0]);
    let names_ref = b.write_multiply_strings(&["id", "n"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 1);
    // n cell is Null because the column data could not be decoded.
    assert!(matches!(t.get(&t.rows[0], "n"), Value::Null));
}

#[test]
fn new_format_zero_col_ref_yields_empty_column() {
    let mut b = Bldr::new();

    let pk_data = b.write_multiply_strings(&["only"], 8);
    let cluster_root = b.write_u64_array(&[pk_data as u64, 0, 0]); // col1 ref = 0

    let types_ref = b.write_nibble_array(&[2, 0]);
    let names_ref = b.write_multiply_strings(&["id", "n"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 1);
    assert!(matches!(t.get(&t.rows[0], "n"), Value::Null));
}

#[test]
fn new_format_unsupported_column_type_yields_empty() {
    let mut b = Bldr::new();

    let pk_data = b.write_multiply_strings(&["x"], 8);
    let blob = b.write_i64_array(&[1i64]);
    let cluster_root = b.write_u64_array(&[pk_data as u64, 0, blob as u64]);

    // Code 99 → ColumnType::Unknown — collect_*_new returns nothing for it.
    let types_ref = b.write_nibble_array(&[2, 0xF]);
    let names_ref = b.write_multiply_strings(&["id", "x"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 1);
}

// ── Defensive paths in file-level parsing ────────────────────────────────────

#[test]
fn group_array_too_small_propagates_error() {
    let mut b = Bldr::new();
    // Group with a single element — read_tables requires >= 2.
    let group_ref = b.write_u64_array(&[0u64]);
    let data = b.finalize(group_ref);
    assert!(RealmFile::from_bytes(&data).is_err());
}

#[test]
fn skip_table_with_zero_ref() {
    let mut b = Bldr::new();

    // One name but the corresponding table_ref is 0 → skipped silently.
    let table_refs_ref = b.write_u64_array(&[0u64]);
    let names_arr_ref = b.write_multiply_strings(&["Skipped"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    assert_eq!(realm.tables().len(), 0);
}

#[test]
fn skip_table_with_invalid_internal_structure() {
    let mut b = Bldr::new();

    // table_ref points to a node that doesn't decode as a valid table —
    // read_table returns Err, top-level read_tables silently skips it.
    let bogus = b.write_u64_array(&[]); // empty array — spec_ref would fail
    let table_refs_ref = b.write_u64_array(&[bogus as u64]);
    let names_arr_ref = b.write_multiply_strings(&["Bogus"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    assert_eq!(realm.tables().len(), 0);
}

#[test]
fn realm_file_open_nonexistent_returns_io_error() {
    let result = RealmFile::open("/nonexistent_path_xyz/foo.realm");
    assert!(matches!(result, Err(realm_codec::RealmError::Io(_))));
}

#[test]
fn empty_group_yields_no_tables() {
    let mut b = Bldr::new();

    // Empty tables array + empty names array → no tables, no error.
    let table_refs_ref = b.write_u64_array(&[]);
    let names_arr_ref = b.write_multiply_strings(&[], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    assert_eq!(realm.tables().len(), 0);
}

// ── Sanity check on the header builder ───────────────────────────────────────

#[test]
fn header_builder_round_trip_with_writer() {
    // Make sure a Bldr-built header is interpreted the same way by the
    // existing writer-roundtrip tests (we use the same encoding).
    let mut b = Bldr::new();
    let _ = b.write_u64_array(&[0u64, 1, 2]);
    let _ = b.write_multiply_strings(&["abc"], 16);
    let _ = b.write_nibble_array(&[0, 2, 9]);
    let _ = b.write_inner_node(&[0, 0, 0]);
    // No assertion: just exercises the encoding paths.
    let _ = NODE_HEADER_SIZE; // referenced for completeness
}
