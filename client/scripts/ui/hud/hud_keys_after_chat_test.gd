extends SceneTree

## The panel keys work again after a line of chat once the player clicks the
## HUD (round 605; HudPanels.release_text_focus_on_press). The chat's line
## keeps the keyboard after Enter, and the rebuilt HUD's buttons are
## FOCUS_NONE, so on d4d1303 a click on the underbar's buttons, its menu or a
## window left the focus in the chat and every key went into it. Round 606:
## a window drawn over a focused line takes the keyboard too (3d08974 kept
## it), and Enter opens the chat line and, on an empty line, ends it, as the
## client's key handlers do (HudChat).
##
## Builds the HUD in World3D's order -- the underbar, HudPanels, the chat
## (stack_over) in an IGNORE full-screen control -- and drives it with
## Viewport.push_input only: every click and key goes through Godot's own
## hit-testing, focus and key routing, as a player's do. A node at the root
## records the keys that reach the unhandled stage, as World3D's own
## _unhandled_input would see them. Synthetic layouts only (docs/LEGAL.md):
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_keys_after_chat_test.gd

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const UnderbarFixture = preload("res://scripts/ui/hud/underbar_fixture.gd")
const RECORD := 0x3d0

var _failures := 0
var _keys_seen: Array = []
var _sent: Array = []

class KeySink extends Node:
	var seen: Array
	func _unhandled_key_input(event: InputEvent) -> void:
		var k := event as InputEventKey
		if k != null and k.pressed:
			seen.append(k.keycode)

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

