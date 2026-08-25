extends SceneTree

## Exercises CpdReader against synthetic compound objects (never real game
## data) matching the 3 real shapes found live-testing real Jangan scenery,
## run headless:
## `godot4 --headless --path client --script res://scripts/cpd/cpd_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _put_u32(b: PackedByteArray, off: int, v: int) -> void:
	b[off] = v & 0xFF
	b[off + 1] = (v >> 8) & 0xFF
	b[off + 2] = (v >> 16) & 0xFF
	b[off + 3] = (v >> 24) & 0xFF

func _put_u16(b: PackedByteArray, off: int, v: int) -> void:
	b[off] = v & 0xFF
	b[off + 1] = (v >> 8) & 0xFF

func _append_u32(buf: PackedByteArray, v: int) -> void:
	var tmp := PackedByteArray()
	tmp.resize(4)
	_put_u32(tmp, 0, v)
	buf.append_array(tmp)

func _append_len_prefixed(buf: PackedByteArray, s: String) -> void:
	var sb := s.to_ascii_buffer()
	_append_u32(buf, sb.size())
	buf.append_array(sb)

## Builds a real-shaped .cpd header (magic + 2 unconfirmed u32 + 20
## reserved bytes + 2 unconfirmed u16, matching every real sample checked)
## followed by a real length-prefixed name string.
func _build_header(name: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(CpdReader.HEADER_LEN)
	var magic := CpdReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_put_u32(buf, 12, 66) # unconfirmed field A
	_put_u32(buf, 16, 70) # unconfirmed field B
	_put_u16(buf, 40, 2) # unconfirmed field C
	_put_u16(buf, 42, 3) # unconfirmed field D
	_append_len_prefixed(buf, name)
	return buf

func _init() -> void:
	# Real st_sand_01.cpd shape: a flat real sub-count (unused by this
	# reader) followed directly by 2 real .bsr path entries.
	var flat := _build_header("st_sand_01")
	_append_u32(flat, 0) # real reserved/unconfirmed field
	_append_u32(flat, 0) # real reserved/unconfirmed field
	_append_u32(flat, 2) # real sub-count (unused by this reader)
	_append_len_prefixed(flat, "res\\nature\\particle\\st_sand01.bsr")
	_append_len_prefixed(flat, "res\\nature\\particle\\st_sand02.bsr")

	var flat_compound := CpdReader.parse(flat)
	_check(flat_compound != null, "parses the real flat-sub-count shape")
	if flat_compound != null:
		_check(flat_compound.name == "st_sand_01", "name matches (got %s)" % flat_compound.name)
		_check(flat_compound.bsr_paths.size() == 2, "2 real .bsr paths (got %d)" % flat_compound.bsr_paths.size())
		if flat_compound.bsr_paths.size() == 2:
			_check(flat_compound.bsr_paths[0] == "res\\nature\\particle\\st_sand01.bsr", "path[0] matches (got %s)" % flat_compound.bsr_paths[0])
			_check(flat_compound.bsr_paths[1] == "res\\nature\\particle\\st_sand02.bsr", "path[1] matches (got %s)" % flat_compound.bsr_paths[1])

	# Real x_mas_tree_b.cpd shape: real unconfirmed fields, a real
	# duplicate entry, and a real unconfirmed count-like field sitting
	# between two entries. The scanning approach must recover all real
	# entries regardless.
	var nested := _build_header("x_mas_tree_b")
	_append_u32(nested, 3) # real unconfirmed field
	_append_u32(nested, 2) # real unconfirmed field
	_append_len_prefixed(nested, "res\\bldg\\common\\event-xmas\\x_mas_tree_b.bsr")
	_append_u32(nested, 8) # real unconfirmed mid-list field
	_append_len_prefixed(nested, "res\\bldg\\common\\event-xmas\\x_mas_tree_b.bsr")
	_append_len_prefixed(nested, "res\\bldg\\common\\event-xmas\\x_mas_tree_bcandle.bsr")
	_append_len_prefixed(nested, "res\\bldg\\common\\event-xmas\\x_mas_tree_bdeco.bsr")

	var nested_compound := CpdReader.parse(nested)
	_check(nested_compound != null, "parses the real nested/duplicate shape")
	if nested_compound != null:
		_check(nested_compound.bsr_paths.size() == 4, "4 real .bsr paths (got %d)" % nested_compound.bsr_paths.size())
		if nested_compound.bsr_paths.size() == 4:
			_check(nested_compound.bsr_paths[0] == nested_compound.bsr_paths[1], "the real duplicate entry survives (got %s / %s)" % [nested_compound.bsr_paths[0], nested_compound.bsr_paths[1]])

	var bad_magic := PackedByteArray()
	bad_magic.resize(CpdReader.HEADER_LEN + 4)
	_check(CpdReader.parse(bad_magic) == null, "rejects bad magic")

	_check(CpdReader.parse(PackedByteArray([1, 2, 3])) == null, "rejects a buffer too small for a header")

	var empty := _build_header("empty")
	var empty_compound := CpdReader.parse(empty)
	_check(empty_compound != null and empty_compound.bsr_paths.size() == 0, "no trailing data yields zero real .bsr paths, not an error")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
