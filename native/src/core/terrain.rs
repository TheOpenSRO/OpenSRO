//! The terrain and navigation parsers (round 670), ported one-to-one from the GDScript they
//! stand beside:
//! - `.m` (JMXVMAPM): client/scripts/mapm/mapm_reader.gd, docs/protocol/MAPM_FORMAT.md;
//! - `.nvm` (JMXVNVM): client/scripts/nvm/nvm_reader.gd, docs/protocol/NVM_FORMAT.md;
//! - the lightmap term's per-byte loop: MapmTerrainBuilder.lightmap_term.
//!
//! Every check, every count and every error message is the GDScript reader's own, in the same
//! order, so a file that fails there fails here with the same words. Results are flat columns
//! (one Vec per field), which the binding (../gd_terrain.rs) hands back as packed arrays; the
//! GDScript reader rebuilds its own classes from them (`parse_native`), so nothing that reads a
//! ParsedRegion changes.
//!
//! The `.m` and `.nvm` decodes are NOT on the load path (round 670, MEASURED): rebuilding the
//! reader's objects from the columns costs as much as the GDScript parse, so `parse()` stays in
//! GDScript until the region's readers move onto the columns. The lightmap loop is on it.
//!
//! Floats: GDScript reads each with `decode_float`, a float32 widened to a 64-bit float, and the
//! fields that are float32 again (Vector2/3, PackedFloat32Array) narrow it back. On x86-64 both
//! conversions keep a NaN's payload and set its quiet bit, so a signalling NaN in the file comes
//! out quiet on the GDScript path. `f32_gd` does the same to the raw bits, so every float here is
//! bit-for-bit what the GDScript path holds (native_parity_terrain.gd compares the bit patterns).
//!
//! Safety (round 667's review): no `unsafe`; every offset is checked against the data before it
//! is read; every allocation is fallible and clamped to what the data could hold, so a garbage
//! count is an error, never an abort.

/// A float32 from its little-endian bytes, as GDScript holds it after decode_float (see above).
#[inline(always)]
fn f32_gd(b: &[u8], off: usize) -> f32 {
    let bits = u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]);
    let quiet = if (bits & 0x7f80_0000) == 0x7f80_0000 && (bits & 0x007f_ffff) != 0 { bits | 0x0040_0000 } else { bits };
    let v = f32::from_bits(quiet);
    if cfg!(feature = "parity-negative") && off % 97 == 13 {
        // The parity negative's bug (native/README.md, "Parity"): one float in 97 a hair off.
        return f32::from_bits(quiet ^ 1);
    }
    v
}

#[inline(always)]
fn u16_at(b: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([b[off], b[off + 1]])
}

#[inline(always)]
fn i16_at(b: &[u8], off: usize) -> i16 {
    i16::from_le_bytes([b[off], b[off + 1]])
}

#[inline(always)]
fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}

/// PackedByteArray.get_string_from_ascii (Godot 4.2.2): the bytes up to the first NUL, each one
/// a code point (Latin-1).
pub fn ascii_gd(b: &[u8]) -> String {
    b.iter().take_while(|&&c| c != 0).map(|&c| c as char).collect()
}

/// A Vec with room for `want` items, but never more than `cap` (what the data left could hold),
/// and allocated fallibly: an untrusted count must be an error, not an abort.
fn vec_for<T>(want: usize, cap: usize) -> Result<Vec<T>, String> {
    let mut v = Vec::new();
    v.try_reserve_exact(want.min(cap)).map_err(|_| format!("terrain: cannot allocate {} items", want.min(cap)))?;
    Ok(v)
}

// ---------------------------------------------------------------------------------------------
// .m

