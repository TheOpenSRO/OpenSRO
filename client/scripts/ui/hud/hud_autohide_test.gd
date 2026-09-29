extends SceneTree

## The auto-hide of the chat and the system message window against what
## round 641 read (docs/protocol/chat.md and system_message.md, "Auto-hide"):
## CGInterface's update (0x77b140) asks each window every frame whether its
## frame is wanted -- the chat: the mouse in its rect (both edges inclusive,
## 0xb8f3d0), its input line holding the keyboard, or the mouse in the
## whisper list's rect (0x7a9d10); the system window: its rect, or the open
## filter board's (0x7b85a0) -- and shows or hides the frame (0x7a9bd0,
## 0x7b84e0), never the lines. The chat's lock (ID 12, 0x7a99b0) keeps it
## shown and starts off (0x7ad3e4).
##
## Everything is reached through call() behind has_method, so against a
## client without the auto-hide (the negative, dev 8658370) this reports FAIL
## lines instead of failing to compile. The layouts are synthetic fixtures
## with the authored names and rects; no archive is read.

const CHAT_PATH := "res://scripts/ui/hud/hud_chat.gd"
const SYSLOG_PATH := "res://scripts/ui/hud/hud_system_message.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, id: int, rect: String, style: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"%d\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, id, rect, style]

## ifchatviewer.txt's controls (UI_UPDATE_2009_FIRST), at their authored rects.
func _chat_layout() -> String:
	var body := ""
	body += _control("GDR_WHISPERLIST", "CIFWhisperList", 51, "16,-152,141,153", 64)
	body += _control("GDR_CHAT_VSCROLL", "CIFVerticalScroll", 24, "0,36,16,308")
	body += _control("GDR_STATIC_APPRENTICE", "CIFStatic", 31, "254,6,4,8")
	body += _control("GDR_STATIC_ALLYLAMP", "CIFStatic", 23, "203,6,4,8")
	body += _control("GDR_STATIC_GUILDLAMP", "CIFStatic", 22, "152,6,4,8")
	body += _control("GDR_STATIC_PARTYLAMP", "CIFStatic", 21, "101,6,4,8")
	body += _control("GDR_STATIC_ALLLAMP", "CIFStatic", 20, "50,6,4,8")
	for pair in [["GDR_LIST_APPRENTICE", 30], ["GDR_LIST_CHATALLIACNE", 19], ["GDR_LIST_CHATGUILD", 18],
			["GDR_LIST_CHATPARTY", 17], ["GDR_LIST_CHATTING", 16]]:
		body += _control(pair[0], "CIFTextBox", pair[1], "27,28,365,343")
	body += _control("GDR_BTN_CHAT_SIZE", "CIFButton", 15, "0,378,16,20")
	body += _control("GDR_BUTTON_WHISPERLIST", "CIFButton", 14, "15,0,16,20")
	body += _control("GDR_BUTTON_CHATTABHIDE", "CIFButton", 12, "30,0,16,20")
	body += _control("GDR_CHAT_STA_PENALTY", "CIFStatic", 52, "404,380,160,20")
	body += _control("GDR_CHAT_MODE_VIEW_WND", "CIFChatModeViewer", 42, "0,0,136,20", 64)
	body += _control("GDR_CHAT_MODE_BTN", "CIFButton", 41, "18,378,20,20")
	body += _control("GDR_CHAT_INPUTBOX", "CIFEInputChatBox", 11, "38,378,360,20")
	body += _control("GDR_CHAT_BG_DOWN", "CIFStatic", 7, "18,373,381,4")
	body += _control("GDR_CHAT_BG_MID", "CIFStatic", 6, "18,25,381,348")
	body += _control("GDR_CHAT_BG_UP", "CIFStatic", 5, "18,21,381,4")
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

