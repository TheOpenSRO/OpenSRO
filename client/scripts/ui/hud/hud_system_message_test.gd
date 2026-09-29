extends SceneTree

## The system message window against what round 639 read out of
## CIFSystemMessage (docs/protocol/system_message.md): the size modes and the
## bottom-right anchor (0x7b87a0), the filter and the colours (0x7781b0,
## 0x7b85f0), the 100-line list, the chat's refusals routed to it, the kill's
## EXP lines (Client_ApplyExpAndLevelUp) and the level-up line's format.
##
## Everything is reached by path and call(), so against a client without
## round 639 this reports FAIL lines instead of failing to compile (the
## negative, run against dev 5a82339). The layout is a synthetic fixture with
## the authored names and rects; no archive is read.

const SYSLOG_PATH := "res://scripts/ui/hud/hud_system_message.gd"
const CHAT_PATH := "res://scripts/ui/hud/hud_chat.gd"
const WORLD_PATH := "res://scripts/World3D.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, id: int, rect: String, style: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"%d\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, id, rect, style]

## ifsystemmessage.txt's controls at their authored rects (the size button's
## 0,0 size is its art's, 16x20, given here).
func _layout() -> String:
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
	cache["resinfo\\ifsystemmessage.txt"] = UiLayoutParser.parse(_layout())
	return builder

func _has(script: Script, method: String) -> bool:
	if script == null:
		return false
	for d in script.get_script_method_list():
		if d["name"] == method:
			return true
	return false

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
	var sys := _load(SYSLOG_PATH)
	_check(sys != null, "the system message window exists (hud_system_message.gd)")
	_static_checks(sys)
	if sys != null:
		await _window_checks(sys)
	await _chat_sink_checks()
	_world_checks()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _static_checks(sys: Script) -> void:
	if not _has(sys, "mode_geometry"):
		_check(false, "HudSystemMessage.mode_geometry lays out the size modes (0x7b87a0)")
		return
	var consts: Dictionary = sys.get_script_constant_map()
	_check(consts.get("MODE_DEFAULT") == 2 and consts.get("MAX_LINES") == 100 and consts.get("LINE_PITCH") == 14,
		"mode 2 at start (+0x370), 100 lines (+0x3a0), pitch 14 (0x638c20(0xe))")
	var g2: Dictionary = sys.call("mode_geometry", 2)
	_check(g2 == {"height": 117, "list_h": 84, "rows": 6, "scroll_len": 27, "scroll_shown": true, "mid_h": 109, "down_y": 113},
		"mode 2: window 117 tall, text 84 showing 6 rows, scroll 27 (got %s)" % [g2])
	var g6: Dictionary = sys.call("mode_geometry", 6)
	_check(g6["height"] == 285 and g6["list_h"] == 252 and g6["scroll_len"] == 195 and g6["mid_h"] == 277 and g6["down_y"] == 281 and g6["rows"] == 18,
		"mode 6 is the layout's own geometry (got %s)" % [g6])
	_check(not bool(sys.call("mode_geometry", 1)["scroll_shown"]), "mode 1 hides the scroll bar (0x7b888e)")
	var r: Rect2 = sys.call("screen_rect", 2, Vector2(1280, 720))
	_check(r == Rect2(923, 513, 350, 117) and r.end.y == 630.0,
		"on 1280x720 mode 2 sits at x = W - 357, y = H - 375 + 4 * 42, bottom H - 90 (got %s)" % [r])
	var r6: Rect2 = sys.call("screen_rect", 6, Vector2(1024, 768))
	_check(r6 == Rect2(667, 393, 350, 285), "mode 6 on 1024x768: (667, 393) 350x285 (got %s)" % [r6])
	# The colours (0x7781b0): type 6 blue, everything else tan.
	var c := func(t: int) -> Color: return sys.call("color_for", t)
	_check(c.call(6) == Color8(0xba, 0xcf, 0xf2) and c.call(0) == Color8(0xdb, 0xc9, 0x9b)
		and c.call(1) == Color8(0xdb, 0xc9, 0x9b) and c.call(2) == Color8(0xdb, 0xc9, 0x9b),
		"type 6 is 0xffbacff2, the rest 0xffdbc99b")