# --- fixtures (the shapes of hud_stack_test.gd's) ----------------------------

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
	var builder := UnderbarFixture.builder()
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(_chat())
	cache[_ifdef_key("resinfo\\ifchatviewer.txt", ["UI_UPDATE_2009_FIRST"])] = UiLayoutParser.parse(_chat(), true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	var twodt = builder.get("_twodt_cache")
	var Reader = load(READER_PATH)
	if Reader != null and twodt is Dictionary:
		twodt["res_ui\\questlist.2dt"] = Reader.parse(_questlist())
	return builder

# --- input, all through the viewport ------------------------------------------

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

## A key as the OS delivers it: keycode, physical keycode, label and, for a
## printable key, its character.
func _key(code: Key, unicode: int = 0) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.key_label = code
		ev.unicode = unicode if pressed else 0
		ev.pressed = pressed
		get_root().push_input(ev)

func _type(text: String) -> void:
	for i in text.length():
		var ch := text[i]
		_key(OS.find_keycode_from_string(ch.to_upper()), ch.unicode_at(0))

func _centre(c: Control) -> Vector2:
	return c.get_global_rect().get_center() if c != null else Vector2(-1, -1)

func _focus_name() -> String:
	var f := get_root().gui_get_focus_owner()
	return "null" if f == null else String(f.name)

# --- the checks ---------------------------------------------------------------

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var sink := KeySink.new()
	sink.seen = _keys_seen
	get_root().add_child(sink)
	var builder := _builder()
	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_root().add_child(ui)
	# World3D's order: the bar, the windows, then the chat, stacked under
	# the windows.
	var bar := HudUnderbar.new(builder, null, null)
	ui.add_child(bar)
	bar.position = Vector2((1152 - bar.size.x) / 2.0, 648 - bar.size.y)
	var panels: Control = load(PANELS_PATH).new(builder)
	ui.add_child(panels)
	bar.menu_action.connect(func(a: String) -> void: panels.call("menu_action", a))
	var chat := HudChat.new(builder)
	ui.add_child(chat)
	chat.setup()
	chat.position = Vector2(2, 648 - bar.size.y - chat.size.y)
	panels.call("stack_over", chat)
	chat.message_submitted.connect(func(t: String) -> void: _sent.append(t))
	for i in 4:
		await process_frame

	var line := chat.find_child("Input", true, false) as LineEdit
	var scrollback := chat.find_child("GDR_LIST_CHATTING", true, false) as Control
	var inv_btn: Control = bar.control([HudUnderbar.ID_BTN_INVENTORY])
	var menu_btn: Control = bar.menu_button()
	_check(line != null and inv_btn != null and menu_btn != null and scrollback != null,
		"the probe: the chat line, its scrollback, the bar's inventory and menu buttons are built")
	if line == null or inv_btn == null or menu_btn == null or scrollback == null:
		return

	# (a) A line of chat: click the line, type, Enter. The line keeps the
	# keyboard after Enter (LineEdit's own behaviour, kept), and a panel key
	# typed now goes into it.
	_click(_centre(line))
	await process_frame
	_check(get_root().gui_get_focus_owner() == line, "the probe: a click on the chat line gives it the keyboard (focus %s)" % _focus_name())
	_type("hi")
	_key(KEY_ENTER)
	await process_frame
	_check(_sent == ["hi"], "Enter sends the line (sent %s)" % [_sent])
	_check(get_root().gui_get_focus_owner() == line, "the line keeps the keyboard after Enter (focus %s)" % _focus_name())
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(not panels.call("is_open", "quest"), "Q while the line has the keyboard is typed, not a shortcut")
	line.clear()

	# (b) A press on the chat's own scrollback keeps the line (round 522's
	# review: a click on the scrollback must not end a message being typed).
	_click(_centre(scrollback))
	await process_frame
	_check(get_root().gui_get_focus_owner() == line, "a click on the chat's scrollback keeps the line (focus %s)" % _focus_name())
	# ... and so does a right press anywhere (a right drag orbits the camera).
	_click(Vector2(700, 100), MOUSE_BUTTON_RIGHT)
	await process_frame
	_check(get_root().gui_get_focus_owner() == line, "a right press keeps the line (focus %s)" % _focus_name())

	# (c) NEGATIVE (fails on d4d1303): a click on the bar's inventory button
	# takes the keyboard from the chat, and the keys are shortcuts again.
	_click(_centre(inv_btn))
	await process_frame
	_check(get_root().gui_get_focus_owner() == null,
		"a click on the bar's inventory button takes the keyboard from the chat (focus %s)" % _focus_name())
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(panels.call("is_open", "quest"), "after it Q opens the quest window")
	_keys_seen.clear()
	_key(KEY_J, "j".unicode_at(0))
	_check(_keys_seen.has(KEY_J), "after it an unbound key reaches the unhandled stage")
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(not panels.call("is_open", "quest"), "Q again closes the quest window")

	# (d) NEGATIVE: the bar's menu button, then the menu's quest item.
	_click(_centre(line))
	_type("yo")
	_key(KEY_ENTER)
	await process_frame
	_check(get_root().gui_get_focus_owner() == line, "the probe: the line has the keyboard again (focus %s)" % _focus_name())
	_click(_centre(menu_btn))
	await process_frame
	_check(bar.is_menu_open(), "the bar's menu button opens its menu")
	_check(get_root().gui_get_focus_owner() == null,
		"a click on the bar's menu button takes the keyboard from the chat (focus %s)" % _focus_name())
	# Escape still closes the menu first (round 598), and not the System window.
	_key(KEY_ESCAPE)
	await process_frame
	_check(not bar.is_menu_open() and not panels.call("is_open", "system"),
		"Escape closes the bar's menu and opens nothing")
	_click(_centre(line))
	await process_frame
	_click(_centre(menu_btn))
	await process_frame
	var quest_item: Control = bar.control([HudUnderbar.ID_MENU, 111])
	_click(_centre(quest_item))
	await process_frame
	_check(panels.call("is_open", "quest"), "the menu's quest item opens the quest window")
	_check(get_root().gui_get_focus_owner() == null, "after the menu the chat does not have the keyboard (focus %s)" % _focus_name())
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(not panels.call("is_open", "quest"), "then Q closes the quest window")

	# (e) NEGATIVE: a click on a window drawn over the chat is the window's
	# (stack_over), so it takes the keyboard even inside the chat's rect.
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	var quest: Control = panels.find_child("Window_quest", false, false) as Control
	_click(_centre(line))
	await process_frame
	var overlap := Rect2()
	if quest != null:
		overlap = quest.get_global_rect().intersection(chat.get_global_rect())
	var spot := overlap.get_center()
	_check(quest != null and overlap.has_area() and not line.get_global_rect().has_point(spot)
		and get_root().gui_get_focus_owner() == line,
		"the probe: the quest window overlaps the chat at %s, off the line, and the line has the keyboard" % spot)
	_click(spot)
	await process_frame
	_check(get_root().gui_get_focus_owner() == null,
		"a click on the quest window over the chat takes the keyboard from the chat (focus %s)" % _focus_name())
	_check(panels.call("is_open", "quest"), "the click on the window leaves it open")
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(not panels.call("is_open", "quest"), "then Q closes it")

	# (f) A press on another text line hands the keyboard straight to it.
	var other := LineEdit.new()
	other.position = Vector2(700, 60)
	other.size = Vector2(160, 30)
	ui.add_child(other)
	await process_frame
	_click(_centre(line))
	await process_frame
	_click(_centre(other))
	await process_frame
	_check(get_root().gui_get_focus_owner() == other, "a click on another text line gives it the keyboard (focus %s)" % _focus_name())
	# A click on the line itself keeps it (the caret moves, the focus stays).
	_click(_centre(other) + Vector2(20, 0))
	await process_frame
	_check(get_root().gui_get_focus_owner() == other, "a click on the focused line keeps it (focus %s)" % _focus_name())
	other.queue_free()
	await process_frame

	# (g) Round 606, NEGATIVE (fails on 3d08974): a window drawn over the
	# chat line takes the press on the covered part of the line, and the
	# keyboard with it.
	var line_spot := _centre(line)
	_click(line_spot)
	await process_frame
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(get_root().gui_get_focus_owner() == line and not panels.call("is_open", "quest"),
		"the probe: the chat line has the keyboard and the quest window is closed (focus %s)" % _focus_name())
	line.clear()
	panels.call("open", "quest")
	await process_frame
	quest = panels.find_child("Window_quest", false, false) as Control
	if quest != null:
		quest.position = line_spot - Vector2(40, 40)
	await process_frame
	_check(quest != null and quest.visible and quest.get_global_rect().has_point(line_spot)
		and get_root().gui_get_focus_owner() == line,
		"the probe: the quest window now covers the chat line at %s, and the line has the keyboard" % line_spot)
	_click(line_spot)
	await process_frame
	_check(get_root().gui_get_focus_owner() == null,
		"a click on a window over the chat line takes the keyboard from it (focus %s)" % _focus_name())
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(not panels.call("is_open", "quest"), "then Q closes the window")

	# (h) Round 606, NEGATIVE: a text line in one window, under another
	# window (a party-match field under the popup, as measured).
	panels.call("open", "quest")
	await process_frame
	var field := LineEdit.new()
	field.position = Vector2(40, 60)
	field.size = Vector2(200, 30)
	quest.add_child(field)
	await process_frame
	var field_spot := _centre(field)
	_click(field_spot)
	await process_frame
	_check(get_root().gui_get_focus_owner() == field, "the probe: a click on the window's line gives it the keyboard (focus %s)" % _focus_name())
	var cover := Control.new()
	cover.name = "Window_cover"
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	cover.position = field_spot - Vector2(30, 30)
	cover.size = Vector2(120, 80)
	panels.add_child(cover)
	await process_frame
	_click(field_spot)
	await process_frame
	_check(get_root().gui_get_focus_owner() == null,
		"a click on a window over another window's line takes the keyboard from it (focus %s)" % _focus_name())
	_type("k")
	await process_frame
	_check(field.text == "", "the key after it is not typed into the covered line (text '%s')" % field.text)
	cover.queue_free()
	field.queue_free()
	panels.call("close", "quest")
	await process_frame

	# (i) The chat line's strip that hangs below the chat window keeps the
	# keyboard: nothing is drawn over it but the bar, which comes earlier.
	var chat_rect := chat.get_global_rect()
	var line_rect := line.get_global_rect()
	if line_rect.end.y > chat_rect.end.y + 2:
		var strip := Vector2(line_rect.get_center().x, (chat_rect.end.y + line_rect.end.y) / 2.0)
		_click(line_spot)
		await process_frame
		_click(strip)
		await process_frame
		_check(get_root().gui_get_focus_owner() == line,
			"a click on the chat line below the chat window keeps it (focus %s at %s)" % [_focus_name(), strip])
	else:
		print("ok  (the chat line does not hang below the chat window here: %s in %s)" % [line_rect, chat_rect])
	get_root().gui_release_focus()

	# (j) Round 606, NEGATIVE (fails on 3d08974): Enter opens the chat line
	# (0x78b660 -> 0x7a9a70), a line is sent and the line keeps the keyboard
	# (0x7ad400's send path), an empty Enter ends the input (0x7ad598), and
	# then the keys are shortcuts again.
	_check(get_root().gui_get_focus_owner() == null, "the probe: nothing has the keyboard (focus %s)" % _focus_name())
	_key(KEY_ENTER)
	await process_frame
	_check(get_root().gui_get_focus_owner() == line, "Enter opens the chat line (focus %s)" % _focus_name())
	_sent.clear()
	_type("yo")
	_key(KEY_ENTER)
	await process_frame
	_check(_sent == ["yo"], "Enter sends it (sent %s)" % [_sent])
	_check(get_root().gui_get_focus_owner() == line, "after a line is sent the line keeps the keyboard (focus %s)" % _focus_name())
	_key(KEY_ENTER)
	await process_frame
	_check(get_root().gui_get_focus_owner() == null, "Enter on the empty line ends the input (focus %s)" % _focus_name())
	_check(_sent == ["yo"], "and sends nothing (sent %s)" % [_sent])
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_check(panels.call("is_open", "quest"), "then Q opens the quest window")
	_key(KEY_Q, "q".unicode_at(0))
	await process_frame
	_key(KEY_KP_ENTER)
	await process_frame
	_check(get_root().gui_get_focus_owner() == line, "the keypad's Enter opens the line too (focus %s)" % _focus_name())
	# Escape in the line ends the input (0x7ad4dd) and opens nothing.
	_key(KEY_ESCAPE)
	await process_frame
	_check(get_root().gui_get_focus_owner() == null and not panels.call("is_open", "system"),
		"Escape in the line ends the input and does not open the System window (focus %s)" % _focus_name())
	# While the HUD is hidden, Enter does not open the line.
	chat.visible = false
	_key(KEY_ENTER)
	await process_frame
	_check(get_root().gui_get_focus_owner() == null, "with the chat hidden, Enter opens nothing (focus %s)" % _focus_name())
	chat.visible = true