pub const MAPM_MAGIC: &str = "JMXVMAPM";
const MAPM_HEADER_LEN: usize = 12;
pub const MAPM_BLOCK_COUNT: usize = 36;
pub const MAPM_VERTEX_COUNT: usize = 17 * 17;
const MAPM_BLOCK_HEADER_LEN: usize = 6;
const MAPM_PLANE_INFO_LEN: usize = 6;
const MAPM_TILE_FLAG_LEN: usize = 512;
const MAPM_HEIGHT_INFO_LEN: usize = 8;
const MAPM_MAX_KNOWN_TRAILER: usize = 8192;

/// MapmReader.ParsedRegion as columns. `heights[b * 289 + v]` is block b's vertex v;
/// `extras` holds each vertex's `vertex_len - 4` remaining bytes in the same order.
#[derive(Debug, Default, PartialEq)]
pub struct Mapm {
    pub version: String,
    pub vertex_len: usize,
    pub flags: Vec<u32>,
    pub environment_ids: Vec<u16>,
    pub heights: Vec<f32>,
    pub extras: Vec<u8>,
    pub plane_types: Vec<i8>,
    pub wave_ids: Vec<u8>,
    pub plane_heights: Vec<f32>,
    pub height_max: Vec<f32>,
    pub height_min: Vec<f32>,
}

/// MapmReader._detect_vertex_size: (vertex_len, reserved_len) from the file's own size.
fn mapm_sizes(size: usize) -> Option<(usize, usize)> {
    let fixed = MAPM_BLOCK_HEADER_LEN + MAPM_PLANE_INFO_LEN + MAPM_TILE_FLAG_LEN + MAPM_HEIGHT_INFO_LEN;
    let total7 = MAPM_HEADER_LEN + MAPM_BLOCK_COUNT * (fixed + MAPM_VERTEX_COUNT * 7 + 20);
    let total11 = MAPM_HEADER_LEN + MAPM_BLOCK_COUNT * (fixed + MAPM_VERTEX_COUNT * 11 + 70);
    if size >= total11 && size <= total11 + MAPM_MAX_KNOWN_TRAILER {
        return Some((11, 70));
    }
    if size >= total7 && size <= total7 + MAPM_MAX_KNOWN_TRAILER {
        return Some((7, 20));
    }
    None
}

/// MapmReader._pp_parse.
pub fn parse_mapm(data: &[u8]) -> Result<Mapm, String> {
    if data.len() < MAPM_HEADER_LEN {
        return Err("mapm: file too small to contain a header".into());
    }
    let magic = ascii_gd(&data[0..8]);
    if magic != MAPM_MAGIC {
        return Err(format!("mapm: bad magic {magic}, want {MAPM_MAGIC}"));
    }
    let (vertex_len, reserved_len) =
        mapm_sizes(data.len()).ok_or_else(|| format!("mapm: file size {} doesn't match either known real layout", data.len()))?;
    let nv = MAPM_BLOCK_COUNT * MAPM_VERTEX_COUNT;
    let extra_len = vertex_len - 4;
    // The sizes are fixed by the layout and the file is at least that long (mapm_sizes).
    let mut r = Mapm {
        version: ascii_gd(&data[8..12]),
        vertex_len,
        flags: vec_for(MAPM_BLOCK_COUNT, MAPM_BLOCK_COUNT)?,
        environment_ids: vec_for(MAPM_BLOCK_COUNT, MAPM_BLOCK_COUNT)?,
        heights: vec_for(nv, nv)?,
        extras: vec_for(nv * extra_len, nv * extra_len)?,
        plane_types: vec_for(MAPM_BLOCK_COUNT, MAPM_BLOCK_COUNT)?,
        wave_ids: vec_for(MAPM_BLOCK_COUNT, MAPM_BLOCK_COUNT)?,
        plane_heights: vec_for(MAPM_BLOCK_COUNT, MAPM_BLOCK_COUNT)?,
        height_max: vec_for(MAPM_BLOCK_COUNT, MAPM_BLOCK_COUNT)?,
        height_min: vec_for(MAPM_BLOCK_COUNT, MAPM_BLOCK_COUNT)?,
    };
    let mut off = MAPM_HEADER_LEN;
    for _ in 0..MAPM_BLOCK_COUNT {
        r.flags.push(u32_at(data, off));
        r.environment_ids.push(u16_at(data, off + 4));
        off += MAPM_BLOCK_HEADER_LEN;
        for v in 0..MAPM_VERTEX_COUNT {
            let v_off = off + v * vertex_len;
            r.heights.push(f32_gd(data, v_off));
            r.extras.extend_from_slice(&data[v_off + 4..v_off + vertex_len]);
        }
        off += MAPM_VERTEX_COUNT * vertex_len;
        r.plane_types.push(data[off] as i8);
        r.wave_ids.push(data[off + 1]);
        r.plane_heights.push(f32_gd(data, off + 2));
        off += MAPM_PLANE_INFO_LEN;
        off += MAPM_TILE_FLAG_LEN;
        r.height_max.push(f32_gd(data, off));
        r.height_min.push(f32_gd(data, off + 4));
        off += MAPM_HEIGHT_INFO_LEN;
        off += reserved_len;
    }
    if off != data.len() && data[off..].iter().any(|&b| b != 0) {
        return Err(format!(
            "mapm: parsed {} bytes but file is {}, and the {} leftover bytes aren't all zero",
            off,
            data.len(),
            data.len() - off
        ));
    }
    Ok(r)
}

