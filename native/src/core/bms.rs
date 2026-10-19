//! The `.bms` (JMXVBMS 0110) mesh reader, ported one to one from BmsReader.parse
//! (client/scripts/bms/bms_reader.gd, round 669). docs/protocol/BMS_FORMAT.md has the format.
//!
//! The GDScript reader stays the reference, and this answers exactly what it answers:
//! - every value it stores, at the same bit pattern (a float goes through the same f32 -> f64 ->
//!   f32 round trip GDScript's `decode_float` and `Vector3` give it, so a signalling NaN comes
//!   out quiet, as there);
//! - the same partial results (a skin section refused at vertex i keeps the bones and weights of
//!   vertices 0..i, with no palette, exactly as `_parse_skin`'s early return leaves them).
//!
//! Where the GDScript reader returns null, `parse` returns `Err`. It also returns `Err` for the
//! inputs whose GDScript behaviour depends on Godot's negative indexing (a header pointer at or
//! above 2^31, which `PackedInt32Array` makes negative). Either way the client falls back to the
//! GDScript reader, which then answers, and reports, as it always has. So an `Err` here never
//! changes what the client does; it only means GDScript does the work.
//!
//! Integer arithmetic is i64 throughout, as GDScript's `int` is. Every offset is checked against
//! the data before it is read, and no allocation is larger than the data it is read from.

const MAGIC: &[u8] = b"JMXVBMS 0110";
const PREAMBLE_END: i64 = 0x48;
const INDEX_REC_SIZE: i64 = 6;
const HEADER_PTRS_BASE: i64 = 0x10;
const VERTEX_REC_SIZE_CANDIDATES: [i64; 2] = [44, 52];
const SKIN_REC_SIZE: i64 = 6;
const NO_BONE: i64 = 255;
const WEIGHT_FULL_SCALE: f64 = 65535.0;
/// BmsReader.OBJECT_SPACE.
pub const OBJECT_SPACE: i32 = -2;
const VERTEX_MOTION_PTR_OFFSET: i64 = HEADER_PTRS_BASE + 2 * 4;
const VERTEX_MOTION_REC_SIZE: i64 = 8;
const VERTEX_LINK_PTR_OFFSET: i64 = HEADER_PTRS_BASE + 3 * 4;
const VERTEX_LINK_REC_SIZE: i64 = 12;

/// The per-vertex skin, parallel to the vertices: what `_parse_skin` wrote into each Vertex.
/// Present whenever its per-vertex loop started, even if it then stopped early.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Skin {
    pub bone0: Vec<i32>,
    pub bone1: Vec<i32>,
    pub weight0: Vec<f64>,
    pub weight1: Vec<f64>,
}

/// BmsReader.ParsedMesh, as flat arrays.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Mesh {
    pub mesh_name: String,
    pub material_name: String,
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Vec<[f32; 2]>,
    /// Each vertex's trailing bytes (record offset 0x20 on), `extra_size` a vertex.
    pub extra: Vec<u8>,
    pub extra_size: usize,
    pub skin: Option<Skin>,
    pub bone_names: Vec<String>,
    pub object_space_vertices: i64,
    pub indices: Vec<i32>,
    /// (min, max), when the header's box pointer lands inside the file.
    pub bounds: Option<([f32; 3], [f32; 3])>,
    pub vertex_motion: Vec<f32>,
    pub vertex_pinned: Vec<u8>,
    pub vertex_links: Vec<i32>,
    pub vertex_link_lengths: Vec<f32>,
    pub vertex_link_order: Vec<i32>,
    /// The 36 bytes after the order (round 794, READ: the cloth's parameter block,
    /// core/cloth.rs `Params`): the flag and the divisor as numbers, the seven floats as they
    /// are. Empty when the section is not whole.
    pub cloth_params: Vec<f32>,
}

/// A Vec of `n` slots, refused rather than aborting when the allocation fails. Every caller has
/// already checked that `n` records fit in the data.
pub(crate) fn vec_with<T>(n: i64) -> Result<Vec<T>, String> {
    let n = usize::try_from(n).map_err(|_| "negative size".to_string())?;
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| format!("cannot allocate {n} elements"))?;
    Ok(v)
}

/// The data, read the way the GDScript readers read a PackedByteArray: by i64 offsets, every one
/// bounds-checked (an offset GDScript would read out of range is an `Err`, never a panic).
pub(crate) struct Bytes<'a>(pub &'a [u8]);

