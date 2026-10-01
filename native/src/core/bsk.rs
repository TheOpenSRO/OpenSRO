//! The `.bsk` (JMXVBSK 0101) skeleton reader, ported one to one from BskReader.parse
//! (client/scripts/bsk/bsk_reader.gd, round 669). docs/protocol/BSK_FORMAT.md has the format,
//! and BskReader.parse's doc comment the announce-then-resolve walk this repeats step for step.
//!
//! As with bms.rs: where the GDScript reader returns null this returns `Err`, and the client then
//! runs the GDScript reader, which reports its own error. Names pass the GDScript reader's own
//! character check, so they are plain ASCII and need no Latin-1 handling.

use std::collections::HashSet;

use super::bms::Bytes;

const MAGIC: &[u8] = b"JMXVBSK 0101";
const ROOT_TRANSFORM_LEN: i64 = 92;
const BONE_TRANSFORM_LEN: i64 = 88;
const MAX_NAME_LEN: i64 = 60;

/// BskReader.ParsedSkeleton, flat: bone i's transform is `transforms[offsets[i]..offsets[i + 1]]`
/// (88 bytes with a parent name, 92 without).
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Skeleton {
    pub root_name: String,
    pub root_transform: Vec<u8>,
    pub bone_names: Vec<String>,
    /// "" for a parent-less ("Type A") bone, as Bone.parent_name.
    pub parent_names: Vec<String>,
    pub transforms: Vec<u8>,
    pub offsets: Vec<i32>,
}

/// `_read_len_prefixed_string`: a 1..60-byte name of letters, digits, `()[]_-` and space.
fn read_name(d: &Bytes, off: i64) -> Option<(String, i64)> {
    if off + 4 > d.len() {
        return None;
    }
    let n = d.u32(off).ok()?;
    let off = off + 4;
    if n <= 0 || n > MAX_NAME_LEN || off + n > d.len() {
        return None;
    }
    let s = d.slice(off, off + n).ok()?;
    let ok = s.iter().all(|&c| c.is_ascii_alphanumeric() || matches!(c, b'(' | b')' | b'[' | b']' | b'_' | b'-' | b' '));
    if !ok {
        return None;
    }
    Some((s.iter().map(|&c| c as char).collect(), off + n))
}

/// `_read_len_prefixed_string_flex`: at `off`, or one byte on.
fn read_name_flex(d: &Bytes, off: i64) -> Option<(String, i64)> {
    read_name(d, off).or_else(|| read_name(d, off + 1))
}

/// `_looks_synced`.
fn looks_synced(d: &Bytes, off: i64) -> bool {
    off + 8 == d.len() || read_name_flex(d, off).is_some()
}

/// `_resolve_bone`: Type A (no parent, 92 bytes) when what follows is in sync, else Type B.
fn resolve_bone(d: &Bytes, s: &mut Skeleton, name: String, off: i64) -> Option<i64> {
    let a_end = off + ROOT_TRANSFORM_LEN;
    let (parent, from, end) = if a_end <= d.len() && looks_synced(d, a_end) {
        (String::new(), off, a_end)
    } else {
        let (parent, parent_end) = read_name_flex(d, off)?;
        let b_end = parent_end + BONE_TRANSFORM_LEN;
        if b_end > d.len() {
            return None;
        }
        (parent, parent_end, b_end)
    };
    let t = d.slice(from, end).ok()?;
    s.transforms.try_reserve(t.len()).ok()?;
    s.transforms.extend_from_slice(t);
    s.offsets.push(s.transforms.len() as i32);
    s.bone_names.push(name);
    s.parent_names.push(parent);
    Some(end)
}