func _window_checks(sys: Script) -> void:
	var w: Control = sys.new(_builder())
	root.add_child(w)
	w.call("setup")
	w.call("anchor_bottom_right")
	await process_frame
	await process_frame
	_check(w.offset_left == -357.0 and w.offset_right == -7.0 and w.offset_bottom == -90.0 and w.offset_top == -207.0 and w.anchor_left == 1.0 and w.anchor_bottom == 1.0,
		"anchored bottom-right: left 357 in, bottom 90 up, 117 tall (got %s..%s, %s..%s)" % [w.offset_left, w.offset_right, w.offset_top, w.offset_bottom])
	var box := w.find_child("GDR_SYETEM_MESSAGE_TEXTBOX", true, false) as Control
	var mid := w.find_child("GDR_SYETEM_MESSAGE_BG_MID", true, false) as Control
	var down := w.find_child("GDR_SYETEM_MESSAGE_BG_DOWN", true, false) as Control
	var btn := w.find_child("GDR_SYETEM_MESSAGE_SIZE_BTN", true, false) as Control
	_check(box != null and box.size == Vector2(316, 84), "the text box is 316x84 in mode 2 (got %s)" % [box.size if box != null else null])
	_check(mid != null and mid.size.y == 109 and down != null and down.position.y == 113,
		"BG_MID 109 tall, BG_DOWN right under it at 113")
	_check(btn != null and btn.position.y == 97.0, "the size button sits on BG_DOWN's bottom, 117 - 20 (got %s)" % [btn.position if btn != null else null])
	var board := w.find_child("GDR_SYETEM_MESSAGE_OPTBOARD", true, false) as CanvasItem
	_check(board != null and not board.visible, "the option board starts hidden (Style 0x40)")
	# The size button: 2 -> 3 .. 6 -> 1 (0x7b89c0).
	var modes: Array = []
	for i in 6:
		w.call("cycle_mode")
		modes.append(int(w.get("mode")))
	_check(modes == [3, 4, 5, 6, 1, 2], "the size button steps 3, 4, 5, 6, 1, 2 (got %s)" % [modes])
	w.call("set_mode", 3)
	_check(w.offset_bottom == -90.0 and w.offset_top == -90.0 - 159.0, "mode 3 keeps the bottom at H - 90, 159 tall")
	_check(box.size.y == 126 and int(w.call("list").get("rows")) == 9, "mode 3's text box: 126 tall, 9 rows")
	w.call("set_mode", 2)
	# The filter (0x7b85f0) and the add (0x7781b0).
	var p := func(t: int) -> bool: return w.call("passes", t)
	_check(p.call(0) and p.call(6) and p.call(1) and p.call(3) and p.call(4) and p.call(5) and p.call(7),
		"types 0 and 6 always pass; 1, 3, 4, 5 and 7 by their checked boxes")
	_check(not p.call(2), "FIGHT (2) starts unchecked (no chop.dat, 0x7a9779)")
	_check(not p.call(8) and not p.call(0xff), "any other type never passes (the switch's default)")
	_check(bool(w.call("add_message", 1, "[120]Experience Points gained.")), "a GAIN line is added")
	_check(not bool(w.call("add_message", 2, "a battle line")), "a FIGHT line is dropped")
	w.call("add_message", 6, "[Guide] a tip")
	var msgs: Array = w.call("messages")
	_check(msgs.size() == 2 and msgs[0]["text"] == "[120]Experience Points gained." and msgs[0]["color"] == Color8(0xdb, 0xc9, 0x9b)
		and msgs[1]["color"] == Color8(0xba, 0xcf, 0xf2), "the window holds the two passed lines in their colours")
	for i in 120:
		w.call("add_message", 0, "line %d" % i)
	msgs = w.call("messages")
	_check(msgs.size() == 100 and msgs[99]["text"] == "line 119" and msgs[0]["text"] == "line 20", "100 lines kept, the oldest dropped")
	var lst: Control = w.call("list")
	_check(lst != null and not bool(lst.get("hover_enabled")), "no hover bar (Create sets no hover colour)")
	w.queue_free()

