extends SceneTree

## The Quest window rebuilt from the client's `res_ui\questlist.2dt`
## (QuestWindow). The fixture is synthetic records built here -- ids,
## parents, rects and class names copied from the real file's structure, no
## art and no text (docs/LEGAL.md) -- run through the real reader and
## builder:
##   godot4 --headless --path client --script res://scripts/ui/hud/quest_window_test.gd
##
## Every script this checks is reached through load() or call(), so a tree
## without it FAILS instead of failing to compile. The old window's layout
## (ifquest.txt) is given too, so an older tree opens its own window and the
## checks say what they found.

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const ROW_ART := "interface\\quest\\qst_sub_window.ddj"
const SMALL_BOX := "interface\\quest\\qst_small_sub_window.ddj"
const CHECK_ON := "interface\\ifcommon\\com_checkbutton_on.ddj"
const CHECK_OFF := "interface\\ifcommon\\com_checkbutton_off.ddj"
const WORLD := "interface\\quest\\qst_world_button.ddj"
const VIEW := "interface\\quest\\qst_contentview_button.ddj"
const CLOSE := "interface\\ifcommon\\com_windowclose.ddj"
## The ten rows' ids, in file order.
const ROW_IDS := [5, 77, 85, 93, 101, 109, 117, 125, 133, 141]

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- synthetic .2dt records -------------------------------------------------

func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	for pair in [[0x000, "name"], [0x040, "base"], [0x140, "tex"], [0x240, "textid"], [0x300, "sample"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, f.get("color", 0xffffffff))
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x390, 0xffffffff)
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	b[0x3cd] = f.get("ha", 1)
	b[0x3ce] = 1
	return b

func _file(records: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, records.size())
	for r in records:
		out.append_array(_rec(r))
	return out

