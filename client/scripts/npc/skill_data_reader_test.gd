extends SceneTree

## Exercises SkillDataReader against synthetic rows shaped like the real
## skillgroup.txt / skilldata_*.txt (never real game data):
##   godot4 --headless --path client --script res://scripts/npc/skill_data_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A skillgroup row with the fields at the columns the reader reads.
func _group(mastery: String, row: String, name_code: String, icon: String) -> String:
	var cols := PackedStringArray()
	cols.resize(7)
	cols.fill("0")
	cols[SkillDataReader.G_MASTERY] = mastery
	cols[SkillDataReader.G_ROW] = row
	cols[SkillDataReader.G_NAME] = name_code
	cols[SkillDataReader.G_ICON] = icon
	return "\t".join(cols)

## A skilldata row (119 columns) with the fields the reader reads.
func _skill(base_id: String, level: String, mastery: String, req_ml: String,
		group_row: String, icon: String, name: String) -> String:
	var cols := PackedStringArray()
	cols.resize(119)
	cols.fill("0")
	cols[SkillDataReader.S_UNIQUE_ID] = str(int(base_id) * 100 + int(level))
	cols[SkillDataReader.S_BASE_ID] = base_id
	cols[SkillDataReader.S_BASIC_CODE] = name.replace("SN_", "") + "_0" + level
	cols[SkillDataReader.S_LEVEL] = level
	cols[SkillDataReader.S_MASTERY] = mastery
	cols[SkillDataReader.S_REQ_MASTERY_LEVEL] = req_ml
	cols[SkillDataReader.S_GROUP_ROW] = group_row
	cols[SkillDataReader.S_ICON] = icon
	cols[SkillDataReader.S_NAME] = name
	# Cast stats: cast/cooldown/range constant per skill; sp/mp rise per level.
	cols[SkillDataReader.S_CAST_TIME] = "400"
	cols[SkillDataReader.S_REUSE_DELAY] = "3000"
	cols[SkillDataReader.S_RANGE] = "0"
	cols[SkillDataReader.S_TARGET_REQUIRED] = "1"
	cols[SkillDataReader.S_TARGET_LAND] = "0"
	cols[SkillDataReader.S_REQ_SP] = str(int(level) * 10)
	cols[SkillDataReader.S_CONSUME_MP] = str(int(level) * 5)
	cols[SkillDataReader.S_TOOLTIP_DESC] = name + "_TT"
	# Level 2 of every synthetic skill needs group 174 at level 9 -- the shape
	# of the real SKILL_CH_SWORD_SMASH_B_01 row (ReqLearn_Skill1/Level1).
	if level == "2":
		cols[SkillDataReader.S_REQ_SKILL_1] = "174"
		cols[SkillDataReader.S_REQ_SKILL_LEVEL_1] = "9"
	return "\t".join(cols)

func _init() -> void:
	_test_groups()
	_test_skills()
	_test_level_range_and_targeting()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _test_groups() -> void:
	var rows := PackedStringArray([
		"// a comment row the real file carries",
		_group("257", "0", "UIIT_G0", "skillgroup\\china\\pack_sword_smash.ddj"),
		_group("257", "2", "UIIT_G2", "skillgroup\\china\\pack_sword_shield.ddj"),
		_group("257", "1", "UIIT_G1", "skillgroup\\china\\pack_sword_chain.ddj"),
		# Europe -- a china-only parse must drop it.
		_group("513", "0", "UIIT_EU", "skillgroup\\europe\\pack_eu.ddj"),
	])
	var groups := SkillDataReader.parse_groups(("\n".join(rows) + "\n").to_utf16_buffer())
	_check(groups.has(257) and not groups.has(513),
		"china groups kept, europe dropped")
	if groups.has(257):
		var g: Array = groups[257]
		_check(g.size() == 3, "three groups for mastery 257 (got %d)" % g.size())
		_check(g[0].row == 0 and g[1].row == 1 and g[2].row == 2,
			"groups are ordered by row")
		_check(g[0].icon_path == "skillgroup\\china\\pack_sword_smash.ddj",
			"the group icon is the table's own path")

