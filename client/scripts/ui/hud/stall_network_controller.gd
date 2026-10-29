extends RefCounted
class_name StallNetworkController

## Round 840 (lane N): the stall network's window life and wire
## (docs/protocol/stall_network.md; c: sro_client.exe, READ unless marked).
##
## - Open (FUN_00799020(1), c:0x799020): nothing while the world takes no
##   input (0x77c8e0); outside a town category 10 0x3c49 (the town test is
##   CRegionManagerBody slot 23 c:0x414560: the position's regioninfo claim
##   is kind 2, #TOWN); nothing while this player's own stall window
##   (GDR_STALL, 0x21) exists; else `res_ui\stallnetwork.2dt` loaded as window
##   0x96 and centred (0x798c50). OURS: the underbar's item 120 reaches it
##   (retail hides the item, c:0x60e2cd); a second press brings it forward.
## - Close (0x799020(0), from the window's X vslot_043 c:0x6bc6b0): 0x7462 when
##   a mode-1 search went out (0xeea828), the flag cleared, the window
##   destroyed (0x468c50).
## - 0xB461 (c:0x88dca0): a refusal shows its code (category 10); 0x3c49 also
##   clears the flags and closes the window without 0x7462 (c:0x88de71..).
## - 0xB463 (c:0x88dec0): {1} the bought row out of its page and the item into
##   the bag (OURS, as round 839: the bag list asked again); a refusal its code.
## - Whisper (c:0x6bf560): the chat line set to "$seller ".

## The window the client loads it as (0x799020's FUN_00469140 id).
const WINDOW_ID := 0x96

var panels
## NetClient, or a test's stand-in.
var net = null
var window: StallNetworkWindow = null
var box: StallNetworkBox = null
## The record a buy went out for (0xeea850).
var pending: StallNetworkNet.Record = null

func _init(hud_panels) -> void:
	panels = hud_panels

func _net():
	if net != null:
		return net
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("/root/NetClient") if tree != null else null

func is_open() -> bool:
	return window != null and is_instance_valid(window)

## 0x799020(1); `in_town` is the caller's town test, `busy` 0x77c8e0's.
func open(in_town: bool, busy: bool) -> String:
	if is_open():
		window.show()
		window.move_to_front()
		return "already open"
	if busy:
		return "busy"
	if not in_town:
		panels.stall_network_code(StallNetworkNet.CODE_USE_CITY)
		return "refused: not in a town"
	if panels.stall_window_shown():
		return "the own stall window is open"
	var w := StallNetworkWindow.new(panels._builder)
	w.name = "Window_stallnetwork"
	panels.add_child(w)
	if not w.build_window():
		panels.remove_child(w)
		w.queue_free()
		print("StallNetwork: %s did not build" % StallNetworkWindow.FILE_2DT)
		return "no window"
	window = w
	w.item_icon = func(ref: int) -> Texture2D: return panels._item_icon(ref)
	w.item_name = func(ref: int) -> String: return panels.item_name(ref)
	w.repairable = func(it) -> bool: return panels.stall_network_repairable(it)
	w.search_requested.connect(_on_search_requested)
	w.buy_requested.connect(_on_buy_requested)
	w.whisper_requested.connect(func(seller: String) -> void: panels._party_match_whisper(seller))
	w.closed.connect(close)
	w.on_create(panels.stall_network_tree(), panels.stall_window_shown(), panels.carried_gold())
	w.show()
	w.place_centred()
	w.move_to_front()
	_make_box()
	print("StallNetwork: window opened (%s)" % StallNetworkWindow.FILE_2DT)
	return "opened"

## Round 841 (lane K): the stall network's key (KeyMap slot 33, OURS, default
## F). With the window up it closes it, 0x799020(0) (close(): 0x7462 when a
## search went out); otherwise it is item 120's open, 0x799020(1), with its
## town rule and refusal. The toggle is INFERRED from the retail keys for
## windows the menu only opens (Y: window 0xa8 there -> 0x798e20(0), else
## 0x798e20(1), READ 0x780a65..0x780a8c).
func toggle(in_town: bool, busy: bool) -> String:
	if is_open():
		close()
		return "closed"
	return open(in_town, busy)

## The buy box, loaded hidden with the window (c:0x6c5140's window 300).
func _make_box() -> void:
	var b := StallNetworkBox.new(panels._builder)
	b.name = "StallNetworkBox"
	if not b.build_box():
		b.queue_free()
		return
	b.visible = false
	panels.add_child(b)
	b.confirmed.connect(_on_buy_confirmed)
	box = b

## 0x799020(0).
func close() -> void:
	var n = _net()
	if is_open() and window.entered and n != null:
		n.stall_net_leave()
	_drop()

func _drop() -> void:
	if is_open():
		if window.get_parent() != null:
			window.get_parent().remove_child(window)
		window.queue_free()
	window = null
	if box != null and is_instance_valid(box):
		if box.get_parent() != null:
			box.get_parent().remove_child(box)
		box.queue_free()
	box = null
	pending = null

func _on_search_requested(mode: int, page: int, group: int, degree: int) -> void:
	var n = _net()
	if n != null:
		n.stall_net_search(mode, page, group, degree)
	print("StallNetwork: 0x7461 mode %d page %d group %d degree %d" % [mode, page, group, degree])

## 0xB461.
func on_searched(d: Dictionary) -> void:
	var code := int(d.get("code", -1))
	if code != 1:
		panels.stall_network_code(code)
		if code == StallNetworkNet.CODE_USE_CITY and is_open():
			window.entered = false
			_drop()
		return
	if is_open():
		window.on_result(d)
		print("StallNetwork: 0xB461 page %d: %d record(s) of %d page(s)" % [window.page,
			(d.get("records", []) as Array).size(), int(d.get("pages", 0))])

## Purchase -> the buy box (c:0x6c83b0).
func _on_buy_requested(r: StallNetworkNet.Record) -> void:
	if box == null or not is_instance_valid(box):
		return
	box.show_record(r, panels._item_icon(r.item.ref_item_id), panels.item_name(r.item.ref_item_id))
	box.place_centred()

## Buy (c:0x6c7c20): 0x7463 with the record.
func _on_buy_confirmed(r: StallNetworkNet.Record) -> void:
	pending = r
	var n = _net()
	if n != null:
		n.stall_net_buy(r)
	print("StallNetwork: 0x7463 owner %d slot %d price %d count %d" % [r.owner, r.slot, r.price, r.count])

## 0xB463.
func on_bought(code: int) -> void:
	if code != 1:
		panels.stall_network_code(code)
		pending = null
		return
	if is_open() and pending != null:
		window.remove_record(pending)
	pending = null
	panels.refresh_bag_after_exchange()
	if is_open():
		window.set_gold(panels.carried_gold())

## The gold changed (0x304E): the window's gold line (c:0x6becb0 runs at
## every gold update the window hears, INFERRED).
func gold_changed(gold: int) -> void:
	if is_open():
		window.set_gold(gold)
