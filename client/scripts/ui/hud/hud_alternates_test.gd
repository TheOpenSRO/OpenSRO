extends SceneTree

## Same-rect alternates (round 585): where a layout authors several controls
## at one rect and the client's own class shows one of them, the built window
## shows exactly that one. Each fixture below is a synthetic layout carrying
## the authored names, IDs and rects of the real controls (read from the
## archive's resinfo files and recorded in docs/RE_COMPLETION.md) -- never
## real game data:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_alternates_test.gd
##
## - academy: GDR_APPRENTICESHIP_PICTURE hidden at create, LEADER_STATUS kept
##   (CIFApprenticeShip 0x6e9848).
## - alchemy: Process shown, Cancel hidden (CIFAlchemyProcess 0x725740).
## - the equipment pane beside the bag: the worn slots and the change-to-avatar
##   button shown; the avatar slots, change-to-equipment button and avatar
##   skill strip hidden; either button flips the two sets; hiding the window
##   goes back to equipment (CIFEquipment 0x6abde0 / 0x6abf60).
##
## The academy, the bag and the equipment are panes of the main popup (the
## main popup round), so the fixture carries its registry entry and
## ifmainpopup.txt's panes, and each group is looked for inside its pane.
## - chat: the "all" list shown, the other four hidden; the input line at
##   its UI_UPDATE_2009_FIRST rect, clear of the mode button (CIFChatViewer
##   0x7ab920).
##
## New methods are reached through has_method / call, so a tree without them
## FAILS here rather than failing to parse.

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const CHAT_PATH := "res://scripts/ui/hud/hud_chat.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, id: int, rect: String, extra: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n%s\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, id, extra, rect]

func _layout(body: String, extra_sections: String = "") -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n" + extra_sections

## ifapprenticeship.txt's two controls at 9,33,28,28 and a frame.
func _academy() -> String:
	# The two extra sections the academy composes (HudPanels.EXTRA_SECTIONS),
	# empty: a section the layout lacks builds the first one again.
	return _layout(_control("GDR_APPRENTICESHIP_LEADER_STATUS", "CIFStatic", 46, "9,33,28,28")
		+ _control("GDR_APPRENTICESHIP_PICTURE", "CIFStaticWithPictureClip", 41, "9,33,28,28")
		+ _control("GDR_APPRENTICESHIP_FRAMEL", "CIFFrame", 1, "0,0,364,339"),
		"Section = NotifySubBox,\"0,0,0,0\",\"0\"\n{\n}\nSection = NotifyContents,\"0,0,0,0\",\"0\"\n{\n}\n")

## ifalchemyprocess.txt's buttons (the archive's are 0x0, sized by their art;
## the fixture gives the art's 104x28 directly).
func _alchemy() -> String:
	return _layout(_control("GDR_AB_MANUFACTURING_BUTTON_ALL_PROCESS", "CIFButton", 31, "20,179,104,28")
		+ _control("GDR_AB_MANUFACTURING_BUTTON_PROCESS", "CIFButton", 30, "253,179,104,28")
		+ _control("GDR_AB_MANUFACTURING_BUTTON_CANCEL", "CIFButton", 35, "253,179,104,28")
		+ _control("GDR_AB_FRAME", "CIFFrame", 1, "0,0,340,203"))

func _inventory() -> String:
	return _layout(_control("GDR_INVENTORY_FRAME", "CIFFrame", 1, "0,0,176,308"))

## ifequipment.txt's slots, buttons and skill strip at their authored rects.
const WORN_RECTS := {
	100: "5,86,32,32", 101: "5,129,32,32", 102: "141,86,32,32", 103: "141,129,32,32",
	104: "5,172,32,32", 105: "141,172,32,32", 106: "12,12,32,32", 107: "134,12,32,32",
	108: "141,308,32,32", 109: "5,215,32,32", 110: "141,215,32,32", 111: "5,258,32,32",
	112: "141,258,32,32",
}
const AVATAR_RECTS := {
	"GDR_AVATAR_SLOT_01": [113, "5,86,32,32"], "GDR_AVATAR_SLOT_02": [114, "5,129,32,32"],
	"GDR_AVATAR_SLOT_03": [115, "141,129,32,32"], "GDR_AVATAR_SLOT_04": [116, "141,86,32,32"],
	"GDR_AVATAR_SLOT_05": [117, "5,172,32,32"],
}

