extends SceneTree

## Round 652: the icon on the cursor. Retail picks an icon up with one click
## and puts it down with the next (held_icon.gd has what is READ); the user:
## "I left [click] the item once and it sticks to my cursor then I click again
## to drop it in a slot I want", and "When I try drag an item from my person
## into the inventory to a slot I want it moves it to the next available slot
## instead."
##
## - HeldIcon's state machine: pick up, put down on a slot, put down on
##   nothing, the right-click cancel, the tabs and buttons that pass through,
##   and what it swallows.
## - The bag and the paper doll under REAL viewport input (push_input): a
##   click on the worn boots then a click on bag slot 10 sends OP_UNEQUIP
##   naming slot 10 (retail's client does; the server, like retail's, still
##   uses the first free slot); a bag item carried to page 2 through its tab; a bag item
##   put on the doll. The packets are read back off NetClient's peer.
## - The encoder: the unequip's trailing target slot.
##
## The NEGATIVE is the integration half: on the base a click-click sends
## nothing, and the old press-drag-release sent OP_UNEQUIP with no slot.
## Synthetic fixtures only:
##   godot4 --headless --path client --script res://scripts/ui/hud/held_icon_test.gd

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const HELD_PATH := "res://scripts/ui/hud/held_icon.gd"
const MFRAME := "interface\\frame\\mframe_wnd_"
const MFRAME_PIECES := ["left_up", "mid_up", "right_up", "left_side", "right_side", "left_down", "mid_down", "right_down"]
const TAB_ART := ["interface\\ifcommon\\com_tab_on.ddj", "interface\\ifcommon\\com_tab_off.ddj",
	"interface\\ifcommon\\com_short_tab_on.ddj", "interface\\ifcommon\\com_short_tab_off.ddj",
	"interface\\pet\\pt_block.ddj"]
const OP_MOVE := 0x0032
const OP_EQUIP := 0x0042
const OP_UNEQUIP := 0x0043

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	root.size = Vector2i(1920, 1080)
	await _state_machine_checks()
	_encoder_checks()
	await _panel_checks()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- HeldIcon on its own --------------------------------------------------------

func _mouse(button: MouseButton, pressed: bool, at: Vector2, shift := false) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	ev.shift_pressed = shift
	return ev

func _texture(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.4, 0.3, 1.0))
	return ImageTexture.create_from_image(img)

