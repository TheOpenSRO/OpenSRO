extends SceneTree

## The registry-framed windows (round 586). Storage, exchange, system, party
## match and auto potion are CIFMainFrame windows the client builds from
## resinfo\ginterface.txt: the entry gives the window's size and its
## `mframe_wnd_` frame, CIFMainFrame's OnCreate (0x816f80) adds a caption at
## (10, 12, width - 21, 12), a drag strip at (10, 0, width - 21, 34) and a
## close button at (width - 26, 10), and the layout goes in at the window's
## origin. Before this round HudWindow ignored the registry: each of these
## windows was sized to its layout alone and drew no outer frame at all,
## with ifalchemybox's caption row and a 42-pixel drag strip floating over
## empty space.
##
## Every fixture here is synthetic -- control names, IDs and rects copied
## from the real layouts, textures made at the real pieces' sizes (the
## `mframe_wnd_` set measured by the GUI audit: corners 40x68 over 40x48,
## sides 40 wide, top and bottom 68 and 48 tall) -- and no game data:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_registry_frame_test.gd

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const MFRAME := "interface\\frame\\mframe_wnd_"
## mframe_wnd_'s eight pieces at their measured sizes.
const MFRAME_PIECES := {
	"left_up": Vector2i(40, 68), "mid_up": Vector2i(128, 68), "right_up": Vector2i(40, 68),
	"left_side": Vector2i(40, 128), "right_side": Vector2i(40, 128),
	"left_down": Vector2i(40, 48), "mid_down": Vector2i(128, 48), "right_down": Vector2i(40, 48),
}

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, rect: String, ddj: String = "",
		id: int = 0, text: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"1\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, id, rect, text]

func _section(section_name: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section_name, body]

## ginterface.txt's entries for the windows under test, in the file's own
## shape: GDR_EXCHANGE's rect in its three #ifdef branches, GDR_PARTY_MATCH
## and GDR_AUTO_POTION in sections of their own.
func _registry() -> String:
	var exchange := "\tGDR_EXCHANGE:CIFExchange\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tID=INTEGER,\"26\"\n#ifdef APPLY_EXCHANGE_UPDATE_1TH\n#ifdef UI_UPDATE_2009_FIRST\n\t\tRect=RECT,\"200,200,254,361\"\n#else\n\t\tRect=RECT,\"200,200,363,363\"\n#endif\n#else\n\t\tRect=RECT,\"200,200,254,361\"\n#endif\n\t\tText=STRING,\"UIIT_STT_EXCHANGE\"\n\t}\n" % MFRAME
	return "Interface Text\n\n" \
		+ _section("Create", exchange
			+ _control("GDR_COMMUNITY", "CIFCommunity", "0,0,477,393", MFRAME, 23, "UIIT_STT_COMMUNITY")
			+ _control("GDR_STORAGEROOM", "CIFStorageRoom", "0,0,254,317", MFRAME, 19, "UIIT_STT_STORAGEROOM")
			+ _control("GDR_SYSTEM", "CIFSystemWnd", "300,200,214,245", MFRAME, 98, "UIIT_PAG_SYSTEM")) \
		+ _section("PartyMatch", _control("GDR_PARTY_MATCH", "CIFPartyMatch", "0,0,785,480", MFRAME, 130, "UIIT_PAG_PARTYMATCH_PSEARCH")) \
		+ _section("AutoPotion", _control("GDR_AUTO_POTION", "CIFAutoPotion", "0,0,394,520", MFRAME, 135, "UIIT_PAG_MACROPOTION_TITLE"))

func _layout(body: String) -> String:
	return "Interface Text\n\n" + _section("Create", body)

## ifstorageroom.txt's frame and its gold strip: a 245x307 layout.
func _storage() -> String:
	return _layout(_control("GDR_STORAGE_TXT_MONEY_TITLE", "CIFStatic", "9,283,236,24", "interface\\store\\str_slot_01.ddj", 14)
		+ _control("GDR_STORAGE_BG_CTRL", "CIFSubFrame", "9,38,236,241", "interface\\frame\\sframe_wnd_", 4))

