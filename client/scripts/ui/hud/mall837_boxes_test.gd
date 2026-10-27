extends SceneTree

## Round 837: the item mall's dialog boxes against the real Media.pk2 --
## MallConfirmBuy (ID 1200), MallMessageBox (IDs 122 / 306 / 1202 / 1203),
## MallUsePoint (ID 400) and MallEnterBox (kind 0x1e), driven through a fake
## controller and fake balances / bag. SKIP without the archive.
##   godot4 --headless --path client --script res://scripts/ui/hud/mall837_boxes_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeMall extends RefCounted:
	var busy := false
	var dealing := 0
	var reserve: Array = []
	var lump: Array = []
	var sent: Array = []
	var lumps: Array = []
	var results: Array = []
	var reserve_shown := 0
	var real: ItemMallController
	func send_buy(g, c: int, p: int) -> void:
		sent.append([g, c, p])
		dealing += c
	func start_lump(goods: Array, _reserved := false) -> void:
		lumps.append(goods)
		lump = goods.duplicate()
		dealing = 1
	func on_buy_result(r: Dictionary) -> void:
		results.append(r)
		dealing = 0
		lump = []
	func show_reserve() -> void:
		reserve_shown += 1
	func package_name(p) -> String:
		return real.package_name(p)
	func package_icon(p) -> Texture2D:
		return real.package_icon(p)

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

func _rect(c: Control) -> Rect2:
	var r = c.get_meta(UiBuilder.AUTHORED_RECT_META, null) if c != null else null
	return r if r is Rect2 else (Rect2(c.position, c.size) if c != null else Rect2())

func _label(n: Node) -> String:
	if n == null:
		return "<none>"
	if n is Label:
		return (n as Label).text
	for c in n.find_children("*", "Label", true, false):
		return (c as Label).text
	return "<none>"

func _title(w: HudWindow) -> String:
	var bar := w.get_node_or_null("TitleBar") as Label
	return bar.text if bar != null else "<none>"

func _gone(c) -> bool:
	return c == null or not is_instance_valid(c) or (c as Node).is_queued_for_deletion()

var panels: Control
var items: Dictionary
var st := {"free": 50, "bal": [100000, 0, 0], "msgs": []}

func _opts() -> Dictionary:
	return {"host": panels,
		"free_slots": func() -> int: return int(st["free"]),
		"balances": func() -> Array: return st["bal"],
		"message": func(code: int) -> void: (st["msgs"] as Array).append(code)}

func _item(code: String):
	return items.get(code)

## A good of the real catalogue whose package passes `test`.
func _find(data: MallData, test: Callable) -> MallData.Good:
	for g in data.goods:
		if test.call(g):
			return g
	return null

func _is_33(g: MallData.Good, data_zero: bool) -> bool:
	var p := g.package
	if p.is_bundle() or p.scraps.is_empty():
		return false
	var s: MallData.Scrap = p.scraps[0]
	var it = _item(s.item_code)
	if it == null or it.type_ids.size() < 2 or it.type_ids[0] != 3 or it.type_ids[1] != 3 or (int(it.bionic) & 1) != 0:
		return false
	return (s.data == 0) == data_zero and (not data_zero or int(it.max_stack) > 5)