func _state_machine_checks() -> void:
	_check(ResourceLoader.exists(HELD_PATH), "the held-icon controller exists (%s)" % HELD_PATH)
	if not ResourceLoader.exists(HELD_PATH):
		return
	var Held: GDScript = load(HELD_PATH)
	var held: Node = Held.new()
	root.add_child(held)
	var drops: Array = []
	held.set("drop_handler", func(what: Dictionary, at: Vector2) -> void: drops.append([what, at]))
	var tab_rect := Rect2(500, 500, 40, 20)
	held.set("passes_through", func(at: Vector2) -> bool: return tab_rect.has_point(at))
	var source := TextureRect.new()
	root.add_child(source)

	# The pick-up click (0x652540's 0x202, no Ctrl/Shift/Alt).
	_check(bool(Held.call("is_pick_click", _mouse(MOUSE_BUTTON_LEFT, false, Vector2.ZERO))),
		"a plain left RELEASE is the pick-up click")
	_check(not bool(Held.call("is_pick_click", _mouse(MOUSE_BUTTON_LEFT, true, Vector2.ZERO))),
		"a left press is not (a slot's press does nothing: 0x46fd60)")
	_check(not bool(Held.call("is_pick_click", _mouse(MOUSE_BUTTON_LEFT, false, Vector2.ZERO, true))),
		"a Shift+left release is not (GetKeyState 0x10 sends it to the slot's own handler)")
	_check(not bool(Held.call("is_pick_click", _mouse(MOUSE_BUTTON_RIGHT, false, Vector2.ZERO))),
		"a right release is not")

	# Pick up.
	var what := {"kind": "bag", "slot": 3, "item_id": 4842, "qty": 1}
	_check(bool(held.call("pick_up", what, _texture(32, 32), source, Vector2(100, 100))), "pick up: accepted")
	_check(bool(held.call("is_holding")) and String(held.call("kind")) == "bag", "pick up: holding the bag item")
	var ghost := held.get_node_or_null("HeldIconGhost") as Control
	_check(ghost != null and ghost.global_position == Vector2(84, 84),
		"the icon is drawn centred on the cursor (CGame 0x8423d0: mouse - size/2; got %s)" % [ghost.global_position if ghost != null else null])
	_check(source.modulate.a < 1.0, "the slot it came from is dimmed")
	_check(not bool(held.call("pick_up", {"kind": "bag", "slot": 4}, null, null, Vector2.ZERO)),
		"a second pick-up is refused while one is held")

	# What passes on and what is swallowed (0x6523d0).
	var motion := InputEventMouseMotion.new()
	motion.global_position = Vector2(300, 200)
	_check(not bool(held.call("handle", motion)), "a mouse move passes on (0x200)")
	_check(ghost != null and ghost.global_position == Vector2(284, 184), "... and the icon follows it")
	var key := InputEventKey.new()
	key.keycode = KEY_I
	key.pressed = true
	_check(not bool(held.call("handle", key)), "a key passes on (0x100)")
	_check(bool(held.call("handle", _mouse(MOUSE_BUTTON_LEFT, true, Vector2(300, 200)))),
		"a left press is swallowed (0x201)")
	_check(bool(held.call("is_holding")) and drops.is_empty(), "... and puts nothing down")
	_check(bool(held.call("handle", _mouse(MOUSE_BUTTON_WHEEL_UP, true, Vector2(300, 200)))),
		"the wheel is swallowed while holding (0x6523d0's default)")
	_check(not bool(held.call("handle", _mouse(MOUSE_BUTTON_LEFT, true, Vector2(510, 505)))),
		"a left press on a tab/button passes on (CIFSelectableArea 0xee96c0 / CIFButton 0xee9828)")
	_check(not bool(held.call("handle", _mouse(MOUSE_BUTTON_LEFT, false, Vector2(510, 505)))),
		"... and so does its release")
	_check(bool(held.call("is_holding")) and drops.is_empty(), "... still holding, nothing put down")

	# Put down on a slot.
	_check(bool(held.call("handle", _mouse(MOUSE_BUTTON_LEFT, false, Vector2(640, 360)))),
		"the next left release is taken")
	_check(drops.size() == 1 and int((drops[0][0] as Dictionary).get("slot", -1)) == 3 and drops[0][1] == Vector2(640, 360),
		"put down: the host gets the payload and the point (%s)" % [drops])
	_check(not bool(held.call("is_holding")), "put down: nothing held after")
	_check(held.get_node_or_null("HeldIconGhost") == null or (held.get_node("HeldIconGhost") as Node).is_queued_for_deletion(),
		"put down: the ghost is gone")
	_check(source.modulate == Color.WHITE, "put down: the source is lit again")
	_check(not bool(held.call("handle", _mouse(MOUSE_BUTTON_LEFT, false, Vector2(640, 360)))),
		"with nothing held, a click is not the controller's")

	# Put down on something that takes nothing (an invalid slot): the host
	# does nothing with it, and it is let go all the same (0x6523d0 releases
	# after the offer, whatever the answer).
	drops.clear()
	held.set("drop_handler", func(_w: Dictionary, _at: Vector2) -> void: drops.append("refused"))
	held.call("pick_up", {"kind": "worn", "slot": 5, "item_id": 7}, _texture(32, 32), source, Vector2(10, 10))
	held.call("handle", _mouse(MOUSE_BUTTON_LEFT, true, Vector2(5, 5)))
	held.call("handle", _mouse(MOUSE_BUTTON_LEFT, false, Vector2(5, 5)))
	_check(drops == ["refused"] and not bool(held.call("is_holding")),
		"put down where nothing takes it: offered once, then let go")

	# Cancel: a right press (0x204).
	drops.clear()
	held.call("pick_up", {"kind": "skill", "skill_id": 3, "code": "SKILL_CH_SWORD_SMASH_A_01"}, _texture(32, 32), source, Vector2(10, 10))
	_check(bool(held.call("handle", _mouse(MOUSE_BUTTON_RIGHT, true, Vector2(10, 10)))), "a right press is taken")
	_check(not bool(held.call("is_holding")) and drops.is_empty(), "a right press cancels: let go, nothing put down")
	_check(source.modulate == Color.WHITE, "cancel: the source is lit again")
	held.queue_free()
	source.queue_free()
	await process_frame

# --- The encoder -------------------------------------------------------------------

