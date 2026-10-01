//! The per-pixel decodes of DdjReader.to_image (client/scripts/ddj/ddj_reader.gd): an
//! uncompressed texture through its own DDS channel masks, and the A16B16G16R16F ('q') one. The
//! DXT branches stay in GDScript: Image.create_from_data already hands them to Godot's C++.
//! docs/protocol/DDJ_FORMAT.md has the format. Errors carry the GDScript reader's own messages.

pub struct Masks {
    pub r: u64,
    pub g: u64,
    pub b: u64,
    pub a: u64,
}

fn mask_shift(mask: u64) -> u32 {
    if mask == 0 {
        0
    } else {
        mask.trailing_zeros()
    }
}

#[inline(always)]
fn scale(masked: u64, shift: u32, max: u64) -> u8 {
    if max == 0 {
        255
    } else {
        // u128: a mask wider than 56 bits would overflow u64 here (round 667's review, L1).
        ((((masked >> shift) as u128) * 255) / max as u128) as u8
    }
}

/// ddj_reader.gd's `""` branch: RGBA8 from `pixels` (the DDS payload after its header), read
/// `bpp / 8` bytes a pixel, little-endian, each channel scaled up to 0..255 by its own mask.
/// bpp 0 and all-zero colour masks take the GDScript reader's historical fallbacks.
pub fn decode_masked(pixels: &[u8], width: u64, height: u64, bpp_in: u64, masks: &Masks) -> Result<Vec<u8>, String> {
    let px_count = width.checked_mul(height).ok_or("ddj: texture size overflows")?;
    let mut bpp = bpp_in;
    if bpp == 0 {
        bpp = if (pixels.len() as u64) >= px_count.saturating_mul(4) { 32 } else { 24 };
    }
    if bpp % 8 != 0 {
        return Err(format!("ddj: uncompressed texture with {bpp} bits per pixel"));
    }
    let stride = (bpp / 8) as usize;
    let need = px_count.saturating_mul(stride as u64);
    if (pixels.len() as u64) < need {
        return Err(format!(
            "ddj: uncompressed payload is {} bytes, need {} for {}x{} at {} bpp",
            pixels.len(), need, width, height, bpp
        ));
    }
    if stride == 0 || stride > 8 {
        return Err(format!("ddj: uncompressed texture with {bpp} bits per pixel"));
    }
    let (mut r, mut g, mut b, mut a) = (masks.r, masks.g, masks.b, masks.a);
    if r == 0 && g == 0 && b == 0 {
        r = 0x00FF_0000;
        g = 0x0000_FF00;
        b = 0x0000_00FF;
        a = if stride == 4 { 0xFF00_0000 } else { 0 };
    }
    let (rs, gs, bs, as_) = (mask_shift(r), mask_shift(g), mask_shift(b), mask_shift(a));
    let (rm, gm, bm, am) = (r >> rs, g >> gs, b >> bs, a >> as_);
    let n = px_count as usize;
    let mut out = vec![0u8; n * 4];
    for (i, o) in out.chunks_exact_mut(4).enumerate() {
        let src = &pixels[i * stride..i * stride + stride];
        let mut px: u64 = 0;
        for (k, &byte) in src.iter().enumerate() {
            px |= (byte as u64) << (k * 8);
        }
        o[0] = scale(px & r, rs, rm);
        o[1] = scale(px & g, gs, gm);
        o[2] = scale(px & b, bs, bm);
        if cfg!(feature = "parity-negative") {
            o.swap(0, 2); // the parity negative's bug: BGR left unswizzled
        }
        o[3] = if a != 0 { scale(px & a, as_, am) } else { 255 };
    }
    Ok(out)
}

/// IEEE half -> f64, as Godot's PackedByteArray.decode_half (Math::half_to_float).
fn half_to_f64(h: u16) -> f64 {
    let sign = if h & 0x8000 != 0 { -1.0 } else { 1.0 };
    let exp = ((h >> 10) & 0x1f) as i32;
    let mant = (h & 0x3ff) as f64;
    let v = match exp {
        0 => mant * 2f64.powi(-24),
        31 => {
            if mant == 0.0 {
                f64::INFINITY
            } else {
                f64::NAN
            }
        }
        _ => (1.0 + mant / 1024.0) * 2f64.powi(exp - 15),
    };
    sign * v
}

