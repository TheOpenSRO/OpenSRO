extends SceneTree

## Round 860: a long text in an edit, as the original draws it (READ,
## CIFEdit's draw c:0x637b70, 0x637d85..0x637de3 and 0x637ef1..0x637f6f; the
## rule in TextLayout.edit_scrolled_left, drawn by CifEdit). A text more than
## `w - 5` wide has its end at `w - 5`; when its start is then left of the
## text rect and the caret within 40 px of the rect's left, it moves right
## until the caret is 40 px in or the start is at the rect's left. Pure checks
## on known widths and caret moves, then CifEdit laid out as the chat line
## (ClientRect 5,4,0,0 in 360x20) with a long line typed, walked with Home /
## End / arrows and deleted back. The font is whatever the headless run gives
## (each check measures with it). No game data.
##   godot4 --headless --path client --script res://scripts/ui/long_text860_test.gd

var _failures := 0
var _reached := 0

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
	_rule()
	_walk()
	await process_frame
	root.size = Vector2i(1280, 720)
	await _chat_edit()
	await _other_edits()
	await _centred_overrun()
	_check(_reached == 3,"every part ran to its end (a script error stops one silently)")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The rule on the chat line's text rect (43,382 355x16: ifchatviewer's
## GDR_CHAT_INPUTBOX less its ClientRect 5,4,0,0).
func _rule() -> void:
	var tr := Rect2(43, 382, 355, 16)
	_check(TextLayout.edit_scrolled_left(43, tr, 349, 349) == 43, "349 wide (under w - 5 = 350): not moved")
	_check(TextLayout.edit_scrolled_left(43, tr, 350, 350) == 43, "exactly w - 5 = 350: not moved (strictly wider, READ 0x637d9c)")
	_check(TextLayout.edit_scrolled_left(43, tr, 351, 351) == 42, "351 wide, caret at the end: end at 43 + 350 = 393, left 42")
	_check(TextLayout.edit_scrolled_left(43, tr, 351, 0) == 43, "351 wide, caret at the start: pulled back the 1 px (min(1, 41))")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 500) == -107, "500 wide, caret at the end: left 393 - 500 = -107")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 200) == -107, "the caret at 200 (x 93, more than 40 in): the end stays at 393")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 191) == -107, "the caret at x 84: still more than 40 in, not moved")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 190) == -107, "the caret at x 83 (exactly 40 in, `<=` READ 0x637f13): moved by min(150, 0) = 0")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 150) == -67, "the caret at 150 (x 43): moved 40 right, the caret 40 in (x 83)")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 0) == 43, "the caret at the start: the text's start at the rect's left (min(150, 190))")
	# The alignment does not matter once the text is long: H2's left
	# (right - w - 2.0) and H1's centre end at w - 5 alike.
	_check(TextLayout.edit_scrolled_left(43 + 355 - 500 - 2, tr, 500, 500) == -107, "H2: the end at w - 5 too")
	_check(TextLayout.edit_scrolled_left(43 + (355 - 500) * 0.5, tr, 500, 500) == -107, "H1: the end at w - 5 too")
	# A short H2 text keeps its own left (right - w - 2.0).
	_check(TextLayout.edit_scrolled_left(43 + 355 - 100 - 2, tr, 100, 50) == 296, "a short H2 text keeps right - w - 2.0")