## The chat's own 0x7781b0 lines go to the system window: the group refusals
## with type 4 (0x7ad866), the server's refusals with type 0 (0x877798).
func _chat_sink_checks() -> void:
	var chat_script := _load(CHAT_PATH)
	var builder := UiBuilder.new(null, null)
	var chat_layout := "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" \
		+ _control("GDR_LIST_APPRENTICE", "CIFTextBox", 30, "27,28,365,343") \
		+ _control("GDR_LIST_CHATALLIACNE", "CIFTextBox", 19, "27,28,365,343") \
		+ _control("GDR_LIST_CHATGUILD", "CIFTextBox", 18, "27,28,365,343") \
		+ _control("GDR_LIST_CHATPARTY", "CIFTextBox", 17, "27,28,365,343") \
		+ _control("GDR_LIST_CHATTING", "CIFTextBox", 16, "27,28,365,343") \
		+ _control("GDR_CHAT_INPUTBOX", "CIFEInputChatBox", 11, "38,378,360,20") + "}\n"
	(builder.get("_layout_cache") as Dictionary)["resinfo\\ifchatviewer.txt" + char(1) + "UI_UPDATE_2009_FIRST"] = \
		UiLayoutParser.parse(chat_layout, true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	var chat: Control = chat_script.new(builder)
	root.add_child(chat)
	chat.call("setup")
	await process_frame
	if not ("system_sink" in chat):
		_check(false, "HudChat hands its refusals to the system window (system_sink)")
		chat.queue_free()
		return
	var got: Array = []
	chat.set("system_sink", func(t: int, text: String) -> void: got.append([t, text]))
	chat.set("group_check", func(_t: int) -> bool: return false)
	_check(chat.find_child("Input", true, false) != null, "the fixture chat has its input line")
	# A party line with no party: 0x7ad400's own refusal.
	chat.call("_on_submitted", "#hello")
	chat.call("on_result", false, 2, 9, 3, "Bram")
	_check(got.size() == 2 and got[0][0] == 4 and String(got[0][1]).begins_with("Cannot find the corresponding party")
		and got[1][0] == 0 and got[1][1] == "Cannot find [Bram].",
		"the party refusal goes out with type 4, the server's with type 0 (got %s)" % [got])
	_check((chat.call("list_messages", 0) as Array).is_empty(), "and nothing lands in the chat's All list")
	chat.queue_free()

func _world_checks() -> void:
	var world := _load(WORLD_PATH)
	if not _has(world, "exp_gain_lines"):
		_check(false, "World3D.exp_gain_lines writes the kill's EXP lines")
	else:
		var l: PackedStringArray = world.call("exp_gain_lines", 1234, 1234,
			"[%I64d]Experience Points gained.", "[%u]skill experience point gained.")
		_check(l == PackedStringArray(["[1234]Experience Points gained.", "[1234]skill experience point gained."]),
			"a kill writes the EXP and skill EXP lines in the archive's words (got %s)" % [l])
		_check((world.call("exp_gain_lines", 0, 0, "", "") as PackedStringArray).is_empty(), "no experience, no line")
		_check(world.call("exp_gain_lines", 0, 5, "", "")[0] == "[5]skill experience point gained.", "the English stands in without a table")
	if not _has(world, "level_up_line"):
		_check(false, "World3D.level_up_line formats the level-up line")
	else:
		_check(world.call("level_up_line", 7, "You have advanced to level [%d].") == "You have advanced to level [7].",
			"the level-up line keeps its brackets, as swprintf leaves them")
