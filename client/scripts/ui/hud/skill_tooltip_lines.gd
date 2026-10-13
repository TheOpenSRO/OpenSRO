extends RefCounted
class_name SkillTooltipLines

## The lines of a skill's hover tooltip, composed as the original composes
## them (round 786; docs/protocol/skill_tooltip.md). The rows are
## ItemTooltipLines' shape -- {"text", "color", "bold", "icon"} -- and are
## drawn by the same window, ItemTooltipBubble (CNIFHelperBubbleWindow), so a
## skill shows the blue com_tooltip frame the items do instead of Godot's
## native tooltip.
##
## READ, sro_client.exe: CIFSlotWithHelp::vslot_048 (0x686db0) builds a slot's
## help; a slot of the skill window (window kind 0x49, set on the skill slot at
## 0x6a09e5) and a quick slot holding a skill (kind 0x0c, its content kind
## 0x19 set at 0x60ec5d) both go to UI_SILKMALL 0x67a970, which writes:
##
##   "%s %s %d\n " -- the name (the record's name code +0x124 through the
##       text manager, else +0x24), UIIT_STT_LEVEL_LV, the level (+0x60);
##       white, the name sign, font 3 (bold)  0x67aa64 / 0x67aaa5 / 0x67aae9 / 0x67aaf0
##   PARAM_PASSIVE_SKILL when +0x61 is 0, else PARAM_ACTIVE_SKILL; beige
##                                                       0x67ab54
##   the requirement text 0x96d7e0 fills (beige), when it has any:
##       PARAM_REQ_HP / PARAM_REQ_MP "%d" (+0x854 / +0x858, each when > 0),
##       PARAM_REQ_HP_RATIO / _MP_RATIO (+0x85c / +0x85e), then
##       "%s: %s\n" or "%s: %s, %s\n" of PARAM_REQ_WEAPON_TYPE and the one or
##       two weapon names (+0xd8 / +0xdc, 0xff = none), the names from
##       PARAM_WEAPON_* (2-6) and UIO_NEWCHAR_STT_EU_* (7-15)
##   the required-item line (0x96d7e0, UIIT_STT_EU_REQUIRE_ITEM / _ESSENTIAL_
##       ITEM), beige or red by the equipped item           -- OPEN here
##   the description: +0x15c's text when +0x170 (its length) is not 0; white
##   " " -- a blank row; white                         0x67ad81..0x67ad8e
##   the effect text 0x96e480 bit 2 fills (attack power, reach, the params'
##       lines through ICPlayer 0x960b50); beige          -- OPEN here
##   then, unless the slot's kind or content kind is 0x19 (the quick slot):
##     a level-1 skill not yet learned whose mastery is held:
##       PARAM_CONDITION_OF_LEARN (white, a sign: 0x7771e0), then the level's
##       conditions; or a learned skill below its last level (0x944940):
##       "\n " (0x67b054), PARAM_CONDITION_OF_NEXT_LEVEL, the next level's
##       conditions.
##
## The conditions (0x96d0e0, in this order), each a type and a value that
## 0x67a970 colours -- beige (0xffefdaa4) when the player has it, red
## (0xffff4a4a) when not:
##   1 "%s : %s Lv %d" -- PARAM_MASTERY_LEVEL, the mastery's name, its level
##       (+0x820); red below the held mastery level
##   2 / 3 "%s : %d" -- PARAM_STR / PARAM_INT (+0x824 / +0x828), when not 0
##       -- not parsed here (0 on player skills, round 781), OPEN
##   5 "%s%d : %s %s %d" -- PARAM_REQ_PREV_SKILL, its place in the list (from
##       1), the skill's name, UIIT_STT_LEVEL_LV, its level; red unless
##       known; a skill of this skill's own group is skipped (+0x778)
##   4 "%s : %d" -- PARAM_REQ_SP (+0x83c), when not 0; red above the points
##
## The record offsets map to skilldata columns by the record's layout
## (INFERRED, as round 781 mapped +0xf8 / +0xfc): +0x60 level (col 7), +0x61
## Basic_Activity (col 8, MEASURED 0 on every passive), +0xd8 / +0xdc
## ReqCast_Weapon1/2 (50 / 51), +0x124 the name (62), +0x15c the description
## (64: the name's 0x1c-byte string and one more after it), +0x820 / +0x83c /
## +0x858 the mastery level / SP / MP of the level (36 / 46 / 53).

