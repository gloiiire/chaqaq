//! High-level Realm file reader: Group → Tables → Rows.

use crate::format::{
    decode_short_string, multiply_elem_bytes, parse_file_header, read_bits_elem,
    NodeHeader, NODE_HEADER_SIZE, WTYPE_BITS, WTYPE_IGNORE, WTYPE_MULTIPLY,
};
use crate::{ColumnType, RealmError, RealmTable, Result, Row, Value};

/// Reads the raw file bytes and returns a list of `RealmTable`.
pub fn read_tables(data: &[u8]) -> Result<Vec<RealmTable>> {
    let (top_ref, _version) = parse_file_header(data)?;
    let group = read_array(data, top_ref)?;

    // Group children: [0]=names_ref, [1]=tables_ref (both are refs)
    if group.len() < 2 {
        return Err(RealmError::InvalidFormat("group array too small".into()));
    }

    let names_ref = group[0] as usize;
    let tables_ref = group[1] as usize;

    let table_refs = read_array(data, tables_ref)?;

    // names array: WTYPE_MULTIPLY, width=64 bytes per slot
    let names = read_string_array_multiply(data, names_ref, 64)?;
    // table_refs array: WTYPE_BITS width=64 (each element is an 8-byte ref)
    // We already have them in table_refs vec as u64 values

    let count = names.len().min(table_refs.len());
    let mut tables = Vec::with_capacity(count);

    for i in 0..count {
        let name = names[i].clone();
        let tref = table_refs[i] as usize;
        if tref == 0 {
            continue;
        }
        match read_table(data, &name, tref) {
            Ok(t) => tables.push(t),
            Err(_) => {} // skip malformed tables
        }
    }

    Ok(tables)
}

