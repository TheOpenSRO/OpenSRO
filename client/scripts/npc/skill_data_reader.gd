extends RefCounted
class_name SkillDataReader

## Reads the skill tree the way the real client's CIFSkillBoard does, from the
## player's own Media.pk2 -- `skillgroup.txt` (the rows) and `skilldata_*.txt`
## (the skills in each row). Recovered 2026-09-12 from the pserver client's
## resinfo layouts and a decompile of CIFSkillBoard/CIFSkillGroup/CIFSkillSlot
## (see the skill-window-layout note): a mastery's skill board is one BAR per
## skill group, and each bar holds the group's skills laid left to right in
## columns. China and, since round 691, Europe (masteries 513-518, group
## icons under `skillgroup\europe\`, skills SKILL_EU_*).
##
## skillgroup.txt (UTF-16, tab separated, 0-indexed):
##   [2] MasteryID   [4] Row (the bar's order in the board)
##   [5] DescCode (a UIIT_ token)   [6] group pack icon (skillgroup\china\pack_*.ddj)
##
## skilldata_*.txt (UTF-16, 119 columns, 0-indexed):
##   [2] base skill id (shared by every level of the skill)
##   [7] level   [34] mastery id   [36] required mastery level (rises per level)
##   [59] group row (== skillgroup Row; 255 = ungrouped, e.g. the basic attack)
##   [61] icon (skill\china\*.ddj)   [62] name code (SN_SKILL_*)

const GROUP_TABLE := "server_dep\\silkroad\\textdata\\skillgroup.txt"

## The skilldata files that carry China mastery skills, measured against the
## pserver archive. The client splits skilldata across many files; only these
## hold player-mastery (257-259, 273-276) skills.
const SKILL_TABLES := [
	"server_dep\\silkroad\\textdata\\skilldata_1000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_5000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_10000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_25000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_30000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_35000.txt",
]

## The skilldata files that carry Europe mastery (513-518) skills (round 691).
## MEASURED on the render box's Media.pk2: the 3,242 Service-1 rows of a Europe
## mastery have 3,242 distinct ids spread over eleven files, and these six
## cover every one -- 15000 (1,732), 10000 (1,362), 35000 (83), then 9000,
## 12000 and 22000 for the last 65 (a greedy cover; 11000, 25000, 31000,
## 32000 and 36000 add none). Listed in the index's numeric order, which is
## the order the client loads them in (skilldata.txt).
const EUROPE_SKILL_TABLES := [
	"server_dep\\silkroad\\textdata\\skilldata_9000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_10000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_12000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_15000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_22000.txt",
	"server_dep\\silkroad\\textdata\\skilldata_35000.txt",
]

## The files a race's skill board reads (MasteryReader.RACE_*).
static func tables_for_race(race: int) -> Array:
	return EUROPE_SKILL_TABLES if race == 1 else SKILL_TABLES

## Both races' files once each, in the index's numeric order -- for the
## tables that must know every player skill (cast sounds, effects).
static func all_tables() -> Array:
	var out: Array = []
	for p in SKILL_TABLES + EUROPE_SKILL_TABLES:
		if not out.has(p):
			out.append(p)
	out.sort_custom(func(a, b): return SkillDataReader._table_number(a) < SkillDataReader._table_number(b))
	return out

static func _table_number(path: String) -> int:
	var at := path.rfind("skilldata_")
	var digits := path.substr(at + 10).trim_suffix(".txt") if at >= 0 else ""
	return int(digits) if digits.is_valid_int() else 0

## The client pads every group row out to this many skill columns with the
## `skl_mastery_nothing.ddj` empty slot (CIFSkillGroup loops while x < 0x145,
## x = col*0x24 + 0x25, so columns 0..7).
const COLUMNS := 8

const G_MASTERY := 2
const G_ROW := 4
const G_NAME := 5
const G_ICON := 6

