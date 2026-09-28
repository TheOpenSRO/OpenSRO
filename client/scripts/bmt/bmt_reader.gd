extends RefCounted
class_name BmtReader

## Read-only parser for the .bmt (JMXVBMT) material format.
## See docs/protocol/BMT_FORMAT.md for the on-disk layout. Mirrors
## server/internal/bmt's Go implementation; keep the two in sync if the
## format understanding changes.
##
## Unlike the other JMXV* formats, the whole file (after a 4-byte size
## header) is a standard zlib stream. Godot's PackedByteArray.decompress()
## only speaks raw DEFLATE, not the zlib wrapper, so the 2-byte zlib header
## and 4-byte Adler32 trailer are stripped before decompressing.

const MAGIC := "JMXVBMT 0102"
const MAGIC_LEN := 12
const MAX_NAME_LEN := 256

class Layer:
	var layer_name: String
	var ambient: Color
	var diffuse: Color
	var specular: Color
	var emissive: Color
	## Unconfirmed meaning -- see docs/protocol/BMT_FORMAT.md.
	var power: float
	## The layer's flag word (the name is historical). READ in round 625:
	## the client's material reader (CPrimMtrl FUN_00bf9270) stores it at
	## the runtime material's +0x70, and every draw path of CObjRendererVS
	## hands it to FUN_00c42a60, which sets the render states from it --
	## see ObjectLoader.LAYER_FLAG_ALPHA_TEST / LAYER_FLAG_TWO_SIDED and
	## docs/protocol/BMT_FORMAT.md.
	var unknown: int
	## The seven bytes after the texture path, READ in round 625 from
	## CPrimMtrl FUN_00bf91b0: a uint32 (meaning not read) and three bytes;
	## the third says the path is a full archive path (non-zero) rather
	## than a name beside the .bmt (zero, FUN_00bf9090).
	var texture_word: int
	var texture_bytes: PackedByteArray = PackedByteArray()
	## A bare filename (not a path), e.g. "avatar_m_zombie.ddj" -- resolve
	## against whatever directory this .bmt itself lives in. Empty if this
	## layer has no texture.
	var texture_path: String

class ParsedMaterial:
	var layers: Array[Layer] = []

## Parses a .bmt file's raw bytes. Returns null (and pushes an error) on
## failure.
##
## Two real on-disk variants exist: files from a patch-staging tree
## (patch_upload_temp) are a 4-byte decompressed-size header followed by a
## zlib stream, but real files from a live client Data tree
## (Prim/Mtrl/Char/China/man/*.bmt) are the raw "JMXVBMT 0102" magic at byte
## 0 with no compression at all -- confirmed across 3 real files
## (chinaman_warrior.bmt, chinaman_bogy.bmt, chinaman_monk.bmt). Detect by
## checking for the magic directly before assuming the compressed layout.
static func parse(data: PackedByteArray) -> ParsedMaterial:
	if data.size() >= MAGIC_LEN and data.slice(0, MAGIC_LEN).get_string_from_ascii() == MAGIC:
		return _parse_decompressed(data)

	if data.size() < 4 + 2 + 4:
		push_error("bmt: file too small to contain the size header and a zlib stream")
		return null

	var want_size := _le_u32(data, 0)
	var zlib_stream := data.slice(4)
	# Strip the 2-byte zlib header (CMF/FLG) and 4-byte Adler32 trailer,
	# then inflate with our own decoder -- Godot's built-in
	# PackedByteArray.decompress(..., COMPRESSION_DEFLATE) was confirmed to
	# fail (return 0 bytes) on at least one real, valid zlib stream that a
	# standard library decodes correctly. See inflate.gd.
	var raw_deflate := zlib_stream.slice(2, zlib_stream.size() - 4)
	var dec := Inflate.inflate(raw_deflate)
	if dec.size() != want_size:
		push_error("bmt: decompressed size is %d, want %d (size header)" % [dec.size(), want_size])
		return null

	return _parse_decompressed(dec)