// ---------------------------------------------------------------------------------------------
// .nvm

pub const NVM_MAGIC: &str = "JMXVNVM 1000";
const NVM_MAGIC_LEN: usize = 12;
pub const NVM_TILE_COUNT: usize = 96 * 96;
pub const NVM_HEIGHT_COUNT: usize = 97 * 97;
pub const NVM_PLANE_COUNT: usize = 36;

/// One edge list of NvmReader (global or internal) as columns: `lines` holds line_min.x,
/// line_min.y, line_max.x, line_max.y per edge; the region ids are -1 for internal edges.
#[derive(Debug, Default, PartialEq)]
pub struct NvmEdges {
    pub lines: Vec<f32>,
    pub flags: Vec<u8>,
    pub dir_from: Vec<i8>,
    pub dir_to: Vec<i8>,
    pub cell_from: Vec<i16>,
    pub cell_to: Vec<i16>,
    pub region_from: Vec<i32>,
    pub region_to: Vec<i32>,
}

/// NvmReader.ParsedRegion as columns. An object's links are
/// `links[3 * link_start[i] .. 3 * link_start[i + 1]]` (other_object_index, other_edge_index,
/// edge_index per link); a cell's object indices are `cell_objects[cell_start[i] ..
/// cell_start[i + 1]]`.
#[derive(Debug, Default, PartialEq)]
pub struct Nvm {
    pub obj_resource_id: Vec<u32>,
    pub obj_position: Vec<f32>,
    pub obj_is_static: Vec<i16>,
    pub obj_yaw: Vec<f32>,
    pub obj_uid: Vec<u16>,
    pub obj_is_big: Vec<u8>,
    pub obj_is_struct: Vec<u8>,
    pub obj_region_id: Vec<u16>,
    pub link_start: Vec<u32>,
    pub links: Vec<i16>,
    pub walkable_cell_count: u32,
    pub cell_rects: Vec<f32>,
    pub cell_start: Vec<u32>,
    pub cell_objects: Vec<u16>,
    pub global_edges: NvmEdges,
    pub internal_edges: NvmEdges,
    pub tile_cell_index: Vec<i32>,
    pub tile_flags: Vec<u16>,
    pub tile_texture_id: Vec<u16>,
    pub heights: Vec<f32>,
    pub plane_types: Vec<u8>,
    pub plane_heights: Vec<f32>,
}