const S_UNIQUE_ID := 1
const S_BASE_ID := 2
const S_BASIC_CODE := 3          # SKILL_CH_..._NN -- names the cast .ban clip
const S_LEVEL := 7
# Cast timing / cost / range, verified against SMASH_A (see the skilldata-columns
# note): all in ms except Range. CastTime/ReuseDelay are constant per skill;
# ReqSP and ConsumeMP rise per level. Range varies by level in five skills
# (the box's skilldata tables, every row with a non-zero mastery grouped by
# GroupID; round 519 review, re-counted rounds 523 and 527;
# docs/RE_COMPLETION.md, round 523, "Range per level is constant for China
# skills only"). Four are China skills, SKILL_CH_BOW_SPECIAL_A..D (bases
# 467-470), which rise 2 a level: 204->214, 218->228, 228->238 and 240->244.
# The fifth is a Europe skill, SKILL_EU_WARRIOR_FRENZYA_TOUNT_SPRINT_A (group
# 540, ids 8479-8499), 80 -> 240. Every other China skill keeps one Range
# across its levels. This reader keeps Range per level (level_range), so the
# four bow skills and -- since round 691 reads SKILL_EU_ rows too -- the
# Europe sprint carry each level's own.
const S_CAST_TIME := 12
const S_REUSE_DELAY := 14         # the cooldown
const S_RANGE := 21               # 0 = melee
# The two targeting bytes the skill tick reads before it computes a reach band
# (Tick_UseSkill 0x004ae590 phase 0, asm 0x4ae73b-0x4ae753;
# docs/protocol/auto_command.md, "The skill tick"): Target_Required
# (CRefSkill+0x94) and TargetType_Land (+0x96). Their columns follow the
# copy order of CRefSkill::CopyFixedColumns 0x6ab5a0
# (docs/protocol/skill_fields.md, "The fixed columns"): Range +0x92 is
# column 21, Target_Required +0x94 column 22 (the exporter's
# skTargetRequired), TargetType_Animal +0x95 column 23, TargetType_Land +0x96
# column 24. Measured on the box's tables: Target_Required is 0 on every
# SKILL_CH_WATER_SELFHEAL row and 1 on every SKILL_CH_WATER_HEAL row, and
# TargetType_Land is 1 only on the 19 SKILL_CH_LIGHTNING_GYEONGGONG_B/D rows
# among the 2,185 China board rows.
const S_TARGET_REQUIRED := 22
const S_TARGET_LAND := 24
## TargetType_Animal (23), _Building (25) and TargetGroup_Self / _Ally /
## _Party (26-28), round 622: whether a Target_Required 1 row is aimed at a
## friend (a heal, a party buff) and whether retail refuses it with nothing
## selected (the client's 0x3011 test, FUN_0081ba10 0x81be5e: Target_Required,
## Animal, no Land, no Building -- SelfCast.plan).
const S_TARGET_ANIMAL := 23
const S_TARGET_BUILDING := 25
const S_TARGET_SELF := 26
const S_TARGET_ALLY := 27
const S_TARGET_PARTY := 28
const S_MASTERY := 34
const S_REQ_MASTERY_LEVEL := 36
# The learn prerequisites: up to three (skill GROUP id, level) pairs a level
# needs known first -- skilldata ReqLearn_Skill1..3 / ReqLearn_SkillLevel1..3.
# Verified 2026-09-19 on SKILL_CH_SWORD_SMASH_B_01: 174 (the A series) at 9.
const S_REQ_SKILL_1 := 40
const S_REQ_SKILL_2 := 41
const S_REQ_SKILL_3 := 42
const S_REQ_SKILL_LEVEL_1 := 43
const S_REQ_SKILL_LEVEL_2 := 44
const S_REQ_SKILL_LEVEL_3 := 45
const S_REQ_SP := 46              # SP to learn this level
# ReqCast_Weapon1/2 (round 691): the itemdata TypeID4 codes the skill may be
# cast with, 255 = unused (the skilldata-columns note; the server's
# refdata.Skill.ReqCastWeapon1/2 and combat.SkillAllowsWeapon).
const S_REQ_WEAPON_1 := 50
const S_REQ_WEAPON_2 := 51
const S_CONSUME_MP := 53
const S_GROUP_ROW := 59
const S_ICON := 61
const S_NAME := 62
const S_TOOLTIP_DESC := 64        # SN_..._TT_DESC, resolved via the UI text table

