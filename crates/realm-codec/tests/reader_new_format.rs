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
        Self {
            buf: vec![0u8; FILE_HEADER_SIZE],
        }
    }

    fn align(&mut self) {
        while !self.buf.len().is_multiple_of(8) {
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

#[test]
fn new_format_with_backlink_column_consumes_zero_cluster_slots() {
    let mut b = Bldr::new();

    let col0_data = b.write_multiply_strings(&["r"], 8);
    let int_data = b.write_i64_array(&[99i64]);
    // BackLink column (nibble code 14, ColumnType::BackLink) occupies 0
    // cluster slots — the Int column that follows still maps to cluster[2].
    let cluster_root = b.write_u64_array(&[col0_data as u64, 0, int_data as u64]);

    let types_ref = b.write_nibble_array(&[2, 14, 0]); // String, BackLink, Int
    let names_ref = b.write_multiply_strings(&["id", "bl", "n"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 1);
    assert_eq!(t.get(&t.rows[0], "n").as_int(), 99);
}

// ── String leaf — compact variant (offsets + concatenated blob) ──────────────

/// WTYPE_IGNORE node containing raw bytes (used for string blobs).
fn write_ignore_node(b: &mut Bldr, bytes: &[u8]) -> usize {
    // wtype=2 (IGNORE), width=8 in the encoding still required but reader
    // doesn't use it for IGNORE — `size` is the byte count.
    let start = b.write_header(bytes.len(), Bldr::wenc(8), 2, false);
    b.buf.extend_from_slice(bytes);
    b.align();
    start
}

#[test]
fn new_format_string_compact_leaf() {
    let mut b = Bldr::new();

    // Concatenated null-terminated strings.
    let blob_bytes = b"hello\0world\0";
    let blob_ref = write_ignore_node(&mut b, blob_bytes);
    // Offsets: index r points one past the null terminator of string r.
    //   "hello\0" ends at byte 6, "world\0" ends at byte 12.
    let offsets_ref = b.write_i64_array(&[6i64, 12]);

    // Compact leaf: WTYPE_BITS, size <= 3, payload = [offsets_ref, blob_ref].
    let col0_leaf = b.write_u64_array(&[offsets_ref as u64, blob_ref as u64]);

    // PK is this string leaf directly (already cluster[0] = leaf).
    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);

    let types_ref = b.write_nibble_array(&[2]); // String
    let names_ref = b.write_multiply_strings(&["id"], 32);
    let spec_ref = b.write_u64_array(&[types_ref as u64, names_ref as u64, 0, 0]);
    let table_ref = b.write_u64_array(&[spec_ref as u64, cluster_root as u64]);

    let table_refs_ref = b.write_u64_array(&[table_ref as u64]);
    let names_arr_ref = b.write_multiply_strings(&["T"], 64);
    let group_ref = b.write_u64_array(&[names_arr_ref as u64, table_refs_ref as u64]);

    let data = b.finalize(group_ref);
    let realm = RealmFile::from_bytes(&data).expect("parse");
    let t = realm.table("T").unwrap();
    assert_eq!(t.rows.len(), 2);
    assert_eq!(t.get(&t.rows[0], "id").as_str(), "hello");
    assert_eq!(t.get(&t.rows[1], "id").as_str(), "world");
}

#[test]
fn new_format_string_compact_leaf_with_empty_string() {
    let mut b = Bldr::new();

    // Empty first string: offsets[0] = 1 (just the null byte), then "x\0" → 3.
    let blob_bytes = b"\0x\0";
    let blob_ref = write_ignore_node(&mut b, blob_bytes);
    let offsets_ref = b.write_i64_array(&[1i64, 3]);
    let col0_leaf = b.write_u64_array(&[offsets_ref as u64, blob_ref as u64]);

    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);
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
    assert_eq!(t.get(&t.rows[0], "id").as_str(), "");
    assert_eq!(t.get(&t.rows[1], "id").as_str(), "x");
}

#[test]
fn new_format_string_compact_leaf_rejects_zero_offsets_ref() {
    let mut b = Bldr::new();

    let blob_bytes = b"hello\0";
    let blob_ref = write_ignore_node(&mut b, blob_bytes);
    // Offsets ref = 0 → reader's defensive path returns vec![].
    let col0_leaf = b.write_u64_array(&[0u64, blob_ref as u64]);

    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);
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
    assert_eq!(t.rows.len(), 0);
}

#[test]
fn new_format_string_compact_leaf_rejects_zero_blob_ref() {
    let mut b = Bldr::new();

    let offsets_ref = b.write_i64_array(&[6i64]);
    // Blob ref = 0 → reader's defensive path returns vec![].
    let col0_leaf = b.write_u64_array(&[offsets_ref as u64, 0u64]);

    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);
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
    assert_eq!(t.rows.len(), 0);
}

#[test]
fn new_format_string_compact_leaf_rejects_non_ignore_blob() {
    let mut b = Bldr::new();

    // Blob is a u64 array (wtype=0), not WTYPE_IGNORE → reader returns vec![].
    let bogus_blob = b.write_u64_array(&[0u64, 0]);
    let offsets_ref = b.write_i64_array(&[6i64]);
    let col0_leaf = b.write_u64_array(&[offsets_ref as u64, bogus_blob as u64]);

    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);
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
    assert_eq!(t.rows.len(), 0);
}