func _equipment() -> String:
	var body := _control("GDR_AVATAR_SKILL_WND", "CIFEquipSkillSlotWnd", 500, "0,240,177,50")
	for n in AVATAR_RECTS:
		body += _control(n, "CIFSlotWithHelp", AVATAR_RECTS[n][0], AVATAR_RECTS[n][1])
	for id in WORN_RECTS:
		body += _control("GDR_EQUIPMENT_SLOT_%d" % id, "CIFSlotWithHelp", id, WORN_RECTS[id])
	body += _control("GDR_EQ_BTN_CHANGE_EQUIP_SLOT", "CIFButton", 14, "1,305,40,40")
	body += _control("GDR_EQ_BTN_CHANGE_AVATAR_SLOT", "CIFButton", 13, "1,305,40,40")
	body += _control("GDR_EQ_FRAME", "CIFFrame", 4, "0,0,178,355")
	return _layout(body)

## ifchatviewer.txt's five lists, the mode button and the input line with its
## two rects behind #ifdef UI_UPDATE_2009_FIRST, exactly as the archive
## spells the property-level branch.
func _chat() -> String:
	var input := "\tGDR_CHAT_INPUTBOX:CIFEInputChatBox\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tID=INTEGER,\"11\"\n#ifdef UI_UPDATE_2009_FIRST\n\t\tRect=RECT,\"38,378,360,20\"\n#else\n\t\tRect=RECT,\"18,378,381,20\"\n#endif\n\t\tText=STRING,\"\"\n\t}\n"
	return _layout("#ifdef UI_UPDATE_2009_FIRST\n" + _control("GDR_LIST_APPRENTICE", "CIFTextBox", 30, "27,28,365,343") + "#endif\n"
		+ _control("GDR_LIST_CHATALLIACNE", "CIFTextBox", 19, "27,28,365,343")
		+ _control("GDR_LIST_CHATGUILD", "CIFTextBox", 18, "27,28,365,343")
		+ _control("GDR_LIST_CHATPARTY", "CIFTextBox", 17, "27,28,365,343")
		+ _control("GDR_LIST_CHATTING", "CIFTextBox", 16, "27,28,365,343")
		+ "#ifdef UI_UPDATE_2009_FIRST\n" + _control("GDR_CHAT_MODE_BTN", "CIFButton", 41, "18,378,20,20") + "#endif\n"
		+ input)

## ifmainpopup.txt's panes at their authored rects (APPLY_MENTOR_SYSTEM taken),
## and ginterface.txt's GDR_MAINPOPUP.
func _mainpopup() -> String:
	return _layout(_control("GDR_APPRENTICESHIP", "CIFApprenticeShip", 77, "13,38,365,355")
		+ _control("GDR_QUEST", "CIFQuest", 76, "13,38,365,355")
		+ _control("GDR_PLAYERINFO", "CIFPlayerInfo", 75, "13,38,364,356")
		+ _control("GDR_ACTION", "CIFAction", 74, "13,38,364,357")
		+ _control("GDR_SKILL", "CIFSkill", 73, "13,63,364,333")
		+ _control("GDR_PARTY", "CIFParty", 72, "13,38,364,337")
		+ _control("GDR_EQUIPMENT", "CIFEquipment", 71, "198,41,178,355")
		+ _control("GDR_INVENTORY", "CIFInventory", 70, "13,63,176,333"))