## One bar (row) of a mastery's board.
class SkillGroup:
	var mastery_id: int
	var row: int
	## The UIIT_ token naming the group, resolved through the UI text table.
	var name_code: String
	## The group's pack icon, `skillgroup\china\pack_*.ddj`, drawn at the row's left.
	var icon_path: String

## One skill in a group -- a column in that group's row. A skill spans several
## levels; this is the skill itself, with the span the archive gives it.
class BaseSkill:
	var base_id: int
	var mastery_id: int
	var group_row: int
	## 0-based position in the row, assigned by base-id order within the group.
	var column: int
	var icon_path: String
	var name_code: String
	## The mastery level at which level 1 of this skill becomes learnable -- the
	## lowest required-mastery-level across its levels. The board greys a skill
	## (skl_mastery_disable.ddj) until the mastery reaches this.
	var min_req_mastery_level: int
	var max_level: int
	## The unique per-level skill id of this skill's level 1 -- the id the "+"
	## learn button sends. 0 if the archive carries no level-1 row for it.
	var first_level_id: int
	## Every level's unique skill id, index i = level i+1's id (0 for a level the
	## archive is missing). The "+" button sends the next unlearned level's id.
	var level_ids: PackedInt64Array = PackedInt64Array()
	## Every level's required mastery level, aligned with level_ids -- a level
	## becomes learnable when the mastery reaches level_reqs[level-1].
	var level_reqs: PackedInt32Array = PackedInt32Array()
	## SP to learn each level, aligned with level_ids (skilldata ReqLearn_SP).
	var level_sp: PackedInt32Array = PackedInt32Array()
	## MP each level costs to cast, aligned with level_ids (skilldata Consume_MP).
	var level_mp: PackedInt32Array = PackedInt32Array()
	## Each level's learn prerequisites, aligned with level_ids: an Array of
	## [group_id, level] pairs (skilldata ReqLearn_Skill1..3 / SkillLevel1..3),
	## empty when the level needs nothing but its mastery level and SP.
	var level_prereqs: Array = []
	## Each level's Range (S_RANGE, world units, 0 = the weapon's), aligned with
	## level_ids -- what that level's cast is measured with. Among the China
	## skills this reader keeps, it differs from range_val only on the four
	## SKILL_CH_BOW_SPECIAL skills (see S_RANGE).
	var level_range: PackedInt32Array = PackedInt32Array()
	## ReqCast_Weapon1/2 of level 1 (skilldata columns 50/51, round 691): the
	## TypeID4s the skill is cast with; 255 or 0 = no requirement in that slot.
	var req_weapon_1: int = 255
	var req_weapon_2: int = 255
	## Each level's Target_Required (S_TARGET_REQUIRED) and TargetType_Land
	## (S_TARGET_LAND), aligned with level_ids: whether the skill tick walks
	## into reach before the cast (CombatNet.skill_tick_approaches).
	var level_target_required: PackedInt32Array = PackedInt32Array()
	var level_target_land: PackedInt32Array = PackedInt32Array()
	## Each level's target groups (round 622), aligned with level_ids: bit 0
	## TargetType_Animal, 1 _Building, 2 TargetGroup_Self, 3 _Ally, 4 _Party
	## (TARGET_BIT_*).
	var level_target_groups: PackedInt32Array = PackedInt32Array()
	## Cast timing / range as the level-1 row gives them: cast time and
	## cooldown in ms (constant across levels, verified for SMASH_A), range in
	## game units (0 = melee; constant but for four China skills -- level_range
	## has every level's), and the tooltip description code resolved through the UI
	## text table.
	var cast_time_ms: int
	var cooldown_ms: int
	var range_val: int
	var desc_code: String
	## The skill's Basic_Code (SKILL_CH_..._NN). The cast animation clip is named
	## after it (see cast_anim_name / the skill-animations note).
	var basic_code: String
	## Accumulator during parse: level -> [unique_id, req_mastery_level, sp, mp,
	## prereqs, range, target_required, target_land].
	## Folded into the level_* arrays once every row is seen; not used after that.
	var _levels: Dictionary = {}

	## The cast animation clip's base name: the Basic_Code lowercased with the
	## trailing "_NN" level suffix removed, e.g. SKILL_CH_SWORD_SMASH_A_01 ->
	## "skill_ch_sword_smash_a". "" if the skill has no Basic_Code. The clip
	## lives at Prim\Ani\Char\<China|Europe>\<gender>\<this>.ban in Data.pk2
	## (cast_clip_path).
	func cast_anim_name() -> String:
		if basic_code == "":
			return ""
		var lower := basic_code.to_lower()
		var us := lower.rfind("_")
		if us > 0 and lower.substr(us + 1).is_valid_int():
			return lower.substr(0, us)
		return lower

	## The skill's tooltip description, resolved through the UI text table (like
	## display_name); "" when the archive carries none.
	func description(names: UiTextTable) -> String:
		if names != null and desc_code != "" and desc_code != "xxx":
			var resolved := names.get_text(desc_code)
			if resolved != "" and resolved != desc_code:
				return resolved
		return ""

	func display_name(names: UiTextTable) -> String:
		if names != null and name_code != "" and name_code != "xxx":
			var resolved := names.get_text(name_code)
			if resolved != "" and resolved != name_code:
				return resolved
		return name_code if name_code != "" else "Skill %d" % base_id

	## The weapon types a skill is cast with (ReqCast_Weapon1/2), as labels:
	## "" when neither slot names one (255 or 0). The labels are
	## MasteryReader.WEAPON_LABEL's (OURS words for READ codes); 1 is the bare hand.
	func weapon_requirement() -> String:
		var out := PackedStringArray()
		for code in [req_weapon_1, req_weapon_2]:
			if code <= 0 or code == 255:
				continue
			out.append("Bare hand" if code == 1 else String(MasteryReader.WEAPON_LABEL.get(code, "weapon type %d" % code)))
		return " or ".join(out)

