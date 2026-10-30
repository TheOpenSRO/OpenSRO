extends RefCounted
class_name GuildStorageController

## The guild storage window (round 844, lane H): GDR_GUILDSTORAGEROOM, the
## same CIFStorageRoom as the personal storage -- ginterface.txt's
## GuildStorageRoom section, ID 145 (0x91), 254x317, titled
## UIIT_STT_GUILD_WAREHOUSE "Guild storage", its layout ifstorageroom.txt
## (READ). GuildStorageNet has the wire; GuildStorageState the list.
##
## The flow (READ, sro_client.exe):
##   - 0xB250 {1}: the window shown (0x79bf40(1), with snd_window_open from
##     the helper 0x79a7e0), the inventory beside it (0x6aefa0, 0x79af20), the
##     NPC kept (+0x7c8), then 0x7252 (0x820980) and the list;
##   - its X (CIFStorageRoom::vslot_043 for 0x91): 0x79bf40(0) -- the window
##     hidden, 0x7251 {npc}; 0xB251 {1} ends the talk (0x704B);
##   - a bag item put down on it: the deposit box, purpose 0x10 (0x6b0e90),
##     the fee (unit fee x count) / 2, then 0x7034 type 0x1e; a stored item put
##     down on the bag: the withdraw box, purpose 0x11 (0x6b15b0), then type
##     0x1f; put down on another cell: type 0x1d with the stack (0x7950b0);
##   - the gold: the window's money button the withdraw box (purpose 0x13,
##     0x6b29f0), the bag's while the window is up the deposit box (0x12,
##     0x6b2800); 0x7034 types 0x21 / 0x20.
##   - the bag drop's own test (CIFStorageRoom::vslot_028 -> 0x6cc190): the
##     item's ref +0xa7 bit 7, else UIIT_MSG_STRGERR_INVALID_TARGET_STORAGE
##     (0x1843) with no request (OPEN here: the client's item table does not
##     carry that byte; the server refuses the same items, 0x1843).

const WINDOW := "guild_storage"
const MIN_LEVEL := 2
const LATTICE := "GDR_STORAGE_LAT"
const SPIN := "GDR_STORAGE_SPIN_PAGE"
const MONEY := "GDR_STORAGE_STA_MONEY"
const MONEY_BUTTON := "GDR_STORAGE_BTN_MONEY"
const SLOT_PREFIX := "GDR_STORAGE_SLOT_"

var panels
## Ends the NPC talk (0x704B); World3D binds it.
var end_talk: Callable
var npc_name := ""
## The window is up (0xB250 {1} came and no close since).
var active := false
var page := 0
## Deposits in flight, by bag slot: {"item_id", "qty", "inst"} -- the reply
## names the slots, the kept list needs the item.
var _pending := {}

## The network (NetClient, or a test's stand-in with the same members).
var net = null

func _init(hud_panels, net_override = null) -> void:
	panels = hud_panels
	net = net_override
	var st := state()
	st.opened.connect(_on_opened)
	st.closed.connect(_on_closed)
	st.listed.connect(func(_c: int, _g: int, _s: Dictionary) -> void: _redraw())
	st.list_refused.connect(func(code: int) -> void: print("GuildStorage: list refused 0x%x" % code))
	st.moved.connect(_on_moved)
	st.max_stack = func(ref_id: int) -> int:
		panels._load_items()
		var it: ItemTableReader.Item = panels._items.get(ref_id)
		return maxi(1, it.max_stack) if it != null else 1

func _net():
	return net if net != null else NetClient

func state() -> GuildStorageState:
	return _net().guild_storage

func window() -> HudWindow:
	return panels._windows.get(WINDOW)

func node(control: String) -> Control:
	var w := window()
	return w.node(control) as Control if w != null else null

func is_open() -> bool:
	var w := window()
	return active and w != null and w.is_visible_in_tree()

## The talk line's 0xB046 {1, 0x0f}: 0x7250.
func request_open(npc_uid: int, name: String) -> void:
	npc_name = name
	print("GuildStorage: 0x7250 open at NPC %d (%s)" % [npc_uid, name])
	state().request_open(npc_uid)

