//! High-level Realm file reader: Group → Tables → Rows.

use crate::format::{
    decode_short_string, multiply_elem_bytes, parse_file_header, read_bits_elem,
    NodeHeader, NODE_HEADER_SIZE, WTYPE_BITS, WTYPE_IGNORE, WTYPE_MULTIPLY,
};
use crate::{ColumnType, RealmError, RealmTable, Result, Row, Value};

pub(crate) fn read_tables(data: &[u8]) -> Result<Vec<RealmTable>> {
    let (top_ref, _version) = parse_file_header(data)?;
    let group = read_array(data, top_ref)?;

    if group.len() < 2 {
        return Err(RealmError::InvalidFormat("group array too small".into()));
    }

    let names_ref = group[0] as usize;
    let tables_ref = group[1] as usize;

    let names = read_string_array_multiply(data, names_ref, 64)?;
    let table_refs = read_array(data, tables_ref)?;

    let count = names.len().min(table_refs.len());
    let mut tables = Vec::with_capacity(count);

    for i in 0..count {
        let tref = table_refs[i] as usize;
        if tref == 0 {
            continue;
        }
        if let Ok(t) = read_table(data, &names[i], tref) {
            tables.push(t);
        }
    }

    Ok(tables)
}

// ── Array primitives ──────────────────────────────────────────────────────────

/// Parse the array at `offset` and return its elements as `Vec<u64>`.
fn read_array(data: &[u8], offset: usize) -> Result<Vec<u64>> {
    if offset + NODE_HEADER_SIZE > data.len() {
        return Err(RealmError::InvalidFormat(format!(
            "array offset {offset:#x} out of bounds"
        )));
    }
    let hdr = NodeHeader::parse(data[offset..offset + 8].try_into().unwrap());
    let payload = &data[offset + NODE_HEADER_SIZE..];

    let mut elems = Vec::with_capacity(hdr.size);
    match hdr.wtype {
        WTYPE_BITS => {
            for i in 0..hdr.size {
                elems.push(read_bits_elem(payload, i, hdr.width));
            }
        }
        WTYPE_MULTIPLY => {
            for i in 0..hdr.size {
                let slot = multiply_elem_bytes(payload, i, hdr.width);
                let val = match hdr.width {
                    8 => u64::from_le_bytes(slot.try_into().unwrap_or([0u8; 8])),
                    4 => u32::from_le_bytes(slot.try_into().unwrap_or([0u8; 4])) as u64,
                    2 => u16::from_le_bytes(slot.try_into().unwrap_or([0u8; 2])) as u64,
                    1 => slot[0] as u64,
                    _ => 0,
                };
                elems.push(val);
            }
        }
        _ => {}
    }
    Ok(elems)
}

fn read_string_array_multiply(data: &[u8], offset: usize, slot_width: u8) -> Result<Vec<String>> {
    if offset + NODE_HEADER_SIZE > data.len() {
        return Err(RealmError::InvalidFormat(format!(
            "string array offset {offset:#x} out of bounds"
        )));
    }
    let hdr = NodeHeader::parse(data[offset..offset + 8].try_into().unwrap());
    let payload = &data[offset + NODE_HEADER_SIZE..];
    let mut result = Vec::with_capacity(hdr.size);
    for i in 0..hdr.size {
        let slot = multiply_elem_bytes(payload, i, slot_width);
        result.push(decode_short_string(slot));
    }
    Ok(result)
}

// ── Table ─────────────────────────────────────────────────────────────────────