const WHITE := ItemTooltipLines.WHITE
const BEIGE := ItemTooltipLines.BEIGE
const RED := ItemTooltipLines.RED

## The width the help's text box is given before every help is built (READ,
## 0x686db0: the box's slot 0x54(200, 1)); INFERRED to be its wrap width.
const WRAP_WIDTH := 200.0

## Weapon TypeID4 -> the key 0x96d7e0 names it with (READ, its switch at
## 0x96d7e0); the fallback words are MasteryReader.WEAPON_LABEL's
## (OURS), shown only when the text table lacks the key. Any other code
## prints "" (the switch's default). The switch is in 0x96d7e0.
const WEAPON_KEYS := {
	2: "PARAM_WEAPON_SWORD", 3: "PARAM_WEAPON_BLADE", 4: "PARAM_WEAPON_SPEAR",
	5: "PARAM_WEAPON_TBLADE", 6: "PARAM_WEAPON_BOW",
	7: "UIO_NEWCHAR_STT_EU_ONEHANDSWORD", 8: "UIO_NEWCHAR_STT_EU_TWOHANDSWORD",
	9: "UIO_NEWCHAR_STT_EU_DUELAXE", 10: "UIO_NEWCHAR_STT_EU_DARKSTAFF",
	11: "UIO_NEWCHAR_STT_EU_TWOHANDSTAFF", 12: "UIO_NEWCHAR_STT_EU_CROSSBOW",
	13: "UIO_NEWCHAR_STT_EU_DAGGER", 14: "UIO_NEWCHAR_STT_EU_HARP",
	15: "UIO_NEWCHAR_STT_EU_ONEHANDSTAFF",
}
## ReqCast_Weapon's "none" (READ, 0x96dc60 / 0x96dc70: `cmp [..], 0xff`).
const NO_WEAPON := 255

## The rows of skill `s` at `level` (the record the slot holds: the learned
## level, or level 1 for a skill not learned yet). `ctx`:
##   "text": Callable(key, fallback) -> String  (the UI text table)
##   "names": UiTextTable  (the skill names and descriptions)
##   "conditions": bool  (true for the skill window's slots; a quick slot's
##       tooltip stops after the effect text)
##   "learned": int  (the learned level, 0 for none)
##   "mastery_name": String, "mastery_level": int, "mastery_held": bool
##   "sp": int  (the player's skill points)
##   "skill_name_of": Callable(group_id) -> String
##   "skill_level_of": Callable(group_id) -> int  (the learned level of that skill)
static func compose(s: SkillDataReader.BaseSkill, level: int, ctx: Dictionary) -> Array:
	var lines: Array = []
	if s == null:
		return lines
	var t: Callable = ctx.get("text", func(_k, f): return f)
	var names: UiTextTable = ctx.get("names", null)
	var lv_word: String = t.call("UIIT_STT_LEVEL_LV", "Lv")
	level = maxi(level, 1)
	# "%s %s %d\n ": the name row, then the " " row it ends with.
	_add(lines, "%s %s %d" % [name_of(s, names), lv_word, level], WHITE, true, true)
	_add(lines, " ", WHITE, true)
	_add(lines, t.call("PARAM_PASSIVE_SKILL", "Passive") if s.activity == 0 else t.call("PARAM_ACTIVE_SKILL", "Active"), BEIGE)
	for row in requirement_rows(s, level, t):
		_add(lines, row, BEIGE)
	var desc := s.description(names)
	if desc != "":
		for row in ItemTooltipLines.sml2_rows(desc, WHITE):
			var r: Dictionary = row
			r["icon"] = false
			lines.append(r)
	_add(lines, " ", WHITE)
	if not bool(ctx.get("conditions", false)):
		return lines
	var learned := int(ctx.get("learned", 0))
	if learned <= 0:
		if not bool(ctx.get("mastery_held", true)):
			return lines
		_add(lines, t.call("PARAM_CONDITION_OF_LEARN", "Acquisition condition"), WHITE, false, true)
		lines.append_array(condition_rows(s, 1, ctx, t))
	elif learned < s.max_level:
		# "\n%s" of L" " (0x67b054): an empty row and a " " row (INFERRED:
		# the text box breaks an added string at its "\n").
		_add(lines, "", WHITE)
		_add(lines, " ", WHITE)
		_add(lines, t.call("PARAM_CONDITION_OF_NEXT_LEVEL", "Next level condition"), WHITE, false, true)
		lines.append_array(condition_rows(s, learned + 1, ctx, t))
	return lines