impl Bytes<'_> {
    pub fn len(&self) -> i64 {
        self.0.len() as i64
    }

    fn at(&self, off: i64, n: i64) -> Result<&[u8], String> {
        if off < 0 || off.checked_add(n).is_none_or(|e| e > self.len()) {
            return Err(format!("read of {n} bytes at {off} is outside the {} byte file", self.len()));
        }
        Ok(&self.0[off as usize..(off + n) as usize])
    }

    pub fn u8(&self, off: i64) -> Result<i64, String> {
        Ok(self.at(off, 1)?[0] as i64)
    }

    pub fn u16(&self, off: i64) -> Result<i64, String> {
        let b = self.at(off, 2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]) as i64)
    }

    /// `_le_u32`: unsigned, 0..2^32-1, in an i64.
    pub fn u32(&self, off: i64) -> Result<i64, String> {
        let b = self.at(off, 4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as i64)
    }

    /// `_le_f32` as GDScript stores it: `decode_float` widens the f32 to a double, and storing
    /// that in a Vector3 / PackedFloat32Array narrows it back, which quiets a signalling NaN.
    pub fn f32(&self, off: i64) -> Result<f32, String> {
        let b = self.at(off, 4)?;
        Ok(gd_f32(u32::from_le_bytes([b[0], b[1], b[2], b[3]])))
    }

    pub fn slice(&self, from: i64, to: i64) -> Result<&[u8], String> {
        self.at(from, to - from)
    }
}

/// An f32 after GDScript's f32 -> f64 -> f32 round trip: the same value, a NaN made quiet (the x86
/// conversions set the quiet bit and keep the payload).
pub(crate) fn gd_f32(bits: u32) -> f32 {
    let v = f32::from_bits(bits);
    if v.is_nan() {
        f32::from_bits(bits | 0x0040_0000)
    } else {
        v
    }
}

/// `PackedByteArray.get_string_from_ascii()` in Godot 4.2.2: the bytes up to the first NUL, each
/// one a Latin-1 code point (String::copy_from(const char *)).
pub fn ascii_string(b: &[u8]) -> String {
    b.iter().take_while(|&&c| c != 0).map(|&c| c as char).collect()
}

/// `_read_len_prefixed_string`: (string, next offset), or None.
fn read_len_prefixed_string(d: &Bytes, off: i64) -> Option<(String, i64)> {
    if off + 4 > d.len() {
        return None;
    }
    let n = d.u32(off).ok()?;
    let off = off + 4;
    if off + n > d.len() {
        return None;
    }
    Some((ascii_string(d.slice(off, off + n).ok()?), off + n))
}

/// The header pointer `i` as GDScript holds it: `hdr` is a PackedInt32Array, so a u32 at or
/// above 2^31 wraps negative.
fn hdr(d: &Bytes, i: i64) -> Result<i64, String> {
    Ok(d.u32(HEADER_PTRS_BASE + i * 4)? as u32 as i32 as i64)
}

