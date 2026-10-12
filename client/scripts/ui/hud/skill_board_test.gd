extends SceneTree

## Round 781: the skill window's rules and layout as read from the retail
## client (SkillBoard, SkillPracticeBox). No archive -- the board builds from
## a plain model and the checks read the nodes it made:
##   godot4 --headless --path client --script res://scripts/ui/hud/skill_board_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	_test_slot_view()
	_test_levelup()
	_test_texts()
	_test_layout()
	_test_columns()
	_test_practice_box()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A three-level skill: ids 101..103, mastery 1 / 5 / 9, cost 2 / 10 / 20.
func _view(learned: int, mastery: int, sp: int, prereqs := true) -> Dictionary:
	return SkillBoard.slot_view(learned, 3, mastery, PackedInt64Array([101, 102, 103]),
		PackedInt32Array([1, 5, 9]), PackedInt32Array([2, 10, 20]), prereqs, sp)

func _test_slot_view() -> void:
	var v := _view(0, 0, 100)
	_check(v["locked"] and not v["dim"] and v["button"] == SkillBoard.Btn.NONE and not v["badge"],
		"unlearned below level 1's mastery: the locked book, no button, no level (0x9c0c80, 0x6a1740)")
	v = _view(0, 1, 100)
	_check(not v["locked"] and v["dim"] and v["button"] == SkillBoard.Btn.ADD and v["target_id"] == 101,
		"unlearned, mastery met, points enough: its own icon dimmed and ADD for level 1 (state 8)")
	v = _view(0, 1, 1)
	_check(v["button"] == SkillBoard.Btn.NONE and not v["locked"],
		"NEGATIVE: 1 SP against a 2 SP level 1 -- no button, icon still its own (0x6a1245 jb)")
	v = _view(0, 1, 100, false)
	_check(v["button"] == SkillBoard.Btn.NONE, "NEGATIVE: a missing prerequisite skill hides ADD (0x6a11a6)")
	v = _view(1, 4, 100)
	_check(v["badge"] and v["level"] == 1 and v["button"] == SkillBoard.Btn.NONE and v["target_id"] == 102,
		"learned Lv 1, mastery 4 < level 2's 5: the badge and no UP")
	v = _view(1, 5, 100)
	_check(v["button"] == SkillBoard.Btn.UP and v["target_id"] == 102 and not v["dim"] and not v["locked"],
		"learned Lv 1, mastery 5: UP for level 2 (state 0), full strength")
	v = _view(3, 50, 100)
	_check(v["button"] == SkillBoard.Btn.MAX and v["badge"] and v["level"] == 3,
		"learned at its top level: MAX (0x6a109b)")
	# OURS: a level with no learn cost offers nothing (the server's 0x3409).
	var free := SkillBoard.slot_view(0, 1, 9, PackedInt64Array([7]), PackedInt32Array([1]), PackedInt32Array([0]), true, 50)
	_check(free["button"] == SkillBoard.Btn.NONE, "NEGATIVE: a 0-cost level offers no ADD (round 691's 0x3409)")

func _test_levelup() -> void:
	_check(SkillBoard.levelup_visible(0, 1, 0, 999), "level 0: LEVEL UP always shows (0x69c880)")
	_check(not SkillBoard.levelup_visible(20, 20, 999, 1), "NEGATIVE: level + 1 above the character's level hides it")
	_check(SkillBoard.levelup_visible(19, 20, 53, 53), "cost == points shows it (ja, 0x69c7ea)")
	_check(not SkillBoard.levelup_visible(19, 20, 52, 53), "NEGATIVE: one point short hides it")
	_check(not SkillBoard.levelup_visible(120, 140, 999999, 0), "NEGATIVE: level 120 hides it (cmp al,0x78; jae)")
	_check(SkillBoard.levelup_visible(119, 140, 999999, 5), "level 119 can still show it")