## A synthetic good (a real item, our prices) for the bit sets the catalogue lacks.
func _synthetic(base: MallData.Good, costs: Dictionary, scraps: int = 1) -> MallData.Good:
	var p := MallData.Package.new()
	p.id = 900000 + costs.size() * 10 + scraps
	p.code = "PACKAGE_TEST_%d" % p.id
	p.name_strid = base.package.name_strid
	p.icon = base.package.icon
	for i in scraps:
		p.scraps.append(base.package.scraps[0])
	for bit in costs:
		p.costs[bit] = costs[bit]
		p.devices |= int(bit)
	var g := MallData.Good.new()
	g.shop_index = base.shop_index
	g.tab_index = base.tab_index
	g.slot = base.slot
	g.package = p
	return g

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
	panels = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	root.size = Vector2i(1280, 720)
	await process_frame
	print("view %s" % str(panels.get_viewport_rect().size))
	panels.call("_load_items")
	items = panels.get("_items_by_code")
	var mall := FakeMall.new()
	mall.real = ItemMallController.new(panels)
	var data := mall.real.load_data()
	_check(data.goods.size() > 0, "the mall catalogue loads (%d goods)" % data.goods.size())
	if data.goods.is_empty():
		return
	await _confirm_checks(builder, mall, data)
	await _message_checks(builder, mall, data)
	await _enter_checks(builder)
	await _scale_checks(builder, mall, data)

# --- MallConfirmBuy ---------------------------------------------------------------

