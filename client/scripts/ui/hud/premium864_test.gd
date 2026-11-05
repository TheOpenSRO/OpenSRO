extends SceneTree

## Round 864: the premium's icons. One kind-5 icon per composite item (READ
## c:0x8992b0: the board entry is keyed by the composite), its tooltip the
## composite's name, a blank line, the remaining time and one "<fill>: <n>Unit"
## line per fill (c:0x800a10 kind 5; MEASURED); the Gold Time icon with its
## gauge (c:0x805a40 case 3); the composite window's own refusals (c:0x7afd05..
## 0x7b035d) keep it open and send nothing.

const ErrorText = preload("res://scripts/net/error_text.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var words := {"UIIT_STT_REMAIN_TIME": "Remaining time", "PARAM_DAY": "Day", "PARAM_HOUR": "Hour",
		"PARAM_MINUTE": "Minute", "PARAM_SECOND": "Second"}
	var board := HudBuffBoard.new(null, SkillBuffCatalog.new(null))
	board.ui_text = func(k: String) -> String: return String(words.get(k, k))
	root.add_child(board)
	var lines := PackedStringArray(["Instant Return Scroll: 3Unit", "100% resurrection scroll: 1Unit", "Reverse Return Scroll: 3Unit"])
	var total := 2419200 * 1000
	var b := board.add_item_state(-9277, "icon\\item\\etc\\mall_premium_goldtime.ddj", total, total - 60000, "Premium Gold Time (4 weeks)", lines)
	_check(b != null and b.kind == 5 and board.item_state_tokens() == [-9277], "one kind-5 icon for the composite")
	var want := "Premium Gold Time (4 weeks)\n\nRemaining time: 27Day 23Hour 59Minute\nInstant Return Scroll: 3Unit\n100% resurrection scroll: 1Unit\nReverse Return Scroll: 3Unit"
	_check(board.tooltip_for(-9277) == want, "the tooltip as measured (got %s)" % board.tooltip_for(-9277).c_escape())
	# Refreshed in place: a state after a use keeps one icon and its place.
	lines[0] = "Instant Return Scroll: 2Unit"
	board.add_item_state(-9277, "icon\\item\\etc\\mall_premium_goldtime.ddj", total, total - 120000, "Premium Gold Time (4 weeks)", lines)
	_check(board.item_state_tokens() == [-9277] and board.tooltip_for(-9277).contains("Instant Return Scroll: 2Unit"),
		"a refresh updates the one icon")
	# The Gold Time's gauge (case 3: total the ref's Param1, remaining the period left).
	var g := board.add_gold_time(-0x3206, "", "Expert Package Service", total, total)
	_check(g != null and g.slot != null and g.slot.gauge.visible and is_equal_approx(g.gauge_value(), 1.0),
		"the Gold Time icon shows a full gauge")
	_check(board.tooltip_for(-0x3206) == "Expert Package Service", "its tooltip is the caller's lines only")
	# NEGATIVE: no total keeps the round-838 gaugeless entry.
	var g2 := board.add_gold_time(-0x3207, "", "x")
	_check(g2 != null and not g2.slot.gauge.visible, "no total: no gauge")
	board.queue_free()

	# The window's pre-check: a refusal keeps it open and sends nothing.
	var win := CompositeItemWindow.new()
	win.set("_builder", UiBuilder.new(null, null))
	root.add_child(win)
	var sent := []
	var refused := []
	win.use_requested.connect(func(id: int) -> void: sent.append(id))
	win.refused.connect(func(code: int) -> void: refused.append(code))
	win.pre_check = func(id: int) -> int: return 0x1887 if id == 3783 else 0
	win.show_entries([[3769, "Instant Return Scroll", 3], [3783, "100% resurrection scroll", 1], [3795, "Reverse Return Scroll", 0]])
	win.show()
	var res := win.get_node_or_null("CompositeButton1") as BaseButton
	if res != null:
		res.pressed.emit()
	_check(win.visible and sent.is_empty() and refused == [0x1887], "a refused fill: window open, nothing sent, 0x1887")
	var inst := win.get_node_or_null("CompositeButton0") as BaseButton
	if inst != null:
		inst.pressed.emit()
	_check(not win.visible and sent == [3769], "an allowed fill closes the window and goes")
	var rev := win.get_node_or_null("CompositeButton2") as BaseButton
	_check(rev != null and rev.disabled and CompositeItemWindow.button_text(rev) == "Reverse Return Scroll(0)",
		"a fill at 0 is greyed, \"<name>(0)\"")
	win.queue_free()
	_check(ErrorText.SCROLL_UIIT_BY_CODE.get(0x1887, "") == "UIIT_MSG_STRGERR_ONLY_THE_DEAD_CAN_USE_RESURRECT_SCROLL",
		"0x1887's text key (c:0x7b9261)")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		quit(1)
