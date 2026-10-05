extends SceneTree

## Round 726: the store's and the warehouse's confirm boxes (StoreMessageBox)
## built from the client's layouts (synthetic copies, StoreBoxFixture), and
## the retail gestures in HudPanels (Ctrl+click buys and sells with no box).
##   godot4 --headless --path client --script res://scripts/ui/hud/store_message_box_test.gd

var _failures := 0
var _frame := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _box(kind: int, opts: Dictionary) -> StoreMessageBox:
	var box := StoreMessageBox.new()
	var built := box.build(StoreBoxFixture.builder(), kind, opts)
	_check(built, "%s builds" % StoreMessageBox.Kind.keys()[kind])
	root.add_child(box)
	return box

func _visible(box: Node, node_name: String) -> bool:
	var n := box.find_child(node_name, true, false) as CanvasItem
	return n != null and n.visible

func _rect(box: Node, node_name: String) -> Rect2:
	var n := box.find_child(node_name, true, false) as Control
	return Rect2(n.position, n.size) if n != null else Rect2()

func _text_of(box: Node, node_name: String) -> String:
	var n := box.find_child(node_name, true, false)
	if n is LineEdit:
		return (n as LineEdit).text
	if n is Label:
		return (n as Label).text
	if n != null:
		var l := n.get_node_or_null("Text") as Label
		if l != null:
			return l.text
		l = n.get_node_or_null("ButtonLabel") as Label
		if l != null:
			return l.text
	return ""

func _check_buy() -> void:
	var box := _box(StoreMessageBox.Kind.BUY, {"name": "HP Recovery Potion (X-Large)", "count": 1, "max": 50, "unit_price": 600})
	# READ 0x7c3f70: the gold row adds 22 to the 327x155 window and its BG 4.
	_check(box.size == Vector2(327, 177), "buy: the box is 327x177 (got %s)" % box.size)
	_check(_rect(box, "GDR_ITEMMALL_CONFIRM_BUY_BG").size == Vector2(295, 128), "buy: background 4 grows to 295x128 (got %s)" % _rect(box, "GDR_ITEMMALL_CONFIRM_BUY_BG"))
	var row := box.get_node_or_null("PriceRow") as Control
	_check(row != null and row.position == Vector2(0, 100), "buy: the price row sits at y 100 (got %s)" % (row.position if row != null else "none"))
	_check(_text_of(box, "GDR_ITEMMALL_CONFIRM_STA_1") == "Price" and _text_of(box, "GDR_ITEMMALL_CONFIRM_STA_2") == "Gold",
		"buy: the row reads Price ... Gold")
	_check(_rect(box, "GDR_ITEMMALL_CONFIRM_BTN_BUY").position == Vector2(82, 137)
		and _rect(box, "GDR_ITEMMALL_CONFIRM_BTN_CANCEL").position == Vector2(170, 137),
		"buy: Buy at (82,137), Cancel at (170,137) (x+82 / x+170, y+h-40)")
	_check(_text_of(box, "GDR_ITEMMALL_CONFIRM_BTN_BUY") == "Buy" and _text_of(box, "GDR_ITEMMALL_CONFIRM_BTN_CANCEL") == "Cancel",
		"buy: the buttons read Buy / Cancel")
	_check(_text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT_ITEM_NAME") == "HP Recovery Potion (X-Large)", "buy: the item's name")
	_check(_text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT_COUNT") == "1" and _text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT") == "600",
		"buy: count 1, price 600 (got %s / %s)" % [_text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT_COUNT"), _text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT")])
	_check(_visible(box, "GDR_ITEMMALL_CONFIRM_SPINBTN_UP"), "buy: a stack shows its spin buttons")
	# The spin and the price arithmetic: unit x count, no separators.
	(box.find_child("GDR_ITEMMALL_CONFIRM_SPINBTN_UP", true, false) as BaseButton).pressed.emit()
	(box.find_child("GDR_ITEMMALL_CONFIRM_SPINBTN_UP", true, false) as BaseButton).pressed.emit()
	_check(box.count == 3 and _text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT") == "1800", "buy: two spins up: 3 for 1800 (got %d / %s)" % [box.count, _text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT")])
	box.set_count(0)
	_check(box.count == 1, "buy: the count stops at 1")
	box.set_count(99)
	_check(box.count == 50 and _text_of(box, "GDR_ITEMMALL_CONFIRM_EDIT") == "30000", "buy: the count stops at the stack, 50 for 30000")
	var edit := box.find_child("GDR_ITEMMALL_CONFIRM_EDIT_COUNT", true, false) as LineEdit
	edit.text = "12a"
	edit.text_changed.emit("12a")
	_check(box.count == 12 and edit.text == "12", "buy: a typed count keeps its digits (got %d '%s')" % [box.count, edit.text])
	var got := [-1]
	box.confirmed.connect(func(n: int) -> void: got[0] = n)
	(box.find_child("GDR_ITEMMALL_CONFIRM_BTN_BUY", true, false) as BaseButton).pressed.emit()
	_check(got[0] == 12 and box.is_queued_for_deletion() and not box.visible, "buy: Buy confirms 12 and the box closes")
	var single := _box(StoreMessageBox.Kind.BUY, {"name": "Sword", "count": 1, "max": 1, "unit_price": 900})
	_check(not _visible(single, "GDR_ITEMMALL_CONFIRM_SPINBTN_UP"), "buy: a single item hides its spin buttons (OURS)")
	single.queue_free()

