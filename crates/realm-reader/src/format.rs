//! Realm v9 binary format constants and low-level node parsing.
//!
//! Reference: realm-core `src/realm/node_header.hpp` + `array.hpp`.

pub(crate) const MAGIC: &[u8; 4] = b"T-DB";
pub(crate) const SUPPORTED_VERSION: u32 = 9;
pub(crate) const FILE_HEADER_SIZE: usize = 24;
pub(crate) const NODE_HEADER_SIZE: usize = 8;

// wtype values (bits 4-3 of NodeHeader byte 4)
pub(crate) const WTYPE_BITS: u8 = 0;
pub(crate) const WTYPE_MULTIPLY: u8 = 1;

/// Parsed 8-byte Realm NodeHeader (internal representation).
#[derive(Debug, Clone)]
pub(crate) struct NodeHeader {
    pub(crate) size: usize,
    pub(crate) width: u8,    // element width in bits: 0,1,2,4,8,16,32,64
    pub(crate) wtype: u8,    // WTYPE_BITS / WTYPE_MULTIPLY / WTYPE_IGNORE
    pub(crate) is_inner: bool,
}

impl NodeHeader {
    pub(crate) fn parse(h: &[u8; 8]) -> Self {
        let flags = h[4];
        let is_inner = flags & 0x80 != 0;
        let wtype = (flags & 0x18) >> 3;
        // width_enc 0..7 → actual width: 0,1,2,4,8,16,32,64
        let width_enc = flags & 0x07;
        let width: u8 = if width_enc == 0 { 0 } else { 1u8 << (width_enc - 1) };
        let size = ((h[5] as usize) << 16) | ((h[6] as usize) << 8) | (h[7] as usize);
        NodeHeader { size, width, wtype, is_inner }
    }
}

/// Parse the file header; returns `(top_ref, version)`.
pub(crate) fn parse_file_header(data: &[u8]) -> crate::Result<(usize, u32)> {
    if data.len() < FILE_HEADER_SIZE {
        return Err(crate::RealmError::InvalidFormat("file too small".into()));
    }
    let top_ref = u64::from_le_bytes(data[0..8].try_into().unwrap()) as usize;
    if &data[16..20] != MAGIC {
        return Err(crate::RealmError::InvalidFormat(
            format!("bad magic: {:?}", &data[16..20]),
        ));
    }
    let version = u32::from_le_bytes(data[20..24].try_into().unwrap());
    if version != SUPPORTED_VERSION {
        return Err(crate::RealmError::UnsupportedVersion(version));
    }
    Ok((top_ref, version))
}

/// Read a single element from a WTYPE_BITS array at index `i`.
/// `width` is in bits (0, 1, 2, 4, 8, 16, 32, 64). Returns `u64`.
pub(crate) fn read_bits_elem(payload: &[u8], i: usize, width: u8) -> u64 {
    match width {
        0 => 0,
        1 => ((payload[i / 8] >> (i % 8)) & 1) as u64,
        2 => ((payload[i / 4] >> ((i % 4) * 2)) & 0x3) as u64,
        4 => ((payload[i / 2] >> ((i % 2) * 4)) & 0xf) as u64,
        8 => payload[i] as u64,
        16 => {
            let off = i * 2;
            u16::from_le_bytes(payload[off..off + 2].try_into().unwrap()) as u64
        }
        32 => {
            let off = i * 4;
            u32::from_le_bytes(payload[off..off + 4].try_into().unwrap()) as u64
        }
        64 => {
            let off = i * 8;
            u64::from_le_bytes(payload[off..off + 8].try_into().unwrap())
        }
        _ => 0,
    }
}

/// Return the `i`-th slot from a WTYPE_MULTIPLY array (each slot is `width` bytes).
pub(crate) fn multiply_elem_bytes(payload: &[u8], i: usize, width: u8) -> &[u8] {
    let w = width as usize;
    let off = i * w;
    &payload[off..off + w]
}

/// Decode a Realm short-string slot.
///
/// The last byte is the "tail": `tail = slot_width - string_len - 1`.
/// String bytes occupy `slot[0..string_len]`.
pub(crate) fn decode_short_string(slot: &[u8]) -> String {
    if slot.is_empty() {
        return String::new();
    }
    let w = slot.len();
    let tail = slot[w - 1] as usize;
    let len = if tail < w { w - 1 - tail } else { 0 };
    String::from_utf8_lossy(&slot[..len]).into_owned()
}
