extends SceneTree

## Exercises MapmReader against synthetic terrain regions (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/mapm/mapm_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _append_float32(buf: PackedByteArray, v: float) -> PackedByteArray:
	var fb := PackedByteArray()
	fb.resize(4)
	fb.encode_float(0, v)
	var out := buf.duplicate()
	out.append_array(fb)
	return out

func _append_u16(buf: PackedByteArray, v: int) -> PackedByteArray:
	var out := buf.duplicate()
	out.append(v & 0xff)
	out.append((v >> 8) & 0xff)
	return out

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

## Builds one real-shaped block: header, VERTEX_COUNT vertices (each
## height_fn(v) plus vertex_len-4 filler bytes), plane info, the
## tile-flag grid, height info, and reserved_len trailing bytes -- the
## exact real structure confirmed in docs/protocol/MAPM_FORMAT.md.
func _build_block(buf: PackedByteArray, vertex_len: int, reserved_len: int, height_fn: Callable) -> PackedByteArray:
	buf = _append_u32(buf, 0) # Flag
	buf = _append_u16(buf, 0) # EnvironmentID
	for v in range(MapmReader.VERTEX_COUNT):
		buf = _append_float32(buf, height_fn.call(v))
		buf = _append_zeros(buf, vertex_len - 4)
	buf.append(0xff) # PlaneType = -1 (Normal)
	buf.append(0) # WaveID
	buf = _append_float32(buf, 0.0) # PlaneHeight
	buf = _append_zeros(buf, MapmReader.TILE_FLAG_LEN)
	buf = _append_float32(buf, 0.0) # HeightMax
	buf = _append_float32(buf, 0.0) # HeightMin
	buf = _append_zeros(buf, reserved_len)
	return buf

## Builds a full, real-shaped region: BLOCK_COUNT (36) blocks in real
## nested order. height_fn is called with (block_index, vertex_index) so
## tests can make specific vertices distinguishable.
func _build_region(vertex_len: int, reserved_len: int, height_fn: Callable) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(MapmReader.MAGIC.to_ascii_buffer())
	buf.append_array("1000".to_ascii_buffer())
	for b in range(MapmReader.BLOCK_COUNT):
		buf = _build_block(buf, vertex_len, reserved_len, func(v): return height_fn.call(b, v))
	return buf

func _init() -> void:
	# vertex_len=7 (real ~92KB file-size class).
	var data7 := _build_region(MapmReader.VERTEX_LEN_7, MapmReader.RESERVED_LEN_7, func(block, v):
		return 182.67 if block == 0 and v == 5 else 0.0)
	var r7 := MapmReader.parse(data7)
	_check(r7 != null, "parses a full synthetic vertex_len=7 region")
	if r7 != null:
		_check(r7.version == "1000", "version matches (got %s)" % r7.version)
		_check(r7.blocks.size() == MapmReader.BLOCK_COUNT, "36 blocks (got %d)" % r7.blocks.size())
		var v5: MapmReader.Vertex = r7.blocks[0].vertices[5]
		_check(absf(v5.height - 182.67) < 0.01, "block 0 vertex 5 height matches (got %s)" % v5.height)
		_check(v5.extra.size() == MapmReader.VERTEX_LEN_7 - 4, "extra length matches (got %d)" % v5.extra.size())

	# vertex_len=11 (real ~136-137KB file-size class).
	var last_v := MapmReader.VERTEX_COUNT - 1
	var data11 := _build_region(MapmReader.VERTEX_LEN_11, MapmReader.RESERVED_LEN_11, func(block, v):
		return 11.08 if block == 35 and v == last_v else 0.0)
	var r11 := MapmReader.parse(data11)
	_check(r11 != null, "parses a full synthetic vertex_len=11 region")
	if r11 != null:
		_check(r11.blocks.size() == MapmReader.BLOCK_COUNT, "36 blocks (got %d)" % r11.blocks.size())
		var last: MapmReader.Vertex = r11.blocks[35].vertices[last_v]
		_check(absf(last.height - 11.08) < 0.01, "last vertex height matches (got %s)" % last.height)
		_check(last.extra.size() == MapmReader.VERTEX_LEN_11 - 4, "extra length matches (got %d)" % last.extra.size())

	# Block-level fields (Flag, EnvironmentID, PlaneType, WaveID,
	# HeightMax/Min) round-trip correctly.
	var buf := PackedByteArray()
	buf.append_array(MapmReader.MAGIC.to_ascii_buffer())
	buf.append_array("1000".to_ascii_buffer())
	for b in range(MapmReader.BLOCK_COUNT):
		var flag := 1 if b == 3 else 0
		var env_id := 42 if b == 3 else 0
		buf = _append_u32(buf, flag)
		buf = _append_u16(buf, env_id)
		for _v in range(MapmReader.VERTEX_COUNT):
			buf = _append_float32(buf, 0.0)
			buf = _append_zeros(buf, MapmReader.VERTEX_LEN_7 - 4)
		buf.append(1 if b == 3 else 0xff) # PlaneType: Ice for block 3, else Normal
		buf.append(7) # WaveID
		buf = _append_float32(buf, 12.5)
		buf = _append_zeros(buf, MapmReader.TILE_FLAG_LEN)
		buf = _append_float32(buf, 200.0) # HeightMax
		buf = _append_float32(buf, -5.0) # HeightMin
		buf = _append_zeros(buf, MapmReader.RESERVED_LEN_7)
	var r_fields := MapmReader.parse(buf)
	_check(r_fields != null, "parses the block-fields fixture")
	if r_fields != null:
		var block3: MapmReader.Block = r_fields.blocks[3]
		_check(block3.flag == 1, "Flag matches (got %d)" % block3.flag)
		_check(block3.environment_id == 42, "EnvironmentID matches (got %d)" % block3.environment_id)
		_check(block3.plane_type == 1, "PlaneType matches (got %d)" % block3.plane_type)
		_check(block3.wave_id == 7, "WaveID matches (got %d)" % block3.wave_id)
		_check(block3.height_max == 200.0 and block3.height_min == -5.0, "HeightMax/Min match")

	var bad_magic := PackedByteArray()
	bad_magic.resize(MapmReader.HEADER_LEN + 10)
	_check(MapmReader.parse(bad_magic) == null, "rejects bad magic")

	var too_small := PackedByteArray()
	too_small.resize(MapmReader.HEADER_LEN - 1)
	_check(MapmReader.parse(too_small) == null, "rejects a buffer too small for a header")

	var unrecognized := PackedByteArray()
	unrecognized.append_array(MapmReader.MAGIC.to_ascii_buffer())
	unrecognized.append_array("1000".to_ascii_buffer())
	unrecognized = _append_zeros(unrecognized, 100) # not a real block size at all
	_check(MapmReader.parse(unrecognized) == null, "rejects a region with an unrecognized body size")

	var truncated_mid_block := data7.slice(0, data7.size() - 5)
	_check(MapmReader.parse(truncated_mid_block) == null, "rejects a region truncated mid-block")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
