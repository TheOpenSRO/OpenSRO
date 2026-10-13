extends SceneTree

## Round 786: a skill's hover tooltip as the original composes it
## (SkillTooltipLines, READ from UI_SILKMALL 0x67a970 / 0x96d7e0 / 0x96d0e0)
## and drawn in the original's window (ItemTooltipBubble), never Godot's
## native tooltip. Synthetic skills and text (never real game data):
##   godot4 --headless --path client --script res://scripts/ui/hud/skill_tooltip_lines_test.gd

const L := preload("res://scripts/ui/hud/skill_tooltip_lines.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Every key a stand-in English, so a row shows which key built it.
func _t(k: String, f: String) -> String:
	var known := {
		"UIIT_STT_LEVEL_LV": "Lv", "PARAM_ACTIVE_SKILL": "Active", "PARAM_PASSIVE_SKILL": "Passive",
		"PARAM_REQ_MP": "Consumed MP: %d", "PARAM_REQ_WEAPON_TYPE": "Used weapon",
		"PARAM_WEAPON_SWORD": "Sword", "PARAM_WEAPON_BLADE": "Blade",
		"PARAM_CONDITION_OF_LEARN": "Acquisition condition", "PARAM_CONDITION_OF_NEXT_LEVEL": "Next level condition",
		"PARAM_MASTERY_LEVEL": "Mastery level", "PARAM_REQ_PREV_SKILL": "Required skill",
		"PARAM_REQ_SP": "Required skillpoint",
	}
	return String(known.get(k, f))

## A three-level sword skill: ids 101..103, mastery 1 / 5 / 9, SP 2 / 10 / 20,
## MP 7 / 9 / 11; level 2 asks for skill group 50 at level 3, and for its own
## group (which the client skips).
func _skill() -> SkillDataReader.BaseSkill:
	var s := SkillDataReader.BaseSkill.new()
	s.base_id = 40
	s.mastery_id = 257
	s.name_code = "SN_SMASH"
	s.desc_code = "SN_SMASH_TT_DESC"
	s.basic_code = "SKILL_CH_SWORD_SMASH_A_01"
	s.activity = 2
	s.max_level = 3
	s.level_ids = PackedInt64Array([101, 102, 103])
	s.level_reqs = PackedInt32Array([1, 5, 9])
	s.level_sp = PackedInt32Array([2, 10, 20])
	s.level_mp = PackedInt32Array([7, 9, 11])
	s.level_prereqs = [[], [[40, 1], [50, 3]], []]
	s.req_weapon_1 = 2
	s.req_weapon_2 = 3
	return s

func _names() -> UiTextTable:
	return UiTextTable.parse(("1\tSN_SMASH\tፕ\t0\t0\t0\t0\t0\tStrike Smash\n"
		+ "1\tSN_SMASH_TT_DESC\tፕ\t0\t0\t0\t0\t0\t<sml2>Swing your sword.<br><font color=\"255,255,0,0\">Hot</font></sml2>\n").to_utf16_buffer())

func _ctx(learned: int, conditions: bool, mastery_level: int, sp: int, other_level: int) -> Dictionary:
	var name_of := func(g: int) -> String: return "Other %d" % g
	var level_of := func(_g: int) -> int: return other_level
	return {"text": Callable(self, "_t"), "names": _names(), "conditions": conditions, "learned": learned,
		"mastery_name": "Bicheon", "mastery_level": mastery_level, "mastery_held": true, "sp": sp,
		"skill_name_of": name_of, "skill_level_of": level_of}

func _texts(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		out.append(String(l["text"]))
	return out

func _initialize() -> void:
	var s := _skill()
	# A skill not learned, in the skill window (kind 0x49): level 1's record
	# and the acquisition conditions, all met.
	var a := L.compose(s, 1, _ctx(0, true, 4, 100, 0))
	var at := _texts(a)
	_check(at[0] == "Strike Smash Lv 1" and bool(a[0]["bold"]) and bool(a[0]["icon"]) and a[0]["color"] == L.WHITE,
		"the name row: \"%%s %%s %%d\" of the name, UIIT_STT_LEVEL_LV, the level; white, bold, the sign (got %s)" % at[0])
	_check(at[1] == " " and at[2] == "Active" and a[2]["color"] == L.BEIGE,
		"then the \" \" row and Active in beige (Basic_Activity 2; 0x67ab54) (got '%s', '%s')" % [at[1], at[2]])
	_check(at[3] == "Consumed MP: 7" and at[4] == "Used weapon: Sword, Blade" and a[4]["color"] == L.BEIGE,
		"the requirement rows: PARAM_REQ_MP, then \"%%s: %%s, %%s\" of the two weapons (0x96d7e0) (got %s / %s)" % [at[3], at[4]])
	_check(at[5] == "Swing your sword." and at[6] == "Hot" and a[5]["color"] == L.WHITE and a[6]["color"] == Color8(255, 0, 0),
		"the description's sml2 markup as rows, the font colour kept (got %s / %s)" % [at[5], at[6]])
	_check(at[7] == " ", "a \" \" row after the description (0x67ad81)")
	_check(at[8] == "Acquisition condition" and bool(a[8]["icon"]) and a[8]["color"] == L.WHITE,
		"PARAM_CONDITION_OF_LEARN heads level 1's conditions, with a sign (0x7771e0)")
	_check(at[9] == "Mastery level : Bicheon Lv 1" and a[9]["color"] == L.BEIGE,
		"the mastery row \"%%s : %%s Lv %%d\" (0x96d19a), beige when met (got %s)" % at[9])
	_check(at[10] == "Required skillpoint : 2" and a[10]["color"] == L.BEIGE and at.size() == 11,
		"the SP row last; level 1 asks for no other skill (got %s)" % str(at))

	# NEGATIVE: the conditions red when unmet.
	var b := L.compose(s, 1, _ctx(0, true, 0, 1, 0))
	_check(b[9]["color"] == L.RED and b[10]["color"] == L.RED, "mastery 0 < 1 and 1 SP < 2: both rows red (0xffff4a4a)")

	# Learned at 1: the next level's conditions after "\n " (0x67b054).
	var c := L.compose(s, 1, _ctx(1, true, 5, 100, 2))
	var ct := _texts(c)
	_check(ct[8] == "" and ct[9] == " " and ct[10] == "Next level condition",
		"a learned skill below its last level: an empty row, a \" \" row, PARAM_CONDITION_OF_NEXT_LEVEL (got %s)" % str(ct.slice(8, 11)))
	_check(ct[11] == "Mastery level : Bicheon Lv 5" and c[11]["color"] == L.BEIGE, "level 2's mastery row")
	_check(ct[12] == "Required skill2 : Other 50 Lv 3" and c[12]["color"] == L.RED,
		"\"%%s%%d : %%s %%s %%d\" (0x96d55a): its place in the list from 1, red while the other skill is below 3 (got %s)" % ct[12])
	_check(not ct.has("Required skill1 : Other 40 Lv 1"), "NEGATIVE: the skill's own group is skipped (+0x778)")
	_check(ct[13] == "Required skillpoint : 10", "then level 2's SP")

	# Learned at its last level: nothing after the description's " " row.
	var d := L.compose(s, 3, _ctx(3, true, 50, 100, 9))
	_check(_texts(d).size() == 8 and _texts(d)[0] == "Strike Smash Lv 3" and _texts(d)[3] == "Consumed MP: 11",
		"a skill at its last level: the level's own record, no conditions (0x944940) (got %s)" % str(_texts(d)))

	# A quick slot (kind 0x0c, content 0x19): no conditions, even unlearned.
	var e := L.compose(s, 2, _ctx(2, false, 0, 0, 0))
	_check(_texts(e).size() == 8 and not _texts(e).has("Next level condition"),
		"NEGATIVE: a quick slot's tooltip stops after the description (0x67adb4) (got %s)" % str(_texts(e)))

	# A passive skill, one weapon, no MP.
	var p := _skill()
	p.activity = 0
	p.req_weapon_2 = L.NO_WEAPON
	p.level_mp = PackedInt32Array([0, 0, 0])
	var pt := _texts(L.compose(p, 1, _ctx(0, false, 0, 0, 0)))
	_check(pt[2] == "Passive" and pt[3] == "Used weapon: Sword", "Passive for Basic_Activity 0; \"%%s: %%s\" for one weapon (got %s)" % str(pt))
	p.req_weapon_1 = L.NO_WEAPON
	_check(L.requirement_rows(p, 1, Callable(self, "_t")).is_empty(), "no MP and no weapon (0xff): no requirement rows")
	var bare := func(_k: String, f: String) -> String: return f
	_check(L.weapon_row(7, L.NO_WEAPON, bare) == "Used weapon: One-handed Sword",
		"a Europe weapon falls back to the reader's words when the table lacks the key")

	# A mastery not held: the not-learned skill shows no conditions (0x67ae3a).
	var nh := _ctx(0, true, 0, 0, 0)
	nh["mastery_held"] = false
	_check(not _texts(L.compose(s, 1, nh)).has("Acquisition condition"), "NEGATIVE: an unheld mastery's skill lists no conditions")

	_bubble_checks()
	_panel_checks()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The rows in the original's window: wrapped at the help's 200 px, the
## sign on every row that asks for one.
func _bubble_checks() -> void:
	var holder := Control.new()
	holder.size = Vector2(1280, 720)
	root.add_child(holder)
	var bub := ItemTooltipBubble.new(null)
	holder.add_child(bub)
	var long := {"text": "word ".repeat(60).strip_edges(), "color": L.WHITE, "bold": false, "icon": false}
	var rows := bub.wrapped([long], L.WRAP_WIDTH)
	var widest := 0.0
	for r in rows:
		widest = maxf(widest, bub.text_width(r))
	_check(rows.size() > 1 and widest <= L.WRAP_WIDTH, "a long row breaks at spaces into rows no wider than 200 (%d rows, %.0f px)" % [rows.size(), widest])
	var lines := L.compose(_skill(), 1, _ctx(0, true, 4, 100, 0))
	bub.show_lines(lines + [long], Rect2(100, 50, 32, 32), null, L.WRAP_WIDTH)
	_check(bub.visible and bub.shown_lines().size() > lines.size() + 1 and bub.size.x <= L.WRAP_WIDTH + 16 + 1,
		"the bubble shows the skill rows, the long one wrapped, within 200 + the frame (got %s)" % str(bub.size))
	var signs := 0
	for ch in bub.get_children():
		if ch is TextureRect and String(ch.name).contains("Sign"):
			signs += 1
	_check(signs == 2, "two sign rows: the name and the condition header (got %d)" % signs)
	holder.queue_free()

## HudPanels.set_bubble_tip: no native tooltip is left on a control, and the
## rows come from the source at hover time.
func _panel_checks() -> void:
	var script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	if script == null or not script.can_instantiate():
		_check(false, "HudPanels compiles")
		return
	var p: Node = script.new()
	var c := Control.new()
	c.tooltip_text = "native"
	var n := [0]
	var rows := func() -> Array:
		n[0] += 1
		return [{"text": "row %d" % n[0], "color": L.WHITE, "bold": false, "icon": false}]
	p.call("set_bubble_tip", c, rows, L.WRAP_WIDTH)
	_check(c.tooltip_text == "", "set_bubble_tip empties tooltip_text: no native popup")
	var first: Array = p.call("bubble_tip_lines", c)
	var second: Array = p.call("bubble_tip_lines", c)
	_check(first.size() == 1 and String(first[0]["text"]) == "row 1" and String(second[0]["text"]) == "row 2",
		"a Callable source is read at each hover")
	var s := Control.new()
	p.call("set_bubble_tip", s, "one\ntwo")
	var sl: Array = p.call("bubble_tip_lines", s)
	_check(sl.size() == 2 and String(sl[1]["text"]) == "two" and sl[1]["color"] == L.WHITE, "a String source is white rows")
	p.call("set_bubble_tip", s, "")
	_check((p.call("bubble_tip_lines", s) as Array).is_empty(), "an empty source clears the help")
	c.free()
	s.free()
	p.free()