func _check_store_confirm() -> void:
	var sell := _box(StoreMessageBox.Kind.SELL, {"name": "HP Recovery Potion", "count": 15, "max": 15, "unit_price": 148})
	_check(sell.size == Vector2(327, 175), "sell: the box is 327x175 (READ 0x63eb94)")
	_check(_text_of(sell, "Title") == "Confirmation window", "sell: titled Confirmation window")
	_check(_rect(sell, "GDR_MSGBOX_BG").size == Vector2(295, 119), "sell: the box's Create tile is (w-32, h-56) (got %s)" % _rect(sell, "GDR_MSGBOX_BG"))
	_check(_text_of(sell, "GDR_MBS_CONFIRM_BTN_SELL") == "Sell" and _text_of(sell, "GDR_MBS_CONFIRM_BTN_CANCEL") == "Cancel", "sell: Sell / Cancel")
	_check(_text_of(sell, "GDR_MBS_CONFIRM_EDIT_COUNT") == "15", "sell: a stack starts at its size")
	_check(_text_of(sell, "GDR_MBS_CONFIRM_EDIT_PRICE") == "2220", "sell: price 148 x 15 = 2220 (got %s)" % _text_of(sell, "GDR_MBS_CONFIRM_EDIT_PRICE"))
	_check(_visible(sell, "GDR_MBS_CONFIRM_SPINBTN_UP") and _visible(sell, "GDR_MBS_CONFIRM_SPINBTN_DOWN"), "sell: the purpose keeps the spins")
	(sell.find_child("GDR_MBS_CONFIRM_SPINBTN_DOWN", true, false) as BaseButton).pressed.emit()
	_check(sell.count == 14 and _text_of(sell, "GDR_MBS_CONFIRM_EDIT_PRICE") == "2072", "sell: one down: 14 for 2072")
	var cancelled := [false]
	sell.cancelled.connect(func() -> void: cancelled[0] = true)
	(sell.find_child("GDR_MBS_CONFIRM_BTN_CANCEL", true, false) as BaseButton).pressed.emit()
	_check(cancelled[0] and sell.is_queued_for_deletion(), "sell: Cancel closes the box")

	var dep := _box(StoreMessageBox.Kind.DEPOSIT, {"name": "Premium Silver Time (4 weeks)", "count": 1, "max": 1, "fixed_price": 0})
	_check(_text_of(dep, "GDR_MBS_CONFIRM_BTN_SELL") == "Deposit", "deposit: OK reads Deposit")
	_check(not _visible(dep, "GDR_MBS_CONFIRM_SPINBTN_UP") and not _visible(dep, "GDR_MBS_CONFIRM_SPINBTN_DOWN"),
		"deposit: the purpose hides the spins (READ, and the user's MKtR5Kd.png)")
	_check(_visible(dep, "GDR_MBS_CONFIRM_STA_PRICE") and _visible(dep, "GDR_MBS_CONFIRM_EDIT_ITEM_NAME"), "deposit: price label and name shown")
	_check(_text_of(dep, "GDR_MBS_CONFIRM_EDIT_PRICE") == "1", "deposit: a zero fee shows the original's floor, 1 (READ 0x63d676)")
	_check(_visible(dep, "GDR_MBS_CONFIRM_EDIT_COUNT") and _visible(dep, "GDR_MBS_CONFIRM_STA_COUNT"), "deposit: a stack keeps the quantity group")
	dep.queue_free()
	var single := _box(StoreMessageBox.Kind.DEPOSIT, {"name": "Blade", "count": 1, "max": 1, "fixed_price": 0, "stackable": false})
	_check(not _visible(single, "GDR_MBS_CONFIRM_EDIT_COUNT") and not _visible(single, "GDR_MBS_CONFIRM_STA_COUNT"),
		"deposit: an item that does not stack hides the count and Quantity (READ 0x63bc80(3))")
	single.queue_free()
	var wd1 := _box(StoreMessageBox.Kind.WITHDRAW, {"name": "Blade", "count": 1, "max": 1, "fixed_price": 0, "stackable": false})
	_check(not _visible(wd1, "GDR_MBS_CONFIRM_EDIT_COUNT") and not _visible(wd1, "GDR_MBS_CONFIRM_STA_COUNT"),
		"withdraw: an item that does not stack hides the quantity group")
	wd1.queue_free()
	var sell1 := _box(StoreMessageBox.Kind.SELL, {"name": "Blade", "count": 1, "max": 1, "unit_price": 10, "stackable": false})
	_check(_visible(sell1, "GDR_MBS_CONFIRM_EDIT_COUNT"), "sell: the group stays for an item that does not stack (the sell fill has no 0x63bc80(3))")
	sell1.queue_free()
	var taxed := _box(StoreMessageBox.Kind.SELL, {"name": "x", "count": 15, "max": 15, "unit_price": 148, "tax_rate": 0.1})
	_check(taxed.price_text() == "1998", "sell: P - ftol(P x rate): 2220 - 222 = 1998 (got %s)" % taxed.price_text())
	taxed.queue_free()

	var wd := _box(StoreMessageBox.Kind.WITHDRAW, {"name": "Premium Silver Time (4 weeks)", "count": 3, "max": 3, "fixed_price": 0})
	_check(_text_of(wd, "GDR_MBS_CONFIRM_BTN_SELL") == "Take", "withdraw: OK reads Take (UIIT_STT_WITHDRAW)")
	_check(not _visible(wd, "GDR_MBS_CONFIRM_SPINBTN_UP"), "withdraw: spins hidden")
	_check(not _visible(wd, "GDR_MBS_CONFIRM_STA_PRICE") and not _visible(wd, "GDR_MBS_CONFIRM_EDIT_ITEM_NAME"),
		"withdraw: the price label and the name hidden (READ 0x63ee85..0x63ee9f)")
	wd.queue_free()

	var bb := _box(StoreMessageBox.Kind.BUY_BACK, {"name": "x", "count": 1, "max": 1, "unit_price": 10})
	_check(_text_of(bb, "GDR_MBS_CONFIRM_BTN_SELL") == "Buy back" and not _visible(bb, "GDR_MBS_CONFIRM_SPINBTN_UP"),
		"buy back: OK reads Buy back, spins hidden")
	_check(bb.price_text() == "10", "buy back: count x the sell price (got %s)" % bb.price_text())
	bb.queue_free()
	var bb3 := _box(StoreMessageBox.Kind.BUY_BACK, {"name": "x", "count": 3, "max": 3, "unit_price": 210})
	_check(bb3.price_text() == "630", "buy back: 3 x 210 = 630 (got %s)" % bb3.price_text())
	bb3.queue_free()
	# Round 728: the fee a unit (+0xcc, KeepingFee) times the count, floored at 1.
	var fee := _box(StoreMessageBox.Kind.DEPOSIT, {"name": "x", "count": 5, "max": 5, "unit_price": 11})
	_check(fee.price_text() == "55", "deposit: 5 x a fee of 11 = 55 (got %s)" % fee.price_text())
	fee.queue_free()
	var free_fee := _box(StoreMessageBox.Kind.DEPOSIT, {"name": "x", "count": 5, "max": 5, "unit_price": 0})
	_check(free_fee.price_text() == "1", "deposit: a zero fee still shows 1 (got %s)" % free_fee.price_text())
	free_fee.queue_free()