fn read_table(data: &[u8], name: &str, table_ref: usize) -> Result<RealmTable> {
    let table_arr = read_array(data, table_ref)?;
    if table_arr.is_empty() {
        return Err(RealmError::InvalidFormat(format!("table '{name}' array empty")));
    }

    let spec_ref = table_arr[0] as usize;
    let spec_arr = read_array(data, spec_ref)?;
    if spec_arr.len() < 2 {
        return Err(RealmError::InvalidFormat(format!("table '{name}' spec too small")));
    }

    let col_names = read_string_array_multiply(data, spec_arr[1] as usize, 32)?;
    let col_type_ints = read_array(data, spec_arr[0] as usize)?;

    let columns: Vec<(String, ColumnType)> = col_names
        .iter()
        .enumerate()
        .map(|(i, n)| {
            let t = col_type_ints.get(i).copied().unwrap_or(0) as u8;
            (n.clone(), ColumnType::from_u8(t))
        })
        .collect();

    // Realm SDK 5+ "cluster tree" format: spec_arr has ≥ 4 elements.
    // table_arr = [spec_ref, cluster_root_ref] (only 2 elements).
    if spec_arr.len() >= 4 {
        if table_arr.len() < 2 {
            return Err(RealmError::InvalidFormat(format!(
                "table '{name}' new-format table_arr too small"
            )));
        }
        let cluster_root_ref = table_arr[1] as usize;
        let cluster_root = read_array(data, cluster_root_ref)?;
        return read_table_new(data, name, &columns, &col_type_ints, &cluster_root);
    }

    // Old format: table_arr = [spec_ref, col_ref_0, col_ref_1, ...]
    let col_refs: Vec<usize> = table_arr[1..].iter().map(|&r| r as usize).collect();

    let row_count = col_refs
        .iter()
        .find(|&&r| r != 0)
        .map(|&r| count_node_rows(data, r))
        .unwrap_or(0);

    let mut rows = Vec::with_capacity(row_count);
    for row_idx in 0..row_count {
        let values = col_refs
            .iter()
            .enumerate()
            .take(columns.len())
            .map(|(ci, &col_ref)| {
                let col_type = columns[ci].1;
                read_cell(data, col_ref, row_idx, col_type).unwrap_or(Value::Null)
            })
            .collect();
        rows.push(Row { values });
    }

    Ok(RealmTable { name: name.to_string(), columns, rows })
}

// ── New-format (cluster tree) table reader ────────────────────────────────────

/// Build a `RealmTable` from a Realm SDK 5+ cluster-tree table.
///
/// Cluster layout:
///   cluster[0]   = col[0] (primary key column — always a string in practice)
///   cluster[1]   = pk_index B+ tree (skip — not a data column)
///   cluster[2..] = col[1], col[2], ...  with these exceptions:
///     type 8  (Timestamp) occupies 2 slots (seconds + fractionals)
///     type 13 (BackLink)  occupies 0 slots (virtual column, no cluster entry)
fn read_table_new(
    data: &[u8],
    name: &str,
    columns: &[(String, ColumnType)],
    col_type_ints: &[u64],
    cluster_root: &[u64],
) -> Result<RealmTable> {
    let mut col_values: Vec<Vec<Value>> = Vec::with_capacity(columns.len());

    for (col_idx, (_, col_type)) in columns.iter().enumerate() {
        let ci = cluster_index_for_col(col_idx, col_type_ints);
        let col_ref = cluster_root.get(ci).copied().unwrap_or(0) as usize;

        let values: Vec<Value> = if col_ref == 0 {
            vec![]
        } else {
            match col_type {
                ColumnType::String | ColumnType::Data => collect_strings_new(data, col_ref)
                    .into_iter()
                    .map(Value::String)
                    .collect(),
                ColumnType::Bool => collect_ints_new(data, col_ref)
                    .into_iter()
                    .map(|v| Value::Bool(v != 0))
                    .collect(),
                ColumnType::Int => collect_ints_new(data, col_ref)
                    .into_iter()
                    .map(|v| Value::Int(v as i64))
                    .collect(),
                ColumnType::Timestamp => collect_ints_new(data, col_ref)
                    .into_iter()
                    .map(|v| Value::Timestamp(v as i64))
                    .collect(),
                _ => vec![],
            }
        };
        col_values.push(values);
    }

    let row_count = col_values.iter().map(|v| v.len()).max().unwrap_or(0);
    let mut rows = Vec::with_capacity(row_count);
    for row_idx in 0..row_count {
        let values: Vec<Value> = col_values
            .iter()
            .map(|cv| cv.get(row_idx).cloned().unwrap_or(Value::Null))
            .collect();
        rows.push(Row { values });
    }

    Ok(RealmTable { name: name.to_string(), columns: columns.to_vec(), rows })
}

