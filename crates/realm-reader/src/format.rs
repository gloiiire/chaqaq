//! Realm v9 binary format constants and low-level node parsing.
//!
//! Reference: realm-core `src/realm/node_header.hpp` + `array.hpp`.

/// Magic bytes at offset 16 in the file header.
pub const MAGIC: &[u8; 4] = b"T-DB";

/// Supported Realm file format version.
pub const SUPPORTED_VERSION: u32 = 9;

/// File header is 24 bytes: top_ref[0] (8B LE), top_ref[1] (8B LE), magic (4B), version (4B).
pub const FILE_HEADER_SIZE: usize = 24;

// wtype constants (bits 4-3 of header byte 4)
pub const WTYPE_BITS: u8 = 0;
pub const WTYPE_MULTIPLY: u8 = 1;
pub const WTYPE_IGNORE: u8 = 2;

/// Parsed Realm NodeHeader (8 bytes).
#[derive(Debug, Clone)]
pub struct NodeHeader {
    pub capacity: usize,
    pub size: usize,
    pub width: u8,   // element width in bits (0,1,2,4,8,16,32,64)
    pub wtype: u8,   // WTYPE_BITS / WTYPE_MULTIPLY / WTYPE_IGNORE
    pub is_inner: bool,
    pub has_refs: bool,
}

impl NodeHeader {
    /// Parse an 8-byte NodeHeader from a slice.
    pub fn parse(h: &[u8; 8]) -> Self {
        // capacity packed in h[0..2] (big-endian, 3 bytes, bits shifted)
        let capacity = ((h[0] as usize) << 19) | ((h[1] as usize) << 11) | ((h[2] as usize) << 3);
        // h[3] unused
        let flags = h[4];
        let is_inner = flags & 0x80 != 0;
        let has_refs = flags & 0x40 != 0;
        let wtype = (flags & 0x18) >> 3;
        // width encoded as log2: encoded value 0..7 → actual width 0,1,2,4,8,16,32,64
        let width_enc = flags & 0x07;
        let width: u8 = if width_enc == 0 { 0 } else { 1u8 << (width_enc - 1) };
        let size = ((h[5] as usize) << 16) | ((h[6] as usize) << 8) | (h[7] as usize);
        NodeHeader { capacity, size, width, wtype, is_inner, has_refs }
    }
}

/// Read a little-endian u64 reference (8 bytes).
#[inline]
pub fn read_ref(data: &[u8], offset: usize) -> u64 {
    let b = &data[offset..offset + 8];
    u64::from_le_bytes(b.try_into().unwrap())
}

/// Read a little-endian u32.
#[inline]
pub fn read_u32(data: &[u8], offset: usize) -> u32 {
    let b = &data[offset..offset + 4];
    u32::from_le_bytes(b.try_into().unwrap())
}

/// Read the file header; returns (top_ref, version).
pub fn parse_file_header(data: &[u8]) -> crate::Result<(usize, u32)> {
    if data.len() < FILE_HEADER_SIZE {
        return Err(crate::RealmError::InvalidFormat("file too small".into()));
    }
    let top_ref = u64::from_le_bytes(data[0..8].try_into().unwrap()) as usize;
    let magic = &data[16..20];
    if magic != MAGIC {
        return Err(crate::RealmError::InvalidFormat(
            format!("bad magic: {:?}", magic),
        ));
    }
    let version = read_u32(data, 20);
    if version != SUPPORTED_VERSION {
        return Err(crate::RealmError::UnsupportedVersion(version));
    }
    Ok((top_ref, version))
}

/// Byte offset of the first data element inside an array node.
pub const NODE_HEADER_SIZE: usize = 8;

/// Read a single integer element from a WTYPE_BITS array at index `i`.
/// `width` is in bits (0,1,2,4,8,16,32,64). Returns u64.
pub fn read_bits_elem(payload: &[u8], i: usize, width: u8) -> u64 {
    match width {
        0 => 0,
        1 => {
            let byte = payload[i / 8];
            ((byte >> (i % 8)) & 1) as u64
        }
        2 => {
            let byte = payload[i / 4];
            ((byte >> ((i % 4) * 2)) & 0x3) as u64
        }
        4 => {
            let byte = payload[i / 2];
            ((byte >> ((i % 2) * 4)) & 0xf) as u64
        }
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

/// Read a WTYPE_MULTIPLY element at index `i`. Each element is `width` bytes.
/// Returns the raw bytes as a slice.
pub fn multiply_elem_bytes<'a>(payload: &'a [u8], i: usize, width: u8) -> &'a [u8] {
    let w = width as usize;
    let off = i * w;
    &payload[off..off + w]
}

/// Decode a Realm short string from a `width`-byte slot.
/// Last byte = tail = (width - actual_len - 1). String = slot[0..actual_len].
pub fn decode_short_string(slot: &[u8]) -> String {
    if slot.is_empty() {
        return String::new();
    }
    let w = slot.len();
    let tail = slot[w - 1] as usize;
    // tail = w - len - 1  =>  len = w - 1 - tail
    let len = if tail < w { w - 1 - tail } else { 0 };
    String::from_utf8_lossy(&slot[..len]).into_owned()
}