/// BskReader.parse.
pub fn parse(data: &[u8]) -> Result<Skeleton, String> {
    let d = Bytes(data);
    if d.len() < MAGIC.len() as i64 + 5 {
        return Err("bsk: file too small to contain a header".into());
    }
    if super::bms::ascii_string(&data[..MAGIC.len()]).as_bytes() != MAGIC {
        return Err("bsk: bad magic".into());
    }
    let (root_name, mut off) = read_name(&d, MAGIC.len() as i64 + 5).ok_or("bsk: reading root name")?;
    if off + ROOT_TRANSFORM_LEN > d.len() {
        return Err("bsk: truncated before root transform".into());
    }
    let mut s = Skeleton { root_name, root_transform: d.slice(off, off + ROOT_TRANSFORM_LEN)?.to_vec(), offsets: vec![0], ..Default::default() };
    off += ROOT_TRANSFORM_LEN;

    let mut pending: HashSet<String> = HashSet::new();
    while off < d.len() {
        let Some((name, next)) = read_name_flex(&d, off) else {
            break; // the constant zero trailer, or truncation
        };
        if pending.remove(&name) {
            off = resolve_bone(&d, &mut s, name, next).ok_or("bsk: resolving a bone")?;
            continue;
        }
        if let Some((again, after)) = read_name_flex(&d, next) {
            if again == name {
                off = resolve_bone(&d, &mut s, name, after).ok_or("bsk: resolving a bone")?;
                continue;
            }
        }
        pending.insert(name);
        off = next;
    }
    if !pending.is_empty() {
        return Err(format!("bsk: {} bone name(s) announced but never resolved", pending.len()));
    }
    if s.bone_names.is_empty() {
        return Err("bsk: no bones parsed".into());
    }
    if cfg!(feature = "parity-negative") {
        if let Some(p) = s.parent_names.iter_mut().rev().find(|p| !p.is_empty()) {
            p.push(' '); // the parity negative's bug: the last named parent gains a space
        }
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push_name(b: &mut Vec<u8>, s: &str) {
        b.extend_from_slice(&(s.len() as u32).to_le_bytes());
        b.extend_from_slice(s.as_bytes());
    }

    /// root; "Bip01 Pelvis" resolved at once with a parent (Type B); "Bip01 Spine" announced,
    /// then "Bip01 Head" (Type B, after a one-byte gap), then the spine resolved Type A; trailer.
    pub(crate) fn synthetic() -> Vec<u8> {
        let mut b = MAGIC.to_vec();
        b.extend_from_slice(&[0u8; 5]);
        push_name(&mut b, "Bip01");
        b.extend((0..92).map(|i| i as u8));
        push_name(&mut b, "Bip01 Pelvis");
        push_name(&mut b, "Bip01 Pelvis");
        push_name(&mut b, "Bip01");
        b.extend([7u8; 88]);
        push_name(&mut b, "Bip01 Spine");
        push_name(&mut b, "Bip01 Head");
        b.push(0);
        push_name(&mut b, "Bip01 Head");
        push_name(&mut b, "Bip01 Spine");
        b.extend([9u8; 88]);
        push_name(&mut b, "Bip01 Spine");
        b.extend([5u8; 92]);
        b.extend([0u8; 8]);
        b
    }

    #[test]
    fn announcements_resolve_in_both_shapes() {
        let s = parse(&synthetic()).unwrap();
        assert_eq!(s.root_name, "Bip01");
        assert_eq!(s.root_transform.len(), 92);
        assert_eq!(s.bone_names, vec!["Bip01 Pelvis", "Bip01 Head", "Bip01 Spine"]);
        assert_eq!(s.parent_names, vec!["Bip01", "Bip01 Spine", ""]);
        assert_eq!(s.offsets, vec![0, 88, 176, 268]);
        assert_eq!(s.transforms[88], 9);
        assert_eq!(s.transforms[267], 5);
    }

    #[test]
    fn truncated_and_random_input_never_panics() {
        let full = synthetic();
        for n in 0..full.len() {
            let _ = parse(&full[..n]);
        }
        let mut seed = 0x1234_5678_9abc_def1u64;
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
        let mut b = full;
        b.truncate(200);
        assert!(parse(&b).is_err());
    }
}