/// Map a column index to its position in the cluster root array.
///
/// col[0] → cluster[0]; pk_index at cluster[1] is skipped.
/// For col[k ≥ 1]: start at cluster[2] and account for multi-slot types
/// encountered in cols 1..k-1 (type 8 = 2 slots, type 13 = 0 slots).
fn cluster_index_for_col(col_idx: usize, col_type_ints: &[u64]) -> usize {
    if col_idx == 0 {
        return 0;
    }
    // col[1] starts at cluster[2] (cluster[0]=pk_col, cluster[1]=pk_index)
    let mut ci = 2usize;
    for k in 1..col_idx {
        let ct = col_type_ints.get(k).copied().unwrap_or(0) as u8;
        match ct {
            8 => ci += 2,  // Timestamp: seconds + fractionals = 2 cluster slots
            13 => {}       // BackLink: virtual, 0 cluster slots
            _ => ci += 1,
        }
    }
    ci
}

// ── New-format string collection ──────────────────────────────────────────────

/// Collect all strings from a column's B+ tree (new format).
///
/// Inner nodes: `[offsets_tracking_ref, child_0, ..., child_{N-1}]`
/// — element 0 is always the offsets-tracking node (skip).
/// — garbage refs (misaligned addresses) are detected and skipped.
fn collect_strings_new(data: &[u8], col_ref: usize) -> Vec<String> {
    if col_ref == 0 || col_ref % 8 != 0 || col_ref + NODE_HEADER_SIZE > data.len() {
        return vec![];
    }
    let hdr = NodeHeader::parse(data[col_ref..col_ref + 8].try_into().unwrap());

    if hdr.is_inner {
        let children = match read_array(data, col_ref) {
            Ok(c) => c,
            Err(_) => return vec![],
        };
        let mut result = vec![];
        for (j, &child_u64) in children.iter().enumerate() {
            if j == 0 {
                continue; // always the offsets-tracking ref
            }
            let child_ref = child_u64 as usize;
            // Realm nodes are always 8-byte aligned; misaligned = garbage
            if child_ref == 0 || child_ref % 8 != 0 || child_ref + NODE_HEADER_SIZE > data.len() {
                continue;
            }
            result.extend(collect_strings_new(data, child_ref));
        }
        return result;
    }

    collect_string_leaf(data, col_ref, &hdr)
}

/// Dispatch to the correct leaf reader based on node shape.
///
/// Three leaf types observed in Realm 5+ string columns:
///   1. Compact string  — `wtype=0, size ∈ {2,3}`: `[offsets_ref, blob_ref]`
///   2. Per-row refs    — `wtype=0, width ≥ 16, size > 3`: each elem → wtype=2 node
///   3. Inline strings  — `wtype=1`: fixed-width slots, `decode_short_string` encoding
fn collect_string_leaf(data: &[u8], leaf_ref: usize, hdr: &NodeHeader) -> Vec<String> {
    match hdr.wtype {
        WTYPE_BITS => {
            if hdr.size <= 3 {
                read_compact_string_leaf(data, leaf_ref).unwrap_or_default()
            } else if hdr.size < 100_000 && hdr.width >= 16 {
                read_perrow_string_refs(data, leaf_ref)
            } else {
                vec![]
            }
        }
        WTYPE_MULTIPLY if hdr.width > 0 && hdr.size > 0 && hdr.size < 100_000 => {
            let payload_start = leaf_ref + NODE_HEADER_SIZE;
            let needed = hdr.size * hdr.width as usize;
            if payload_start + needed > data.len() {
                return vec![];
            }
            let payload = &data[payload_start..];
            (0..hdr.size)
                .map(|i| decode_short_string(multiply_elem_bytes(payload, i, hdr.width)))
                .collect()
        }
        _ => vec![],
    }
}

/// Read a compact-string leaf node: `[offsets_ref, blob_ref]`.
///
/// `offsets[r]` = byte offset one past the null terminator of string r.
/// The blob is a wtype=2 (WTYPE_IGNORE) node holding the concatenated
/// null-terminated UTF-8 strings.
fn read_compact_string_leaf(data: &[u8], leaf_ref: usize) -> Result<Vec<String>> {
    let elems = read_array(data, leaf_ref)?;
    if elems.len() < 2 {
        return Ok(vec![]);
    }
    let offsets_ref = elems[0] as usize;
    let blob_ref = elems[1] as usize;

    if offsets_ref == 0 || offsets_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(vec![]);
    }
    if blob_ref == 0 || blob_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(vec![]);
    }

    let blob_hdr = NodeHeader::parse(data[blob_ref..blob_ref + 8].try_into().unwrap());
    if blob_hdr.wtype != WTYPE_IGNORE {
        return Ok(vec![]);
    }
    let blob_end = (blob_ref + NODE_HEADER_SIZE + blob_hdr.size).min(data.len());
    let blob = &data[blob_ref + NODE_HEADER_SIZE..blob_end];

    let offsets = read_array(data, offsets_ref)?;
    let mut strings = Vec::with_capacity(offsets.len());
    for r in 0..offsets.len() {
        let start = if r == 0 { 0 } else { offsets[r - 1] as usize };
        // offsets[r] points one past the null terminator; subtract 1 for the string end
        let raw_end = offsets[r] as usize;
        let end = if raw_end > 0 { (raw_end - 1).min(blob.len()) } else { start };
        let start = start.min(end);
        strings.push(String::from_utf8_lossy(&blob[start..end]).into_owned());
    }
    Ok(strings)
}