func _confirm_checks(builder: UiBuilder, mall: FakeMall, data: MallData) -> void:
	var silk_only := _find(data, func(g): return g.package.devices == MallData.PAY_SILK and not g.package.scraps.is_empty())
	var two_bit := _find(data, func(g): return (g.package.devices & 6) == 6 and not g.package.scraps.is_empty())
	_check(silk_only != null, "a silk-only package in the catalogue (%s)" % (silk_only.package.code if silk_only != null else "-"))
	if silk_only == null:
		return
	if two_bit == null:
		print("note: no silk + gift package in the catalogue; a synthetic one")
		two_bit = _synthetic(silk_only, {2: 30, 4: 30})
	var three_bit := _find(data, func(g):
		var n := 0
		for b in [1, 2, 4, 8, 16, 32]:
			if g.package.devices & b:
				n += 1
		return n >= 3 and not g.package.scraps.is_empty())
	if three_bit == null:
		print("note: no 3-bit package in the catalogue; a synthetic gold + silk + gift one")
		three_bit = _synthetic(silk_only, {1: 1000, 2: 30, 4: 25})

	# A 2-bit package: silk and gift rows, then the space row.
	var box := MallConfirmBuy.open(panels, mall, two_bit, _opts())
	_check(box != null and mall.busy, "the confirm box opens and sets busy (+0x7c8)")
	if box == null:
		return
	await process_frame
	await process_frame
	var expect_rows := MallConfirmBuy.row_indices(two_bit.package)
	_check(box.row_order == expect_rows and expect_rows.has(1) and expect_rows.has(2) and expect_rows.has(700),
		"2-bit: rows %s (silk, gift, space)" % str(box.row_order))
	_check(box.size == Vector2(338, 212 + 30 * expect_rows.size()), "2-bit: 338 x 212 + 30 a row (got %s)" % str(box.size))
	var ys: Array = []
	for i in box.row_order:
		ys.append(int((box.rows[i] as Control).position.y))
	_check(ys[0] == 140 and ys[1] == 170, "rows at y 140, 30 apart (got %s)" % str(ys))
	# The archive's table has three rows for UIIT_STT_SILKMALL_SILK ("Premium
	# Silk", then "Silk Scrolls" twice); the label is whatever the table gives.
	_check(box.row_text(1) == builder.resolve_text("UIIT_STT_SILKMALL_SILK") and box.row_text(1, true) == "Silk",
		"silk row: UIIT_STT_SILKMALL_SILK / Silk (got %s / %s)" % [box.row_text(1), box.row_text(1, true)])
	_check(box.row_text(2) == "Gift Silk" and box.row_text(2, true) == "Silk", "gift row: Gift Silk / Silk")
	_check(box.row_text(700) == "Remained space" and box.row_text(700, true) == "Slot", "space row: Remained space / Slot")
	var v1 := (box.rows[1] as Control).find_child(MallConfirmBuy.R_VALUE, true, false) as LineEdit
	var v700 := (box.rows[700] as Control).find_child(MallConfirmBuy.R_VALUE, true, false) as LineEdit
	_check(v1 != null and v1.text == str(two_bit.package.costs[2]), "silk row shows the price x 1 (got %s)" % (v1.text if v1 else "-"))
	_check(v700 != null and v700.text == "50", "space row shows the free slots")
	var buy := box.node(MallConfirmBuy.C_BUY) as Control
	var cancel := box.node(MallConfirmBuy.C_CANCEL) as Control
	_check(_rect(buy).position == Vector2(62, box.size.y - 40) and _rect(cancel).position == Vector2(185, box.size.y - 40),
		"Buy at (62, h - 40), Cancel at (185, h - 40) (got %s / %s)" % [_rect(buy).position, _rect(cancel).position])
	_check(_label(box.node("GDR_ITEMMALL_CONFIRM_BUY_TITLE")) == "Buy" and _title(box) == "",
		"title control 5 'Buy'; CIFMainFrame's caption empty")
	_check(_label(box.node(MallConfirmBuy.C_NAME)) == mall.package_name(two_bit.package), "the name on control 40")
	var vp := box.get_viewport_rect().size
	_check(box.global_position == Vector2(int(vp.x) / 2 - int(box.size.x) / 2, int(vp.y) / 2 - int(box.size.y) / 2),
		"centred on the screen at its final size (got %s)" % str(box.global_position))
	_check(MallConfirmBuy.open(panels, mall, two_bit, _opts()) == null, "a second box is refused while busy")
	box.spin(1)
	var want := mini(2, box.cap)
	_check(box.count == want and v1.text == str(want * int(two_bit.package.costs[2])),
		"spin up: %d (cap %d), the silk row follows (got %d, %s)" % [want, box.cap, box.count, v1.text])
	box.cancel()
	await process_frame
	_check(_gone(box) and not mall.busy and mall.sent.is_empty(), "Cancel: closed, busy cleared, nothing sent")

	# A 3-bit package: gold row first.
	box = MallConfirmBuy.open(panels, mall, three_bit, _opts())
	await process_frame
	_check(box.row_order.size() == MallConfirmBuy.row_indices(three_bit.package).size() and box.row_order.size() >= 4,
		"3-bit: %d rows (%s)" % [box.row_order.size(), str(box.row_order)])
	if box.row_order.has(0):
		_check(box.row_text(0) == "Price" and box.row_text(0, true) == "Gold", "gold row: Price / Gold")
	_check(box.size.y == 212 + 30 * box.row_order.size(), "3-bit: the box grows 30 a row (h %d)" % int(box.size.y))
	var frame := box.node("GDR_ITEMMALL_CONFIRM_BUY_FRAME") as Control
	_check(frame != null and _rect(frame).size.y == 120 + 30 * box.row_order.size(), "frame 1001 grows with the rows")
	box.cancel()
	await process_frame

	# Quantity caps.
	var stack := _find(data, func(g): return _is_33(g, true))
	var counted := _find(data, func(g): return _is_33(g, false))
	var equip := _find(data, func(g):
		if g.package.is_bundle() or g.package.scraps.is_empty():
			return false
		var it = _item((g.package.scraps[0] as MallData.Scrap).item_code)
		return it != null and it.type_ids.size() >= 2 and it.type_ids[0] == 3 and it.type_ids[1] == 1)
	if stack != null:
		box = MallConfirmBuy.open(panels, mall, stack, _opts())
		var ms := int(_item((stack.package.scraps[0] as MallData.Scrap).item_code).max_stack)
		_check(box.cap == ms, "3/3, Data 0: the cap is MaxStack %d (got %d, %s)" % [ms, box.cap, stack.package.code])
		var sv := (box.rows[1] as Control).find_child(MallConfirmBuy.R_VALUE, true, false) as LineEdit if box.rows.has(1) else null
		box.spin(1)
		_check(box.count == 2 and box.edit.text == "2" and (sv == null or sv.text == str(2 * stack.package.silk_price())),
			"spin up: 2 in the edit, the silk row x 2 (got %s)" % (sv.text if sv != null else "-"))
		box.spin(-1)
		_check(box.count == 1, "spin down: 1")
		box.set_count(ms + 10)
		_check(box.count == ms, "held to MaxStack")
		# The slot test: the stack kind needs one free slot whatever the count.
		st["free"] = 1
		box.press_buy()
		_check(mall.sent.size() == 1 and int(mall.sent[0][1]) == ms and int(mall.sent[0][2]) == 0 and _gone(box),
			"3/3 MaxStack x%d with 1 free slot: sent (count %d, points 0), closed" % [ms, ms])
		st["free"] = 50
		mall.sent.clear()
		mall.dealing = 0
		await process_frame
	else:
		print("note: no 3/3 Data-0 package with MaxStack > 5 in the catalogue")
	for pair in [[counted, "3/3 with a Data count"], [equip, "equipment (3/1)"], [_synthetic(silk_only, {2: 10}, 2), "a bundle"]]:
		var g: MallData.Good = pair[0]
		if g == null:
			print("note: no %s package" % pair[1])
			continue
		box = MallConfirmBuy.open(panels, mall, g, _opts())
		box.set_count(99)
		_check(box.cap == 5 and box.count == 5, "%s: the cap is 5 (got %d)" % [pair[1], box.cap])
		box.cancel()
		await process_frame

	# Spin down to 0; the checks.
	box = MallConfirmBuy.open(panels, mall, silk_only, _opts())
	box.spin(-1)
	_check(box.count == 0 and box.edit.text == "0", "spin down from 1 reaches 0")
	box.spin(-1)
	_check(box.count == 0, "and stays at 0")
	box.press_buy()
	await process_frame
	_check(_gone(box) and mall.sent.is_empty() and not mall.busy, "a count of 0: closed, nothing sent")
	var non_stack: MallData.Good = equip if equip != null else _synthetic(silk_only, {2: 10}, 2)
	box = MallConfirmBuy.open(panels, mall, non_stack, _opts())
	box.set_count(3)
	st["free"] = 2
	box.press_buy()
	_check((st["msgs"] as Array) == [0x1807] and not _gone(box) and mall.sent.is_empty() and mall.busy,
		"3 of a one-slot item, 2 free slots: 0x1807, the box stays (got %s)" % str(st["msgs"]))
	st["free"] = 50
	st["bal"] = [0, 0, 0]
	(st["msgs"] as Array).clear()
	box.press_buy()
	await process_frame
	_check((st["msgs"] as Array) == [0x1880] and _gone(box) and mall.sent.is_empty() and not mall.busy,
		"silk + gift + point below the price: 0x1880, closed (got %s)" % str(st["msgs"]))
	# Silk + gift + point together cover it.
	var price := non_stack.package.silk_price()
	st["bal"] = [price, 0, price]
	(st["msgs"] as Array).clear()
	box = MallConfirmBuy.open(panels, mall, non_stack, _opts())
	box.set_count(2)
	box.press_buy()
	await process_frame
	_check(mall.sent.size() == 1 and mall.sent[0][0] == non_stack and int(mall.sent[0][1]) == 2 and _gone(box) and not mall.busy,
		"silk + point = price x 2: sent x2, closed, busy cleared")
	mall.sent.clear()
	mall.dealing = 0
	st["bal"] = [100000, 0, 0]

	# The X (vslot 43) and Esc.
	box = MallConfirmBuy.open(panels, mall, silk_only, _opts())
	box.closed.emit()
	await process_frame
	_check(_gone(box) and not mall.busy, "the X closes it and clears busy")

	# The point row (bit 16): a synthetic package, the catalogue has none.
	var pointy := _synthetic(silk_only, {2: 100, 16: 30})
	st["bal"] = [100000, 0, 50]
	box = MallConfirmBuy.open(panels, mall, pointy, _opts())
	await process_frame
	await process_frame
	_check(box.row_order == [1, 700, 4], "bit 16: silk, space, then the point row (got %s)" % str(box.row_order))
	_check(box.row_text(4) == builder.resolve_text("UIIT_CTL_SILK_INQUIRY_POINT") and box.row_text(4, true) == "P",
		"point row: UIIT_CTL_SILK_INQUIRY_POINT / P (got %s / %s)" % [box.row_text(4), box.row_text(4, true)])
	var plabel := (box.rows[4] as Control).find_child(MallConfirmBuy.R_LABEL, true, false) as Control
	_check(_rect(plabel).position.x == 57 - 15, "its label moved 15 left (x %d)" % int(_rect(plabel).position.x))
	var pbtn := (box.rows[4] as Control).find_child(MallConfirmBuy.R_POINT, true, false) as BaseButton
	var sbtn := (box.rows[1] as Control).find_child(MallConfirmBuy.R_POINT, true, false) as BaseButton
	_check(pbtn != null and pbtn.visible and sbtn != null and not sbtn.visible, "the point button shows on the point row only")
	_check(box.points == 30 and box.row_value(1) == 70 and box.row_value(4) == 30, "points start at the bit-16 Cost: silk 100 - 30")
	pbtn.pressed.emit()
	await process_frame
	var up := box.use_point
	_check(up != null and up.size == Vector2(244, 177), "the point button opens CItemMallUsePoint 244 x 177")
	if up != null:
		_check((up.root.get_node(MallUsePoint.EDIT_REMAIN) as LineEdit).text == "50", "it shows the point balance 50")
		up.edit.text = "80"
		up.edit.text_changed.emit("80")
		_check(up.typed_points() == 50, "typed points held to the balance")
		up.press_use()
		await process_frame
	_check(box.points == 50 and box.row_value(1) == 50 and not box.edit.editable, "Use: 50 points, silk row 50, the quantity locked")
	_check((box.node(MallConfirmBuy.C_UP) as BaseButton).disabled and (box.node(MallConfirmBuy.C_DOWN) as BaseButton).disabled, "both spins disabled")
	box.press_buy()
	await process_frame
	_check(mall.sent.size() == 1 and int(mall.sent[0][2]) == 50, "the request carries the points (got %s)" % str(mall.sent))
	mall.sent.clear()
	mall.dealing = 0
	st["bal"] = [100000, 0, 0]

