extends SceneTree

## Round 631: this client's own confirm boxes on the store and the warehouse
## (buy, sell, deposit/withdraw, the warehouse gold dialog) must not free
## themselves from inside their own button's `pressed`. Each box is an
## ancestor of its buttons, so a synchronous free() deleted the Button while
## BaseButton was still emitting and the Viewport still routing the click. A
## real X click on Sell (Login -> CharacterSelect route, render box) printed
## "~Object: ... freed ... while a signal is being emitted" and then
## "Program crashed with signal 11" on dev cfddf39.
##
##   (a) Every action and Cancel/Close button of the four boxes, pressed
##       through its connected handler: the button survives the call, and the
##       box is hidden and queued for deletion instead.
##   (b) The totals line of the buy and sell boxes is filled (the refresh
##       lambda called the static _grouped unqualified: "Nonexistent function
##       '_grouped' in base 'Nil'", measured in the same real-input run).
##   (c) A click on Sell pushed through the live viewport (press + release,
##       the OS path): the process survives it, and the box is gone a frame
##       later.
##   (e) Round 631 review: a box does not outlive its window. Hiding the
##       store (Escape, its X, close()) closes its sell box, so showing it
##       again shows no stale box that would sell whatever has since moved
##       into the captured bag slot; open_shop / open_storage reusing the
##       window for a new NPC drop any box too.
##   (f) Round 631 review: the gold dialog closes on Deposit / Withdraw, as
##       retail's MsgBoxStoreMoney closes on OK, so a double click cannot
##       move the amount twice.
##   (d) The store's and the warehouse's authored slot controls
##       (GDR_STORE_SLOT_100.. / GDR_STORAGE_SLOT_100.., ifstore.txt /
##       ifstorageroom.txt) sit on their lattice cells and come later in the
##       tree; a click on a good must still reach the cell's ItemIcon, which
##       is what opens the buy / withdraw box. Measured on a synthetic window
##       laid out like the authored one (slot 100 at 21,71,32,32).
##
## Synthetic item only, no archive:
##   godot4 --headless --path client --script res://scripts/ui/hud/confirm_box_test.gd

var _failures := 0
var _panels: Node
var _store: HudWindow
var _frame := 0
var _live_box: Control
var _live_button: BaseButton

const ITEM_ID := 7

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Round 726: the boxes are the client's own (StoreMessageBox), their
## buttons TextureButtons captioned by a ButtonLabel.
func _find_button(node: Node, text: String) -> BaseButton:
	if node is BaseButton:
		var l := node.get_node_or_null("ButtonLabel") as Label
		if (node is Button and (node as Button).text == text) or (l != null and l.text == text):
			return node as BaseButton
	for child in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null

func _find_label_prefix(node: Node, prefix: String) -> Label:
	if node is Label and (node as Label).text.begins_with(prefix):
		return node as Label
	for child in node.get_children():
		var found := _find_label_prefix(child, prefix)
		if found != null:
			return found
	return null

## Runs a button's connected handlers the way its `pressed` emission would,
## without emitting (an emission from a freed Button is the crash itself).
func _press_handlers(button: BaseButton) -> void:
	for c in button.pressed.get_connections():
		(c["callable"] as Callable).call()

func _window(window_name: String) -> HudWindow:
	var w := HudWindow.new()
	w.name = window_name
	w.size = Vector2(400, 400)
	_panels.add_child(w)
	(_panels.get("_windows") as Dictionary)[window_name] = w
	return w

func _item() -> ItemTableReader.Item:
	var item := ItemTableReader.Item.new()
	item.id = ITEM_ID
	item.code_name = "ITEM_QA_SYNTHETIC"
	item.max_stack = 50
	item.sell_price = 148
	return item

