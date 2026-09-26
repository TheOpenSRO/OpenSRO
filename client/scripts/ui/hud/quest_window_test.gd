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
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		cache["res_ui\\questlist.2dt"] = Reader.parse(_file(_questlist()))
	for p in [ROW_ART, SMALL_BOX, CHECK_ON, CHECK_OFF, WORLD, VIEW, CLOSE]:
		_tex(builder, p, Vector2i(16, 16))
	return builder

# --- helpers ----------------------------------------------------------------

class _Quest:
	var quest_id: int
	var quest_name: String
	var accepted: bool
	var completed: bool
	var kills: int
	func _init(n: String, a: bool, c: bool, id: int = 0, k: int = 0) -> void:
		quest_name = n
		accepted = a
		completed = c
		quest_id = id
		kills = k

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

func _quests(n: int) -> Array:
	var out := []
	for i in n:
		out.append(_Quest.new("Q%d" % (i + 1), true, false, i + 1))
	return out

# --- the checks -------------------------------------------------------------

func _run() -> void:
	# The client's default window, 1152x648 (the headless root starts at
	# 64x64 and takes a size only after its first frame).
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var script := load(PANELS_PATH) as GDScript
	var panels: Control = script.new(_builder())
	get_root().add_child(panels)
	await process_frame
	var net := _net()
	_check(net != null, "NetClient is registered for this suite")
	if net == null:
		return
	panels.call("connect_net")
	# A quest list that arrives before the window is built is kept and drawn
	# when it is: one accepted in progress, one not accepted, one completed.
	net.emit_signal("quest_list_result", [_Quest.new("Wolf Hunt", true, false),
		_Quest.new("Bear Hunt", false, false), _Quest.new("Fox Hunt", true, true)], "")

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
	_check(panels.get("last_populated") == "quest", "opening it asks the server for the list (_populate)")
	# OnCreate (0x6e3ff0): centred, then x = 0x50: (80, 324 - 184).
	_check(window.position == Vector2(80, 140), "it sits at (0x50, centred y) = (80, 140) in the 1152x648 view (got %s)" % window.position)
	# CNIFMainFrame's chrome (0x479a50).
	var bar := window.get_node_or_null("TitleBar") as Control
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == 603,
		"the caption is at (10, 12), 603 wide (got %s)" % (Rect2(bar.position, bar.size) if bar else null))
	var close := window.get_node_or_null("CloseButton") as Control
	_check(close != null and close.position == Vector2(598, 10) and close.size == Vector2(16, 16),
		"the close button is at (598, 10), 16x16 (got %s)" % (Rect2(close.position, close.size) if close else null))
	_check(window.call("in_drag_strip", Vector2(300, 30)) and not window.call("in_drag_strip", Vector2(300, 36)),
		"it drags by (10, 0, 603, 34)")
	_check(qroot != null and qroot.get_node_or_null("Text") == null,
		"record 0's text is the caption, not a label over the window")
	_check(_rect_in(window, _at(qroot, [2])) == Rect2(11, 38, 603, 322) and _at(qroot, [2]).is_visible_in_tree(),
		"the inner frame 2 is shown at (11, 38), 603x322")
	_check(_rect_in(window, _at(qroot, [3])) == Rect2(38, 68, 547, 284) and _at(qroot, [3]).is_visible_in_tree(),
		"the tile 3 is shown at (38, 68), 547x284")
	var row_rects := []
	for id in [5, 77, 141]:
		row_rects.append(_rect_in(window, _at(qroot, [id])))
	_check(row_rects == [Rect2(16, 43, 576, 32), Rect2(16, 74, 576, 32), Rect2(16, 322, 576, 32)],
		"the rows are at (16, 43), (16, 74) .. (16, 322), 576x32 (got %s)" % [row_rects])

	# The rows: the player's quests, in file order from the top.
	_check(_drawn(qroot) == ["Wolf Hunt", "", "", "", "", "", "", "", "", ""],
		"the list that came before the window was built is on row 5; a quest not accepted and a completed one are not rows (got %s)" % [_drawn(qroot)])
	var row := _at(qroot, [5])
	_check(_at(row, [7]) != null and _at(row, [7]).visible, "a filled row's small box 7 is shown (0x6e5830(0))")
	var box := _at(row, [8]) as BaseButton
	var mark := box.get_node_or_null("Mark") as CanvasItem if box != null else null
	_check(box != null and box.visible and not box.button_pressed and mark != null and not mark.visible,
		"its check box 8 is shown and unchecked (0x482cb0(0))")
	_check(box != null and box.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"the check box takes no click (the quick list it feeds is not built)")
	_check(_at(row, [18]) != null and _at(row, [18]).visible and _at(row, [19]) != null and _at(row, [19]).visible,
		"its world-map 18 and content-view 19 buttons are shown")
	_check(_at(row, [11]) != null and not _at(row, [11]).visible, "its status text 11 is hidden in quest mode")
	_check(_at(row, [75]) != null and not _at(row, [75]).visible, "its time 75 is hidden for a quest with no time (0x6e5a60)")
	var name_label := _at(row, [16]).get_node_or_null("Text") as Label if _at(row, [16]) else null
	_check(name_label != null and name_label.get_theme_color("font_color") == Color(1, 1, 1, 1),
		"the name is drawn in 0xffffffff (0x475ce0(-1))")
	_check(_text(_at(row, [16])) != "SAMPLE-QUEST" and _text(_at(_at(qroot, [77]), [16])) != "SAMPLE-QUEST",
		"the editor-only sample text is never drawn")
	for id in ROW_IDS.slice(1):
		_check(_at(qroot, [id]) != null and not _at(qroot, [id]).visible, "row %d, past the list, is hidden" % id)

	# A reply while the window is up redraws it; the wheel scrolls it.
	net.emit_signal("quest_list_result", _quests(12), "")
	await process_frame
	_check(_drawn(qroot) == ["Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Q7", "Q8", "Q9", "Q10"],
		"twelve quests fill the ten rows (got %s)" % [_drawn(qroot)])
	_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	_check(_drawn(qroot)[0] == "Q2" and _drawn(qroot)[9] == "Q11", "the wheel down moves the list one quest (0x4794f0, got %s)" % [_drawn(qroot)])
	for i in 20:
		_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	_check(_drawn(qroot) == ["Q12", "", "", "", "", "", "", "", "", ""],
		"the scroll stops at the last quest, 0..count-1 (0x478960, got %s)" % [_drawn(qroot)])
	_wheel(window, MOUSE_BUTTON_WHEEL_UP)
	_check(_drawn(qroot)[0] == "Q11", "the wheel up moves it back one (0x4794d0, got %s)" % [_drawn(qroot)])
	# The reply opening asks for, unchanged: the scroll stays (0x6e12b0
	# keeps it); in any order: the rows are sorted by quest id.
	net.emit_signal("quest_list_result", _quests(12), "")
	_check(_drawn(qroot)[0] == "Q11", "the same list again keeps the scroll where it was (got %s)" % [_drawn(qroot)])
	var shuffled := _quests(12)
	shuffled.reverse()
	var mid: Variant = shuffled[3]
	shuffled.remove_at(3)
	shuffled.insert(9, mid)
	net.emit_signal("quest_list_result", shuffled, "")
	_check(_drawn(qroot)[0] == "Q11" and _drawn(qroot)[1] == "Q12",
		"a shuffled reply of the same quests draws the same rows (got %s)" % [_drawn(qroot)])
	window.set("_scroll", 0)
	if window.has_method("refresh"):
		window.call("refresh")
	_check(_drawn(qroot) == ["Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Q7", "Q8", "Q9", "Q10"],
		"the rows are in quest-id order whatever order the reply came in (got %s)" % [_drawn(qroot)])
	_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	# A counted kill changes nothing drawn: the scroll stays (ours).
	var counted := _quests(12)
	(counted[4] as _Quest).kills = 1
	net.emit_signal("quest_list_result", counted, "")
	_check(_drawn(qroot)[0] == "Q3", "a reply that only counts a kill keeps the scroll (got %s)" % [_drawn(qroot)])
	# A quest gone from the list is a change: 0x6e3810 starts from the first
	# quest.
	var changed := _quests(12)
	changed.remove_at(4)
	net.emit_signal("quest_list_result", changed, "")
	_check(_drawn(qroot)[0] == "Q1", "a changed list starts from the first quest again (0x6e3810, got %s)" % [_drawn(qroot)])
	net.emit_signal("quest_list_result", [], "not logged in")
	_check(_drawn(qroot)[0] == "Q1", "a refused list keeps the last one (got %s)" % [_drawn(qroot)])

	# Q toggles; showing it does not move it (0x6e12b0 has no 0x798c50).
	var moved := Vector2(300, 200)
	window.position = moved
	_press(panels, KEY_Q)
	await process_frame
	_check(not window.visible, "Q again hides it")
	_press(panels, KEY_Q)
	await process_frame
	_check(window.visible and window.position == moved, "shown again it stays where it was (got %s)" % window.position)
	# Reopening keeps the scroll: ShowWindow (0x6e12b0) only refreshes, and
	# the list opening asks for is the same list.
	_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	_wheel(window, MOUSE_BUTTON_WHEEL_DOWN)
	_press(panels, KEY_Q)
	await process_frame
	_press(panels, KEY_Q)
	await process_frame
	net.emit_signal("quest_list_result", changed, "")
	_check(_drawn(qroot)[0] == "Q3", "closed and reopened, with the same list sent again, the scroll is kept (got %s)" % [_drawn(qroot)])
	_check(_visible_window(panels) == window, "Q never opens a second window")
	panels.call("toggle", "quest")
	await process_frame
	_check(not window.visible, "the menu's quest item toggles the same window")

	# The quest list that came before the HUD existed: NetClient keeps it.
	var kept := "last_quest_list" in net
	_check(kept, "NetClient keeps the last quest list")
	if kept:
		net.set("last_quest_list", [_Quest.new("Kept", true, false)])
		net.set("has_quest_list", true)
		var later: Control = script.new(_builder())
		get_root().add_child(later)
		later.call("connect_net")
		await process_frame
		later.call("toggle", "quest")
		await process_frame
		var w2 := _visible_window(later)
		var r2 := _root(w2)
		_check(r2 != null and _drawn(r2)[0] == "Kept", "a quest list that came before the HUD existed is drawn (got %s)" % [_drawn(r2) if r2 else null])
		net.set("last_quest_list", [])
		net.set("has_quest_list", false)
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
		var w3 := _visible_window(p2)
		_check(w3 != null and w3.position == pair[1],
			"at UI scale %s (view %s) it is built at %s (got %s)" % [pair[0], w3.get_viewport_rect().size if w3 else null, pair[1], w3.position if w3 else null])
		p2.free()
	get_root().content_scale_factor = 1.0
	panels.free()
