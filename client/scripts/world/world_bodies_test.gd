extends SceneTree

## Round 689 (charselect.md lane W), headless, on synthetic rows and tables
## (never game data):
## `godot4 --headless --path client --script res://scripts/world/world_bodies_test.gd`
##
## - WorldBodies: the world draws a character from its own model -- a Europe
##   id is a Europe body -- and falls back to the gender's legacy body only
##   when the server sent no model or the archive lacks it.
## - BodyAnimations + BsrReader: the client's clip lookup (READ, round 689):
##   the weapon -> group switch with the fortress weapon by race, the last
##   entry of a type winning, and an entry naming no file falling back to
##   `default` instead of playing nothing -- the round's T-pose fix for the
##   Europe bodies' empty entries (onehand_staff type 5, onehand_sword type 16).
## - Every core action resolves a clip in every group of a body built like
##   the archive's (the real 52 are client/tools/body_anim_probe.gd's).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _row(id: int, code: String, country: int, sex: int, model: String) -> String:
	var cols := PackedStringArray()
	cols.resize(95)
	for i in range(95):
		cols[i] = "0"
	cols[CharCatalog.COL_SERVICE] = "1"
	cols[CharCatalog.COL_ID] = str(id)
	cols[CharCatalog.COL_CODE] = code
	cols[CharCatalog.COL_TYPE_ID1] = "1"
	cols[CharCatalog.COL_TYPE_ID1 + 1] = "1"
	cols[CharCatalog.COL_COUNTRY] = str(country)
	cols[CharCatalog.COL_MODEL] = model
	cols[CharCatalog.COL_SEX] = str(sex)
	return "\t".join(cols)

func _entry(t: int, path: String) -> BsrReader.AnimationEntry:
	var e := BsrReader.AnimationEntry.new()
	e.action_type = t
	e.path = path
	return e