## (a) One box: open it, press `button_text`, then check the button outlived
## its own handler and the box is on its way out.
func _check_press(label: String, box_name: String, window: HudWindow, open: Callable, button_text: String) -> void:
	open.call()
	var box := window.get_node_or_null(box_name) as Control
	_check(box != null, "%s: the %s box opens" % [label, box_name])
	if box == null:
		return
	var button := _find_button(box, button_text)
	_check(button != null, "%s: the box has a %s button" % [label, button_text])
	if button == null:
		return
	_press_handlers(button)
	# NEGATIVE (fails on dev cfddf39: the handler freed the box, and the
	# button with it, while the button was the one emitting).
	_check(is_instance_valid(button), "%s: the %s button is not freed by its own press" % [label, button_text])
	_check(is_instance_valid(box) and box.is_queued_for_deletion() and not box.visible,
		"%s: %s closes by hiding and queue_free" % [label, box_name])

func _initialize() -> void:
	pass

## (a) and (b), on the first frame, once the root is in the tree (the boxes
## wait a frame to centre themselves and read the tree for their sounds).
func _build_and_press() -> void:
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var compiled := panels_script != null and panels_script.can_instantiate()
	_check(compiled, "HudPanels compiles")
	if not compiled:
		return
	_panels = panels_script.new()
	_panels.set("_items_loaded", true)
	_panels.set("_builder", StoreBoxFixture.builder())
	(_panels.get("_items") as Dictionary)[ITEM_ID] = _item()
	(_panels.get("_shop_prices") as Dictionary)[ITEM_ID] = 600
	root.add_child(_panels)
	_store = _window("store")
	var storage := _window("storage")

	# (b) the price fields, read before any box is closed (round 726: the
	# client's own Price field, unit x count).
	_panels.call("_confirm_buy", ITEM_ID)
	var buy_box := _store.get_node_or_null("BuyConfirm") as StoreMessageBox
	_check(buy_box != null and buy_box.price_text() == "600",
		"the buy box shows its price (%s)" % (buy_box.price_text() if buy_box != null else "no box"))
	_panels.call("_confirm_sell", 3, ITEM_ID, 15)
	var sell_box := _store.get_node_or_null("SellConfirm") as StoreMessageBox
	_check(sell_box != null and sell_box.price_text() == "2220",
		"the sell box shows what it pays for the stack (%s)" % (sell_box.price_text() if sell_box != null else "no box"))

	# (a) every close path of the four boxes.
	var buy := func() -> void: _panels.call("_confirm_buy", ITEM_ID)
	var sell := func() -> void: _panels.call("_confirm_sell", 3, ITEM_ID, 15)
	var deposit := func() -> void: _panels.call("_confirm_deposit", 4, ITEM_ID, 15)
	var withdraw := func() -> void: _panels.call("_confirm_withdraw", 5, ITEM_ID, 15)
	var gold := func() -> void: _panels.call("_open_gold_dialog")
	_check_press("buy", "BuyConfirm", _store, buy, "Buy")
	_check_press("buy", "BuyConfirm", _store, buy, "Cancel")
	_check_press("sell", "SellConfirm", _store, sell, "Sell")
	_check_press("sell", "SellConfirm", _store, sell, "Cancel")
	_check_press("deposit", "DepositConfirm", storage, deposit, "Deposit")
	_check_press("deposit", "DepositConfirm", storage, deposit, "Cancel")
	_check_press("withdraw", "WithdrawConfirm", storage, withdraw, "Take")
	_check_press("withdraw", "WithdrawConfirm", storage, withdraw, "Cancel")
	_check_press("gold", "GoldDialog", storage, gold, "Cancel")
	# (f) NEGATIVE (fails on dev cfddf39: the dialog stayed up on Deposit
	# and Withdraw, and a second click sent the amount again). Round 726:
	# one box per direction, Deposit from the bag's button, Take from the
	# warehouse's.
	_check_press("gold", "GoldDialog", storage, gold, "Deposit")
	var gold_out := func() -> void: _panels.call("_open_gold_withdraw")
	_check_press("gold", "GoldDialog", storage, gold_out, "Take")

	# (e) the window closing takes its boxes with it.
	for pair in [[_store, "SellConfirm", sell], [_store, "BuyConfirm", buy],
			[storage, "DepositConfirm", deposit], [storage, "WithdrawConfirm", withdraw],
			[storage, "GoldDialog", gold]]:
		var host: HudWindow = pair[0]
		(pair[2] as Callable).call()
		var box := host.get_node_or_null(pair[1]) as Control
		host.hide()
		# NEGATIVE (fails on dev cfddf39: hiding only hid the window).
		_check(box != null and (not is_instance_valid(box) or box.is_queued_for_deletion()),
			"hiding its window closes %s" % pair[1])
		host.show()
		var again := host.get_node_or_null(pair[1]) as Control
		_check(again == null, "showing the window again shows no stale %s" % pair[1])
	# open_shop reusing an open store for another NPC.
	sell.call()
	var stale := _store.get_node_or_null("SellConfirm") as Control
	if _panels.has_method("_close_window_boxes"):
		_panels.call("_close_window_boxes", _store)
	_check(_panels.has_method("_close_window_boxes") and stale != null and stale.is_queued_for_deletion(),
		"_close_window_boxes (called by open_shop / open_storage) closes a box left on the window")

