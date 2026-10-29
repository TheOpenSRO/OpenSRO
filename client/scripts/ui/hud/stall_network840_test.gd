extends SceneTree

## Round 840 (lane N): the stall network against the real Media.pk2 --
## CNIFStallNetwork (res_ui\stallnetwork.2dt), its buy box
## (nifstallnetworkmsgbox.2dt), the category tree, the paging and the
## remote buy driven through StallNetworkController, and the stall owner's
## network side in StallController (the type-1001 question, the net values,
## 0xB0BA's network answers, 0x30B7 kind 4's lines).
##   godot4 --headless --path client --script res://scripts/ui/hud/stall_network840_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeNet extends RefCounted:
	var sent: Array = []
	var own_character_id := 1
	var current_character_name := "Aria"
	var stalls := {}
	var buff_items := {}
	func stall_net_search(mode: int, page: int, group: int, degree: int) -> void:
		sent.append("search %d %d %d %d" % [mode, page, group, degree])
	func stall_net_leave() -> void: sent.append("leave")
	func stall_net_buy(r) -> void:
		sent.append("buy %d %d %d %d %d %d" % [r.owner, r.slot, r.price, r.count, r.level, r.serial])
	func stall_open(t: String) -> void: sent.append("open " + t)
	func stall_close() -> void: sent.append("close")
	func stall_update(body: PackedByteArray) -> void: sent.append("update " + body.hex_encode())
	func send_chat(_t: int, _i: int, _n: String, _text: String) -> void: pass

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

func _rec(n: int, owner: int, slot: int, ref: int, count: int, level: int, price: int, serial: int, seller: String) -> StallNetworkNet.Record:
	var r := StallNetworkNet.Record.new()
	var it := ItemInstance.new()
	it.ref_item_id = ref
	it.count = count
	it.is_equipment = false
	r.item = it
	r.owner = owner
	r.seller = seller
	r.slot = slot
	r.count = count
	r.level = level
	r.price = price
	r.serial = serial
	r.number = n
	return r

