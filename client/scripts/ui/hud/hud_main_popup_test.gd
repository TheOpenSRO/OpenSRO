extends SceneTree

## The main popup (docs/RE_COMPLETION.md, the main popup round): the
## character, inventory with equipment, skill, action, party and academy are
## panes of ONE registry-framed window, CIFMainPopup, switched by tab. Every
## fixture below carries the authored names, IDs and rects of the real
## controls (resinfo\ginterface.txt's GDR_MAINPOPUP, resinfo\ifmainpopup.txt
## with its APPLY_MENTOR_SYSTEM branches spelled as the archive spells them,
## and a frame and a few controls from each pane's layout) with synthetic
## textures -- never real game data:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_main_popup_test.gd
##
## Checked, each against what the binary does (addresses in the record):
## - every tab opens the same 388x408 window, framed by mframe_wnd_, with
##   CIFMainFrame's caption and close button;
## - each pane at its ifmainpopup rect, its own layout at the pane's origin;
## - the tab strip and its decoration hidden at create;
## - per tab: which panes show, the caption, the background tile's rect,
##   and the window's side of the screen;
## - the keys' toggle: a key hides the window only on its own tab;
## - the equipment pane's avatar mode resets when another tab hides it;
## - the character pane is built from ifplayerinfo_trijob2.txt and its stat
##   rows are still filled from the server's stats;
## - drag targets over the bag only count while the inventory tab shows.
##
## New methods are reached through call / get, so a tree without them FAILS
## here rather than failing to parse.

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const MFRAME := "interface\\frame\\mframe_wnd_"
const MFRAME_PIECES := {
	"left_up": Vector2i(40, 68), "mid_up": Vector2i(128, 68), "right_up": Vector2i(40, 68),
	"left_side": Vector2i(40, 128), "right_side": Vector2i(40, 128),
	"left_down": Vector2i(40, 48), "mid_down": Vector2i(128, 48), "right_down": Vector2i(40, 48),
}
const POPUP_SIZE := Vector2(388, 408)
const POPUP_LAYOUT := "resinfo\\ifmainpopup.txt"

