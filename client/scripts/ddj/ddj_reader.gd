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
	var pixels := tex.dds.slice(4 + DDS_HEADER_SIZE)
	var image: Image

	match tex.four_cc:
		"DXT1":
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
