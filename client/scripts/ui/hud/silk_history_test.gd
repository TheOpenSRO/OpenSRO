extends SceneTree

## Round 837: the Buying list (SilkHistoryWindow, res_ui\silksearch.2dt)
## against the real Media.pk2, with a stand-in for NetClient
## (docs/protocol/item_mall.md §4g, item_mall_wire.md §5).
##   godot4 --headless --path client --script res://scripts/ui/hud/silk_history_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const ObjectLoader = preload("res://scripts/assets/object_loader.gd")

class FakeNet extends RefCounted:
	signal mall_history(result: Dictionary)
	var sent: Array = []
	func mall_history_request(kind: int, period: int) -> void:
		sent.append([kind, period])

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## 0xB11A's body: kind, period, result, u16 n, n x {u32 amount, u32 date}.
static func _reply(kind: int, period: int, result: int, rows: Array) -> PackedByteArray:
	var b := PackedByteArray([kind, period, result])
	if result != 0:
		return b
	var head := PackedByteArray()
	head.resize(2)
	head.encode_u16(0, rows.size())
	b.append_array(head)
	for r in rows:
		var e := PackedByteArray()
		e.resize(8)
		e.encode_u32(0, int(r[0]) & 0xffffffff)
		e.encode_u32(4, int(r[1]))
		b.append_array(e)
	return b