/// ddj_reader.gd's `"q"` branch (D3DFMT_A16B16G16R16F, round 621): the top level only, each
/// channel clamped to 0..1 and rounded to 8 bits -- clampi(roundi(clampf(h, 0, 1) * 255), 0, 255).
pub fn decode_half_rgba(pixels: &[u8], width: u64, height: u64) -> Result<Vec<u8>, String> {
    let need = width.checked_mul(height).and_then(|n| n.checked_mul(8)).ok_or("ddj: texture size overflows")?;
    if (pixels.len() as u64) < need {
        return Err(format!("ddj: A16B16G16R16F payload is {} bytes, need {}", pixels.len(), need));
    }
    let n = (width * height * 4) as usize;
    let mut out = vec![0u8; n];
    for (k, o) in out.iter_mut().enumerate() {
        let h = half_to_f64(u16::from_le_bytes([pixels[k * 2], pixels[k * 2 + 1]]));
        // Godot's CLAMP passes a NaN through and roundi of NaN lands on 0 after clampi; `as i64`
        // saturates NaN to 0 the same way.
        let c = if h < 0.0 { 0.0 } else if h > 1.0 { 1.0 } else { h };
        let v = (c * 255.0).round() as i64;
        *o = v.clamp(0, 255) as u8;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bgra32_is_swizzled_to_rgba() {
        let px = [0x10, 0x20, 0x30, 0x40, 0xff, 0x00, 0x80, 0x01];
        let m = Masks { r: 0x00FF_0000, g: 0x0000_FF00, b: 0xFF, a: 0xFF00_0000 };
        assert_eq!(decode_masked(&px, 2, 1, 32, &m).unwrap(), vec![0x30, 0x20, 0x10, 0x40, 0x80, 0x00, 0xff, 0x01]);
    }

    #[test]
    fn argb1555_scales_five_bits_to_eight() {
        // 0xFFFF: every channel full; 0x7C00: red full, alpha bit clear; 0x0421: 1/31 each.
        let px = [0xff, 0xff, 0x00, 0x7c, 0x21, 0x04];
        let m = Masks { r: 0x7C00, g: 0x03E0, b: 0x001F, a: 0x8000 };
        assert_eq!(
            decode_masked(&px, 3, 1, 16, &m).unwrap(),
            vec![255, 255, 255, 255, 255, 0, 0, 0, 8, 8, 8, 0]
        );
    }

    #[test]
    fn fallbacks_and_errors_match_the_gdscript_reader() {
        let none = Masks { r: 0, g: 0, b: 0, a: 0 };
        // bpp 0 with 3 bytes a pixel -> 24-bit BGR, opaque.
        assert_eq!(decode_masked(&[1, 2, 3], 1, 1, 0, &none).unwrap(), vec![3, 2, 1, 255]);
        assert_eq!(decode_masked(&[1, 2], 1, 1, 12, &none).unwrap_err(), "ddj: uncompressed texture with 12 bits per pixel");
        assert_eq!(
            decode_masked(&[1, 2], 1, 1, 32, &none).unwrap_err(),
            "ddj: uncompressed payload is 2 bytes, need 4 for 1x1 at 32 bpp"
        );
    }

    /// A mask wider than 56 bits (a negative int from GDScript becomes one through the binding)
    /// must not overflow `value * 255` (round 667's review, L1).
    #[test]
    fn wide_masks_do_not_overflow() {
        let px = [0xffu8; 8];
        let m = Masks { r: u64::MAX, g: 0, b: 0, a: 0 };
        // An empty colour mask reads full (255), as _scale_channel's `channel_max <= 0` does.
        assert_eq!(decode_masked(&px, 1, 1, 64, &m).unwrap(), vec![255, 255, 255, 255]);
        let m = Masks { r: u64::MAX, g: 0xff, b: 0xff00, a: 0 };
        let px = [0x80u8, 0x40, 0, 0, 0, 0, 0, 0];
        // r: 0x4080 * 255 / (2^64 - 1) rounds down to 0.
        assert_eq!(decode_masked(&px, 1, 1, 64, &m).unwrap(), vec![0, 0x80, 0x40, 255]);
    }

    #[test]
    fn half_floats_clamp_and_round() {
        // 0.0, 1.0, 0.5 (-> 127.5 -> 128), -2.0 (-> 0), 65504 (-> 255), NaN (-> 0), +inf, 0.25
        let hs: [u16; 8] = [0x0000, 0x3c00, 0x3800, 0xc000, 0x7bff, 0x7e00, 0x7c00, 0x3400];
        let bytes: Vec<u8> = hs.iter().flat_map(|h| h.to_le_bytes()).collect();
        assert_eq!(decode_half_rgba(&bytes, 2, 1).unwrap(), vec![0, 255, 128, 0, 255, 0, 255, 64]);
        assert!(decode_half_rgba(&bytes, 2, 2).is_err());
    }
}
