extends SceneTree

## Round 859: where the original puts text and the caret (TextLayout, READ
## c:0x652800 / 0x64d9b0 / 0x637b70 / 0x47b5b0), and that CifEdit draws them
## there: the chat line's caret 5 px in (ClientRect 5,4,0,0), a top-aligned
## edit's text at its top, HAlign 1 / 2 carets, the caret's height, the long
## text rule. Pure checks on known strings and rects; the font is whatever the
## headless run gives (each check measures with that font). No game data.
##   godot4 --headless --path client --script res://scripts/ui/text_layout859_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	_formulas()
	await process_frame
	root.size = Vector2i(1280, 720)
	await _edits()
	await _chat_line()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _formulas() -> void:
	# The text rect: ifchatviewer's input, 38,378 360x20 less 5,4,0,0.
	var chat := Rect2(38, 378, 360, 20)
	_check(TextLayout.text_rect(chat, Rect2i(5, 4, 0, 0)) == Rect2(43, 382, 355, 16), "the chat line's text rect is 43,382 355x16")
	_check(TextLayout.text_rect(Rect2(20, 102, 42, 24), Rect2i(7, 5, 7, 5)) == Rect2(27, 107, 28, 14), "ClientRect 7,5,7,5 takes 14 off each way")
	# A static (0x64d9b0): 60 x 13 text in 0,0 100x20.
	var r := Rect2(0, 0, 100, 20)
	var t := Vector2(60, 13)
	_check(TextLayout.static_origin(r, Rect2i(), 0, 0, t) == Vector2(0, 0), "static H0 V0 at the top-left")
	_check(TextLayout.static_origin(r, Rect2i(), 1, 1, t) == Vector2(20, 3.5), "static H1 V1 centred: (20, 3.5)")
	_check(TextLayout.static_origin(r, Rect2i(), 2, 2, t) == Vector2(40, 7), "static H2 V2: right - w, bottom - h, no inset")
	# An edit (0x637b70): HAlign 2 stops 2.0 short; the rest as the static.
	_check(TextLayout.edit_origin(r, Rect2i(), 2, 0, t, 13.0) == Vector2(38, 0), "edit H2: right - w - 2.0")
	_check(TextLayout.edit_origin(chat, Rect2i(5, 4, 0, 0), 0, 0, t, 13.0) == Vector2(43, 382), "the chat line's text at (43, 382)")
	# Empty edit: H1 is the rect's centre; V1 centres tmHeight + 2.
	_check(TextLayout.edit_origin(r, Rect2i(), 1, 1, Vector2.ZERO, 13.0) == Vector2(50, 2), "an empty H1 V1 edit: x at the centre, y (20 - 13 - 2) >> 1 = 2")
	_check(TextLayout.edit_origin(r, Rect2i(), 0, 2, Vector2.ZERO, 13.0) == Vector2(0, 7), "an empty V2 edit: bottom - tmHeight")
	# The caret: x + advance, 2 wide, tmHeight + 2 tall.
	_check(TextLayout.caret_rect(Vector2(43, 382), 31, 13.0) == Rect2(74, 382, 2, 15), "caret after 31 px of text: 74,382 2x15")
	# The long-text rule: end at right - 5; caret near the left pulls it back.
	var tr := Rect2(0, 0, 100, 16)
	_check(TextLayout.edit_scrolled_left(0, tr, 90, 90) == 0, "a 90-wide text in 100: not moved (95 > 90)")
	_check(TextLayout.edit_scrolled_left(0, tr, 150, 150) == -55, "a 150-wide text: its end at 95 (left -55)")
	_check(TextLayout.edit_scrolled_left(0, tr, 150, 10) == 0, "the caret 10 px in: pulled back to the rect's left (min(55, 85))")
	_check(TextLayout.edit_scrolled_left(0, tr, 150, 80) == -40, "the caret at -55 + 80 = 25: moved right 15 so it is 40 in")
	# LineEdit margins for the original's VAlign.
	var m := TextLayout.line_edit_margins(20, Rect2i(5, 4, 0, 0), 0, 0, 13)
	_check(m == PackedFloat32Array([5, 4, 0, 3]), "chat line margins 5,4,0,3: text at the top (got %s)" % [m])
	m = TextLayout.line_edit_margins(24, Rect2i(7, 5, 7, 5), 2, 0, 13)
	_check(m == PackedFloat32Array([7, 5, 9, 6]), "H2 V0 margins 7,5,9,6 (got %s)" % [m])
	m = TextLayout.line_edit_margins(20, Rect2i(), 0, 2, 13)
	_check(m == PackedFloat32Array([0, 7, 0, 0]), "V2 margins put the text at the bottom (got %s)" % [m])
	m = TextLayout.line_edit_margins(20, Rect2i(), 1, 1, 13)
	_check(m == PackedFloat32Array([0, 0, 0, 0]), "V1 keeps LineEdit's centring (got %s)" % [m])

