extends SceneTree

## Round 848 (lane T): HelpTips -- every tooltip in the original's help
## bubble, at once on hover, placed by 0x776c00 -- and no native context
## menu on a text input; OriginalScroll -- the original's scroll bars on a
## natively scrolling control.
##   godot4 --headless --path client --script res://scripts/ui/help_tips_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

class TipByOverride extends Control:
	var calls := 0
	func _get_tooltip(_at: Vector2) -> String:
		calls += 1
		return "from _get_tooltip"

func _initialize() -> void:
	_check(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5)) >= 1e5,
		"Godot's own tooltip popup is held off (gui/timers/tooltip_delay_sec)")
	HelpTips.archive_fallback = false
	HelpTips.hover_probe = func() -> Control: return _pick(root)
	HelpTips.mouse_probe = func() -> Vector2: return _at
	var router: HelpTips = root.get_node_or_null("NativeGuiGuard") as HelpTips
	if router == null:
		router = HelpTips.new()
		router.name = "HelpTipsUnderTest"
		root.add_child(router)
	await process_frame
	_check(HelpTips.instance() != null, "the router is running")
	await _hover_tests(router)
	await _input_tests()
	await _scroll_tests()
	HelpTips.hover_probe = Callable()
	HelpTips.mouse_probe = Callable()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

## The control under `to` (topmost first, Godot's own pick for a mouse
## that stops or passes), since a headless run has no mouse to hover with.
var _at := Vector2(-1, -1)
func _pick(n: Node) -> Control:
	for i in range(n.get_child_count() - 1, -1, -1):
		var hit := _pick(n.get_child(i))
		if hit != null:
			return hit
	if n is Control:
		var c := n as Control
		if c.is_visible_in_tree() and c.mouse_filter != Control.MOUSE_FILTER_IGNORE and c.get_global_rect().has_point(_at):
			return c
	return null

func _move(to: Vector2) -> void:
	_at = to
	await process_frame
	await process_frame