/// BmsReader.parse.
pub fn parse(data: &[u8]) -> Result<Mesh, String> {
    let d = Bytes(data);
    if d.len() < PREAMBLE_END {
        return Err("bms: file too small to contain a header".into());
    }
    if ascii_string(&data[..MAGIC.len()]).as_bytes() != MAGIC {
        return Err("bms: bad magic".into());
    }
    let hdr0 = hdr(&d, 0)?;
    let hdr1 = hdr(&d, 1)?;
    let hdr4 = hdr(&d, 4)?;

    let (mesh_name, off) = read_len_prefixed_string(&d, PREAMBLE_END).ok_or("bms: reading name")?;
    let (material_name, mut off) = read_len_prefixed_string(&d, off).ok_or("bms: reading material name")?;
    if off + 8 > d.len() {
        return Err("bms: truncated before vertex count".into());
    }
    off += 4;
    let vertex_count = d.u32(off)?;
    off += 4;

    let rec = detect_vertex_rec_size(&d, off, vertex_count, hdr1)?;
    if rec == -1 {
        return Err(format!("bms: vertex array (count={vertex_count}) doesn't fit in the file at any known real record size"));
    }
    if off + vertex_count * rec > d.len() {
        return Err(format!("bms: vertex array (count={vertex_count}) runs past end of file"));
    }

    let mut m = Mesh { mesh_name, material_name, ..Default::default() };
    m.positions = vec_with(vertex_count)?;
    m.normals = vec_with(vertex_count)?;
    m.uvs = vec_with(vertex_count)?;
    m.extra_size = (rec - 0x20) as usize;
    m.extra = vec_with(vertex_count * (rec - 0x20))?;
    for i in 0..vertex_count {
        let r = off + i * rec;
        m.positions.push([d.f32(r)?, d.f32(r + 4)?, d.f32(r + 8)?]);
        m.normals.push([d.f32(r + 0x0c)?, d.f32(r + 0x10)?, d.f32(r + 0x14)?]);
        m.uvs.push([d.f32(r + 0x18)?, d.f32(r + 0x1c)?]);
        m.extra.extend_from_slice(d.slice(r + 0x20, r + rec)?);
    }

    parse_skin(&d, hdr0, hdr1, vertex_count, &mut m)?;

    let index_off = hdr1;
    if index_off + 4 > d.len() {
        return Err("bms: index section offset (hdr[1]) out of range".into());
    }
    if index_off < 0 {
        // GDScript reads this through Godot's negative indexing: left to it.
        return Err("bms: negative index section offset (left to the GDScript reader)".into());
    }
    let tri_count = d.u32(index_off)?;
    let index_start = index_off + 4;
    if index_start + tri_count * INDEX_REC_SIZE > d.len() {
        return Err(format!("bms: index array (triangles={tri_count}) runs past end of file"));
    }
    m.indices = vec_with(tri_count * 3)?;
    for i in 0..tri_count * 3 {
        m.indices.push(d.u16(index_start + i * 2)? as i32);
    }

    let bbox = hdr4;
    if bbox + 24 <= d.len() {
        if bbox < 0 {
            return Err("bms: negative bounding box offset (left to the GDScript reader)".into());
        }
        m.bounds = Some((
            [d.f32(bbox)?, d.f32(bbox + 4)?, d.f32(bbox + 8)?],
            [d.f32(bbox + 12)?, d.f32(bbox + 16)?, d.f32(bbox + 20)?],
        ));
    }

    parse_vertex_motion(&d, &mut m)?;
    parse_vertex_links(&d, &mut m)?;
    Ok(m)
}

/// `_detect_vertex_rec_size`: the candidate size under which the fewest normals are not unit
/// length (the first on a tie), or -1 when the array fits at neither.
fn detect_vertex_rec_size(d: &Bytes, off: i64, vertex_count: i64, index_off: i64) -> Result<i64, String> {
    let mut best_size = -1;
    let mut best_bad = -1;
    for size in VERTEX_REC_SIZE_CANDIDATES {
        let end = off + vertex_count * size;
        if end > d.len() || (index_off > 0 && end > index_off) {
            continue;
        }
        let mut bad = 0;
        for i in 0..vertex_count {
            let r = off + i * size;
            let nx = d.f32(r + 0x0c)? as f64;
            let ny = d.f32(r + 0x10)? as f64;
            let nz = d.f32(r + 0x14)? as f64;
            let length = (nx * nx + ny * ny + nz * nz).sqrt();
            if length.is_nan() || length < 0.9 || length > 1.1 {
                bad += 1;
            }
        }
        if best_bad == -1 || bad < best_bad {
            best_bad = bad;
            best_size = size;
        }
    }
    Ok(best_size)
}