/// NvmReader._pp_parse.
pub fn parse_nvm(data: &[u8]) -> Result<Nvm, String> {
    let n = data.len();
    if n < NVM_MAGIC_LEN + 2 {
        return Err("nvm: file too small to contain a header".into());
    }
    let magic = ascii_gd(&data[0..NVM_MAGIC_LEN]);
    if magic != NVM_MAGIC {
        return Err(format!("nvm: bad magic {magic}, want {NVM_MAGIC}"));
    }
    let mut r = Nvm::default();
    let mut off = NVM_MAGIC_LEN;

    let object_count = u16_at(data, off) as usize;
    off += 2;
    let cap = n / 32 + 1; // an object takes at least 32 bytes
    r.obj_resource_id = vec_for(object_count, cap)?;
    r.obj_position = vec_for(object_count * 3, cap * 3)?;
    r.obj_is_static = vec_for(object_count, cap)?;
    r.obj_yaw = vec_for(object_count, cap)?;
    r.obj_uid = vec_for(object_count, cap)?;
    r.obj_is_big = vec_for(object_count, cap)?;
    r.obj_is_struct = vec_for(object_count, cap)?;
    r.obj_region_id = vec_for(object_count, cap)?;
    r.link_start = vec_for(object_count + 1, cap + 1)?;
    r.link_start.push(0);
    for _ in 0..object_count {
        if off + 30 > n {
            return Err("nvm: truncated reading object header".into());
        }
        r.obj_resource_id.push(u32_at(data, off));
        r.obj_position.extend_from_slice(&[f32_gd(data, off + 4), f32_gd(data, off + 8), f32_gd(data, off + 12)]);
        r.obj_is_static.push(i16_at(data, off + 16));
        r.obj_yaw.push(f32_gd(data, off + 18));
        r.obj_uid.push(u16_at(data, off + 22));
        r.obj_is_big.push((data[off + 26] != 0) as u8);
        r.obj_is_struct.push((data[off + 27] != 0) as u8);
        r.obj_region_id.push(u16_at(data, off + 28));
        off += 30;
        if off + 2 > n {
            return Err("nvm: truncated reading object's LinkedEdgeCount".into());
        }
        let link_count = u16_at(data, off) as usize;
        off += 2;
        r.links.try_reserve(3 * link_count.min((n - off) / 6)).map_err(|_| "nvm: cannot allocate links".to_string())?;
        for _ in 0..link_count {
            if off + 6 > n {
                return Err("nvm: truncated reading a LinkedEdge".into());
            }
            r.links.extend_from_slice(&[i16_at(data, off), i16_at(data, off + 2), i16_at(data, off + 4)]);
            off += 6;
        }
        r.link_start.push((r.links.len() / 3) as u32);
    }

    if off + 8 > n {
        return Err("nvm: truncated reading CellCount/WalkableCellCount".into());
    }
    let cell_count = u32_at(data, off) as usize;
    r.walkable_cell_count = u32_at(data, off + 4);
    off += 8;
    let cap = (n - off) / 17 + 1;
    r.cell_rects = vec_for(cell_count.saturating_mul(4), cap * 4)?;
    r.cell_start = vec_for(cell_count.saturating_add(1), cap + 1)?;
    r.cell_start.push(0);
    for _ in 0..cell_count {
        if off + 17 > n {
            return Err("nvm: truncated reading a Cell".into());
        }
        r.cell_rects
            .extend_from_slice(&[f32_gd(data, off), f32_gd(data, off + 4), f32_gd(data, off + 8), f32_gd(data, off + 12)]);
        let idx_count = data[off + 16] as usize;
        off += 17;
        if off + 2 * idx_count > n {
            return Err("nvm: truncated reading a Cell's ObjectIndices".into());
        }
        r.cell_objects.try_reserve(idx_count).map_err(|_| "nvm: cannot allocate cell objects".to_string())?;
        for _ in 0..idx_count {
            r.cell_objects.push(u16_at(data, off));
            off += 2;
        }
        r.cell_start.push(r.cell_objects.len() as u32);
    }

    off = parse_nvm_edges(data, off, true, &mut r.global_edges)?;
    off = parse_nvm_edges(data, off, false, &mut r.internal_edges)?;

    if off + NVM_TILE_COUNT * 8 > n {
        return Err("nvm: truncated reading the real TileMap".into());
    }
    r.tile_cell_index = vec_for(NVM_TILE_COUNT, NVM_TILE_COUNT)?;
    r.tile_flags = vec_for(NVM_TILE_COUNT, NVM_TILE_COUNT)?;
    r.tile_texture_id = vec_for(NVM_TILE_COUNT, NVM_TILE_COUNT)?;
    for _ in 0..NVM_TILE_COUNT {
        r.tile_cell_index.push(u32_at(data, off) as i32);
        r.tile_flags.push(u16_at(data, off + 4));
        r.tile_texture_id.push(u16_at(data, off + 6));
        off += 8;
    }

    if off + NVM_HEIGHT_COUNT * 4 > n {
        return Err("nvm: truncated reading the real HeightMap".into());
    }
    r.heights = vec_for(NVM_HEIGHT_COUNT, NVM_HEIGHT_COUNT)?;
    for _ in 0..NVM_HEIGHT_COUNT {
        r.heights.push(f32_gd(data, off));
        off += 4;
    }

    if off + NVM_PLANE_COUNT + NVM_PLANE_COUNT * 4 > n {
        return Err("nvm: truncated reading the real PlaneTypeMap/PlaneHeightMap".into());
    }
    r.plane_types = data[off..off + NVM_PLANE_COUNT].to_vec();
    off += NVM_PLANE_COUNT;
    r.plane_heights = vec_for(NVM_PLANE_COUNT, NVM_PLANE_COUNT)?;
    for _ in 0..NVM_PLANE_COUNT {
        r.plane_heights.push(f32_gd(data, off));
        off += 4;
    }

    if off != n {
        return Err(format!("nvm: parsed {off} bytes but file is {n}"));
    }
    Ok(r)
}