## ifmainpopup.txt's panes (Create section, APPLY_MENTOR_SYSTEM taken).
const PANES := {
	"GDR_APPRENTICESHIP": ["CIFApprenticeShip", 77, "13,38,365,355"],
	"GDR_QUEST": ["CIFQuest", 76, "13,38,365,355"],
	"GDR_PLAYERINFO": ["CIFPlayerInfo", 75, "13,38,364,356"],
	"GDR_ACTION": ["CIFAction", 74, "13,38,364,357"],
	"GDR_SKILL": ["CIFSkill", 73, "13,63,364,333"],
	"GDR_PARTY": ["CIFParty", 72, "13,38,364,337"],
	"GDR_EQUIPMENT": ["CIFEquipment", 71, "198,41,178,355"],
	"GDR_INVENTORY": ["CIFInventory", 70, "13,63,176,333"],
}
## Each pane's own frame (the control at its layout's origin).
const PANE_FRAMES := {
	"GDR_INVENTORY": "GDR_INVENTORY_FRAME", "GDR_EQUIPMENT": "GDR_EQ_FRAME",
	"GDR_PLAYERINFO": "GDR_PI_SUBFRAME", "GDR_SKILL": "GDR_SKILL_FRAME",
	"GDR_ACTION": "GDR_ACTION_BG_CTRL", "GDR_PARTY": "GDR_PARTY_FRAMEL",
	"GDR_APPRENTICESHIP": "GDR_APPRENTICESHIP_FRAMEL",
}
## tab -> [panes shown, caption, tile rect or null, right-hand side]
const TABS := {
	"character": [["GDR_PLAYERINFO"], "Char sheet", null, false],
	"inventory": [["GDR_INVENTORY", "GDR_EQUIPMENT"], "Bag", Rect2(189, 68, 9, 292), true],
	"skill": [["GDR_SKILL"], "Skills", null, true],
	"action": [["GDR_ACTION"], "Actions", Rect2(40, 154, 308, 124), true],
	"party": [["GDR_PARTY"], "Group", null, true],
	"academy": [["GDR_APPRENTICESHIP"], "Mentor", null, false],
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

func _layout(body: String) -> String:
	return "Interface Text\n\n" + _section("Create", body)

func _registry() -> String:
	return "Interface Text\n\n" + _section("Create",
		_control("GDR_MAINPOPUP", "CIFMainPopup", "595,262,388,408", MFRAME, 25)
		+ _control("GDR_STORAGEROOM", "CIFStorageRoom", "0,0,254,317", MFRAME, 19))

## ifmainpopup.txt: the panes, then the tab strip in both #ifdef branches as
## the archive has them, then the background tile.
func _mainpopup() -> String:
	var body := "#ifdef APPLY_MENTOR_SYSTEM\n"
	body += _control("GDR_APPRENTICESHIP", "CIFApprenticeShip", PANES["GDR_APPRENTICESHIP"][2], "", 77)
	body += "#endif\n"
	for pane in PANES:
		if pane != "GDR_APPRENTICESHIP":
			body += _control(pane, PANES[pane][0], PANES[pane][2], "", PANES[pane][1])
	var mp := "interface\\mainpopup\\main_sysbutton_"
	body += "#ifdef APPLY_MENTOR_SYSTEM\n"
	body += _control("GDR_BTN_APPRENTICE", "CIFButton", "-36,330,28,28", mp + "apprenticeship.ddj", 16)
	body += _control("GDR_BTN_QUEST", "CIFButton", "-36,288,28,28", mp + "quest.ddj", 15)
	body += _control("GDR_BTN_PARTY", "CIFButton", "-36,246,28,28", mp + "party.ddj", 14)
	body += _control("GDR_BTN_ACT", "CIFButton", "-36,204,28,28", mp + "action.ddj", 13)
	body += _control("GDR_BTN_SKILL", "CIFButton", "-36,162,28,28", mp + "skill.ddj", 12)
	body += _control("GDR_BTN_INV", "CIFButton", "-36,120,28,28", mp + "inventory.ddj", 11)
	body += _control("GDR_BTN_CHAR", "CIFButton", "-36,78,28,28", mp + "character.ddj", 10)
	body += _control("GDR_MAINPOPUP_LEFT_DECO_STATIC", "CIFStatic", "-42,55,48,326", "interface\\mainpopup\\main_systab_02.ddj", 4)
	body += "#else\n"
	body += _control("GDR_BTN_QUEST", "CIFButton", "-36,306,28,28", mp + "quest.ddj", 15)
	body += _control("GDR_BTN_CHAR", "CIFButton", "-36,96,28,28", mp + "character.ddj", 10)
	body += _control("GDR_MAINPOPUP_LEFT_DECO_STATIC", "CIFStatic", "-42,73,48,284", "interface\\mainpopup\\main_systab.ddj", 4)
	body += "#endif\n"
	body += _control("GDR_MAINPOPUP_BG_TILE", "CIFStatic", "40,154,308,124", "interface\\ifcommon\\bg_tile\\com_bg_tile_a.ddj", 3)
	return _layout(body)

func _inventory() -> String:
	return _layout(_control("GDR_INVENTORY_STA_GOLD", "CIFStatic", "143,314,24,12", "", 12, "")
		+ _control("GDR_INVENTORY_FRAME", "CIFFrame", "0,0,176,308", "", 0))

## ifequipment.txt's worn slots at their authored rects, one avatar slot,
## the two change buttons and the frame.
const WORN_RECTS := {
	100: "5,86,32,32", 101: "5,129,32,32", 102: "141,86,32,32", 103: "141,129,32,32",
	104: "5,172,32,32", 105: "141,172,32,32", 106: "12,12,32,32", 107: "134,12,32,32",
	108: "141,308,32,32", 109: "5,215,32,32", 110: "141,215,32,32", 111: "5,258,32,32",
	112: "141,258,32,32",
}

func _equipment() -> String:
	var body := _control("GDR_AVATAR_SLOT_01", "CIFSlotWithHelp", "5,86,32,32", "", 113)
	for id in WORN_RECTS:
		body += _control("GDR_EQUIPMENT_SLOT_%d" % id, "CIFSlotWithHelp", WORN_RECTS[id], "", id)
	body += _control("GDR_EQ_BTN_CHANGE_EQUIP_SLOT", "CIFButton", "1,305,40,40", "", 14)
	body += _control("GDR_EQ_BTN_CHANGE_AVATAR_SLOT", "CIFButton", "1,305,40,40", "", 13)
	body += _control("GDR_EQ_FRAME", "CIFFrame", "0,0,178,355", "", 4)
	return _layout(body)

## ifplayerinfo_trijob2.txt's rows the stats fill, and its frame.
func _playerinfo() -> String:
	return _layout(_control("GDR_PI_JOB_ALIAS", "CIFStatic", "147,273,99,15", "", 70)
		+ _control("GDR_PI_TEXT_PHYATT_DAT", "CIFStatic", "75,171,98,15", "", 34)
		+ _control("GDR_PI_TEXT_INTELLECT_DAT", "CIFStatic", "84,143,30,12", "", 19)
		+ _control("GDR_PI_TEXT_STRENGTH_DAT", "CIFStatic", "84,114,30,12", "", 18)
		+ _control("GDR_PI_TEXT_HP_DAT", "CIFStatic", "153,114,228,11", "", 12)
		+ _control("GDR_PI_TEXT_STAT2", "CIFStatic", "89,85,28,12", "", 9)
		+ _control("GDR_PI_TEXT_LEVEL", "CIFStatic", "9,8,346,12", "", 2)
		+ _control("GDR_PI_SUBFRAME", "CIFSubFrame", "0,0,364,356", "", 1))

func _single(frame: String, rect: String) -> String:
	return _layout(_control(frame, "CIFFrame", rect, "", 1))

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_STT_CHARACTER", "Char sheet"], ["UIIT_STT_INVENTORY", "Bag"],
			["UIIT_STT_SKILL", "Skills"], ["UIIT_STT_ACTION", "Actions"],
			["UIIT_STT_PARTY", "Group"], ["UIIT_CTL_TC_TRAININGCAMP", "Mentor"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

## UiBuilder.load_layout's cache key for a layout read with these defines.
func _ifdef_key(path: String, defines: Array) -> String:
	return "%s%s%s" % [path, char(1), char(2).join(PackedStringArray(defines))]

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var cache: Dictionary = builder.get("_layout_cache")
	cache[_ifdef_key(POPUP_LAYOUT, ["APPLY_MENTOR_SYSTEM"])] = UiLayoutParser.parse(_mainpopup(), true, PackedStringArray(["APPLY_MENTOR_SYSTEM"]))
	cache["resinfo\\ifinventory.txt"] = UiLayoutParser.parse(_inventory())
	# ifstorageroom.txt's inner frame, for the warehouse the bag pairs with.
	cache["resinfo\\ifstorageroom.txt"] = UiLayoutParser.parse(_single("GDR_STORAGE_BG_CTRL", "9,38,236,241"))
	cache["resinfo\\ifequipment.txt"] = UiLayoutParser.parse(_equipment())
	cache["resinfo\\ifplayerinfo_trijob2.txt"] = UiLayoutParser.parse(_playerinfo())
	cache["resinfo\\ifskill.txt"] = UiLayoutParser.parse(_single("GDR_SKILL_FRAME", "0,0,364,333"))
	cache["resinfo\\ifaction.txt"] = UiLayoutParser.parse(_single("GDR_ACTION_BG_CTRL", "0,0,364,117"))
	cache["resinfo\\ifparty.txt"] = UiLayoutParser.parse(_single("GDR_PARTY_FRAMEL", "0,0,364,303"))
	cache["resinfo\\ifapprenticeship.txt"] = UiLayoutParser.parse(_single("GDR_APPRENTICESHIP_FRAMEL", "0,0,364,303"))
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	var textures: Dictionary = builder.get("_texture_cache")
	for piece in MFRAME_PIECES:
		var img := Image.create(MFRAME_PIECES[piece].x, MFRAME_PIECES[piece].y, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.4, 0.3, 1.0))
		textures[(MFRAME + piece + ".ddj").to_lower()] = ImageTexture.create_from_image(img)
	return builder

func _frame_piece_count(builder: UiBuilder, window: Control) -> int:
	var ids := {}
	var textures: Dictionary = builder.get("_texture_cache")
	for piece in MFRAME_PIECES:
		ids[textures[(MFRAME + piece + ".ddj").to_lower()].get_instance_id()] = true
	var n := 0
	for node in window.find_children("*", "TextureRect", true, false):
		var t := (node as TextureRect).texture
		if t != null and ids.has(t.get_instance_id()):
			n += 1
	return n

func _rect_of(window: Control, control_name: String) -> Rect2:
	var n := window.call("node", control_name) as Control
	if n == null:
		return Rect2(-1, -1, -1, -1)
	return Rect2(n.global_position - window.global_position, n.size)

func _shows(window: Control, control_name: String) -> bool:
	var n := window.call("node", control_name) as CanvasItem
	return n != null and n.is_visible_in_tree()

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var panels_script := load(PANELS_PATH) as GDScript
	_check(panels_script != null and panels_script.can_instantiate(), "HudPanels compiles")
	if panels_script != null and panels_script.can_instantiate():
		var spec: Array = (panels_script.get_script_constant_map().get("PANELS", {}) as Dictionary).get("character", [])
		_check(not spec.is_empty() and spec[0] == "resinfo\\ifplayerinfo_trijob2.txt",
			"PANELS[\"character\"] is ifplayerinfo_trijob2.txt, the layout CIFPlayerInfo loads (got %s)" % [spec])
		await _popup_checks(panels_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _popup_checks(panels_script: GDScript) -> void:
	# A screen the client's own placement fits on (x needs 468, y 670).
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	await process_frame
	var builder := _builder()
	var panels: Control = panels_script.new(builder)
	root.add_child(panels)
	await process_frame

	# One window for every tab.
	var first: Control = panels.call("open", "inventory")
	_check(first != null, "the inventory tab opens")
	if first == null:
		panels.free()
		return
	var same := true
	for id in ["equipment", "character", "skill", "action", "party", "academy"]:
		var w: Control = panels.call("open", id)
		if w != first:
			same = false
			_check(false, "%s opens the same window as inventory (got %s)" % [id, w])
	_check(same, "inventory, equipment, character, skill, action, party and academy are one window")
	var window := first
	await process_frame
	await process_frame
	_check(window.size == POPUP_SIZE, "the window is GDR_MAINPOPUP's %s (got %s)" % [POPUP_SIZE, window.size])
	_check(_frame_piece_count(builder, window) == 8,
		"GDR_MAINPOPUP's mframe_wnd_ frame is drawn, all eight pieces (got %d)" % _frame_piece_count(builder, window))
	var bar := window.get_node_or_null("TitleBar") as Label
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == POPUP_SIZE.x - 21,
		"the caption is CIFMainFrame's (10, 12, 367 wide) (got %s)" % [[bar.position, bar.size] if bar != null else null])
	var close := window.get_node_or_null("CloseButton") as Control
	_check(close != null and close.position == Vector2(POPUP_SIZE.x - 26, 10),
		"the close button is CIFMainFrame's (362, 10) (got %s)" % [close.position if close != null else null])

	# The panes at their ifmainpopup rects, each pane's layout at its origin.
	for pane in PANES:
		var parts: PackedStringArray = String(PANES[pane][2]).split(",")
		var want := Rect2(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
		_check(_rect_of(window, pane) == want, "%s at its ifmainpopup rect %s (got %s)" % [pane, want, _rect_of(window, pane)])
		if PANE_FRAMES.has(pane):
			var frame_at := _rect_of(window, PANE_FRAMES[pane]).position
			_check(frame_at == want.position, "%s's layout starts at the pane's origin %s (its frame at %s)" % [pane, want.position, frame_at])

	# The tab strip and its decoration are hidden at create, and only the
	# APPLY_MENTOR_SYSTEM branch was built.
	var strip_shown := []
	for n in ["GDR_BTN_CHAR", "GDR_BTN_INV", "GDR_BTN_SKILL", "GDR_BTN_ACT", "GDR_BTN_PARTY",
			"GDR_BTN_QUEST", "GDR_BTN_APPRENTICE", "GDR_MAINPOPUP_LEFT_DECO_STATIC"]:
		if _shows(window, n):
			strip_shown.append(n)
	_check(_rect_of(window, "GDR_BTN_APPRENTICE") != Rect2(-1, -1, -1, -1) and strip_shown.is_empty(),
		"the tab strip is built (APPLY_MENTOR_SYSTEM) and hidden at create (shown: %s)" % [strip_shown])
	_check(window.find_children("GDR_BTN_CHAR*", "", true, false).size() == 1,
		"one GDR_BTN_CHAR: the #else branch is not built too")

	# Each tab: its panes, caption, tile and side.
	var view_w := window.get_viewport_rect().size.x
	for tab in TABS:
		panels.call("open", tab)
		await process_frame
		var spec: Array = TABS[tab]
		var shown := []
		for pane in PANES:
			if _shows(window, pane):
				shown.append(pane)
		shown.sort()
		var want_panes: Array = (spec[0] as Array).duplicate()
		want_panes.sort()
		_check(shown == want_panes, "%s tab: panes shown %s (got %s)" % [tab, want_panes, shown])
		var caption := window.get_node_or_null("TitleBar") as Label
		_check(caption != null and caption.text == spec[1], "%s tab: the caption is '%s' (got '%s')" % [tab, spec[1], caption.text if caption != null else null])
		var tile_shows := _shows(window, "GDR_MAINPOPUP_BG_TILE")
		if spec[2] == null:
			_check(not tile_shows, "%s tab: the background tile is hidden" % tab)
		else:
			_check(tile_shows and _rect_of(window, "GDR_MAINPOPUP_BG_TILE") == spec[2],
				"%s tab: the background tile at %s (got %s, shown %s)" % [tab, spec[2], _rect_of(window, "GDR_MAINPOPUP_BG_TILE"), tile_shows])
		var want_x: float = (view_w - POPUP_SIZE.x - 80.0) if spec[3] else 80.0
		_check(window.position == Vector2(want_x, 262),
			"%s tab: the window at (%s, 262) (got %s)" % [tab, want_x, window.position])
		_check(panels.call("is_open", tab), "%s tab: is_open(%s)" % [tab, tab])

	# The keys' toggle.
	panels.call("open", "inventory")
	_check(panels.call("is_open", "equipment") and not panels.call("is_open", "character"),
		"on the inventory tab, is_open(equipment) and not is_open(character)")
	panels.call("toggle", "character")
	_check(window.visible and panels.call("is_open", "character"),
		"C with the inventory tab up switches to the character tab, the window stays")
	panels.call("toggle", "character")
	_check(not window.visible, "C on the character tab hides the window")
	panels.call("toggle", "skill")
	_check(window.visible and panels.call("is_open", "skill"), "the skill key brings the window back on the skill tab")
	panels.call("toggle", "skill")
	_check(not window.visible, "the skill key on the skill tab hides it")

	# The equipment pane's avatar mode resets when another tab hides it.
	panels.call("open", "inventory")
	panels.call("set_equipment_avatar_mode", true)
	panels.call("open", "character")
	panels.call("open", "inventory")
	_check(panels.call("is_equipment_avatar_mode") == false and _shows(window, "GDR_EQUIPMENT_SLOT_100"),
		"switching tabs away from the equipment pane returns it to equipment mode")

	# Drag targets: the bag only counts while its tab shows.
	var inside := window.global_position + Vector2(100, 150)
	panels.call("open", "inventory")
	_check(panels.call("_over_inventory_window", inside), "a point on the window counts as the bag on the inventory tab")
	panels.call("open", "character")
	_check(not panels.call("_over_inventory_window", inside), "the same point does not count as the bag on the character tab")

	# Our deviation: the window stays inside the viewport at the project's
	# default 1152x648 and at 1366x768 with UI scale 1.5, on open, on every tab
	# switch, and after a resize (round 591).
	for view in [[Vector2i(1152, 648), 1.0], [Vector2i(1366, 768), 1.5]]:
		root.size = view[0]
		root.content_scale_factor = view[1]
		await process_frame
		for tab in TABS:
			panels.call("open", tab)
			var vr := window.get_viewport_rect()
			var r := Rect2(window.position, window.size)
			_check(vr.encloses(r), "%s at %s, UI scale %s: the window %s stays inside the viewport %s" % [tab, view[0], view[1], r, vr.size])
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	await process_frame
	panels.call("open", "inventory")
	root.size = Vector2i(1152, 648)
	await process_frame
	await process_frame
	var after := Rect2(window.position, window.size)
	_check(window.get_viewport_rect().encloses(after),
		"opened at 1920x1080 and resized to 1152x648, the window %s is pulled inside the viewport %s" % [after, window.get_viewport_rect().size])
	root.size = Vector2i(1920, 1080)
	await process_frame
	# The clamp is only drawn (round 592): back at 1920x1080 the window is
	# where the selector wants it again, y 262, not stuck at the clamped y.
	root.size = Vector2i(1366, 768)
	root.content_scale_factor = 1.5
	await process_frame
	await process_frame
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	await process_frame
	await process_frame
	_check(window.position.y == 262.0, "clamped at 1366x768 x1.5 and resized back, the window is at y 262 again (got %s)" % window.position)
	panels.call("open", "skill")
	_check(window.position == Vector2(window.get_viewport_rect().size.x - 468.0, 262.0),
		"and a tab opened then is at the selector's (W - 468, 262) (got %s)" % window.position)
	# A real drag is kept: drag by the caption strip, shrink, grow back.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(100, 10)
	window.call("_gui_input", press)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(100, 10) + Vector2(-1000, -150)
	window.call("_gui_input", motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	window.call("_gui_input", release)
	var dragged_to := window.position
	root.size = Vector2i(1366, 768)
	root.content_scale_factor = 1.5
	await process_frame
	await process_frame
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	await process_frame
	await process_frame
	_check(dragged_to == Vector2(window.get_viewport_rect().size.x - 468.0 - 1000.0, 112.0) and window.position == dragged_to,
		"a drag to %s is kept through a clamp and back (got %s)" % [dragged_to, window.position])

	# The bag beside the warehouse (open_storage, likewise open_shop): placed
	# through the popup's wanted position, so a window resize keeps the
	# pairing instead of snapping the bag back to its tab's side (round 593).
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	await process_frame
	panels.call("open_storage", "Keeper")
	var paired := window.position
	_check(paired == Vector2(968, 336), "the bag opens beside the warehouse at (968, 336) (got %s)" % paired)
	root.size = Vector2i(1900, 1070)
	await process_frame
	await process_frame
	_check(window.position == paired, "a resize to 1900x1070 keeps the bag at %s (got %s)" % [paired, window.position])
	root.size = Vector2i(1920, 1080)
	await process_frame
	await process_frame
	_check(window.position == paired, "and back to 1920x1080 it is still at %s (got %s)" % [paired, window.position])

	# The character pane's rows, filled from the server's stats.
	var stats := StatsNet.Stats.new()
	stats.level = 7
	stats.hp = 50
	stats.max_hp = 100
	stats.str = 42
	stats.intel = 21
	stats.stat_points = 3
	stats.phys_attack_min = 3
	stats.phys_attack = 9
	stats.has_character_rows = true
	panels.call("_apply_stats", stats)
	var got := {}
	for n in ["GDR_PI_TEXT_STRENGTH_DAT", "GDR_PI_TEXT_INTELLECT_DAT", "GDR_PI_TEXT_HP_DAT",
			"GDR_PI_TEXT_STAT2", "GDR_PI_TEXT_PHYATT_DAT"]:
		var label := window.call("node", n) as Label
		got[n] = label.text if label != null else null
	_check(got == {"GDR_PI_TEXT_STRENGTH_DAT": "42", "GDR_PI_TEXT_INTELLECT_DAT": "21",
		"GDR_PI_TEXT_HP_DAT": "50 / 100", "GDR_PI_TEXT_STAT2": "3", "GDR_PI_TEXT_PHYATT_DAT": "3 ~ 9"},
		"the character pane's rows carry the server's stats (got %s)" % [got])
	panels.free()
