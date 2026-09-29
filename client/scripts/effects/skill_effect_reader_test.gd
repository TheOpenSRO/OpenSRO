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

## Round 640: skillaniset2's Priority (col 3) and DefenseEfp (col 13), and
## the highest-Priority pick. SYNTHETIC rows in the section's shape (the wall
## codes and efp names as the retail rows spell them).
func _test_defense_efp() -> void:
	var fire := PackedStringArray(["1", "wall", "SKILL_CH_FIRE_HWABYEOK_A", "0", "FALSE", "1", "DEFAULT",
		"ANI_READY04", "ANI_WAIT04", "ANI_SKILL_4", "none", "none", "none",
		"skill\\china\\fire_ganggi_damage_a.efp", "none"])
	var cold := PackedStringArray(["1", "wall", "SKILL_CH_COLD_BINGBYEOK_A", "0", "FALSE", "1", "DEFAULT",
		"ANI_READY04", "ANI_WAIT04", "ANI_SKILL_4", "none", "none", "none", "hiteffect\\hit_2_ice.efp", "none"])
	var high := PackedStringArray(["1", "x", "SKILL_TEST_HIGH", "5", "FALSE", "0", "DEFAULT",
		"none", "none", "none", "none", "none", "none", "hiteffect\\high.efp", "none"])
	var plain := PackedStringArray(["1", "x", "SKILL_TEST_PLAIN", "9", "FALSE", "0", "DEFAULT",
		"none", "none", "ANI_ATTACK1", "none", "none", "none", "none", "hiteffect\\hit.efp"])
	var rows := PackedStringArray(["#section\tskillaniset2", "\t".join(fire), "\t".join(cold),
		"\t".join(high), "\t".join(plain)])
	var sets := SkillEffectReader.parse_aniset(("\n".join(rows) + "\n").to_utf16_buffer())
	_check(SkillEffectReader.defense_efp_for(sets, ["SKILL_CH_FIRE_HWABYEOK_A_01"]) == "skill\\china\\fire_ganggi_damage_a.efp",
		"Fire Wall's DefenseEfp is col 13, by its level id")
	_check(SkillEffectReader.defense_efp_for(sets, ["SKILL_CH_COLD_BINGBYEOK_A_03"]) == "hiteffect\\hit_2_ice.efp",
		"Crystal Wall's DefenseEfp is col 13")
	_check(SkillEffectReader.defense_efp_for(sets, ["SKILL_TEST_PLAIN", "SKILL_CH_COLD_BINGBYEOK_A"]) == "hiteffect\\hit_2_ice.efp",
		"a row naming none (a DamageEfp only) is passed over")
	_check(SkillEffectReader.defense_efp_for(sets, ["SKILL_CH_FIRE_HWABYEOK_A", "SKILL_TEST_HIGH"]) == "hiteffect\\high.efp",
		"the highest Priority wins")
	_check(SkillEffectReader.defense_efp_for(sets, []) == "", "no buffs, no DefenseEfp")

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

	_test_defense_efp()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