## The name the tooltip heads with: the name code's text, else the record's
## code (READ: 0x67aaa5 falls back to +0x24 when the text is empty; the
## Basic_Code here, INFERRED).
static func name_of(s: SkillDataReader.BaseSkill, names: UiTextTable) -> String:
	var nm := s.display_name(names)
	if (nm == s.name_code or nm == "") and s.basic_code != "":
		return s.basic_code
	return nm

## 0x96d7e0's rows for one level: the MP cost, then the weapon line. The HP
## cost and the two ratio costs are not parsed by SkillDataReader (OPEN).
static func requirement_rows(s: SkillDataReader.BaseSkill, level: int, t: Callable) -> PackedStringArray:
	var out := PackedStringArray()
	var mp := _at(s.level_mp, level)
	if mp > 0:
		out.append(_fmt(t.call("PARAM_REQ_MP", "Consumed MP: %d"), mp))
	var w := weapon_row(s.req_weapon_1, s.req_weapon_2, t)
	if w != "":
		out.append(w)
	return out

## "%s: %s" / "%s: %s, %s" (READ, 0x96d7e0 after 0x96dc60); "" when the first
## weapon is none.
static func weapon_row(w1: int, w2: int, t: Callable) -> String:
	if w1 == NO_WEAPON:
		return ""
	var label: String = t.call("PARAM_REQ_WEAPON_TYPE", "Used weapon")
	if w2 == NO_WEAPON:
		return "%s: %s" % [label, weapon_name(w1, t)]
	return "%s: %s, %s" % [label, weapon_name(w1, t), weapon_name(w2, t)]

static func weapon_name(code: int, t: Callable) -> String:
	if not WEAPON_KEYS.has(code):
		return ""
	return t.call(WEAPON_KEYS[code], String(MasteryReader.WEAPON_LABEL.get(code, "")))

## The conditions of `level` (0x96d0e0), each coloured as 0x67a970 colours it.
static func condition_rows(s: SkillDataReader.BaseSkill, level: int, ctx: Dictionary, t: Callable) -> Array:
	var out: Array = []
	var lv_word: String = t.call("UIIT_STT_LEVEL_LV", "Lv")
	var need_m := _at(s.level_reqs, level)
	var have_m := int(ctx.get("mastery_level", 0))
	# The format's own "Lv" is a literal (READ, 0x96d19a's "%s : %s Lv %d").
	_add(out, "%s : %s Lv %d" % [t.call("PARAM_MASTERY_LEVEL", "Mastery level"), String(ctx.get("mastery_name", "")), need_m],
		RED if have_m < need_m else BEIGE)
	var prereqs: Array = s.level_prereqs[level - 1] if level - 1 < s.level_prereqs.size() else []
	var name_of_skill: Callable = ctx.get("skill_name_of", func(g): return "%d" % int(g))
	var level_of_skill: Callable = ctx.get("skill_level_of", func(_g): return 0)
	for i in prereqs.size():
		var group := int(prereqs[i][0])
		var need := int(prereqs[i][1])
		if group == s.base_id:
			continue
		var have := int(level_of_skill.call(group))
		_add(out, "%s%d : %s %s %d" % [t.call("PARAM_REQ_PREV_SKILL", "Required skill"), i + 1,
			String(name_of_skill.call(group)), lv_word, need], BEIGE if have >= need else RED)
	var sp := _at(s.level_sp, level)
	if sp != 0:
		_add(out, "%s : %d" % [t.call("PARAM_REQ_SP", "Required skillpoint"), sp],
			RED if int(ctx.get("sp", 0)) < sp else BEIGE)
	return out

static func _at(values, level: int) -> int:
	var i := level - 1
	return int(values[i]) if i >= 0 and i < values.size() else 0

## A one-argument printf of the client's "%d" texts.
static func _fmt(fmt: String, value: int) -> String:
	return fmt.replace("%d", str(value)) if fmt.contains("%d") else "%s %d" % [fmt, value]

static func _add(lines: Array, text: String, colour: Color, bold: bool = false, icon: bool = false) -> void:
	lines.append({"text": text, "color": colour, "bold": bold, "icon": icon})
