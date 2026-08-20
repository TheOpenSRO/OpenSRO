extends SceneTree

## Exercises MapoReader against a synthetic map region (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/mapo/mapo_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _append_u32(buf: PackedByteArray, v: int) -> PackedByteArray:
	var lp := PackedByteArray()
	lp.resize(4)
	lp[0] = v & 0xFF
	lp[1] = (v >> 8) & 0xFF
	lp[2] = (v >> 16) & 0xFF
	lp[3] = (v >> 24) & 0xFF
	var out := buf.duplicate()
	out.append_array(lp)
	return out

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

func _build_region() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(MapoReader.MAGIC.to_ascii_buffer())
	buf.append_array("1001".to_ascii_buffer())
	buf = _append_u32(buf, 0) # unconfirmed header field
	buf = _append_u32(buf, 0) # unconfirmed header field

	# Object 1: no trailing bytes beyond the fixed 28, immediately
	# followed by object 2.
	buf = _append_u32(buf, 1805)
	buf = _append_float32(buf, 287.14)
	buf = _append_float32(buf, 219.43)
	buf = _append_float32(buf, 157.65)
	buf = _append_zeros(buf, 12) # unconfirmed fixed 12 bytes

	# Object 2: a real trailing block (zero padding + a small nonzero
	# tail value, matching the shape seen in every real file checked)
	# before object 3 starts.
	buf = _append_u32(buf, 1159)
	buf = _append_float32(buf, 414.19)
	buf = _append_float32(buf, 183.37)
	buf = _append_float32(buf, 318.94)
	buf = _append_zeros(buf, 12) # unconfirmed fixed 12 bytes
	buf = _append_zeros(buf, 4)
	buf.append_array(PackedByteArray([3, 0])) # trailing block tail value

	# Object 3: the last object, no trailer, end of file right after.
	buf = _append_u32(buf, 1798)
	buf = _append_float32(buf, 471.84)
	buf = _append_float32(buf, 206.89)
	buf = _append_float32(buf, 40.23)
	buf = _append_zeros(buf, 12) # unconfirmed fixed 12 bytes

	return buf

func _init() -> void:
	var data := _build_region()

	var r := MapoReader.parse(data)
	_check(r != null, "parses synthetic region")
	if r != null:
		_check(r.version == "1001", "version matches (got %s)" % r.version)
		_check(r.objects.size() == 3, "3 objects (got %d)" % r.objects.size())
		if r.objects.size() == 3:
			_check(r.objects[0].type_id == 1805 and r.objects[0].extra.is_empty(), "object 1 matches")
			_check(r.objects[0].position.is_equal_approx(Vector3(287.14, 219.43, 157.65)), "object 1 position matches")
			_check(r.objects[1].type_id == 1159 and r.objects[1].extra.size() == 6, "object 2 matches (extra=%d)" % r.objects[1].extra.size())
			_check(r.objects[2].type_id == 1798 and r.objects[2].extra.is_empty(), "object 3 matches")

	var empty_region := PackedByteArray()
	empty_region.append_array(MapoReader.MAGIC.to_ascii_buffer())
	empty_region.append_array("1000".to_ascii_buffer())
	empty_region = _append_zeros(empty_region, 200)
	var empty_result := MapoReader.parse(empty_region)
	_check(empty_result != null and empty_result.objects.is_empty(), "all-zero region parses with 0 objects")

	# A real, confirmed complication: some real files have an 18-byte
	# header (2 bytes narrower than the usual 20) before the first record
	# -- found via cross-checking against additional real samples beyond
	# the one this format was originally cracked against. See
	# docs/protocol/MAPO_FORMAT.md.
	var narrow_buf := PackedByteArray()
	narrow_buf.append_array(MapoReader.MAGIC.to_ascii_buffer())
	narrow_buf.append_array("1001".to_ascii_buffer())
	narrow_buf = _append_u32(narrow_buf, 0) # unconfirmed header field, only 4 bytes here (not 8)
	narrow_buf = _append_u32(narrow_buf, 1489)
	narrow_buf = _append_float32(narrow_buf, 56.8)
	narrow_buf = _append_float32(narrow_buf, 167.0)
	narrow_buf = _append_float32(narrow_buf, 22.98)
	narrow_buf = _append_zeros(narrow_buf, 12)
	var narrow_result := MapoReader.parse(narrow_buf)
	_check(narrow_result != null and narrow_result.objects.size() == 1 and narrow_result.objects[0].type_id == 1489,
		"recovers an object past a narrower header")

	var bad_magic := PackedByteArray()
	bad_magic.resize(MapoReader.MIN_HEADER_LEN + 10)
	_check(MapoReader.parse(bad_magic) == null, "rejects bad magic")

	var truncated := PackedByteArray()
	truncated.resize(MapoReader.MIN_HEADER_LEN - 1)
	_check(MapoReader.parse(truncated) == null, "rejects truncated buffer")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