func _page(first: int, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(_rec(first + i, 100 + i, i % 10, 9, 1 + i, 10 + i, 1000 * (i + 1), 5000 + first + i, "Seller%d" % i))
	return out

func _run() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	var t := func(key: String) -> String: return String(panels.call("_resolve_ui", key, key))
	var lines: Array = []
	panels.stall_system_line.connect(func(text: String, ty: int) -> void: lines.append([text, ty]))
	var c: StallNetworkController = panels.call("_stall_network")
	var net := FakeNet.new()
	c.net = net

	# The tree.
	var tree: Array = panels.call("stall_network_tree")
	var types := 0
	for k in tree:
		types += (k as StallNetworkNet.Category).types.size()
	_check(tree.size() == 15 and types == 57, "fmncategorytreedata: 15 classes, 57 types (got %d, %d)" % [tree.size(), types])

	# Not in a town: 0x3c49's box, no window.
	_check(c.open(false, false) == "refused: not in a town" and not c.is_open(), "outside a town the window does not open")
	await process_frame
	var notice := panels.get_node_or_null("StallNetworkNotice") as PartyMatchConfirm
	_check(notice != null and (notice.get_node("Message") as Label).text == t.call("UIIT_MSG_WARENETWORK_USE_CITY"),
		"0x3c49: the USE_CITY box (\"%s\")" % t.call("UIIT_MSG_WARENETWORK_USE_CITY"))
	if notice != null:
		notice.queue_free()

	# Open.
	_check(c.open(true, false) == "opened" and c.is_open(), "the window opens in a town")
	await process_frame
	var w := c.window
	_check(w.size == Vector2(662, 561), "CNIFStallNetwork 662 x 561 (got %s)" % str(w.size))
	var vp := w.get_viewport_rect().size
	_check(w.position == Vector2(maxi(0, (int(vp.x) >> 1) - 331), maxi(0, (int(vp.y) >> 1) - 280)), "centred (0x798c50) (got %s)" % str(w.position))
	var bar := w.get_node_or_null("TitleBar") as Label
	_check(bar != null and bar.text == t.call("UIIT_STT_WARENETWORK_TITLE"), "the caption \"%s\"" % t.call("UIIT_STT_WARENETWORK_TITLE"))
	var cls := w.combo(StallNetworkWindow.ID_CLASS)
	var typ := w.combo(StallNetworkWindow.ID_TYPE)
	var deg := w.combo(StallNetworkWindow.ID_DEGREE)
	_check(cls != null and cls.item_count == 16 and cls.get_item_text(0) == t.call("UIIT_CTL_WARENETWORK_SCAN_SELECT")
		and cls.get_item_text(1) == t.call("UIIT_CTL_WK_CH_WEAPON"), "Class: Choose + the 15 classes (got %d)" % (cls.item_count if cls else -1))
	_check(typ.item_count == 1 and typ.get_item_text(0) == t.call("UIIT_CTL_WARENETWORK_SCAN_END")
		and deg.item_count == 1 and deg.get_item_text(0) == t.call("UIIT_CTL_WARENETWORK_SCAN_END"), "Type and Degree: None")
	_check(not w.is_enabled(StallNetworkWindow.ID_WHISPER) and w.is_enabled(StallNetworkWindow.ID_BUY)
		and not w.control([StallNetworkWindow.ID_SELLER_CAPTION]).visible, "Whisper off, Purchase on, the Seller caption hidden")
	_check(w.text_at([StallNetworkWindow.ID_GOLD]).ends_with(t.call("UIIT_STT_GOLD")), "the gold line \"0 Gold\" (got %s)" % w.text_at([StallNetworkWindow.ID_GOLD]))
	_check(w.press_search() == "no type", "Search needs a type")
	w.choose(StallNetworkWindow.ID_CLASS, 1)
	_check(typ.item_count == 7 and typ.get_item_text(1) == t.call("UIIT_CTL_WK_CH_WEAPON_SWORD"), "a class: Choose + its 6 types (got %d)" % typ.item_count)
	w.choose(StallNetworkWindow.ID_TYPE, 1)
	_check(deg.item_count == 12 and deg.get_item_text(3) == "3 " + t.call("UIIT_STT_CLASS"),
		"a type with 11 degrees: Choose + \"1 %s\" .. (got %d, %s)" % [t.call("UIIT_STT_CLASS"), deg.item_count, deg.get_item_text(3) if deg.item_count > 3 else ""])
	_check(w.press_search() == "no degree", "Search needs a degree when the type has degrees")
	w.choose(StallNetworkWindow.ID_DEGREE, 3)
	net.sent.clear()
	w.press_search()
	_check(net.sent == ["search 1 0 1 3"] and not w.is_enabled(StallNetworkWindow.ID_SEARCH),
		"the first search: 0x7461 mode 1, page 0, group 1, degree 3; Search off for 10 s (got %s)" % str(net.sent))
	# 0xB461 page 0 of 3.
	c.on_searched({"code": 1, "pages": 3, "records": _page(1, 15)})
	_check(w.text_at([120, 122]) == "1" and w.text_at([120, 123]) == "10" and w.text_at([120, 126]) == "1"
		and w.text_at([120, 127]) == "1,000" and w.text_at([234, 122]) == "15" and w.text_at([234, 127]) == "15,000",
		"the rows: Number, Level, Quantity, Price (got %s %s %s %s)" % [w.text_at([120, 122]), w.text_at([120, 123]), w.text_at([120, 126]), w.text_at([120, 127])])
	_check(w.pager.visible and w.pager.button_text(0) == "1" and w.pager.button_text(2) == "3" and w.pager.button_text(3) == ""
		and w.pager.current == 0, "the page manager: 1 2 3, page 1 current")
	# A page never asked for: mode 3.
	net.sent.clear()
	w.pager.press_index(1)
	_check(net.sent == ["search 3 1 1 3"], "page 2: 0x7461 mode 3 page 1 (got %s)" % str(net.sent))
	w.pager.press_index(2)
	_check(net.sent == ["search 3 1 1 3"], "a page change while an answer is awaited is ignored")
	c.on_searched({"code": 1, "pages": 3, "records": _page(16, 2)})
	_check(w.text_at([120, 122]) == "16" and w.text_at([129, 122]) == "17" and w.text_at([137, 122]) == "", "page 2: two rows, 16 and 17")
	net.sent.clear()
	w.pager.press_index(0)
	_check(net.sent.is_empty() and w.text_at([120, 122]) == "1", "page 1 again: from the cache, nothing sent")
	# Sort by price (column 5) then Number.
	w.press_sort(StallNetworkWindow.SORT_PRICE)
	_check(w.text_at([120, 127]) == "1,000", "price order: ascending")
	# A row.
	w.select_row(2)
	_check(w.is_enabled(StallNetworkWindow.ID_WHISPER) and w.control([StallNetworkWindow.ID_SELLER_CAPTION]).visible
		and w.text_at([StallNetworkWindow.ID_SELLER_BOX]) == "Seller2" and w.row_selected(2), "a filled row: selected, Whisper on, Seller2")
	# Buy: the box, then 0x7463.
	_check(w.press_buy() == "buy box" and c.box != null and c.box.visible, "Purchase shows the buy box")
	_check(c.box.size == Vector2(454, 192) and c.box.text_at([21]) == "3" and c.box.text_at([22]) == "3000",
		"the buy box 454 x 192: count 3, price %%I64d 3000 (got %s %s)" % [c.box.text_at([21]), c.box.text_at([22])])
	net.sent.clear()
	c.box.press_buy()
	_check(net.sent == ["buy 102 2 3000 3 12 5003"], "Buy: 0x7463 {owner, slot, price, count, level, serial} (got %s)" % str(net.sent))
	c.on_bought(1)
	_check(w.text_at([120, 122]) == "1" and w.text_at([129, 122]) == "2" and w.text_at([137, 122]) == "4", "0xB463 {1}: the bought row leaves its page")
	c.on_bought(0x3c52)
	_check(not lines.is_empty() and String(lines[-1][0]) == t.call("UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD"), "0xB463 0x3c52: the gold line")
	# Close: 0x7462 (a mode-1 search went out).
	net.sent.clear()
	w._on_close_pressed()
	_check(net.sent == ["leave"] and not c.is_open(), "the X sends 0x7462 and the window goes")
	# 0x3c49 to a search: closed, no 0x7462.
	c.open(true, false)
	c.window.choose(StallNetworkWindow.ID_CLASS, 13)
	c.window.choose(StallNetworkWindow.ID_TYPE, 1)
	net.sent.clear()
	c.window.press_search()
	_check(net.sent.size() == 1 and String(net.sent[0]).begins_with("search 1 0 "), "a type with no degree: degree 0 (got %s)" % str(net.sent))
	net.sent.clear()
	c.on_searched({"code": 0x3c49})
	_check(not c.is_open() and net.sent.is_empty(), "0xB461 0x3c49 closes the window without 0x7462")
	await process_frame
	var n2 := panels.get_node_or_null("StallNetworkNotice")
	if n2 != null:
		n2.queue_free()

	# --- the stall owner's side ---------------------------------------------------
	var sc: StallController = panels.call("_stall")
	sc.net = net
	sc.on_open_result(1)
	await process_frame
	sc.open = false
	panels.set("stall_network_town", func() -> bool: return true)
	net.sent.clear()
	sc.press_state()
	await process_frame
	var q := panels.get_node_or_null("StallNetworkQuestion") as PartyMatchConfirm
	_check(q != null and net.sent.is_empty() and (q.get_node("Message") as Label).text.contains(t.call("UIIT_MSG_WARENETWORK_REGIST_01")),
		"Start in a town asks the type-1001 question (OURS creator) with REGIST_01..03")
	if q != null:
		q.confirmed.emit()
	_check(net.sent == ["update 05010100"] and sc.network, "Yes: 0x70BA type 5 {1, net 1}; the stall on the network (got %s)" % str(net.sent))
	sc.on_updated({"code": 1, "type": 5, "open": true, "net": 1})
	var sw: HudWindow = panels.get("_windows").get("stall")
	var chat := sw.find_child("Lines", true, false) as RichTextLabel if sw != null else null
	_check(chat != null and chat.get_parsed_text().contains(t.call("UIIT_MSG_WARENETWORK_REGIST_SUCCESS")), "0xB0BA type 5 net 1: REGIST_SUCCESS in the window's chat")
	net.sent.clear()
	sc.press_state()
	_check(net.sent == ["update 05000300"], "open -> modify while on the network: {0, net 3} (got %s)" % str(net.sent))
	sc.open = false
	sc.entries = {0: StallNet.Entry.new()}
	(sc.entries[0] as StallNet.Entry).item = ItemInstance.new()
	net.sent.clear()
	sc.slot_to_bag(0)
	_check(net.sent == ["update 03000500"], "remove while on the network: net 5 (got %s)" % str(net.sent))
	lines.clear()
	sc.on_updated({"code": 1, "type": 3, "net": 0x3c41, "entries": {}})
	_check(not lines.is_empty() and String(lines[-1][0]) == t.call("UIIT_MSG_WARENETWORK_ERROR_FAIL"), "type 3 answered 0x3c41: ERROR_FAIL")
	sc.on_updated({"code": 1, "type": 5, "open": true, "net": 0x3c4a})
	_check(not sc.network, "type 5 answered 0x3c4a: off the network")
	await process_frame
	var n3 := panels.get_node_or_null("StallNetworkNotice")
	_check(n3 != null, "0x3c4a: the USE_CITY box")
	if n3 != null:
		n3.queue_free()
	# Outside a town Start opens plainly.
	sc.open = false
	panels.set("stall_network_town", func() -> bool: return false)
	net.sent.clear()
	sc.press_state()
	_check(net.sent == ["update 05010000"], "Start outside a town: {1, 0} at once (got %s)" % str(net.sent))
	# 0x30B7 kind 4.
	sc.network = true
	var e := StallNet.Entry.new()
	var it := ItemInstance.new()
	it.ref_item_id = 9
	e.item = it
	e.price = 1000
	e.count = 1
	sc.entries = {2: e, 3: e}
	sc.on_event({"kind": 4, "slot": 2, "buyer": "Bram", "entries": {3: e}})
	var want_buy: String = t.call("UIIT_MSG_WARENETWORK_BUY_SUCCESS") % ["Bram", panels.call("item_name", 9)]
	var want_fee: String = t.call("UIIT_MSG_WARENETWORK_CHARGE") % "9"
	_check(chat.get_parsed_text().contains(want_buy) and chat.get_parsed_text().contains(want_fee),
		"kind 4: \"%s\" and the commission line \"%s\" (1000 -> 9)" % [want_buy, want_fee])
	panels.queue_free()
