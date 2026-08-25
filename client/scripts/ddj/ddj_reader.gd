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

	return tex

## Builds a Godot Texture2D from a parsed Texture, decoding the pixel data
## according to the embedded DDS pixel format. Returns null (and pushes an
## error) for a compression format not yet handled.
static func to_texture(tex: ParsedTexture) -> ImageTexture:
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
			# Uncompressed. DDS stores pixels as BGR(A) for the standard
			# 0x00ff0000/0x0000ff00/0x000000ff/0xff000000 masks our real
			# samples used; swizzle to Godot's RGBA8.
			var rgba := PackedByteArray()
			rgba.resize(pixels.size())
			var has_alpha := pixels.size() >= tex.width * tex.height * 4
			var stride := 4 if has_alpha else 3
			var px_count := pixels.size() / stride
			rgba.resize(px_count * 4)
			for i in range(px_count):
				var o := i * stride
				var b := pixels[o]
				var g := pixels[o + 1]
				var r := pixels[o + 2]
				var a := pixels[o + 3] if has_alpha else 255
				var d := i * 4
				rgba[d] = r
				rgba[d + 1] = g
				rgba[d + 2] = b
				rgba[d + 3] = a
			image = Image.create_from_data(tex.width, tex.height, false, Image.FORMAT_RGBA8, rgba)
		_:
			push_error("ddj: unhandled compression format %s" % tex.four_cc)
			return null

	if image == null:
		push_error("ddj: failed to build Image from decoded pixel data")
		return null
	return ImageTexture.create_from_image(image)

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