## Round 728: the split box, MsgBoxDivideCount (0x640020, 0x6b3fa0).
func _check_divide() -> void:
	var d := _box(StoreMessageBox.Kind.DIVIDE, {"name": "Vigor Recovery Grain (Small)", "stack": 5000, "count": 1, "min": 0, "max": 4999})
	_check(d.size == Vector2(300, 183), "divide: 300x183 (READ 0x6400c8), got %s" % d.size)
	_check(_text_of(d, "Title") == "Input window" or _text_of(d, "Title") == "UIIT_STT_INPUT_BOX", "divide: titled Input window (got %s)" % _text_of(d, "Title"))
	_check(_text_of(d, "GDR_MBDC_STATIC_CURRENT_AMOUNT") == "5000", "divide: retained 5000")
	_check(_text_of(d, "GDR_MBDC_STATIC_DIVIDE_AMOUNT_EDIT") == "1", "divide: the edit opens at 1 (0xd87bdc)")
	_check(_text_of(d, "GDR_MBDC_STATIC_NAMEBOARD") == "Vigor Recovery Grain (Small)", "divide: the name on the board")
	var got := [-1]
	d.confirmed.connect(func(q: int) -> void: got[0] = q)
	var edit := d.find_child("GDR_MBDC_STATIC_DIVIDE_AMOUNT_EDIT", true, false) as LineEdit
	edit.text = "9000"
	edit.text_changed.emit("9000")
	_check(d.count == 4999, "divide: held to stack - 1 (0x634f20), got %d" % d.count)
	edit.text = "250"
	(d.find_child("GDR_MBDC_BTN_OK", true, false) as BaseButton).pressed.emit()
	_check(got[0] == 250, "divide: OK hands back 250, got %d" % got[0])
	var e := _box(StoreMessageBox.Kind.DIVIDE, {"stack": 3, "count": 1, "min": 0, "max": 2})
	var got0 := [-1]
	e.confirmed.connect(func(q: int) -> void: got0[0] = q)
	(e.find_child("GDR_MBDC_STATIC_DIVIDE_AMOUNT_EDIT", true, false) as LineEdit).text = ""
	(e.find_child("GDR_MBDC_BTN_OK", true, false) as BaseButton).pressed.emit()
	_check(got0[0] == 0, "divide: an empty edit gives 0 (the 0x8076 flag), got %d" % got0[0])

	# The digit label (ItemCountLabel, FUN_0067bd70).
	_check(ItemCountLabel.digit_xs(1) == [2], "count: one digit at x0+2, got %s" % [ItemCountLabel.digit_xs(1)])
	_check(ItemCountLabel.digit_xs(4) == [-1, 4, 9, 14], "count: 4 digits from x0-1, pitch 5, got %s" % [ItemCountLabel.digit_xs(4)])
	_check(ItemCountLabel.shows_count([3, 3, 1, 1], false, 1), "count: an expendable shows even 1")
	_check(not ItemCountLabel.shows_count([1, 6, 1, 1], false, 1) and not ItemCountLabel.shows_count([3, 3, 1, 1], true, 5),
		"count: equipment and bionic show none")

	# The buy-back codecs (shop.gd), against the Go encoding's bytes.
	var bytes := PackedByteArray([0, 0, 1])
	var ent := PackedByteArray(); ent.resize(20)
	ent.encode_s64(0, 7); ent.encode_u32(8, 3); ent.encode_s64(12, 210)
	bytes.append_array(ent)
	var list := ShopNet.decode_buyback_list(bytes)
	_check(list.error == "" and list.entries.size() == 1 and list.entries[0].item_id == 7 and list.entries[0].quantity == 3 \
		and list.entries[0].unit == 210, "buy back: the list decodes")
	var req := ShopNet.encode_buyback("Aria", 4)
	_check(req.size() == 2 + 4 + 4 and req.decode_u16(0) == 4 and req.decode_u32(6) == 4, "buy back: the request encodes")