## The Data.pk2 path of a skill's name-matched cast clip for a body
## (round 691): `Prim\Ani\Char\<Race>\<man|woman>\<anim_base>.ban`, the race
## directory from the character's gender string ("europe_man" ->
## `Europe\man`; any other -> `China`). MEASURED on the render box's Data.pk2:
## `Prim\Ani\Char\Europe\man` holds 122 clips and `...\woman` 119, 228 of
## them `skill_eu_*`; but only 33 of the 284 Europe board skills have a clip
## named after their Basic_Code -- retail picks a Europe cast's body motion
## through skilleffect.txt's aniset (ANI_SKILL_n in the row's AniGroup) in the
## body's .bsr, which is the per-body clip lookup of the world lane (OPEN
## here). Pure, so the world can adopt or replace it.
static func cast_clip_path(gender: String, anim_base: String) -> String:
	var race_dir := "Europe" if gender.begins_with("europe") else "China"
	var sex_dir := "woman" if gender.ends_with("woman") else "man"
	return "Prim\\Ani\\Char\\%s\\%s\\%s.ban" % [race_dir, sex_dir, anim_base]

## Parses skillgroup.txt into mastery_id -> Array[SkillGroup] ordered by row.
## Only the player races' groups (pack icon under `china\` or `europe\`) are
## kept, so a partial archive still yields what it has.
static func parse_groups(data: PackedByteArray) -> Dictionary:
	var by_mastery: Dictionary = {}
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= G_ICON:
			continue
		var icon := cols[G_ICON].strip_edges()
		var low := icon.to_lower()
		if not (low.contains("china\\") or low.contains("china/") or low.contains("europe\\") or low.contains("europe/")):
			continue
		var mastery_text := cols[G_MASTERY].strip_edges()
		if not mastery_text.is_valid_int():
			continue
		var g := SkillGroup.new()
		g.mastery_id = int(mastery_text)
		g.row = _int_at(cols, G_ROW)
		g.name_code = cols[G_NAME].strip_edges()
		g.icon_path = icon.replace("/", "\\")
		if not by_mastery.has(g.mastery_id):
			by_mastery[g.mastery_id] = []
		by_mastery[g.mastery_id].append(g)
	for mid in by_mastery:
		by_mastery[mid].sort_custom(func(a, b): return a.row < b.row)
	return by_mastery

