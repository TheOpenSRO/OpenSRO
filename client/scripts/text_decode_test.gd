extends SceneTree

## Round 760 (blocker 4): TextDecode.utf16 decodes plain UTF-16 exactly as
## get_string_from_utf16 does, and reads every unpaired surrogate as U+FFFD,
## so no decoded text carries Godot's uninitialised character (TextDecode's
## header: String::append_utf16 drops a lead surrogate followed by a plain
## character but sizes the string for it; encoding that garbage overflows the
## heap on 4.7.2). With the native library, the exact path that corrupted
## table_parity.gd's heap -- a table the port hands back, read by the GDScript
## reader, its cells handed to SrNativeTables.numbers -- is run 2,000 times.
## `godot4 --headless --path client --script res://scripts/text_decode_test.gd`
##
## NEGATIVE: with TextDecode.utf16 returning data.get_string_from_utf16(), the
## "no garbage" and "U+FFFD" checks fail (and on 4.7.2 the native loop usually
## aborts the process: tools/utf16_garbage_probe.gd, rc 134).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _le(units: Array, bom: bool = true) -> PackedByteArray:
	var b := PackedByteArray()
	if bom:
		b.append_array([0xFF, 0xFE])
	for u in units:
		b.append(int(u) & 0xFF)
		b.append(int(u) >> 8)
	return b

static func _codes(s: String) -> Array:
	var out := []
	for i in range(s.length()):
		out.append(s.unicode_at(i))
	return out

func _same_as_engine(label: String, d: PackedByteArray) -> void:
	_check(TextDecode.utf16(d) == d.get_string_from_utf16() and TextDecode.safe_utf16_bytes(d) == d,
		"plain text decodes as the engine does, bytes untouched: %s" % label)

func _initialize() -> void:
	# Plain text: identical to the engine, no copy.
	_same_as_engine("ascii with BOM", "a\tb\r\nc".to_utf16_buffer())
	_same_as_engine("ascii", _le([0x61, 0x62], false))
	_same_as_engine("CJK and Hangul, high bytes near the surrogates", _le([0x4E2D, 0xD7A3, 0xACD8, 0x00D8, 0x00DF, 0xDF, 0x41]))
	_same_as_engine("a surrogate pair (U+1F600)", _le([0x41, 0xD83D, 0xDE00, 0x42]))
	_same_as_engine("the stop at a NUL", _le([0x61, 0x62, 0, 0x63]))
	_same_as_engine("swapped BOM", PackedByteArray([0xFE, 0xFF, 0x00, 0x41, 0xD8, 0x3D, 0xDE, 0x00]))
	_same_as_engine("odd size", PackedByteArray([0xFF, 0xFE, 0x41, 0x00, 0xD8]))
	_same_as_engine("empty", PackedByteArray())

	# Unpaired surrogates: U+FFFD each, every other character kept.
	var cases := [
		["lead then a plain character", _le([0x41, 0xD800, 0x42]), [0x41, 0xFFFD, 0x42]],
		["lead at the end", _le([0x41, 0xDBFF]), [0x41, 0xFFFD]],
		["lone trail", _le([0xDC00, 0x41]), [0xFFFD, 0x41]],
		["lead, lead, trail", _le([0xD800, 0xD83D, 0xDE00]), [0xFFFD, 0x1F600]],
		["trail, lead (reversed pair)", _le([0xDE00, 0xD83D, 0x41]), [0xFFFD, 0xFFFD, 0x41]],
		["lead before a NUL", _le([0x41, 0xD800, 0, 0x42]), [0x41, 0xFFFD]],
		["no BOM", _le([0xD800, 0x42], false), [0xFFFD, 0x42]],
		["swapped BOM, lead then plain", PackedByteArray([0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x42]), [0xFFFD, 0x42]],
	]
	for c in cases:
		var got := _codes(TextDecode.utf16(c[1]))
		_check(got == c[2], "%s -> %s (%s)" % [c[0], str(c[2]), str(got)])

	# Encrypted-looking bytes: deterministic, no character outside Unicode, encodable.
	var rng := RandomNumberGenerator.new()
	rng.seed = 760
	var garbage := 0
	var unstable := 0
	for r in range(300):
		var d := PackedByteArray([0xFF, 0xFE])
		for i in range(512):
			d.append(rng.randi() & 0xFF)
			# Many units in the surrogate range, as encrypted text has.
			d.append(0xD8 + (rng.randi() % 8) if rng.randi() % 3 == 0 else rng.randi() & 0xFF)
		var a := TextDecode.utf16(d)
		var b := TextDecode.utf16(d)
		if a != b:
			unstable += 1
		for ch in _codes(a):
			if int(ch) > 0x10FFFF or int(ch) < 0 or (int(ch) >= 0xD800 and int(ch) < 0xE000):
				garbage += 1
		var _u8 := a.to_utf8_buffer()
		var _u16 := a.to_utf16_buffer()
	_check(garbage == 0, "300 random tables: no lone surrogate and no character past U+10FFFF (%d)" % garbage)
	_check(unstable == 0, "300 random tables: each decodes the same twice (%d differ)" % unstable)

	# The table_parity path, with the native library when it loads (4.7+ only).
	var nt: Object = NativeAssets.new_tables()
	if nt == null:
		print("ok  (no usable native library here: the native path is not exercised -- %s)" % Engine.get_version_info().string)
	else:
		var table := _le([0x31, 0x09, 0xD800, 0x41, 0x09, 0x32, 0x0A, 0x41, 0xDC00, 0x0A, 0x33, 0x2E, 0x35, 0xD83D])
		var r: Dictionary = nt.call("split_rows", table, true)
		_check(r.has("fallback"), "the native split hands a table with unpaired surrogates back (%s)" % str(r.get("fallback", "")))
		var ok := true
		for i in range(2000):
			var cells := PackedStringArray()
			for line in NpcTableReader._lines(table):
				cells.append_array(line.split("\t"))
			var nums: Dictionary = nt.call("numbers", cells)
			if (nums["ints"] as PackedInt64Array).size() != cells.size():
				ok = false
		_check(ok, "2,000 GDScript decodes of it handed to SrNativeTables.numbers")
		_check(_codes(NpcTableReader._lines(table)[0]) == [0x31, 0x09, 0xFFFD, 0x41, 0x09, 0x32],
			"the GDScript reader's first line reads the lone lead as U+FFFD")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit()