func _check_money() -> void:
	var g := _box(StoreMessageBox.Kind.GOLD_DEPOSIT, {"count": 0, "min": 0, "max": 5000})
	_check(_text_of(g, "GDR_MBS_EDIT_AMOUNT") == "0", "gold: the amount opens at 0 (READ 0x6b28c8)")
	_check(not _visible(g, "GDR_MBS_STATIC_AMOUNT"), "gold: Unit (ID 4) hidden (READ 0x6b28a8)")
	g.set_count(-3)
	_check(g.count == 0, "gold: no minimum but 0 (got %d)" % g.count)
	g.set_count(9000)
	_check(g.count == 5000, "gold: held to the maximum")
	_check(g.size == Vector2(308, 148), "gold: the box is 308x148 (READ 0x6af55f)")
	_check(_text_of(g, "GDR_MBS_STATIC_NAME1") == "Deposit" and _text_of(g, "GDR_MBS_BTN_OK") == "Deposit", "gold deposit: NAME1 and OK read Deposit")
	_check(not _visible(g, "GDR_MBS_STATIC_PRICET1") and not _visible(g, "GDR_MBS_STATIC_NAME2") and not _visible(g, "GDR_MBS_STATIC_PRICE"),
		"gold: IDs 8, 9 and 2 hidden")
	# The rect the settling pass holds it to (a font-less test cannot lay a
	# LineEdit out below Godot's default line height).
	var amount_rect: Rect2 = (g.find_child("GDR_MBS_EDIT_AMOUNT", true, false) as Control).get_meta(UiBuilder.AUTHORED_RECT_META, Rect2())
	_check(amount_rect == Rect2(121, 66, 121, 24), "gold: the amount edit moved to (121,66) 121x24 (got %s)" % amount_rect)
	var edit := g.find_child("GDR_MBS_EDIT_AMOUNT", true, false) as LineEdit
	edit.text = "250"
	edit.text_changed.emit("250")
	var got := [-1]
	g.confirmed.connect(func(n: int) -> void: got[0] = n)
	(g.find_child("GDR_MBS_BTN_OK", true, false) as BaseButton).pressed.emit()
	_check(got[0] == 250 and g.is_queued_for_deletion(), "gold: OK moves the typed 250 once and closes")
	var w := _box(StoreMessageBox.Kind.GOLD_WITHDRAW, {"count": 1, "max": 10})
	_check(_text_of(w, "GDR_MBS_STATIC_NAME1") == "Taken" and _text_of(w, "GDR_MBS_BTN_OK") == "Take", "gold withdraw: NAME1 Taken, OK Take")
	w.queue_free()

