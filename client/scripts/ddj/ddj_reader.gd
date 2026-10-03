extends RefCounted
class_name DdjReader

## Read-only parser for the .ddj texture container format.
## See docs/protocol/DDJ_FORMAT.md for the on-disk layout. Mirrors
## server/internal/ddj's Go implementation; keep the two in sync if the
## format understanding changes.
##
## .ddj is a small proprietary 20-byte wrapper around an otherwise
## completely standard, unmodified Microsoft DDS file -- see the doc for how
## that was confirmed. This reader exposes the embedded DDS header fields
## plus a ready-to-use Godot Texture2D built from the raw pixel data.

const MAGIC := "JMXVDDJ 1000"
const MAGIC_LEN := 12
const WRAPPER_SIZE := 20
const DDS_HEADER_SIZE := 124
const DDPF_FOURCC := 0x4
const DDPF_RGB := 0x40
const DDPF_ALPHAPIXELS := 0x1

class ParsedTexture:
	var width: int
	var height: int
	var mip_map_count: int
	var four_cc: String
	## Bits per pixel and the channel masks, for an uncompressed texture
	## (all zero when four_cc is set). Read from the file's own
	## DDS_PIXELFORMAT rather than assumed: real interface art is 16-bit
	## ARGB1555 while real world textures are 32-bit BGRA, and only these
	## fields distinguish them. See to_texture.
	var rgb_bit_count: int
	var r_mask: int
	var g_mask: int
	var b_mask: int
	var a_mask: int
	## Raw bytes of the embedded DDS file (starting at its own "DDS " magic).
	var dds: PackedByteArray

## Parses a .ddj file's raw bytes. Returns null (and pushes an error) on
## failure.
static func parse(data: PackedByteArray) -> ParsedTexture:
	var _pp := ParseProfile.t0()
	var _out: ParsedTexture = _pp_parse(data)
	ParseProfile.add("ddj.parse", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray) -> ParsedTexture:
	if data.size() < WRAPPER_SIZE + 4:
		push_error("ddj: file too small to contain the wrapper header")
		return null

	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("ddj: bad magic %s, want %s" % [magic, MAGIC])
		return null

	# The 0x0c field usually equals data.size()-MAGIC_LEN, but a real sample
	# (Prim\Mtrl\Item\China\weapon\shield_90.ddj, 2026-08-24) has a value
	# 256 bytes larger than the actual file, even though its embedded DDS
	# header and pixel data are otherwise completely well formed and
	# byte-exact for its declared width/height/mip count. So it's not a
	# reliable file-size check across all real files and isn't used to
	# gate parsing.

	var dds := data.slice(WRAPPER_SIZE)
	if dds.size() < 4 + DDS_HEADER_SIZE:
		push_error("ddj: truncated before embedded DDS header")
		return null
	var dds_magic := dds.slice(0, 4).get_string_from_ascii()
	if dds_magic != "DDS ":
		push_error("ddj: embedded payload has bad DDS magic %s" % dds_magic)
		return null
	var hdr_size := _le_u32(dds, 4)
	if hdr_size != DDS_HEADER_SIZE:
		push_error("ddj: embedded DDS_HEADER dwSize is %d, want %d" % [hdr_size, DDS_HEADER_SIZE])
		return null

	var tex := ParsedTexture.new()
	tex.height = _le_u32(dds, 4 + 8)
	tex.width = _le_u32(dds, 4 + 12)
	tex.mip_map_count = _le_u32(dds, 4 + 24)
	tex.dds = dds

	var pf_off := 4 + 72
	if dds.size() >= pf_off + 12:
		var pf_flags := _le_u32(dds, pf_off + 4)
		if pf_flags & DDPF_FOURCC != 0:
			tex.four_cc = dds.slice(pf_off + 8, pf_off + 12).get_string_from_ascii()
		elif dds.size() >= pf_off + 32:
			# DDS_PIXELFORMAT continues with dwRGBBitCount and the four
			# channel masks. Only meaningful for an uncompressed texture.
			tex.rgb_bit_count = _le_u32(dds, pf_off + 12)
			tex.r_mask = _le_u32(dds, pf_off + 16)
			tex.g_mask = _le_u32(dds, pf_off + 20)
			tex.b_mask = _le_u32(dds, pf_off + 24)
			tex.a_mask = _le_u32(dds, pf_off + 28) if pf_flags & DDPF_ALPHAPIXELS != 0 else 0

	return tex