## Parses the skilldata files into "<mastery>:<row>" -> Array[BaseSkill], each
## array ordered by base id and given sequential column indices. `mastery_ids`
## limits the scan to the player's masteries; rows for other owners (monsters,
## NPCs) and the ungrouped basic attack (row 255) are dropped.
static func parse_skills(datas: Array, mastery_ids: PackedInt32Array) -> Dictionary:
	var want: Dictionary = {}
	for mid in mastery_ids:
		want[mid] = true
	# base_id -> BaseSkill, so a skill's many level rows collapse to one entry.
	var by_base: Dictionary = {}
	for data in datas:
		if data == null or (data is PackedByteArray and data.is_empty()):
			continue
		for line in _lines(data):
			# Cheap reject before the tab split: player mastery skills are the
			# only ones with these codes, and they are a fraction of the file.
			if not line.contains("SKILL_CH_") and not line.contains("SKILL_EU_"):
				continue
			var cols := line.split("\t")
			if cols.size() <= S_NAME:
				continue
			var mastery := _int_at(cols, S_MASTERY)
			if not want.has(mastery):
				continue
			var row := _int_at(cols, S_GROUP_ROW)
			if row < 0 or row >= 250:
				continue
			var base_id := _int_at(cols, S_BASE_ID)
			if base_id <= 0:
				continue
			var level := _int_at(cols, S_LEVEL)
			var req := _int_at(cols, S_REQ_MASTERY_LEVEL)
			var unique_id := _int_at(cols, S_UNIQUE_ID)
			var sp := _int_at(cols, S_REQ_SP)
			var mp := _int_at(cols, S_CONSUME_MP)
			var prereqs: Array = []
			for pair in [[S_REQ_SKILL_1, S_REQ_SKILL_LEVEL_1], [S_REQ_SKILL_2, S_REQ_SKILL_LEVEL_2], [S_REQ_SKILL_3, S_REQ_SKILL_LEVEL_3]]:
				var g := _int_at(cols, pair[0])
				if g > 0:
					prereqs.append([g, _int_at(cols, pair[1])])
			var level_info: Array = [unique_id, req, sp, mp, prereqs, _int_at(cols, S_RANGE),
				_int_at(cols, S_TARGET_REQUIRED), _int_at(cols, S_TARGET_LAND), target_groups(cols)]
			if by_base.has(base_id):
				var existing: BaseSkill = by_base[base_id]
				existing.max_level = maxi(existing.max_level, level)
				if req > 0:
					existing.min_req_mastery_level = mini(existing.min_req_mastery_level, req) \
						if existing.min_req_mastery_level > 0 else req
				if level == 1:
					existing.first_level_id = unique_id
				if level >= 1:
					existing._levels[level] = level_info
			else:
				var s := BaseSkill.new()
				s.base_id = base_id
				s.mastery_id = mastery
				s.group_row = row
				s.icon_path = cols[S_ICON].strip_edges().replace("/", "\\")
				s.name_code = cols[S_NAME].strip_edges()
				s.min_req_mastery_level = req
				s.max_level = level
				if level == 1:
					s.first_level_id = unique_id
				if level >= 1:
					s._levels[level] = level_info
				by_base[base_id] = s
			var bs: BaseSkill = by_base[base_id]
			if bs.cast_time_ms == 0 and bs.cooldown_ms == 0 and bs.range_val == 0 and bs.desc_code == "":
				bs.cast_time_ms = _int_at(cols, S_CAST_TIME)
				bs.cooldown_ms = _int_at(cols, S_REUSE_DELAY)
				bs.range_val = _int_at(cols, S_RANGE)
				bs.desc_code = cols[S_TOOLTIP_DESC].strip_edges() if cols.size() > S_TOOLTIP_DESC else ""
				bs.basic_code = cols[S_BASIC_CODE].strip_edges() if cols.size() > S_BASIC_CODE else ""
			if level == 1:
				bs.req_weapon_1 = _int_at(cols, S_REQ_WEAPON_1)
				bs.req_weapon_2 = _int_at(cols, S_REQ_WEAPON_2)
				bs.cast_time_ms = _int_at(cols, S_CAST_TIME)
				bs.cooldown_ms = _int_at(cols, S_REUSE_DELAY)
				bs.range_val = _int_at(cols, S_RANGE)
				bs.desc_code = cols[S_TOOLTIP_DESC].strip_edges() if cols.size() > S_TOOLTIP_DESC else ""
				bs.basic_code = cols[S_BASIC_CODE].strip_edges() if cols.size() > S_BASIC_CODE else ""

	# Group by mastery:row, order by base id, assign columns.
	var grid: Dictionary = {}
	var bases: Array = by_base.values()
	bases.sort_custom(func(a, b): return a.base_id < b.base_id)
	for entry in bases:
		var s: BaseSkill = entry
		_finalize_levels(s)
		var key := "%d:%d" % [s.mastery_id, s.group_row]
		if not grid.has(key):
			grid[key] = []
		s.column = grid[key].size()
		grid[key].append(s)
	return grid