## ifsystemmessage.txt's controls at their authored rects.
func _sys_layout() -> String:
	var body := ""
	body += _control("GDR_SYETEM_MESSAGE_OPTBOARD", "CIFChatOptionBoard", 50, "207,-155,144,156", 64)
	body += _control("GDR_SYETEM_MESSAGE_VSCROLL", "CIFVerticalScroll", 24, "337,37,16,195")
	body += _control("GDR_SYETEM_MESSAGE_TEXTBOX", "CIFTextBox", 19, "10,15,316,252")
	body += _control("GDR_SYETEM_MESSAGE_SIZE_BTN", "CIFButton", 15, "337,265,16,20")
	body += _control("GDR_SYETEM_MESSAGE_CHATOPTION_BTN", "CIFButton", 13, "337,0,16,16")
	body += _control("GDR_SYETEM_MESSAGE_BG_DOWN", "CIFStatic", 7, "0,281,335,4")
	body += _control("GDR_SYETEM_MESSAGE_BG_MID", "CIFStatic", 6, "0,4,335,277")
	body += _control("GDR_SYETEM_MESSAGE_BG_UP", "CIFStatic", 5, "0,0,335,4")
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	var defines := PackedStringArray(["UI_UPDATE_2009_FIRST"])
	var key := "%s%s%s" % ["resinfo\\ifchatviewer.txt", char(1), char(2).join(defines)]
	cache[key] = UiLayoutParser.parse(_chat_layout(), true, defines)
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(_chat_layout())
	cache["resinfo\\ifsystemmessage.txt"] = UiLayoutParser.parse(_sys_layout())
	return builder

func _load(path: String) -> Script:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Script

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	await _chat_checks(_load(CHAT_PATH))
	await _syslog_checks(_load(SYSLOG_PATH))
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _visible(w: Control, n: String) -> bool:
	var c := w.find_child(n, true, false) as CanvasItem
	return c != null and c.visible

func _node(w: Control, n: String) -> Control:
	return w.find_child(n, true, false) as Control

## Every method the auto-hide adds, reported missing one by one.
func _methods(w: Object, names: Array, who: String) -> bool:
	var ok := true
	for m in names:
		if not w.has_method(m):
			_check(false, "%s has %s()" % [who, m])
			ok = false
	return ok