## ifsystemwnd.txt's Create section, IDs and rects as authored.
func _system() -> String:
	return _layout(_control("GDR_SYSTEM_BTN_QUIT", "CIFButton", "31,192,0,0", "interface\\system\\sys_button.ddj", 14)
		+ _control("GDR_SYSTEM_BTN_RESTART", "CIFButton", "31,159,0,0", "interface\\system\\sys_button.ddj", 13)
		+ _control("GDR_SYSTEM_BTN_CAS_HELP", "CIFButton", "31,125,0,0", "interface\\system\\sys_button.ddj", 12)
		+ _control("GDR_SYSTEM_BTN_HELP", "CIFButton", "31,92,0,0", "interface\\system\\sys_button.ddj", 11)
		+ _control("GDR_SYSTEM_BTN_OPTION", "CIFButton", "31,58,0,0", "interface\\system\\sys_button.ddj", 10)
		+ _control("GDR_SYSTEM_FRAME", "CIFFrame", "17,45,180,185", "interface\\inventory\\int_window_", 6)
		+ _control("GDR_SYSTEM_BGTILE", "CIFNormalTile", "33,82,148,110", "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj", 5))

## ifexchange.txt's two subframes and the lattice under them: 245x352.
func _exchange() -> String:
	return _layout(_control("GDR_EXCHANGE_MY_SUBFRAME", "CIFSubFrame", "9,182,236,141", "interface\\frame\\sframe_wnd_")
		+ _control("GDR_EXCHANGE_OTHER_SUBFRAME", "CIFSubFrame", "9,38,236,141", "interface\\frame\\sframe_wnd_")
		+ _control("GDR_EXCHANGE_BGTILE", "CIFNormalTile", "9,327,236,25", "interface\\ifcommon\\bg_tile\\com_bg_tile_c.ddj"))

## ifpartymatch.txt's frame and one control from each section CIFPartyMatch
## builds.
func _partymatch() -> String:
	return "Interface Text\n\n" \
		+ _section("Create", _control("GDR_PARTYMATCH_FRAME", "CIFFrame", "12,42,762,428", "interface\\inventory\\int_window_", 1)) \
		+ _section("SearchInfo", _control("GDR_PARTYMATCH_SEARCH_FRAME", "CIFFrame", "21,58,735,61", "interface\\frame\\frameg_wnd_", 2)) \
		+ _section("SlotListButton", _control("GDR_PARTYMATCH_BTN_PREV", "CIFButton", "300,440,0,0", "", 3)) \
		+ _section("SlotList", _control("GDR_PARTYMATCH_SLOT_1", "CIFPartyMatchSlot", "28,144,715,24", "", 4))

## ifautopotion.txt's frame and one control from each extra section.
func _autopotion() -> String:
	return "Interface Text\n\n" \
		+ _section("Create", _control("GDR_AUTO_POTION_FRAME_1", "CIFFrame", "13,42,368,465", "interface\\inventory\\int_window_", 1)) \
		+ _section("AbnormalSlot", _control("GDR_AUTO_POTION_ABNORMAL", "CIFStatic", "23,197,347,73", "", 2)) \
		+ _section("PotionDelaySlot", _control("GDR_AUTO_POTION_DELAY", "CIFStatic", "23,283,347,73", "", 3))

