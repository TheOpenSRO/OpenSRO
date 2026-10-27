extends SceneTree

## Round 837 (OURS): the item chest window and its icon (ItemChestWindow,
## ItemChestIcon) against the real Media.pk2, with a stand-in for NetClient,
## and the layout at UI scale 1.0 and 1.5.
##   godot4 --headless --path client --script res://scripts/ui/hud/item_chest_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const ObjectLoader = preload("res://scripts/assets/object_loader.gd")

class FakeNet extends RefCounted:
	signal chest_list(entries: Array)
	signal chest_take_result(result: Dictionary)
	signal chest_log(entries: Array)
	signal chest_received(entry: Dictionary)
	var lists := 0
	var logs := 0
	var takes: Array = []
	func chest_list_request() -> void:
		lists += 1
	func chest_take(entry: int) -> void:
		takes.append(entry)
	func chest_log_request() -> void:
		logs += 1

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

static func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

static func _str(s: String) -> PackedByteArray:
	var u := s.to_utf8_buffer()
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, u.size())
	b.append_array(u)
	return b

## 0x00D1: u16 n, n x {u32 entry, u32 item, u32 count, str from, u32 date}.
static func _list_bytes(n: int, t0: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, n)
	for i in n:
		b.append_array(_u32(500 + i))
		b.append_array(_u32(1000 + i))
		b.append_array(_u32(i + 1))
		b.append_array(_str("Mall" if i % 2 == 0 else "GM"))
		b.append_array(_u32(t0 + 3600 * i))
	return b

## 0x00D5: u16 n, n x {u32 item, u32 count, str from, u32 date, u32 taken}.
static func _log_bytes(n: int, t0: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, n)
	for i in n:
		b.append_array(_u32(2000 + i))
		b.append_array(_u32(3))
		b.append_array(_str("Mall"))
		b.append_array(_u32(t0))
		b.append_array(_u32(t0 + 86400))
	return b

