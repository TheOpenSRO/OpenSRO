//! The `.ban` (JMXVBAN 0102) bone-animation reader, ported one to one from BanReader.parse
//! (client/scripts/ban/ban_reader.gd, round 669). docs/protocol/BAN_FORMAT.md has the format.
//!
//! As with bms.rs: where the GDScript reader returns null this returns `Err`, the client then
//! runs the GDScript reader (which reports its own error), and every stored value has the bit
//! pattern GDScript gives it. The keyframes come back flat -- every bone's keys in file order,
//! with a key count per bone -- and BanReader builds its Keyframe objects from them.

use super::bms::{ascii_string, vec_with, Bytes};

const MAGIC: &[u8] = b"JMXVBAN 0102";
const KEYFRAME_SIZE: i64 = 28;
const MAX_TABLE_COUNT: i64 = 100_000;
const MAX_NAME_LEN: i64 = 4096;

/// BanReader.ParsedAnimation, as flat arrays.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Animation {
    pub animation_name: String,
    pub duration_ms: i64,
    pub authored_fps: i64,
    pub cyclic: bool,
    /// u32s stored in a PackedInt32Array, so a value at or above 2^31 wraps, as there.
    pub key_times: Vec<i32>,
    pub bone_names: Vec<String>,
    pub key_counts: Vec<i32>,
    /// x, y, z, w per keyframe.
    pub rotations: Vec<f32>,
    pub positions: Vec<[f32; 3]>,
}

fn read_len_prefixed_string(d: &Bytes, off: i64) -> Option<(String, i64)> {
    if off + 4 > d.len() {
        return None;
    }
    let n = d.u32(off).ok()?;
    let off = off + 4;
    if n > MAX_NAME_LEN || off + n > d.len() {
        return None;
    }
    Some((ascii_string(d.slice(off, off + n).ok()?), off + n))
}