## The caret walked left from the end of a 500 px text of 10 px characters
## (50 of them), then right: what the text's left and the caret do each step.
func _walk() -> void:
	var tr := Rect2(43, 382, 355, 16)
	var lefts := []
	var carets := []
	for col in range(50, -1, -1):
		var l := TextLayout.edit_scrolled_left(43, tr, 500, col * 10.0)
		lefts.append(l)
		carets.append(l + col * 10.0)
	# Columns 50..31: the end pinned (left -107), the caret walking left
	# from 393 to 203 ... down to 83 at column 19.
	_check(lefts[0] == -107 and carets[0] == 393, "End: left -107, the caret at 393 (w - 5)")
	_check(lefts[31] == -107 and carets[31] == 83, "column 19: the caret reaches 83 (40 in), the text still pinned")
	_check(lefts[32] == -97 and carets[32] == 83, "column 18: the text moves 10 right, the caret stays at 83")
	_check(lefts[46] == 43 and carets[46] == 83, "column 4: the text's start at the rect's left")
	_check(lefts[47] == 43 and carets[47] == 73, "column 3: the caret walks on left, the text stays")
	_check(lefts[50] == 43 and carets[50] == 43, "Home: the start at the left, the caret on it")
	var moved := 0
	for i in range(1, lefts.size()):
		if lefts[i] != lefts[i - 1]:
			moved += 1
			_check(lefts[i] - lefts[i - 1] == 10.0, "each step moves the text one character's width (step %d)" % i)
	_check(moved == 15, "it moved on 15 of the 50 steps left (got %d)" % moved)
	# Back right from Home: the caret walks right, the text is drawn from the
	# rect's left until the caret is more than 40 in and the end is pinned.
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 40) == 43, "Home + 4 (the caret at x 83): the start still at the left")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 50) == 33, "Home + 5: the caret held 40 in, the text moves 10 left (33)")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 190) == -107, "Home + 19: the end back at w - 5, the caret 40 in")
	_check(TextLayout.edit_scrolled_left(43, tr, 500, 200) == -107, "Home + 20: the end stays pinned, the caret walks right")

func _adv(e: LineEdit, s: String) -> float:
	var line := TextLine.new()
	line.add_string(s, e.get_theme_font(&"font"), e.get_theme_font_size(&"font_size"))
	return TextServerManager.get_primary_interface().shaped_text_get_width(line.get_rid())

func _edit(rect: Rect2, client: Rect2i, h: int, v: int) -> CifEdit:
	var e := CifEdit.new()
	e.add_theme_font_size_override(&"font_size", 12)
	root.add_child(e)
	e.lay_out(client, h, v)
	e.position = rect.position
	e.size = rect.size
	return e

## The rule's expected left (the edit's coordinates) for `e` now.
func _want_left(e: CifEdit, unscrolled: float) -> float:
	var s := e.text
	if e.secret:
		s = "*".repeat(s.length())
	var tw := _adv(e, s)
	var span := e.rule_span()
	var l := TextLayout.edit_scrolled_left(unscrolled, Rect2(span.x, 0, span.y, 0), ceilf(tw), _adv(e, s.left(e.caret_column)))
	return l if l == unscrolled else floorf(l)

