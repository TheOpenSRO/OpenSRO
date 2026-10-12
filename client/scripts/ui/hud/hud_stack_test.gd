extends SceneTree

## The game windows draw and take clicks above the chat window where the two
## overlap (HudPanels.stack_over, called by World3D). Builds the HUD the way
## World3D does -- an IGNORE full-screen control, HudPanels, then HudChat on
## the underbar at (2, 182) -- and pushes real mouse events through the
## viewport (Viewport.push_input), so Godot's own hit-testing decides who
## gets them. Synthetic layouts only (docs/LEGAL.md):
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_stack_test.gd

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const CHAT_PATH := "res://scripts/ui/hud/hud_chat.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const WORLD_PATH := "res://scripts/World3D.gd"
const RECORD := 0x3d0

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

# --- fixtures -----------------------------------------------------------------

func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	for pair in [[0x000, "name"], [0x040, "base"], [0x140, "tex"], [0x240, "textid"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, 0xffffffff)
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x390, 0xffffffff)
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	return b

## questlist.2dt's window and two rows (the ids and rects of the real file).
func _questlist() -> PackedByteArray:
	var recs := [{"type": 0, "id": 76, "name": "CNIFQuest", "root": true, "rect": Rect2i(198, 193, 624, 369)}]
	var y := 236
	for id in [5, 77]:
		recs.append({"type": 8, "id": id, "name": "CNIFQuestSlot", "parent": 76, "rect": Rect2i(214, y, 576, 32)})
		recs.append({"type": 5, "id": 16, "parent": id, "gp": 76, "rect": Rect2i(248, y + 8, 383, 16)})
		y += 31
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, recs.size())
	for r in recs:
		out.append_array(_rec(r))
	return out

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n%s}\n" % body

func _control(n: String, type: String, rect: String) -> String:
	return "\t%s:%s\n\t{\n\t\tID=INTEGER,\"1\"\n\t\tRect=RECT,\"%s\"\n\t}\n" % [n, type, rect]

## ifchatviewer.txt's message box and input line, at their authored rects.
func _chat() -> String:
	return _layout(_control("GDR_LIST_CHATTING", "CIFTextBox", "27,28,365,343")
		+ _control("GDR_CHAT_INPUTBOX", "CIFStatic", "38,378,360,20"))

func _ifdef_key(path: String, defines: Array) -> String:
	return "%s%s%s" % [path, char(1), char(2).join(PackedStringArray(defines))]

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(_chat())
	cache[_ifdef_key("resinfo\\ifchatviewer.txt", ["UI_UPDATE_2009_FIRST"])] = UiLayoutParser.parse(_chat(), true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	var Reader = load(READER_PATH)
	var twodt = builder.get("_twodt_cache")
	if Reader != null and twodt is Dictionary:
		twodt["res_ui\\questlist.2dt"] = Reader.parse(_questlist())
	return builder

func _mouse(at: Vector2, button: MouseButton, pressed: bool) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_root().push_input(motion)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	get_root().push_input(ev)

func _click(at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_mouse(at, button, true)
	_mouse(at, button, false)

# --- the checks ---------------------------------------------------------------

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var builder := _builder()
	# World3D's order: the UI control (IGNORE, full screen), HudPanels, then
	# the chat, on the 68-pixel underbar at x 2.
	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_root().add_child(ui)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	ui.add_child(panels)
	var chat: Control = (load(CHAT_PATH) as GDScript).new(builder)
	ui.add_child(chat)
	chat.call("setup")
	# The tallest size mode (6, the layout's own geometry; round 634), so
	# the chat reaches under the window this test stacks over it.
	if chat.has_method("set_mode"):
		chat.call("set_mode", 6)
	chat.position = Vector2(2, 648 - 68 - chat.size.y)
	var stacks := panels.has_method("stack_over")
	_check(stacks, "HudPanels can put the chat below its windows (stack_over)")
	if stacks:
		panels.call("stack_over", chat)
	var world_src := FileAccess.get_file_as_string(WORLD_PATH)
	_check(world_src.contains("_hud_panels.stack_over(_hud_chat)"), "World3D stacks the windows over the chat after adding it")
	await process_frame
	_check(chat.get_rect() == Rect2(2, 181, 399, 399), "the chat in mode 6 is 399x399 at (2, 181) (got %s)" % chat.get_rect())
	_check(chat.get_index() == panels.get_index() - 1,
		"the chat sits directly below the windows (chat %d, panels %d): above nothing it was not above" % [chat.get_index(), panels.get_index()])

	# The quest window at (80, 140) with twelve quests.
	var ev := InputEventKey.new()
	ev.keycode = KEY_Q
	ev.pressed = true
	panels.call("_unhandled_key_input", ev)
	await process_frame
	var window := panels.get_node_or_null("Window_quest") as Control
	_check(window != null and window.visible and window.position == Vector2(80, 140), "Q opens the quest window at (80, 140)")
	if window == null:
		return
	var quests := []
	for i in 12:
		quests.append([i + 1, QuestNet.View.new()])
	window.call("fill_log", quests)
	var got := {"window": 0, "chat": 0}
	window.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			got["window"] += 1)
	chat.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			got["chat"] += 1)

	# Where the two overlap (x 80..401, y 182..509): the window.
	var overlap := Vector2(200, 300)
	_check(Rect2(80, 140, 624, 369).has_point(overlap) and chat.get_rect().has_point(overlap), "(200, 300) is over both")
	_click(overlap)
	await process_frame
	_check(got["window"] == 1 and got["chat"] == 0,
		"a click where they overlap reaches the quest window, not the chat (window %d, chat %d)" % [got["window"], got["chat"]])
	# A wheel notch arrives as a press and a release, as the OS sends it.
	_click(overlap, MOUSE_BUTTON_WHEEL_DOWN)
	await process_frame
	_check(int(window.call("scroll_position")) == 1,
		"the wheel where they overlap scrolls the quest list (position %s)" % window.call("scroll_position"))
	_check(window.get_global_rect().has_point(overlap) and window.get_index() >= 0 and panels.get_index() > chat.get_index(),
		"the windows draw after the chat")

	# The chat still works where no window is.
	var outside := Vector2(30, 300)
	_check(not window.get_global_rect().has_point(outside), "(30, 300) is over the chat only")
	var before: int = got["chat"]
	_click(outside)
	await process_frame
	_check(got["chat"] == before + 1, "a click on the chat alone still reaches the chat (%d -> %d)" % [before, got["chat"]])
	var line := chat.get("_input") as LineEdit
	_check(line != null, "the chat has its input line")
	if line != null:
		var at := line.get_global_rect().get_center()
		_check(not window.get_global_rect().has_point(at), "the input line (%s) is clear of the window" % line.get_global_rect())
		_click(at)
		await process_frame
		_check(line.has_focus(), "clicking the chat's input line focuses it")
	ui.free()
