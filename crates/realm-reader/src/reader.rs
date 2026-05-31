//! High-level Realm file reader: Group → Tables → Rows.

use crate::format::{
    decode_short_string, multiply_elem_bytes, parse_file_header, read_bits_elem,
    NodeHeader, NODE_HEADER_SIZE, WTYPE_BITS, WTYPE_MULTIPLY,
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
    // Table array layout: [spec_ref, col_ref_0, col_ref_1, ...]
    let table_arr = read_array(data, table_ref)?;
    if table_arr.is_empty() {
        return Err(RealmError::InvalidFormat(format!(
            "table '{name}' array empty"
        )));
    }

    let spec_ref = table_arr[0] as usize;
    // Spec array: [types_ref (4-bit/col), names_ref (32-byte multiply slots)]
    let spec_arr = read_array(data, spec_ref)?;
    if spec_arr.len() < 2 {
        return Err(RealmError::InvalidFormat(format!(
            "table '{name}' spec too small"
        )));
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

    let col_refs: Vec<usize> = table_arr[1..].iter().map(|&r| r as usize).collect();

    // Determine row count from the first non-empty column reference.
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

// ── Row count ─────────────────────────────────────────────────────────────────

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
    // Inner node: last element is a ref to the cumulative-sizes array.
    // The last value in that array equals the total row count.
    let payload = &data[node_ref + NODE_HEADER_SIZE..];
    let sizes_ref = read_bits_elem(payload, hdr.size - 1, 64) as usize;
    read_array(data, sizes_ref)
        .ok()
        .and_then(|s| s.last().copied())
        .unwrap_or(0) as usize
}

// ── Cell reading ──────────────────────────────────────────────────────────────

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
                // Short string: each slot is `width` bytes
                let slot = multiply_elem_bytes(payload, row_idx, hdr.width);
                Ok(Value::String(decode_short_string(slot)))
            } else if hdr.wtype == WTYPE_BITS && hdr.width == 64 {
                // Long string: element is a ref to a string-leaf node
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

/// Traverse a B-tree inner node to locate the leaf cell at `row_idx`.
///
/// Inner-node layout: `[child_ref_0, ..., child_ref_n, cumulative_sizes_ref]`
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

    // Scan cumulative sizes to find the child subtree containing row_idx.
    let mut prev_cum = 0usize;
    for ci in 0..n_children {
        let cum = sizes.get(ci).copied().unwrap_or(0) as usize;
        if row_idx < cum {
            let child_ref = read_bits_elem(payload, ci, 64) as usize;
            // Local row index within this subtree = row_idx - previous cumulative count
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