func _test_texts() -> void:
	_check(SkillBoard.total_text(140, 330) == "140/330", "the footer total is \"%d/%d\" (FUN_006aa3e0)")
	_check(SkillBoard.header_name("Bicheon", "Mastery") == "Bicheon Mastery", "the header name is \"%s %s\"")
	_check(SkillBoard.level_text("Lv", 100) == "Lv 100", "the header level is \"%s %d\"")
	var one := SkillBoard.level_digits(7)
	_check(one.size() == 1 and one[0][0] == SkillBoard.DIGIT_MID and one[0][1] == 7, "Lv 7: one digit at 26,24 (0x6a0bb7)")
	var two := SkillBoard.level_digits(16)
	_check(two.size() == 2 and two[0][0] == SkillBoard.DIGIT_FIRST and two[0][1] == 1
		and two[1][0] == SkillBoard.DIGIT_SECOND and two[1][1] == 6, "Lv 16: tens at 24,24, units at 29,24 (0x6a0afe)")
	_check(SkillBoard.category_tab_rect(1) == Rect2(66, -23, 60, 24), "the second category tab at (66,-23) 60x24 (0x3e pitch)")
	_check(SkillBoard.mastery_tab_rect(2) == Rect2(148, 4, 68, 28), "the third mastery tab at (12 + 2*68, 4) 68x28")
	_check(SkillBoard.slot_rect(7) == Rect2(289, 3, 36, 56), "column 7's slot at x 7*36+37, y 3, 36x56")
	_check(SkillBoard.max_first_row(9) == 5 and SkillBoard.max_first_row(3) == 0, "nine rows scroll to a first row of 5; three do not scroll")

func _slot(view: Dictionary) -> Dictionary:
	return {"icon": null, "view": view, "tooltip": "t", "meta": {}}

func _model(rows: int) -> Dictionary:
	var out: Array = []
	for r in range(rows):
		var slots: Array = []
		slots.resize(SkillBoard.COLUMNS)
		slots[0] = _slot(_view(0, 1, 100))
		slots[1] = _slot(_view(1, 5, 100))
		slots[3] = _slot(_view(3, 50, 100))
		out.append({"icon": null, "focus": null, "name": "Group %d" % r, "slots": slots})
	return {"categories": ["Melee", "Caster"], "category": 0, "masteries": ["Warrior", "Rogue"],
		"mastery": 1, "header": {"name": "Rogue Mastery", "level": "Lv 7", "levelup": false},
		"rows": out, "first_row": 0}

func _test_layout() -> void:
	var view := SkillBoard.new()
	view.build(_model(6))
	var cats := view.find_child("SkillCategoryTabs", true, false)
	_check(cats != null and cats.get_child_count() == 2, "two category tabs")
	if cats != null and cats.get_child_count() == 2:
		var t1 := cats.get_child(1) as Control
		_check(t1.position == Vector2(66, -23) and t1.size == Vector2(60, 24), "the second category tab sits above the pane")
		_check((t1.get_node("Title") as Label).text == "Caster", "the tab's title")
	var ms := view.find_child("SkillMasteryTabs", true, false)
	_check(ms != null and ms.get_child_count() == 2 and bool(ms.get_child(1).get_meta("selected"))
		and not bool(ms.get_child(0).get_meta("selected")), "two mastery tabs, the second selected")
	var lv := view.find_child("GDR_SKILLBOARD_BTNLEVUP", true, false) as Control
	_check(lv != null and not lv.visible, "LEVEL UP hidden as the model says")
	var lvl := view.find_child("GDR_SKILLBOARD_MASTERYLEV", true, false) as Label
	_check(lvl != null and lvl.text == "Lv 7", "the level box reads 'Lv 7'")
	_check(view.row_count() == 6, "six rows")
	var rows := view.find_child("SkillRows", true, false)
	var shown := 0
	for c in rows.get_children():
		if (c as Control).visible:
			shown += 1
	_check(shown == 4, "four rows show at a time (0x8123f0(4)) (got %d)" % shown)
	_check((rows.get_child(1) as Control).position == Vector2(0, 55), "rows are pitched 55 (0x37)")
	var scrolled: Array = []
	view.scrolled.connect(func(n: int) -> void: scrolled.append(n))
	view.set_first_row(10)
	_check(view.first_row == 2 and scrolled == [2], "scrolling stops at rows - 4 and reports it")
	_check(not (rows.get_child(0) as Control).visible and (rows.get_child(2) as Control).position == Vector2.ZERO,
		"a scrolled-off row is hidden, the first shown sits at the top")
	var row0 := rows.get_child(0)
	_check(row0.get_node_or_null("Nothing2") == null, "a gap before the last used column stays empty (0x69f1e1)")
	_check(row0.get_node_or_null("Nothing4") != null and row0.get_node_or_null("Nothing7") != null
		and row0.get_node_or_null("Nothing3") == null, "the columns after the last skill get skl_mastery_nothing")
	var add := row0.get_node("Slot0/Button") as BaseButton
	var up := row0.get_node("Slot1/Button") as BaseButton
	var mx := row0.get_node("Slot3/Button") as BaseButton
	_check(String(add.get_meta("kind")) == "ADD" and String(up.get_meta("kind")) == "UP"
		and String(mx.get_meta("kind")) == "MAX" and mx.disabled and not up.disabled,
		"ADD, UP and a MAX that cannot be pressed")
	_check(add.position == Vector2(0, 32) and add.size == Vector2(32, 20), "the button at 0,32 32x20 (ifskill_slot.txt)")
	_check(row0.get_node_or_null("Slot0/LevelTab") == null and row0.get_node_or_null("Slot1/LevelTab") != null,
		"only a learned skill carries the level tab")
	var digits: Array = []
	for c in row0.get_node("Slot3").get_children():
		if (c as Node).has_meta("digit"):
			digits.append(int((c as Node).get_meta("digit")))
	_check(digits == [3], "the max-level skill's digit is 3 (got %s)" % str(digits))
	var dim := (row0.get_node("Slot0/Icon") as CanvasItem).modulate.a
	_check(absf(dim - 128.0 / 255.0) < 0.001, "an unlearned skill's icon at 0x80 (got %f)" % dim)
	var learned: Array = []
	view.learn_pressed.connect(func(id: int) -> void: learned.append(id))
	up.pressed.emit()
	add.pressed.emit()
	_check(learned == [102, 101], "UP asks for level 2's id, ADD for level 1's (got %s)" % str(learned))
	view.free()

