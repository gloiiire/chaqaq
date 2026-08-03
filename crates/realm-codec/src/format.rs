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
pub(crate) const WTYPE_IGNORE: u8 = 2; // raw bytes; `size` field = byte count

/// Parsed 8-byte Realm NodeHeader (internal representation).
#[derive(Debug, Clone)]
pub(crate) struct NodeHeader {
    pub(crate) size: usize,
    pub(crate) width: u8, // element width in bits: 0,1,2,4,8,16,32,64
    pub(crate) wtype: u8, // WTYPE_BITS / WTYPE_MULTIPLY / WTYPE_IGNORE
    pub(crate) is_inner: bool,
}

impl NodeHeader {
    pub(crate) fn parse(h: &[u8; 8]) -> Self {
        let flags = h[4];
        let is_inner = flags & 0x80 != 0;
        let wtype = (flags & 0x18) >> 3;
        // width_enc 0..7 → actual width: 0,1,2,4,8,16,32,64
        let width_enc = flags & 0x07;
        let width: u8 = if width_enc == 0 {
            0
        } else {
            1u8 << (width_enc - 1)
        };
        let size = ((h[5] as usize) << 16) | ((h[6] as usize) << 8) | (h[7] as usize);
        NodeHeader {
            size,
            width,
            wtype,
            is_inner,
        }
    }
}

/// Parse the file header; returns `(top_ref, version)`.
pub(crate) fn parse_file_header(data: &[u8]) -> crate::Result<(usize, u32)> {
    if data.len() < FILE_HEADER_SIZE {
        return Err(crate::RealmError::InvalidFormat("file too small".into()));
    }
    let top_ref_bytes: [u8; 8] = data[0..8]
        .try_into()
        .map_err(|_| crate::RealmError::InvalidFormat("top_ref slice".into()))?;
    let top_ref = u64::from_le_bytes(top_ref_bytes) as usize;
    if &data[16..20] != MAGIC {
        return Err(crate::RealmError::InvalidFormat(format!(
            "bad magic: {:?}",
            &data[16..20]
        )));
    }
    // Byte 20 is the file-format version (u8). Bytes 21-23 are history-type and
    // history-schema-version fields that vary by Realm feature set — ignore them.
    let version = data[20] as u32;
    if version != SUPPORTED_VERSION {
        return Err(crate::RealmError::UnsupportedVersion(version));
    }
    Ok((top_ref, version))
}

/// Bounds-checked NodeHeader read at `offset`.
///
/// Returns [`RealmError::InvalidFormat`] if the 8-byte header would extend past
/// the end of `data`. Used everywhere a `NodeHeader` is decoded from a raw ref —
/// replaces the older `try_into().unwrap()` pattern which would panic on a
/// truncated file.
pub(crate) fn read_node_header(data: &[u8], offset: usize) -> crate::Result<NodeHeader> {
    let slice = data
        .get(offset..offset.saturating_add(NODE_HEADER_SIZE))
        .ok_or_else(|| {
            crate::RealmError::InvalidFormat(format!(
                "node header offset {offset:#x} out of bounds"
            ))
        })?;
    let bytes: &[u8; NODE_HEADER_SIZE] = slice
        .try_into()
        .map_err(|_| crate::RealmError::InvalidFormat("node header slice".into()))?;
    Ok(NodeHeader::parse(bytes))
}

/// Read a single element from a WTYPE_BITS array at index `i`.
/// `width` is in bits (0, 1, 2, 4, 8, 16, 32, 64). Returns `u64`.
///
/// Every access is bounds-checked against `payload`: the element index and
/// the width both come from the file being parsed, so a truncated or
/// crafted array would otherwise index past the end and panic. A malformed
/// file must produce garbage or an error, never abort the process — and an
/// unwind out of the async FFI *does* abort (see `ffi/extractors.rs`).
///
/// Out of range yields `0`, matching the intent of the previous
/// `unwrap_or([0; N])` — which was unreachable, since the range index
/// panicked before `try_into` ever ran.
pub(crate) fn read_bits_elem(payload: &[u8], i: usize, width: u8) -> u64 {
    /// Reads `N` bytes at `off`, or zeroes when they don't all fit.
    fn le_bytes<const N: usize>(payload: &[u8], off: usize) -> [u8; N] {
        payload
            .get(off..off.saturating_add(N))
            .and_then(|s| s.try_into().ok())
            .unwrap_or([0; N])
    }
    match width {
        0 => 0,
        1 => payload.get(i / 8).map_or(0, |b| ((b >> (i % 8)) & 1) as u64),
        2 => payload
            .get(i / 4)
            .map_or(0, |b| ((b >> ((i % 4) * 2)) & 0x3) as u64),
        4 => payload
            .get(i / 2)
            .map_or(0, |b| ((b >> ((i % 2) * 4)) & 0xf) as u64),
        8 => payload.get(i).map_or(0, |b| *b as u64),
        16 => u16::from_le_bytes(le_bytes::<2>(payload, i.saturating_mul(2))) as u64,
        32 => u32::from_le_bytes(le_bytes::<4>(payload, i.saturating_mul(4))) as u64,
        64 => u64::from_le_bytes(le_bytes::<8>(payload, i.saturating_mul(8))),
        _ => 0,
    }
}

/// Return the `i`-th slot from a WTYPE_MULTIPLY array (each slot is `width` bytes).
///
/// Bounds-checked for the same reason as [`read_bits_elem`]: `i` and `width`
/// are file-controlled. Returns an empty slice when the slot doesn't fit,
/// which callers already treat as "no data".
pub(crate) fn multiply_elem_bytes(payload: &[u8], i: usize, width: u8) -> &[u8] {
    let w = width as usize;
    let off = i.saturating_mul(w);
    payload.get(off..off.saturating_add(w)).unwrap_or(&[])
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