/// Parse the array at `offset` and return its elements as Vec<u64>.
/// For WTYPE_MULTIPLY the value is the byte offset of each slot (raw ref or data).
fn read_array(data: &[u8], offset: usize) -> Result<Vec<u64>> {
    if offset + NODE_HEADER_SIZE > data.len() {
        return Err(RealmError::InvalidFormat(format!(
            "array offset {:#x} out of bounds",
            offset
        )));
    }
    let h: [u8; 8] = data[offset..offset + 8].try_into().unwrap();
    let hdr = NodeHeader::parse(&h);
    let payload = &data[offset + NODE_HEADER_SIZE..];

    let mut elems = Vec::with_capacity(hdr.size);
    match hdr.wtype {
        WTYPE_BITS => {
            for i in 0..hdr.size {
                elems.push(read_bits_elem(payload, i, hdr.width));
            }
        }
        WTYPE_MULTIPLY => {
            // Each element is `width` bytes; treat as a little-endian integer ref
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
        WTYPE_IGNORE => {}
        _ => {}
    }
    Ok(elems)
}

/// Read a multiply-encoded string array (slot_width bytes per string slot).
fn read_string_array_multiply(data: &[u8], offset: usize, slot_width: u8) -> Result<Vec<String>> {
    if offset + NODE_HEADER_SIZE > data.len() {
        return Err(RealmError::InvalidFormat(format!(
            "string array offset {:#x} out of bounds",
            offset
        )));
    }
    let h: [u8; 8] = data[offset..offset + 8].try_into().unwrap();
    let hdr = NodeHeader::parse(&h);
    let payload = &data[offset + NODE_HEADER_SIZE..];
    let mut result = Vec::with_capacity(hdr.size);
    for i in 0..hdr.size {
        let slot = multiply_elem_bytes(payload, i, slot_width);
        result.push(decode_short_string(slot));
    }
    Ok(result)
}

/// Read a Realm table at the given top ref offset.
fn read_table(data: &[u8], name: &str, table_ref: usize) -> Result<RealmTable> {
    // Table array: [0]=spec_ref, [1..]=column_refs
    let table_arr = read_array(data, table_ref)?;
    if table_arr.is_empty() {
        return Err(RealmError::InvalidFormat(format!(
            "table '{}' array empty",
            name
        )));
    }

    let spec_ref = table_arr[0] as usize;
    // spec array: [0]=types_ref (4-bit per col), [1]=names_ref (32-byte multiply)
    let spec_arr = read_array(data, spec_ref)?;
    if spec_arr.len() < 2 {
        return Err(RealmError::InvalidFormat(format!(
            "table '{}' spec too small",
            name
        )));
    }

    let types_ref = spec_arr[0] as usize;
    let names_ref = spec_arr[1] as usize;

    let col_names = read_string_array_multiply(data, names_ref, 32)?;
    let col_type_ints = read_array(data, types_ref)?;

    let mut columns = Vec::with_capacity(col_names.len());
    for (i, col_name) in col_names.iter().enumerate() {
        let type_int = col_type_ints.get(i).copied().unwrap_or(0) as u8;
        columns.push((col_name.clone(), ColumnType::from_u8(type_int)));
    }

    // Read rows: column data refs start at table_arr[1..]
    // Each column_ref is an array of row values
    let num_cols = columns.len();
    let col_refs: Vec<usize> = table_arr[1..].iter().map(|&r| r as usize).collect();

    let row_count = if col_refs.is_empty() {
        0
    } else {
        estimate_row_count(data, col_refs[0]).unwrap_or(0)
    };

    let mut rows = Vec::with_capacity(row_count);
    for row_idx in 0..row_count {
        let mut row_vals = Vec::with_capacity(num_cols);
        for (col_idx, &col_ref) in col_refs.iter().enumerate() {
            if col_idx >= num_cols {
                break;
            }
            let col_type = columns[col_idx].1;
            let val = read_cell(data, col_ref, row_idx, col_type).unwrap_or(Value::Null);
            row_vals.push(val);
        }
        rows.push(Row { values: row_vals });
    }

    Ok(RealmTable {
        name: name.to_string(),
        columns,
        rows,
    })
}

/// Estimate row count from the first column's array (simple leaf only).
fn estimate_row_count(data: &[u8], col_ref: usize) -> Result<usize> {
    if col_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(0);
    }
    let h: [u8; 8] = data[col_ref..col_ref + 8].try_into().unwrap();
    let hdr = NodeHeader::parse(&h);
    // If inner node, we can't trivially count rows without full B-tree traversal
    if hdr.is_inner {
        return Ok(0); // B-tree — skip for now
    }
    Ok(hdr.size)
}

/// Read a single cell value from a column array at the given row index.
fn read_cell(data: &[u8], col_ref: usize, row_idx: usize, col_type: ColumnType) -> Result<Value> {
    if col_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(Value::Null);
    }
    let h: [u8; 8] = data[col_ref..col_ref + 8].try_into().unwrap();
    let hdr = NodeHeader::parse(&h);

    if hdr.is_inner {
        // B-tree inner node — traverse to find the right leaf
        return read_cell_btree(data, col_ref, row_idx, col_type);
    }

    if row_idx >= hdr.size {
        return Ok(Value::Null);
    }

    let payload = &data[col_ref + NODE_HEADER_SIZE..];

    match col_type {
        ColumnType::Bool => {
            let v = read_bits_elem(payload, row_idx, hdr.width);
            Ok(Value::Bool(v != 0))
        }
        ColumnType::Int => {
            let v = read_bits_elem(payload, row_idx, hdr.width);
            Ok(Value::Int(v as i64))
        }
        ColumnType::String | ColumnType::Data => {
            // String columns: WTYPE_MULTIPLY, each slot width bytes
            if hdr.wtype == WTYPE_MULTIPLY && hdr.width > 0 {
                let slot = multiply_elem_bytes(payload, row_idx, hdr.width);
                Ok(Value::String(decode_short_string(slot)))
            } else if hdr.wtype == WTYPE_BITS && hdr.width == 64 {
                // String column stored as refs to separate string leaf arrays
                let str_ref = read_bits_elem(payload, row_idx, 64) as usize;
                if str_ref == 0 {
                    return Ok(Value::String(String::new()));
                }
                let s = read_leaf_string(data, str_ref)?;
                Ok(Value::String(s))
            } else {
                Ok(Value::Null)
            }
        }
        ColumnType::Float => {
            // 32-bit IEEE float stored as 4-byte multiply or 32-bit bits
            if hdr.width == 32 {
                let off = row_idx * 4;
                let f = f32::from_le_bytes(payload[off..off + 4].try_into().unwrap_or([0; 4]));
                Ok(Value::Float(f as f64))
            } else {
                Ok(Value::Null)
            }
        }
        ColumnType::Double => {
            if hdr.width == 64 {
                let off = row_idx * 8;
                let f = f64::from_le_bytes(payload[off..off + 8].try_into().unwrap_or([0; 8]));
                Ok(Value::Float(f))
            } else {
                Ok(Value::Null)
            }
        }
        ColumnType::Timestamp => {
            // Timestamps stored as int (seconds since Unix epoch)
            let v = read_bits_elem(payload, row_idx, hdr.width);
            Ok(Value::Timestamp(v as i64))
        }
        ColumnType::Link | ColumnType::LinkList | ColumnType::BackLink => {
            let v = read_bits_elem(payload, row_idx, hdr.width);
            Ok(Value::Link(v as usize))
        }
        ColumnType::Unknown(_) => Ok(Value::Null),
    }
}