## Builds a Godot Texture2D from a parsed Texture, decoding the pixel data
## according to the embedded DDS pixel format. Returns null (and pushes an
## error) for a compression format not yet handled.
static func to_texture(tex: ParsedTexture) -> ImageTexture:
	var image := to_image(tex)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)

## to_texture's Image, before the ImageTexture (round 565). An Image owns no
## RenderingServer RID, so a WorkerThreadPool task can decode one
## (World3D._terrain_prepare does, for a region's ground tiles) and the main
## thread uploads it with ImageTexture.create_from_image -- to_texture is
## exactly that pair. Null (and the same pushed errors) where to_texture
## returns null.
static func to_image(tex: ParsedTexture) -> Image:
	var _pp := ParseProfile.t0()
	var _out: Image = _pp_to_image(tex)
	# Keyed by format (round 667): the per-pixel branches are what cost.
	ParseProfile.add("ddj.to_image." + (tex.four_cc if tex.four_cc != "" else "rgb%d" % tex.rgb_bit_count), _pp)
	return _out

## The per-pixel decodes through the native library (round 667), or an empty
## array -- no library, or an input the native decode refuses, which the
## GDScript branch below then reports with its own error. `four_cc` is "" or
## "q", the two branches that loop over pixels in GDScript.
static func _native_rgba(tex: ParsedTexture, pixels: PackedByteArray) -> PackedByteArray:
	var native := NativeAssets.parsers()
	if native == null:
		return PackedByteArray()
	var d: Dictionary
	if tex.four_cc == "q":
		d = native.call("ddj_decode_half", pixels, tex.width, tex.height)
	else:
		d = native.call("ddj_decode_masked", pixels, tex.width, tex.height, tex.rgb_bit_count,
			tex.r_mask, tex.g_mask, tex.b_mask, tex.a_mask)
	return d.get("rgba", PackedByteArray())

## **DXT1's transparent texels under Forward+ (round 695).** Godot 4.2.2's
## RenderingDevice renderers (Forward+, Mobile) upload Image.FORMAT_DXT1 as
## Vulkan's BC1_RGB with the alpha swizzled to ONE (READ: servers/rendering/
## renderer_rd/storage_rd/texture_storage.cpp 1721-1735), so a texel a
## three-colour DXT1 block marks transparent (index 3) samples as opaque
## black. GL Compatibility uploads COMPRESSED_RGBA_S3TC_DXT1 (drivers/gles3/
## storage/texture_storage.cpp 418-426) and keeps it transparent. From round
## 693 (Forward+ by default) every alpha-tested card in such a texture -- tree
## leaves, hair, fences -- drew as a solid dark quad. 4,024 of the archives'
## 24,493 DXT1 textures mark a texel transparent (MEASURED, round 695).
##
## 4.2.2 has no Image format for BC1 with alpha, and texture_rd_create refuses
## BC1_RGBA (_texture_format_from_rd has no entry for it). So under Forward+
## such a texture is decoded on the CPU by the engine's own decoder (squish),
## one mip level at a time (dxt1_to_rgba8), and handed to Godot as
## Image.FORMAT_RGBA8, whose upload keeps the alpha channel. (The RD path's own
## fallback where BC1 is unsupported, 1725-1731, decompresses too but still
## sets swizzle_a = ONE at 1735 -- it would lose the alpha as well; it is the
## FORMAT_RGBA8 handed over that keeps it.) Alpha then equals Compatibility's
## texel for texel: transparent texels (0, 0, 0, 0). The colours are within a
## few levels of what a GPU's DXT1 decoder gives (squish interpolates the
## middle colours in integer arithmetic; GPUs differ from it and from each
## other by about 1-3/255). It costs 8x the DXT1's memory, for those textures
## only. A DXT1 with no transparent texel, and every DXT1 under Compatibility,
## stays DXT1. (A DXT3 re-encode, a quarter of that memory, was tried and
## rejected: WORLD_ISSUES round 695.)

