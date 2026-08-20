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

func _append_zeros(buf: PackedByteArray, n: int) -> PackedByteArray:
	var pad := PackedByteArray()
	pad.resize(n)
	var out := buf.duplicate()
	out.append_array(pad)
	return out

func _repeat_heights(v: float, n: int) -> Array:
	var out := []
	out.resize(n)
	out.fill(v)
	return out

## Builds a synthetic region using SHAPE_A (11-byte tiles), the layout
## confirmed against the larger (~136-137KB) real file size class. Repeats
## enough tiles for the shape/offset detector to confidently distinguish
## this from SHAPE_B or header padding.
func _build_region_shape_a(heights: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(MapmReader.MAGIC.to_ascii_buffer())
	buf.append_array("1000".to_ascii_buffer())
	buf = _append_zeros(buf, 12) # unconfirmed header bytes
	for h in heights:
		buf.append_array(PackedByteArray([97, 0, 0, 0xff, 0xff]))
		buf = _append_float32(buf, h)
		buf.append_array(PackedByteArray([0, 0]))
	return buf

func _build_region_shape_b(heights: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(MapmReader.MAGIC.to_ascii_buffer())
	buf.append_array("1000".to_ascii_buffer())
	buf = _append_zeros(buf, 12) # unconfirmed header bytes
	for h in heights:
		buf.append_array(PackedByteArray([5, 200]))
		buf = _append_float32(buf, h)
		buf.append_array(PackedByteArray([1]))
	return buf

func _init() -> void:
	var run_len: int = MapmReader.DETECT_RUN_LEN

	# Shape A.
	var heights_a := _repeat_heights(11.08, run_len + 2)
	heights_a.append(12.61)
	var data_a := _build_region_shape_a(heights_a)
	var r_a := MapmReader.parse(data_a)
	_check(r_a != null, "parses synthetic shape-A region")
	if r_a != null:
		_check(r_a.version == "1000", "version matches (got %s)" % r_a.version)
		# >= rather than == -- the all-zero header bytes right before the
		# real data can themselves look like one harmless leading
		# all-zero tile to the shape/offset detector (a zero height
		# always passes the sanity check) -- confirmed to happen on real
		# files too (see docs/protocol/MAPM_FORMAT.md).
		_check(r_a.tiles.size() >= heights_a.size(), "at least %d shape-A tiles (got %d)" % [heights_a.size(), r_a.tiles.size()])
		if r_a.tiles.size() >= heights_a.size():
			_check(r_a.tiles[r_a.tiles.size() - 2].extra.size() == 7, "shape-A extra length matches")
			var last_a: MapmReader.Tile = r_a.tiles[r_a.tiles.size() - 1]
			_check(absf(last_a.height - 12.61) < 0.01, "shape-A last tile height matches")

	# Shape B.
	var heights_b := _repeat_heights(19.66, run_len + 2)
	heights_b.append(18.28)
	var data_b := _build_region_shape_b(heights_b)
	var r_b := MapmReader.parse(data_b)
	_check(r_b != null, "parses synthetic shape-B region")
	if r_b != null:
		_check(r_b.tiles.size() >= heights_b.size(), "at least %d shape-B tiles (got %d)" % [heights_b.size(), r_b.tiles.size()])
		if r_b.tiles.size() >= heights_b.size():
			_check(r_b.tiles[r_b.tiles.size() - 2].extra.size() == 3, "shape-B extra length matches")
			var last_b: MapmReader.Tile = r_b.tiles[r_b.tiles.size() - 1]
			_check(absf(last_b.height - 18.28) < 0.01, "shape-B last tile height matches")

	# Resync path: a single unreadable byte the fixed-stride read can't
	# skip past on its own.
	var heights_gap := _repeat_heights(11.08, run_len + 2)
	var gap_buf := _build_region_shape_a(heights_gap)
	var gap_start := gap_buf.size()
	gap_buf.append_array(PackedByteArray([0x44]))
	var tile2_start := gap_buf.size()
	gap_buf.append_array(PackedByteArray([97, 0, 0, 0xff, 0xff]))
	gap_buf = _append_float32(gap_buf, 12.61)
	gap_buf.append_array(PackedByteArray([0, 0]))

	var fixture_ok := true
	for off in range(gap_start, tile2_start):
		if MapmReader._looks_like_tile(gap_buf, off, MapmReader.SHAPE_A):
			fixture_ok = false
	_check(fixture_ok, "fixture bug guard: gap byte doesn't coincidentally look like a tile")

	var gap_result := MapmReader.parse(gap_buf)
	_check(gap_result != null and gap_result.tiles.size() >= heights_gap.size() + 1, "resync recovers past an unreadable gap byte")
	if gap_result != null and gap_result.tiles.size() >= heights_gap.size() + 1:
		var last_gap: MapmReader.Tile = gap_result.tiles[gap_result.tiles.size() - 1]
		_check(absf(last_gap.height - 12.61) < 0.01, "resynced last tile height matches")

	var bad_magic := PackedByteArray()
	bad_magic.resize(MapmReader.MIN_HEADER_LEN + 10)
	_check(MapmReader.parse(bad_magic) == null, "rejects bad magic")

	var truncated := PackedByteArray()
	truncated.resize(MapmReader.MIN_HEADER_LEN - 1)
	_check(MapmReader.parse(truncated) == null, "rejects truncated buffer")

	var no_room := PackedByteArray()
	no_room.append_array(MapmReader.MAGIC.to_ascii_buffer())
	no_room.append_array("1000".to_ascii_buffer())
	_check(MapmReader.parse(no_room) == null, "rejects a region with no room for tile data")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
