extends SceneTree

## SkillAudio's skill context and the skilleffectset SndBegin lookup, against
## synthetic tables written here (never the game's), run headless:
## `godot4 --headless --path client --script res://scripts/audio/skill_audio_test.gd`
##
## Loaded by path, so a checkout without the script prints FAIL lines.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

## One skilldata-shaped row: Service, ID, GroupID, Basic_Code, Basic_Name,
## Basic_Group, Basic_Original, Basic_Level, then filler columns.
func _skill_row(id: int, code: String, group: String, original: int) -> String:
	return "1\t%d\t%d\t%s\tname\t%s\t%d\t1\t0\t0\t0\r\n" % [id, id, code, group, original]

## One skilleffectset-shaped row with SndBegin at `snd_col` (0-based).
func _effect_row(label: String, id: String, ani: String, start_event: int, snd: String, snd_col: int = 26) -> String:
	var cols: Array = [label, id, ani, str(start_event)]
	while cols.size() < snd_col:
		cols.append("x")
	cols.append(snd)
	cols.append("none")
	return "\t".join(PackedStringArray(cols)) + "\r\n"

func _initialize() -> void:
	var sa: GDScript = load("res://scripts/audio/skill_audio.gd")
	_check(sa != null, "scripts/audio/skill_audio.gd exists (SkillAudio, the skill context and cast sounds)")
	if sa == null:
		_finish()
		return

	_check(sa.READY == 0 and sa.WAIT == 1 and sa.SHOT == 2 and sa.ACT_OS == 3 and sa.ACT_OL == 4
		and sa.ACT_OE == 5 and sa.ACT_S == 6 and sa.ACT_L == 7 and sa.DEACT == 8 and sa.S_RETURN == 9,
		"the AniType numbers are the name table's order")

	# skilldata: ids -> code, group, original.
	var sd := "//\tcomment row\r\n"
	sd += _skill_row(101, "TEST_SKILL_A_01", "TEST_SKILL_A", 0)
	sd += _skill_row(102, "TEST_SKILL_A_02", "TEST_SKILL_A", 0)
	sd += _skill_row(201, "TEST_ALIAS_001", "xxx", 101)
	sd += _skill_row(301, "TEST_BASE_01", "TEST_BASE", 0)
	sd += _skill_row(401, "TEST_LOOP_01", "TEST_LOOP", 402)
	sd += _skill_row(402, "TEST_LOOP_02", "TEST_LOOP", 401)
	var skills: Dictionary = sa.parse_skills(_utf16(sd))
	_check(skills.size() == 6, "six skill rows parse, the comment does not (%d)" % skills.size())
	var c102: Dictionary = sa.context_in(skills, 102)
	_check(c102["code"] == "TEST_SKILL_A_02" and c102["group"] == "TEST_SKILL_A", "a skill's own code and group")
	var c201: Dictionary = sa.context_in(skills, 201)
	_check(c201["code"] == "TEST_SKILL_A_01" and c201["group"] == "TEST_SKILL_A",
		"Basic_Original is followed to the root record (%s)" % str(c201))
	var c0: Dictionary = sa.context_in(skills, 0)
	var c999: Dictionary = sa.context_in(skills, 999)
	_check(c0["code"] == "-" and c0["group"] == "-" and c999["group"] == "-", "no skill or an unknown one is '-'")
	_check(sa.root_id(skills, 401) >= 0, "a Basic_Original cycle stops")

	# skilleffectset: only its own section, only rows with a SndBegin.
	var se := "#section\tcharacterInfo\t\r\n"
	se += _effect_row("x", "TEST_SKILL_A", "READY", 0, "test\\in_other_section.wav")
	se += "#section\tskilleffectset\t\t\r\n"
	var header: Array = ["//SkillName11", "SkillEffectID", "AniType", "StartEvent"]
	while header.size() < 26:
		header.append("col%d" % header.size())
	header.append("SndBegin")
	header.append("SndEnd")
	se += "\t".join(PackedStringArray(header)) + "\r\n"
	se += _effect_row("label", "TEST_SKILL_A", "READY", 0, "test\\Ready.WAV")
	se += _effect_row("-", "TEST_SKILL_A", "SHOT", 0, "test\\shot0.wav")
	se += _effect_row("-", "TEST_SKILL_A", "SHOT", 1, "test\\shot1.wav")
	se += _effect_row("-", "TEST_SKILL_A", "SHOT", 2, "test\\shot2.wav")
	se += _effect_row("-", "TEST_SKILL_A", "ACT_S", 0, "none")
	se += _effect_row("-", "TEST_SKILL_A", "WAIT", 0, "test\\wait.wav")
	se += _effect_row("-", "TEST_SKILL_A", "BOGUS", 0, "test\\bogus.wav")
	se += _effect_row("-", "TEST_BASE_01", "SHOT", 1, "test\\base.wav")
	se += "#section\tenv\t\r\n"
	se += _effect_row("-", "TEST_SKILL_A", "SHOT", 1, "test\\after.wav")
	var effects: Dictionary = sa.parse_effect_sounds(_utf16(se))
	var rows: Array = effects.get("TEST_SKILL_A", [])
	_check(rows.size() == 5, "five SndBegin rows for the skill: none, an unknown AniType and other sections are dropped (%d)" % rows.size())
	var ready: PackedStringArray = sa.sounds_in(skills, effects, 102, sa.READY)
	_check(ready.size() == 1 and ready[0] == "prim\\snd\\test\\ready.wav",
		"READY's SndBegin, as prim\\snd\\ + the column, lowercased (%s)" % ",".join(ready))
	var shot1: PackedStringArray = sa.sounds_in(skills, effects, 101, sa.SHOT, 1)
	_check(shot1.size() == 1 and shot1[0] == "prim\\snd\\test\\shot1.wav", "SHOT rows split by StartEvent (%s)" % ",".join(shot1))
	_check(sa.sounds_in(skills, effects, 101, sa.SHOT).size() == 3, "StartEvent -1 takes every SHOT row")
	_check(sa.sounds_in(skills, effects, 201, sa.SHOT, 0).size() == 1, "an aliased skill finds its original's rows")
	var base: PackedStringArray = sa.sounds_in(skills, effects, 301, sa.SHOT, 1)
	_check(base.size() == 1 and base[0] == "prim\\snd\\test\\base.wav", "a row keyed by Basic_Code is found when the group has none")
	_check(sa.sounds_in(skills, effects, 999, sa.READY).is_empty(), "an unknown skill has no cast sounds")

	# A header that puts SndBegin elsewhere moves the column.
	var se2 := "#section\tskilleffectset\r\n//a\tSkillEffectID\tAniType\tStartEvent\tSndBegin\tSndEnd\r\n"
	se2 += "l\tTEST_SKILL_A\tREADY\t0\ttest\\moved.wav\tnone\r\n"
	var moved: Dictionary = sa.parse_effect_sounds(_utf16(se2))
	_check(moved.has("TEST_SKILL_A") and String((moved["TEST_SKILL_A"] as Array)[0][2]) == "prim\\snd\\test\\moved.wav",
		"SndBegin is found by the header's own column name")

	# The loaded-table API the animation sounds use.
	sa.set_tables(skills, effects)
	var who := Node.new()
	_check(sa.current_skill(who) == 0 and sa.context_of(who)["group"] == "-", "no current skill: '-'")
	sa.set_current(who, 102)
	_check(sa.current_skill(who) == 102 and sa.context_of(who)["group"] == "TEST_SKILL_A", "set_current / context_of")
	sa.set_current(who, 0)
	_check(sa.current_skill(who) == 0, "set_current 0 clears it")
	var left: Array = sa.unplayed_rows(101)
	_check(left.size() == 2, "the rows this client does not fire are reported: WAIT and SHOT/2 (%s)" % str(left))
	who.free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
