extends SceneTree

## Round 843 (lane S): an item slot's per-item effects in every window that
## holds item slots, against the real Media.pk2 (docs/protocol/item_seal_edge.md
## §6, docs/protocol/stall.md "The slots' item effects"). The original's
## CIFSlotWithHelp starts them in its SetItem (0x6871d0) and draws them after
## the icon (0x67cfb0) whatever its window: the seal star (ItemSealEdge), the
## awake devil's spirit's edge, the summoned pet's edge, the dead pet's or
## spent spirit's blue wash and the pet's life flash (ItemStateEdge).
## Covered: the stall's ten slots, owner and visitor (a list, a Modify, a
## sale, a close and a reopen), the exchange's two grids, the warehouse, the
## bag (states, the 0x3040 change and its life flash), the worn avatar slot,
## the quick slots and the held icon.
##   godot4 --headless --path client --script res://scripts/ui/hud/slot_fx843_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeNet extends RefCounted:
	var sent: Array = []
	var own_character_id := 1
	var current_character_name := "Aria"
	var stalls := {}
	var buff_items := {}
	func stall_open(t: String) -> void: sent.append("open " + t)
	func stall_close() -> void: sent.append("close")
	func stall_leave() -> void: sent.append("leave")
	func stall_buy(slot: int) -> void: sent.append("buy %d" % slot)
	func stall_enter(uid: int) -> void: sent.append("enter %d" % uid)
	func stall_update(body: PackedByteArray) -> void: sent.append("update %d" % body[0])
	func stall_avatar(key: int, deco: int) -> void: sent.append("avatar %d %d" % [key, deco])
	func send_chat(t: int, _i: int, _n: String, text: String) -> void: sent.append("chat %d %s" % [t, text])

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

func _find(panels: Control, pred: Callable) -> ItemTableReader.Item:
	var items: Dictionary = panels.get("_items")
	var ids := items.keys()
	ids.sort()
	for id in ids:
		var it: ItemTableReader.Item = items[id]
		if pred.call(it):
			return it
	return null

func _inst(ref: int, equipment := true) -> ItemInstance:
	var it := ItemInstance.new()
	it.ref_item_id = ref
	it.is_equipment = equipment
	it.count = 1
	return it

func _entry(slot: int, it: ItemInstance, price: int, bag: int) -> StallNet.Entry:
	var e := StallNet.Entry.new()
	e.slot = slot
	e.item = it
	e.count = 1
	e.price = price
	e.bag_slot = bag
	return e