## Where each box appears (READ 0x798b70): ConfirmBuy centred at its own
## 327x177; the inventory's boxes at the corner their 308x148 creation was
## centred to, whatever size the purpose then gives them.
func _check_placement() -> void:
	var screen := Vector2(1280, 720)
	var b := _box(StoreMessageBox.Kind.BUY, {"count": 1, "max": 50, "unit_price": 60})
	_check(b.screen_position(screen) == Vector2(640 - 163, 360 - 88), "placement: the buy box centred at 327x177 -> (477,272) (got %s)" % b.screen_position(screen))
	var s := _box(StoreMessageBox.Kind.SELL, {"count": 1, "max": 1, "unit_price": 10})
	_check(s.screen_position(screen) == Vector2(640 - 154, 360 - 74), "placement: the sell box at the 308x148 creation's corner (486,286) (got %s)" % s.screen_position(screen))
	var g := _box(StoreMessageBox.Kind.GOLD_WITHDRAW, {"count": 1, "max": 10})
	_check(g.screen_position(Vector2(1353, 823)) == Vector2(676 - 154, 411 - 74), "placement: integer halves on an odd screen (got %s)" % g.screen_position(Vector2(1353, 823)))
	for box in [b, s, g]:
		box.queue_free()

## The gestures, through HudPanels with its network calls recorded.
const RECORDER := """
extends "res://scripts/ui/hud/hud_panels.gd"
var bought := []
var sold := []
func _do_buy(item_id: int, quantity: int = 1) -> void:
	bought.append([item_id, quantity])
func _do_sell(slot: int, quantity: int) -> void:
	sold.append([slot, quantity])
"""