# --- MallMessageBox ---------------------------------------------------------------

func _message_checks(builder: UiBuilder, mall: FakeMall, data: MallData) -> void:
	var some: Array = []
	for g in data.goods:
		if not (g as MallData.Good).package.scraps.is_empty() and (g as MallData.Good).package.silk_price() > 0:
			some.append(g)
		if some.size() == 4:
			break
	var sum := 0
	for g in some:
		sum += (g as MallData.Good).package.silk_price()
	var box := MallMessageBox.open_lump(panels, mall, some, false, _opts())
	_check(box != null and mall.busy, "ID 122 opens, busy set")
	if box == null:
		return
	await process_frame
	await process_frame
	_check(box.size == Vector2(368, 348) and _title(box) == "Buy Item Worn", "ID 122: 368 x 348, 'Buy Item Worn' (got %s, %s)" % [box.size, _title(box)])
	_check(_label(box.node("GDR_ITEMMALL_ALL_BUY_FRAME_1_TEXT")) == "Buy all equipped items?", "the prompt")
	_check(box.list_names().size() == 4 and box.list_names()[0] == mall.package_name(some[0].package), "one list row per good")
	var rows := box.node(MallMessageBox.A_LIST).get_node("Rows")
	_check(rows.get_child(2).visible and not rows.get_child(3).visible, "three rows shown")
	box.scroll_list(5)
	_check(box.list_first == 1 and not rows.get_child(0).visible and rows.get_child(3).visible, "the slider runs 0..n - 3")
	_check(box.text_of(MallMessageBox.A_TOTAL) == str(sum) and box.text_of(MallMessageBox.A_SPACE) == "50",
		"the total %d and the free slots" % sum)
	var vp := box.get_viewport_rect().size
	_check(box.global_position == Vector2(int(vp.x) / 2 - 184, int(vp.y) / 2 - 174), "centred (got %s)" % str(box.global_position))
	box.press_buy()
	await process_frame
	_check(mall.lumps.size() == 1 and mall.lumps[0] == some and _gone(box) and not mall.busy, "Buy: the lump starts, closed, busy cleared")
	mall.lumps.clear()
	mall.lump = []
	mall.dealing = 0
	# 0x7d7d80's own refusals.
	st["bal"] = [sum - 1, 0, 0]
	box = MallMessageBox.open_lump(panels, mall, some, false, _opts())
	box.press_buy()
	await process_frame
	_check(mall.lumps.is_empty() and mall.results.size() == 1 and int(mall.results[0]["code"]) == 0x1880 and _gone(box),
		"too little silk: B034 {2, 0x1880} to the reply handler, closed")
	st["bal"] = [100000, 0, 0]
	st["free"] = 3
	mall.results.clear()
	box = MallMessageBox.open_lump(panels, mall, some, false, _opts())
	box.press_buy()
	await process_frame
	_check(mall.lumps.is_empty() and mall.results.size() == 1 and int(mall.results[0]["code"]) == 0x1807, "4 goods, 3 free slots: 0x1807")
	st["free"] = 50
	mall.results.clear()

	# ID 306, Reserved's Buy All.
	var three := some.slice(0, 3)
	box = MallMessageBox.open_lump(panels, mall, three, true, _opts())
	await process_frame
	_check(box.size == Vector2(376, 272) and _title(box) == "Buy All", "ID 306: 376 x 272, 'Buy All'")
	_check(box.text_of(MallMessageBox.Z_COUNT) == "3" and box.text_of(MallMessageBox.Z_TOTAL) == str(box.total)
		and box.text_of(MallMessageBox.Z_SPACE) == "50", "count, total, space")
	_check(_label(box.node("GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_STA_TEXT")).begins_with("Will you buy items"), "the question")
	box.press_buy()
	_check(mall.lumps.size() == 1 and not _gone(box), "Buy: the lump starts, the box stays")
	_check(not box.request_close() and not _gone(box), "Cancel refused while it is being sent")
	mall.lump = []
	mall.dealing = 0
	await process_frame
	await process_frame
	_check(_gone(box) and not mall.busy, "closed once the lump is done")
	mall.lumps.clear()

	# IDs 1202 / 1203.
	var g0: MallData.Good = some[0]
	box = MallMessageBox.open_reserve(panels, mall, g0, true, _opts())
	await process_frame
	_check(box.size == Vector2(396, 252) and _title(box) == "Pre-select", "ID 1202: 396 x 252, 'Pre-select'")
	_check(box.text_of(MallMessageBox.R_NAME) == mall.package_name(g0.package) and box.text_of(MallMessageBox.R_PRICE) == str(g0.package.silk_price()),
		"name and price")
	var pml := box.node(MallMessageBox.R_PML).get_node_or_null("PmlText") as RichTextLabel
	_check(pml != null and pml.get_parsed_text().contains("Will you reserve this item?"), "the PML text")
	box.press_ok()
	await process_frame
	_check(mall.reserve == [g0] and _gone(box) and not mall.busy, "OK adds the good to the reserve list")
	mall.reserve = [g0, some[1], g0]
	box = MallMessageBox.open_reserve(panels, mall, g0, false, _opts())
	await process_frame
	_check(_title(box) == "Delete" and _label(box.node(MallMessageBox.R_OK)) == "Delete", "ID 1203: 'Delete' caption and button")
	_check(_label(box.node("GDR_ITEMMALL_ZZIM_DELETE_TEXT")) == "Delete the selected items in the reservation list.", "the delete text")
	box.press_ok()
	await process_frame
	_check(mall.reserve == [some[1], g0] and mall.reserve_shown == 1, "OK removes the first entry and redraws the reserve view")
	box = MallMessageBox.open_reserve(panels, mall, g0, true, _opts())
	var c := box.node(MallMessageBox.R_CANCEL) as BaseButton
	c.pressed.emit()
	await process_frame
	_check(mall.reserve.size() == 2 and _gone(box) and not mall.busy, "Cancel: nothing added, closed")