func _on_opened(r: Dictionary) -> void:
	if not bool(r.get("ok", false)):
		var code := int(r.get("code", 0))
		print("GuildStorage: open refused 0x%x %s" % [code, String(r.get("name", ""))])
		panels.guild_storage_refused.emit(code, String(r.get("name", "")))
		# UI_SILKMALL::FUN_0078fc20: the talk ends (0x704B).
		if end_talk.is_valid():
			end_talk.call()
		return
	var w: HudWindow = panels.open(WINDOW)
	if w == null:
		print("GuildStorage: the window could not be built")
		return
	active = true
	page = 0
	_wire(w)
	panels._close_window_boxes(w)
	panels._lattice_takes_clicks(w, SLOT_PREFIX)
	w.show()
	w.move_to_front()
	UiSounds.window_toggled(true, panels._interface_shown(), "guild storage opened (0x79bf40)")
	# The inventory beside it (0x79af20), the original's companion; placed as
	# the personal storage's (OURS, rounds 513 / 593).
	var bag: HudWindow = panels.inventory_companion("guild storage opened (0x79af20)")
	# The bag's gold button: the deposit box while the storage is up.
	panels.wire_bag_money_button()
	if bag != null:
		var view: Vector2 = panels.get_viewport_rect().size
		w.position = Vector2(view.x * 0.5 - w.size.x - 8.0, (view.y - w.size.y) * 0.5).round()
		panels.place_window(bag, Vector2(view.x * 0.5 + 8.0, (view.y - bag.size.y) * 0.5).round())
		bag.move_to_front()
		w.move_to_front()
	_redraw()
	print("GuildStorage: window open at %s; 0x7252 list" % npc_name)
	state().request_list()

func _wire(w: HudWindow) -> void:
	if w.has_meta("gs_wired"):
		return
	w.set_meta("gs_wired", true)
	w.visibility_changed.connect(func() -> void:
		if not w.visible and active:
			_closed_by_window())
	var spin := w.node(SPIN) as Control
	if spin != null:
		spin.connect("spin_changed", func(value: int) -> void:
			page = value
			_redraw())
	var btn := w.node(MONEY_BUTTON) as BaseButton
	if btn != null:
		btn.pressed.connect(func() -> void: open_gold_box(false))

## The window went away (its X, Escape, a hide): 0x79bf40(0) -> 0x7251.
func _closed_by_window() -> void:
	active = false
	panels.cancel_held_icon("the guild storage closed")
	print("GuildStorage: closed; 0x7251")
	state().request_close()

## Escape's and the X's close.
func press_close() -> void:
	var w := window()
	if w != null and w.visible:
		w.hide()
		UiSounds.window_toggled(false, panels._interface_shown(), "Escape: guild storage (vslot_043)")

func _on_closed(r: Dictionary) -> void:
	print("GuildStorage: 0xB251 %s" % ("{1}" if bool(r.get("ok", false)) else "refused 0x%x" % int(r.get("code", 0))))
	if end_talk.is_valid():
		end_talk.call()

func page_count() -> int:
	return maxi(1, int(ceil(float(state().capacity) / GuildStorageNet.PAGE_SLOTS)))

## The lattice for the page shown, and the gold.
func _redraw() -> void:
	var w := window()
	if w == null:
		return
	var st := state()
	panels._set_money_text(w, MONEY, st.gold)
	var grid := w.node(LATTICE) as Control
	if grid == null:
		return
	panels._load_items()
	page = clampi(page, 0, page_count() - 1)
	var spin := w.node(SPIN) as Control
	if spin != null and spin.has_meta("value"):
		UiBuilder.set_spin_range(spin, 0, page_count() - 1)
		if UiBuilder.spin_value(spin) != page:
			spin.set_meta("value", page)
			UiBuilder.set_spin_range(spin, 0, page_count() - 1)
	var first := page * GuildStorageNet.PAGE_SLOTS
	var cells := grid.get_child_count()
	for i in cells:
		var cell := grid.get_child(i)
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		var count := cell.get_node_or_null("CountLabel") as Label
		if count != null:
			count.text = ""
		if icon == null:
			continue
		var slot := first + i
		var it: ItemInstance = st.slots.get(slot)
		if it == null or i >= GuildStorageNet.PAGE_SLOTS:
			icon.texture = null
			panels._set_item_tip(icon, -1)
			panels._set_item_slot_fx(icon, -1)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			for m in ["gs_slot", "gs_item_id", "gs_qty"]:
				if icon.has_meta(m):
					icon.remove_meta(m)
			continue
		var qty: int = it.count if not it.is_equipment else 1
		icon.texture = panels._item_icon(it.ref_item_id)
		panels._set_item_tip(icon, it.ref_item_id, WINDOW, slot)
		panels._set_item_slot_fx(icon, it.ref_item_id, it)
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		icon.set_meta("gs_slot", slot)
		icon.set_meta("gs_item_id", it.ref_item_id)
		icon.set_meta("gs_qty", qty)
		if not icon.has_meta("gs_click_wired"):
			icon.set_meta("gs_click_wired", true)
			icon.gui_input.connect(func(ev: InputEvent) -> void: _on_cell_input(ev, icon))
		if count != null and panels._shows_count(it.ref_item_id, qty):
			count.text = str(qty)