/// NvmReader._parse_edges: 27-byte global records (with region ids) or 23-byte internal ones.
fn parse_nvm_edges(data: &[u8], mut off: usize, is_global: bool, e: &mut NvmEdges) -> Result<usize, String> {
    let n = data.len();
    if off + 4 > n {
        return Err("nvm: truncated reading an edge count".into());
    }
    let count = u32_at(data, off) as usize;
    off += 4;
    let fixed_len = if is_global { 27 } else { 23 };
    let cap = (n - off) / fixed_len + 1;
    e.lines = vec_for(count.saturating_mul(4), cap * 4)?;
    e.flags = vec_for(count, cap)?;
    e.dir_from = vec_for(count, cap)?;
    e.dir_to = vec_for(count, cap)?;
    e.cell_from = vec_for(count, cap)?;
    e.cell_to = vec_for(count, cap)?;
    e.region_from = vec_for(count, cap)?;
    e.region_to = vec_for(count, cap)?;
    for _ in 0..count {
        if off + fixed_len > n {
            return Err("nvm: truncated reading an edge".into());
        }
        e.lines.extend_from_slice(&[f32_gd(data, off), f32_gd(data, off + 4), f32_gd(data, off + 8), f32_gd(data, off + 12)]);
        e.flags.push(data[off + 16]);
        e.dir_from.push(data[off + 17] as i8);
        e.dir_to.push(data[off + 18] as i8);
        e.cell_from.push(i16_at(data, off + 19));
        e.cell_to.push(i16_at(data, off + 21));
        if is_global {
            e.region_from.push(u16_at(data, off + 23) as i32);
            e.region_to.push(u16_at(data, off + 25) as i32);
        } else {
            e.region_from.push(-1);
            e.region_to.push(-1);
        }
        off += fixed_len;
    }
    Ok(off)
}

// ---------------------------------------------------------------------------------------------
// The lightmap term