/// Traverse a B-tree to find the leaf cell at `row_idx`.
fn read_cell_btree(
    data: &[u8],
    node_ref: usize,
    row_idx: usize,
    col_type: ColumnType,
) -> Result<Value> {
    if node_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(Value::Null);
    }
    let h: [u8; 8] = data[node_ref..node_ref + 8].try_into().unwrap();
    let hdr = NodeHeader::parse(&h);

    if !hdr.is_inner {
        // Reached a leaf
        return read_cell(data, node_ref, row_idx, col_type);
    }

    let payload = &data[node_ref + NODE_HEADER_SIZE..];

    // Inner node: each element is a child ref (width=64 bits).
    // Last element is a size-accumulator array (offsets), also as a ref.
    // Layout: [child_ref_0, child_ref_1, ..., child_ref_n, sizes_ref]
    let n_children = if hdr.size > 0 { hdr.size - 1 } else { return Ok(Value::Null) };
    let sizes_ref = read_bits_elem(payload, hdr.size - 1, 64) as usize;

    // sizes array: cumulative row counts
    let sizes = read_array(data, sizes_ref)?;

    let mut remaining = row_idx;
    for ci in 0..n_children {
        let cum = sizes.get(ci).copied().unwrap_or(0) as usize;
        let child_ref = read_bits_elem(payload, ci, 64) as usize;
        // cum = cumulative count including this subtree
        if remaining < cum {
            return read_cell_btree(data, child_ref, remaining, col_type);
        }
        remaining -= cum;
    }

    Ok(Value::Null)
}

/// Read a raw leaf string node (the string data itself, not an array of strings).
fn read_leaf_string(data: &[u8], str_ref: usize) -> Result<String> {
    if str_ref + NODE_HEADER_SIZE > data.len() {
        return Ok(String::new());
    }
    let h: [u8; 8] = data[str_ref..str_ref + 8].try_into().unwrap();
    let hdr = NodeHeader::parse(&h);
    let payload = &data[str_ref + NODE_HEADER_SIZE..];

    if hdr.wtype == WTYPE_MULTIPLY {
        // Short string leaf — slot 0 is the string
        let slot = multiply_elem_bytes(payload, 0, hdr.width);
        return Ok(decode_short_string(slot));
    }

    // Fallback: raw bytes up to first null
    let len = payload.len().min(hdr.size);
    let end = payload[..len].iter().position(|&b| b == 0).unwrap_or(len);
    Ok(String::from_utf8_lossy(&payload[..end]).into_owned())
}