## A click on a stored item picks it up onto the cursor (HeldIcon).
func _on_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if panels._is_pick_click_on(event, icon) and icon.has_meta("gs_slot"):
		panels.pick_up_icon({"kind": WINDOW, "slot": int(icon.get_meta("gs_slot")), "item_id": int(icon.get_meta("gs_item_id")),
			"qty": int(icon.get_meta("gs_qty")), "icon": icon.texture},
			icon.texture, icon, (event as InputEventMouseButton).global_position)

## The storage slot under a screen point on the page shown, or -1.
func slot_at(at: Vector2) -> int:
	var grid := node(LATTICE)
	if grid == null or not window().get_global_rect().has_point(at):
		return -1
	for i in mini(grid.get_child_count(), GuildStorageNet.PAGE_SLOTS):
		var cell := grid.get_child(i) as Control
		if cell != null and cell.get_global_rect().has_point(at):
			return page * GuildStorageNet.PAGE_SLOTS + i
	return -1

func first_free() -> int:
	for i in state().capacity:
		if not state().slots.has(i):
			return i
	return -1

func instance_at(slot: int) -> Object:
	return state().slots.get(slot)

## A bag item put down on the window: the deposit box (purpose 0x10), its fee
## the guild's half; OK sends type 0x1e naming the cell it was put down on.
func deposit_from_bag(bag_slot: int, item_id: int, qty: int, at: Vector2) -> void:
	if not is_open():
		return
	panels._load_items()
	var item: ItemTableReader.Item = panels._items.get(item_id)
	var n := maxi(1, qty)
	var dst := slot_at(at)
	if dst < 0 or state().slots.has(dst):
		dst = first_free()
	var fee := GuildStorageNet.deposit_fee(item.keeping_fee if item != null else 0, n)
	panels._open_store_box(WINDOW, "DepositConfirm", StoreMessageBox.Kind.DEPOSIT, {
		"icon": panels._item_icon(item_id), "name": item.display_name(panels._object_names) if item != null else "",
		"count": n, "max": n, "fixed_price": fee, "stackable": HudPanels.is_stack_item(item),
	}, func(_q: int) -> void:
		if dst < 0:
			print("GuildStorage: deposit not sent -- no empty slot")
			return
		_pending[bag_slot] = {"item_id": item_id, "qty": n, "inst": panels._item_instance("bag", bag_slot)}
		print("GuildStorage: 0x7034 type 0x1e bag %d -> storage %d (fee %d)" % [bag_slot, dst, fee])
		_net().guild_storage_move(GuildStorageNet.encode_deposit(bag_slot, dst, state().npc)))

## A stored item put down on the bag: the withdraw box (purpose 0x11); OK
## sends type 0x1f naming the bag cell (or the first free one).
func withdraw_to_bag(slot: int, item_id: int, qty: int, bag_slot: int) -> void:
	if not is_open():
		return
	panels._load_items()
	var item: ItemTableReader.Item = panels._items.get(item_id)
	var n := maxi(1, qty)
	panels._open_store_box(WINDOW, "WithdrawConfirm", StoreMessageBox.Kind.WITHDRAW, {
		"icon": panels._item_icon(item_id), "name": item.display_name(panels._object_names) if item != null else "",
		"count": n, "max": n, "fixed_price": 0, "stackable": HudPanels.is_stack_item(item),
	}, func(_q: int) -> void:
		var to: int = bag_slot if bag_slot >= 0 else panels.first_empty_bag_slot()
		if to < 0:
			print("GuildStorage: withdraw not sent -- the bag is full")
			return
		print("GuildStorage: 0x7034 type 0x1f storage %d -> bag %d" % [slot, to])
		_net().guild_storage_move(GuildStorageNet.encode_withdraw(slot, to, state().npc)))