/// BanReader.parse.
pub fn parse(data: &[u8]) -> Result<Animation, String> {
    let d = Bytes(data);
    if d.len() < MAGIC.len() as i64 + 4 {
        return Err("ban: file too small to contain a header".into());
    }
    if ascii_string(&data[..MAGIC.len()]).as_bytes() != MAGIC {
        return Err("ban: bad magic".into());
    }
    let off = MAGIC.len() as i64 + 8;
    let (animation_name, mut off) = read_len_prefixed_string(&d, off).ok_or("ban: reading name")?;
    if off + 12 > d.len() {
        return Err("ban: truncated before header fields".into());
    }
    let mut a = Animation {
        animation_name,
        duration_ms: d.u32(off)?,
        authored_fps: d.u32(off + 4)?,
        cyclic: d.u32(off + 8)? != 0,
        ..Default::default()
    };
    off += 12;

    if off + 4 > d.len() {
        return Err("ban: truncated before the key time table".into());
    }
    let table_count = d.u32(off)?;
    off += 4;
    if table_count > MAX_TABLE_COUNT {
        return Err(format!("ban: implausible key time count {table_count}"));
    }
    if off + table_count * 4 > d.len() {
        return Err("ban: key time table runs past end of file".into());
    }
    a.key_times = vec_with(table_count)?;
    for i in 0..table_count {
        a.key_times.push(d.u32(off + i * 4)? as u32 as i32);
    }
    if cfg!(feature = "parity-negative") {
        if let Some(last) = a.key_times.last_mut() {
            *last = last.wrapping_add(1); // the parity negative's bug: the last key time a millisecond late
        }
    }
    off += table_count * 4;

    if off + 4 > d.len() {
        return Err("ban: truncated before bone count".into());
    }
    let bone_count = d.u32(off)?;
    off += 4;

    // No reservation from bone_count: it is not checked against the data, and a bone takes at
    // least 8 bytes, so the vectors grow only with what the file really holds.
    let mut keys_total: i64 = 0;
    for i in 0..bone_count {
        let (name, next) = read_len_prefixed_string(&d, off).ok_or_else(|| format!("ban: reading bone {}/{}", i + 1, bone_count))?;
        off = next;
        if off + 4 > d.len() {
            return Err(format!("ban: reading bone {}/{}", i + 1, bone_count));
        }
        let kf_count = d.u32(off)?;
        off += 4;
        let end = off + kf_count * KEYFRAME_SIZE;
        if end > d.len() {
            return Err(format!("ban: reading bone {}/{}", i + 1, bone_count));
        }
        keys_total += kf_count;
        a.rotations.try_reserve(kf_count as usize * 4).map_err(|e| e.to_string())?;
        a.positions.try_reserve(kf_count as usize).map_err(|e| e.to_string())?;
        for k in 0..kf_count {
            let r = off + k * KEYFRAME_SIZE;
            for c in 0..4 {
                a.rotations.push(d.f32(r + c * 4)?);
            }
            a.positions.push([d.f32(r + 16)?, d.f32(r + 20)?, d.f32(r + 24)?]);
        }
        a.bone_names.push(name);
        a.key_counts.push(kf_count as i32);
        off = end;
    }
    debug_assert_eq!(keys_total as usize, a.positions.len());
    Ok(a)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push_str(b: &mut Vec<u8>, s: &[u8]) {
        b.extend_from_slice(&(s.len() as u32).to_le_bytes());
        b.extend_from_slice(s);
    }

    fn synthetic() -> Vec<u8> {
        let mut b = MAGIC.to_vec();
        b.extend_from_slice(&[0u8; 8]);
        push_str(&mut b, b"walk\xff");
        for v in [2333u32, 30, 1] {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&3u32.to_le_bytes());
        for t in [0u32, 1167, 0x8000_0000] {
            b.extend_from_slice(&t.to_le_bytes());
        }
        b.extend_from_slice(&2u32.to_le_bytes());
        push_str(&mut b, b"Bip01");
        b.extend_from_slice(&2u32.to_le_bytes());
        for k in 0..2 {
            for f in [0.0f32, 0.0, 0.0, 1.0, k as f32, 2.0, 3.0] {
                b.extend_from_slice(&f.to_le_bytes());
            }
        }
        push_str(&mut b, b"");
        b.extend_from_slice(&0u32.to_le_bytes());
        b
    }

    #[test]
    fn a_synthetic_clip_reads_every_field() {
        let a = parse(&synthetic()).unwrap();
        assert_eq!(a.animation_name, "walk\u{ff}");
        assert_eq!((a.duration_ms, a.authored_fps, a.cyclic), (2333, 30, true));
        assert_eq!(a.key_times, vec![0, 1167, i32::MIN]);
        assert_eq!(a.bone_names, vec!["Bip01".to_string(), String::new()]);
        assert_eq!(a.key_counts, vec![2, 0]);
        assert_eq!(a.rotations, vec![0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
        assert_eq!(a.positions, vec![[0.0, 2.0, 3.0], [1.0, 2.0, 3.0]]);
    }

    #[test]
    fn truncated_and_random_input_never_panics() {
        let full = synthetic();
        for n in 0..full.len() {
            assert!(parse(&full[..n]).is_err());
        }
        let mut seed = 0x9e37_79b9_7f4a_7c15u64;
        for round in 0..3000 {
            let mut b = full.clone();
            for _ in 0..1 + round % 6 {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                let at = (seed as usize) % b.len();
                b[at] = (seed >> 32) as u8;
            }
            let _ = parse(&b);
        }
        // Four billion bones and four billion keys: refused by the data's size, not allocated.
        let mut b = full.clone();
        let bones_at = full.len() - (4 + 5 + 4 + 2 * 28 + 4 + 4) - 4;
        b[bones_at..bones_at + 4].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(parse(&b).is_err());
        let mut b = full;
        let kf_at = bones_at + 4 + 4 + 5;
        b[kf_at..kf_at + 4].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(parse(&b).is_err());
    }
}