func _test_skills() -> void:
	var rows := PackedStringArray([
		# SMASH_A: two levels -> one base skill, max level 2, min req 5.
		_skill("174", "1", "257", "5", "0", "skill\\china\\sword_smash_a.ddj", "SN_SKILL_CH_SWORD_SMASH_A"),
		_skill("174", "2", "257", "7", "0", "skill\\china\\sword_smash_a.ddj", "SN_SKILL_CH_SWORD_SMASH_A"),
		# SMASH_B, same row.
		_skill("175", "1", "257", "27", "0", "skill\\china\\sword_smash_b.ddj", "SN_SKILL_CH_SWORD_SMASH_B"),
		# CHAIN_A, row 1.
		_skill("177", "1", "257", "7", "1", "skill\\china\\sword_chain_a.ddj", "SN_SKILL_CH_SWORD_CHAIN_A"),
		# A skill for a mastery the caller did not ask for -> dropped.
		_skill("900", "1", "999", "1", "0", "skill\\x.ddj", "SN_SKILL_CH_OTHER"),
		# The ungrouped basic attack (row 255) -> dropped from the grid.
		_skill("173", "1", "257", "0", "255", "skill\\basic.ddj", "SN_SKILL_CH_BASIC"),
	])
	var grid := SkillDataReader.parse_skills(
		[("\n".join(rows) + "\n").to_utf16_buffer()], PackedInt32Array([257, 258]))
	_check(grid.has("257:0") and grid.has("257:1"), "rows keyed by mastery:row")
	_check(not grid.has("257:255"), "the ungrouped row 255 is dropped")
	_check(not grid.has("999:0"), "a mastery the caller did not ask for is dropped")
	if grid.has("257:0"):
		var r0: Array = grid["257:0"]
		_check(r0.size() == 2, "row 0 has two base skills, levels collapsed (got %d)" % r0.size())
		if r0.size() == 2:
			_check(r0[0].base_id == 174 and r0[0].column == 0
				and r0[1].base_id == 175 and r0[1].column == 1,
				"columns are assigned by base-id order")
			_check(r0[0].max_level == 2, "max level aggregates across a skill's levels")
			_check(r0[0].min_req_mastery_level == 5,
				"min required mastery level aggregates across levels")
			_check(r0[0].first_level_id == 174 * 100 + 1,
				"first_level_id is the level-1 row's unique id (got %d)" % r0[0].first_level_id)
			_check(r0[0].level_ids.size() == 2
				and r0[0].level_ids[0] == 174 * 100 + 1
				and r0[0].level_ids[1] == 174 * 100 + 2,
				"level_ids holds each level's unique id in order")
			_check(r0[0].level_reqs.size() == 2
				and r0[0].level_reqs[0] == 5 and r0[0].level_reqs[1] == 7,
				"level_reqs holds each level's required mastery level")
			_check(r0[0].level_sp.size() == 2
				and r0[0].level_sp[0] == 10 and r0[0].level_sp[1] == 20,
				"level_sp holds each level's learn SP cost")
			_check(r0[0].level_mp.size() == 2
				and r0[0].level_mp[0] == 5 and r0[0].level_mp[1] == 10,
				"level_mp holds each level's cast MP cost")
			_check(r0[0].cast_time_ms == 400 and r0[0].cooldown_ms == 3000
				and r0[0].range_val == 0,
				"cast time / cooldown / range are the skill's constants")
			_check(r0[0].desc_code == "SN_SKILL_CH_SWORD_SMASH_A_TT",
				"desc_code is the tooltip description token")
			_check(r0[0].level_prereqs.size() == 2 and (r0[0].level_prereqs[0] as Array).is_empty()
				and (r0[0].level_prereqs[1] as Array).size() == 1
				and int(r0[0].level_prereqs[1][0][0]) == 174 and int(r0[0].level_prereqs[1][0][1]) == 9,
				"level_prereqs holds each level's (group, level) prerequisites (got %s)" % str(r0[0].level_prereqs))
			_check(r0[0].cast_anim_name() == "skill_ch_sword_smash_a",
				"cast_anim_name lowercases Basic_Code and drops the level suffix (got %s)" % r0[0].cast_anim_name())

## Range kept per level, and the two targeting bytes the skill tick reads.
## The shapes are the real ones, synthetic values: a SKILL_CH_BOW_SPECIAL-like
## skill whose Range rises 2 a level (204, 206), a self-cast skill with
## Target_Required 0 (the SKILL_CH_WATER_SELFHEAL shape), and a land-targeted
## one (the SKILL_CH_LIGHTNING_GYEONGGONG_B/D shape).
func _test_level_range_and_targeting() -> void:
	var bow1 := _skill("467", "1", "258", "1", "0", "skill\\china\\bow_special_a.ddj", "SN_SKILL_CH_BOW_SPECIAL_A").split("\t")
	var bow2 := _skill("467", "2", "258", "3", "0", "skill\\china\\bow_special_a.ddj", "SN_SKILL_CH_BOW_SPECIAL_A").split("\t")
	bow1[SkillDataReader.S_RANGE] = "204"
	bow2[SkillDataReader.S_RANGE] = "206"
	var heal := _skill("600", "1", "276", "1", "1", "skill\\china\\water_selfheal.ddj", "SN_SKILL_CH_WATER_SELFHEAL_A").split("\t")
	heal[SkillDataReader.S_TARGET_REQUIRED] = "0"
	var land := _skill("700", "1", "274", "1", "2", "skill\\china\\lightning_gyeonggong.ddj", "SN_SKILL_CH_LIGHTNING_GYEONGGONG_B").split("\t")
	land[SkillDataReader.S_TARGET_LAND] = "1"
	var rows := PackedStringArray(["\t".join(bow1), "\t".join(bow2), "\t".join(heal), "\t".join(land)])
	var grid := SkillDataReader.parse_skills(
		[("\n".join(rows) + "\n").to_utf16_buffer()], PackedInt32Array([258, 274, 276]))
	if not (grid.has("258:0") and grid.has("276:1") and grid.has("274:2")):
		_check(false, "the three synthetic skills parse (got %s)" % str(grid.keys()))
		return
	var bow: SkillDataReader.BaseSkill = grid["258:0"][0]
	_check(bow.level_range.size() == 2 and bow.level_range[0] == 204 and bow.level_range[1] == 206,
		"level_range keeps each level's Range (got %s)" % str(bow.level_range))
	_check(bow.range_val == 204, "range_val stays the level-1 Range (got %d)" % bow.range_val)
	_check(bow.level_target_required[0] == 1 and bow.level_target_required[1] == 1
		and bow.level_target_land[0] == 0,
		"a targeted skill reads Target_Required 1, TargetType_Land 0")
	var self_heal: SkillDataReader.BaseSkill = grid["276:1"][0]
	_check(self_heal.level_target_required.size() == 1 and self_heal.level_target_required[0] == 0,
		"a self heal reads Target_Required 0 (col 22)")
	var ghost: SkillDataReader.BaseSkill = grid["274:2"][0]
	_check(ghost.level_target_required[0] == 1 and ghost.level_target_land[0] == 1,
		"a land-targeted skill reads TargetType_Land 1 (col 24)")
