extends SceneTree

## Exercises ObjidxReader against a synthetic .ifo table (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/objidx/objidx_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _build_table(entries: Array) -> PackedByteArray:
	var text := ObjidxReader.MAGIC + "\n" + str(entries.size()) + "\n"
	for e in entries:
		text += "%05d 0x%08x \"%s\"\n" % [e[0], e[1], e[2]]
	return text.to_ascii_buffer()

func _init() -> void:
	var data := _build_table([
		[0, 1, "res\\bldg\\test\\tree01.bsr"],
		[1, 0, "res\\bldg\\test\\rock01.bsr"],
		[2, 0, "res\\nature\\test\\grass01.bsr"],
	])

	var table := ObjidxReader.parse(data)
	_check(table != null, "parses a synthetic sequential table")
	if table != null:
		_check(table.entries.size() == 3, "3 entries (got %d)" % table.entries.size())

		var e1 := table.lookup(1)
		_check(e1 != null, "lookup(1) succeeds")
		if e1 != null:
			_check(e1.path == "res\\bldg\\test\\rock01.bsr", "lookup(1).path matches (got %s)" % e1.path)
			_check(e1.flags == 0, "lookup(1).flags == 0 (got %d)" % e1.flags)

		var e0 := table.lookup(0)
		_check(e0 != null and e0.flags == 1, "lookup(0).flags == 1 (got %s)" % (e0.flags if e0 != null else "null"))

		_check(table.lookup(5) == null, "lookup out of range returns null")

	var bad_magic := "NOT_REAL_MAGIC\n0\n".to_ascii_buffer()
	_check(ObjidxReader.parse(bad_magic) == null, "rejects bad magic")

	var bad_count := (ObjidxReader.MAGIC + "\n5\n00000 0x00000000 \"res\\a.bsr\"\n").to_ascii_buffer()
	_check(ObjidxReader.parse(bad_count) == null, "rejects declared count exceeding real body lines")

	var bad_record := (ObjidxReader.MAGIC + "\n1\nnot a real record line\n").to_ascii_buffer()
	_check(ObjidxReader.parse(bad_record) == null, "rejects a malformed record line")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