func _run() -> void:
	# The formats need no archive (READ 0x7ea310).
	var d := SilkHistoryWindow.pack_date(2026, 10, 27, 14, 5, 33)
	_check(SilkHistoryWindow.format_date(d) == "2026/10/27 14:05", "the packed date reads 2026/10/27 14:05 (got %s)" % SilkHistoryWindow.format_date(d))
	_check(d & 0x3f == 26 and (d >> 6) & 0xf == 10 and (d >> 10) & 0x1f == 27 and (d >> 15) & 0x1f == 14 and (d >> 20) & 0x3f == 5,
		"year-2000 bits 0..5, month 6..9, day 10..14, hour 15..19, minute 20..25")
	_check(SilkHistoryWindow.format_no(7) == "007", "No. is %03d")
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var text_entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table: UiTextTable = UiTextTable.parse(pk2.read_file(text_entry)) if text_entry != null else null
	# The headless root is 64 x 64 until its first frame has run.
	await process_frame
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	await process_frame
	var w := SilkHistoryWindow.new(builder)
	var net := FakeNet.new()
	w.net = net
	var opened := [0]
	var closed := [0]
	w.opened.connect(func() -> void: opened[0] += 1)
	w.closed.connect(func() -> void: closed[0] += 1)
	_check(w.open(host), "the window builds from res_ui\\silksearch.2dt")
	await process_frame
	await process_frame
	await process_frame
	_check(w.is_open() and opened[0] == 1, "open shows it and says so (the mall goes busy)")
	_check(w.size == Vector2(462, 527), "462 x 527 (got %s)" % w.size)
	_check(w.position == Vector2(409, 97), "centred, 0x798be0: (view w >> 1) - (w >> 1), (view h >> 1) - (h >> 1) (got %s)" % w.position)
	var title := w.get_node_or_null("TitleBar") as Label
	_check(title != null and title.text == "Buying list", "the caption is UIIT_STT_SILKMALL_BUY_LIST")
	_check(w.slots().size() == 11, "eleven CNIFSilkRecieveListSlot rows (W7; got %d)" % w.slots().size())
	_check(TwoDtBuilder.is_checked(w.control([SilkHistoryWindow.ID_TAB])), "tab 17 checked")
	var combo := w.control([SilkHistoryWindow.ID_COMBO]).get_node_or_null("Combo") as OptionButton
	var items: Array = []
	if combo != null:
		for i in combo.item_count:
			items.append(combo.get_item_text(i))
	_check(items == ["1 day", "7 days", "1 month", "3 months"] and combo.selected == 0,
		"the combo: 1 day, 7 days, 1 month, 3 months, on 1 day (got %s)" % [items])
	_check(w.note_text().begins_with("You can check your Silk charge history"),
		"400 carries UIIT_STT_SILK_INQUIRY_MONTH_SILK, sml2 stripped (got '%s')" % w.note_text())
	_check(w.total_text() == "0Silk" and w.status_text() == "", "reset: total '0Silk', no status (got '%s' / '%s')" % [w.total_text(), w.status_text()])
	_check(TwoDtBuilder.text_of(w.control([SilkHistoryWindow.ID_INQUIRY])) == "Silk Charge History", "button 12's caption")
	# Inquiry with 1 month.
	w.select_period(2)
	(w.control([SilkHistoryWindow.ID_INQUIRY]) as BaseButton).pressed.emit()
	_check(net.sent == [[1, 3]], "Inquiry sends 0x711a {1, index + 1} (got %s)" % [net.sent])
	_check(w.pending and w.status_text() == "Inquiry is in process. Please wait.", "pending, and the wait line")
	# Fifteen rows.
	var rows: Array = []
	var want_total := 0
	for i in 15:
		var amount := 100 * (i + 1)
		want_total += amount
		rows.append([amount, SilkHistoryWindow.pack_date(2026, 9, i + 1, i, 2 * i)])
	net.mall_history.emit(MallNet.decode_history(_reply(1, 3, 0, rows)))
	_check(not w.pending and w.status_text() == "", "the reply clears pending and the status line")
	_check(w.slot_texts(0) == ["001", "100", "2026/09/01 00:00"], "row 1 (got %s)" % [w.slot_texts(0)])
	_check(w.slot_texts(10) == ["011", "1100", "2026/09/11 10:20"], "slot 10 shows row 11 (got %s)" % [w.slot_texts(10)])
	_check(w.total_text() == "%dSilk" % want_total, "the total is the sum, '%%d%%s' (got %s)" % w.total_text())
	w.scroll_to(99)
	await process_frame
	_check(w.scroll_line() == 4 and w.slot_texts(0)[0] == "005" and w.slot_texts(10)[0] == "015",
		"scrolled to the end: line 4 = 15 - 11, slots show 5..15")
	# The wheel over the window (vslot_036): one line up.
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	w.panel_root.gui_input.emit(wheel)
	_check(w.scroll_line() == 3 and w.slot_texts(0)[0] == "004", "the wheel moves a line")
	# A failed reply changes nothing; another kind is the Obtained list's.
	net.mall_history.emit(MallNet.decode_history(_reply(1, 3, 2, [])))
	_check(w.slot_texts(0)[0] == "004" and w.total_text() == "%dSilk" % want_total, "a non-zero result is ignored")
	net.mall_history.emit(MallNet.decode_history(_reply(2, 1, 0, [[5, 0]])))
	_check(w.rows.size() == 15, "kind 2 is not this list")
	# A negative offset prints signed ("%d").
	(w.control([SilkHistoryWindow.ID_INQUIRY]) as BaseButton).pressed.emit()
	_check(w.slot_texts(0) == ["", "", ""] and w.total_text() == "0Silk", "Inquiry empties the rows first")
	net.mall_history.emit(MallNet.decode_history(_reply(1, 3, 0, [[-50, 0], [80, 0]])))
	_check(w.slot_texts(0)[1] == "-50" and w.total_text() == "30Silk", "amounts are signed (got %s, %s)" % [w.slot_texts(0)[1], w.total_text()])
	# No rows.
	(w.control([SilkHistoryWindow.ID_INQUIRY]) as BaseButton).pressed.emit()
	net.mall_history.emit(MallNet.decode_history(_reply(1, 3, 0, [])))
	_check(w.status_text() == "No history is available." and not w.pending and w.total_text() == "0Silk",
		"n = 0: 'No history is available.' (got '%s')" % w.status_text())
	# Closing with an inquiry out sends nothing; the mall's close cancels.
	(w.control([SilkHistoryWindow.ID_INQUIRY]) as BaseButton).pressed.emit()
	var before := net.sent.size()
	w.close()
	_check(not w.is_open() and closed[0] == 1 and net.sent.size() == before and w.pending,
		"the X hides it and sends nothing (0x7d6ff0)")
	_check(w.mall_closing() and net.sent.back() == [1, 0xff] and not w.pending, "the mall's close sends {1, 0xff} for the pending inquiry")
	_check(not w.mall_closing() and net.sent.size() == before + 1, "nothing pending, nothing sent")
	# Re-opening resets.
	w.open(host)
	_check(w.period_index() == 0 and w.slot_texts(0) == ["", "", ""] and w.total_text() == "0Silk", "open resets (0x7ecad0)")
	# The close button.
	var x := w.get_node_or_null("CloseButton") as BaseButton
	_check(x != null and x.position == Vector2(436, 10), "the X at (w - 26, 10)")
	if x != null:
		x.pressed.emit()
	_check(not w.is_open(), "the X closes it")
	# UI scale: the layout is in UI units, the screen size scales.
	for k in [1.0, 1.5]:
		root.content_scale_factor = k
		await process_frame
		var w2 := SilkHistoryWindow.new(builder)
		w2.net = FakeNet.new()
		w2.open(host)
		for i in 4:
			await process_frame
		var slot0 := w2.slots()[0]
		var slot10 := w2.slots()[10]
		var rel0 := slot0.get_global_rect().position - w2.get_global_rect().position
		_check(rel0 == Vector2(22, 227) and slot0.size == Vector2(402, 24) and slot10.position.y - slot0.position.y == 230,
			"at UI scale %s slot 0 is (22, 227) 402 x 24 and slot 10 230 lower (got %s %s)" % [k, rel0, slot0.size])
		var px := ViewportPixels.physical_size(slot0)
		_check(px == Vector2i(roundi(402 * k), roundi(24 * k)), "at UI scale %s a slot covers %s physical pixels (got %s)" % [k, Vector2i(roundi(402 * k), roundi(24 * k)), px])
		var view := w2.get_viewport_rect().size
		_check(w2.position == Vector2(maxi(0, (int(view.x) >> 1) - 231), maxi(0, (int(view.y) >> 1) - 263)),
			"at UI scale %s centred in the %s view" % [k, view])
		w2.queue_free()
		await process_frame
	root.content_scale_factor = 1.0
	host.queue_free()