func _check_gestures() -> void:
	var script := GDScript.new()
	script.source_code = RECORDER
	_check(script.reload() == OK, "the recording HudPanels compiles")
	var panels = script.new()
	panels.set("_items_loaded", true)
	var item := ItemTableReader.Item.new()
	item.id = 7
	item.max_stack = 50
	item.sell_price = 148
	(panels.get("_items") as Dictionary)[7] = item
	(panels.get("_shop_prices") as Dictionary)[7] = 600
	panels.set("_builder", StoreBoxFixture.builder())
	root.add_child(panels)
	var store := HudWindow.new()
	store.name = "store"
	store.size = Vector2(254, 370)
	panels.add_child(store)
	(panels.get("_windows") as Dictionary)["store"] = store
	var icon := TextureRect.new()
	icon.set_meta("shop_item_id", 7)
	var ctrl_release := InputEventMouseButton.new()
	ctrl_release.button_index = MOUSE_BUTTON_LEFT
	ctrl_release.pressed = false
	ctrl_release.ctrl_pressed = true
	panels.call("_on_shop_cell_input", ctrl_release, icon)
	_check((panels.get("bought") as Array) == [[7, 50]], "ctrl+click on a good buys its stack with no box (got %s)" % str(panels.get("bought")))
	_check(store.get_node_or_null("BuyConfirm") == null, "ctrl+click opens no box")
	var plain := InputEventMouseButton.new()
	plain.button_index = MOUSE_BUTTON_LEFT
	plain.pressed = false
	_check(not panels.call("_is_ctrl_click_on", plain, icon), "a plain click is not a ctrl+click")
	# A good put down on the bag opens the buy box (CIFInventory::vslot_028).
	panels.call("_confirm_buy", 7)
	var buy := store.get_node_or_null("BuyConfirm") as StoreMessageBox
	_check(buy != null and buy.kind == StoreMessageBox.Kind.BUY and buy.max_count == 50, "a good on the bag opens the buy box")
	if buy != null:
		buy.set_count(4)
		(buy.find_child("GDR_ITEMMALL_CONFIRM_BTN_BUY", true, false) as BaseButton).pressed.emit()
		_check((panels.get("bought") as Array).back() == [7, 4], "Buy sends the count (got %s)" % str((panels.get("bought") as Array).back()))
	# Ctrl+click on a bag item with the store open sells the stack.
	var bag_icon := TextureRect.new()
	bag_icon.set_meta("inv_slot", 3)
	bag_icon.set_meta("inv_item_id", 7)
	bag_icon.set_meta("inv_qty", 15)
	store.show()
	panels.call("_on_inventory_cell_input", ctrl_release, bag_icon)
	_check((panels.get("sold") as Array) == [[3, 15]], "ctrl+click on a bag item with the store open sells the stack (got %s)" % str(panels.get("sold")))
	panels.call("_confirm_sell", 3, 7, 15)
	var sell := store.get_node_or_null("SellConfirm") as StoreMessageBox
	_check(sell != null and sell.count == 15 and sell.price_text() == "2220", "a bag item on the store opens the sell box, stack 15 for 2220")
	# The slot no longer holds the item: Sell sends nothing.
	(panels.get("sold") as Array).clear()
	if sell != null:
		(sell.find_child("GDR_MBS_CONFIRM_BTN_SELL", true, false) as BaseButton).pressed.emit()
	_check((panels.get("sold") as Array).is_empty(), "Sell on a slot that no longer holds the item sends nothing")
	# It does: Sell sends.
	var entry := BagEntry.new()
	entry.slot = 3
	entry.item_id = 7
	entry.count = 15
	panels.set("_bag_slots", [entry])
	panels.call("_confirm_sell", 3, 7, 15)
	sell = store.get_node_or_null("SellConfirm") as StoreMessageBox
	if sell != null:
		(sell.find_child("GDR_MBS_CONFIRM_BTN_SELL", true, false) as BaseButton).pressed.emit()
	_check((panels.get("sold") as Array) == [[3, 15]], "Sell on a slot still holding the item sends it (got %s)" % str(panels.get("sold")))
	# One inventory box at a time, across the store and the warehouse.
	var storage := HudWindow.new()
	storage.name = "storage"
	storage.size = Vector2(254, 370)
	panels.add_child(storage)
	(panels.get("_windows") as Dictionary)["storage"] = storage
	panels.call("_confirm_sell", 3, 7, 15)
	panels.call("_confirm_deposit", 3, 7, 15)
	_check(store.get_node_or_null("SellConfirm") == null and storage.get_node_or_null("DepositConfirm") != null,
		"a deposit box closes the store's sell box (one CIFInventory +0x390)")
	panels.call("_open_gold_box", true)
	_check(storage.get_node_or_null("DepositConfirm") == null and storage.get_node_or_null("GoldDialog") != null,
		"the gold box closes the deposit box")
	panels.call("_confirm_buy", 7)
	_check(store.get_node_or_null("BuyConfirm") != null and storage.get_node_or_null("GoldDialog") != null,
		"the buy box is a separate object and closes nothing")
	# A cash item is refused a Ctrl+click quick-sell.
	var cash := ItemTableReader.Item.new()
	cash.id = 9
	cash.cash_item = 1
	cash.type_ids = PackedInt32Array([3, 3, 1, 1])
	(panels.get("_items") as Dictionary)[9] = cash
	var e9 := BagEntry.new()
	e9.slot = 4
	e9.item_id = 9
	e9.count = 1
	panels.set("_bag_slots", [e9])
	(panels.get("sold") as Array).clear()
	var notices := []
	panels.system_notice.connect(func(t: String) -> void: notices.append(t))
	panels.call("_ctrl_sell", 4, 1)
	_check((panels.get("sold") as Array).is_empty() and notices.size() == 1, "ctrl+click does not quick-sell a cash item, and says so (READ 0x6813f3)")
	_check(panels.call("is_stack_item", cash) and not panels.call("is_stack_item", ItemTableReader.Item.new()), "the stack test: TypeID1 3, TypeID2 3, not bionic")
	panels.queue_free()

## A bag list entry as the server's list hands it over (the fields
## HudPanels._first_field looks for).
class BagEntry:
	var slot := 0
	var item_id := 0
	var count := 0

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 1:
		_check_buy()
		_check_store_confirm()
		_check_money()
		_check_divide()
		_check_placement()
		_check_gestures()
	elif _frame == 3:
		if _failures == 0:
			print("ALL PASS")
		else:
			print("%d FAILED" % _failures)
		quit(1 if _failures > 0 else 0)
		return true
	return false
