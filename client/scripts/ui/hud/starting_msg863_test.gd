extends SceneTree

## Round 863: the starting message. CGInterface::Create (c:0x78c910) adds
## its text to the chat window as a type-0xff line in 0xffdbc99b (0x78cf1d ->
## 0x777c60 -> 0x7aca30): every list, that colour; its line breaks start new
## rows at the left edge, and only a row too long for the list wraps with the
## hanging indent. The words are OpenSRO's own (OURS): the archive's row is
## not used, whatever it says. No archive is read: the layout is a fixture.

const CHAT_PATH := "res://scripts/ui/hud/hud_chat.gd"
const TEXT := "An archive's own welcome row\n with a website in it."

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, id: int, rect: String) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, id, rect]

func _layout() -> String:
	var body := ""
	body += _control("GDR_CHAT_VSCROLL", "CIFVerticalScroll", 24, "0,36,16,308")
	for pair in [["GDR_LIST_APPRENTICE", 30], ["GDR_LIST_CHATALLIACNE", 19], ["GDR_LIST_CHATGUILD", 18],
			["GDR_LIST_CHATPARTY", 17], ["GDR_LIST_CHATTING", 16]]:
		body += _control(pair[0], "CIFTextBox", pair[1], "27,28,365,343")
	body += _control("GDR_CHAT_INPUTBOX", "CIFEInputChatBox", 11, "38,378,360,20")
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _builder(with_text: bool) -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	var key := "%s%s%s" % ["resinfo\\ifchatviewer.txt", char(1), char(2).join(PackedStringArray(["UI_UPDATE_2009_FIRST"]))]
	cache[key] = UiLayoutParser.parse(_layout(), true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(_layout())
	var table := UiTextTable.new()
	if with_text:
		table._strings["UIIT_STT_STARTING_MSG"] = TEXT
	builder._text_table = table
	return builder

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var chat_script: Script = load(CHAT_PATH)
	if chat_script == null or not chat_script.can_instantiate():
		_check(false, "HudChat compiles")
		_finish()
		return
	var ui := Control.new()
	ui.size = Vector2(1024, 768)
	root.add_child(ui)

	var chat: Control = chat_script.new(_builder(true))
	ui.add_child(chat)
	chat.call("setup")
	for i in 4:
		await process_frame
	_check(chat.has_method("add_starting_message"), "HudChat has add_starting_message")
	if chat.has_method("add_starting_message"):
		_check(chat.call("add_starting_message") == true, "the starting message is added")
		for tab in 5:
			var msgs: Array = chat.call("list_messages", tab)
			_check(msgs.size() == 1, "tab %d holds it (type 0xff: every list) (got %d)" % [tab, msgs.size()])
			if msgs.size() == 1:
				var c: Color = msgs[0]["color"]
				_check(c.r8 == 0xdb and c.g8 == 0xc9 and c.b8 == 0x9b and c.a8 == 0xff,
					"tab %d: in 0xffdbc99b (got %s)" % [tab, c])
		var rows: Array = chat.call("list_lines", 0)
		var texts := []
		for r in rows:
			texts.append(String(r["text"]) if r is Dictionary else String(r))
		print("rows: %s" % [texts])
		_check(texts.has(" across the wide open Silk Road."), "a break starts a new row, its own leading space kept, no hanging indent")
		_check(texts.has("Grow into a true adventurer"), "a row after a break starts at the left edge")
		_check(texts.has(" Have a great time in OpenSRO."), "the last row")
		_check(not texts.has(" with a website in it."), "the archive's row is not used (OURS)")
		var joined := "".join(PackedStringArray(texts))
		_check(not joined.contains("\\n") and not joined.contains("\n"), "no written or real break is drawn")
	ui.remove_child(chat)
	chat.free()

	var bare: Control = chat_script.new(_builder(false))
	ui.add_child(bare)
	bare.call("setup")
	await process_frame
	if bare.has_method("add_starting_message"):
		_check(bare.call("add_starting_message") == true, "no row in the archive: still added (the words are ours)")
		_check((bare.call("list_messages", 0) as Array).size() == 1, "and the All list holds it")

	# The wrap itself: a row too long for the width wraps with the indent;
	# the next break's row does not.
	var font := ThemeDB.fallback_font
	var w := font.get_string_size("Make your way as a Trader", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var wrapped: PackedStringArray = chat_script.call("wrap", "Make your way as a Trader, Hunter\\nNext", font, 12, w + 2.0)
	print("wrapped: %s" % [wrapped])
	_check(wrapped.size() == 3, "one long row wraps into two, the break adds a third (got %d)" % wrapped.size())
	if wrapped.size() == 3:
		_check(wrapped[1].begins_with(" ") and wrapped[1].strip_edges().ends_with("Hunter"), "the wrapped tail is indented")
		_check(wrapped[2] == "Next", "the row after the break is not")
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURES" % _failures)
	quit(1 if _failures > 0 else 0)
