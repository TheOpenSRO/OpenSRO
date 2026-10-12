extends SceneTree

## Round 781: the action pane (HudActionPane) filled the way CIFAction::Create
## fills it, on a synthetic ifaction.txt carrying the authored names, ids and
## rects of a few of its slots (MEASURED from the archive) and synthetic
## actionwnddata rows (no textures, no archive text).
##
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_action_pane_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _c(control_name: String, rect: String, id: int) -> String:
	return "\t%s:CIFSlotWithHelp\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [
		control_name, id, rect]

func _ifaction() -> String:
	var b := ""
	b += _c("GDR_ACT_ACT_SLOT_401", "58,276,32,32", 401)
	b += _c("GDR_ACT_ACT_SLOT_400", "22,276,32,32", 400)
	b += _c("GDR_ACT_ORD_SLOT_116", "274,72,32,32", 116)
	b += _c("GDR_ACT_ORD_SLOT_107", "274,36,32,32", 107)
	b += _c("GDR_ACT_ORD_SLOT_101", "58,36,32,32", 101)
	b += _c("GDR_ACT_ORD_SLOT_SITDOWN", "22,36,32,32", 100)
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n%s}\n" % b

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for k in ["UIIT_CTL_TOG_SIT_STAND_TT", "UIIT_CTL_TOG_RUN_WALK_TT", "UIIT_CTL_EMOT_GREETING_TT",
			"UIIT_CTL_EMOT_LAUGH_TT", "UIIT_CTL_SIT", "UIIT_CTL_STAND", "UIIT_CTL_RUN", "UIIT_CTL_WALK",
			"UIIT_CTL_AUTOGET_TT"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	rows.append("1\tUIIT_STT_TOGGLE_CONTENTS_MENU_SITDOWN\t\t\t\t\t\t\tSit ( %s )")
	rows.append("1\tUIIT_STT_TOGGLE_CONTENTS_MENU_PICKUP\t\t\t\t\t\t\tGrab ( %s )")
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _entries() -> Array:
	var text := "\n".join(PackedStringArray([
		"1000\t1\tx\tUIIT_CTL_TOG_SIT_STAND_TT\ticon\\action\\icon_cha_sit.ddj\t1\t0",
		"1001\t1\tx\tUIIT_CTL_TOG_RUN_WALK_TT\ticon\\action\\icon_cha_walk.ddj\t1\t1",
		"1008\t1\tx\tUIIT_CTL_AUTOGET_TT\ticon\\action\\icon_cha_autoget.ddj\t1\t7",
		"4000\t1\tx\tUIIT_CTL_EMOT_GREETING_TT\ticon\\action\\emot_act_greeting.ddj\t4\t0",
	]))
	return ActionWndData.parse_text(text)

func _initialize() -> void:
	var builder := UiBuilder.new(null, _text_table())
	var cache: Dictionary = builder.get("_layout_cache")
	cache[HudActionPane.LAYOUT] = UiLayoutParser.parse(_ifaction())
	var pane := Control.new()
	pane.name = "GDR_ACTION"
	pane.size = Vector2(364, 357)
	root.add_child(pane)
	pane.add_child(builder.build_section(builder.load_layout(HudActionPane.LAYOUT), "Create"))
	var p := HudActionPane.new(builder, pane, _entries())

	_check(p.slots.size() == 4, "four rows fill four slots (got %d)" % p.slots.size())
	_check(p.slot_by_control_id(100) == p.slots.get(1000) and p.slot_by_control_id(100).name == "GDR_ACT_ORD_SLOT_SITDOWN",
		"1000 (section 1 slot 0) is control 100, GDR_ACT_ORD_SLOT_SITDOWN")
	_check(p.slots.get(1008) == p.slot_by_control_id(107), "1008 (slot 7) is control 107")
	_check(p.slots.get(4000) == p.slot_by_control_id(400), "4000 (section 4 slot 0) is control 400")
	_check(not p.slot_by_control_id(116).visible and not p.slot_by_control_id(401).visible,
		"a slot no row fills is hidden (Create's 0xb9daf0(0))")
	_check(p.slot_by_control_id(100).visible and p.slot_by_control_id(400).visible, "a filled slot is shown")
	_check(String(p.icon_paths.get(1001, "")) == "icon\\action\\icon_cha_walk.ddj", "1001 starts on its row's icon (walk)")
	_check(p.slots[4000].tooltip_text == "<UIIT_CTL_EMOT_GREETING_TT>", "a tooltip is its row's text key")
	var sit_key := OS.get_keycode_string(KeyMap.key_for("sit"))
	_check(p.slots[1000].tooltip_text == "Sit ( %s )" % sit_key,
		"1000's tooltip is rewritten with its key (FUN_006a4320): %s" % p.slots[1000].tooltip_text)
	_check(p.slots[1008].tooltip_text == "Grab ( %s )" % OS.get_keycode_string(KeyMap.key_for("pickup")),
		"... and 1008's with G")

	# The motion swaps (FUN_006a3fb0).
	_check(p.set_motion(4) == 1000 and String(p.icon_paths[1000]) == "icon\\action\\icon_cha_stand.ddj"
		and p.slots[1000].tooltip_text == "<UIIT_CTL_STAND>", "seated: 1000 shows stand + UIIT_CTL_STAND")
	_check(p.set_motion(0) == 1000 and String(p.icon_paths[1000]) == "icon\\action\\icon_cha_sit.ddj"
		and p.slots[1000].tooltip_text == "<UIIT_CTL_SIT>", "standing: sit + UIIT_CTL_SIT")
	_check(p.set_motion(2) == 1001 and String(p.icon_paths[1001]) == "icon\\action\\icon_cha_run.ddj"
		and p.slots[1001].tooltip_text == "<UIIT_CTL_RUN>", "walking: 1001 offers the run")
	_check(p.set_motion(3) == 1001 and String(p.icon_paths[1001]) == "icon\\action\\icon_cha_walk.ddj"
		and p.slots[1001].tooltip_text == "<UIIT_CTL_WALK>", "running: 1001 offers the walk")
	_check(p.set_motion(0x12) == -1, "a value the window does not draw changes nothing")

	# Right click uses, left click picks up.
	var used: Array = []
	var picked: Array = []
	p.use_requested.connect(func(id: int) -> void: used.append(id))
	p.pick_requested.connect(func(what: Dictionary, _i: Texture2D, _s: Control, _a: Vector2) -> void: picked.append(what))
	var slot: Control = p.slots[4000]
	await process_frame
	var at := slot.get_global_rect().get_center()
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = false
	right.global_position = at
	right.position = at
	slot.gui_input.emit(right)
	_check(used == [4000], "a right release on a slot uses it (vslot 33 -> 0x682040 kind 0x4a)")
	var left := InputEventMouseButton.new()
	left.button_index = MOUSE_BUTTON_LEFT
	left.pressed = false
	left.global_position = at
	left.position = at
	slot.gui_input.emit(left)
	_check(picked.size() == 1 and String(picked[0].get("kind", "")) == "action" and int(picked[0].get("action_id", 0)) == 4000,
		"a left click picks the action up, kind \"action\"")

	pane.queue_free()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