## (c) the OS path, over a few frames: the box needs a frame to lay out.
func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 1:
		_build_and_press()
		if _panels == null:
			return _finish()
	elif _frame == 2:
		# (d) before (c): on dev cfddf39, (c) ends the process.
		_check_lattice_clicks("GDR_STORE_SLOT_")
		_check_lattice_clicks("GDR_STORAGE_SLOT_")
	elif _frame == 3:
		# The warehouse window was added after the store and covers it.
		(_panels.get("_windows") as Dictionary)["storage"].hide()
		_panels.call("_confirm_sell", 3, ITEM_ID, 15)
		_live_box = _store.get_node_or_null("SellConfirm") as Control
		_check(_live_box != null, "(c) a fresh sell box opens")
	elif _frame == 6:
		if _live_box == null:
			return _finish()
		_live_button = _find_button(_live_box, "Sell")
		var at := _live_button.get_global_rect().get_center()
		print("    (c) Sell at %s, box %s" % [at, _live_box.get_global_rect()])
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = pressed
			ev.position = at
			ev.global_position = at
			root.push_input(ev, true)
		# Reaching this line is part of the check: on dev cfddf39 a click here
		# can end the process with signal 11.
		_check(true, "(c) the process survives a click on Sell through the viewport")
		_check(not is_instance_valid(_live_box) or not _live_box.visible, "(c) the click reached Sell: the box is closing")
	elif _frame == 8:
		_check(not is_instance_valid(_live_box), "(c) the clicked box is gone a frame later")
		return _finish()
	return false

## (d) A window shaped like ifstore/ifstorageroom: a lattice cell with its
## ItemIcon (STOP, as _fill_shop_grid sets it), then the authored slot over
## it (PASS, as UiBuilder._build_slot builds every slot).
func _check_lattice_clicks(prefix: String) -> void:
	var w := HudWindow.new()
	w.position = Vector2(600, 20)
	w.size = Vector2(260, 300)
	w.panel_root = Control.new()
	w.panel_root.size = w.size
	w.add_child(w.panel_root)
	var cell := Control.new()
	cell.mouse_filter = Control.MOUSE_FILTER_PASS
	cell.position = Vector2(21, 71)
	cell.size = Vector2(32, 32)
	var icon := TextureRect.new()
	icon.name = "ItemIcon"
	icon.mouse_filter = Control.MOUSE_FILTER_STOP
	icon.size = Vector2(32, 32)
	cell.add_child(icon)
	w.panel_root.add_child(cell)
	var slot := Control.new()
	slot.name = prefix + "100"
	slot.mouse_filter = Control.MOUSE_FILTER_PASS
	slot.position = Vector2(21, 71)
	slot.size = Vector2(32, 32)
	w.panel_root.add_child(slot)
	_panels.add_child(w)
	var hits: Array = []
	icon.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			hits.append(ev))
	var has := _panels.has_method("_lattice_takes_clicks")
	# NEGATIVE (fails on dev cfddf39: no such step, and the click stops at
	# the slot).
	_check(has, "HudPanels has _lattice_takes_clicks")
	if has:
		_panels.call("_lattice_takes_clicks", w, prefix)
	var at := icon.get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		root.push_input(ev, true)
	_check(hits.size() == 1, "(d) a click on the first good under %s100 reaches its ItemIcon (%d press(es))" % [prefix, hits.size()])
	w.free()

func _finish() -> bool:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
	return true
