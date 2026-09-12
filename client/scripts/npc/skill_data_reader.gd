extends RefCounted
class_name SkillDataReader

## Reads the skill tree the way the real client's CIFSkillBoard does, from the
## player's own Media.pk2 -- `skillgroup.txt` (the rows) and `skilldata_*.txt`
## (the skills in each row). Recovered 2026-09-12 from the pserver client's
## resinfo layouts and a decompile of CIFSkillBoard/CIFSkillGroup/CIFSkillSlot
## (see the skill-window-layout note): a mastery's skill board is one BAR per
## skill group, and each bar holds the group's skills laid left to right in
## columns. China only for now.
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
const S_LEVEL := 7
# Cast timing / cost / range, verified against SMASH_A (see the skilldata-columns
# note): all in ms except Range. CastTime/ReuseDelay/Range are constant per skill;
# ReqSP and ConsumeMP rise per level.
const S_CAST_TIME := 12
const S_REUSE_DELAY := 14         # the cooldown
const S_RANGE := 21               # 0 = melee
const S_MASTERY := 34
const S_REQ_MASTERY_LEVEL := 36
const S_REQ_SP := 46              # SP to learn this level
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
	## Cast timing / range, constant across a skill's levels (verified for SMASH_A):
	## cast time and cooldown in ms, range in game units (0 = melee), and the
	## tooltip description code resolved through the UI text table.
	var cast_time_ms: int
	var cooldown_ms: int
	var range_val: int
	var desc_code: String
	## Accumulator during parse: level -> [unique_id, req_mastery_level, sp, mp].
	## Folded into the level_* arrays once every row is seen; not used after that.
	var _levels: Dictionary = {}

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

## Parses skillgroup.txt into mastery_id -> Array[SkillGroup] ordered by row.
## Only China groups (pack icon under `china\`) are kept, so a partial archive
## still yields what it has.
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
		if not low.contains("china\\") and not low.contains("china/"):
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
			# Cheap reject before the tab split: China mastery skills are the
			# only ones with this code, and they are a fraction of the file.
			if not line.contains("SKILL_CH_"):
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
			if by_base.has(base_id):
				var existing: BaseSkill = by_base[base_id]
				existing.max_level = maxi(existing.max_level, level)
				if req > 0:
					existing.min_req_mastery_level = mini(existing.min_req_mastery_level, req) \
						if existing.min_req_mastery_level > 0 else req
				if level == 1:
					existing.first_level_id = unique_id
				if level >= 1:
					existing._levels[level] = [unique_id, req, sp, mp]
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
					s._levels[level] = [unique_id, req, sp, mp]
				by_base[base_id] = s
			var bs: BaseSkill = by_base[base_id]
			if bs.cast_time_ms == 0 and bs.cooldown_ms == 0 and bs.range_val == 0 and bs.desc_code == "":
				bs.cast_time_ms = _int_at(cols, S_CAST_TIME)
				bs.cooldown_ms = _int_at(cols, S_REUSE_DELAY)
				bs.range_val = _int_at(cols, S_RANGE)
				bs.desc_code = cols[S_TOOLTIP_DESC].strip_edges() if cols.size() > S_TOOLTIP_DESC else ""
			if level == 1:
				bs.cast_time_ms = _int_at(cols, S_CAST_TIME)
				bs.cooldown_ms = _int_at(cols, S_REUSE_DELAY)
				bs.range_val = _int_at(cols, S_RANGE)
				bs.desc_code = cols[S_TOOLTIP_DESC].strip_edges() if cols.size() > S_TOOLTIP_DESC else ""

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
	for lv in s._levels:
		var info: Array = s._levels[lv]
		s.level_ids[int(lv) - 1] = int(info[0])
		s.level_reqs[int(lv) - 1] = int(info[1])
		s.level_sp[int(lv) - 1] = int(info[2])
		s.level_mp[int(lv) - 1] = int(info[3])

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