func _encoder_checks() -> void:
	var plain: PackedByteArray = EquipmentNet.encode_unequip("Ab", 5)
	_check(plain.size() == 2 + 2 + 4, "an unequip with no target is the old 8 bytes (got %d)" % plain.size())
	var eq_script: GDScript = load("res://scripts/net/equipment.gd")
	var aimed: PackedByteArray = eq_script.call("encode_unequip", "Ab", 5, 10) if _takes_target() else PackedByteArray()
	_check(aimed.size() == 12 and aimed.decode_u32(4) == 5 and aimed.decode_s32(8) == 10,
		"an unequip onto bag slot 10 ends with the worn slot, then 10 (got %s)" % [aimed])

func _takes_target() -> bool:
	for m in (load("res://scripts/net/equipment.gd") as GDScript).get_script_method_list():
		if m["name"] == "encode_unequip":
			return (m["args"] as Array).size() >= 3
	return false

# --- The windows, under real input --------------------------------------------------

func _control(control_name: String, type: String, rect: String, ddj: String = "",
		id: int = 0, style: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"1\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"%d\"\n\t\tText=STRING,\"\"\n\t}\n" % [
		control_name, type, ddj, id, rect, style]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n%s}\n" % body

func _registry() -> String:
	return _layout(_control("GDR_MAINPOPUP", "CIFMainPopup", "595,262,388,408", MFRAME, 25, 64)
		+ _control("GDR_STORAGEROOM", "CIFStorageRoom", "0,0,254,317", MFRAME, 19, 64))

func _mainpopup() -> String:
	return _layout(_control("GDR_PARTY", "CIFParty", "13,38,364,337", "", 72)
		+ _control("GDR_EQUIPMENT", "CIFEquipment", "198,41,178,355", "", 71)
		+ _control("GDR_INVENTORY", "CIFInventory", "13,63,176,333", "", 70)
		+ _control("GDR_MAINPOPUP_BG_TILE", "CIFStatic", "40,154,308,124", "", 3))

func _inventory() -> String:
	return _layout(_control("GDR_INVENTORY_STA_MONEY", "CIFStatic", "0,305,176,28", "interface\\inventory\\int_window_downbox.ddj", 10)
		+ _control("GDR_INVENTORY_LATTICE", "CIFLattice", "18,13,144,288", "", 2)
		+ _control("GDR_INVENTORY_FRAME", "CIFFrame", "0,0,176,308", "", 0))

const WORN := {100: "5,86", 101: "5,129", 102: "141,86", 103: "141,129", 104: "5,172", 105: "141,172",
	106: "12,12", 107: "134,12", 108: "141,308", 109: "5,215", 110: "141,215", 111: "5,258", 112: "141,258"}

func _equipment() -> String:
	var body := ""
	for id in WORN:
		body += _control("GDR_EQUIPMENT_SLOT_%d" % id, "CIFSlotWithHelp", WORN[id] + ",32,32", "", id)
	body += _control("GDR_EQ_FRAME", "CIFFrame", "0,0,178,355", "", 4)
	return _layout(body)

