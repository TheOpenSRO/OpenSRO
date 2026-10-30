extends SceneTree

## Round 843 (lane P): Magic POP's own bag pane against the real Media.pk2
## (docs/protocol/magic_pop.md §3a). The original (CIFGhaCha, c:0x749560,
## c:0x748790, c:0x747a40, c:0x749030, c:0x749a30) builds a page tab per bag
## page and a cell per bag slot, and takes a card put down from any page:
## a page-1 card only on the card slot, a page-2 or page-3 card anywhere in
## the window (c:0x7478c0 checks the first 32 cells only).
##
## Driven through the viewport (push_input): the tabs, the pick-up click on a
## cell and the put-down click go where Godot's hit-testing and HudPanels'
## held icon send them, as a player's clicks do.
##
## NEGATIVE: before round 843 the pane has no tabs and only the first 32
## cells, so the page-2 and page-3 checks fail (no tab_of / cell_of).
##   godot4 --headless --path client --script res://scripts/ui/hud/gacha843_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const CARD := 9238
const COUPON_LOSE := 9240
const SIZE := 80

var _failures := 0
var _panels: Control
var _win: GachaWindow
var _bag: Array = []
var _sent: Array = []

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(240.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _slot(index: int, item_id: int, quantity: int) -> InventoryNet.Slot:
	var sl := InventoryNet.Slot.new()
	sl.slot_index = index
	sl.item_id = item_id
	sl.quantity = quantity
	return sl

func _set_bag(entries: Array) -> void:
	_bag = entries
	_panels.set("_bag_slots", entries)
	_win.on_bag_changed()

func _click(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion)
	await process_frame
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		root.push_input(ev)
		await process_frame

## The window's timers stopped: the test steps them itself.
func _stop_timers() -> void:
	for t in ["_roll_timer", "_send_timer", "_effect_timer", "_win_timer"]:
		(_win.get(t) as Timer).stop()

func _centre(c: Control) -> Vector2:
	return c.get_global_rect().get_center()

func _held() -> HeldIcon:
	return _panels.get("held_icon") as HeldIcon

func _find(pred: Callable) -> ItemTableReader.Item:
	var items: Dictionary = _panels.get("_items")
	var ids := items.keys()
	ids.sort()
	for id in ids:
		var it: ItemTableReader.Item = items[id]
		if pred.call(it):
			return it
	return null

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
	_panels = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(_panels)
	await process_frame
	_panels.call("_load_items")
	_panels.call("set_bag_size", SIZE)

	var tables := GachaTables.new().load(func(path: String) -> PackedByteArray:
		var e := ObjectLoader.find_file(pk2, path)
		return pk2.read_file(e) if e != null else PackedByteArray())
	var types := func(ref: int) -> PackedInt32Array: return _panels.call("item_types", ref)
	var prizes := tables.prizes_for(tables.prize_set(9251), null, types)
	_check(prizes.size() == 10, "the machine's prize set: %d prizes" % prizes.size())

	_win = GachaWindow.new()
	root.add_child(_win)
	_check(_win.setup(builder), "the window builds from ifghacha.txt")
	# World3D's wiring.
	_win.icon_of = func(ref: int) -> Texture2D: return _panels.call("_item_icon", ref)
	_win.types_of = types
	_win.bag_of = func() -> Array: return _bag
	_win.size_of = func() -> int: return SIZE
	_win.gold_of = func() -> int: return 1234567
	_win.slot_fx = func(icon: Control, ref: int, bag_slot: int) -> void:
		_panels.call("_set_item_slot_fx", icon, ref, null)
	_win.tip_of = func(icon: Control, ref: int, bag_slot: int) -> void:
		_panels.call("_set_item_tip", icon, ref, "bag" if bag_slot >= 0 else "", bag_slot)
	_win.count_shows = func(ref: int, qty: int) -> bool: return _panels.call("shows_count", ref, qty)
	_win.pick_up = func(what: Dictionary, tex: Texture2D, source: Control, at: Vector2) -> bool:
		return _panels.call("pick_up_icon", what, tex, source, at)
	_win.play_requested.connect(func(uid: int, gid: int, bag_slot: int) -> void:
		_sent.append(GachaNet.encode_play(uid, gid, bag_slot)))
	var flashed: Array = []
	_win.coupon_flashed.connect(func(s: int) -> void: flashed.append(s))
	_panels.connect("held_dropped_outside", func(what: Dictionary, at: Vector2) -> void: _win.accept_drop(what, at))
	(_panels.get("click_pass_through") as Array).append(_win.passes_at)

	var seal := _find(func(it: ItemTableReader.Item) -> bool:
		return it.family() == ItemTooltipLines.WEAPON_FAMILY and ItemTooltipLines.is_seal(it))
	var potion := _find(func(it: ItemTableReader.Item) -> bool:
		return it.type_ids.size() >= 4 and it.type_ids[0] == 3 and it.type_ids[1] == 3 and it.type_ids[2] == 1)
	_check(seal != null and potion != null, "a seal weapon and a potion in the item table")
	# Cards on page 1 (slot 3), page 2 (slot 40) and page 3 (slot 70); the
	# seal weapon on page 2; a potion stack on page 1.
	_bag = [_slot(0, potion.id, 50), _slot(3, CARD, 1), _slot(33, seal.id, 1), _slot(40, CARD, 1), _slot(70, CARD, 1)]
	_panels.set("_bag_slots", _bag)

	_win.open_for(0x7f000007, prizes)
	await process_frame
	await process_frame

	# --- The pane (c:0x748790, c:0x749560) -----------------------------------
	_check(_win.bag_pages() == 3, "a bag of %d slots has 3 pages" % SIZE)
	var t0 := _win.tab_of(0)
	var t1 := _win.tab_of(1)
	var t2 := _win.tab_of(2)
	_check(t0 != null and t1 != null and t2 != null and _win.tab_of(3) == null, "three page tabs, IDs 500..502")
	if t0 == null or t1 == null or t2 == null:
		return
	var texts := [String((t0.get_node("Text") as Label).text), String((t1.get_node("Text") as Label).text),
		String((t2.get_node("Text") as Label).text)]
	_check(texts == ["Page 1", "Page 2", "Page 2"],
		"the tabs read UIIT_CTL_BELOINGING, then UIIT_STT_INVENTORY_EXTENSION_TEB for every other page: %s" % str(texts))
	var r1: Rect2 = t1.get_meta(UiBuilder.AUTHORED_RECT_META)
	_check(r1 == Rect2(537, 55, 60, 24), "tab 1 at (475 + 62, 55), 60 x 24: %s" % r1)
	_check((t0 as TextureButton).texture_normal == builder.load_texture(GachaWindow.TAB_ON)
		and (t1 as TextureButton).texture_normal == builder.load_texture(GachaWindow.TAB_OFF), "page 1's tab on, the rest off")
	_check(_win.cell_of(95) != null and _win.cell_of(96) == null, "a cell per slot of the three pages (96)")
	var c40 := _win.cell_of(40)
	var r40: Rect2 = c40.get_meta(UiBuilder.AUTHORED_RECT_META)
	_check(r40 == Rect2(494, 91 + 36 * 2, 32, 32), "cell 40 at (494 + 36 * (40 mod 4), 91 + 36 * ((40 mod 32) / 4)): %s" % r40)
	# The DECO's two sheets (MEASURED): the cells c:0x749739 / c:0x747098 cut.
	var prep := builder.load_texture(GachaWindow.DECO_PREPARE)
	var win_sheet := builder.load_texture(GachaWindow.DECO_WIN)
	print("note: alcm_effect_prepare %s, ga_effect_sucess %s" % [prep.get_size() if prep else "missing", win_sheet.get_size() if win_sheet else "missing"])
	_check(prep != null and int(prep.get_width() / 64) * int(prep.get_height() / 64) >= GachaWindow.DECO_PREPARE_FRAMES,
		"alcm_effect_prepare holds 16 cells of 64 x 64")
	_check(win_sheet != null and int(win_sheet.get_width() / 64) * int(win_sheet.get_height() / 81) >= GachaWindow.DECO_WIN_FRAMES,
		"ga_effect_sucess holds 15 cells of 64 x 81")
	_check(_win.cell_of(3).visible and not c40.visible and not _win.cell_of(70).visible, "page 1's cells shown, the others hidden")
	var lock := (_win.cell_of(85).get_node("ItemIcon") as TextureRect)
	_check(lock.texture == builder.load_texture(GachaWindow.BLOCK_DDJ) and bool(lock.get_meta("gacha_locked")),
		"a cell past the bag's size shows pt_block.ddj and is locked")
	var count0 := _win.cell_of(0).get_node("CountLabel") as Label
	_check(count0.text == "50", "an expendable stack's count on its cell: '%s'" % count0.text)
	var gold := _win.node("GDR_CHACHA_STA_MONEY") as Control
	var gold_label := gold.get_node_or_null("Text") as Label if gold != null else null
	_check(gold_label != null and gold_label.text == "1,234,567", "the purse on GDR_CHACHA_STA_MONEY, grouped")
	_check(_win.status_text() == "Choose item of desire.", "no prize: '%s'" % _win.status_text())

	# --- Item effects (lane S's OPEN item) -------------------------------------
	var c33 := _win.cell_of(33).get_node("ItemIcon") as Control
	var star := c33.get_node_or_null(ItemSealEdge.NODE_NAME) as CanvasItem
	_check(star != null and star.visible, "the seal weapon's cell carries the seal star (SetItem with the bag record)")
	var seal_prize := -1
	for i in prizes.size():
		var it: ItemTableReader.Item = (_panels.get("_items") as Dictionary).get((prizes[i] as GachaTables.Prize).ref_id)
		if it != null and ItemTooltipLines.is_seal(it):
			seal_prize = i
	if seal_prize >= 0:
		var pi := (_win.node("GDR_GHACHA_SLOT_%d" % (100 + seal_prize)) as Control).get_node("ItemIcon") as Control
		var ps := pi.get_node_or_null(ItemSealEdge.NODE_NAME) as CanvasItem
		_check(ps != null and ps.visible, "a seal prize's slot carries the star (a record with +0x28 set, c:0x748eb1)")
	else:
		print("note: no seal prize in this archive's set")
	var pcount := (_win.node("GDR_GHACHA_SLOT_100") as Control).get_node("CountLabel") as Label
	_check(pcount.text == "", "no count on a prize slot (source kind 0x8c)")

	# --- A page-1 card put down off the card slot: refused (c:0x7478c0) ------
	await _click(_centre(_win.node("GDR_GHACHA_SLOT_100") as Control))
	_check(_win.chosen == 0 and _win.state() == 1, "prize 0 chosen by a click: state 1")
	var marker := ((_win.node("GDR_GHACHA_SLOT_100") as Control).get_node("ItemIcon") as Control).get_node_or_null("GachaChosenEdge")
	_check(marker != null and (marker as CanvasItem).visible, "the chosen prize turns the pet-edge marker (0x666680(1))")
	_check(_win.status_text() == "Register Magic POP card.", "'%s'" % _win.status_text())
	await _click(_centre(_win.cell_of(3).get_node("ItemIcon") as Control))
	_check(_held().is_holding() and _held().kind() == "gacha_bag" and int(_held().payload["slot"]) == 3,
		"a click picks the page-1 card up")
	await _click(_centre(_win.cell_of(5).get_node("ItemIcon") as Control))
	_check(not _held().is_holding() and _win.card_slot == -1, "put down on another cell: let go, not taken")

	# --- Carry a page-1 card across a page turn onto the card slot ------------
	await _click(_centre(_win.cell_of(3).get_node("ItemIcon") as Control))
	await _click(_centre(t1))
	_check(_held().is_holding(), "the tab's click passes the held card (0x6523d0): still held")
	_check(_win.bag_page == 1 and c40.visible and not _win.cell_of(3).visible, "page 2 shown")
	_check((t1 as TextureButton).texture_normal == builder.load_texture(GachaWindow.TAB_ON), "tab 2 selected")
	await _click(_centre(_win.node("GDR_GHACHA_CARD_SLOT") as Control))
	_check(not _held().is_holding() and _win.card_slot == 3, "put down on the card slot: registered from bag slot 3")
	_check(_win.state() == 2 and _win.status_text() == "Click PLAY button." and _win.can_play(), "state 2, PLAY on")

	# --- Page 2: a card registered, played, answered --------------------------
	# The page-1 card goes back to the bag when its slot is taken from it.
	_set_bag([_slot(0, potion.id, 50), _slot(33, seal.id, 1), _slot(40, CARD, 1), _slot(70, CARD, 1), _slot(4, CARD, 1)])
	_check(_win.card_slot == -1 and _win.state() == 1, "the card slot empties when its bag slot changes to another item")
	await _click(_centre(c40.get_node("ItemIcon") as Control))
	_check(_held().is_holding() and int(_held().payload["slot"]) == 40, "the page-2 card picked up")
	await _click(_centre(_win.node("GDR_GHACHA_SLOT_105") as Control))
	_check(_win.card_slot == 40, "a page-2 card put down anywhere in the window is taken (on a prize slot here)")
	_check(_win.chosen == 0, "the put-down did not choose the prize under it")
	UiSounds.clear_fired()
	_win.play()
	_stop_timers()
	_check(_win.busy and bool(_win.deco_state()["visible"]) and String(_win.deco_state()["sheet"]) == GachaWindow.DECO_PREPARE,
		"PLAY: busy, the DECO shown on alcm_effect_prepare")
	_check(UiSounds.count(GachaWindow.SND_MOVE) == 1 and UiSounds.count(GachaWindow.SND_TURN) == 1,
		"snd_gacha_move and snd_gacha_turn")
	_check(not _win.close_window(), "closing is refused while busy")
	_win.call("_on_send_due")
	_check(_sent.size() == 1 and (_sent[0] as PackedByteArray)[8] == 40 + 13,
		"0x7118 names bag slot 40 + 13: %s" % [(_sent[0] as PackedByteArray).hex_encode() if not _sent.is_empty() else "nothing"])
	# The effect's 41 ticks and the reset (c:0x746f21).
	_win.effect_log.clear()
	for k in 42:
		_win.call("_on_effect_tick")
	var log := _win.effect_log
	_check(log.size() == 43 and log[0].ends_with("ga_effect_01.ddj") and log[7].ends_with("ga_effect_08.ddj")
		and log[16].ends_with("ga_effect_08.ddj") and log[17].ends_with("ga_effect_09.ddj")
		and log[23].ends_with("ga_effect_15.ddj") and log[36].ends_with("ga_effect_15.ddj")
		and log[40].ends_with("ga_effect_19.ddj") and log[42].ends_with("ga_effect_01.ddj"),
		"the effect: 01..07, 08 held 10 ticks, 09..14, 15 held 14, 16..19, then 01 (%s ...)" % ", ".join(log.slice(0, 18)))
	_check(not bool(_win.deco_state()["visible"]), "the DECO hidden at tick 41 after a loss")
	_win.on_result({"ok": true, "win": false})
	_check(not _win.busy and _win.status_text() == "The item you wanted was not won.", "the loss: '%s'" % _win.status_text())
	_check(UiSounds.count(GachaWindow.SND_END) == 1, "snd_gacha_end")
	_set_bag([_slot(0, potion.id, 50), _slot(33, seal.id, 1), _slot(40, COUPON_LOSE, 1), _slot(70, CARD, 1), _slot(4, CARD, 1)])
	_check(_win.card_slot == 40 and flashed == [40], "the card's slot turned coupon: the card slot keeps it, the cell flashes")
	_check(_win.status_text() == "The item you wanted was not won.", "the result line stays")

	# --- Page 3: a card registered over the coupon -----------------------------
	await _click(_centre(t2))
	_check(_win.bag_page == 2 and _win.cell_of(70).visible, "page 3 shown (its tab reads Page 2)")
	await _click(_centre(_win.cell_of(70).get_node("ItemIcon") as Control))
	await _click(_centre(_win.node("GDR_GHACHA_CARD_SLOT") as Control))
	_check(_win.card_slot == 70 and _win.state() == 2, "the page-3 card registered over the coupon")
	_win.play()
	_stop_timers()
	_win.call("_on_send_due")
	_check(_sent.size() == 2 and (_sent[1] as PackedByteArray)[8] == 70 + 13, "0x7118 names bag slot 70 + 13")
	_win.on_result({"ok": true, "win": true})
	_check(_win.status_text() == "Congratulations." and UiSounds.count(GachaWindow.SND_WIN) == 1, "the win line and snd_gacha_win")
	_win.effect_log.clear()
	for k in 41:
		_win.call("_on_effect_tick")
	# After the loss the tick was left at 1 (the original's quirk): this run
	# takes 41 ticks, holds 07 and 14 instead, and shows the win sheet.
	_check(_win.effect_log.size() == 42 and _win.effect_log[6].ends_with("ga_effect_07.ddj")
		and _win.effect_log[15].ends_with("ga_effect_07.ddj") and _win.effect_log[40].ends_with("ga_effect_19.ddj")
		and _win.effect_log[41].ends_with("ga_effect_01.ddj"),
		"after a loss the next run starts at tick 1 (%d paths, last %s)" % [_win.effect_log.size(), _win.effect_log[-1] if not _win.effect_log.is_empty() else ""])
	_check(bool(_win.deco_state()["visible"]) and String(_win.deco_state()["sheet"]) == GachaWindow.DECO_WIN
		and int(_win.deco_state()["frame"]) == 1, "a win: the DECO plays ga_effect_sucess from frame 1")
	_stop_timers()
	for k in 14:
		_win.call("_on_win_tick")
	_check(not bool(_win.deco_state()["visible"]) and String(_win.deco_state()["sheet"]) == GachaWindow.DECO_PREPARE,
		"at frame 14 the DECO hides and goes back to the prepare sheet")

	# --- Closing -------------------------------------------------------------
	UiSounds.clear_fired()
	_check(_win.close_window() and not _win.visible and UiSounds.count(UiSounds.KEY_WINDOW_CLOSE) == 1,
		"closing: hidden, snd_window_close")