static func _parse_decompressed(dec: PackedByteArray) -> ParsedMaterial:
	if dec.size() < MAGIC_LEN + 4:
		push_error("bmt: decompressed data too small to contain a header")
		return null
	var magic := dec.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("bmt: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var count := _le_u32(dec, MAGIC_LEN)
	var off := MAGIC_LEN + 4

	var m := ParsedMaterial.new()
	for i in range(count):
		var result = _parse_layer(dec, off)
		if result == null:
			if i == 0:
				push_error("bmt: reading layer 1/%d" % count)
				return null
			break
		var layer: Layer = result[0]
		off = result[1]
		m.layers.append(layer)

		if i + 1 < count:
			# READ (round 625): the layer ends with a uint32 and three bytes
			# after its texture path (FUN_00bf91b0), so the next name starts
			# LAYER_TRAILER_BYTES on. The forward scan is kept only for a
			# file where that does not land on a plausible name.
			var next := off + LAYER_TRAILER_BYTES
			if not _name_at(dec, next):
				next = _scan_for_name_string(dec, off)
			if next < 0:
				break
			off = next

	return m

static func _parse_layer(dec: PackedByteArray, off: int):
	var name_result = _read_len_prefixed_string(dec, off)
	if name_result == null:
		return null
	var l := Layer.new()
	l.layer_name = name_result[0]
	off = name_result[1]

	if off + 64 + 4 + 4 > dec.size():
		return null
	l.ambient = _read_color(dec, off)
	l.diffuse = _read_color(dec, off + 16)
	l.specular = _read_color(dec, off + 32)
	l.emissive = _read_color(dec, off + 48)
	off += 64
	l.power = _le_f32(dec, off)
	off += 4
	l.unknown = _le_u32(dec, off)
	off += 4

	var tex_result = _read_len_prefixed_string(dec, off)
	if tex_result == null:
		return null
	# The declared length includes trailing NUL padding in at least one
	# real file checked -- trim it.
	l.texture_path = (tex_result[0] as String).rstrip(char(0))
	off = tex_result[1]
	if off + LAYER_TRAILER_BYTES <= dec.size():
		l.texture_word = _le_u32(dec, off)
		l.texture_bytes = dec.slice(off + 4, off + LAYER_TRAILER_BYTES)

	return [l, off]

## Bytes after a layer's texture path: a uint32 and three bytes (READ,
## CPrimMtrl FUN_00bf91b0).
const LAYER_TRAILER_BYTES := 7

static func _name_at(data: PackedByteArray, pos: int) -> bool:
	if pos < 0 or pos + 4 > data.size():
		return false
	var n := _le_u32(data, pos)
	return n > 0 and n <= MAX_NAME_LEN and pos + 4 + n <= data.size() \
		and _is_plausible_name(data.slice(pos + 4, pos + 4 + n))

static func _scan_for_name_string(data: PackedByteArray, off: int) -> int:
	var pos := off
	while pos + 4 <= data.size():
		var n := _le_u32(data, pos)
		if n > 0 and n <= MAX_NAME_LEN and pos + 4 + n <= data.size():
			if _is_plausible_name(data.slice(pos + 4, pos + 4 + n)):
				return pos
		pos += 1
	return -1

static func _is_plausible_name(b: PackedByteArray) -> bool:
	if b.size() == 0:
		return false
	for c in b:
		var is_alnum := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
		var is_extra := c == 95 or c == 45 or c == 32 or c == 46 or c == 35 # _ - space . #
		if not (is_alnum or is_extra):
			return false
	return true

static func _read_len_prefixed_string(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n < 0 or off + n > data.size():
		return null
	return [data.slice(off, off + n).get_string_from_ascii(), off + n]

static func _read_color(b: PackedByteArray, off: int) -> Color:
	return Color(_le_f32(b, off), _le_f32(b, off + 4), _le_f32(b, off + 8), _le_f32(b, off + 12))

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

static func _le_f32(b: PackedByteArray, off: int) -> float:
	return b.slice(off, off + 4).decode_float(0)