/// `_parse_skin`, including its early returns: the palette is kept only when every vertex's
/// record is accepted, but the vertices before a refused one keep what was written into them.
fn parse_skin(d: &Bytes, section_start: i64, section_end: i64, vertex_count: i64, m: &mut Mesh) -> Result<(), String> {
    if section_start <= 0 || section_start + 4 > d.len() || section_end > d.len() {
        return Ok(());
    }
    let bone_count = d.u32(section_start)?;
    if bone_count <= 0 || bone_count > 512 {
        return Ok(());
    }
    let mut off = section_start + 4;
    let mut names = Vec::with_capacity(bone_count as usize);
    for _ in 0..bone_count {
        if off + 4 > d.len() {
            return Ok(());
        }
        let n = d.u32(off)?;
        off += 4;
        if n <= 0 || n > 128 || off + n > d.len() {
            return Ok(());
        }
        names.push(ascii_string(d.slice(off, off + n)?));
        off += n;
    }
    if section_end - off != vertex_count * SKIN_REC_SIZE {
        return Ok(());
    }

    let palette = names.len() as i64;
    let mut skin = Skin {
        bone0: vec![-1; vertex_count as usize],
        bone1: vec![-1; vertex_count as usize],
        weight0: vec![0.0; vertex_count as usize],
        weight1: vec![0.0; vertex_count as usize],
    };
    for i in 0..vertex_count {
        let r = off + i * SKIN_REC_SIZE;
        let b0 = d.u8(r)?;
        let w0 = d.u16(r + 1)? as f64;
        let b1 = d.u8(r + 3)?;
        let w1 = d.u16(r + 4)? as f64;
        let s0 = b0 != NO_BONE;
        let s1 = b1 != NO_BONE;
        if (s0 && b0 >= palette) || (s1 && b1 >= palette) {
            m.skin = Some(skin);
            return Ok(()); // the palette is not kept; the vertices before this one are
        }
        let f0 = if w0 == WEIGHT_FULL_SCALE { 1.0 } else { w0 / WEIGHT_FULL_SCALE };
        let f1 = if w1 == WEIGHT_FULL_SCALE { 1.0 } else { w1 / WEIGHT_FULL_SCALE };
        let total = (if s0 { f0 } else { 0.0 }) + (if s1 { f1 } else { 0.0 });
        let mut blend = if total != 0.0 { f0 / total } else { 0.0 };
        if cfg!(feature = "parity-negative") {
            blend = blend as f32 as f64; // the parity negative's bug: the blend rounded to f32
        }
        let e0 = if s0 { b0 as i32 } else { OBJECT_SPACE };
        let e1 = if s1 { b1 as i32 } else { OBJECT_SPACE };
        let i = i as usize;
        if blend >= 1.0 || e0 == e1 {
            skin.bone0[i] = if blend >= 1.0 { e0 } else { e1 };
            skin.weight0[i] = 1.0;
        } else if blend <= 0.0 {
            skin.bone0[i] = e1;
            skin.weight0[i] = 1.0;
        } else {
            skin.bone0[i] = e0;
            skin.weight0[i] = blend;
            skin.bone1[i] = e1;
            skin.weight1[i] = 1.0 - blend;
        }
        if skin.bone0[i] == OBJECT_SPACE || skin.bone1[i] == OBJECT_SPACE {
            m.object_space_vertices += 1;
        }
    }
    m.skin = Some(skin);
    m.bone_names = names;
    Ok(())
}

/// `_parse_vertex_motion`.
fn parse_vertex_motion(d: &Bytes, m: &mut Mesh) -> Result<(), String> {
    let start = d.u32(VERTEX_MOTION_PTR_OFFSET)?;
    if start == 0 || start + 4 > d.len() {
        return Ok(());
    }
    let count = d.u32(start)?;
    if count != m.positions.len() as i64 || start + 4 + count * VERTEX_MOTION_REC_SIZE > d.len() {
        return Ok(());
    }
    let mut motion = vec_with(count)?;
    let mut pinned = vec_with(count)?;
    for i in 0..count {
        let r = start + 4 + i * VERTEX_MOTION_REC_SIZE;
        motion.push(d.f32(r)?);
        pinned.push(if d.u32(r + 4)? != 0 { 1 } else { 0 });
    }
    m.vertex_motion = motion;
    m.vertex_pinned = pinned;
    Ok(())
}