## Tests set this: -1 asks the renderer, 0 keeps DXT1, 1 decodes. The QA
## A/B switch OPENSRO_QA_DXT1_KEEP=1 (OURS) keeps DXT1 for a whole run: the
## pre-695 drawing, for a before picture and a cost comparison.
static var dxt1_alpha_override := -1
static var _dxt1_rd := -1
## How many DXT1s were decoded to RGBA8 this way, and their RGBA8 bytes
## (QA ENTRY's line; round 695).
static var dxt1_alpha_decoded := 0
static var dxt1_alpha_bytes := 0
static var _dxt1_count_lock := Mutex.new()

## True when DXT1's alpha would be lost: a RenderingDevice renderer drawing.
static func dxt1_needs_alpha_format() -> bool:
	if dxt1_alpha_override >= 0:
		return dxt1_alpha_override == 1
	if _dxt1_rd < 0:
		# RendererChoice.running()'s test: headless draws nothing.
		_dxt1_rd = 1 if DisplayServer.get_name() != "headless" and RenderingServer.get_rendering_device() != null \
			and OS.get_environment("OPENSRO_QA_DXT1_KEEP") != "1" else 0
	return _dxt1_rd == 1

## True when any whole 8-byte block of a DXT1 payload marks a texel
## transparent: colour0 <= colour1 (three-colour mode) and an index of 3.
## Through the native library when it is loaded (native/src/core/dxt.rs).
static func dxt1_has_transparent(pixels: PackedByteArray) -> bool:
	# Guarded by method, not by the interface number (round 695's review, L6):
	# a library from before round 695 (an update whose DLL swap rolled back)
	# keeps every other native reader and only this scan runs in GDScript.
	var native := NativeAssets.parsers()
	if native != null and native.has_method("ddj_dxt1_has_transparent"):
		return bool(native.call("ddj_dxt1_has_transparent", pixels))
	var n := pixels.size() >> 3
	for b in range(n):
		var o := b << 3
		if pixels.decode_u16(o) <= pixels.decode_u16(o + 2):
			var idx := pixels.decode_u32(o + 4)
			if idx & (idx >> 1) & 0x55555555 != 0:
				return true
	return false

## The DXT1 payload decoded to RGBA8 (mip levels kept), or null when no texel
## is transparent (it stays DXT1) or a level could not be decoded.
static func _dxt1_with_alpha(tex: ParsedTexture, pixels: PackedByteArray) -> Image:
	if not dxt1_has_transparent(pixels):
		return null
	var img := dxt1_to_rgba8(tex.width, tex.height, tex.mip_map_count > 1, pixels)
	if img == null:
		return null
	_dxt1_count_lock.lock()
	dxt1_alpha_decoded += 1
	dxt1_alpha_bytes += img.get_data().size() # a copy-on-write reference, not a copy
	_dxt1_count_lock.unlock()
	return img

## A DXT1 payload (`mipmaps`: the full chain to 1x1, as Image.create_from_data
## lays it out) as one RGBA8 Image, decoded ONE LEVEL AT A TIME (round 695's
## review, M1). Image.decompress on the whole chain is wrong for a non-square
## texture in 4.2.2: squish's loop halves width and height with no floor of 1
## (modules/squish/image_decompress_squish.cpp, `w >>= 1; h >>= 1;`), so once
## the short side reaches 0 the remaining levels are not decoded and keep
## whatever the buffer held (MEASURED by the review: a 256x64 texture's last
## two levels came out (0,0,0,0), a 64x256's held leftover bytes). Each level
## here has its own width and height, floored at 1, and the block-padded size
## Image._get_dst_image_size gives it: ceil(w/4) x ceil(h/4) blocks of 8 bytes.
## Null when the payload is short or a level does not decode.
static func dxt1_to_rgba8(width: int, height: int, mipmaps: bool, pixels: PackedByteArray) -> Image:
	var out := PackedByteArray()
	var mw := width
	var mh := height
	var ofs := 0
	while true:
		var size := ((mw + 3) >> 2) * ((mh + 3) >> 2) * 8
		if ofs + size > pixels.size():
			return null
		var level := Image.create_from_data(mw, mh, false, Image.FORMAT_DXT1, pixels.slice(ofs, ofs + size))
		if level == null or level.is_empty() or level.decompress() != OK or level.get_format() != Image.FORMAT_RGBA8:
			return null
		out.append_array(level.get_data())
		ofs += size
		if not mipmaps or (mw == 1 and mh == 1):
			break
		mw = maxi(1, mw >> 1)
		mh = maxi(1, mh >> 1)
	return Image.create_from_data(width, height, mipmaps, Image.FORMAT_RGBA8, out)

