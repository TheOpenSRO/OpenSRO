extends RefCounted
class_name MapTReader

## Read-only parser for the .t (JMXVMAPT) map-region terrain lighting/
## shadow format. See docs/protocol/MAPT_FORMAT.md for the on-disk layout
## and the public-documentation citation this is verified against.
##
## Structure: a 12-byte header (magic + version), a real fixed 9,216-byte
## ("96x96") ShadowMap, a real TextureLength/TextureType uint32 pair, then
## a real, complete, standard embedded DDS file (TextureLength-8 bytes) --
## a genuine grayscale lightmap, per public documentation and this
## project's own visual verification (see MAPT_FORMAT.md). Only DXT1-
## compressed DDS payloads are decoded (the only real FourCC seen in the
## one real sample checked); any other FourCC is treated as an honest
## decode failure (texture left null) rather than guessed at.
##
## .t exists alongside .m/.o/.o2 only for newer-generation ("Shape B")
## regions -- see docs/protocol/MAPM_FORMAT.md's real per-vertex record
## size split.

const MAGIC := "JMXVMAPT"
const MAGIC_LEN := 8
const VERSION_LEN := 4
const HEADER_LEN := MAGIC_LEN + VERSION_LEN # 12
const SHADOW_MAP_SIDE := 96
const SHADOW_MAP_LEN := SHADOW_MAP_SIDE * SHADOW_MAP_SIDE # 9216
const LENGTH_FIELDS_LEN := 4 + 4 # TextureLength(uint32) + TextureType(uint32)

const DDS_MAGIC := "DDS "
const DDS_HEADER_LEN := 4 + 124 # magic + DDS_HEADER struct
const DDS_PIXELFORMAT_OFF := 72 # relative to the DDS_HEADER start (offset 4 in the file)
const DXT1_FOURCC := "DXT1"

class ParsedRegion:
	## The 4-byte tag after the magic, e.g. "1001".
	var version: String
	## The real, raw 9,216-byte ShadowMap -- per public documentation, "a
	## simplified map used to check if an object is inside shadow." Not
	## independently decoded byte-by-byte; kept raw.
	var shadow_map: PackedByteArray
	## The real embedded lightmap texture, decoded from the file's real
	## embedded DDS -- null if the embedded DDS's pixel format isn't the
	## one real, confirmed FourCC (DXT1) this reader supports, or if
	## decoding otherwise fails.
	var texture: Texture2D
	## The same lightmap as a decompressed Image, set instead of `texture`
	## when parse() is asked for no texture (round 565): an Image owns no
	## RenderingServer RID, so World3D's WorkerThreadPool task reads a
	## region's `.t` this way and the main thread uploads it.
	var image: Image

## Parses a .t file's raw bytes. Returns null (and pushes an error) on a
## structural failure (bad magic, too small, TextureLength not matching
## the real remaining bytes) -- a failure to decode the embedded DDS
## itself is not fatal (texture is left null, matching the real "this
## region has no confirmed real ground detail" case elsewhere in this
## project).
## `with_texture` false (round 565) decodes the lightmap into `image` and
## leaves `texture` null, building nothing that owns an RID -- for a caller
## off the main thread. The Image is the one `texture` is uploaded from.
static func parse(data: PackedByteArray, with_texture: bool = true) -> ParsedRegion:
	var _pp := ParseProfile.t0()
	var _out: ParsedRegion = _pp_parse(data, with_texture)
	ParseProfile.add("mapt.parse", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray, with_texture: bool = true) -> ParsedRegion:
	if data.size() < HEADER_LEN + SHADOW_MAP_LEN + LENGTH_FIELDS_LEN:
		push_error("mapt: file too small to contain a header, shadow map, and texture-length fields")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("mapt: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var r := ParsedRegion.new()
	r.version = data.slice(MAGIC_LEN, HEADER_LEN).get_string_from_ascii()

	var off := HEADER_LEN
	r.shadow_map = data.slice(off, off + SHADOW_MAP_LEN)
	off += SHADOW_MAP_LEN

	var texture_length := data.decode_u32(off)
	off += LENGTH_FIELDS_LEN

	var dds_len := texture_length - 8 # TextureLength counts itself + TextureType
	if dds_len < 0 or off + dds_len != data.size():
		push_error("mapt: TextureLength implies %d embedded texture bytes, but %d remain in the file" % [dds_len, data.size() - off])
		return null

	var image := _decode_dds_image(data.slice(off, off + dds_len))
	if with_texture:
		r.texture = ImageTexture.create_from_image(image) if image != null else null
	else:
		r.image = image
	return r

## Decodes a real, complete, standard DDS file's DXT1 payload into a
## decompressed Image (an ImageTexture of it until round 565; parse()
## uploads it when asked for the texture). Returns null (no error pushed -- an honest, expected
## "couldn't decode this one" outcome, not a structural parse failure) if
## the DDS is too small, isn't really a DDS, or isn't DXT1-compressed.
static func _decode_dds_image(dds: PackedByteArray) -> Image:
	if dds.size() < DDS_HEADER_LEN:
		return null
	if dds.slice(0, 4).get_string_from_ascii() != DDS_MAGIC:
		return null

	var height := dds.decode_u32(4 + 8)
	var width := dds.decode_u32(4 + 12)
	var fourcc := dds.slice(4 + DDS_PIXELFORMAT_OFF + 8, 4 + DDS_PIXELFORMAT_OFF + 12).get_string_from_ascii()
	if fourcc != DXT1_FOURCC:
		return null

	var payload_len := (width / 4) * (height / 4) * 8
	if dds.size() < DDS_HEADER_LEN + payload_len:
		return null
	var payload := dds.slice(DDS_HEADER_LEN, DDS_HEADER_LEN + payload_len)

	var img := Image.create_from_data(width, height, false, Image.FORMAT_DXT1, payload)
	if img == null:
		return null
	img.decompress()
	return img
