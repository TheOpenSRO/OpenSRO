extends SceneTree

## SoundTable's parse, key, pick and volume rules against synthetic rows
## written here (never the game's table), run headless:
## `godot4 --headless --path client --script res://scripts/audio/sound_table_test.gd`
##
## Loaded by path, so a checkout without the script prints FAIL lines.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 0.001) -> bool:
	return absf(a - b) <= eps

func _initialize() -> void:
	var st: GDScript = load("res://scripts/audio/sound_table.gd")
	_check(st != null, "scripts/audio/sound_table.gd exists (SoundTable, the contract's play_key)")
	if st == null:
		_finish()
		return

	# Latin-1: a CP949 byte pair survives as two characters, so the Korean
	# labels and descriptions never disturb the ASCII structure.
	var hi: String = st.latin1(PackedByteArray([0x41, 0xB3, 0xB7, 0x09, 0x42]))
	_check(hi.length() == 5 and hi.unicode_at(1) == 0xB3 and hi.unicode_at(2) == 0xB7 and hi.unicode_at(3) == 9,
		"bytes >= 0x80 decode one character per byte (Latin-1)")

	# A synthetic table in the retail shape: leading tab, tabs and spaces
	# mixed, comments, a block comment, a short row, a shared key.
	var text := ""
	text += "//\tobject\thandle\tskill_ID\tevent1\tevent2\tevent3\tblank\tfolder\tfilename\tvolume\tdescription\r\n"
	text += "\tTESTOBJ\tSND_TICK\t-\t-\t-\t-\t0\tFolderA\\\tOne.WAV\t80\tdesc words here\r\n"
	text += "\tTESTOBJ\tSND_TICK\t-\t-\t-\t-\t2\tfoldera\\\ttwo.wav\t200\r\n"
	text += "  TESTOBJ SND_Tock skill_x  KIND - - - FolderB\\ three.wav -\r\n"
	text += "/* a block\r\n\tTESTOBJ\tSND_GONE\t-\t-\t-\t-\t0\tx\\\tgone.wav\t80\r\n*/\r\n"
	text += "\tTESTOBJ\tSND_SHORT\t-\t-\t-\t0\tx\\\tshort.wav\t80\r\n"
	text += "//\tTESTOBJ\tSND_COMMENTED\t-\t-\t-\t-\t0\tx\\\tc.wav\t80\r\n"
	var bytes := text.to_ascii_buffer()
	bytes.append_array(PackedByteArray([0x09, 0xB3, 0xB7, 0x0D, 0x0A])) # a Korean-only line
	var table: Dictionary = st.parse(bytes)

	var tick_key: String = st.make_key("TESTOBJ", "SND_TICK")
	_check(tick_key == "TESTOBJ:snd_tick:-:-:-:-", "make_key joins six tokens with ':' and lowercases the handle")
	_check(st.make_key("TESTOBJ", "SND_Tock", "skill_x", "KIND") == "TESTOBJ:snd_tock:SKILL_X:KIND:-:-",
		"make_key uppercases the skill token and keeps the object and events as written")
	_check(table.has(tick_key) and (table[tick_key] as Array).size() == 2, "two rows under one key are both kept (a multimap)")
	_check(table.has("TESTOBJ:snd_tock:SKILL_X:KIND:-:-"), "space-separated columns parse the same as tab-separated")
	_check(not table.has("TESTOBJ:snd_gone:-:-:-:-"), "rows inside /* */ are skipped")
	_check(not table.has("TESTOBJ:snd_commented:-:-:-:-"), "a // row is skipped")
	_check(table.size() == 2, "a row with fewer than ten columns is skipped (%d keys)" % table.size())
	_check(not table.has("testobj:snd_tick:-:-:-:-") and not table.has("TESTOBJ:SND_TICK:-:-:-:-"), "the match is exact: other spellings are other keys")
	if table.has(tick_key):
		var r0 = table[tick_key][0]
		var r1 = table[tick_key][1]
		_check(r0.path == "prim\\snd\\foldera\\one.wav", "path = prim\\snd\\ + folder + filename, lowercased (%s)" % r0.path)
		_check(_near(r0.volume, 0.8) and r0.blank == 0, "volume column 80 -> 0.8, blank 0")
		_check(_near(r1.volume, 1.0) and r1.blank == 2, "volume 200 clamps to 1.0; blank 2 is read")
	var tock = table.get("TESTOBJ:snd_tock:SKILL_X:KIND:-:-", [null])[0]
	_check(tock != null and tock.volume == 0.0 and tock.blank == 0, "a '-' volume or blank reads as atoi's 0")

	# The pick: row roll % n, then the per-row blank counter.
	var rows: Array = []
	for b in [0, 2]:
		var r2 = st.Row.new()
		r2.blank = b
		rows.append(r2)
	var hits0 := 0
	for i in range(6):
		if st.pick(rows, 4) != null: # 4 % 2 == 0 -> row 0, blank 0
			hits0 += 1
	_check(hits0 == 6, "a blank-0 row plays on every trigger (6 of 6)")
	var pattern := ""
	for i in range(7):
		pattern += "1" if st.pick(rows, 3) != null else "0" # 3 % 2 == 1 -> row 1, blank 2
	_check(pattern == "1001001", "a blank-2 row plays on the 1st trigger, then every 3rd: %s" % pattern)
	_check(st.pick([], 0) == null, "no rows, nothing to play")

	# The volume law (READ): 0 dB inside 100, linear in dB to -30 at 300.
	_check(st.distance_mb(0.0) == 0.0 and st.distance_mb(100.0) == 0.0, "distMB is 0 within 100 units")
	_check(_near(st.distance_mb(200.0), -1500.0), "distMB is -1500 halfway, at 200 units")
	_check(_near(st.distance_mb(250.0), -2250.0), "distMB is -2250 at 250 units")
	_check(st.distance_mb(300.0) == -3000.0 and st.distance_mb(5000.0) == -3000.0, "distMB is the -3000 floor from 300 units")
	# effect slider 50 -> -1000 mB -> optFrac 2/3.
	_check(st.volume_mb(0.0, -1000, 0.8) == -1400, "near, Effect 50, row 80: -3000 + 3000 * 2/3 * 0.8 = -1400 mB")
	_check(st.volume_mb(0.0, -1000, 1.0) == -1000, "near, row 100: exactly the slider's -1000 mB")
	_check(st.volume_mb(0.0, 0, 1.0) == 0, "near, Effect 100, row 100: 0 mB")
	_check(st.volume_mb(-1500.0, -1000, 1.0) == -2000, "at 200 units, Effect 50: -3000 + 1500 * 2/3 = -2000 mB")
	_check(st.volume_mb(0.0, -2000, 1.0) == -2000, "Effect 0 (-20 dB) is still audible: -2000 mB")
	_check(not st.audible(st.volume_mb(-3000.0, 0, 1.0)), "at 300 units nothing plays (vol must be above -3000)")
	_check(st.audible(-2999) and not st.audible(-3000), "audible means strictly above the floor")
	_check(st.culled(600.0 * 600.0 + 1.0) and not st.culled(600.0 * 600.0), "the cull is strictly beyond 600 units")

	# Pan (READ): lateral / 300 * 10000, clamped.
	_check(st.pan_units(150.0) == 5000 and st.pan_units(-150.0) == -5000, "150 units to the side is pan +-5000")
	_check(st.pan_units(0.0) == 0, "straight ahead is centred")
	_check(st.pan_units(900.0) == 10000 and st.pan_units(-301.0) == -10000, "300+ units to the side is fully one-sided")

	# characterInfo, UTF-16 with a byte-order mark, only its own section.
	var ci := "#section\tcharacterInfo\t\t\r\n//ResourceFileID\tResourceTypeName\r\n"
	ci += "TEST_CODE_A\tSOUND_OBJ_A\t1.9\tnone\r\nTEST_CODE_B\tSOUND_OBJ_B\t1.0\r\n"
	ci += "#section\tlight\t\r\nTEST_CODE_C\tSOUND_OBJ_C\r\n"
	var ci_bytes := PackedByteArray([0xFF, 0xFE])
	ci_bytes.append_array(ci.to_utf16_buffer())
	var info: Dictionary = st.parse_character_info(ci_bytes)
	_check(info.get("TEST_CODE_A", "") == "SOUND_OBJ_A" and info.get("TEST_CODE_B", "") == "SOUND_OBJ_B",
		"characterInfo maps column 1 to column 2 (UTF-16)")
	_check(not info.has("TEST_CODE_C") and not info.has("//ResourceFileID"), "rows of other sections and comments are not taken")
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
