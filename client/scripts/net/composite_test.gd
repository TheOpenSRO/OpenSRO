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

## Round 838: the Gold Time's 0x3206 (the server's own golden bytes,
## mall838_test.go's TestGoldTimeStateBytes), its pause, a reverse return
## fill's option and the fill result's cast time, the BFI1 push, the board's
## Gold Time icon and the use-on kinds.
func _round838() -> void:
	var st := CompositeNet.decode_gold_time(PackedByteArray([3, 1, 0x3e, 0x24, 0, 0, 0x00, 0xea, 0x24, 0x00, 0x30, 0x2a, 0x64, 0x00, 1]))
	_check(st != null and st.sub == 1 and st.ref_id == 9278 and st.period_left == 2419200 and st.prev == 100 \
		and st.today == 10800 and st.paused and not st.ended, "0x3206 state decodes")
	var end := CompositeNet.decode_gold_time(PackedByteArray([3, 1, 0x3e, 0x24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	_check(end != null and end.ended, "0x3206 end decodes")
	var ref := CompositeNet.decode_gold_time(PackedByteArray([3, 2, 0xfb, 0x18, 0x3e, 0x24, 0, 0]))
	_check(ref != null and ref.sub == 2 and ref.code == 0x18fb and ref.ref_id == 9278, "0x3206 refusal decodes")
	_check(CompositeNet.encode_gold_time_pause(true) == PackedByteArray([3, 1]), "0x34BF pause")
	var enc := CompositeNet.encode_use("Aria", 3795, UseItemNet.OPTION_MAP, 12)
	_check(enc.size() == 2 + 4 + 8 + 5 and enc[14] == 7 and enc.decode_u32(15) == 12, "a map fill carries 7 and the point")
	_check(CompositeNet.encode_use("Aria", 3795, 2).size() == 2 + 4 + 8 + 1, "a recall fill carries the option alone")
	var res := PackedByteArray()
	res.resize(2 + 8 + 13)
	res.encode_s64(2, 3769)
	res.encode_s32(10, 2)
	res.encode_u32(19, 1000)
	var u := CompositeNet.decode_use_result(res)
	_check(u.item_id == 3769 and u.remaining == 2 and u.cast_ms == 1000, "a fill result's cast time decodes")
	var bi := CompositeNet.decode_buff_item(CompositeNet.OP_BUFF_ITEM_START, PackedByteArray([0x8f, 0x8a, 0, 0, 0x00, 0xea, 0x24, 0x00, 0x07, 0x0f, 0, 0]))
	_check(int(bi.get("key", 0)) == 35471 and int(bi.get("decoration", 0)) == 3847 and not bool(bi.get("ended", true)), "0x315C decodes")
	var board := HudBuffBoard.new(null, SkillBuffCatalog.new(null))
	root.add_child(board)
	var b := board.add_gold_time(-0x3206, "", "Gold Time\nline")
	_check(b != null and b.kind == HudBuffBoard.KIND_GOLD_TIME and board.tooltip_for(-0x3206).begins_with("Gold Time"), "the Gold Time icon and tooltip")
	_check(board.right_click_action(-0x3206) == HudBuffBoard.ACTION_NONE, "a right-click on it does nothing")
	var clicked := [0]
	board.gold_time_clicked.connect(func(t: int) -> void: clicked[0] = t)
	board.on_slot_left_click(-0x3206)
	_check(clicked[0] == -0x3206, "a left-click asks to pause or resume")
	board.remove_gold_time(-0x3206)
	_check(board.buff(-0x3206) == null, "the end removes it")
	board.queue_free()
	for t in [[[3, 3, 13, 12], true], [[3, 3, 13, 15], true], [[3, 3, 13, 16], true], [[3, 3, 1, 6], true],
			[[3, 3, 13, 14], false], [[3, 3, 1, 4], false], [[3, 1, 14, 1], false]]:
		_check(UseItemNet.is_use_on_item(PackedInt32Array(t[0])) == bool(t[1]), "use-on kind %s -> %s" % [str(t[0]), str(t[1])])

func add_child_to_root(n: Node) -> void:
	root.add_child(n)

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
	# Round 848: the buttons are CIFButtons from the builder (no archive here:
	# no art, the captions as given).
	win.set("_builder", UiBuilder.new(null, null))
	root.add_child(win)
	win.show_entries([[23937, "Hwan regeneration fill", 1]])
	var cancel := win.get_node_or_null("CompositeCancel") as BaseButton
	_check(cancel != null, "a Cancel button follows the item buttons (count + 1)")
	_check(cancel != null and cancel.position == CompositeItemWindow.BUTTON_ORIGIN + Vector2(0, CompositeItemWindow.BUTTON_STEP),
		"Cancel sits one step below the last item button")
	_check(cancel is TextureButton and not (cancel is Button), "round 848: a CIFButton (TextureButton), not a Godot Button")
	_check(cancel != null and cancel.size == CompositeItemWindow.BUTTON_SIZE, "150 x 25 (got %s)" % [cancel.size if cancel != null else null])
	var fill := win.get_node_or_null("CompositeButton0") as BaseButton
	_check(fill != null and CompositeItemWindow.button_text(fill) == "Hwan regeneration fill(1)", "the item button reads name(count)")
	win.show()
	if cancel != null:
		cancel.pressed.emit()
	_check(not win.visible, "Cancel closes the window")
	win.queue_free()
	_round838()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		quit(1)