func _edit(rect: Rect2, client: Rect2i, h: int, v: int) -> CifEdit:
	var e := CifEdit.new()
	# FontIndex 0's 12 px (UiBuilder.FONT_SIZES), not the headless theme's 16.
	e.add_theme_font_size_override(&"font_size", 12)
	root.add_child(e)
	# Laid out before it is sized: Godot's default LineEdit box (4 px each
	# way) would otherwise hold it taller than asked.
	e.lay_out(client, h, v)
	e.position = rect.position
	e.size = rect.size
	return e

func _adv(e: CifEdit, s: String) -> float:
	var line := TextLine.new()
	line.add_string(s, e.get_theme_font(&"font"), e.get_theme_font_size(&"font_size"))
	# Unrounded: the headless face has fractional advances (the client's has
	# subpixel positioning off, whole pixels).
	return TextServerManager.get_primary_interface().shaped_text_get_width(line.get_rid())

func _edits() -> void:
	# The chat line's layout on a plain edit.
	var e := _edit(Rect2(38, 378, 360, 20), Rect2i(5, 4, 0, 0), 0, 0)
	await process_frame
	var fh := e.font_height()
	var th := ceilf(fh)
	var sb := e.get_theme_stylebox(&"normal")
	_check(sb.content_margin_left == 5 and sb.content_margin_top == 4 and sb.content_margin_right == 0
		and is_equal_approx(sb.content_margin_bottom, maxf(0.0, 20 - 4 - th)),
		"VAlign 0: the room under the text is margin (got %s, size %s, text h %s)" % [[sb.content_margin_left, sb.content_margin_top, sb.content_margin_right, sb.content_margin_bottom], e.size, th])
	var c := e.caret_rect()
	_check(c.position == Vector2(5, 4), "the empty chat caret at (5, 4) of the box (got %s)" % [c.position])
	_check(c.size == Vector2(2, fh + 2), "the caret 2 x tmHeight + 2 (got %s)" % [c.size])
	e.text = "Hello there"
	e.caret_column = e.text.length()
	var adv := _adv(e, "Hello there")
	c = e.caret_rect()
	_check(absf(c.position.x - (5 + adv)) < 1.0 and c.position.y == 4, "after the text: x = 5 + its width %.1f (got %s)" % [adv, c.position])
	e.caret_column = 0
	_check(e.caret_rect().position == Vector2(5, 4), "Home: back at the text's left (got %s)" % [e.caret_rect().position])
	e.caret_column = 5
	var a5 := _adv(e, "Hello")
	_check(absf(e.caret_rect().position.x - (5 + a5)) <= 1.0, "after 'Hello': x = 5 + 'Hello' (%.1f, got %.1f)" % [5 + a5, e.caret_rect().position.x])
	# A resize keeps the top: 30 tall now.
	e.size = Vector2(360, 30)
	await process_frame
	_check(e.caret_rect().position.y == 4 and is_equal_approx(e.get_theme_stylebox(&"normal").content_margin_bottom, 30 - 4 - th),
		"30 tall: the text stays at the top (y %s)" % [e.caret_rect().position.y])
	e.queue_free()
	# HAlign 2 (the amounts): an empty caret at right - 2; text ends there.
	var r := _edit(Rect2(0, 0, 79, 14), Rect2i(), 2, 0)
	await process_frame
	_check(r.caret_rect().position.x == 79 - 2, "an empty H2 edit's caret at 77 (got %s)" % [r.caret_rect().position.x])
	r.text = "1234"
	r.caret_column = 4
	# LineEdit: x = int(79 - ceil(2 + w)), so the end is within a pixel of 77.
	_check(absf(r.caret_rect().position.x - 77.0) < 1.0, "after '1234' the caret is at right - 2 (got %s)" % [r.caret_rect().position.x])
	r.queue_free()
	# HAlign 1 VAlign 1 (the login slots): empty caret centred both ways.
	var l := _edit(Rect2(0, 0, 135, 20), Rect2i(), 1, 1)
	await process_frame
	var lc := l.caret_rect()
	_check(lc.position == Vector2(67, floorf((20 - l.font_height() - 2) / 2.0)), "an empty H1 V1 edit's caret at (67, (20 - tmHeight - 2) >> 1) (got %s, tmHeight %s, size %s)" % [lc.position, l.font_height(), l.size])
	l.queue_free()
	# The draw: hidden until the blink's first flip, then shown with focus.
	var d := _edit(Rect2(0, 0, 100, 20), Rect2i(), 0, 0)
	d.grab_focus()
	if d.has_method("edit"):
		d.call("edit")
	await process_frame
	_check(d.get("_blink_on") == false, "the caret starts hidden when the edit takes the keyboard (READ 0x637b50)")
	await create_timer(0.25).timeout
	_check(d.get("_blink_on") == true and d.caret_shown(), "200 ms later it shows")
	d.release_focus()
	await process_frame
	_check(not d.caret_shown(), "no caret without the keyboard")
	d.queue_free()