## Folds a skill's per-level accumulator into level_ids/level_reqs, indexed
## by level-1 (index 0 = level 1). Levels the archive is missing stay 0.
static func _finalize_levels(s: BaseSkill) -> void:
	var top := 0
	for lv in s._levels:
		top = maxi(top, int(lv))
	if top <= 0:
		return
	s.level_ids.resize(top)
	s.level_reqs.resize(top)
	s.level_sp.resize(top)
	s.level_mp.resize(top)
	s.level_prereqs.resize(top)
	s.level_range.resize(top)
	s.level_target_required.resize(top)
	s.level_target_land.resize(top)
	s.level_target_groups.resize(top)
	for i in range(top):
		s.level_prereqs[i] = []
	for lv in s._levels:
		var info: Array = s._levels[lv]
		s.level_ids[int(lv) - 1] = int(info[0])
		s.level_reqs[int(lv) - 1] = int(info[1])
		s.level_sp[int(lv) - 1] = int(info[2])
		s.level_mp[int(lv) - 1] = int(info[3])
		if info.size() > 4:
			s.level_prereqs[int(lv) - 1] = info[4]
		if info.size() > 7:
			s.level_range[int(lv) - 1] = int(info[5])
			s.level_target_required[int(lv) - 1] = int(info[6])
			s.level_target_land[int(lv) - 1] = int(info[7])
		if info.size() > 8:
			s.level_target_groups[int(lv) - 1] = int(info[8])

## The target-group bits of level_target_groups.
const TARGET_BIT_ANIMAL := 1
const TARGET_BIT_BUILDING := 2
const TARGET_BIT_SELF := 4
const TARGET_BIT_ALLY := 8
const TARGET_BIT_PARTY := 16

## A row's TargetType_Animal/_Building and TargetGroup_Self/_Ally/_Party as
## TARGET_BIT_* bits.
static func target_groups(cols: PackedStringArray) -> int:
	var bits := 0
	for pair in [[S_TARGET_ANIMAL, TARGET_BIT_ANIMAL], [S_TARGET_BUILDING, TARGET_BIT_BUILDING],
			[S_TARGET_SELF, TARGET_BIT_SELF], [S_TARGET_ALLY, TARGET_BIT_ALLY], [S_TARGET_PARTY, TARGET_BIT_PARTY]]:
		if _int_at(cols, int(pair[0])) != 0:
			bits |= int(pair[1])
	return bits

static func _int_at(cols: PackedStringArray, col: int) -> int:
	if col >= cols.size():
		return 0
	var text := cols[col].strip_edges()
	return int(text) if text.is_valid_int() else 0

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text.replace("\r", "").split("\n")