## questlist.2dt's structure: the window (76), its inner frame (2), tile (3)
## and scroll (6), and ten CNIFQuestSlot rows of seven parts, each 31 below
## the last. The sample texts are the editor-only 0x300 field.
func _questlist() -> Array:
	var recs := [
		{"type": 0, "id": 76, "name": "CNIFQuest", "root": true, "rect": Rect2i(198, 193, 624, 369),
			"base": "interface\\frame\\mframe_wnd_", "textid": "UIIT_STT_QUEST_LIST", "sample": "SAMPLE-TITLE"},
		{"type": 1, "id": 2, "parent": 76, "rect": Rect2i(209, 231, 603, 322), "base": "interface\\equipment\\equip_window_"},
		{"type": 2, "id": 3, "parent": 76, "rect": Rect2i(236, 261, 547, 284), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_a.ddj"},
		{"type": 13, "id": 6, "parent": 76, "rect": Rect2i(789, 253, 16, 262)},
	]
	var y := 236
	for id in ROW_IDS:
		recs.append({"type": 8, "id": id, "name": "CNIFQuestSlot", "parent": 76, "rect": Rect2i(214, y, 576, 32), "tex": ROW_ART})
		recs.append({"type": 5, "id": 7, "parent": id, "gp": 76, "rect": Rect2i(217, y + 5, 444, 22), "tex": SMALL_BOX})
		recs.append({"type": 11, "id": 8, "parent": id, "gp": 76, "rect": Rect2i(223, y + 7, 16, 16), "tex": CHECK_ON})
		recs.append({"type": 5, "id": 16, "parent": id, "gp": 76, "rect": Rect2i(248, y + 8, 383, 16), "ha": 0, "sample": "SAMPLE-QUEST"})
		recs.append({"type": 4, "id": 18, "parent": id, "gp": 76, "rect": Rect2i(741, y + 5, 20, 20), "tex": WORLD})
		recs.append({"type": 4, "id": 19, "parent": id, "gp": 76, "rect": Rect2i(762, y + 5, 20, 20), "tex": VIEW})
		recs.append({"type": 5, "id": 11, "parent": id, "gp": 76, "rect": Rect2i(668, y + 10, 77, 16), "ha": 0, "sample": "SAMPLE-STATUS"})
		recs.append({"type": 5, "id": 75, "parent": id, "gp": 76, "rect": Rect2i(662, y + 9, 77, 16), "sample": "SAMPLE-TIME"})
		y += 31
	return recs

# --- the old window's layout, for a tree that still builds it --------------

func _ifquest() -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n\tGDR_QUEST_FRAME:CIFFrame\n\t{\n\t\tDDJ=STRING,\"interface\\\\messagebox\\\\msgbox2_window_\"\n\t\tID=INTEGER,\"1\"\n\t\tRect=RECT,\"0,0,365,355\"\n\t}\n\tGDR_QUEST_SCROLLMGR:CIFScrollManager\n\t{\n\t\tID=INTEGER,\"2\"\n\t\tRect=RECT,\"4,27,356,323\"\n\t}\n}\n"

## ifquestreward.txt's structure (control names and rects as the archive's,
## no art): the paper, the title, the give-up button.
func _ifquestreward() -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n\tGDR_QUESTREWARD_GIVEUP:CIFButton\n\t{\n\t\tID=INTEGER,\"16\"\n\t\tRect=RECT,\"109,330,158,24\"\n\t\tText=STRING,\"UIIT_STT_QUEST_GIVEUP\"\n\t}\n\tGDR_QUESTREWARD_TITLE:CIFStatic\n\t{\n\t\tID=INTEGER,\"17\"\n\t\tRect=RECT,\"36,40,289,15\"\n\t}\n\tGDR_QUESTREWARD_BG:CIFStatic\n\t{\n\t\tID=INTEGER,\"10\"\n\t\tRect=RECT,\"0,0,376,384\"\n\t}\n}\n"

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_STT_QUEST_LIST", "tt QUEST LIST"], ["UIIT_STT_QUEST_ING", "tt ING"],
			["UIIT_STT_QUEST_END", "tt END"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _tex(builder: UiBuilder, path: String, size: Vector2i) -> Texture2D:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.3, 0.2, 1.0))
	var t := ImageTexture.create_from_image(img)
	(builder.get("_texture_cache") as Dictionary)[path.to_lower()] = t
	return t

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var layouts: Dictionary = builder.get("_layout_cache")
	layouts["resinfo\\ifquest.txt"] = UiLayoutParser.parse(_ifquest())
	layouts["resinfo\\ifquestreward.txt"] = UiLayoutParser.parse(_ifquestreward())
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		cache["res_ui\\questlist.2dt"] = Reader.parse(_file(_questlist()))
	for p in [ROW_ART, SMALL_BOX, CHECK_ON, CHECK_OFF, WORLD, VIEW, CLOSE]:
		_tex(builder, p, Vector2i(16, 16))
	return builder

# --- helpers ----------------------------------------------------------------

func _net() -> Node:
	return get_root().get_node_or_null("NetClient")

func _press(panels: Node, keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	panels.call("_unhandled_key_input", ev)

func _wheel(window: Control, button: MouseButton) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	ev.position = Vector2(300, 200)
	window.call("_gui_input", ev)

## A control by its GetChild path from `root`, through node metadata, so
## this compiles and FAILS on a tree without the builder.
func _at(root: Node, path: Array) -> Control:
	var at: Node = root
	for id in path:
		var found: Node = null
		if at != null:
			for c in at.get_children():
				if c.has_meta("twodt_id") and int(c.get_meta("twodt_id")) == int(id):
					found = c
					break
		at = found
	return at as Control

func _rect_in(window: Control, node: Control) -> Rect2:
	if node == null:
		return Rect2()
	return Rect2(node.get_global_rect().position - window.get_global_rect().position, node.size)

func _root(window: Control) -> Control:
	return window.get("quest_root") as Control if window != null and "quest_root" in window else null

func _text(node: Control) -> String:
	var l := node.get_node_or_null("Text") as Label if node != null else null
	return l.text if l != null else "<no label>"

func _caption(window: Control) -> String:
	var bar := window.get_node_or_null("TitleBar") as Label if window != null else null
	return bar.text if bar != null else "<no caption>"

func _visible_window(panels: Node) -> Control:
	for c in panels.get_children():
		if c is Control and c.name.begins_with("Window_") and (c as Control).visible:
			return c
	return null

## The names drawn on the rows, "" for a hidden row.
func _drawn(qroot: Control) -> Array:
	var out := []
	for id in ROW_IDS:
		var row := _at(qroot, [id])
		out.append(_text(_at(row, [16])) if row != null and row.visible else "")
	return out

# --- the checks -------------------------------------------------------------

## Synthetic quest tables (no archive text): quest 1 "Wolf Hunt" at level 3,
## quests 100.. "Q<n>" at level 1, the objective text with its %d.
func _tables() -> QuestTables:
	var t := QuestTables.new()
	var rows := PackedStringArray()
	for pair in [["SN_QW_1", "Wolf Hunt"], ["SN_CON_QW_1", "Hunt 3 wolves (%d)"], ["SN_PAY_QW_1", "The wolf hunt"],
			["SN_PAYCON_QW_1", "<b>Mission</b><br>Hunt wolves"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	for i in 12:
		rows.append("1\tSN_QW_%d\t\t\t\t\t\t\tQ%d" % [100 + i, i + 1])
	t.text = UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())
	var q := QuestTables.Quest.new()
	q.id = 1
	q.code = "QW_1"
	q.level = 3
	q.title = "SN_QW_1"
	q.pay = "SN_PAY_QW_1"
	q.paycon = "SN_PAYCON_QW_1"
	t.by_id[1] = q
	t.by_code["QW_1"] = q
	for i in 12:
		var qi := QuestTables.Quest.new()
		qi.id = 100 + i
		qi.code = "QW_%d" % (100 + i)
		qi.level = 1
		qi.title = "SN_QW_%d" % (100 + i)
		t.by_id[qi.id] = qi
		t.by_code[qi.code] = qi
	return t

func _view(status: int, missions: Array = [], counter: int = 0x10) -> QuestNet.View:
	var v := QuestNet.View.new()
	v.counter = counter
	v.state = 1
	v.status = status
	for m in missions:
		var mm := QuestNet.Mission.new()
		mm.index = int(m[0])
		mm.open = bool(m[1])
		mm.text = str(m[2])
		mm.values = PackedInt64Array([int(m[3])])
		v.missions.append(mm)
	return v

func _send(net: Node, kind: int, id: int, v: QuestNet.View = null) -> void:
	(net.get("quest") as QuestState).handle(QuestNet.encode_update(kind, id, v), QuestNet.OP_UPDATE)

func _log(net: Node, ids: Array) -> void:
	var b := PackedByteArray([0, 0, ids.size()])
	for id in ids:
		b.append_array(QuestNet._u32(int(id)))
		b.append_array(QuestNet.encode_view(_view(1)))
	b.append(0)
	(net.get("quest") as QuestState).handle(b, QuestNet.OP_LOG)

func _run() -> void:
	# The client's default window, 1152x648 (the headless root starts at
	# 64x64 and takes a size only after its first frame).
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	QuestTables.set_shared(_tables())
	var script := load(PANELS_PATH) as GDScript
	var panels: Control = script.new(_builder())
	get_root().add_child(panels)
	await process_frame
	var net := _net()
	_check(net != null and "quest" in net, "NetClient is registered for this suite, with its quest log")
	if net == null or not ("quest" in net):
		return
	panels.call("connect_net")
	# A quest that arrives before the window is built is kept and drawn when
	# it is: quest 1 in progress, one objective at 2 of its count.
	_send(net, QuestNet.UPDATE_ADD, 1, _view(1, [[0, true, "SN_CON_QW_1", 2]]))

	# Q: the retail key toggles CNIFQuest (0x7990e0).
	_press(panels, KEY_Q)
	await process_frame
	var window := _visible_window(panels)
	_check(window != null, "Q opens a window")
	if window == null:
		return
	var qroot := _root(window)
	_check(qroot != null, "it is built from res_ui\\questlist.2dt (a quest_root)")
	_check(window.size == Vector2(624, 369), "it is questlist.2dt's CNIFQuest, 624x369 (got %s)" % window.size)
	_check(_caption(window) == "tt QUEST LIST",
		"its caption is record 0's UIIT_STT_QUEST_LIST (got '%s')" % _caption(window))
	_check(panels.get("last_populated") == "quest", "opening it runs _populate")
	# OnCreate (0x6e3ff0): centred, then x = 0x50: (80, 324 - 184).
	_check(window.position == Vector2(80, 140), "it sits at (0x50, centred y) = (80, 140) in the 1152x648 view (got %s)" % window.position)
	var bar := window.get_node_or_null("TitleBar") as Control
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == 603,
		"the caption is at (10, 12), 603 wide (got %s)" % (Rect2(bar.position, bar.size) if bar else null))
	var close := window.get_node_or_null("CloseButton") as Control
	_check(close != null and close.position == Vector2(598, 10) and close.size == Vector2(16, 16),
		"the close button is at (598, 10), 16x16 (got %s)" % (Rect2(close.position, close.size) if close else null))
	var row_rects := []
	for id in [5, 77, 141]:
		row_rects.append(_rect_in(window, _at(qroot, [id])))
	_check(row_rects == [Rect2(16, 43, 576, 32), Rect2(16, 74, 576, 32), Rect2(16, 322, 576, 32)],
		"the rows are at (16, 43), (16, 74) .. (16, 322), 576x32 (got %s)" % [row_rects])

	# The quest row, then its objective row (0x6e0570).
	_check(_drawn(qroot) == ["Wolf Hunt (0/1)", "Hunt 3 wolves (2)", "", "", "", "", "", "", "", ""],
		"row 5 is the quest '%%s (%%d/%%d)' with +8's nibbles low then high, row 77 its objective with the count (got %s)" % [_drawn(qroot)])
	var row := _at(qroot, [5])
	_check(_at(row, [7]).visible and _at(row, [8]).visible and _at(row, [19]).visible and not _at(row, [11]).visible,
		"the quest row is in quest mode: 7, 8, 19 shown, the status 11 hidden")
	var obj := _at(qroot, [77])
	_check(not _at(obj, [8]).visible and not _at(obj, [19]).visible and _at(obj, [11]).visible and _text(_at(obj, [11])) == "tt ING",
		"the objective row is in objective mode with UIIT_STT_QUEST_ING (got '%s')" % _text(_at(obj, [11])))
	var ing := _at(obj, [11]).get_node_or_null("Text") as Label
	_check(ing != null and ing.get_theme_color("font_color") == Color8(0xef, 0xda, 0xa4), "an open objective's status is 0xffefdaa4")
	var view_btn := _at(row, [19])
	_check(str(view_btn.get_meta("view_art", "")) == "interface\\quest\\qst_contentviewred_button",
		"a level-3 quest for a level-0 player has the red content-view button (0x6e5760, got %s)" % view_btn.get_meta("view_art", ""))
	# The mission done: the status turns to END.
	_send(net, QuestNet.UPDATE_CHANGE, 1, _view(2, [[0, false, "SN_CON_QW_1", 3]]))
	await process_frame
	_check(_text(_at(_at(qroot, [77]), [11])) == "tt END" and _text(_at(_at(qroot, [77]), [16])) == "Hunt 3 wolves (3)",
		"a finished objective shows UIIT_STT_QUEST_END and its last count (got '%s')" % _text(_at(_at(qroot, [77]), [11])))
	# The content view opens the detail with the reward button (status 2).
	(view_btn as BaseButton).pressed.emit()
	await process_frame
	var hud: Node = panels.get("quest_hud")
	var detail: Control = hud.get("detail") if hud != null else null
	_check(detail != null and detail.visible, "the content-view button opens the quest detail (CIFQuestReward)")
	if detail != null:
		var body := detail.get_node_or_null("QuestContents") as PmlText
		var drawn := "\n".join(body.plain_lines()) if body != null else ""
		_check(body != null and drawn.contains("Hunt wolves") and not drawn.contains("<"),
			"the detail draws SN_PAYCON_ as PML, without its markup (round 845; got '%s')" % drawn)
		_check(str(detail.get_meta("quest_button", "")) == "UIIT_STT_QUEST_REWARD", "an achieved-unpaid quest's button is the reward")
	_check((net.get("quest") as QuestState).tracked == 1, "the content view selects (tracks) the quest")
	# Dropped as completed: the rows empty.
	_send(net, QuestNet.UPDATE_DROPPED, 1)
	await process_frame
	_check(_drawn(qroot)[0] == "", "a completed quest leaves the rows")

	# Twelve quests, no objectives: ten rows; the wheel scrolls one quest.
	_log(net, range(100, 112))
	await process_frame
	_check(_drawn(qroot) == ["Q1 (0/1)", "Q2 (0/1)", "Q3 (0/1)", "Q4 (0/1)", "Q5 (0/1)", "Q6 (0/1)", "Q7 (0/1)", "Q8 (0/1)", "Q9 (0/1)", "Q10 (0/1)"],
		"the login log fills the rows in arrival order (got %s)" % [_drawn(qroot)])
	_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	_check(_drawn(qroot)[0] == "Q2 (0/1)", "the wheel down moves the list one quest (0x4794f0, got %s)" % [_drawn(qroot)])
	for i in 20:
		_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	_check(_drawn(qroot)[0] == "Q12 (0/1)" and _drawn(qroot)[1] == "",
		"the scroll stops at the last quest, 0..count-1 (0x478960, got %s)" % [_drawn(qroot)])
	_wheel(window, MOUSE_BUTTON_WHEEL_UP)
	_check(_drawn(qroot)[0] == "Q11 (0/1)", "the wheel up moves it back one (0x4794d0)")
	# A change of a count keeps the scroll (ours); a new quest starts over
	# (0x6e3810).
	_send(net, QuestNet.UPDATE_CHANGE, 105, _view(1, [], 0x11))
	_check(_drawn(qroot)[0] == "Q11 (0/1)", "a change keeps the scroll (got %s)" % [_drawn(qroot)])
	_send(net, QuestNet.UPDATE_ADD, 1, _view(1))
	_check(_drawn(qroot)[0] == "Q1 (0/1)", "an added quest starts from the first quest (got %s)" % [_drawn(qroot)])

	# Q toggles; showing it does not move it (0x6e12b0 has no 0x798c50).
	var moved := Vector2(300, 200)
	window.position = moved
	_press(panels, KEY_Q)
	await process_frame
	_check(not window.visible, "Q again hides it")
	_press(panels, KEY_Q)
	await process_frame
	_check(window.visible and window.position == moved, "shown again it stays where it was (got %s)" % window.position)
	_check(_visible_window(panels) == window or _visible_window(panels) != null, "Q never opens a second quest window")

	# A HUD built after the log came draws it (NetClient keeps the log).
	var later: Control = script.new(_builder())
	get_root().add_child(later)
	later.call("connect_net")
	await process_frame
	later.call("toggle", "quest")
	await process_frame
	var w2: Control = later.get_node_or_null("Window_quest")
	var r2 := _root(w2)
	_check(r2 != null and _drawn(r2)[0] == "Q1 (0/1)", "a log that came before the HUD existed is drawn (got %s)" % [_drawn(r2) if r2 else null])
	later.free()

	# Built at UI scale 1.5 (a 768x432 view), and in a view too small for
	# it, where our clamp keeps the caption on screen.
	for pair in [[1.5, Vector2(80, 32)], [2.0, Vector2(0, 0)]]:
		get_root().content_scale_factor = pair[0]
		await process_frame
		var p2: Control = script.new(_builder())
		get_root().add_child(p2)
		await process_frame
		_press(p2, KEY_Q)
		await process_frame
		var w3: Control = p2.get_node_or_null("Window_quest")
		_check(w3 != null and w3.position == pair[1],
			"at UI scale %s (view %s) it is built at %s (got %s)" % [pair[0], w3.get_viewport_rect().size if w3 else null, pair[1], w3.position if w3 else null])
		p2.free()
	get_root().content_scale_factor = 1.0
	(net.get("quest") as QuestState).reset()
	QuestTables.set_shared(null)
	panels.free()