func _builder() -> UiBuilder:
	var rows := PackedStringArray()
	for pair in [["UIIT_STT_INVENTORY", "Inventory"], ["UIIT_CTL_BELOINGING", "Page 1"],
			["UIIT_STT_INVENTORY_EXTENSION_TEB", "Page 2"], ["UIIT_STT_INVENTORY_EXTENSION_TEB2", "Page 3"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	var key := "%s%s%s" % ["resinfo\\ifmainpopup.txt", char(1), char(2).join(PackedStringArray(["APPLY_MENTOR_SYSTEM"]))]
	cache[key] = UiLayoutParser.parse(_mainpopup(), true, PackedStringArray(["APPLY_MENTOR_SYSTEM"]))
	cache["resinfo\\ifinventory.txt"] = UiLayoutParser.parse(_inventory())
	cache["resinfo\\ifequipment.txt"] = UiLayoutParser.parse(_equipment())
	cache["resinfo\\ifparty.txt"] = UiLayoutParser.parse(_layout(_control("GDR_PARTY_FRAMEL", "CIFFrame", "0,0,364,303", "", 1)))
	cache["resinfo\\ifstorageroom.txt"] = UiLayoutParser.parse(_layout(_control("GDR_STORAGE_BG_CTRL", "CIFSubFrame", "9,38,236,241", "", 4)))
	for other in ["ifplayerinfo_trijob2", "ifskill", "ifaction", "ifapprenticeship"]:
		cache["resinfo\\%s.txt" % other] = UiLayoutParser.parse(_layout(_control("GDR_X_FRAME", "CIFFrame", "0,0,300,300", "", 1)))
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	var textures: Dictionary = builder.get("_texture_cache")
	for piece in MFRAME_PIECES:
		textures[(MFRAME + piece + ".ddj").to_lower()] = _texture(40, 48)
	for path in TAB_ART + ["interface\\ifcommon\\com_kindred_china16.ddj"]:
		textures[path.to_lower()] = _texture(60, 24)
	return builder

func _bag_slot(index: int, item_id: int, quantity: int) -> InventoryNet.Slot:
	var sl := InventoryNet.Slot.new()
	sl.slot_index = index
	sl.item_id = item_id
	sl.quantity = quantity
	return sl

func _worn(slot: int, item_id: int) -> EquipmentNet.Equipped:
	var e := EquipmentNet.Equipped.new()
	e.slot = slot
	e.item_id = item_id
	return e

## A left click at a point, as the OS delivers it: a move there, the press,
## the release -- through the viewport, so Godot's own hit-testing and
## HudPanels._input decide who gets each event.
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

## The packets NetClient wrote since the last call, as [opcode, payload].
func _sent(net: Node) -> Array:
	var peer := net.get("_peer") as StreamPeerBuffer
	var out: Array = []
	if peer == null:
		return out
	var bytes := peer.data_array
	var at := 0
	while at + 6 <= bytes.size():
		var size := bytes.decode_u16(at) & 0x7FFF
		var op := bytes.decode_u16(at + 2)
		out.append([op, bytes.slice(at + 6, at + 6 + size)])
		at += 6 + size
	peer.clear()
	return out

## The worn slot and trailing target of an OP_UNEQUIP payload, or [-1, -1].
func _unequip_fields(payload: PackedByteArray) -> Array:
	var name_len := payload.decode_u16(0)
	var at := 2 + name_len
	var worn := payload.decode_u32(at) if payload.size() >= at + 4 else -1
	var to := payload.decode_s32(at + 4) if payload.size() >= at + 8 else -1
	return [worn, to]

func _of(packets: Array, op: int) -> Array:
	return packets.filter(func(p: Array) -> bool: return int(p[0]) == op)

func _panel_checks() -> void:
	var net := root.get_node_or_null("NetClient")
	_check(net != null, "the NetClient autoload is there")
	if net == null:
		return
	# NetClient writes into a buffer the test reads back; its own poll (which
	# would see no socket and disconnect) is paused for the run.
	net.set_process(false)
	net.set("_connected", true)
	net.set("_peer", StreamPeerBuffer.new())
	net.set("current_character_name", "Tester")
	net.set("last_inventory_capacity", 40)

	var panels: Control = (load(PANELS_PATH) as GDScript).new(_builder())
	root.add_child(panels)
	await process_frame
	var window: Control = panels.call("open", "inventory")
	await process_frame
	await process_frame
	var grid := window.call("node", "GDR_INVENTORY_LATTICE") as Control
	_check(grid != null and grid.get_child_count() >= 32, "the bag's lattice is built")
	if grid == null:
		return
	# Slot 0 holds a potion, so the first free slot is 1 -- not the 10 the
	# player clicks.
	panels.call("_fill_inventory_grid", [_bag_slot(0, 4, 5), _bag_slot(3, 4843, 1)])
	panels.call("_fill_equipment_slots", [_worn(5, 4842)])
	await process_frame
	# No item table here, so give the icons a texture of their own.
	var boots_slot := window.call("node", "GDR_EQUIPMENT_SLOT_105") as Control
	var boots := boots_slot.get_node_or_null("ItemIcon") as TextureRect if boots_slot != null else null
	_check(boots != null and boots.is_visible_in_tree(), "the doll's boots slot is on screen")
	if boots == null:
		return
	boots.texture = _texture(32, 32)
	for i in [0, 3]:
		(grid.get_child(i).get_node("ItemIcon") as TextureRect).texture = _texture(32, 32)
	_sent(net)

	# The user's case: click the boots on the doll, then click bag slot 10.
	var cell10 := (grid.get_child(10) as Control).get_global_rect().get_center()
	await _click(boots.get_global_rect().get_center())
	var held = panels.get("held_icon")
	_check(held != null and bool(held.call("is_holding")) and String(held.call("kind")) == "worn",
		"one click on the worn boots puts them on the cursor")
	_check(_of(_sent(net), OP_UNEQUIP).is_empty(), "... and sends nothing yet")
	await _click(cell10)
	var unequips := _of(_sent(net), OP_UNEQUIP)
	_check(unequips.size() == 1, "the second click, on bag slot 10, sends one OP_UNEQUIP (got %d)" % unequips.size())
	if unequips.size() == 1:
		var f := _unequip_fields(unequips[0][1])
		_check(f[0] == 5 and f[1] == 10,
			"... taking off worn slot 5 and naming bag slot 10, the one clicked, as retail's client does (got worn %d, target %d)" % [f[0], f[1]])
	_check(held != null and not bool(held.call("is_holding")), "... and the cursor is empty again")

	# A bag item carried to page 2: click it, click the Page 2 tab (it passes
	# through, 0x6523d0), click a slot there.
	var pane := window.call("node", "GDR_INVENTORY") as Control
	var strip := pane.get_node_or_null("BagPageTabs") as Control if pane != null else null
	_check(strip != null and strip.get_child_count() >= 2, "the bag shows its page tabs")
	if strip != null and strip.get_child_count() >= 2:
		await _click((grid.get_child(3) as Control).get_global_rect().get_center())
		_check(held != null and bool(held.call("is_holding")) and int(held.get("payload").get("slot", -1)) == 3,
			"a click on bag slot 3 picks it up")
		await _click((strip.get_child(1) as Control).get_global_rect().get_center())
		_check(int(panels.call("bag_page")) == 1 and held != null and bool(held.call("is_holding")),
			"a click on the Page 2 tab turns the page and keeps holding it")
		await _click((grid.get_child(2) as Control).get_global_rect().get_center())
		var moves := _of(_sent(net), OP_MOVE)
		_check(moves.size() == 1, "a click on page 2's third cell sends one OP_MOVE (got %d)" % moves.size())
		if moves.size() == 1:
			var p: PackedByteArray = moves[0][1]
			var nl := p.decode_u16(0)
			_check(p.decode_s64(2 + nl) == 3 and p.decode_s64(10 + nl) == 34,
				"... from slot 3 to slot 34 (got %d -> %d)" % [p.decode_s64(2 + nl), p.decode_s64(10 + nl)])
		panels.call("select_bag_page", 0)
		await process_frame

	# A bag item put on the doll: OP_EQUIP naming the worn slot.
	await _click((grid.get_child(3) as Control).get_global_rect().get_center())
	var mail := (window.call("node", "GDR_EQUIPMENT_SLOT_101") as Control)
	await _click(mail.get_global_rect().get_center())
	var equips := _of(_sent(net), OP_EQUIP)
	_check(equips.size() == 1, "a bag item clicked onto the doll's mail slot sends one OP_EQUIP (got %d)" % equips.size())

	# A right click cancels: nothing is sent.
	await _click((grid.get_child(3) as Control).get_global_rect().get_center())
	for pressed in [true, false]:
		var rb := InputEventMouseButton.new()
		rb.button_index = MOUSE_BUTTON_RIGHT
		rb.pressed = pressed
		rb.position = cell10
		rb.global_position = cell10
		root.push_input(rb)
		await process_frame
	_check(held != null and not bool(held.call("is_holding")), "a right click lets the held item go")
	await _click(cell10)
	_check(_sent(net).is_empty(), "... and the next click sends nothing")

	# Overlapping windows: a drop belongs to the one drawn in front (r2 of the
	# live run put a bag item down on the warehouse where it covered the
	# store, and the store's sell dialog opened).
	var storage: Control = panels.call("open", "storage")
	await process_frame
	_check(storage != null, "the warehouse opens")
	if storage != null:
		storage.global_position = window.global_position
		storage.move_to_front()
		await process_frame
		var p := storage.get_global_rect().get_center()
		_check(window.get_global_rect().has_point(p), "the probe: the point is over both windows")
		_check(panels.call("_topmost_window_at", p) == storage,
			"where the warehouse covers the bag, the warehouse (in front) takes the drop")
		window.move_to_front()
		_check(panels.call("_topmost_window_at", p) == window, "... and the bag once it is in front again")
		storage.hide()

	net.set("_connected", false)
	net.set("_peer", null)
	net.set("last_inventory_capacity", 0)
	net.set_process(true)
