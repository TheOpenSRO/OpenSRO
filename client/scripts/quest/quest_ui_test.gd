extends SceneTree

## Round 785: the quest tables reader (QuestTables), the NPC quest pages
## (QuestHud.page_lines), the guide icon (QuestInfoGuide), the marks
## (QuestMarks) and the minimap's quest signs (HudMinimap.update_quest).
## Every table here is synthetic (no archive data, docs/LEGAL.md).
##
##   godot4 --headless --path client --script res://scripts/quest/quest_ui_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _utf16(lines: Array) -> PackedByteArray:
	var b := PackedByteArray([0xff, 0xfe])
	b.append_array(("\r\n".join(PackedStringArray(lines))).to_utf16_buffer())
	return b

func _files() -> Dictionary:
	var T := QuestTables.TEXTDATA
	return {
		T + "questdata.txt": _utf16([
			"1\t3\tQX_SMITH_1\t0\tkorean\tSN_QX_SMITH_1\tSN_PAY_QX_SMITH_1\txxx\tSN_PAYCON_QX_SMITH_1\tSN_NN_QX_SMITH_1\tSN_NC_QX_SMITH_1",
			"1\t5\tQX_EU_1\t5\tkorean\tSN_QX_EU_1\tSN_PAY_QX_EU_1\txxx\txxx\txxx\txxx",
			"1\t6\tQX_CH_5\t5\tkorean\tSN_QX_CH_5\txxx\txxx\txxx\txxx\txxx",
			"1\t7\tQX_ANY_5\t5\tkorean\tSN_QX_ANY_5\txxx\txxx\txxx\txxx\txxx",
			"0\t8\tQX_OFF\t5\tkorean\tSN_QX_OFF\txxx\txxx\txxx\txxx\txxx",
		]),
		T + "questcontentsdata.txt": _utf16([
			"QX_EU_1\tkorean\t1\txxx\t0\tSN_CON_QX_EU_1",
			"QX_CH_5\tkorean\t0\txxx\t0\tSN_CON_QX_CH_5",
			"QX_ANY_5\tkorean\t3\txxx\t0\tSN_CON_QX_ANY_5",
		]),
		T + "refqusetreward.txt": _utf16(["3\tQX_SMITH_1\t1\t1\t0\t0\t0\t0\t0\t0\t205\t270\t0\t0\t0\txxx"]),
		T + "refquestrewarditems.txt": _utf16(["5\tQX_EU_1\t0\tITEM_QX_EU_1_01\txxx\txxx\t0\t1\t0\txxx"]),
		T + "textquest.txt": _utf16(["TextQuest_QuestString.txt"]),
		T + "textquest_queststring.txt": _utf16([
			"1\tSN_QX_SMITH_1\t\t\t\t\t\t\tWeapon Letter",
			"1\tSN_TALK_QX_1\t\t\t\t\t\t\tWill you help?",
			"1\tSN_PAYCON_QX_SMITH_1\t\t\t\t\t\t\t<sml2><strong>Mission</strong><br>Deliver it",
		]),
	}

func _test_tables() -> QuestTables:
	var files := _files()
	var t := QuestTables.new()
	t.load_from(func(path: String) -> PackedByteArray: return files.get(path, PackedByteArray()))
	_check(t.by_id.size() == 4 and not t.by_id.has(8), "questdata's service-1 rows (got %d)" % t.by_id.size())
	var q := t.quest(3)
	_check(q != null and q.code == "QX_SMITH_1" and q.level == 0 and q.title == "SN_QX_SMITH_1" and q.paycon == "SN_PAYCON_QX_SMITH_1",
		"questdata's columns (id, code, level col 3, SN_ title col 5, SN_PAYCON_ col 8)")
	_check(q.gold == 205 and q.exp == 270, "refqusetreward: gold col 10, EXP col 11 (got %d / %d)" % [q.gold, q.exp])
	_check(t.quest(5).country == 1 and t.quest(5).items == [["ITEM_QX_EU_1_01", 1]], "questcontentsdata's country and the reward item")
	_check(t.title_of(3) == "Weapon Letter", "a title resolves through the files textquest.txt names")
	_check(QuestTables.plain(t.resolve("SN_PAYCON_QX_SMITH_1")) == "Mission\nDeliver it", "sml2 markup to plain lines")
	# The guide's count (FUN_00940210): level exactly, not had, country or 3.
	var none := func(_id: int) -> bool: return false
	var china := t.unlocked_at(5, 0, none).map(func(x) -> int: return (x as QuestTables.Quest).id)
	var europe := t.unlocked_at(5, 1, none).map(func(x) -> int: return (x as QuestTables.Quest).id)
	_check(china == [6, 7] and europe == [5, 7], "level 5 unlocks by country (china %s, europe %s)" % [china, europe])
	var had := func(id: int) -> bool: return id == 7
	_check(t.unlocked_at(5, 0, had).size() == 1, "a quest the player has is not counted")
	return t