func _registry() -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n\tGDR_MAINPOPUP:CIFMainPopup\n\t{\n\t\tDDJ=STRING,\"interface\\\\frame\\\\mframe_wnd_\"\n\t\tID=INTEGER,\"25\"\n\t\tRect=RECT,\"595,262,388,408\"\n\t\tText=STRING,\"\"\n\t}\n}\n"

## The same-rect groups inside the named panes of `window`, together.
func _pane_groups(window: Node, panes: Array) -> Array:
	var out := []
	for pane in panes:
		var node := window.call("node", pane) as Node
		if node != null:
			out.append_array(_same_rect_groups(node))
	return out

## UiBuilder.load_layout's cache key for a layout read with these defines
## (the path, \x01, the defines joined by \x02).
func _ifdef_key(path: String, defines: Array) -> String:
	return "%s%s%s" % [path, char(1), char(2).join(PackedStringArray(defines))]

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifapprenticeship.txt"] = UiLayoutParser.parse(_academy())
	cache["resinfo\\ifalchemyprocess.txt"] = UiLayoutParser.parse(_alchemy())
	cache["resinfo\\ifinventory.txt"] = UiLayoutParser.parse(_inventory())
	cache["resinfo\\ifequipment.txt"] = UiLayoutParser.parse(_equipment())
	# The builder has no archive to parse from, so the chat layout is cached
	# both ways it can be asked for: plain (both #ifdef branches read, the
	# #else rect last) and with UI_UPDATE_2009_FIRST selected. Which one the
	# chat asked for shows in the input line's rect.
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(_chat())
	cache[_ifdef_key("resinfo\\ifchatviewer.txt", ["UI_UPDATE_2009_FIRST"])] = UiLayoutParser.parse(_chat(), true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	cache[_ifdef_key("resinfo\\ifmainpopup.txt", ["APPLY_MENTOR_SYSTEM"])] = UiLayoutParser.parse(_mainpopup(), true, PackedStringArray(["APPLY_MENTOR_SYSTEM"]))
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	return builder

## Every group of GDR_ controls under `root` authored at one on-screen rect,
## as [[name, visible], ...] per group of two or more.
func _same_rect_groups(root: Node) -> Array:
	var by_rect := {}
	for n in root.find_children("GDR_*", "Control", true, false):
		var c := n as Control
		if not c.has_meta(UiBuilder.AUTHORED_RECT_META):
			continue
		var ar: Rect2 = c.get_meta(UiBuilder.AUTHORED_RECT_META)
		var parent_at := (c.get_parent() as Control).global_position if c.get_parent() is Control else Vector2.ZERO
		var key := str(Rect2(parent_at + ar.position, ar.size))
		if not by_rect.has(key):
			by_rect[key] = []
		by_rect[key].append([String(c.name), c.is_visible_in_tree()])
	var groups := []
	for k in by_rect:
		if (by_rect[k] as Array).size() > 1:
			groups.append(by_rect[k])
	return groups

func _shown(groups: Array) -> Array:
	var out := []
	for g in groups:
		var names := []
		for m in g:
			if m[1]:
				names.append(m[0])
		out.append(names)
	return out

func _visible(window: Node, control_name: String) -> bool:
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
		await _panel_checks(panels_script)
	_chat_checks()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _panel_checks(panels_script: GDScript) -> void:
	var panels: Node = panels_script.new(_builder())
	root.add_child(panels)

	var academy: Node = panels.call("open", "academy")
	_check(academy != null, "the academy window builds from the fixture")
	if academy != null:
		var shown := _shown(_pane_groups(academy, ["GDR_APPRENTICESHIP"]))
		_check(shown == [["GDR_APPRENTICESHIP_LEADER_STATUS"]],
			"academy: one of PICTURE / LEADER_STATUS shown, LEADER_STATUS (got %s)" % [shown])

	var alchemy: Node = panels.call("open", "alchemy")
	_check(alchemy != null, "the alchemy window builds from the fixture")
	if alchemy != null:
		var shown := _shown(_same_rect_groups(alchemy))
		_check(shown == [["GDR_AB_MANUFACTURING_BUTTON_PROCESS"]],
			"alchemy: one of PROCESS / CANCEL shown, PROCESS (got %s)" % [shown])
		_check(_visible(alchemy, "GDR_AB_MANUFACTURING_BUTTON_ALL_PROCESS"), "alchemy: All-compound stays shown")

	var inv: Node = panels.call("open", "inventory")
	_check(inv != null, "the main popup builds on its inventory tab, the bag and the equipment")
	if inv == null:
		panels.free()
		return
	var groups := _pane_groups(inv, ["GDR_INVENTORY", "GDR_EQUIPMENT"])
	_check(groups.size() == 6, "inventory: six same-rect groups -- five slot pairs and the change buttons (got %d)" % groups.size())
	var one_each := true
	for names in _shown(groups):
		if (names as Array).size() != 1:
			one_each = false
	_check(one_each, "inventory: exactly one control of each same-rect group shown (got %s)" % [_shown(groups)])
	var worn_all := true
	for id in WORN_RECTS:
		worn_all = worn_all and _visible(inv, "GDR_EQUIPMENT_SLOT_%d" % id)
	var avatar_none := true
	for n in AVATAR_RECTS:
		avatar_none = avatar_none and not _visible(inv, n)
	_check(worn_all and avatar_none, "equipment mode on open: all 13 worn slots shown, the 5 avatar slots hidden")
	_check(_visible(inv, "GDR_EQ_BTN_CHANGE_AVATAR_SLOT") and not _visible(inv, "GDR_EQ_BTN_CHANGE_EQUIP_SLOT"),
		"equipment mode on open: change-to-avatar shown, change-to-equipment hidden")
	_check(not _visible(inv, "GDR_AVATAR_SKILL_WND"), "the avatar skill strip is hidden")

	# The toggle: button 13 -> avatar mode.
	var to_avatar := inv.call("node", "GDR_EQ_BTN_CHANGE_AVATAR_SLOT") as BaseButton
	if to_avatar != null:
		to_avatar.pressed.emit()
	var worn_hidden := true
	for id in WORN_RECTS:
		if id != 108:
			worn_hidden = worn_hidden and not _visible(inv, "GDR_EQUIPMENT_SLOT_%d" % id)
	var avatar_all := true
	for n in AVATAR_RECTS:
		avatar_all = avatar_all and _visible(inv, n)
	_check(worn_hidden and avatar_all and _visible(inv, "GDR_EQUIPMENT_SLOT_108"),
		"change-to-avatar: the avatar slots shown, the worn slots hidden but SLOT_108")
	_check(_visible(inv, "GDR_EQ_BTN_CHANGE_EQUIP_SLOT") and not _visible(inv, "GDR_EQ_BTN_CHANGE_AVATAR_SLOT"),
		"change-to-avatar: the buttons swap")
	var one_each_avatar := true
	for names in _shown(_pane_groups(inv, ["GDR_INVENTORY", "GDR_EQUIPMENT"])):
		if (names as Array).size() != 1:
			one_each_avatar = false
	_check(one_each_avatar, "avatar mode: still exactly one of each same-rect group shown")
	var to_equip := inv.call("node", "GDR_EQ_BTN_CHANGE_EQUIP_SLOT") as BaseButton
	if to_equip != null:
		to_equip.pressed.emit()
	_check(_visible(inv, "GDR_EQUIPMENT_SLOT_100") and not _visible(inv, "GDR_AVATAR_SLOT_01")
		and _visible(inv, "GDR_EQ_BTN_CHANGE_AVATAR_SLOT"),
		"change-to-equipment: back to the worn slots")
	# Closing resets: open in avatar mode, hide, reopen.
	if to_avatar != null:
		to_avatar.pressed.emit()
	(inv as CanvasItem).hide()
	panels.call("open", "inventory")
	_check(_visible(inv, "GDR_EQUIPMENT_SLOT_100") and not _visible(inv, "GDR_AVATAR_SLOT_01"),
		"a window hidden in avatar mode reopens in equipment mode")
	panels.free()

func _chat_checks() -> void:
	var chat_script := load(CHAT_PATH) as GDScript
	_check(chat_script != null and chat_script.can_instantiate(), "HudChat compiles")
	if chat_script == null or not chat_script.can_instantiate():
		return
	var chat: Control = chat_script.new(_builder())
	chat.call("setup")
	root.add_child(chat)
	var shown := _shown(_same_rect_groups(chat))
	_check(shown == [["GDR_LIST_CHATTING"]],
		"chat: one of the five channel lists shown, the 'all' list (got %s)" % [shown])
	var input := chat.find_child("GDR_CHAT_INPUTBOX", true, false) as Control
	var mode := chat.find_child("GDR_CHAT_MODE_BTN", true, false) as Control
	var input_rect: Rect2 = input.get_meta(UiBuilder.AUTHORED_RECT_META) if input != null else Rect2()
	_check(input_rect == Rect2(38, 378, 360, 20),
		"chat: the input line is at its UI_UPDATE_2009_FIRST rect 38,378,360,20 (got %s)" % input_rect)
	var mode_rect: Rect2 = mode.get_meta(UiBuilder.AUTHORED_RECT_META) if mode != null else Rect2()
	_check(mode != null and not input_rect.intersects(mode_rect),
		"chat: the input line does not cover the mode button (%s vs %s)" % [input_rect, mode_rect])
	chat.free()
