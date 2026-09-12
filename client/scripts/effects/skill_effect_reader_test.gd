extends SceneTree

## Exercises SkillEffectReader against synthetic rows shaped like the real
## skilleffect.txt (never real game data):
##   godot4 --headless --path client --script res://scripts/effects/skill_effect_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A skill row with Basic_Code at col 2 and a hit .efp at col 14 (or elsewhere).
func _row(code: String, hit_efp_col: String, extra_efp: String = "") -> String:
	var cols := PackedStringArray()
	cols.resize(20)
	cols.fill("none")
	cols[0] = "1"
	cols[SkillEffectReader.E_CODE] = code
	cols[SkillEffectReader.E_HIT_EFP] = hit_efp_col
	if extra_efp != "":
		cols[17] = extra_efp
	return "\t".join(cols)

func _init() -> void:
	var rows := PackedStringArray([
		"#section\tcharacterInfo",
		"CHAR_CH_MAN_FIGHTER\tPCM_FIGHTER\t2\tnone",  # not a SKILL_ row -> dropped
		_row("SKILL_CH_SWORD_SMASH_A", "hiteffect\\hit_3_critical.efp"),
		_row("SKILL_CH_SWORD_GEOMGI_A", "none", "hiteffect\\hit_geomgi.efp"),  # efp not at col14
		_row("SKILL_CH_SWORD_NOEFFECT", "none"),  # no efp anywhere -> dropped
	])
	var data := ("\n".join(rows) + "\n").to_utf16_buffer()
	var effects := SkillEffectReader.parse(data)

	_check(effects.has("SKILL_CH_SWORD_SMASH_A"), "a SKILL_ row is kept")
	_check(not effects.has("CHAR_CH_MAN_FIGHTER"), "a characterInfo row is dropped")
	_check(not effects.has("SKILL_CH_SWORD_NOEFFECT"), "a row with no .efp is dropped")
	_check(effects.get("SKILL_CH_SWORD_SMASH_A", "") == "hiteffect\\hit_3_critical.efp",
		"the hit .efp is read from col 14")
	_check(effects.get("SKILL_CH_SWORD_GEOMGI_A", "") == "hiteffect\\hit_geomgi.efp",
		"a .efp not at col 14 is still found by scan")
	# The lookup tolerates the per-level suffix the table omits.
	_check(SkillEffectReader.hit_efp_for(effects, "SKILL_CH_SWORD_SMASH_A_01") == "hiteffect\\hit_3_critical.efp",
		"hit_efp_for strips the _NN level suffix")
	_check(SkillEffectReader.hit_efp_for(effects, "SKILL_CH_SWORD_UNKNOWN_03") == "",
		"hit_efp_for returns empty for an unknown skill")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