static func _day(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var d := Time.get_datetime_dict_from_unix_time(unix + bias * 60)
	return "%4d/%02d/%02d" % [d.year, d.month, d.day]

func _rel(w: Control, path: String) -> Rect2:
	var n := w.get_node_or_null(path) as Control
	if n == null:
		return Rect2(-1, -1, -1, -1)
	return Rect2(n.get_global_rect().position - w.get_global_rect().position, n.size)

func _run() -> void:
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
	var w := ItemChestWindow.new(builder)
	var net := FakeNet.new()
	w.free_slots = func() -> int: return 60
	w.item_name = func(id: int) -> String: return "Item%d" % id
	var lines: Array = []
	w.message.connect(func(t: String) -> void: lines.append(t))
	w.attach_net(net)
	var icon := ItemChestIcon.new(builder)
	host.add_child(icon)
	ItemChestIcon.place(icon)
	icon.bind(w, host)
	await process_frame
	_check(icon.art_source == "vplus" and icon.texture_normal != null and icon.texture_normal.get_size() == Vector2(40, 40),
		"the icon is vPlus's chesticon (PNG inside the .ddj), 40 x 40 (got %s)" % icon.art_source)
	_check(icon.position == Vector2(1280 - 90, 180) and icon.size == Vector2(40, 40),
		"the icon sits in the alarm column's second slot, (w - 90, 180) (got %s)" % icon.position)
	_check(icon.tooltip_text == "Chest", "its tooltip is VPLUS_UI_CHEST_CAPTION_TEXT")
	# A receipt with the window closed: the line, and the icon pulses.
	net.chest_received.emit(MallNet.decode_chest_received(_u32(1001) + _u32(2)))
	_check(lines == ["You have recieved item [Item1001] into your chest."], "0x00D6 prints VPLUS_MSG_CHEST_ITEM_RECEIVED (got %s)" % [lines])
	_check(w.alert and icon.alerting(), "the icon alerts while the window is closed")
	var m0 := icon.self_modulate
	icon.advance_seconds(0.5)
	var m1 := icon.self_modulate
	icon.advance_seconds(0.5)
	_check(m0 != m1 and icon.self_modulate == m0, "it pulses every 500 ms")
	# Opening: by the icon.
	icon.pressed.emit()
	for i in 4:
		await process_frame
	_check(w.is_open() and not w.alert and not icon.alerting() and icon.self_modulate == Color(1, 1, 1), "the icon opens the window and stops pulsing")
	_check(net.lists == 1, "opening asks for the list (0x00D0)")
	_check(w.size == ItemChestWindow.WINDOW_SIZE and w.position == Vector2(288, 182), "704 x 357, centred (got %s)" % w.position)
	_check((w.get_node("TitleBar") as Label).text == "Chest", "the caption")
	_check(w.count_text() == "60" and w.page_text() == "1", "Inventory Remaining 60, page 1")
	_check(w.take_button().disabled and not w.take_all_button().disabled, "Take disabled with nothing selected, Take All enabled")
	_check((w.tab_button(0).get_node("Art_on") as Control).visible and (w.tab_button(1).get_node("Art_off") as Control).visible,
		"the Chest tab is checked")
	var heads: Array = []
	for i in 5:
		heads.append((w.panel_root.get_node("Head%d/Text" % i) as Label).text)
	_check(heads == ["No.", "Item Name", "Quantity", "From", "Date"], "the column heads (got %s)" % [heads])
	_check((w.take_all_button().get_node("Text") as Label).text == "Take All" and (w.take_button().get_node("Text") as Label).text == "Take"
		and (w.panel_root.get_node("Remaining") as Label).text == "Inventory Remaining", "the archive's button and label texts")
	# 23 entries: three pages of ten.
	var t0 := 1798000000
	net.chest_list.emit(MallNet.decode_chest_list(_list_bytes(23, t0)))
	_check(w.entries.size() == 23 and w.pages() == 3, "23 entries, 3 pages")
	_check(w.row_texts(0) == ["1", "Item1000", "1", "Mall", _day(t0)], "row 1 (got %s)" % [w.row_texts(0)])
	_check(w.row_texts(9)[0] == "10", "ten rows a page")
	_check(w.row_control(0).tooltip_text.begins_with(_day(t0)) and w.row_control(0).tooltip_text.length() == 16, "the full stamp is the row's tooltip")
	(w.page_buttons()[1] as BaseButton).pressed.emit()
	_check(w.page == 1 and w.page_text() == "2" and w.row_texts(0)[0] == "11", "the right arrow: page 2 starts at 11")
	w.set_page(5)
	_check(w.page == 2 and w.row_texts(2)[0] == "23" and w.row_texts(3) == ["", "", "", "", ""], "the last page has 3 rows")
	(w.page_buttons()[0] as BaseButton).pressed.emit()
	_check(w.page == 1, "the left arrow")
	# Select row 1 of page 2 (entry 511) and take it; then take all.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	w.row_control(1).gui_input.emit(press)
	_check(w.selected_entry == 511 and not w.take_button().disabled and (w.row_control(1).get_node("Select") as Control).visible,
		"a press selects the row's entry (511) and enables Take")
	w.take_button().pressed.emit()
	w.take_all_button().pressed.emit()
	_check(net.takes == [511, 0], "Take sends 0x00D2 {511}, Take All {0} (got %s)" % [net.takes])
	var n_lines := lines.size()
	net.chest_take_result.emit(MallNet.decode_chest_take(PackedByteArray([1, 1, 0])))
	_check(net.lists == 1 and lines.size() == n_lines, "a take's success asks nothing (the server sends a fresh 0x00D1) and prints nothing")
	net.chest_take_result.emit(MallNet.decode_chest_take(PackedByteArray([2, 0x07, 0x18])))
	_check(lines.size() == n_lines + 1 and lines.back() == "Inventory is full, cannot claim anymore items.", "0x1807 prints VPLUS_MSG_CHEST_INVENTORY_FULL_ERROR")
	net.chest_take_result.emit(MallNet.decode_chest_take(PackedByteArray([2, 0x09, 0x18])))
	_check(lines.size() == n_lines + 1, "0x1809 (no such entry) prints nothing")
	# The entry gone from a new list drops the selection.
	net.chest_list.emit(MallNet.decode_chest_list(_list_bytes(5, t0)))
	_check(w.selected_entry == 0 and w.take_button().disabled and w.page == 0, "a list without the entry clears the selection")
	# A receipt while open: no alert, the list again.
	net.chest_received.emit({"item": 1002, "count": 1})
	_check(not w.alert and net.lists == 2, "a receipt with the window open refreshes it")
	# The Take Log.
	w.tab_button(1).pressed.emit()
	_check(w.tab == ItemChestWindow.TAB_LOG and net.logs == 1 and w.note_visible() and not w.take_button().visible,
		"the Take Log tab asks 0x00D4, shows the 7-day note, hides Take")
	_check((w.panel_root.get_node("Note") as Label).text == "*Only logs from the last 7 days will appear.", "the note's text")
	net.chest_log.emit(MallNet.decode_chest_log(_log_bytes(4, t0)))
	_check(w.row_texts(0) == ["1", "Item2000", "3", "Mall", _day(t0 + 86400)], "log rows show the take date (got %s)" % [w.row_texts(0)])
	w.row_control(0).gui_input.emit(press)
	_check(w.selected_entry == 0, "log rows are not selectable")
	w.tab_button(0).pressed.emit()
	_check(w.tab == ItemChestWindow.TAB_CHEST and net.lists == 3 and w.take_button().visible, "back on Chest")
	# The X.
	(w.get_node("CloseButton") as BaseButton).pressed.emit()
	_check(not w.is_open(), "the X closes it")
	# The layout at UI scale 1.0 and 1.5: UI units the same, pixels scaled.
	var want := {
		"ChestRoot/InnerFrame": Rect2(8, 60, 689, 291),
		"ChestRoot/ListFrame": Rect2(23, 71, 660, 241),
		"ChestRoot/Tab0": Rect2(18, 39, 72, 24),
		"ChestRoot/Tab1": Rect2(92, 39, 72, 24),
		"ChestRoot/Head0": Rect2(26, 74, 27, 24),
		"ChestRoot/Head1": Rect2(53, 74, 304, 24),
		"ChestRoot/Head2": Rect2(357, 74, 82, 24),
		"ChestRoot/Head3": Rect2(439, 74, 150, 24),
		"ChestRoot/Head4": Rect2(589, 74, 92, 24),
		"ChestRoot/Row0": Rect2(26, 97, 655, 20),
		"ChestRoot/Row9": Rect2(26, 286, 655, 20),
		"ChestRoot/Line0": Rect2(27, 118, 654, 1),
		"ChestRoot/Remaining": Rect2(26, 321, 118, 20),
		"ChestRoot/CountFrame": Rect2(146, 321, 37, 20),
		"ChestRoot/PageLeft": Rect2(329, 322, 16, 16),
		"ChestRoot/PageBox": Rect2(345, 322, 16, 16),
		"ChestRoot/PageRight": Rect2(361, 322, 16, 16),
		"ChestRoot/TakeAll": Rect2(532, 317, 76, 24),
		"ChestRoot/Take": Rect2(610, 317, 76, 24),
		"CloseButton": Rect2(678, 10, 16, 16),
	}
	for k in [1.0, 1.5]:
		root.content_scale_factor = k
		await process_frame
		var w2 := ItemChestWindow.new(builder)
		w2.attach_net(FakeNet.new())
		w2.free_slots = func() -> int: return 7
		w2.open(host)
		for i in 4:
			await process_frame
		var bad: Array = []
		for path in want:
			var got := _rel(w2, path)
			if got != want[path]:
				bad.append("%s %s" % [path, got])
		_check(bad.is_empty(), "at UI scale %s every rect is the picture's (wrong: %s)" % [k, bad])
		var px := ViewportPixels.physical_size(w2.take_all_button())
		_check(px == Vector2i(roundi(76 * k), roundi(24 * k)), "at UI scale %s Take All covers %s physical pixels (got %s)" % [k, Vector2i(roundi(76 * k), roundi(24 * k)), px])
		var view := w2.get_viewport_rect().size
		_check(w2.position == Vector2(maxi(0, (int(view.x) >> 1) - 352), maxi(0, (int(view.y) >> 1) - 178)),
			"at UI scale %s centred in the %s view" % [k, view])
		var icon2 := ItemChestIcon.new(builder)
		host.add_child(icon2)
		ItemChestIcon.place(icon2)
		await process_frame
		_check(icon2.position == ItemChestIcon.slot_position(host.size) and icon2.size == Vector2(40, 40),
			"at UI scale %s the icon is at %s (got %s)" % [k, ItemChestIcon.slot_position(host.size), icon2.position])
		icon2.queue_free()
		w2.queue_free()
		await process_frame
	root.content_scale_factor = 1.0
	host.queue_free()