## Every effect node visible on an icon, by name.
func _fx(icon: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if icon == null:
		return out
	for n in [ItemSealEdge.NODE_NAME, "PetEdge", "NasrunEdge", "LifeEdge", ItemStateEdge.WASH_NAME]:
		var c := icon.get_node_or_null(n) as CanvasItem
		if c != null and c.visible:
			out.append(n)
	return out

## The number of children of an icon named `n` (a refill must not add more).
func _count(icon: Node, n: String) -> int:
	var k := 0
	for c in icon.get_children():
		if String(c.name) == n:
			k += 1
	return k

func _run() -> void:
	_rules()
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
	panels.call("_load_items")
	_sheets(builder)

	var seal := _find(panels, func(it: ItemTableReader.Item) -> bool:
		return it.family() == ItemTooltipLines.WEAPON_FAMILY and ItemTooltipLines.is_seal(it) and it.durability > 0)
	var sword := _find(panels, func(it: ItemTableReader.Item) -> bool:
		return it.family() == ItemTooltipLines.WEAPON_FAMILY and not ItemTooltipLines.is_seal(it) \
			and it.durability > 0 and it.code_name.begins_with("ITEM_CH_SWORD_"))
	var scroll := _find(panels, func(it: ItemTableReader.Item) -> bool: return it.code_name == "ITEM_COS_P_RAVEN_SCROLL")
	var spirit := _find(panels, func(it: ItemTableReader.Item) -> bool: return it.code_name == "ITEM_MALL_AVATAR_M_NASRUN")
	_check(seal != null and sword != null and scroll != null and spirit != null,
		"the archive's items: a seal weapon %s, a sword %s, %s, %s" % [seal.code_name if seal else "?",
			sword.code_name if sword else "?", scroll.code_name if scroll else "?", spirit.code_name if spirit else "?"])
	if seal == null or sword == null or scroll == null or spirit == null:
		return
	_check(ItemStateEdge.is_spirit(spirit) and not ItemStateEdge.is_spirit(scroll) and not ItemStateEdge.is_spirit(seal),
		"0x55edf0: the devil's spirit is 3/1/14, the pet scroll and the seal weapon are not")
	await _stall(panels, seal, sword, scroll)
	await _exchange(panels, seal, sword, scroll)
	await _storage(panels, seal, sword)
	await _bag(panels, seal, sword, scroll, spirit)

## ItemStateEdge's arithmetic and rules (READ, item_state_edge.gd's header).
func _rules() -> void:
	_check(ItemStateEdge.frame_for(ItemStateEdge.Mode.NASRUN, 12) == 0 and ItemStateEdge.frame_for(ItemStateEdge.Mode.NASRUN, 1) == 11
		and ItemStateEdge.frame_for(ItemStateEdge.Mode.NASRUN, 0) == -1, "the spirit's cell (12 - c) & 15: c 12 -> 0, 1 -> 11, 0 none")
	_check(ItemStateEdge.frame_for(ItemStateEdge.Mode.PET, 9) == 0 and ItemStateEdge.frame_for(ItemStateEdge.Mode.PET, 1) == 8
		and ItemStateEdge.frame_for(ItemStateEdge.Mode.PET, 0) == -1, "the pet's cell 9 - c: c 9 -> 0, 1 -> 8, 0 none")
	_check(ItemStateEdge.frame_for(ItemStateEdge.Mode.LIFE, 8) == 0 and ItemStateEdge.frame_for(ItemStateEdge.Mode.LIFE, 1) == 7, "the life flash's cell 8 - c")
	_check(ItemStateEdge.step(ItemStateEdge.Mode.NASRUN, 1) == 12 and ItemStateEdge.step(ItemStateEdge.Mode.NASRUN, 5) == 4
		and ItemStateEdge.step(ItemStateEdge.Mode.PET, 1) == 9 and ItemStateEdge.step(ItemStateEdge.Mode.LIFE, 1) == -1 and ItemStateEdge.step(ItemStateEdge.Mode.LIFE, 8) == 7,
		"the steps: --c, wrapping to 12 / 9; the life flash ends at 0")
	_check(ItemStateEdge.cell_uv(ItemStateEdge.Mode.NASRUN, 3).is_equal_approx(Rect2(96.0 / 512.0, 0, 32.0 / 512.0, 1))
		and ItemStateEdge.cell_uv(ItemStateEdge.Mode.PET, 2).is_equal_approx(Rect2(64.0 / 288.0, 0, 32.0 / 288.0, 1))
		and ItemStateEdge.cell_uv(ItemStateEdge.Mode.LIFE, 7).is_equal_approx(Rect2(224.0 / 256.0, 0, 32.0 / 256.0, 1)),
		"the UVs: 32 / 512, 32 / 288, 32 / 256 a cell, v 0..1")
	_check(ItemStateEdge.INTERVAL_MS[ItemStateEdge.Mode.NASRUN] == 80 and ItemStateEdge.INTERVAL_MS[ItemStateEdge.Mode.PET] == 50 and ItemStateEdge.INTERVAL_MS[ItemStateEdge.Mode.LIFE] == 80,
		"the timers: 0x50, 0x32, 0x50 ms")
	_check(ItemStateEdge.WASH_COLOUR.to_argb32() == 0x80004b7e, "the wash 0x80004b7e")
	var spirit := ItemTableReader.Item.new()
	spirit.type_ids = PackedInt32Array([3, 1, 14, 1])
	var pet := ItemTableReader.Item.new()
	pet.type_ids = PackedInt32Array([3, 2, 1, 1])
	var awake := _inst(1)
	awake.durability = (1 << 31) | 3600
	var spent := _inst(1)
	spent.durability = 1 << 31
	var asleep := _inst(1)
	asleep.durability = 3600
	_check(ItemStateEdge.effects_for(spirit, awake) == {"edge": ItemStateEdge.Mode.NASRUN, "wash": false}
		and ItemStateEdge.effects_for(spirit, spent) == {"edge": -1, "wash": true}
		and ItemStateEdge.effects_for(spirit, asleep) == {"edge": -1, "wash": false}
		and ItemStateEdge.effects_for(spirit, awake, true) == {"edge": -1, "wash": false},
		"a spirit: awake with time the edge, awake with none the wash, asleep nothing, the mall's slot nothing")
	var out := _inst(2, false)
	out.cos_state = 2
	var dead := _inst(2, false)
	dead.cos_state = 4
	var stored := _inst(2, false)
	stored.cos_state = 3
	_check(ItemStateEdge.effects_for(pet, out) == {"edge": ItemStateEdge.Mode.PET, "wash": false}
		and ItemStateEdge.effects_for(pet, dead) == {"edge": -1, "wash": true}
		and ItemStateEdge.effects_for(pet, stored) == {"edge": -1, "wash": false}
		and ItemStateEdge.effects_for(pet, null) == {"edge": -1, "wash": false},
		"a pet scroll: out the edge, dead the wash, in the scroll nothing; no record nothing")
	# The timer: one step per pass at least 80 ms after the last (late ones dropped).
	var e := ItemStateEdge.new()
	e.mode = ItemStateEdge.Mode.NASRUN
	e.set_item(7)
	var start := e.counter
	var t0: int = e._last_ms
	e.tick(t0 + 79)
	_check(e.counter == start, "no step before 80 ms")
	e.tick(t0 + 80)
	_check(e.counter == ItemStateEdge.step(ItemStateEdge.Mode.NASRUN, start), "a step at 80 ms")
	e.tick(t0 + 400)
	_check(e.counter == ItemStateEdge.step(ItemStateEdge.Mode.NASRUN, ItemStateEdge.step(ItemStateEdge.Mode.NASRUN, start)), "a late pass steps once")
	var phase := e.counter
	e.set_item(7)
	_check(e.counter == phase, "the same item set again keeps its phase")
	e.free()
	var life := ItemStateEdge.new()
	life.mode = ItemStateEdge.Mode.LIFE
	life.start_life()
	var l0: int = life._last_ms
	for k in 8:
		life.tick(l0 + 80 * (k + 1))
	_check(life.counter == 0 and not life.visible, "the life flash: 8 cells, then gone")
	life.free()

## MEASURED: the three sheets' sizes in the player's archive.
func _sheets(builder: UiBuilder) -> void:
	for m in [ItemStateEdge.Mode.NASRUN, ItemStateEdge.Mode.PET, ItemStateEdge.Mode.LIFE]:
		ItemStateEdge.ensure_texture(builder, m)
	var n := ItemStateEdge.texture_for(ItemStateEdge.Mode.NASRUN)
	var p := ItemStateEdge.texture_for(ItemStateEdge.Mode.PET)
	var l := ItemStateEdge.texture_for(ItemStateEdge.Mode.LIFE)
	print("MEASURED sheets: nasrun %s, pt_edge_effect %s, pt_life_effect %s" % [
		str(n.get_size()) if n else "none", str(p.get_size()) if p else "none", str(l.get_size()) if l else "none"])
	_check(n != null and p != null and l != null, "the three sheets load from Media.pk2")

## The stall: ten slots, the owner and a visitor.
func _stall(panels: Control, seal: ItemTableReader.Item, sword: ItemTableReader.Item, scroll: ItemTableReader.Item) -> void:
	var c: StallController = panels.call("_stall")
	var net := FakeNet.new()
	c.net = net
	c.start()
	await process_frame
	var tbox := panels.get_node_or_null("StallTitleInput") as HudCosBox
	if tbox != null:
		tbox.press_ok()
	c.on_open_result(1)
	await process_frame
	var w: HudWindow = panels.get("_windows").get("stall")
	var display := w.node("GDR_STALL_DISPLAY") as Control if w != null else null
	_check(display != null, "the stall window and its slots")
	if display == null:
		return
	var icon := func(i: int) -> TextureRect:
		return display.get_node("StallSlot%d/Body/GDR_STALLSLOT_ICON/ItemIcon" % i) as TextureRect
	# The owner's list: seal weapons in the even slots, swords in the odd.
	var entries := {}
	for i in 10:
		entries[i] = _entry(i, _inst(seal.id if i % 2 == 0 else sword.id), 1000 + i, 20 + i)
	c.on_updated({"code": 1, "type": 2, "entries": entries})
	await process_frame
	var all_ok := true
	for i in 10:
		var want := i % 2 == 0
		if (ItemSealEdge.NODE_NAME in _fx(icon.call(i))) != want:
			all_ok = false
			print("  slot %d: %s" % [i, str(_fx(icon.call(i)))])
	_check(all_ok, "the owner's ten slots: the seal weapons (0, 2, 4, 6, 8) have the star, the swords none")
	var e0 := (icon.call(0) as Node).get_node(ItemSealEdge.NODE_NAME) as ItemSealEdge
	_check(e0.get_parent() == icon.call(0) and e0.size == (icon.call(0) as Control).size and (icon.call(0) as Control).size == Vector2(32, 32),
		"the star covers the slot's 32 x 32 icon (got %s)" % str((icon.call(0) as Control).size))
	var phase := e0.counter
	# Modify: slot 2 now a sword, slot 3 a seal; a refill keeps slot 0's phase.
	entries = entries.duplicate()
	entries[2] = _entry(2, _inst(sword.id), 5, 22)
	entries[3] = _entry(3, _inst(seal.id), 5, 23)
	c.on_updated({"code": 1, "type": 2, "entries": entries})
	_check(not (ItemSealEdge.NODE_NAME in _fx(icon.call(2))) and ItemSealEdge.NODE_NAME in _fx(icon.call(3)),
		"Modify: a slot changed to a sword loses the star, one changed to a seal weapon gets it")
	_check(e0.counter == phase and _count(icon.call(0), ItemSealEdge.NODE_NAME) == 1, "an unchanged slot keeps its phase, one star")
	# A pet scroll: a dead one's wash, a summoned one's edge.
	var dead := _inst(scroll.id, false)
	dead.cos_state = CosNet.ITEM_STATE_DEAD
	entries[5] = _entry(5, dead, 9, 25)
	c.on_updated({"code": 1, "type": 2, "entries": entries})
	_check(_fx(icon.call(5)) == PackedStringArray([ItemStateEdge.WASH_NAME]), "a dead pet's scroll in the stall: the blue wash (got %s)" % str(_fx(icon.call(5))))
	# Open, then a sale empties slot 4.
	c.on_updated({"code": 1, "type": 5, "open": true})
	entries = entries.duplicate()
	entries.erase(4)
	c.on_event({"kind": 3, "slot": 4, "buyer": "Bram", "entries": entries})
	_check(_fx(icon.call(4)).is_empty() and ItemSealEdge.NODE_NAME in _fx(icon.call(6)),
		"a sale empties slot 4: its star goes, slot 6's stays (got %s)" % str(_fx(icon.call(4))))
	# Close and open again: the list comes back with the stars, none doubled.
	c.on_close_result(1)
	_check(not w.visible, "closed")
	c.start()
	await process_frame
	tbox = panels.get_node_or_null("StallTitleInput") as HudCosBox
	if tbox != null:
		tbox.press_ok()
	c.on_open_result(1)
	await process_frame
	_check(w.visible and _fx(icon.call(0)).is_empty(), "reopened empty: no star left from before")
	c.on_updated({"code": 1, "type": 2, "entries": {0: _entry(0, _inst(seal.id), 1, 20), 1: _entry(1, _inst(sword.id), 1, 21)}})
	_check(ItemSealEdge.NODE_NAME in _fx(icon.call(0)) and _fx(icon.call(1)).is_empty() and _count(icon.call(0), ItemSealEdge.NODE_NAME) == 1,
		"reopened: the seal weapon's star again, one")
	c.on_close_result(1)
	# A visitor, while the stall is being modified: the icons at alpha 0x80,
	# the star not (0x6554c0 resets the alpha op before 0x67cfb0).
	net.stalls[5] = {"owner": 5, "name": "Bram's", "decoration": 0}
	var out := _inst(scroll.id, false)
	out.cos_state = CosNet.ITEM_STATE_SUMMONED
	c.on_entered({"code": 1, "owner": 5, "greeting": "hi", "open": false, "value4": 0,
		"entries": {0: _entry(0, _inst(seal.id), 50, 1), 7: _entry(7, _inst(sword.id), 60, 2), 9: _entry(9, out, 70, 3)}, "visitors": []})
	await process_frame
	var v0 := icon.call(0) as TextureRect
	var edge := v0.get_node(ItemSealEdge.NODE_NAME) as ItemSealEdge
	_check(not c.own and ItemSealEdge.NODE_NAME in _fx(v0) and _fx(icon.call(7)).is_empty(), "the visitor: the seal weapon's star, the sword none")
	_check(is_equal_approx(v0.self_modulate.a, 128.0 / 255.0) and v0.modulate == Color.WHITE and edge.modulate == Color.WHITE
		and edge.self_modulate == Color.WHITE, "modifying: the icon at alpha 0x80, its star undimmed")
	_check("PetEdge" in _fx(icon.call(9)), "a summoned pet's scroll: the pet edge (got %s)" % str(_fx(icon.call(9))))
	c.on_updated({"code": 1, "type": 5, "open": true})
	_check(is_equal_approx(v0.self_modulate.a, 1.0) and ItemSealEdge.NODE_NAME in _fx(v0), "open: full alpha, the star on")
	c.on_leave_result(1)

## The exchange: both grids (ExchangeNet.Offered records).
func _exchange(panels: Control, seal: ItemTableReader.Item, sword: ItemTableReader.Item, scroll: ItemTableReader.Item) -> void:
	panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "", "normal": true}, {"id": 1, "name": "Sarada", "guild": "", "normal": true})
	await process_frame
	var w: HudWindow = panels.get("_windows").get(ExchangeController.WINDOW)
	if w == null:
		_check(false, "the exchange window")
		return
	var offered := func(i: int, it: ItemInstance) -> ExchangeNet.Offered:
		var o := ExchangeNet.Offered.new()
		o.index = i
		o.item = it
		return o
	var dead := _inst(scroll.id, false)
	dead.cos_state = CosNet.ITEM_STATE_DEAD
	panels.call("exchange_draw_grid", true, {0: offered.call(0, _inst(seal.id)), 1: offered.call(1, _inst(sword.id))}, false)
	panels.call("exchange_draw_grid", false, {2: offered.call(2, _inst(seal.id)), 3: offered.call(3, dead)}, false)
	var mine := w.node("GDR_EXCHANGE_LAT_MY") as Control
	var theirs := w.node("GDR_EXCHANGE_LAT_OTHER") as Control
	_check(ItemSealEdge.NODE_NAME in _fx(mine.get_child(0).get_node("ItemIcon")) and _fx(mine.get_child(1).get_node("ItemIcon")).is_empty(),
		"the exchange, my side: the seal weapon's star, the sword none")
	_check(ItemSealEdge.NODE_NAME in _fx(theirs.get_child(2).get_node("ItemIcon"))
		and _fx(theirs.get_child(3).get_node("ItemIcon")) == PackedStringArray([ItemStateEdge.WASH_NAME]),
		"the exchange, the other side: the star, and a dead pet's wash")
	panels.call("exchange_draw_grid", false, {}, false)
	_check(_fx(theirs.get_child(2).get_node("ItemIcon")).is_empty() and _fx(theirs.get_child(3).get_node("ItemIcon")).is_empty(),
		"an emptied grid: no effects")
	panels.call("close", ExchangeController.WINDOW)