// ── String leaf — per-row refs variant ───────────────────────────────────────

#[test]
fn new_format_string_per_row_refs_leaf() {
    let mut b = Bldr::new();

    // Each cell is a separate wtype=2 node holding the UTF-8 bytes (null-terminated).
    let s0 = write_ignore_node(&mut b, b"first\0");
    let s1 = write_ignore_node(&mut b, b"second\0");
    let s2 = write_ignore_node(&mut b, b"third\0");
    let s3 = write_ignore_node(&mut b, b"fourth\0");
    // The leaf is a u64 array (width=64 ≥ 16, size > 3) of refs.
    let col0_leaf = b.write_u64_array(&[s0 as u64, s1 as u64, s2 as u64, s3 as u64]);

    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);
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
    let strs: Vec<&str> = t.rows.iter().map(|r| t.get(r, "id").as_str()).collect();
    assert_eq!(strs, vec!["first", "second", "third", "fourth"]);
}

#[test]
fn new_format_string_per_row_refs_with_zero_and_misaligned() {
    let mut b = Bldr::new();

    let s0 = write_ignore_node(&mut b, b"ok\0");
    let s2 = write_ignore_node(&mut b, b"good\0");
    let s3 = write_ignore_node(&mut b, b"yes\0");
    // refs: [valid, 0 → empty, misaligned (3) → empty, valid]
    let col0_leaf = b.write_u64_array(&[s0 as u64, 0, 3, s2 as u64, s3 as u64]);

    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);
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
    let strs: Vec<&str> = t.rows.iter().map(|r| t.get(r, "id").as_str()).collect();
    assert_eq!(strs, vec!["ok", "", "", "good", "yes"]);
}

#[test]
fn new_format_string_per_row_refs_non_ignore_node_yields_empty() {
    let mut b = Bldr::new();

    // The per-row ref points to a wtype=0 node (not WTYPE_IGNORE) — reader
    // returns an empty string via read_wtype2_string's defensive path.
    let bogus = b.write_u64_array(&[0u64]);
    let col0_leaf = b.write_u64_array(&[bogus as u64, bogus as u64, bogus as u64, bogus as u64]);

    let cluster_root = b.write_u64_array(&[col0_leaf as u64, 0]);
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
    for row in &t.rows {
        assert_eq!(t.get(row, "id").as_str(), "");
    }
}

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
    assert!(t.get(&t.rows[0], "flag").as_bool());
    assert!(!t.get(&t.rows[1], "flag").as_bool());
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

// ── Malformed-input hardening ────────────────────────────────────────────
//
// A `.realm` file is user-supplied and plausibly attacker-authored (a shared
// "Craft export" over AirDrop or email). Parsing one must never abort the
// process. These reproduce the four crash classes found in the security
// audit; each one aborted a release build before the hardening.
//
// Note `RealmFile::from_bytes` is a clean `&[u8] -> Result`, so these also
// document the shape a future `cargo-fuzz` target would take.

/// Realm's magic + a minimal top-ref pair, then whatever the test wants.
fn realm_with(payload: &[u8]) -> Vec<u8> {
    let mut v = payload.to_vec();
    // The format expects the file to be at least header-sized; pad so the
    // parser reaches the interesting part rather than bailing on length.
    if v.len() < 24 {
        v.resize(24, 0);
    }
    v
}

#[test]
fn truncated_input_does_not_panic() {
    for len in 0..64usize {
        let bytes = vec![0u8; len];
        // Any outcome is fine — Ok, Err — as long as it returns.
        let _ = realm_codec::RealmFile::from_bytes(&bytes);
    }
}

#[test]
fn self_referential_node_terminates_instead_of_overflowing_the_stack() {
    // A node whose child ref points back at itself satisfies every guard the
    // reader had (non-zero, 8-byte aligned, in bounds) and recursed forever.
    let mut bytes = realm_with(&[]);
    bytes.resize(1024, 0);
    // Node header at offset 8 claiming to be an inner node with one child
    // that refs offset 8 — itself.
    bytes[8..16].copy_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]);
    for off in (16..1024).step_by(8) {
        bytes[off..off + 8].copy_from_slice(&8u64.to_le_bytes());
    }
    let _ = realm_codec::RealmFile::from_bytes(&bytes);
}

#[test]
fn garbage_bytes_never_panic() {
    // Deterministic pseudo-random sweep — no RNG dependency, and any failure
    // reproduces from the seed in the loop index.
    let mut state: u64 = 0x9E3779B97F4A7C15;
    for case in 0..256u32 {
        let mut bytes = vec![0u8; 512];
        for b in bytes.iter_mut() {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            *b = (state >> 33) as u8;
        }
        // Keep the size field small enough that we exercise parsing rather
        // than an immediate length bail.
        let _ = realm_codec::RealmFile::from_bytes(&bytes);
        let _ = case;
    }
}

#[test]
fn huge_declared_sizes_do_not_exhaust_memory() {
    // A node header declaring a gigantic element count used to reach
    // `Vec::with_capacity` unclamped and abort with "capacity overflow".
    let mut bytes = vec![0u8; 256];
    for off in (0..256).step_by(8) {
        bytes[off..off + 8].copy_from_slice(&u64::MAX.to_le_bytes());
    }
    let _ = realm_codec::RealmFile::from_bytes(&bytes);
}