func _test_pages(t: QuestTables) -> void:
	var hud := QuestHud.new(null, null, null)
	hud.tables = t
	hud.player_level = 0
	var page := QuestNet.TalkPage.new()
	page.type = QuestNet.PAGE_LIST
	page.text = "SN_TALK_QX_1"
	page.lines = PackedStringArray(["SN_QX_SMITH_1", "SN_QX_EU_1"])
	var lines := hud.page_lines(page)
	_check(lines[0] == "Will you help?" and lines[1] == "", "a page's text, then a blank line")
	_check(lines[2].begins_with("[url=qresp:5]1. [color=#efdaa4]Weapon Letter"), "a list line: response 5, numbered, level-0 quest colour 0xffefdaa4 (got %s)" % lines[2])
	_check(lines[3].begins_with("[url=qresp:6]2. [color=#ff4a4a]"), "a quest above the player's level is 0xffff4a4a (got %s)" % lines[3])
	page.type = QuestNet.PAGE_YES_NO
	lines = hud.page_lines(page)
	_check(lines.size() == 4 and lines[2] == "[url=qresp:2]1. Yes[/url]" and lines[3] == "[url=qresp:3]2. No[/url]", "yes/no: responses 2 and 3")
	page.type = QuestNet.PAGE_CONFIRM
	lines = hud.page_lines(page)
	_check(lines.size() == 3 and lines[2] == "[url=qresp:1]1. Confirm[/url]", "confirm: response 1")
	_check(QuestHud.response_of("qresp:7") == 7 and QuestHud.response_of("talk") == -1, "a line's key gives its response")
	_check(QuestHud.line_colour(20, 5) == QuestHud.COLOUR_HIGH and QuestHud.line_colour(5, 5) == QuestHud.COLOUR_EVEN, "the level colours")
	hud.free()

func _test_guide() -> void:
	_check(QuestInfoGuide.slot_position(Vector2(1152, 648)) == Vector2(1104, 180), "the guide's slot: 42 left of (W - 6, 180)")
	_check(QuestInfoGuide.slot_position(Vector2(1152, 648), 4) == Vector2(1104, 224), "the fifth alarm icon starts a row 44 lower")
	var g := QuestInfoGuide.new(null)
	_check(g.size == Vector2(40, 40) and not g.visible, "40x40, hidden until a level-up")
	g.advance(499)
	_check(g.frame == 0, "still the first frame at 499 ms")
	g.advance(1)
	_check(g.frame == 1, "the second frame at 500 ms")
	g.advance(500)
	_check(g.frame == 0, "and back")
	var got := [0]
	g.clicked.connect(func() -> void: got[0] += 1)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	g._gui_input(ev)
	_check(got[0] == 1, "a click is the guide's click")
	g.free()

func _test_marks() -> void:
	_check(QuestMarks.mark_path(1) == "res\\etc\\ex_mark_start.bsr" and QuestMarks.mark_path(2) == "res\\etc\\ex_mark_going.bsr"
		and QuestMarks.mark_path(3) == "res\\etc\\ex_mark_end.bsr" and QuestMarks.mark_path(0) == "res\\etc\\ex_mark_start.bsr", "the mark files by type")
	var holder := Node3D.new()
	var plate := Node3D.new()
	plate.name = "Name"
	plate.position = Vector3(0, 10, 0)
	holder.add_child(plate)
	var loads := [0]
	var loader := func(_p: String) -> Node3D:
		loads[0] += 1
		return Node3D.new()
	var models := {}
	var m := QuestNet.Mark.new()
	m.object_id = 9
	m.mark_type = QuestNet.MARK_END
	_check(QuestMarks.apply({9: holder}, {9: m}, models, loader) == 1, "a mark over its NPC")
	var node := holder.get_node_or_null(QuestMarks.MARK_NODE) as Node3D
	_check(node != null and str(node.get_meta("mark_path")) == "res\\etc\\ex_mark_end.bsr" and is_equal_approx(node.position.y, 11.2), "the end mark above the plate")
	QuestMarks.apply({9: holder}, {9: m}, models, loader)
	_check(loads[0] == 1, "a model is loaded once")
	QuestMarks.apply({9: holder}, {}, models, loader)
	await process_frame
	_check(holder.get_node_or_null(QuestMarks.MARK_NODE) == null, "an unmarked NPC loses its mark")
	holder.free()
	for v in models.values():
		(v as Node).free()
	var sp := NpcTableReader.Spawn.new()
	sp.npc_id = 1000
	sp.region_x = 97
	sp.region_y = 168
	sp.local_position = Vector3(100, 0, 200)
	var index := QuestMarks.index_positions([sp])
	var at := QuestMarks.targets_local(PackedInt64Array([1000, 5]), Vector2i(97, 168), index)
	_check(at.size() == 1 and at[0] == Vector2(100, 200), "an NPC's spot from npcpos in the player's region (got %s)" % at)

func _test_minimap() -> void:
	var mm := HudMinimap.new(null, null, null)
	get_root().add_child(mm)
	await process_frame
	if mm.get("_quest_root") == null:
		print("info: the minimap built no marks root without a builder; quest signs not exercised")
		mm.free()
		return
	# The archive's art is not here: 8x8 and 16x16 stand-ins.
	for pair in [["_quest_npc_tex", 8], ["_quest_arrow_tex", 16]]:
		var img := Image.create(int(pair[1]), int(pair[1]), false, Image.FORMAT_RGBA8)
		mm.set(pair[0], ImageTexture.create_from_image(img))
	mm.update_quest(Vector2(0, 0), PackedVector2Array([Vector2(10, 10), Vector2(1900, 0)]))
	var shown: Vector2i = mm.quest_marks_shown()
	_check(shown == Vector2i(1, 1), "a near NPC is the sign, a far one the rim arrow (got %s)" % shown)
	mm.update_quest(Vector2(0, 0), PackedVector2Array())
	_check(mm.quest_marks_shown() == Vector2i(0, 0), "no tracked quest, no signs")
	mm.free()

func _initialize() -> void:
	var t := _test_tables()
	_test_pages(t)
	_test_guide()
	await _test_marks()
	await _test_minimap()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