## A self-framed window, as a control: its frame at the origin.
func _community() -> String:
	return _layout(_control("GDR_COMMUNITY_FRAME", "CIFFrame", "0,0,464,381", "interface\\messagebox\\msgbox2_window_", 1))

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_STT_STORAGEROOM", "Warehouse"], ["UIIT_STT_EXCHANGE", "Trade"],
			["UIIT_PAG_SYSTEM", "System menu"], ["UIIT_PAG_PARTYMATCH_PSEARCH", "Party search"],
			["UIIT_PAG_MACROPOTION_TITLE", "Potion macro"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifstorageroom.txt"] = UiLayoutParser.parse(_storage())
	cache["resinfo\\ifsystemwnd.txt"] = UiLayoutParser.parse(_system())
	cache["resinfo\\ifexchange.txt"] = UiLayoutParser.parse(_exchange())
	cache["resinfo\\ifpartymatch.txt"] = UiLayoutParser.parse(_partymatch())
	cache["resinfo\\ifautopotion.txt"] = UiLayoutParser.parse(_autopotion())
	cache["resinfo\\ifcommunity.txt"] = UiLayoutParser.parse(_community())
	cache["resinfo\\ifquest.txt"] = UiLayoutParser.parse(_community())
	# The registry as the builder would have read it from the archive: parsed,
	# and (for a lookup that selects #ifdef branches) its raw text.
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	var textures: Dictionary = builder.get("_texture_cache")
	for piece in MFRAME_PIECES:
		var img := Image.create(MFRAME_PIECES[piece].x, MFRAME_PIECES[piece].y, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.4, 0.3, 1.0))
		textures[(MFRAME + piece + ".ddj").to_lower()] = ImageTexture.create_from_image(img)
	return builder

## The mframe_wnd_ pieces drawn in `window`, as {piece: rect relative to the
## window}, and the lowest child index they hang under.
func _frame_pieces(builder: UiBuilder, window: Control) -> Dictionary:
	var by_tex := {}
	var textures: Dictionary = builder.get("_texture_cache")
	for piece in MFRAME_PIECES:
		by_tex[textures[(MFRAME + piece + ".ddj").to_lower()].get_instance_id()] = piece
	var out := {}
	for n in window.find_children("*", "TextureRect", true, false):
		var t := (n as TextureRect).texture
		if t != null and by_tex.has(t.get_instance_id()):
			var r := (n as Control).get_global_rect()
			out[by_tex[t.get_instance_id()]] = Rect2(r.position - window.global_position, r.size)
	return out

## Every piece at its own size, each edge spanning the gap between its two
## corners (round 584's frame geometry), over a window of `size`.
func _check_frame(label: String, pieces: Dictionary, size: Vector2) -> void:
	_check(pieces.size() == 8, "%s: the registry's mframe_wnd_ frame is drawn, all eight pieces (got %s)" % [label, pieces.keys()])
	if pieces.size() != 8:
		return
	var w := size.x
	var h := size.y
	var want := {
		"left_up": Rect2(0, 0, 40, 68), "mid_up": Rect2(40, 0, w - 80, 68), "right_up": Rect2(w - 40, 0, 40, 68),
		"left_side": Rect2(0, 68, 40, h - 116), "right_side": Rect2(w - 40, 68, 40, h - 116),
		"left_down": Rect2(0, h - 48, 40, 48), "mid_down": Rect2(40, h - 48, w - 80, 48), "right_down": Rect2(w - 40, h - 48, 40, 48),
	}
	for piece in want:
		_check(pieces[piece] == want[piece], "%s: %s at %s (got %s)" % [label, piece, want[piece], pieces[piece]])

func _node_at(window: Control, control_name: String) -> Rect2:
	var n := window.call("node", control_name) as Control
	if n == null:
		return Rect2(-1, -1, -1, -1)
	return Rect2(n.global_position - window.global_position, n.size)

## One press on the window at `at`: whether it started a drag.
func _drags(window: Control, at: Vector2) -> bool:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	window.call("_gui_input", press)
	var dragging: bool = window.get("_dragging")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	window.call("_gui_input", release)
	return dragging