/// `_parse_vertex_links`.
fn parse_vertex_links(d: &Bytes, m: &mut Mesh) -> Result<(), String> {
    let start = d.u32(VERTEX_LINK_PTR_OFFSET)?;
    if start == 0 || start + 4 > d.len() {
        return Ok(());
    }
    let count = d.u32(start)?;
    if count == 0 || start + 4 + count * VERTEX_LINK_REC_SIZE > d.len() {
        return Ok(());
    }
    let vertex_count = m.positions.len() as i64;
    let mut links = vec_with(count * 2)?;
    let mut lengths = vec_with(count)?;
    for i in 0..count {
        let r = start + 4 + i * VERTEX_LINK_REC_SIZE;
        let a = d.u32(r)?;
        let b = d.u32(r + 4)?;
        let dist = d.f32(r + 8)?;
        if a >= vertex_count || b >= vertex_count || !((dist as f64) > 0.0) {
            return Ok(());
        }
        links.push(a as i32);
        links.push(b as i32);
        lengths.push(dist);
    }
    m.vertex_links = links;
    m.vertex_link_lengths = lengths;

    let order_at = start + 4 + count * VERTEX_LINK_REC_SIZE;
    if order_at + count * 4 > d.len() {
        return Ok(());
    }
    let mut order = vec_with(count)?;
    for i in 0..count {
        let v = d.u32(order_at + i * 4)?;
        if v >= count {
            return Ok(());
        }
        order.push(v as i32);
    }
    m.vertex_link_order = order;
    let tail = order_at + count * 4;
    if tail + 36 <= d.len() {
        let mut p = vec_with(9)?;
        p.push(d.u32(tail)? as f32);
        for k in 1..8 {
            p.push(d.f32(tail + k * 4)?);
        }
        p.push(d.u32(tail + 32)? as i32 as f32);
        m.cloth_params = p;
    }
    Ok(())
}

/// `_pp_to_arrays`'s index buffer: each triangle's second and third index swapped (the winding
/// reversed, round 47), any entries past the last whole triangle left 0, as the GDScript leaves
/// them.
pub fn wound_indices(indices: &[i32]) -> Vec<i32> {
    let n = indices.len();
    let mut out = vec![0; n];
    let mut i = 0;
    while i + 2 < n {
        out[i] = indices[i];
        out[i + 1] = indices[i + 2];
        out[i + 2] = indices[i + 1];
        i += 3;
    }
    out
}

