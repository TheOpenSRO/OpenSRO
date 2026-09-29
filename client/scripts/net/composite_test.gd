extends SceneTree

## CompositeNet (round 632 review): the state and use-result codecs, and the
## buff board's item-grant icon (kind 5): added, left-click routed, removed.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _state_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2 + 28 + 8)
	out.encode_u16(0, 1)
	out.encode_s64(2, 23937)
	out.encode_s64(10, 23944)
	out.encode_s32(18, 1)
	out.encode_s32(22, 1)
	out.encode_s32(26, 3599)
	out.encode_s32(30, 5)
	out.encode_s32(34, 3599)
	return out

func _init() -> void:
	var st := CompositeNet.decode_state(_state_bytes())
	_check(st.grants.size() == 1, "one grant decodes")
	var g: CompositeNet.Grant = st.grants[0]
	_check(g.item_id == 23937 and g.scroll_id == 23944, "item and scroll ids")
	_check(g.remaining == 1 and g.maximum == 1 and g.seconds_left == 3599, "uses and seconds")
	_check(st.bonus_seconds == 5 and st.bonus_seconds_left == 3599, "berserk bonus")

	var res := PackedByteArray()
	res.resize(2)
	res.encode_u16(0, 0)
	var tail := PackedByteArray()
	tail.resize(17)
	tail.encode_s64(0, 23937)
	tail.encode_s32(8, 0)
	tail.encode_s32(12, 100)
	tail[16] = 0
	res.append_array(tail)
	var u := CompositeNet.decode_use_result(res)
	_check(u.error == "" and u.item_id == 23937 and u.berserk_gauge == 100 and not u.berserk_active, "use result decodes")

	var enc := CompositeNet.encode_use("Aria", 23937)
	_check(enc.decode_u16(0) == 4 and enc.decode_s64(6) == 23937, "use request encodes name and item")

	var board := HudBuffBoard.new(null, SkillBuffCatalog.new(null))
	root.add_child(board)
	var b := board.add_item_state(-23937, "icon\\item\\etc\\etc_second_hwan_scroll_01.ddj", 3600000, 3599000, "Energy of life")
	_check(b != null and b.kind == 5, "an item grant is a kind-5 icon")
	_check(board.item_state_tokens() == [-23937], "listed as an item grant")
	_check(absf(b.gauge_value() - 3599.0 / 3600.0) < 0.001, "gauge = remaining / Param1 seconds")
	_check(board.right_click_action(-23937) == HudBuffBoard.ACTION_NONE, "a right-click on it sends no cancel")
	var clicked := [0]
	board.item_state_clicked.connect(func(t: int) -> void: clicked[0] = t)
	board.on_slot_left_click(-23937)
	_check(clicked[0] == -23937, "a left-click is routed to item_state_clicked")
	board.remove_item_state(-23937)
	_check(board.item_state_tokens().is_empty(), "removed")
	board.queue_free()

	var endb := PackedByteArray()
	endb.resize(16)
	endb.encode_s64(0, 23937)
	endb.encode_s64(8, 23944)
	var ended := CompositeNet.decode_end(endb)
	_check(ended.size() == 2 and int(ended[0]) == 23937 and int(ended[1]) == 23944, "an end push decodes")
	_check(CompositeNet.decode_end(PackedByteArray()).is_empty(), "a short end push decodes to nothing")

	var win := CompositeItemWindow.new()
	root.add_child(win)
	win.show_entries([[23937, "Hwan regeneration fill", 1]])
	var cancel := win.get_node_or_null("CompositeCancel") as Button
	_check(cancel != null, "a Cancel button follows the item buttons (count + 1)")
	_check(cancel != null and cancel.position == CompositeItemWindow.BUTTON_ORIGIN + Vector2(0, CompositeItemWindow.BUTTON_STEP),
		"Cancel sits one step below the last item button")
	var fill := win.get_node_or_null("CompositeButton0") as Button
	_check(fill != null and fill.text == "Hwan regeneration fill(1)", "the item button reads name(count)")
	win.show()
	if cancel != null:
		cancel.pressed.emit()
	_check(not win.visible, "Cancel closes the window")
	win.queue_free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		quit(1)
