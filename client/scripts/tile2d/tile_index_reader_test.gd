extends SceneTree

## Exercises TileIndexReader against a synthetic tile2d.ifo-shaped buffer
## (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/tile2d/tile_index_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _build_table(lines: Array) -> PackedByteArray:
	var text := TileIndexReader.MAGIC + "\n" + str(lines.size()) + "\n" + "\n".join(lines) + "\n"
	return text.to_ascii_buffer()

func _init() -> void:
	var data := _build_table([
		'00000 0x00000000 "CJfild" "c_dust_fld_01.ddj"',
		'00001 0x0000000a "CJfild" "c_grass_fld_03.ddj"',
		'00002 0x0000000a "HMfild" "c_grass_hmfld_01.ddj" {757,64}',
		'00003 0x00000007 "WC" "wc_water_01.ddj"',
	])
	var table := TileIndexReader.parse(data)
	_check(table != null, "parses a synthetic tile2d table")
	if table != null:
		_check(table.entries.size() == 4, "4 entries (got %d)" % table.entries.size())
		var e0 := table.lookup(0)
		_check(e0 != null and e0.type == TileIndexReader.TileType.DIRT, "entry 0 is Dirt (got %s)" % (e0.type if e0 != null else "null"))
		_check(e0 != null and e0.category == "CJfild" and e0.filename == "c_dust_fld_01.ddj", "entry 0 category/filename match")
		var e1 := table.lookup(1)
		_check(e1 != null and e1.type == TileIndexReader.TileType.GRASS, "entry 1 is Grass (got %s)" % (e1.type if e1 != null else "null"))
		var e2 := table.lookup(2)
		_check(e2 != null and e2.filename == "c_grass_hmfld_01.ddj", "entry 2 (with a trailing grass-placement field) still parses correctly")
		var e3 := table.lookup(3)
		_check(e3 != null and e3.type == TileIndexReader.TileType.WATER, "entry 3 is Water (got %s)" % (e3.type if e3 != null else "null"))
		_check(table.lookup(4) == null, "lookup out of range returns null")
		_check(table.lookup(-1) == null, "lookup of a negative id returns null")

	var bad_magic := "NOTREAL\n0\n".to_ascii_buffer()
	_check(TileIndexReader.parse(bad_magic) == null, "rejects bad magic")

	var bad_count := (TileIndexReader.MAGIC + "\nnotanumber\n").to_ascii_buffer()
	_check(TileIndexReader.parse(bad_count) == null, "rejects a non-numeric count line")

	var too_few_lines := (TileIndexReader.MAGIC + "\n5\n" + '00000 0x00000000 "X" "y.ddj"' + "\n").to_ascii_buffer()
	_check(TileIndexReader.parse(too_few_lines) == null, "rejects a declared count larger than the real body")

	var malformed := (TileIndexReader.MAGIC + "\n1\n" + "not a real record line" + "\n").to_ascii_buffer()
	_check(TileIndexReader.parse(malformed) == null, "rejects a malformed record line")

	var too_short := "JMXV2DTI1001".to_ascii_buffer()
	_check(TileIndexReader.parse(too_short) == null, "rejects a file too short to contain a header")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