## A stored item put down on another cell: type 0x1d with its stack.
func move_inside(src: int, dst: int) -> void:
	if not is_open() or dst < 0 or dst == src:
		return
	var it: ItemInstance = state().slots.get(src)
	if it == null:
		return
	var n: int = it.count if not it.is_equipment else 1
	print("GuildStorage: 0x7034 type 0x1d %d -> %d x%d" % [src, dst, n])
	_net().guild_storage_move(GuildStorageNet.encode_inside(src, dst, n, state().npc))

## The gold boxes: in (purpose 0x12, the bag's button) and out (0x13, the
## window's), the amount from 0 to what can move, at most 1,000,000,000.
func open_gold_box(deposit: bool) -> void:
	if not is_open():
		return
	var carried: int = panels._stats.gold if panels._stats != null else 0
	var balance: int = carried if deposit else state().gold
	panels._open_store_box(WINDOW, "GoldDialog",
		StoreMessageBox.Kind.GOLD_DEPOSIT if deposit else StoreMessageBox.Kind.GOLD_WITHDRAW,
		{"count": 0, "min": 0, "max": mini(maxi(0, balance), StoreMessageBox.GOLD_CAP)},
		func(q: int) -> void:
			if q <= 0:
				return
			print("GuildStorage: 0x7034 type 0x%x gold %d" % [GuildStorageNet.TYPE_GOLD_IN if deposit else GuildStorageNet.TYPE_GOLD_OUT, q])
			_net().guild_storage_move(GuildStorageNet.encode_gold(deposit, q)))

func _on_moved(r: Dictionary) -> void:
	var who: String = _net().current_character_name
	if not bool(r.get("ok", false)):
		var code := int(r.get("code", 0))
		print("GuildStorage: move refused 0x%x" % code)
		# The item operation's refusal box, category 1 (0x778190(1, code)):
		# its line to the system channel, as the store's (OURS: where).
		var key: String = GuildStorageNet.MOVE_ERROR_TEXT.get(code, ItemOpNet.ERROR_TEXT.get(code, ""))
		if key != "":
			panels.system_notice.emit(panels._ui_line(key, key))
		if who != "":
			_net().list_inventory(who)
		return
	match int(r.type):
		GuildStorageNet.TYPE_DEPOSIT:
			var bag_slot := int(r.src) - GuildStorageNet.BAG_OFFSET
			var p: Dictionary = _pending.get(bag_slot, {})
			_pending.erase(bag_slot)
			var it: ItemInstance = p.get("inst") as ItemInstance
			if it == null:
				it = ItemInstance.new()
				it.ref_item_id = int(p.get("item_id", 0))
				panels._load_items()
				var item: ItemTableReader.Item = panels._items.get(it.ref_item_id)
				it.is_equipment = item != null and item.type_ids.size() >= 2 and item.type_ids[0] == 3 and item.type_ids[1] == 1
				it.count = int(p.get("qty", 1))
			state().put(int(r.dst), it)
			print("GuildStorage: deposited bag %d -> storage %d" % [bag_slot, int(r.dst)])
		GuildStorageNet.TYPE_WITHDRAW:
			print("GuildStorage: withdrew storage %d -> bag %d" % [int(r.src), int(r.dst) - GuildStorageNet.BAG_OFFSET])
		GuildStorageNet.TYPE_INSIDE:
			print("GuildStorage: moved %d -> %d x%d" % [int(r.src), int(r.dst), int(r.count)])
		GuildStorageNet.TYPE_GOLD_IN, GuildStorageNet.TYPE_GOLD_OUT:
			print("GuildStorage: gold %s %d, the storage holds %d" % ["in" if int(r.type) == GuildStorageNet.TYPE_GOLD_IN else "out",
				int(r.amount), state().gold])
	_redraw()
	if who != "" and int(r.type) != GuildStorageNet.TYPE_INSIDE:
		_net().list_inventory(who)
		_net().character_stats(who)

## QA (OPENSRO_QA_GUILD_STORAGE): the kept list as one line.
func describe() -> String:
	var parts := PackedStringArray()
	var keys := state().slots.keys()
	keys.sort()
	for k in keys:
		var it: ItemInstance = state().slots[k]
		parts.append("%d:%d x%d" % [int(k), it.ref_item_id, it.count if not it.is_equipment else 1])
	return "capacity %d gold %d [%s]" % [state().capacity, state().gold, ", ".join(parts)]
