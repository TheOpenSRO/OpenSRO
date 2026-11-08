extends SceneTree

## The chat window against what round 634 read out of CIFChatViewer
## (docs/protocol/chat.md): the five tabs and their lamps, what each tab
## files, the per-type colours and captions, the channel marks the input line
## reads, the wrap indent, the scroll bar, the sender's echo and refusals, and
## the notice banner's life.
##
## Everything is reached by path and call(), so against a client without the
## round-634 chat this reports FAIL lines instead of failing to compile (the
## negative, run against dev b9bbf07). The layout is a synthetic fixture with
## the authored names and rects; no archive is read.

const CHAT_PATH := "res://scripts/ui/hud/hud_chat.gd"
const NOTICE_PATH := "res://scripts/ui/hud/hud_notice.gd"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, id: int, rect: String) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, id, rect]

## ifchatviewer.txt's controls this test reads, at their authored rects.
func _chat_layout() -> String:
	var body := ""
	body += _control("GDR_CHAT_VSCROLL", "CIFVerticalScroll", 24, "0,36,16,308")
	body += _control("GDR_STATIC_APPRENTICE", "CIFStatic", 31, "254,6,4,8")
	body += _control("GDR_STATIC_ALLYLAMP", "CIFStatic", 23, "203,6,4,8")
	body += _control("GDR_STATIC_GUILDLAMP", "CIFStatic", 22, "152,6,4,8")
	body += _control("GDR_STATIC_PARTYLAMP", "CIFStatic", 21, "101,6,4,8")
	body += _control("GDR_STATIC_ALLLAMP", "CIFStatic", 20, "50,6,4,8")
	for pair in [["GDR_LIST_APPRENTICE", 30], ["GDR_LIST_CHATALLIACNE", 19], ["GDR_LIST_CHATGUILD", 18],
			["GDR_LIST_CHATPARTY", 17], ["GDR_LIST_CHATTING", 16]]:
		body += _control(pair[0], "CIFTextBox", pair[1], "27,28,365,343")
	body += _control("GDR_BUTTON_WHISPERLIST", "CIFButton", 14, "15,0,16,20")
	body += _control("GDR_BUTTON_CHATTABHIDE", "CIFButton", 12, "30,0,16,20")
	body += _control("GDR_CHAT_INPUTBOX", "CIFEInputChatBox", 11, "38,378,360,20")
	body += _control("GDR_BTN_CHAT_SIZE", "CIFButton", 15, "0,378,16,20")
	body += _control("GDR_CHAT_STA_PENALTY", "CIFStatic", 52, "404,380,160,20")
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	var key := "%s%s%s" % ["resinfo\\ifchatviewer.txt", char(1), char(2).join(PackedStringArray(["UI_UPDATE_2009_FIRST"]))]
	cache[key] = UiLayoutParser.parse(_chat_layout(), true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(_chat_layout())
	return builder

func _has(script: Script, method: String) -> bool:
	if script == null:
		return false
	for d in script.get_script_method_list():
		if d["name"] == method:
			return true
	return false

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var chat_script := load(CHAT_PATH) as Script
	_static_checks(chat_script)
	await _window_checks(chat_script)
	_notice_checks()
	_panels_checks()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _static_checks(chat_script: Script) -> void:
	# The channel marks (0x7ad400).
	if not _has(chat_script, "parse_line"):
		_check(false, "HudChat.parse_line reads the channel from the line's first character")
	else:
		var p := func(t: String, gm := false) -> Dictionary: return chat_script.call("parse_line", t, gm)
		_check(p.call("#hi")["type"] == 4 and p.call("#hi")["message"] == "hi", "'#' is party (4), the mark not sent")
		_check(p.call("@hi")["type"] == 5, "'@' is guild (5)")
		_check(p.call("%hi")["type"] == 0x0b, "'%' is union (0x0b)")
		_check(p.call("&hi")["type"] == 0x10, "'&' is academy (0x10)")
		var w: Dictionary = p.call("$Bram hey there")
		_check(w["type"] == 2 and w["target"] == "Bram" and w["message"] == "hey there",
			"'$Bram hey there' whispers Bram 'hey there' (0x7ab230 splits at the first space; got %s)" % [w])
		_check(p.call("$Bram")["type"] == -1 and p.call("$Bram ")["type"] == -1 and p.call("#")["type"] == -1,
			"a lone mark or a whisper with no text is not sent")
		_check(p.call("/w a b")["type"] == -2, "'/' is a command")
		_check(p.call("hello")["type"] == 1 and p.call("hello", true)["type"] == 3,
			"an unmarked line is type 1, type 3 from a GM")
	var consts: Dictionary = chat_script.get_script_constant_map() if chat_script != null else {}
	_check(String(consts.get("LONE_MARKS", "")) == "#$%&/@^~", "the tab switch's lone marks are 0x7aa9dc's # $ %% & / @ ^ ~ (got '%s')" % consts.get("LONE_MARKS", ""))
	_check(consts.get("LINE_PITCH") == 14 and consts.get("MODE_DEFAULT") == 2, "pitch 14 (+0x39c) and mode 2 at start (+0x428)")
	if _has(chat_script, "mode_geometry"):
		var g2: Dictionary = chat_script.call("mode_geometry", 2)
		var g6: Dictionary = chat_script.call("mode_geometry", 6)
		_check(g2 == {"height": 175, "list_h": 119, "rows": 8, "scroll_len": 84, "mid_h": 124, "down_y": 149, "row_y": 154},
			"mode 2: window 175, lists 119 showing 8 rows, scroll 84 (got %s)" % [g2])
		_check(g6["list_h"] == 343 and g6["scroll_len"] == 308 and g6["row_y"] == 378 and g6["down_y"] == 373 and g6["mid_h"] == 348,
			"mode 6 is the layout's own geometry (got %s)" % [g6])
		_check(chat_script.call("mode_geometry", 0)["height"] == 21, "mode 0 is the 0x15-tall input row")
	else:
		_check(false, "HudChat.mode_geometry lays out the size modes (0x7aac20)")
	if _has(chat_script, "caption_for"):
		_check(chat_script.call("caption_for", "UIIT_CTL_CHATMENU_TRAININGCAMP", "&Team", "&Academy") == "&Academy",
			"the private archive's '&Team' gives way to the vanilla '&Academy'")
		_check(chat_script.call("caption_for", "UIIT_CTL_CHAT_ALL", "All", "All") == "All", "other captions are the table's")
	else:
		_check(false, "HudChat.caption_for keeps a private-server row off the Academy tab")
	# What each tab files (0x7aca30).
	if not _has(chat_script, "lists_for"):
		_check(false, "HudChat.lists_for routes a line to its tabs")
	else:
		var l := func(t: int) -> Array: return Array(chat_script.call("lists_for", t))
		_check(l.call(1) == [0] and l.call(6) == [0], "ordinary chat and a global go to All only")
		_check(l.call(4) == [0, 1] and l.call(5) == [0, 2] and l.call(0x0b) == [0, 3] and l.call(0x10) == [0, 4],
			"party, guild, union and academy go to All and their own tab")
		_check(l.call(2) == [0, 1, 2, 3, 4] and l.call(3) == [0, 1, 2, 3, 4],
			"a whisper and a GM line go to every tab")
		_check(l.call(7) == [] and l.call(9) == [], "0x7aca30 files no type 7 or 9 line itself")
	# The colours (0x876810).
	if not _has(chat_script, "color_for"):
		_check(false, "HudChat.color_for colours a line by type")
	else:
		var c := func(t: int) -> Color: return chat_script.call("color_for", t)
		_check(c.call(1) == Color8(255, 255, 255), "all: white")
		_check(c.call(6) == Color8(255, 255, 0), "global: 0xffffff00")
		_check(c.call(7) == Color8(255, 0xae, 0xc3) and c.call(3) == Color8(255, 0xae, 0xc3), "notice and GM: 0xffffaec3")
		_check(c.call(2) == Color8(0x9f, 0xff, 0xfe), "whisper: 0xff9ffffe")
		_check(c.call(4) == Color8(0x9a, 0xff, 0xd0), "party: 0xff9affd0")
		_check(c.call(5) == Color8(0xff, 0xb5, 0x41), "guild: 0xffffb541")
		_check(c.call(0x0b) == Color8(0xc2, 0xf5, 0x73), "union: 0xffc2f573")
		_check(c.call(0x10) == Color8(0x64, 0xc7, 0xff), "academy: 0xff64c7ff")
	# The line after a send (0x7add04..0x7ade70).
	if not _has(chat_script, "line_after_send"):
		_check(false, "HudChat.line_after_send resets the input line")
	else:
		var a := func(d: Dictionary, tab: int) -> String: return chat_script.call("line_after_send", d, tab)
		_check(a.call({"type": 1, "message": "x"}, 0) == "", "after ordinary chat on All: empty")
		_check(a.call({"type": 2, "target": "Bram", "message": "x"}, 0) == "$Bram ", "after a whisper: '$Bram '")
		_check(a.call({"type": 4, "message": "x"}, 0) == "#", "after a party line: '#'")
		_check(a.call({"type": 1, "message": "x"}, 2) == "@", "on the @Guild tab, always '@'")

func _window_checks(chat_script: Script) -> void:
	if chat_script == null or not chat_script.can_instantiate():
		_check(false, "HudChat compiles")
		return
	var ui := Control.new()
	ui.size = Vector2(1024, 768)
	root.add_child(ui)
	var chat: Control = chat_script.new(_builder())
	ui.add_child(chat)
	chat.call("setup")
	for i in 4:
		await process_frame

	# The tabs (0x7ab920).
	var tabs := []
	var built := 0
	for i in 5:
		var t := chat.find_child("ChatTab%d" % i, true, false)
		tabs.append(t)
		if t != null:
			built += 1
	_check(built == 5, "five tabs are built (%d)" % built)
	if built == 5:
		var at := []
		for t in tabs:
			at.append(Rect2((t as Control).position, (t as Control).size))
		_check(at == [Rect2(45, 0, 71, 20), Rect2(115, 0, 71, 20), Rect2(185, 0, 71, 20), Rect2(255, 0, 71, 20), Rect2(325, 0, 71, 20)],
			"the tabs are 71x20 at x = 45 + 70 i (got %s)" % [at])
		_check([tabs[0].caption, tabs[1].caption, tabs[2].caption, tabs[3].caption, tabs[4].caption]
			== ["All", "#Party", "@Guild", "%Union", "&Academy"],
			"the captions are All, #Party, @Guild, %Union, &Academy (no text table here: the fallbacks)")
	# The lamps and the lists.
	var lamps := ["GDR_STATIC_ALLLAMP", "GDR_STATIC_PARTYLAMP", "GDR_STATIC_GUILDLAMP", "GDR_STATIC_ALLYLAMP", "GDR_STATIC_APPRENTICE"]
	var lists := ["GDR_LIST_CHATTING", "GDR_LIST_CHATPARTY", "GDR_LIST_CHATGUILD", "GDR_LIST_CHATALLIACNE", "GDR_LIST_APPRENTICE"]
	var shown := func(names: Array) -> Array:
		var out := []
		for n in names:
			var c := chat.find_child(n, true, false) as Control
			if c != null and c.visible:
				out.append(n)
		return out
	var lamp_x := []
	for n in lamps:
		var c := chat.find_child(n, true, false) as Control
		lamp_x.append(c.position.x if c != null else -1.0)
	_check(lamp_x == [48.0, 118.0, 188.0, 258.0, 328.0], "the lamps sit at x = 48 + 70 i (got %s)" % [lamp_x])
	_check(shown.call(lamps) == ["GDR_STATIC_ALLLAMP"] and shown.call(lists) == ["GDR_LIST_CHATTING"],
		"All starts selected: its lamp and list only (lamps %s, lists %s)" % [shown.call(lamps), shown.call(lists)])
	# Mode 2 at start (+0x428 = 2).
	var box := chat.find_child("GDR_LIST_CHATTING", true, false) as Control
	var inbox := chat.find_child("GDR_CHAT_INPUTBOX", true, false) as Control
	_check(chat.size.y == 175.0 and box != null and box.size.y == 119.0 and inbox != null and inbox.position.y == 154.0,
		"the window opens in mode 2: 175 tall, lists 119, the input row at 154 (got %s, %s, %s)" % [chat.size.y,
		box.size.y if box != null else -1.0, inbox.position.y if inbox != null else -1.0])
	# The penalty line at the size button's y + 3 (0x7ab1cb `add ecx,0x3`),
	# its own x kept: 157 in mode 2, not the authored 2 below the row.
	var penalty := chat.find_child("GDR_CHAT_STA_PENALTY", true, false) as Control
	_check(penalty != null and penalty.position == Vector2(404, 157),
		"the penalty line sits at (404, row + 3 = 157) (got %s)" % [penalty.position if penalty != null else null])
	if not tabs.has(null) and not tabs[0].has_method("text_color"):
		_check(false, "the selected caption is white, the others grey 0xffb4b4b4 (ChatTab.text_color)")
	elif not tabs.has(null):
		_check(tabs[0].call("text_color") == Color8(255, 255, 255) and tabs[1].call("text_color") == Color8(0xb4, 0xb4, 0xb4),
			"the selected caption is white, the others grey 0xffb4b4b4")
	if not _has(chat_script, "select_tab"):
		_check(false, "HudChat.select_tab switches tabs")
		chat.free()
		ui.free()
		return
	var line := chat.find_child("Input", true, false) as LineEdit
	chat.call("select_tab", 1)
	_check(shown.call(lamps) == ["GDR_STATIC_PARTYLAMP"] and shown.call(lists) == ["GDR_LIST_CHATPARTY"],
		"#Party selected: its lamp and list only")
	_check(line != null and line.text == "#", "an empty input line takes the tab's mark '#' (got '%s')" % (line.text if line != null else ""))
	chat.call("select_tab", 0)
	_check(line != null and line.text == "", "back on All the lone mark goes")

	# Filing.
	chat.set("own_name", "Aria")
	chat.call("add_chat", 1, "Bram", "hello")
	chat.call("add_chat", 4, "Bram", "pull")
	chat.call("add_chat", 2, "Cato", "psst")
	chat.call("add_chat", 7, "", "Maintenance soon")
	chat.call("add_chat", 6, "Dax", "WTS blade")
	var texts := func(i: int) -> Array:
		var out := []
		for m in chat.call("list_messages", i):
			out.append(m["text"])
		return out
	_check(texts.call(0) == ["Bram:hello", "Bram(Party):pull", "Cato(FROM):psst", "(Notice):Maintenance soon", "Dax:WTS blade"],
		"All holds every line in 0x876810's format (got %s)" % [texts.call(0)])
	_check(texts.call(1) == ["Bram(Party):pull", "Cato(FROM):psst", "(Notice):Maintenance soon"],
		"#Party holds the party line, the whisper and the notice (got %s)" % [texts.call(1)])
	_check(texts.call(2) == ["Cato(FROM):psst", "(Notice):Maintenance soon"], "@Guild: the whisper and the notice only (got %s)" % [texts.call(2)])
	var global_color: Color = (chat.call("list_messages", 0) as Array)[4]["color"]
	_check(global_color == Color8(255, 255, 0), "the global line is yellow")

	# Bottom stacking and the hover bar (0x639ab0, 0x63ad10), on a fresh list.
	var list = chat.find_child("Messages", true, false)
	if list != null and not list.has_method("top_offset"):
		_check(false, "lines stack from the bottom and the hovered row is barred (ChatList.top_offset / line_at)")
	elif list != null:
		var n: int = (list.lines as Array).size()
		_check(list.line_height() == 14.0 and list.rows == 8, "the list draws 8 rows 14 apart in mode 2")
		_check(list.top_offset() == 14.0 * maxf(0, 8 - n), "%d lines stack from the bottom: the first is %s down" % [n, list.top_offset()])
		var ev := InputEventMouseMotion.new()
		ev.position = Vector2(20, list.top_offset() + 14.0 * 1 + 3)
		list._gui_input(ev)
		_check(list.hover == list.first + 1, "a mouse over the second drawn row hovers it (hover %d)" % list.hover)
		ev.position = Vector2(20, 1)
		list._gui_input(ev)
		_check(list.hover == -1 or n >= 8, "above the stacked lines nothing is hovered")

	# 0x7ad400's own refusal of a group line with no group.
	chat.set("group_check", func(_t: int) -> bool: return false)
	var sent_lines: Array = []
	chat.message_submitted.connect(func(t: String) -> void: sent_lines.append(t))
	if line != null:
		line.text = "#anyone"
		line.text_submitted.emit(line.text)
		_check(sent_lines.is_empty() and line.text == "", "a party line with no party is not sent and the box empties")
		_check(texts.call(0).back() == "Cannot find the corresponding party.", "and the refusal is shown (got %s)" % texts.call(0).back())
		line.text = "@anyone"
		line.text_submitted.emit(line.text)
		_check(texts.call(0).back() == "Cannot carry this function out because you do not belong to the guild.", "the guild's own refusal")
		line.text = "&anyone"
		line.text_submitted.emit(line.text)
		_check(texts.call(0).back() == "You do not belong to an Academy.", "the academy's own refusal")
	chat.set("group_check", func(_t: int) -> bool: return true)

	# The sender's echo and a refusal (0xB025).
	var req: Dictionary = chat.call("request_for", "#on my way")
	_check(req.get("type") == 4 and req.get("message") == "on my way", "request_for gives the party request")
	chat.call("on_result", true, 4, int(req.get("index", 0)), 0, "")
	_check(texts.call(1).back() == "Aria(Party):on my way", "an OK answer shows the player's own party line (got %s)" % [texts.call(1).back()])
	# Round 865 stage 3: the server's copy of the sender's own party or
	# academy line is dropped (c:0x877810 cases 4 and 0x10); others are not.
	var drops: Callable = func(t: int, s: String) -> bool: return HudChat.drops_own_copy(t, s, "Aria")
	_check(drops.call(0x10, "Aria") and drops.call(4, "Aria"), "the own academy and party copies are dropped")
	_check(not drops.call(0x10, "Bram") and not drops.call(5, "Aria") and not drops.call(0x10, ""),
		"another member's academy line, an own guild line and a nameless line are kept")
	var wreq: Dictionary = chat.call("request_for", "$Ghost hello")
	chat.call("on_result", false, 2, int(wreq.get("index", 0)), 3, "Ghost")
	_check(texts.call(0).back() == "Cannot find [Ghost].", "code 3 shows 'Cannot find [Ghost].' (got %s)" % [texts.call(0).back()])
	var sreq: Dictionary = chat.call("request_for", "$Bram hi")
	chat.call("on_result", true, 2, int(sreq.get("index", 0)), 0, "Bram")
	_check(texts.call(0).back() == "Bram(TO):hi", "a sent whisper echoes as 'Bram(TO):hi'")

	# The input line.
	if line != null:
		line.text = "#hello"
		line.text_submitted.emit(line.text)
		_check(line.text == "#", "after a party line the input keeps '#' (got '%s')" % line.text)
		line.text = "$Bram hi"
		line.text_submitted.emit(line.text)
		_check(line.text == "$Bram ", "after a whisper it holds '$Bram ' (got '%s')" % line.text)

	# The wrap and its indent (0x64e930).
	var font: Font = ThemeDB.fallback_font
	var wrapped: PackedStringArray = chat_script.call("wrap", "word ".repeat(40).strip_edges(), font, 12, 200.0)
	var space_w := font.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var indent := " ".repeat(maxi(1, int(20.0 / space_w)))
	_check(wrapped.size() > 1, "a long line wraps (%d lines)" % wrapped.size())
	var ok_indent := wrapped.size() > 1
	for i in range(1, wrapped.size()):
		ok_indent = ok_indent and wrapped[i].begins_with(indent) and not wrapped[i].substr(indent.length()).begins_with(" ")
	_check(ok_indent, "every continuation line starts with floor(20 / space width) = %d spaces" % indent.length())
	_check(not wrapped[0].begins_with(" "), "the first line is not indented")

	# The scroll bar (0x65a390 / 0x659150), in mode 6, the layout's length.
	if chat.has_method("set_mode"):
		chat.call("set_mode", 6)
	for i in 120:
		chat.call("add_chat", 1, "Bram", "line %d" % i)
	await process_frame
	var mx: int = chat.call("scroll_max")
	_check(mx > 0 and chat.call("scroll_position") == mx, "a full list sits at the bottom (%d of %d)" % [chat.call("scroll_position"), mx])
	var kept: Array = chat.call("list_messages", 0)
	_check(kept.size() == 100 and kept[0]["text"] == "Bram:line 20", "a list keeps its last 100 lines (%d, first '%s')" % [kept.size(), kept[0]["text"] if not kept.is_empty() else ""])
	chat.call("scroll_by", -5)
	var bar = chat.call("scroll_bar")
	_check(chat.call("scroll_position") == mx - 5 and bar != null and bar.pos == mx - 5, "scrolling up five lines moves the list and the bar")
	if bar != null:
		_check(bar.position == Vector2(0, 20) and bar.size == Vector2(16, 356), "the bar spans the up arrow at y 20 to the down arrow's bottom at 376 (got %s %s)" % [bar.position, bar.size])
		_check(bar.thumb_y() == 16.0 + floor(float(mx - 5) * 308.0 / float(mx)), "the thumb is (pos * 308 / max) below the bar's top")
		_check(bar.down_y() == 16.0 + 308.0 + 16.0, "the down arrow is 308 + 16 below the bar's top")
	# The size button (0x7ac2a0): 6 wraps to 0, the input row alone.
	var size_btn := chat.find_child("GDR_BTN_CHAT_SIZE", true, false) as BaseButton
	var bottom: float = chat.position.y + chat.size.y
	if not chat.has_method("cycle_mode"):
		_check(false, "the size button steps the mode (0x7ac2a0)")
		chat.free()
		ui.free()
		return
	chat.call("cycle_mode")
	_check(chat.get("mode") == 0 and chat.size.y == 21.0 and not (tabs[0] as Control).visible,
		"mode 6 steps to 0: 21 tall, tabs hidden")
	_check(chat.position.y + chat.size.y == bottom, "the bottom edge stays put")
	chat.call("cycle_mode")
	_check(chat.get("mode") == 1 and chat.size.y == 399.0 - 5 * 56 and (tabs[0] as Control).visible, "and 0 to 1")
	_check(size_btn == null or size_btn.pressed.get_connections().size() > 0, "GDR_BTN_CHAT_SIZE runs the step")
	chat.free()
	ui.free()

func _notice_checks() -> void:
	var s := load(NOTICE_PATH) as Script
	if s == null or not _has(s, "alpha_for"):
		_check(false, "HudNotice fades out over its last 2000 ms of 7000")
		return
	_check(s.call("alpha_for", 7000) == 1.0 and s.call("alpha_for", 2001) == 1.0, "full alpha until the last 2000 ms")
	_check(is_equal_approx(s.call("alpha_for", 1000), float(1000 * 255 / 2000) / 255.0) and s.call("alpha_for", 0) == 0.0,
		"then remaining * 255 / 2000")
	var n: Control = s.new()
	root.add_child(n)
	n.call("setup", null)
	n.call("show_notice", "Server maintenance")
	_check(n.visible and n.call("remaining_ms") == 7000 and n.position.y == 100.0,
		"a notice shows for 7000 ms at GDR_NOTICE's y, 100 (0x78cbbe; round 657)")
	# Measured in the text's own face, the weight-600 variant (text flag 2,
	# round 703).
	var want: float = ceilf(n.call("text_width", "Server maintenance")) if n.has_method("text_width") \
		else ThemeDB.fallback_font.get_string_size("Server maintenance", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	_check(n.size.x == want, "the banner is the text's extent (0x7b3eb0) (got %s)" % n.size)
	n.call("advance", 7000)
	_check(not n.visible, "and is gone after 7000 ms")
	n.free()

func _panels_checks() -> void:
	var s := load(PANELS_PATH) as Script
	if s == null or not _has(s, "is_global_chat_item"):
		_check(false, "HudPanels knows the global chatting item (TypeID 3/3/3/5)")
		return
	_check(s.call("is_global_chat_item", PackedInt32Array([3, 3, 3, 5])), "3/3/3/5 is the global chatting item")
	_check(not s.call("is_global_chat_item", PackedInt32Array([3, 3, 3, 1])), "3/3/3/1 is not")