/// The per-byte loop of MapmTerrainBuilder.lightmap_term (round 610): each RGB8 pixel's channels
/// raised by `add` and saturated at 255, through the GDScript's own per-channel tables
/// (`lut[v] = mini(v + add[ch], 255)`). `add` is already clamped to 0..255 by the caller, as the
/// GDScript does before building the tables. The data must be whole RGB triples.
pub fn lightmap_add(rgb: &[u8], add: [u8; 3]) -> Result<Vec<u8>, String> {
    if rgb.len() % 3 != 0 {
        return Err(format!("lightmap: {} bytes is not whole RGB8 pixels", rgb.len()));
    }
    let mut out = Vec::new();
    out.try_reserve_exact(rgb.len()).map_err(|_| format!("lightmap: cannot allocate {} bytes", rgb.len()))?;
    for px in rgb.chunks_exact(3) {
        for ch in 0..3 {
            let v = (px[ch] as u16 + add[ch] as u16).min(255) as u8;
            out.push(if cfg!(feature = "parity-negative") && ch == 1 && v == 255 { 254 } else { v });
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A synthetic `.m` (never real data): `vertex_len` 7 or 11, each value derived from its
    /// position so a misplaced read shows.
    pub fn synth_mapm(vertex_len: usize, trailer: &[u8]) -> Vec<u8> {
        let reserved = if vertex_len == 11 { 70 } else { 20 };
        let mut d = b"JMXVMAPM1000".to_vec();
        for b in 0..36u32 {
            d.extend_from_slice(&(0x1000 + b).to_le_bytes());
            d.extend_from_slice(&(b as u16 * 3).to_le_bytes());
            for v in 0..289u32 {
                d.extend_from_slice(&((b * 289 + v) as f32 * 0.5 - 100.0).to_le_bytes());
                for k in 0..vertex_len - 4 {
                    d.push((v as usize * 7 + k) as u8);
                }
            }
            d.push(if b % 2 == 0 { 0xff } else { 2 });
            d.push(b as u8);
            d.extend_from_slice(&(b as f32 + 0.25).to_le_bytes());
            d.extend(std::iter::repeat(0xab).take(512));
            d.extend_from_slice(&(b as f32 * 10.0).to_le_bytes());
            d.extend_from_slice(&(-(b as f32)).to_le_bytes());
            d.extend(std::iter::repeat(0xcd).take(reserved));
        }
        d.extend_from_slice(trailer);
        d
    }

    pub fn synth_nvm() -> Vec<u8> {
        let mut d = b"JMXVNVM 1000".to_vec();
        d.extend_from_slice(&2u16.to_le_bytes());
        for o in 0..2u32 {
            d.extend_from_slice(&(100 + o).to_le_bytes());
            for f in [1.5f32, 2.5, 3.5] {
                d.extend_from_slice(&(f + o as f32).to_le_bytes());
            }
            d.extend_from_slice(&(-1i16).to_le_bytes());
            d.extend_from_slice(&0.75f32.to_le_bytes());
            d.extend_from_slice(&(7u16 + o as u16).to_le_bytes());
            d.extend_from_slice(&[0, 0, o as u8, 1]);
            d.extend_from_slice(&0x61a8u16.to_le_bytes());
            d.extend_from_slice(&(o as u16).to_le_bytes());
            for l in 0..o {
                for v in [l as i16, -2, 3] {
                    d.extend_from_slice(&v.to_le_bytes());
                }
            }
        }
        d.extend_from_slice(&2u32.to_le_bytes());
        d.extend_from_slice(&1u32.to_le_bytes());
        for c in 0..2u8 {
            for f in [0.0f32, 1.0, 20.0, 21.0] {
                d.extend_from_slice(&(f + c as f32).to_le_bytes());
            }
            d.push(c);
            for i in 0..c {
                d.extend_from_slice(&(i as u16 + 1).to_le_bytes());
            }
        }
        for global in [true, false] {
            d.extend_from_slice(&2u32.to_le_bytes());
            for e in 0..2u8 {
                for f in [0.0f32, 0.0, 1920.0, 0.0] {
                    d.extend_from_slice(&(f + e as f32).to_le_bytes());
                }
                d.extend_from_slice(&[e | 4, 0xff, 2]);
                d.extend_from_slice(&(-1i16).to_le_bytes());
                d.extend_from_slice(&(e as i16).to_le_bytes());
                if global {
                    d.extend_from_slice(&0x61a8u16.to_le_bytes());
                    d.extend_from_slice(&0x61a9u16.to_le_bytes());
                }
            }
        }
        for t in 0..NVM_TILE_COUNT as u32 {
            d.extend_from_slice(&((t % 3) as i32 - 1).to_le_bytes());
            d.extend_from_slice(&((t % 2) as u16).to_le_bytes());
            d.extend_from_slice(&((t % 300) as u16).to_le_bytes());
        }
        for h in 0..NVM_HEIGHT_COUNT {
            d.extend_from_slice(&(h as f32 * 0.125).to_le_bytes());
        }
        d.extend((0..36u8).map(|p| p % 3));
        for p in 0..36 {
            d.extend_from_slice(&(p as f32 - 5.0).to_le_bytes());
        }
        d
    }

    #[test]
    fn mapm_both_vertex_sizes_and_the_zero_trailer() {
        for vl in [7usize, 11] {
            let m = parse_mapm(&synth_mapm(vl, &[])).unwrap();
            assert_eq!(m.version, "1000");
            assert_eq!(m.vertex_len, vl);
            assert_eq!(m.heights.len(), 36 * 289);
            assert_eq!(m.extras.len(), 36 * 289 * (vl - 4));
            assert_eq!(m.heights[290], 290.0 * 0.5 - 100.0);
            assert_eq!(m.extras[(vl - 4) * 2 + 1], 15);
            assert_eq!(m.flags[35], 0x1023);
            assert_eq!(m.environment_ids[5], 15);
            assert_eq!(m.plane_types[0], -1);
            assert_eq!(m.plane_types[1], 2);
            assert_eq!(m.wave_ids[9], 9);
            assert_eq!(m.plane_heights[3], 3.25);
            assert_eq!(m.height_max[4], 40.0);
            assert_eq!(m.height_min[4], -4.0);
            // Every height, so a misread anywhere shows (the parity negative's among them).
            for (i, h) in m.heights.iter().enumerate() {
                assert_eq!(h.to_bits(), (i as f32 * 0.5 - 100.0).to_bits(), "height {i}");
            }
        }
        assert!(parse_mapm(&synth_mapm(7, &[0u8; 1000])).is_ok());
        let mut t = vec![0u8; 1000];
        t[999] = 1;
        assert_eq!(
            parse_mapm(&synth_mapm(7, &t)).unwrap_err(),
            "mapm: parsed 92712 bytes but file is 93712, and the 1000 leftover bytes aren't all zero"
        );
        assert_eq!(parse_mapm(b"JMXV").unwrap_err(), "mapm: file too small to contain a header");
        assert_eq!(parse_mapm(b"JMXVMAPX1000").unwrap_err(), "mapm: bad magic JMXVMAPX, want JMXVMAPM");
        assert_eq!(parse_mapm(b"JMXVMAPM1000").unwrap_err(), "mapm: file size 12 doesn't match either known real layout");
    }

    #[test]
    fn signalling_nans_come_out_quiet_as_in_gdscript() {
        let mut d = synth_mapm(7, &[]);
        d[18..22].copy_from_slice(&0x7f80_0001u32.to_le_bytes());
        let m = parse_mapm(&d).unwrap();
        if !cfg!(feature = "parity-negative") {
            assert_eq!(m.heights[0].to_bits(), 0x7fc0_0001);
        }
    }

    #[test]
    fn nvm_every_section() {
        let v = parse_nvm(&synth_nvm()).unwrap();
        assert_eq!(v.obj_resource_id, vec![100, 101]);
        assert_eq!(v.obj_position, vec![1.5, 2.5, 3.5, 2.5, 3.5, 4.5]);
        assert_eq!(v.obj_is_static, vec![-1, -1]);
        assert_eq!(v.obj_uid, vec![7, 8]);
        assert_eq!(v.obj_is_big, vec![0, 1]);
        assert_eq!(v.obj_is_struct, vec![1, 1]);
        assert_eq!(v.link_start, vec![0, 0, 1]);
        assert_eq!(v.links, vec![0, -2, 3]);
        assert_eq!(v.walkable_cell_count, 1);
        assert_eq!(v.cell_start, vec![0, 0, 1]);
        assert_eq!(v.cell_objects, vec![1]);
        assert_eq!(v.global_edges.region_to, vec![0x61a9, 0x61a9]);
        assert_eq!(v.internal_edges.region_from, vec![-1, -1]);
        assert_eq!(v.internal_edges.dir_from, vec![-1, -1]);
        assert_eq!(v.internal_edges.cell_to, vec![0, 1]);
        assert_eq!(v.global_edges.flags, vec![4, 5]);
        assert_eq!(v.tile_cell_index[0..3], [-1, 0, 1]);
        assert_eq!(v.tile_texture_id[301], 1);
        assert_eq!(v.heights[8], 1.0);
        assert_eq!(v.plane_types[4], 1);
        assert_eq!(v.plane_heights[35], 30.0);
    }

    /// Every truncation of every synthetic file, and garbage, must come back as an error (or, for
    /// a prefix that happens to be a whole valid file, a result) -- never a panic.
    #[test]
    fn truncated_and_random_input_never_panics() {
        let files = [synth_mapm(7, &[]), synth_mapm(11, &[0u8; 8]), synth_nvm()];
        for f in &files {
            for cut in (0..f.len()).step_by(7).chain(f.len().saturating_sub(64)..f.len()) {
                let _ = parse_mapm(&f[..cut]);
                let _ = parse_nvm(&f[..cut]);
            }
        }
        assert_eq!(parse_nvm(&synth_nvm()[..20]).unwrap_err(), "nvm: truncated reading object header");
        // A xorshift stream, behind each magic: huge counts must fail cleanly, not allocate.
        let mut s = 0x2545_f491_4f6c_dd1du64;
        for round in 0..400 {
            let len = 14 + (round * 37) % 4000;
            let mut d: Vec<u8> = Vec::with_capacity(len);
            for _ in 0..len {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                d.push(s as u8);
            }
            let magic: &[u8] = if round % 2 == 0 { b"JMXVMAPM1000" } else { b"JMXVNVM 1000" };
            d[..12].copy_from_slice(magic);
            assert!(parse_mapm(&d).is_err());
            let _ = parse_nvm(&d);
        }
        // The largest counts the formats can declare.
        let mut d = b"JMXVNVM 1000".to_vec();
        d.extend_from_slice(&0u16.to_le_bytes());
        d.extend_from_slice(&u32::MAX.to_le_bytes());
        d.extend_from_slice(&0u32.to_le_bytes());
        assert_eq!(parse_nvm(&d).unwrap_err(), "nvm: truncated reading a Cell");
    }

    #[test]
    fn lightmap_add_saturates_per_channel() {
        let v = lightmap_add(&[0, 100, 250, 255, 1, 2, 9, 254, 9, 0, 255, 0], [10, 0, 5]).unwrap();
        assert_eq!(v, vec![10, 100, 255, 255, 1, 7, 19, 254, 14, 10, 255, 5]);
        assert!(lightmap_add(&[1, 2], [0, 0, 0]).is_err());
        assert_eq!(lightmap_add(&[], [1, 1, 1]).unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn ascii_stops_at_nul_and_reads_latin1() {
        assert_eq!(ascii_gd(b"ab\0cd"), "ab");
        assert_eq!(ascii_gd(&[0xe9, 0x41]), "\u{e9}A");
    }
}