func _chat_edit() -> void:
	var e := _edit(Rect2(38, 378, 360, 20), Rect2i(5, 4, 0, 0), 0, 0)
	await process_frame
	var ink: Control = null
	for ch in e.get_children(true):
		if ch.name == "CifEditInk":
			ink = ch
	_check(ink != null and ink.name == "CifEditInk" and ink.clip_contents and e.get_child_count() == 0,
		"the edit draws on an internal ink clipped to its rect (the original's viewport, READ 0x6531a0)")
	_check(e.self_modulate.a == 0.0, "LineEdit's own drawing (its scroll) is hidden")
	_check(e.rule_span() == Vector2(5, 355), "the rule's span is the text rect: 5 in, 355 wide")
	# A line longer than the box, typed to the end.
	var long := "The quick brown fox jumps over the lazy dog, and then it runs all the way back home again."
	e.text = long
	e.caret_column = long.length()
	var tw := _adv(e, long)
	_check(ceilf(tw) > 350.0, "the test line is longer than w - 5 (%.1f)" % tw)
	var left := e.text_left()
	_check(left == floorf(5 + 350 - ceilf(tw)), "End: the text's end at 5 + 355 - 5 = 355 (left %.1f, want %.1f)" % [left, floorf(355 - ceilf(tw))])
	var c := e.caret_rect()
	_check(absf(c.position.x - (5 + 350)) <= 1.0, "End: the caret at w - 5 (x %.1f, want 355)" % c.position.x)
	_check(c.position.y == 4 and c.size == Vector2(2, e.font_height() + 2), "the caret's top and quad unchanged (%s)" % [c])
	# Walk left a character at a time, by the edit's own keys.
	var moved := 0
	var last := left
	var steps := 0
	while e.caret_column > 0:
		_key(e, KEY_LEFT)
		steps += 1
		var l := e.text_left()
		_check(l == _want_left(e, 5), "Left to column %d: left %.1f (rule %.1f)" % [e.caret_column, l, _want_left(e, 5)])
		var cx := e.caret_rect().position.x
		_check(cx >= 5.0 - 0.01 and cx <= 5 + 350 + 0.01, "the caret stays inside the text rect (x %.1f)" % cx)
		if l != last:
			moved += 1
			_check(l > last, "the text only moves right while the caret walks left")
			_check(l == 5.0 or absf(cx - 45.0) <= 1.0, "when it moves, the caret is 40 px in or the start at the left (x %.1f, left %.1f)" % [cx, l])
		last = l
	_check(moved > 0 and e.text_left() == 5.0 and e.caret_rect().position.x == 5.0, "at the start: the text's start and the caret at 5 (moved on %d of %d steps)" % [moved, steps])
	_key(e, KEY_END)
	_check(e.text_left() == left, "End: pinned again at once (%.1f)" % e.text_left())
	_key(e, KEY_HOME)
	_check(e.text_left() == 5.0 and e.caret_rect().position.x == 5.0, "Home: the start at the rect's left")
	for i in 3:
		_key(e, KEY_RIGHT)
	_check(e.text_left() == 5.0, "Home + 3 rights: still from the left (the caret within 40)")
	# Deleting back from the end: the end stays at w - 5 until the text fits.
	_key(e, KEY_END)
	var fits := false
	while e.text != "":
		_key(e, KEY_BACKSPACE)
		var s := e.text
		var w := ceilf(_adv(e, s))
		if w > 350.0:
			_check(e.text_left() == floorf(355 - w), "Backspace (%d left): the end stays at w - 5 (left %.1f)" % [s.length(), e.text_left()])
		elif not fits:
			fits = true
			_check(e.text_left() == 5.0, "Backspace: once the text fits it is drawn from the left again (%d chars)" % s.length())
	_check(e.caret_rect().position == Vector2(5, 4), "empty again: the caret at (5, 4)")
	# Focus in and out change nothing (the rule keeps no state).
	e.text = long
	e.caret_column = 10
	var l0 := e.text_left()
	e.grab_focus()
	await process_frame
	var l1 := e.text_left()
	e.release_focus()
	await process_frame
	_check(l0 == l1 and e.text_left() == l0 and l0 == _want_left(e, 5), "focus in and out: the same place (%.1f)" % l0)
	# The ink is redrawn with the edit (the same frame).
	e.caret_column = long.length()
	await process_frame
	_check(not ink.is_queued_for_deletion() and ink.size == e.size, "the ink keeps the edit's size (%s)" % [ink.size])
	e.queue_free()
	_reached += 1

func _key(e: CifEdit, code: Key) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.pressed = true
	if not e.call("_key", k):
		if code == KEY_BACKSPACE and e.caret_column > 0:
			var at := e.caret_column
			e.text = e.text.substr(0, at - 1) + e.text.substr(at)
			e.caret_column = at - 1

