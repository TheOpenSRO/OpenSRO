//! Does a DXT1 payload mark any texel transparent? (round 695)
//!
//! Godot 4.2.2's Forward+ (and Mobile) uploads an `Image.FORMAT_DXT1` as Vulkan's `BC1_RGB` with
//! its alpha swizzled to ONE (READ: servers/rendering/renderer_rd/storage_rd/texture_storage.cpp
//! 1721-1735). A DXT1 block in its three-colour mode (colour0 <= colour1) marks a texel
//! transparent with index 3, which BC1_RGB samples as opaque black. GL Compatibility uploads the
//! same image as `COMPRESSED_RGBA_S3TC_DXT1` (drivers/gles3/storage/texture_storage.cpp 418-426)
//! and keeps it transparent. DdjReader (client/scripts/ddj/ddj_reader.gd) therefore decodes such
//! a texture to RGBA8 under Forward+ -- with the engine's own decoder, as Godot's RD path itself
//! does when BC1 is unsupported -- and needs to know which textures they are without a GDScript
//! loop over every block of every DXT1 it loads. This is that scan.
//!
//! Round 695 also tried, and rejected, re-encoding them as DXT3 (half the memory of RGBA8): a
//! four-colour palette cannot hold a three-colour block's colours and its transparent black at
//! once, so transparent texels lost their black (which a lightmap or an opaque material samples)
//! and 0.42 % of opaque texels moved by more than 8/255 (MEASURED over the archives; WORLD_ISSUES
//! round 695).

/// True when the 8-byte DXT1 block marks at least one texel transparent: three-colour mode
/// (colour0 <= colour1) and a 2-bit index equal to 3.
#[inline]
pub fn block_has_transparent(blk: &[u8]) -> bool {
    let c0 = u16::from_le_bytes([blk[0], blk[1]]);
    let c1 = u16::from_le_bytes([blk[2], blk[3]]);
    // The parity check's NEGATIVE (Cargo.toml, parity-negative): a one-colour block (c0 == c1)
    // is read as four-colour, so its transparent texels are missed.
    if c0 > c1 || (cfg!(feature = "parity-negative") && c0 == c1) {
        return false;
    }
    let idx = u32::from_le_bytes([blk[4], blk[5], blk[6], blk[7]]);
    (idx & (idx >> 1) & 0x5555_5555) != 0
}

/// True when any whole 8-byte block of `data` (a DXT1 payload, every mip level) has a transparent
/// texel. A trailing partial block is ignored, as DdjReader's GDScript scan ignores it.
pub fn has_transparent(data: &[u8]) -> bool {
    data.chunks_exact(8).any(block_has_transparent)
}

/// Blocks of `data` with a transparent texel (the census example).
pub fn transparent_blocks(data: &[u8]) -> usize {
    data.chunks_exact(8).filter(|b| block_has_transparent(b)).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(c0: u16, c1: u16, idx: [u8; 16]) -> [u8; 8] {
        let mut v: u32 = 0;
        for (i, s) in idx.iter().enumerate() {
            v |= (*s as u32) << (2 * i);
        }
        let mut b = [0u8; 8];
        b[0..2].copy_from_slice(&c0.to_le_bytes());
        b[2..4].copy_from_slice(&c1.to_le_bytes());
        b[4..8].copy_from_slice(&v.to_le_bytes());
        b
    }

    #[test]
    fn index_3_is_transparent_only_in_three_colour_mode() {
        let all = [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3];
        // Four-colour (c0 > c1): index 3 is a colour.
        assert!(!block_has_transparent(&block(0xf800, 0x001f, all)));
        // Three-colour without index 3: opaque.
        assert!(!block_has_transparent(&block(0x001f, 0xf800, [0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0])));
        // Three-colour with index 3 at the last texel only; and c0 == c1 counts as three-colour.
        let mut last = [0u8; 16];
        last[15] = 3;
        assert!(block_has_transparent(&block(0x001f, 0xf800, last)));
        assert!(block_has_transparent(&block(0x1234, 0x1234, last)));
        // Index 2 next to index 1 must not look like a 3 across the field boundary.
        assert!(!block_has_transparent(&block(0x001f, 0xf800, [1, 2, 1, 2, 2, 1, 2, 1, 1, 2, 1, 2, 2, 1, 2, 1])));
    }

    #[test]
    fn a_transparent_block_anywhere_in_the_payload_counts() {
        let opaque = block(0xf800, 0x001f, [3; 16]);
        let mut last = [0u8; 16];
        last[0] = 3;
        let t = block(0x0000, 0xffff, last);
        let mut data = Vec::new();
        for _ in 0..100 {
            data.extend_from_slice(&opaque);
        }
        assert!(!has_transparent(&data));
        data.extend_from_slice(&t);
        assert!(has_transparent(&data));
        assert_eq!(transparent_blocks(&data), 1);
        // A trailing partial block is ignored.
        assert!(!has_transparent(&t[0..7]));
    }
}