## The CIFMainFrame chrome and the frame, for a registry window of `size`.
func _check_registry_window(label: String, builder: UiBuilder, window: Control, size: Vector2,
		caption: String) -> void:
	_check(window.size == size, "%s: the window is the registry's %s (got %s)" % [label, size, window.size])
	_check_frame(label, _frame_pieces(builder, window), size)
	var root := window.get("panel_root") as Control
	_check(root != null and root.position == Vector2.ZERO,
		"%s: the layout's origin is the window's (got %s)" % [label, root.position if root != null else null])
	var frame_index := 999
	for n in window.find_children("*", "TextureRect", true, false):
		if (n as TextureRect).texture != null and window.is_ancestor_of(n):
			var top := n as Node
			while top.get_parent() != window:
				top = top.get_parent()
			if top != root:
				frame_index = mini(frame_index, top.get_index())
	_check(root != null and frame_index < root.get_index(),
		"%s: the frame is behind the layout (frame child %d, layout child %d)" % [label, frame_index, root.get_index() if root != null else -1])
	var bar := window.get_node_or_null("TitleBar") as Label
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == size.x - 21,
		"%s: the caption is CIFMainFrame's (10, 12, %d wide) (got %s)" % [label, size.x - 21, [bar.position, bar.size] if bar != null else null])
	_check(bar != null and bar.text == caption, "%s: the caption is the registry's '%s' (got '%s')" % [label, caption, bar.text if bar != null else null])
	_check(bar != null and bar.vertical_alignment == VERTICAL_ALIGNMENT_TOP,
		"%s: the caption is top-aligned, CIFMainFrame's VAlign 0" % label)
	var close := window.get_node_or_null("CloseButton") as Control
	_check(close != null and close.position == Vector2(size.x - 26, 10) and close.size == Vector2(16, 16),
		"%s: the close button is at (%d, 10), 16x16 (got %s)" % [label, size.x - 26, [close.position, close.size] if close != null else null])
	_check(not _drags(window, Vector2(5, 20)), "%s: a press left of the drag strip (x 5) does not drag" % label)
	_check(_drags(window, Vector2(100, 20)), "%s: a press in the drag strip drags" % label)
	_check(not _drags(window, Vector2(100, 38)), "%s: a press below the 34-pixel drag strip does not drag" % label)

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var panels_script := load(PANELS_PATH) as GDScript
	_check(panels_script != null and panels_script.can_instantiate(), "HudPanels compiles")
	if panels_script != null and panels_script.can_instantiate():
		await _panel_checks(panels_script)
	_registry_lookup_checks()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _panel_checks(panels_script: GDScript) -> void:
	var builder := _builder()
	var panels: Node = panels_script.new(builder)
	root.add_child(panels)

	var storage := panels.call("open", "storage") as Control
	_check(storage != null, "the storage window builds from the fixture")
	if storage != null:
		await process_frame
		_check_registry_window("storage", builder, storage, Vector2(254, 317), "Warehouse")
		_check(_node_at(storage, "GDR_STORAGE_BG_CTRL").position == Vector2(9, 38),
			"storage: GDR_STORAGE_BG_CTRL stays at its authored 9,38 inside the frame (got %s)" % _node_at(storage, "GDR_STORAGE_BG_CTRL").position)

	var exchange := panels.call("open", "exchange") as Control
	_check(exchange != null, "the exchange window builds from the fixture")
	if exchange != null:
		await process_frame
		_check_registry_window("exchange", builder, exchange, Vector2(254, 361), "Trade")

	var partymatch := panels.call("open", "partymatch") as Control
	_check(partymatch != null, "the party match window builds from the fixture")
	if partymatch != null:
		await process_frame
		_check_registry_window("partymatch", builder, partymatch, Vector2(785, 480), "Party search")
		_check(_node_at(partymatch, "GDR_PARTYMATCH_FRAME").position == Vector2(12, 42),
			"partymatch: its layout frame stays at 12,42 (got %s)" % _node_at(partymatch, "GDR_PARTYMATCH_FRAME").position)

	var autopotion := panels.call("open", "autopotion") as Control
	_check(autopotion != null, "the auto potion window builds from the fixture")
	if autopotion != null:
		await process_frame
		_check_registry_window("autopotion", builder, autopotion, Vector2(394, 520), "Potion macro")

	# CIFSystemWnd::Create sizes its window in code after building it.
	var system := panels.call("open", "system") as Control
	_check(system != null, "the system window builds from the fixture")
	if system != null:
		for i in 4:
			await process_frame
		_check_registry_window("system", builder, system, Vector2(214, 212), "System menu")
		var cas := system.call("node", "GDR_SYSTEM_BTN_CAS_HELP") as CanvasItem
		_check(cas != null and not cas.visible, "system: the Customer Center button is hidden")
		var rows := [["GDR_SYSTEM_BTN_OPTION", 58], ["GDR_SYSTEM_BTN_HELP", 92],
			["GDR_SYSTEM_BTN_RESTART", 126], ["GDR_SYSTEM_BTN_QUIT", 160]]
		for row in rows:
			var at := _node_at(system, row[0]).position
			_check(at == Vector2(31, row[1]), "system: %s is restacked to (31, %d) (got %s)" % [row[0], row[1], at])
		_check(_node_at(system, "GDR_SYSTEM_FRAME") == Rect2(17, 45, 180, 151),
			"system: its inner frame is 180x151 at 17,45 (got %s)" % _node_at(system, "GDR_SYSTEM_FRAME"))
		_check(_node_at(system, "GDR_SYSTEM_BGTILE") == Rect2(33, 82, 148, 112),
			"system: its tile is 148x112 at 33,82 (got %s)" % _node_at(system, "GDR_SYSTEM_BGTILE"))

	# A self-framed window is unchanged: its layout's size, no registry
	# frame, and ifalchemybox's chrome. (This was the community window until
	# it was rebuilt from res_ui\guild.2dt (round 595). The action window
	# is a tab of the main popup since round 587; the quest panel still has
	# its own self-framed window until res_ui\questlist.2dt is built.)
	var quest := panels.call("open", "quest") as Control
	_check(quest != null, "the quest window builds from the fixture")
	if quest != null:
		await process_frame
		_check(quest.size == Vector2(464, 381), "quest: stays self-framed at its layout's 464x381 (got %s)" % quest.size)
		_check(_frame_pieces(builder, quest).is_empty(), "quest: no registry frame")
		var bar := quest.get_node_or_null("TitleBar") as Control
		_check(bar != null and bar.position == Vector2(10, 18), "quest: its caption stays at (10, 18) (got %s)" % (bar.position if bar != null else null))
		var close := quest.get_node_or_null("CloseButton") as Control
		_check(close != null and close.position == Vector2(464 - 26, 12), "quest: its close button stays at (438, 12) (got %s)" % (close.position if close != null else null))
		_check(_drags(quest, Vector2(5, 38)), "quest: its 42-pixel drag strip is unchanged")
	# The community is no longer built from ifcommunity.txt, which the client
	# never loads: with no res_ui\guild.2dt it does not open at all.
	_check(panels.call("open", "community") == null, "community: not built from ifcommunity.txt")
	panels.free()