func _other_edits() -> void:
	# A password: the rule measures the mask ('*' per character, READ
	# 0x636330), not the typed text.
	var p := _edit(Rect2(0, 0, 100, 20), Rect2i(), 1, 1)
	p.secret = true
	p.secret_character = "*"
	await process_frame
	p.text = "x".repeat(40)
	p.caret_column = 40
	var mw := ceilf(_adv(p, "*".repeat(40)))
	_check(mw > 95.0, "forty '*' are longer than 95 (%.1f)" % mw)
	_check(p.text_left() == floorf(95 - mw), "the masked text's end at 95 (left %.1f)" % p.text_left())
	p.queue_free()
	# HAlign 2 (an amount): short, right - w - 2; long, the end at w - 5.
	var r := _edit(Rect2(0, 0, 79, 14), Rect2i(), 2, 0)
	await process_frame
	r.text = "1234"
	r.caret_column = 4
	_check(absf(r.text_left() + _adv(r, "1234") - 77.0) < 1.0, "a short H2 amount ends at right - 2 (end %.1f)" % (r.text_left() + _adv(r, "1234")))
	r.text = "1234567890123456789"
	r.caret_column = r.text.length()
	var rw := ceilf(_adv(r, r.text))
	_check(rw > 74.0 and r.text_left() == floorf(74 - rw), "a long H2 amount ends at w - 5 = 74 (left %.1f)" % r.text_left())
	r.queue_free()
	# A placeholder longer than the box starts at the left (the rule with
	# the caret at its start).
	var ph := _edit(Rect2(0, 0, 60, 20), Rect2i(), 0, 1)
	ph.placeholder_text = "a long placeholder text"
	await process_frame
	_check(ph.text_left() == 0.0, "a long placeholder starts at the left (%.1f)" % ph.text_left())
	ph.queue_free()
	# The ink is the layout's rect (the original's viewport), not the taller
	# size Godot's minimum holds the edit at: party match's name edit, 81x11.
	var pm := CifEdit.new()
	pm.add_theme_font_size_override(&"font_size", 12)
	pm.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(103, 79, 81, 11))
	root.add_child(pm)
	pm.lay_out(Rect2i(), 2, 0)
	pm.position = Vector2(103, 79)
	pm.size = Vector2(81, 11)
	await process_frame
	var pink: Control = null
	for ch in pm.get_children(true):
		if ch.name == "CifEditInk":
			pink = ch
	_check(pink != null and pink.size == Vector2(81, 11) and pink.clip_contents,
		"an 11 px edit held %s tall by Godot: its ink is the authored 81x11 (%s)" % [pm.size.y, pink.size if pink != null else Vector2.ZERO])
	pm.queue_free()
	_reached += 1

## A centred .2dt text wider than its control (TwoDtBuilder's label, grown
## both ways) starts at floor(left + (w - text w) * 0.5), as CNIFStatic draws
## it (READ 0x4820b0, 0x482020's `_ftol` of a positive screen x): an odd
## overrun puts the half pixel on the left.
func _centred_overrun() -> void:
	var host := Control.new()
	host.position = Vector2(100, 100)
	host.size = Vector2(88, 24)
	root.add_child(host)
	var odd := 0
	for t in ["Silk Charge History!", "Silk Charge History!!", "Silk Charge History!!!", "Short"]:
		var label := Label.new()
		label.add_theme_font_size_override(&"font_size", 12)
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.grow_horizontal = Control.GROW_DIRECTION_BOTH
		label.text = t
		host.add_child(label)
		TwoDtBuilder._hold_centred_overrun(label)
		await process_frame
		var minw := label.get_combined_minimum_size().x
		var over := minw - 88.0
		if over > 0.0 and fmod(over, 2.0) != 0.0:
			odd += 1
		var want := floorf(-over / 2.0) if over > 0.0 else 0.0
		_check(label.position.x == want and label.size.x == maxf(minw, 88.0),
			"'%s' (overrun %.1f): the label at %.1f, want floor(-overrun / 2) = %.1f" % [t, over, label.position.x, want])
		label.queue_free()
	_check(odd > 0, "an odd or fractional overrun was among them (%d)" % odd)
	host.queue_free()
	_reached += 1