## The body of to_image, timed by its wrapper above (ParseProfile, round 667).
static func _pp_to_image(tex: ParsedTexture) -> Image:
	var pixels := tex.dds.slice(4 + DDS_HEADER_SIZE)
	var image: Image

	# The two per-pixel branches below, in Rust when the library is loaded
	# (round 667; native/src/core/ddj.rs, held to them byte for byte).
	if tex.four_cc == "" or tex.four_cc == "q":
		var rgba := _native_rgba(tex, pixels)
		if not rgba.is_empty():
			return Image.create_from_data(tex.width, tex.height, false, Image.FORMAT_RGBA8, rgba)

	match tex.four_cc:
		"DXT1":
			# Under Forward+ a DXT1 with transparent texels changes format
			# (round 695, dxt1_needs_alpha_format); null keeps it DXT1.
			if dxt1_needs_alpha_format():
				image = _dxt1_with_alpha(tex, pixels)
			if image == null:
				image = Image.create_from_data(tex.width, tex.height, tex.mip_map_count > 1, Image.FORMAT_DXT1, pixels)
		"DXT2", "DXT3":
			# DXT2 and DXT3 are bit-identical block formats -- the only real
			# difference is whether DXT2's color channels are premultiplied
			# by alpha (a real encoding convention for certain blend modes),
			# not the compressed block layout itself. Found live-testing a
			# real region outside the initially-tested Jangan cluster
			# (2026-08-24) -- decoding it as plain DXT3 is the correct real
			# block decompression either way; this project doesn't
			# currently do anything with alpha that would need the
			# premultiplied distinction un-done (e.g. a custom premultiplied-
			# alpha blend mode), so no further real correction is applied.
			image = Image.create_from_data(tex.width, tex.height, tex.mip_map_count > 1, Image.FORMAT_DXT3, pixels)
		"DXT5":
			image = Image.create_from_data(tex.width, tex.height, tex.mip_map_count > 1, Image.FORMAT_DXT5, pixels)
		"":
			# Uncompressed, decoded through the file's own channel masks.
			#
			# **Corrected 2026-09-08.** This branch used to assume 24- or
			# 32-bit BGR(A), picking between them by whether the payload was
			# big enough for 4 bytes a pixel. That held for every world
			# texture this project had loaded, and broke the moment real
			# interface art was loaded: `interface\` .ddj files are **16-bit
			# ARGB1555** (`bpp=16`, masks R=0x7C00 G=0x03E0 B=0x001F
			# A=0x8000, verified by reading the DDS_PIXELFORMAT of
			# mm_window, mm_alpha, mm_sign_npc and ub_deco_left directly).
			# The old code read them as 3 bytes a pixel and handed Godot a
			# buffer two-thirds the required size -- "Expected Image data
			# size of 140x184x4 = 103040 bytes, got 68692 instead", and
			# every piece of UI chrome silently failed to build.
			#
			# Driving the decode from dwRGBBitCount and the masks handles
			# both, and is what the format actually specifies rather than
			# what our sample set happened to contain. The standard 32-bit
			# BGRA masks go down exactly the same path and produce the same
			# bytes as before.
			var bpp := tex.rgb_bit_count
			if bpp == 0:
				# No masks recorded (an older parse, or a file that declares
				# neither a fourCC nor a pixel layout): fall back to the
				# historical 24/32-bit BGR(A) assumption rather than failing.
				bpp = 32 if pixels.size() >= tex.width * tex.height * 4 else 24
			if bpp % 8 != 0:
				push_error("ddj: uncompressed texture with %d bits per pixel" % bpp)
				return null
			var stride := bpp / 8
			var px_count: int = tex.width * tex.height
			if pixels.size() < px_count * stride:
				push_error("ddj: uncompressed payload is %d bytes, need %d for %dx%d at %d bpp" % [
					pixels.size(), px_count * stride, tex.width, tex.height, bpp
				])
				return null

			var r_mask := tex.r_mask
			var g_mask := tex.g_mask
			var b_mask := tex.b_mask
			var a_mask := tex.a_mask
			if r_mask == 0 and g_mask == 0 and b_mask == 0:
				# The historical assumption, written as masks.
				r_mask = 0x00FF0000
				g_mask = 0x0000FF00
				b_mask = 0x000000FF
				a_mask = 0xFF000000 if stride == 4 else 0

			var r_shift := _mask_shift(r_mask)
			var g_shift := _mask_shift(g_mask)
			var b_shift := _mask_shift(b_mask)
			var a_shift := _mask_shift(a_mask)
			var r_max := r_mask >> r_shift
			var g_max := g_mask >> g_shift
			var b_max := b_mask >> b_shift
			var a_max := a_mask >> a_shift

			var rgba := PackedByteArray()
			rgba.resize(px_count * 4)
			for i in range(px_count):
				var o := i * stride
				var px := 0
				for byte in range(stride):
					px |= pixels[o + byte] << (byte * 8)
				var d := i * 4
				rgba[d] = _scale_channel(px & r_mask, r_shift, r_max)
				rgba[d + 1] = _scale_channel(px & g_mask, g_shift, g_max)
				rgba[d + 2] = _scale_channel(px & b_mask, b_shift, b_max)
				rgba[d + 3] = _scale_channel(px & a_mask, a_shift, a_max) if a_mask != 0 else 255
			image = Image.create_from_data(tex.width, tex.height, false, Image.FORMAT_RGBA8, rgba)
		"q":
			# Round 621. The DDS "FourCC" here is not text: it is the D3DFORMAT
			# number 113 (0x71, 'q'), D3DFMT_A16B16G16R16F -- four 16-bit
			# floats a pixel, R first in memory (the DXGI R16G16B16A16_FLOAT
			# layout). The client's runtime loader (READ, FUN_00b88420 ->
			# FUN_00b87f20) checks "JMXV" and hands the buffer from offset 20
			# to the statically linked D3DXCreateTextureFromFileInMemoryEx with
			# the file's own MipLevels, and D3DX takes a numeric D3DFORMAT in
			# the FourCC slot. 4 retail files use it (MEASURED, round 621:
			# textures\ques1_monster_paper_q_2..5.ddj in Particles.pk2,
			# 128x128, 8 declared mips). Their top level is a clean image in
			# 0..1; their stored mips are not: level 1 of _q_2 holds 15 values
			# down to -512 and every other stored mip of all four is zero
			# (MEASURED, review follow-up). So retail minifies them to black
			# or garbage. This reader takes the top level only and lets Godot
			# build clean mipmaps (OURS: not retail's look when minified).
			# Each channel is clamped to 0..1 and ROUNDED to 8 bits (OURS; a
			# truncating convert biased every channel by up to -1/255).
			var need: int = tex.width * tex.height * 8
			if pixels.size() < need:
				push_error("ddj: A16B16G16R16F payload is %d bytes, need %d" % [pixels.size(), need])
				return null
			var n: int = tex.width * tex.height * 4
			var rgba8 := PackedByteArray()
			rgba8.resize(n)
			for k in range(n):
				rgba8[k] = clampi(roundi(clampf(pixels.decode_half(k * 2), 0.0, 1.0) * 255.0), 0, 255)
			image = Image.create_from_data(tex.width, tex.height, false, Image.FORMAT_RGBA8, rgba8)
		_:
			push_error("ddj: unhandled compression format %s" % tex.four_cc)
			return null

	if image == null:
		push_error("ddj: failed to build Image from decoded pixel data")
		return null
	return image

## Number of trailing zero bits in a channel mask -- how far right to shift
## the masked value to get the raw channel. 0 for an empty mask.
static func _mask_shift(mask: int) -> int:
	if mask == 0:
		return 0
	var shift := 0
	while mask & 1 == 0:
		mask >>= 1
		shift += 1
	return shift

## Scales a masked channel value up to the full 0-255 range. A 5-bit
## channel's 31 has to become 255, not 31, or every 16-bit texture comes out
## almost black; dividing by the channel's own maximum does that for any
## width, including a 1-bit alpha.
static func _scale_channel(masked: int, shift: int, channel_max: int) -> int:
	if channel_max <= 0:
		return 255
	return ((masked >> shift) * 255) / channel_max

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