/// Read a per-row string ref leaf: each element is a file offset to a wtype=2 node.
fn read_perrow_string_refs(data: &[u8], leaf_ref: usize) -> Vec<String> {
    let refs = match read_array(data, leaf_ref) {
        Ok(r) => r,
        Err(_) => return vec![],
    };
    refs.into_iter()
        .map(|str_ref_u64| {
            let str_ref = str_ref_u64 as usize;
            if str_ref == 0 || str_ref % 8 != 0 || str_ref + NODE_HEADER_SIZE > data.len() {
                return String::new();
            }
            read_wtype2_string(data, str_ref).unwrap_or_default()
        })
        .collect()
}

/// Read raw UTF-8 from a wtype=2 (WTYPE_IGNORE) node, stripping a trailing null if present.
fn read_wtype2_string(data: &[u8], str_ref: usize) -> Result<String> {
    let hdr = NodeHeader::parse(data[str_ref..str_ref + 8].try_into().unwrap());
    if hdr.wtype != WTYPE_IGNORE {
        return Ok(String::new());
    }
    let payload = &data[str_ref + NODE_HEADER_SIZE..];
    let len = hdr.size.min(payload.len());
    let end = if len > 0 && payload[len - 1] == 0 { len - 1 } else { len };
    Ok(String::from_utf8_lossy(&payload[..end]).into_owned())
}

// ── New-format integer collection ─────────────────────────────────────────────

/// Collect all integer elements from a column's B+ tree (new format).
///
/// Same inner-node layout as for strings: skip element 0 (offsets-tracking),
/// filter garbage children by alignment.
fn collect_ints_new(data: &[u8], col_ref: usize) -> Vec<u64> {
    if col_ref == 0 || col_ref % 8 != 0 || col_ref + NODE_HEADER_SIZE > data.len() {
        return vec![];
    }
    let hdr = NodeHeader::parse(data[col_ref..col_ref + 8].try_into().unwrap());

    if hdr.is_inner {
        let children = match read_array(data, col_ref) {
            Ok(c) => c,
            Err(_) => return vec![],
        };
        let mut result = vec![];
        for (j, &child_u64) in children.iter().enumerate() {
            if j == 0 {
                continue;
            }
            let child_ref = child_u64 as usize;
            if child_ref == 0 || child_ref % 8 != 0 || child_ref + NODE_HEADER_SIZE > data.len() {
                continue;
            }
            result.extend(collect_ints_new(data, child_ref));
        }
        return result;
    }

    if hdr.wtype == WTYPE_BITS && hdr.size < 100_000 {
        read_array(data, col_ref).unwrap_or_default()
    } else {
        vec![]
    }
}

// ── Old-format: row count + cell reading ──────────────────────────────────────

/// Count rows in a column node, traversing B-tree inner nodes if needed.
fn count_node_rows(data: &[u8], node_ref: usize) -> usize {
    if node_ref + NODE_HEADER_SIZE > data.len() {
        return 0;
    }
    let hdr = NodeHeader::parse(data[node_ref..node_ref + 8].try_into().unwrap());
    if !hdr.is_inner {
        return hdr.size;
    }
    if hdr.size == 0 {
        return 0;
    }
    // Old format inner node: last element is a ref to the cumulative-sizes array.
    let payload = &data[node_ref + NODE_HEADER_SIZE..];
    let sizes_ref = read_bits_elem(payload, hdr.size - 1, 64) as usize;
    read_array(data, sizes_ref)
        .ok()
        .and_then(|s| s.last().copied())
        .unwrap_or(0) as usize
}