# --- MallEnterBox ---------------------------------------------------------------

func _enter_checks(builder: UiBuilder) -> void:
	var hits := [0]
	var box := MallEnterBox.open(builder, panels, func() -> void: hits[0] += 1)
	_check(box != null, "the F10 box opens")
	if box == null:
		return
	await process_frame
	_check(box.size == Vector2(400, 210) and box.caption.text == "Enter Item Mall", "400 x 210, 'Enter Item Mall'")
	_check(_rect(box.node("GDR_MBIN_STATIC_MESSAGE1")) == Rect2(128, 43, 148, 52) and box.node("GDR_MBIN_STATIC_MESSAGE1").get_node_or_null("Picture") != null,
		"mall_pic.ddj 148 x 52 at (128, 43)")
	_check(_label(box.node("GDR_MBIN_STATIC_MESSAGE2")) == "You can be attacked by monsters or"
		and _label(box.node("GDR_MBIN_STATIC_MESSAGE4")) == "It is recommended to use Item Mall in safe zones."
		and _rect(box.node("GDR_MBIN_STATIC_MESSAGE3")).position == Vector2(20, 125), "the three warning lines at x 20")
	_check(_rect(box.node("GDR_MBIN_BTN_OK")).position == Vector2(123, 168) and _rect(box.node("GDR_MBIN_BTN_CANCEL")).position == Vector2(203, 168)
		and not box.node("GDR_MBIN_BTN_CERTIFY").visible, "OK (123, 168), Cancel (203, 168), CERTIFY hidden")
	var vp := box.get_viewport_rect().size
	_check(box.position == Vector2(floorf(vp.x / 2) - 0x9a, floorf(vp.y / 2) - 0x4a), "placed by the 308 x 148 creation size")
	_check(MallEnterBox.open(builder, panels, func() -> void: pass) == null, "a second one is refused while it is up")
	box.press_cancel()
	await process_frame
	_check(hits[0] == 0, "Cancel: no callback")
	box = MallEnterBox.open(builder, panels, func() -> void: hits[0] += 1)
	_check(box != null, "opens again after closing")
	box.press_ok()
	await process_frame
	_check(hits[0] == 1, "OK calls back")

# --- UI scale ---------------------------------------------------------------------

func _scale_checks(builder: UiBuilder, mall: FakeMall, data: MallData) -> void:
	root.size = Vector2i(1152, 648)
	root.content_scale_factor = 1.5
	await process_frame
	var g: MallData.Good = data.goods[0]
	var box := MallConfirmBuy.open(panels, mall, g, _opts())
	await process_frame
	await process_frame
	var vp := box.get_viewport_rect().size
	_check(box.size.x == 338 and box.global_position == Vector2(int(vp.x) / 2 - 169, int(vp.y) / 2 - int(box.size.y) / 2),
		"at UI scale 1.5 (view %s) the box keeps its UI size and centres in UI units (got %s)" % [vp, box.global_position])
	var buy := box.node(MallConfirmBuy.C_BUY) as Control
	_check(buy.get_global_rect().position - box.global_position == Vector2(62, box.size.y - 40), "its Buy button in UI units")
	box.cancel()
	await process_frame
	root.content_scale_factor = 1.0