func _skill(base: int, ui_col: int) -> SkillDataReader.BaseSkill:
	var s := SkillDataReader.BaseSkill.new()
	s.base_id = base
	s.ui_column = ui_col
	return s

func _test_columns() -> void:
	# Bicheon's passive row, as the box's tables have it: 194 col 0, 1064 col
	# 2, 2011 col 1 (MEASURED) -- base-id order put 1064 second.
	var row := [_skill(194, 0), _skill(1064, 2), _skill(2011, 1)]
	SkillDataReader.assign_columns(row)
	_check(row[0].base_id == 194 and row[1].base_id == 2011 and row[2].base_id == 1064
		and row[2].column == 2, "a row follows skilldata col 60, not base-id order")
	var clash := [_skill(10, 0), _skill(11, 0), _skill(12, -1)]
	SkillDataReader.assign_columns(clash)
	_check(clash[0].column == 0 and clash[1].column == 1 and clash[2].column == 2,
		"a taken or missing column falls to the first free one, in base-id order")

func _test_practice_box() -> void:
	_check(SkillPracticeBox.message(SkillPracticeBox.Mode.SKILL, "Smash", 1, "Learn [%s]skill.", "reinforce [%s]skill upto level [%d].")
		== "Learn [Smash]skill.", "level 1 of a skill: the learn text (0x70658e)")
	_check(SkillPracticeBox.message(SkillPracticeBox.Mode.SKILL, "Smash", 4, "Learn [%s]skill.", "reinforce [%s]skill upto level [%d].")
		== "reinforce [Smash]skill upto level [4].", "a higher level: the reinforce text with the level (0x7065ec)")
	_check(SkillPracticeBox.message(SkillPracticeBox.Mode.MASTERY, "Bicheon", 21, "Learn [%s]skill.", "")
		== "Learn [Bicheon]skill.", "a mastery: the learn text, its extra level argument unused (0x706798)")
	var box := SkillPracticeBox.new()
	box.mode = SkillPracticeBox.Mode.SKILL
	box.target_id = 102
	box.cost = 10
	box.skill_points = 9
	var got: Array = []
	box.confirmed.connect(func(m: int, id: int) -> void: got.append([m, id]))
	box.refused.connect(func(t: String) -> void: got.append(t))
	box.confirm()
	_check(got.size() == 1 and got[0] is String, "NEGATIVE: Confirm with 9 SP against 10 sends nothing (0x706a5f jae)")
	_check(box.is_queued_for_deletion(), "Confirm closes the box either way")
	var box2 := SkillPracticeBox.new()
	box2.mode = SkillPracticeBox.Mode.MASTERY
	box2.target_id = 257
	box2.cost = 10
	box2.skill_points = 10
	var got2: Array = []
	box2.confirmed.connect(func(m: int, id: int) -> void: got2.append([m, id]))
	box2.confirm()
	_check(got2 == [[SkillPracticeBox.Mode.MASTERY, 257]], "Confirm with the points sends the raise for the mastery")