func _init() -> void:
	# --- the body ---------------------------------------------------------------
	var cat := CharCatalog.from_tables(["\n".join([
		_row(1909, "CHAR_CH_MAN_FIGHTER", 0, 1, "char\\china\\chinaman_fighter.bsr"),
		_row(1923, "CHAR_CH_WOMAN_FIGHTER", 0, 0, "char\\china\\chinawoman_fighter.bsr"),
		_row(1925, "CHAR_CH_WOMAN_KANGSI", 0, 0, "char\\china\\chinawoman_kangsi.bsr"),
		_row(14875, "CHAR_EU_MAN_NOBLE", 1, 1, "char\\europe\\europeman_noble.bsr"),
		_row(14888, "CHAR_EU_WOMAN_NOBLE", 1, 0, "char\\europe\\europewoman_noble.bsr"),
	])], [])
	_check(WorldBodies.body_key(cat, 14875, "china_man") == "CHAR_EU_MAN_NOBLE",
		"a Europe man's model draws the Europe body, whatever the gender string says")
	_check(WorldBodies.body_key(cat, 14888, "europe_woman") == "CHAR_EU_WOMAN_NOBLE", "a Europe woman's model draws hers")
	_check(WorldBodies.body_key(cat, 1925, "china_woman") == "CHAR_CH_WOMAN_KANGSI",
		"a China Figure other than the fighter draws its own body (the user's 'default woman skin')")
	_check(WorldBodies.body_key(cat, 0, "china_woman") == "CHAR_CH_WOMAN_FIGHTER", "no model (an older server): the gender's legacy body")
	_check(WorldBodies.body_key(cat, 0, "europe_man") == "CHAR_CH_MAN_FIGHTER", "no model and a gender with no legacy body: the default's")
	_check(WorldBodies.body_key(cat, 31337, "china_woman") == "CHAR_CH_WOMAN_FIGHTER", "a model the archive does not hold: the gender's")
	_check(WorldBodies.body_key(null, 14875, "china_man") == "CHAR_CH_MAN_FIGHTER", "no catalogue: the gender's")

	# --- the group -----------------------------------------------------------------
	_check(BodyAnimations.group_for_weapon(0, 1) == "default", "no weapon: default")
	_check(BodyAnimations.group_for_weapon(7, 1) == "onehand_sword" and BodyAnimations.group_for_weapon(14, 0) == "harf",
		"the switch is the weapon's alone (no race or sex test) for every TypeID4 but 16")
	_check(BodyAnimations.group_for_weapon(16, 0) == "sword" and BodyAnimations.group_for_weapon(16, 1) == "onehand_sword"
		and BodyAnimations.group_for_weapon(16, 7) == "sword", "the fortress weapon: sword for China, onehand_sword for Europe (READ FUN_00a5a7d0)")

	# --- the entry (a body laid out like the Europe man's: default names China clips) ---
	var parsed := BsrReader.ParsedObject.new()
	parsed.animation_groups = {
		"default": [_entry(0, "chinaman_fighter_standcity.ban"), _entry(5, "chinaman_a_handstraightr.ban"),
			_entry(7, "europe_man_fighter_run.ban"), _entry(13, "chinaman_a_sitground.ban"),
			_entry(14, "chinaman_a_sitbreath.ban"), _entry(15, "chinaman_a_sitstand.ban"),
			_entry(16, "chinaman_a_handhookl.ban"), _entry(1, "chinaman_fighter_walkforward.ban"),
			_entry(2, "chinaman_a_handstraightl.ban"), _entry(3, "chinaman_a_benormalhit.ban"),
			_entry(4, "chinaman_a_diehardhit.ban")],
		"onehand_staff": [_entry(0, "chinaman_merchant_standcity.ban"), _entry(2, "skill_eu_wizard_onehand_attack_01.ban"),
			_entry(5, "")],
		"onehand_sword": [_entry(2, "skill_eu_warrior_onehanda_attack01.ban"), _entry(16, ""),
			_entry(7, "europe_man_fighter_sword_run.ban"), _entry(7, "europe_man_fighter_sword_run2.ban")],
	}
	_check(parsed.animation_for(5, "onehand_staff") == "chinaman_a_handstraightr.ban"
		and parsed.animation_group_for(5, "onehand_staff") == "default",
		"an entry naming no file falls back to default (READ ResObject::FUN_00c0f500's null clip, AniMixer::FUN_00c551a0)")
	_check(parsed.animation_for(16, "onehand_sword") == "chinaman_a_handhookl.ban", "the same for onehand_sword's empty type 16")
	_check(parsed.animation_for(7, "onehand_sword") == "europe_man_fighter_sword_run2.ban",
		"of two entries of one type the last wins (READ FUN_00c0f470 overwrites in place)")
	_check(parsed.animation_for(0, "onehand_sword") == "chinaman_fighter_standcity.ban", "a type the group lacks: default's")
	_check(parsed.animation_for(0, "onehand_staff") == "chinaman_merchant_standcity.ban", "a type the group has: its own")
	_check(parsed.animation_for(99, "onehand_staff") == "", "a type no group has: nothing")
	_check(BodyAnimations.entry_for(parsed, 14, "harf") != null and BodyAnimations.entry_for(parsed, 14, "harf").path == "chinaman_a_sitbreath.ban",
		"sitting goes through the same lookup (READ 0xa5a270): a group with no sit clip sits with default's")
	var anims := BodyAnimations.new(null)
	_check(anims.clip_for(null, 0) == null and anims.path_for(null, 0) == "", "no body: no clip, no crash")

	# Every core action, in every group the Europe race's weapons pick, resolves.
	var missing := []
	for g in BodyAnimations.race_groups(BodyAnimations.RACE_EUROPE):
		for name in BodyAnimations.CORE_ACTIONS:
			if parsed.animation_for(int(BodyAnimations.CORE_ACTIONS[name]), g) == "":
				missing.append("%s/%s" % [g, name])
	_check(missing.is_empty(), "every core action resolves in every Europe weapon group (missing: %s)" % str(missing))

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(0)