## HudChat's line over GDR_CHAT_INPUTBOX takes the box's layout (the user's
## report: the caret was 5 px left of the original's).
func _chat_line() -> void:
	var layout := "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" \
		+ "\tGDR_CHAT_INPUTBOX:CIFEInputChatBox\n\t{\n\t\tClientRect=RECT,\"5,4,0,0\"\n\t\tDDJ=STRING,\"\"\n" \
		+ "\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"0\"\n\t\tID=INTEGER,\"11\"\n" \
		+ "\t\tRect=RECT,\"38,378,360,20\"\n\t\tText=STRING,\"\"\n\t\tVAlign=INTEGER,\"0\"\n\t}\n}\n"
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	var key := "%s%s%s" % ["resinfo\\ifchatviewer.txt", char(1), char(2).join(PackedStringArray(["UI_UPDATE_2009_FIRST"]))]
	cache[key] = UiLayoutParser.parse(layout, true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(layout)
	var ui := Control.new()
	ui.size = Vector2(1024, 768)
	root.add_child(ui)
	var chat: Control = (load("res://scripts/ui/hud/hud_chat.gd") as GDScript).new(builder)
	ui.add_child(chat)
	chat.call("setup")
	for i in 4:
		await process_frame
	var box := chat.find_child("GDR_CHAT_INPUTBOX", true, false) as CifEdit
	var input := chat.find_child("Input", true, false) as CifEdit
	_check(box != null and input != null, "the chat line is a CifEdit over the authored CifEdit")
	if box == null or input == null:
		return
	_check(input.is_laid_out() and input.layout_client() == Rect2i(5, 4, 0, 0) and input.layout_valign() == 0,
		"the line has the box's ClientRect 5,4,0,0 and VAlign 0")
	var c := input.caret_rect()
	_check(c.position == Vector2(5, 4), "the empty line's caret 5 px in and 4 down, as the original's text rect (got %s)" % [c.position])
	input.text = "abc"
	input.caret_column = 3
	_check(absf(input.caret_rect().position.x - (5 + _adv(input, "abc"))) < 1.0, "after 'abc' the caret is 5 + its width (got %s)" % [input.caret_rect().position.x])
	ui.queue_free()