fn read_cell(data: &[u8], col_ref: usize, row_idx: usize, col_type: ColumnType) -> Result<Value> {
    if col_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(Value::Null);
    }
    let hdr = NodeHeader::parse(data[col_ref..col_ref + 8].try_into().unwrap());

    if hdr.is_inner {
        return read_cell_btree(data, col_ref, row_idx, col_type);
    }

    if row_idx >= hdr.size {
        return Ok(Value::Null);
    }

    let payload = &data[col_ref + NODE_HEADER_SIZE..];

    match col_type {
        ColumnType::Bool => Ok(Value::Bool(read_bits_elem(payload, row_idx, hdr.width) != 0)),
        ColumnType::Int => Ok(Value::Int(read_bits_elem(payload, row_idx, hdr.width) as i64)),
        ColumnType::Timestamp => {
            Ok(Value::Timestamp(read_bits_elem(payload, row_idx, hdr.width) as i64))
        }
        ColumnType::Link | ColumnType::LinkList | ColumnType::BackLink => {
            Ok(Value::Link(read_bits_elem(payload, row_idx, hdr.width) as usize))
        }
        ColumnType::Float if hdr.width == 32 => {
            let off = row_idx * 4;
            let f = f32::from_le_bytes(payload[off..off + 4].try_into().unwrap_or([0; 4]));
            Ok(Value::Float(f as f64))
        }
        ColumnType::Double if hdr.width == 64 => {
            let off = row_idx * 8;
            let f = f64::from_le_bytes(payload[off..off + 8].try_into().unwrap_or([0; 8]));
            Ok(Value::Float(f))
        }
        ColumnType::String | ColumnType::Data => {
            if hdr.wtype == WTYPE_MULTIPLY && hdr.width > 0 {
                let slot = multiply_elem_bytes(payload, row_idx, hdr.width);
                Ok(Value::String(decode_short_string(slot)))
            } else if hdr.wtype == WTYPE_BITS && hdr.width == 64 {
                let str_ref = read_bits_elem(payload, row_idx, 64) as usize;
                if str_ref == 0 {
                    return Ok(Value::String(String::new()));
                }
                Ok(Value::String(read_leaf_string(data, str_ref)?))
            } else {
                Ok(Value::Null)
            }
        }
        _ => Ok(Value::Null),
    }
}

/// Traverse an old-format B-tree inner node to locate the leaf cell at `row_idx`.
///
/// Old-format layout: `[child_ref_0, ..., child_ref_n, cumulative_sizes_ref]`
/// `cumulative_sizes[i]` = total rows in subtrees 0..=i.
fn read_cell_btree(
    data: &[u8],
    node_ref: usize,
    row_idx: usize,
    col_type: ColumnType,
) -> Result<Value> {
    if node_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(Value::Null);
    }
    let hdr = NodeHeader::parse(data[node_ref..node_ref + 8].try_into().unwrap());

    if !hdr.is_inner {
        return read_cell(data, node_ref, row_idx, col_type);
    }

    if hdr.size == 0 {
        return Ok(Value::Null);
    }

    let payload = &data[node_ref + NODE_HEADER_SIZE..];
    let n_children = hdr.size - 1;
    let sizes_ref = read_bits_elem(payload, hdr.size - 1, 64) as usize;
    let sizes = read_array(data, sizes_ref)?;

    let mut prev_cum = 0usize;
    for ci in 0..n_children {
        let cum = sizes.get(ci).copied().unwrap_or(0) as usize;
        if row_idx < cum {
            let child_ref = read_bits_elem(payload, ci, 64) as usize;
            return read_cell_btree(data, child_ref, row_idx - prev_cum, col_type);
        }
        prev_cum = cum;
    }

    Ok(Value::Null)
}

fn read_leaf_string(data: &[u8], str_ref: usize) -> Result<String> {
    if str_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(String::new());
    }
    let hdr = NodeHeader::parse(data[str_ref..str_ref + 8].try_into().unwrap());
    let payload = &data[str_ref + NODE_HEADER_SIZE..];

    if hdr.wtype == WTYPE_MULTIPLY && hdr.width > 0 {
        let slot = multiply_elem_bytes(payload, 0, hdr.width);
        return Ok(decode_short_string(slot));
    }

    // Fallback: raw bytes up to first null byte
    let len = payload.len().min(hdr.size);
    let end = payload[..len].iter().position(|&b| b == 0).unwrap_or(len);
    Ok(String::from_utf8_lossy(&payload[..end]).into_owned())
}