## UiBuilder.window_def finds entries outside "Create" and selects #ifdef
## branches.
func _registry_lookup_checks() -> void:
	var builder := _builder()
	var pm := builder.window_def("GDR_PARTY_MATCH")
	_check(pm != null and pm.rect == Rect2i(0, 0, 785, 480),
		"window_def finds GDR_PARTY_MATCH in its own \"PartyMatch\" section (got %s)" % (pm.rect if pm != null else null))
	var takes_defines := false
	for m in builder.get_method_list():
		if m["name"] == "window_def":
			takes_defines = (m["args"] as Array).size() >= 3
	_check(takes_defines, "window_def takes #ifdef defines")
	if not takes_defines:
		return
	var both: UiLayoutParser.ControlDef = builder.call("window_def", "GDR_EXCHANGE",
		PackedStringArray(["APPLY_EXCHANGE_UPDATE_1TH", "UI_UPDATE_2009_FIRST"]), true)
	var first: UiLayoutParser.ControlDef = builder.call("window_def", "GDR_EXCHANGE",
		PackedStringArray(["APPLY_EXCHANGE_UPDATE_1TH"]), true)
	_check(both != null and both.rect.size == Vector2i(254, 361),
		"GDR_EXCHANGE with both defines is 254x361 (got %s)" % (both.rect if both != null else null))
	_check(first != null and first.rect.size == Vector2i(363, 363),
		"GDR_EXCHANGE with APPLY_EXCHANGE_UPDATE_1TH alone is 363x363 (got %s)" % (first.rect if first != null else null))