/// `_pp_to_arrays`'s ARRAY_BONES / ARRAY_WEIGHTS, four influences a vertex: OBJECT_SPACE maps to
/// `palette_size` (one past the palette), -1 to 0, and the spare pair is weighted zero.
pub fn skin_arrays(skin: &Skin, palette_size: i32) -> (Vec<i32>, Vec<f32>) {
    let n = skin.bone0.len();
    let mut bones = Vec::with_capacity(n * 4);
    let mut weights = Vec::with_capacity(n * 4);
    for i in 0..n {
        let (b0, b1) = (skin.bone0[i], skin.bone1[i]);
        bones.push(if b0 == OBJECT_SPACE { palette_size } else { b0.max(0) });
        weights.push(if b0 != -1 { skin.weight0[i] as f32 } else { 1.0 });
        bones.push(if b1 == OBJECT_SPACE { palette_size } else { b1.max(0) });
        weights.push(if b1 != -1 { skin.weight1[i] as f32 } else { 0.0 });
        bones.extend_from_slice(&[0, 0]);
        weights.extend_from_slice(&[0.0, 0.0]);
    }
    (bones, weights)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn put_u32(b: &mut Vec<u8>, at: usize, v: u32) {
        b[at..at + 4].copy_from_slice(&v.to_le_bytes());
    }

    fn push_str(b: &mut Vec<u8>, s: &[u8]) {
        b.extend_from_slice(&(s.len() as u32).to_le_bytes());
        b.extend_from_slice(s);
    }

    fn push_f32s(b: &mut Vec<u8>, v: &[f32]) {
        for f in v {
            b.extend_from_slice(&f.to_le_bytes());
        }
    }

    /// A synthetic two-triangle quad: 4 vertices at `rec` bytes each, a skin section over a
    /// 2-bone palette with `skin` records, a bounding box, a motion section and a link section.
    pub(crate) fn synthetic(rec: usize, skin: &[(u8, u16, u8, u16)]) -> Vec<u8> {
        let mut b = vec![0u8; PREAMBLE_END as usize];
        b[..12].copy_from_slice(MAGIC);
        push_str(&mut b, b"quad\xe9");
        push_str(&mut b, b"mtl\0junk");
        b.extend_from_slice(&12u32.to_le_bytes());
        b.extend_from_slice(&4u32.to_le_bytes());
        let pos = [[0.0f32, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 1.0], [0.0, 0.0, 1.0]];
        for (i, p) in pos.iter().enumerate() {
            push_f32s(&mut b, p);
            push_f32s(&mut b, &[0.0, 1.0, 0.0]);
            push_f32s(&mut b, &[p[0], p[2]]);
            b.extend((0..rec - 0x20).map(|k| (i * 16 + k) as u8));
        }
        let skin_at = b.len();
        b.extend_from_slice(&2u32.to_le_bytes());
        push_str(&mut b, b"Bip01");
        push_str(&mut b, b"Bip01 Spine");
        for &(b0, w0, b1, w1) in skin {
            b.push(b0);
            b.extend_from_slice(&w0.to_le_bytes());
            b.push(b1);
            b.extend_from_slice(&w1.to_le_bytes());
        }
        let index_at = b.len();
        b.extend_from_slice(&2u32.to_le_bytes());
        for i in [0u16, 1, 2, 0, 2, 3] {
            b.extend_from_slice(&i.to_le_bytes());
        }
        let bbox_at = b.len();
        push_f32s(&mut b, &[0.0, 0.0, 0.0, 1.0, 0.0, 1.0]);
        let motion_at = b.len();
        b.extend_from_slice(&4u32.to_le_bytes());
        for (f, p) in [(0.0f32, 1u32), (0.05, 0), (0.1, 0), (0.0, 1)] {
            push_f32s(&mut b, &[f]);
            b.extend_from_slice(&p.to_le_bytes());
        }
        let links_at = b.len();
        b.extend_from_slice(&2u32.to_le_bytes());
        for (x, y, l) in [(0u32, 1u32, 1.0f32), (1, 2, 1.0)] {
            b.extend_from_slice(&x.to_le_bytes());
            b.extend_from_slice(&y.to_le_bytes());
            push_f32s(&mut b, &[l]);
        }
        b.extend_from_slice(&1u32.to_le_bytes());
        b.extend_from_slice(&0u32.to_le_bytes());
        // The parameter block: flag, wind, gravity, its gain, the gust's gain, retention, divisor.
        b.extend_from_slice(&1u32.to_le_bytes());
        push_f32s(&mut b, &[0.0, 0.0, 1.0, 9.8, 1.0, 0.0, 0.95]);
        b.extend_from_slice(&2u32.to_le_bytes());
        let base = HEADER_PTRS_BASE as usize;
        put_u32(&mut b, base, if skin.is_empty() { 0 } else { skin_at as u32 });
        put_u32(&mut b, base + 4, index_at as u32);
        put_u32(&mut b, base + 8, motion_at as u32);
        put_u32(&mut b, base + 12, links_at as u32);
        put_u32(&mut b, base + 16, bbox_at as u32);
        b
    }

    const FULL: [(u8, u16, u8, u16); 4] = [(0, 0xffff, 255, 0), (1, 0xffff, 255, 0), (0, 32765, 1, 32765), (255, 0, 1, 0xffff)];

    #[test]
    fn a_synthetic_quad_reads_every_section() {
        for rec in [44usize, 52] {
            let m = parse(&synthetic(rec, &FULL)).unwrap();
            assert_eq!(m.mesh_name, "quad\u{e9}"); // Latin-1, as get_string_from_ascii
            assert_eq!(m.material_name, "mtl"); // cut at the NUL
            assert_eq!(m.positions.len(), 4);
            assert_eq!(m.positions[2], [1.0, 0.0, 1.0]);
            assert_eq!(m.uvs[3], [0.0, 1.0]);
            assert_eq!(m.extra_size, rec - 0x20);
            assert_eq!(m.extra[m.extra_size], 16);
            assert_eq!(m.indices, vec![0, 1, 2, 0, 2, 3]);
            assert_eq!(m.bounds, Some(([0.0, 0.0, 0.0], [1.0, 0.0, 1.0])));
            assert_eq!(m.bone_names, vec!["Bip01".to_string(), "Bip01 Spine".to_string()]);
            let s = m.skin.as_ref().unwrap();
            assert_eq!(s.bone0, vec![0, 1, 0, 1]);
            assert_eq!(s.bone1, vec![-1, -1, 1, -1]);
            assert_eq!(s.weight0[2], 0.5);
            assert_eq!(s.weight1[2], 0.5);
            assert_eq!(m.object_space_vertices, 0);
            assert_eq!(m.vertex_motion, vec![0.0, 0.05, 0.1, 0.0]);
            assert_eq!(m.vertex_pinned, vec![1, 0, 0, 1]);
            assert_eq!(m.vertex_links, vec![0, 1, 1, 2]);
            assert_eq!(m.vertex_link_order, vec![1, 0]);
            assert_eq!(m.cloth_params, vec![1.0, 0.0, 0.0, 1.0, 9.8, 1.0, 0.0, 0.95, 2.0]);
        }
    }

    #[test]
    fn an_empty_slot_is_object_space_and_a_bad_index_keeps_the_partial_skin() {
        // Vertex 1 has no bone in either slot: OBJECT_SPACE, weight 1.
        let m = parse(&synthetic(44, &[(0, 0xffff, 255, 0), (255, 0, 255, 0), (0, 0xffff, 255, 0), (0, 0xffff, 255, 0)])).unwrap();
        let s = m.skin.as_ref().unwrap();
        assert_eq!((s.bone0[1], s.weight0[1]), (OBJECT_SPACE, 1.0));
        assert_eq!(m.object_space_vertices, 1);
        // Vertex 2 indexes bone 7 of 2: the palette is dropped, vertices 0-1 keep theirs.
        let m = parse(&synthetic(44, &[(1, 0xffff, 255, 0), (255, 0, 255, 0), (7, 0xffff, 255, 0), (0, 0xffff, 255, 0)])).unwrap();
        assert!(m.bone_names.is_empty());
        let s = m.skin.as_ref().unwrap();
        assert_eq!(s.bone0, vec![1, OBJECT_SPACE, -1, -1]);
        assert_eq!(m.object_space_vertices, 1);
    }

    /// The blend is a double, as GDScript's float: 1000 / (1000 + 3001) is not an f32.
    #[test]
    fn an_uneven_blend_keeps_double_precision() {
        let m = parse(&synthetic(44, &[(0, 1000, 1, 3001), (0, 0xffff, 255, 0), (0, 0xffff, 255, 0), (0, 0xffff, 255, 0)])).unwrap();
        let (f0, f1) = (1000.0 / 65535.0, 3001.0 / 65535.0);
        let blend: f64 = f0 / (f0 + f1);
        let s = m.skin.as_ref().unwrap();
        assert_eq!(s.weight0[0].to_bits(), blend.to_bits());
        assert_eq!(s.weight1[0].to_bits(), (1.0 - blend).to_bits());
    }

    #[test]
    fn to_arrays_pieces() {
        assert_eq!(wound_indices(&[0, 1, 2, 3, 4, 5, 9]), vec![0, 2, 1, 3, 5, 4, 0]);
        let skin = Skin { bone0: vec![1, OBJECT_SPACE, -1], bone1: vec![-1, 0, OBJECT_SPACE], weight0: vec![1.0, 0.25, 0.0], weight1: vec![0.0, 0.75, 0.0] };
        let (b, w) = skin_arrays(&skin, 2);
        assert_eq!(b, vec![1, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0]);
        assert_eq!(w, vec![1.0, 0.0, 0.0, 0.0, 0.25, 0.75, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn a_signalling_nan_comes_out_quiet() {
        assert_eq!(gd_f32(0x7f80_0001).to_bits(), 0x7fc0_0001);
        assert_eq!(gd_f32(0x3f80_0000), 1.0);
    }

    /// Every truncation of a valid file, and random bytes behind a valid magic: an answer or an
    /// Err, never a panic.
    #[test]
    fn truncated_and_random_input_never_panics() {
        let full = synthetic(52, &FULL);
        for n in 0..full.len() {
            let _ = parse(&full[..n]);
        }
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        for round in 0..3000 {
            let mut b = full.clone();
            let flips = 1 + round % 8;
            for _ in 0..flips {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                let at = (seed as usize) % b.len();
                b[at] = (seed >> 32) as u8;
            }
            let _ = parse(&b);
            let n = (seed as usize >> 8) % (b.len() + 1);
            let _ = parse(&b[..n]);
        }
        // Header pointers past 2^31 (negative in GDScript) are left to the GDScript reader.
        let mut b = full.clone();
        put_u32(&mut b, HEADER_PTRS_BASE as usize + 4, 0xffff_fff0);
        assert!(parse(&b).is_err());
        // A vertex count of four billion is refused before anything is allocated.
        let mut b = full;
        let count_at = PREAMBLE_END as usize + 9 + 12 + 4;
        put_u32(&mut b, count_at, u32::MAX);
        assert!(parse(&b).unwrap_err().contains("doesn't fit"));
    }
}
