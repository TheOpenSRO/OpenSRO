extends SceneTree

## Exercises MapO2Reader against synthetic data shaped like a real .o2 file
## (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/mapo/mapo2_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _append_u16(buf: PackedByteArray, v: int) -> PackedByteArray:
	var out := buf.duplicate()
	out.append(v & 0xFF)
	out.append((v >> 8) & 0xFF)
	return out

func _append_u32(buf: PackedByteArray, v: int) -> PackedByteArray:
	var out := buf.duplicate()
	for i in range(4):
		out.append((v >> (8 * i)) & 0xFF)
	return out

func _append_float32(buf: PackedByteArray, v: float) -> PackedByteArray:
	var fb := PackedByteArray()
	fb.resize(4)
	fb.encode_float(0, v)
	var out := buf.duplicate()
	out.append_array(fb)
	return out

func _append_zeros(buf: PackedByteArray, n: int) -> PackedByteArray:
	var out := buf.duplicate()
	for _i in range(n):
		out.append(0)
	return out

## Builds one real-shaped 30-byte entry: type_id (u32) + position (3x
## float32) + the real, confirmed trailer shape (0xffff sentinel, 2 zero
## u16s, the real 1-based index at relative offset 22, a zero u32, and the
## constant 0x6464 tail) -- see docs/protocol/MAPO2_FORMAT.md.
func _make_entry(buf: PackedByteArray, type_id: int, pos: Vector3, index: int) -> PackedByteArray:
	var out := _append_u32(buf, type_id)
	out = _append_float32(out, pos.x)
	out = _append_float32(out, pos.y)
	out = _append_float32(out, pos.z)
	out = _append_u16(out, 0xffff)
	out = _append_u16(out, 0)
	out = _append_u16(out, 0)
	out = _append_u16(out, index)
	out = _append_u32(out, 0)
	out = _append_u16(out, 0x6464)
	return out

func _empty_sector(buf: PackedByteArray) -> PackedByteArray:
	var out := buf.duplicate()
	for _field_idx in range(MapO2Reader.FIELDS_PER_SECTOR):
		out = _append_u16(out, 0)
	return out

func _init() -> void:
	# A full, real-shaped 6x6 region: every sector empty except sector
	# (0,0), which gets a nonzero, discarded field-0 entry (real, confirmed
	# to exist in the raw file but never stored by the real client -- see
	# MAPO2_FORMAT.md) plus 3 real-shaped entries in field 3 (exposed as
	# lists[2]) -- matching this project's own real empirical find against
	# 100/100.o2 exactly (same type ID, same positions, same sequential
	# indices, and the same "only the last field is ever populated"
	# pattern that sample showed).
	var buf := PackedByteArray()
	buf.append_array(MapO2Reader.MAGIC.to_ascii_buffer())
	buf.append_array("1001".to_ascii_buffer())

	for band_row in range(MapO2Reader.SECTORS_PER_SIDE):
		for band_col in range(MapO2Reader.SECTORS_PER_SIDE):
			if band_row == 0 and band_col == 0:
				buf = _append_u16(buf, 1) # field 0: 1 entry, discarded
				buf = _make_entry(buf, 9999, Vector3(1, 2, 3), 1)
				buf = _append_u16(buf, 0) # field 1 (-> lists[0]): empty
				buf = _append_u16(buf, 0) # field 2 (-> lists[1]): empty
				buf = _append_u16(buf, 3) # field 3 (-> lists[2]): 3 entries
				buf = _make_entry(buf, 1489, Vector3(56.81, 167.02, 22.98), 1)
				buf = _make_entry(buf, 1489, Vector3(128.47, 167.25, 179.25), 2)
				buf = _make_entry(buf, 1489, Vector3(210.54, 167.25, 119.00), 3)
			else:
				buf = _empty_sector(buf)

	var r := MapO2Reader.parse(buf)
	_check(r != null, "parses a full synthetic 6x6 region")
	if r != null:
		_check(r.version == "1001", "version matches (got %s)" % r.version)
		_check(r.sectors.size() == MapO2Reader.SECTORS_PER_SIDE * MapO2Reader.SECTORS_PER_SIDE,
			"36 real sectors recovered (got %d)" % r.sectors.size())

		var sector00: MapO2Reader.Sector = r.sectors[0]
		_check(sector00.lists[0].is_empty(), "sector (0,0) field 1 (lists[0]) is empty")
		_check(sector00.lists[1].is_empty(), "sector (0,0) field 2 (lists[1]) is empty")
		_check(sector00.lists[2].size() == 3, "sector (0,0) field 3 (lists[2]) has 3 entries (got %d)" % sector00.lists[2].size())
		var field0_leaked := false
		for l in sector00.lists:
			for e in l:
				if e.type_id == 9999:
					field0_leaked = true
		_check(not field0_leaked, "field 0's discarded entry (type 9999) never appears in an exposed list")
		if sector00.lists[2].size() == 3:
			var e0: MapO2Reader.Entry = sector00.lists[2][0]
			_check(e0.type_id == 1489, "entry 0 type ID matches (got %d)" % e0.type_id)
			_check(e0.position.is_equal_approx(Vector3(56.81, 167.02, 22.98)), "entry 0 position matches (got %s)" % e0.position)
			_check(e0.index == 1, "entry 0 real sequential index is 1 (got %d)" % e0.index)
			var e2: MapO2Reader.Entry = sector00.lists[2][2]
			_check(e2.index == 3, "entry 2 real sequential index is 3 (got %d)" % e2.index)

		# Every other real sector should be present and genuinely empty --
		# not skipped, not merged into sector (0,0).
		var sector_11: MapO2Reader.Sector = r.sectors[1 * MapO2Reader.SECTORS_PER_SIDE + 1]
		_check(sector_11.lists[0].is_empty() and sector_11.lists[1].is_empty() and sector_11.lists[2].is_empty(),
			"an unrelated sector (1,1) is genuinely empty")

	# A file truncated mid-entry (cuts off partway through sector (0,0)'s
	# field 3) is a real error, not a graceful partial parse -- .o2's
	# layout is fully deterministic (see MAPO2_FORMAT.md), unlike .m's
	# Shape A. Offset: header + field0 (count + 1 entry) + field1 count +
	# field2 count + field3 count + 1 full entry + 5 bytes into the next.
	var truncate_at := MapO2Reader.HEADER_LEN + (2 + MapO2Reader.ENTRY_LEN) + 2 + 2 + 2 + MapO2Reader.ENTRY_LEN + 5
	var truncated := buf.slice(0, truncate_at)
	_check(MapO2Reader.parse(truncated) == null, "rejects a file truncated mid-entry")

	var bad_magic := PackedByteArray()
	bad_magic.resize(MapO2Reader.HEADER_LEN + 10)
	_check(MapO2Reader.parse(bad_magic) == null, "rejects bad magic")

	var too_small := PackedByteArray()
	too_small.resize(MapO2Reader.HEADER_LEN - 1)
	_check(MapO2Reader.parse(too_small) == null, "rejects a buffer too small for a header")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