## The warehouse.
func _storage(panels: Control, seal: ItemTableReader.Item, sword: ItemTableReader.Item) -> void:
	var w = panels.call("open", "storage")
	if w == null:
		_check(false, "the storage window")
		return
	await process_frame
	var slots: Array = []
	for pair in [[0, seal.id], [1, sword.id]]:
		var sl := InventoryNet.Slot.new()
		sl.slot_index = pair[0]
		sl.item_id = pair[1]
		sl.quantity = 1
		slots.append(sl)
	panels.call("_fill_storage_grid", slots)
	var grid := (w as HudWindow).node("GDR_STORAGE_LAT") as Control
	_check(grid != null and ItemSealEdge.NODE_NAME in _fx(grid.get_child(0).get_node("ItemIcon"))
		and _fx(grid.get_child(1).get_node("ItemIcon")).is_empty(), "the warehouse: the seal weapon's star, the sword none")
	panels.call("_fill_storage_grid", [])
	_check(_fx(grid.get_child(0).get_node("ItemIcon")).is_empty(), "an emptied warehouse slot: none")
	panels.call("close", "storage")

## The bag, the 0x3040 change, the worn avatar slot, the quick slots, the held icon.
func _bag(panels: Control, seal: ItemTableReader.Item, sword: ItemTableReader.Item, scroll: ItemTableReader.Item, spirit: ItemTableReader.Item) -> void:
	var net := root.get_node_or_null("NetClient")
	if net == null:
		print("SKIP the bag checks (no NetClient autoload)")
		return
	net.set("last_inventory_capacity", 32)
	var out := _inst(scroll.id, false)
	out.cos_state = CosNet.ITEM_STATE_SUMMONED
	var awake := _inst(spirit.id)
	awake.durability = (1 << 31) | 86400
	var instances := {0: _inst(seal.id), 1: out, 2: awake, 3: _inst(sword.id)}
	net.set("last_inventory_instances", instances)
	var w = panels.call("open", "inventory")
	panels.call("select_bag_page", 0)
	var slots: Array = []
	for i in 4:
		var sl := InventoryNet.Slot.new()
		sl.slot_index = i
		sl.item_id = (instances[i] as ItemInstance).ref_item_id
		sl.quantity = 1
		slots.append(sl)
	panels.call("_fill_inventory_grid", slots)
	await process_frame
	var grid := (w as HudWindow).node("GDR_INVENTORY_LATTICE") as Control
	var bag := func(i: int) -> Control: return grid.get_child(i).get_node("ItemIcon") as Control
	_check(_fx(bag.call(0)) == PackedStringArray([ItemSealEdge.NODE_NAME]) and _fx(bag.call(1)) == PackedStringArray(["PetEdge"])
		and _fx(bag.call(2)) == PackedStringArray(["NasrunEdge"]) and _fx(bag.call(3)).is_empty(),
		"the bag: a seal weapon's star, a summoned pet's edge, an awake spirit's edge, a sword nothing (got %s %s %s %s)" % [
			_fx(bag.call(0)), _fx(bag.call(1)), _fx(bag.call(2)), _fx(bag.call(3))])
	# 0x3040: the pet dies (state 4) -- the wash; it is revived (3 over 4) --
	# the wash goes and the life flash plays once.
	out.cos_state = CosNet.ITEM_STATE_DEAD
	panels.call("bag_item_state_changed", 1, false)
	_check(_fx(bag.call(1)) == PackedStringArray([ItemStateEdge.WASH_NAME]), "0x3040 state 4: the edge goes, the wash comes (got %s)" % str(_fx(bag.call(1))))
	out.cos_state = CosNet.ITEM_STATE_STORED
	panels.call("bag_item_state_changed", 1, true)
	_check(_fx(bag.call(1)) == PackedStringArray(["LifeEdge"]), "0x3040 state 3 over 4: no wash, the life flash (got %s)" % str(_fx(bag.call(1))))
	var wash: Node = (bag.call(1) as Node).get_node_or_null(ItemStateEdge.WASH_NAME)
	_check(wash != null and wash.get_index() == 0 and (bag.call(1) as Node).get_node("LifeEdge").get_index() > wash.get_index(),
		"the wash first, the flash after it (0x67cfb0's order)")
	# The spirit's time runs out: the wash.
	awake.durability = 1 << 31
	panels.call("bag_item_state_changed", 2, false)
	_check(_fx(bag.call(2)) == PackedStringArray([ItemStateEdge.WASH_NAME]), "an awake spirit with no time left: the wash")
	# Refills do not add nodes.
	for k in 3:
		panels.call("_fill_inventory_grid", slots)
	_check(_count(bag.call(0), ItemSealEdge.NODE_NAME) == 1 and _count(bag.call(1), ItemStateEdge.WASH_NAME) == 1
		and _count(bag.call(2), "NasrunEdge") == 1, "refills: one of each node")
	# The held icon carries the slot's effects.
	out.cos_state = CosNet.ITEM_STATE_SUMMONED
	panels.call("_fill_inventory_grid", slots)
	var icon1 := bag.call(1) as TextureRect
	(icon1.get_node("PetEdge") as ItemStateEdge).counter = 5
	panels.call("pick_up_icon", {"kind": "bag", "slot": 1, "item_id": scroll.id, "icon": icon1.texture}, icon1.texture, icon1, Vector2(100, 100))
	var held = panels.get("held_icon")
	var ghost: Control = held.call("ghost") if held != null else null
	var gp := ghost.get_node_or_null("PetEdge") as ItemStateEdge if ghost != null else null
	_check(gp != null and gp.visible and gp.counter == 5, "a held summoned pet's scroll: its edge on the cursor at the slot's phase")
	held.call("cancel")
	# Emptied: nothing left.
	panels.call("_fill_inventory_grid", [])
	# The life flash may still be counting on slot 1, but 0x67cfb0 draws
	# nothing for a slot with no record: it is not drawn on an empty icon.
	var rest := _fx(bag.call(1))
	rest.erase("LifeEdge")
	_check(_fx(bag.call(0)).is_empty() and rest.is_empty() and _fx(bag.call(2)).is_empty()
		and (bag.call(1) as TextureRect).texture == null, "an emptied bag: no effects (a running life flash undrawn)")
	# The worn avatar slot: an awake spirit.
	net.set("last_avatar_instances", {4: awake})
	awake.durability = (1 << 31) | 86400
	panels.call("_fill_avatar_slots")
	var found := false
	for n in (w as HudWindow).find_children("*", "TextureRect", true, false):
		if String(n.name) == "ItemIcon" and "NasrunEdge" in _fx(n):
			found = true
	_check(found, "the worn spirit's avatar slot: its edge")
	net.set("last_avatar_instances", {})
	panels.call("_fill_avatar_slots")
	# The quick slots.
	var Fixture = load("res://scripts/ui/hud/underbar_fixture.gd")
	var bar := HudUnderbar.new(Fixture.builder(), null, null)
	root.add_child(bar)
	bar.set_slot_item(1, ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8)))
	bar.set_slot_item(2, ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8)))
	bar.set_slot_states({1: [scroll, out, scroll.id], 2: [sword, _inst(sword.id), sword.id]})
	_check("PetEdge" in _fx(bar.slot_icon_rect(1)) and _fx(bar.slot_icon_rect(2)).is_empty(), "the quick slot: a summoned pet's edge; a sword none")
	bar.set_slot_states({})
	_check(_fx(bar.slot_icon_rect(1)).is_empty(), "a quick slot emptied: none")
	bar.queue_free()
	net.set("last_inventory_instances", {})
	net.set("last_inventory_capacity", 0)