func _texts(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for r in rows:
		out.append(String((r as Dictionary)["text"]))
	return out

func _hover_tests(router: HelpTips) -> void:
	var holder := Control.new()
	holder.size = Vector2(1000, 700)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(holder)
	var btn := Button.new()
	btn.position = Vector2(100, 50)
	btn.size = Vector2(40, 20)
	btn.tooltip_text = "Hello\nWorld"
	holder.add_child(btn)
	var plain := Control.new()
	plain.position = Vector2(300, 300)
	plain.size = Vector2(40, 40)
	plain.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.add_child(plain)
	await _move(Vector2(-50, -50))
	await _move(Vector2(110, 60))
	_check(router.owner_shown() == btn, "hovering a control with tooltip_text shows its help at once (READ 0xb9dbb0: no timer)")
	_check(_texts(router.shown_lines()) == PackedStringArray(["Hello", "World"]), "one white row a line (got %s)" % [_texts(router.shown_lines())])
	var rows := router.shown_lines()
	_check(rows.size() == 2 and (rows[0] as Dictionary)["color"] == ItemTooltipLines.WHITE and not bool((rows[0] as Dictionary)["bold"]),
		"the help is white, the normal face (0x7769a0: 0xffffffff, font 1)")
	var b := router.bubble()
	_check(b != null and b.get_parent() is CanvasLayer and (b.get_parent() as CanvasLayer).layer == HelpTips.LAYER,
		"the bubble is ItemTooltipBubble on its own top layer")
	if b != null:
		_check(b.position == ItemTooltipBubble.place(Rect2(100, 50, 40, 20), b.size, b.get_viewport_rect()),
			"placed by 0x776c00 from the control's rect (got %s)" % b.position)
		# (A headless root is 64 x 64, so the shown box flips; on a 1280 x
		# 720 screen it sits right of the control, top aligned.)
		_check(ItemTooltipBubble.place(Rect2(100, 50, 40, 20), b.size, Rect2(0, 0, 1280, 720)) == Vector2(140, 50),
			"on a 1280 x 720 screen: right of the control, top aligned")
		_check(b.size.y == 2 * 18 + 16, "two lines, 18 px each, the 8-px frame outside (got %s)" % b.size.y)
	btn.tooltip_text = "Changed"
	await process_frame
	await process_frame
	_check(_texts(router.shown_lines()) == PackedStringArray(["Changed"]), "new text on the hovered control shows at once (0x653dc0)")
	if b != null:
		_check(b.size.y == 14 + 16, "one line is 14 px (got %s)" % b.size.y)
	await _move(Vector2(310, 310))
	_check(router.owner_shown() == null and (b == null or not b.visible), "a control without help hides it")
	# _get_tooltip overrides (the buff bar, the target's buffs).
	var ov := TipByOverride.new()
	ov.position = Vector2(500, 100)
	ov.size = Vector2(20, 20)
	holder.add_child(ov)
	await _move(Vector2(505, 105))
	_check(router.owner_shown() == ov and _texts(router.shown_lines()) == PackedStringArray(["from _get_tooltip"]),
		"a _get_tooltip override shows in the bubble")
	# Godot's walk: a PASS child shows its parent's help; a STOP child ends it.
	var parent := Control.new()
	parent.position = Vector2(600, 100)
	parent.size = Vector2(60, 60)
	parent.tooltip_text = "parent help"
	holder.add_child(parent)
	var pass_child := Control.new()
	pass_child.size = Vector2(20, 20)
	pass_child.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(pass_child)
	var stop_child := Control.new()
	stop_child.position = Vector2(30, 30)
	stop_child.size = Vector2(20, 20)
	stop_child.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(stop_child)
	await _move(Vector2(605, 105))
	_check(router.owner_shown() == parent, "a PASS child shows its parent's help, anchored on the parent")
	await _move(Vector2(635, 135))
	_check(router.owner_shown() == null, "a STOP child without help ends the walk")
	# HudPanels' own item / skill bubbles are left to it.
	var item := Control.new()
	item.position = Vector2(700, 100)
	item.size = Vector2(20, 20)
	item.tooltip_text = "x"
	item.set_meta(&"item_tip", {})
	holder.add_child(item)
	await _move(Vector2(705, 105))
	_check(router.owner_shown() == null, "a control with HudPanels' item_tip meta is not routed")
	# set_tip: rows, a Callable, a String; the tooltip_text emptied.
	var st := Control.new()
	st.position = Vector2(100, 300)
	st.size = Vector2(30, 30)
	st.tooltip_text = "native"
	holder.add_child(st)
	HelpTips.set_tip(st, [{"text": "Gold row", "color": Color8(255, 216, 0), "bold": true, "icon": false}])
	_check(st.tooltip_text == "" and HelpTips.tip_text(st) == "Gold row", "set_tip takes rows and empties tooltip_text")
	await _move(Vector2(110, 310))
	_check(_texts(router.shown_lines()) == PackedStringArray(["Gold row"]) and bool((router.shown_lines()[0] as Dictionary)["bold"]),
		"set_tip's rows are drawn as given")
	var n := [0]
	HelpTips.set_tip(st, func() -> String:
		n[0] += 1
		return "call %d" % n[0])
	await process_frame
	_check(_texts(router.shown_lines()).size() == 1 and _texts(router.shown_lines())[0].begins_with("call "),
		"a Callable is read at hover time and re-shown while hovered")
	HelpTips.set_tip(st, "")
	await process_frame
	await process_frame
	_check(router.owner_shown() == null, "an empty set_tip clears it")
	# Long help wraps at the 200-px text box (0x54(200, 1)).
	var long := Control.new()
	long.position = Vector2(100, 400)
	long.size = Vector2(30, 30)
	long.tooltip_text = "word ".repeat(60).strip_edges()
	holder.add_child(long)
	await _move(Vector2(110, 410))
	_check(router.shown_lines().size() > 1, "a long help wraps at 200 px (%d rows)" % router.shown_lines().size())
	if b != null:
		_check(b.size.x <= 200 + 16 + 1, "no row wider than the 200-px box (width %s)" % b.size.x)
	# The cursor inside the bubble hides it (0x776bb0), and it stays hidden on
	# the same control.
	var edge := Control.new()
	edge.position = Vector2(holder.get_viewport_rect().size.x - 30, 200)
	edge.size = Vector2(30, 30)
	edge.tooltip_text = "a help wide enough to flip left of the control"
	edge.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.add_child(edge)
	await _move(edge.position + Vector2(5, 5))
	_check(b != null and b.visible and b.position.x + b.size.x <= edge.position.x, "at the right edge it flips to the left")
	# The cursor inside the bubble's window hides it (0x776bb0), and it
	# stays hidden while the same control is hovered.
	if b != null and b.visible:
		HelpTips.hover_probe = func() -> Control: return edge
		await _move(b.position + b.size / 2.0)
		_check(not b.visible, "the cursor inside the bubble hides it (READ 0x776bb0)")
		await _move(b.position + b.size / 2.0 + Vector2(1, 0))
		_check(not b.visible, "and it stays hidden on the same control")
		HelpTips.hover_probe = func() -> Control: return _pick(root)
		await _move(Vector2(-50, -50))
		await _move(edge.position + Vector2(5, 5))
		_check(b.visible, "hovering the control afresh shows it again")
	holder.queue_free()
	await process_frame

func _input_tests() -> void:
	var le := LineEdit.new()
	var te := TextEdit.new()
	root.add_child(le)
	root.add_child(te)
	await process_frame
	_check(not le.context_menu_enabled and not te.context_menu_enabled,
		"no right-click menu on a LineEdit or TextEdit (READ: the original's EDIT lives off-screen, 0x637a60)")
	_check(not le.middle_mouse_paste_enabled and not te.middle_mouse_paste_enabled,
		"no middle-button paste (the middle button is quick slot 0)")
	le.queue_free()
	te.queue_free()

func _scroll_tests() -> void:
	var holder := Control.new()
	holder.size = Vector2(400, 300)
	root.add_child(holder)
	var rt := RichTextLabel.new()
	rt.size = Vector2(200, 80)
	rt.text = "\n".join(PackedStringArray(range(40).map(func(i): return "line %d" % i)))
	holder.add_child(rt)
	var host := Control.new()
	host.position = Vector2(210, 16)
	host.size = Vector2(16, 48)
	holder.add_child(host)
	var s := OriginalScroll.attach_cif(rt, null, host)
	await process_frame
	await process_frame
	await process_frame
	_check(s != null and s.cif != null and s.cif.get_parent() == host, "the CIF bar sits on the layout's scroll control")
	var bar := rt.get_v_scroll_bar()
	_check(bar.get_combined_minimum_size().x == 0.0 and bar.modulate.a == 0.0 and bar.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"the native bar takes no width, draws nothing, takes no clicks")
	if s != null and s.cif != null:
		_check(is_equal_approx(s.cif.length, 48.0), "the length is the host's rect height (READ 0x65a9c0)")
		_check(s.cif.position == Vector2(0, -16) and s.cif.size == Vector2(16, 16 * 3 + 48), "up arrow 16 above, down arrow below the length")
		_check(s.cif.maximum == s.max_line() and s.max_line() > 0, "the bar's range is the lines the text scrolls (%d)" % s.max_line())
		s.cif._step(3)
		await process_frame
		_check(is_equal_approx(bar.value, 3.0 * s.line_px()), "a step down moves the text one line each (%s)" % bar.value)
		bar.value = bar.max_value
		await process_frame
		_check(s.cif.pos == s.cif.maximum, "the text scrolled to its end puts the thumb at the bottom")
	var te := TextEdit.new()
	te.size = Vector2(100, 40)
	te.text = "\n".join(PackedStringArray(range(30).map(func(i): return "row %d" % i)))
	holder.add_child(te)
	OriginalScroll.hide_bars(te)
	await process_frame
	_check(te.get_v_scroll_bar().get_combined_minimum_size().x == 0.0 and te.get_v_scroll_bar().modulate.a == 0.0,
		"hide_bars: a TextEdit with no bar in the original shows none")
	holder.queue_free()
	await process_frame