func _key(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		root.push_input(ev)

func _chat_checks(chat_script: Script) -> void:
	if chat_script == null or not chat_script.can_instantiate():
		_check(false, "HudChat compiles")
		return
	var ui := Control.new()
	ui.size = Vector2(1280, 720)
	root.add_child(ui)
	var chat: Control = chat_script.new(_builder())
	ui.add_child(chat)
	chat.call("setup")
	chat.position = Vector2(0, 400)
	# The test drives the update itself; the real one follows the mouse.
	chat.set_process(false)
	for i in 3:
		await process_frame
	var lock := _node(chat, "GDR_BUTTON_CHATTABHIDE") as BaseButton
	_check(lock != null and lock.tooltip_text == "Lock Chat window/Auto hide",
		"the lock's tooltip is UIIT_STT_CHATING_VIEW_AUTO_OFF's (got %s)" % [lock.tooltip_text if lock != null else null])
	if not _methods(chat, ["update_frame", "frame_wanted", "set_frame_shown", "toggle_lock"], "HudChat"):
		return
	_check(chat.get("locked") == false, "the lock starts off: +0x48c = 0 (0x7ad3e4), auto-hide on")
	_check(chat.get("frame_shown") == true, "the frame starts shown (Create shows it)")
	chat.call("add_chat", 1, "Ann", "one line")
	var lines_before: Array = chat.call("list_lines", 0)
	var r := chat.get_global_rect()
	var outside := Vector2(900, 100)
	var inside := r.get_center()

	# Hidden: the frame's parts go, the lines stay.
	chat.call("update_frame", outside)
	_check(chat.get("frame_shown") == false, "mouse off the window, not typing, unlocked: the frame hides")
	var gone := []
	for n in ["GDR_CHAT_BG_UP", "GDR_CHAT_BG_MID", "GDR_CHAT_BG_DOWN", "GDR_BUTTON_WHISPERLIST",
			"GDR_BUTTON_CHATTABHIDE", "GDR_BTN_CHAT_SIZE", "GDR_CHAT_MODE_BTN", "GDR_CHAT_INPUTBOX",
			"ChatScroll", "ChatTab0", "ChatTab1", "ChatTab4", "GDR_STATIC_ALLLAMP"]:
		if _visible(chat, n):
			gone.append(n)
	_check(gone.is_empty(), "hidden: bands, both top-left buttons, size, mode button, input, scroll bar, tabs, lamp (still shown: %s)" % [gone])
	_check(_visible(chat, "GDR_LIST_CHATTING") and chat.call("list_lines", 0) == lines_before,
		"hidden: the All list stays, its lines kept (0x7a9bd0 never touches the lists)")
	_check(_visible(chat, "GDR_CHAT_STA_PENALTY"), "hidden: the penalty line (ID 52) is not the frame's")

	# Shown again by the mouse.
	chat.call("update_frame", inside)
	_check(chat.get("frame_shown") == true, "mouse inside the window's rect: the frame shows")
	_check(_visible(chat, "GDR_CHAT_BG_MID") and _visible(chat, "ChatTab0") and _visible(chat, "GDR_CHAT_INPUTBOX")
		and _visible(chat, "GDR_BUTTON_CHATTABHIDE") and _visible(chat, "ChatScroll"),
		"shown: bands, tabs, input, lock button and scroll bar back")
	_check(_visible(chat, "GDR_STATIC_ALLLAMP") and not _visible(chat, "GDR_STATIC_PARTYLAMP"),
		"shown: only the selected tab's lamp (0x7a9a80(0))")
	_check(bool(chat.call("frame_wanted", r.end)) and bool(chat.call("frame_wanted", r.position)),
		"0xb8f3d0 is inclusive: both corners count")
	_check(not bool(chat.call("frame_wanted", r.end + Vector2(1, 0))), "one pixel right of the rect does not")
	var whisper_pt := r.position + Vector2(20, -100)
	_check(bool(chat.call("frame_wanted", whisper_pt)),
		"the hidden whisper list's rect (16,-152,141,153) above the window counts (0x7a9d3f)")
	_check(not bool(chat.call("frame_wanted", r.position + Vector2(200, -100))), "beside it, above the window, does not")

	# Typing keeps it: Enter opens the line with the frame hidden.
	chat.call("update_frame", outside)
	_check(chat.get("frame_shown") == false, "hidden again")
	var input := _node(chat, "Input") as LineEdit
	_key(KEY_ENTER)
	await process_frame
	_check(input != null and input.has_focus() and chat.get("frame_shown") == true,
		"Enter with the frame hidden: the line has the keyboard and the frame shows")
	chat.call("update_frame", outside)
	_check(chat.get("frame_shown") == true, "typing keeps the frame with the mouse away (0x634ea0)")
	_key(KEY_ESCAPE)
	await process_frame
	_check(input != null and not input.has_focus(), "Escape gives the keyboard back")
	chat.call("update_frame", outside)
	_check(chat.get("frame_shown") == false, "and the next update hides the frame")
	_check(bool(chat.call("open_with", "$Ann ")) and input.has_focus() and chat.get("frame_shown") == true,
		"R's reply opens the line with the frame hidden too")
	input.release_focus()
	chat.call("update_frame", outside)

	# The lock.
	if lock != null:
		lock.pressed.emit()
	_check(chat.get("locked") == true, "the lock button flips +0x48c on (0x7a99b0)")
	chat.call("update_frame", outside)
	_check(chat.get("frame_shown") == true, "locked: the frame stays with the mouse away")
	if lock != null:
		lock.pressed.emit()
	chat.call("update_frame", outside)
	_check(chat.get("locked") == false and chat.get("frame_shown") == false, "unlocked again: it hides")

	# Mode 0: the input row alone follows the frame; the buttons stay hidden.
	chat.call("set_mode", 0)
	chat.call("update_frame", chat.get_global_rect().get_center())
	_check(_visible(chat, "GDR_CHAT_INPUTBOX") and _visible(chat, "GDR_BTN_CHAT_SIZE")
		and not _visible(chat, "GDR_BUTTON_CHATTABHIDE") and not _visible(chat, "ChatTab0"),
		"mode 0 shown: the input row, not the lock or the tabs (0x7a9bd0's mode-0 branch)")
	chat.call("update_frame", outside)
	_check(not _visible(chat, "GDR_CHAT_INPUTBOX") and not _visible(chat, "GDR_BTN_CHAT_SIZE"),
		"mode 0 hidden: the input row goes too")
	# A mouse event runs the test at its own position at once (OURS,
	# FrameWatch): a move over the window shows the frame without an update.
	chat.call("set_mode", 2)
	chat.call("update_frame", outside)
	var mm := InputEventMouseMotion.new()
	mm.position = chat.get_global_rect().get_center()
	mm.global_position = mm.position
	root.push_input(mm)
	_check(chat.get("frame_shown") == true, "a mouse move over the window shows the frame at once")
	var away := InputEventMouseMotion.new()
	away.position = outside
	away.global_position = outside
	root.push_input(away)
	_check(chat.get("frame_shown") == false, "and a move away hides it")
	chat.set_process(true)
	_check(chat.is_processing(), "the update runs every frame (_process)")
	ui.queue_free()
	await process_frame

func _syslog_checks(sys: Script) -> void:
	if sys == null or not sys.can_instantiate():
		_check(false, "HudSystemMessage compiles")
		return
	var ui := Control.new()
	ui.size = Vector2(1280, 720)
	root.add_child(ui)
	var w: Control = sys.new(_builder())
	ui.add_child(w)
	w.call("setup")
	w.position = Vector2(923, 513)
	w.set_process(false)
	for i in 3:
		await process_frame
	if not _methods(w, ["update_frame", "frame_wanted", "set_frame_shown"], "HudSystemMessage"):
		return
	_check(sys.get_script_constant_map().get("AUTO_HIDE") == true, "the system window's auto-hide is always on (OURS, the user's decision)")
	w.call("add_message", 0, "a line")
	var r := w.get_global_rect()
	var outside := Vector2(100, 100)
	w.call("update_frame", outside)
	var still := []
	for n in ["GDR_SYETEM_MESSAGE_BG_UP", "GDR_SYETEM_MESSAGE_BG_MID", "GDR_SYETEM_MESSAGE_BG_DOWN",
			"GDR_SYETEM_MESSAGE_SIZE_BTN", "GDR_SYETEM_MESSAGE_CHATOPTION_BTN", "SystemScroll"]:
		if _visible(w, n):
			still.append(n)
	_check(w.get("frame_shown") == false and still.is_empty(),
		"mouse away: bands, both buttons and the scroll bar hide (0x7b84e0(0); still shown: %s)" % [still])
	_check(_visible(w, "GDR_SYETEM_MESSAGE_TEXTBOX") and (w.call("messages") as Array).size() == 1,
		"the text box and its line stay")
	w.call("update_frame", r.get_center())
	_check(w.get("frame_shown") == true and _visible(w, "GDR_SYETEM_MESSAGE_BG_MID") and _visible(w, "SystemScroll"),
		"mouse over the window: the frame and the scroll bar (mode 2) show")
	_check(bool(w.call("frame_wanted", r.end)) and not bool(w.call("frame_wanted", r.end + Vector2(0, 1))),
		"the rect test is inclusive, and ends there")
	# A mode change while hidden leaves the scroll bar hidden (0x7b8885).
	w.call("update_frame", outside)
	w.call("set_mode", 3)
	_check(not _visible(w, "SystemScroll"), "set_mode while hidden: the scroll bar stays hidden")
	w.call("update_frame", r.get_center())
	w.call("set_mode", 1)
	w.call("update_frame", outside)
	w.call("update_frame", w.get_global_rect().get_center())
	_check(w.get("frame_shown") == true and not _visible(w, "SystemScroll"),
		"mode 1: shown again, the scroll bar stays hidden (0x7b84e0 skips it in mode 1)")
	w.call("set_mode", 2)
	# The open filter board counts, and hides with the frame.
	var board := _node(w, "GDR_SYETEM_MESSAGE_OPTBOARD")
	_check(board != null and not board.visible, "the board starts hidden")
	var above := w.get_global_rect().position + Vector2(250, -60)
	_check(not bool(w.call("frame_wanted", above)), "the hidden board's rect does not count")
	if board != null:
		board.visible = true
	_check(bool(w.call("frame_wanted", above)), "the shown board's rect does (0x7b85a0)")
	w.call("update_frame", outside)
	_check(board != null and not board.visible and w.get("frame_shown") == false, "hiding the frame hides the open board")
	ui.queue_free()
	await process_frame
