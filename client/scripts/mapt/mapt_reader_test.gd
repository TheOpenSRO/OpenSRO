extends SceneTree

## Exercises MapTReader against a synthetic .t file with a real-shaped
## embedded DDS (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/mapt/mapt_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _append_u32(buf: PackedByteArray, v: int) -> PackedByteArray:
	var out := buf.duplicate()
	for i in range(4):
		out.append((v >> (8 * i)) & 0xff)
	return out

func _append_zeros(buf: PackedByteArray, n: int) -> PackedByteArray:
	var out := buf.duplicate()
	for _i in range(n):
		out.append(0)
	return out

## Builds a real-shaped, minimal standard DDS file: magic + a real 124-byte
## DDS_HEADER (only the fields this reader actually uses are set to real
## values; the rest are zeroed, which is not how a real file would look
## but doesn't matter for what's being tested) + a DXT1 payload of
## fill_byte repeated.
func _build_dds_precise(width: int, height: int, fill_byte: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(128)
	buf.fill(0)
	buf[0] = 0x44 # 'D'
	buf[1] = 0x44 # 'D'
	buf[2] = 0x53 # 'S'
	buf[3] = 0x20 # ' '
	buf.encode_u32(4, 124) # dwSize
	buf.encode_u32(4 + 8, height)
	buf.encode_u32(4 + 12, width)
	buf.encode_u32(4 + 72, 32) # pixelformat dwSize
	buf.encode_u32(4 + 72 + 4, 0x4) # DDPF_FOURCC
	buf[4 + 72 + 8] = 0x44 # 'D'
	buf[4 + 72 + 9] = 0x58 # 'X'
	buf[4 + 72 + 10] = 0x54 # 'T'
	buf[4 + 72 + 11] = 0x31 # '1'

	var payload_len := (width / 4) * (height / 4) * 8
	var payload := PackedByteArray()
	payload.resize(payload_len)
	payload.fill(fill_byte)
	buf.append_array(payload)
	return buf

func _build_region(width: int, height: int, fill_byte: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(MapTReader.MAGIC.to_ascii_buffer())
	buf.append_array("1001".to_ascii_buffer())
	buf = _append_zeros(buf, MapTReader.SHADOW_MAP_LEN)
	var dds := _build_dds_precise(width, height, fill_byte)
	buf = _append_u32(buf, dds.size() + 8) # TextureLength counts itself + TextureType
	buf = _append_u32(buf, 3) # TextureType (D3DRTYPE_TEXTURE)
	buf.append_array(dds)
	return buf

func _init() -> void:
	var data := _build_region(8, 8, 0x00)
	var r := MapTReader.parse(data)
	_check(r != null, "parses a synthetic region with a real-shaped embedded DDS")
	if r != null:
		_check(r.version == "1001", "version matches (got %s)" % r.version)
		_check(r.shadow_map.size() == MapTReader.SHADOW_MAP_LEN, "shadow map is the real 9216-byte size (got %d)" % r.shadow_map.size())
		_check(r.texture != null, "decodes the embedded DXT1 texture")
		if r.texture != null:
			_check(r.texture.get_width() == 8 and r.texture.get_height() == 8, "decoded texture has the real declared dimensions (got %dx%d)" % [r.texture.get_width(), r.texture.get_height()])

	# An unrecognized FourCC (not DXT1) is an honest, non-fatal decode
	# failure -- the region itself still parses, texture is just null.
	var bad_fourcc_dds := _build_dds_precise(8, 8, 0)
	bad_fourcc_dds[4 + 72 + 8] = 0x58 # corrupt "DXT1" -> "XXT1"
	var buf2 := PackedByteArray()
	buf2.append_array(MapTReader.MAGIC.to_ascii_buffer())
	buf2.append_array("1001".to_ascii_buffer())
	buf2 = _append_zeros(buf2, MapTReader.SHADOW_MAP_LEN)
	buf2 = _append_u32(buf2, bad_fourcc_dds.size() + 8)
	buf2 = _append_u32(buf2, 3)
	buf2.append_array(bad_fourcc_dds)
	var r2 := MapTReader.parse(buf2)
	_check(r2 != null, "still parses the region even when the embedded texture's format isn't recognized")
	if r2 != null:
		_check(r2.texture == null, "unrecognized FourCC leaves texture null rather than guessing")

	var bad_magic := PackedByteArray()
	bad_magic.resize(MapTReader.HEADER_LEN + MapTReader.SHADOW_MAP_LEN + 20)
	_check(MapTReader.parse(bad_magic) == null, "rejects bad magic")

	var too_small := PackedByteArray()
	too_small.resize(MapTReader.HEADER_LEN - 1)
	_check(MapTReader.parse(too_small) == null, "rejects a buffer too small for a header")

	# A TextureLength that doesn't match the real remaining bytes is a
	# real structural error, not something to silently truncate/pad past.
	var mismatched := _build_region(8, 8, 0)
	mismatched = mismatched.slice(0, mismatched.size() - 10) # truncate the embedded DDS
	_check(MapTReader.parse(mismatched) == null, "rejects a TextureLength that doesn't match the real remaining bytes")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
