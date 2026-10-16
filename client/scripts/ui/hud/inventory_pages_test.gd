extends SceneTree

## Round 633: the inventory window as the client builds it.
##
## - Registry frames drawn again. ginterface.txt gives GDR_MAINPOPUP,
##   GDR_STORAGEROOM and 41 more entries Style 64, which the builder's
##   0x8b5710 test hides on the WINDOW at creation (its ShowWindow(1) shows it
##   again). Round 630 applied it to HudWindow's frame child, which nothing
##   showed: the inventory, character, party, skill panes, the warehouse and
##   the exchange lost their frames. A Style-64 control INSIDE a layout (the
##   party leader's mark) stays hidden, as round 630 made it.
## - The bag's pages (IFInventory 0x6b6620 / 0x6b3d00): one tab per 32 slots,
##   at most three, at their code-given rects with the tab art; the shown
##   page's 32 slots in the lattice's 32 cells; the slots past the size locked.
## - The gold colour (0x5d3df0) at every threshold, on the purse's number.
## - The equipment pane's slot backdrops (CIFEquipment::vslot_013) at their
##   READ places and sizes, in both modes.
## - The paper doll's arrows (0x6ab920 / 0x6ab960 / 0x6ab9a0) and their
##   repeat (1000 ms, then 50 ms), and PaperDoll's retail camera.
## - The bag list's trailing capacity (InventoryNet).
## - Round 791: a bag avatar put down on any avatar window, or on a worn slot
##   in the equipment view, is over the equipment pane (the drop that sends
##   0x7034 type 0x24); the pane's layout root is 0x0 and missed them all.
##
## Synthetic fixtures only (names, IDs and rects copied from the layouts):
##   godot4 --headless --path client --script res://scripts/ui/hud/inventory_pages_test.gd

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const DOLL_PATH := "res://scripts/ui/paper_doll.gd"
const GOLD_PATH := "res://scripts/ui/gold_color.gd"
const MFRAME := "interface\\frame\\mframe_wnd_"
const MFRAME_PIECES := ["left_up", "mid_up", "right_up", "left_side", "right_side", "left_down", "mid_down", "right_down"]
const TAB_ART := ["interface\\ifcommon\\com_tab_on.ddj", "interface\\ifcommon\\com_tab_off.ddj",
	"interface\\ifcommon\\com_short_tab_on.ddj", "interface\\ifcommon\\com_short_tab_off.ddj",
	"interface\\pet\\pt_block.ddj"]

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, rect: String, ddj: String = "",
		id: int = 0, style: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"1\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"%d\"\n\t\tText=STRING,\"\"\n\t}\n" % [
		control_name, type, ddj, id, rect, style]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n%s}\n" % body

## ginterface.txt's two entries, each with the Style 64 the archive gives it.
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
const AVATAR := {113: "5,86", 114: "5,129", 115: "141,129", 116: "141,86", 117: "5,172"}

func _equipment() -> String:
	var body := ""
	for id in AVATAR:
		body += _control("GDR_AVATAR_SLOT_%02d" % (id - 112), "CIFSlotWithHelp", AVATAR[id] + ",32,32", "", id)
	for id in WORN:
		body += _control("GDR_EQUIPMENT_SLOT_%d" % id, "CIFSlotWithHelp", WORN[id] + ",32,32", "", id)
	body += _control("GDR_EQ_BTN_CHANGE_EQUIP_SLOT", "CIFButton", "1,305,40,40", "", 14)
	body += _control("GDR_EQ_BTN_CHANGE_AVATAR_SLOT", "CIFButton", "1,305,40,40", "", 13)
	body += _control("GDR_EQ_BTN_ROTATE_RESET", "CIFButton", "81,327,16,16", "", 12)
	body += _control("GDR_EQ_BTN_ROTATE_RIGHT", "CIFButton", "96,327,28,16", "", 11)
	body += _control("GDR_EQ_BTN_ROTATE_LEFT", "CIFButton", "54,327,28,16", "", 10)
	body += _control("GDR_EQ_NORMALTILE_BG", "CIFNormalTile", "12,12,154,331", "", 5)
	body += _control("GDR_EQ_FRAME", "CIFFrame", "0,0,178,355", "", 4)
	return _layout(body)

func _party() -> String:
	return _layout(_control("GDR_PTY_PARTY_LEADER", "CIFStatic", "33,27,12,12", "", 40, 64)
		+ _control("GDR_PARTY_FRAMEL", "CIFFrame", "0,0,364,303", "", 1))

func _texture(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.4, 0.3, 1.0))
	return ImageTexture.create_from_image(img)

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
	cache["resinfo\\ifparty.txt"] = UiLayoutParser.parse(_party())
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

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	root.size = Vector2i(1920, 1080)
	var panels_script := load(PANELS_PATH) as GDScript
	var builder := _builder()
	var panels: Control = panels_script.new(builder)
	# The panels' own party state, so the party checks leave the NetClient
	# autoload's alone for later suites (round 711's review, 9i).
	panels.set("party_state", PartyState.new())
	root.add_child(panels)
	await process_frame
	await _registry_checks(panels)
	_party_mark_checks(panels)
	await _page_checks(panels, builder)
	_gold_checks(panels)
	_backdrop_checks(panels)
	_avatar_drop_checks(panels)
	_rotation_checks(panels)
	_doll_checks()
	await _doll_pixel_checks(panels)
	_capacity_checks()
	await _seal_edge_checks(panels)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _registry_checks(panels: Control) -> void:
	var window: Control = panels.call("open", "inventory")
	await process_frame
	var frame := window.get_node_or_null("RegistryFrame") as CanvasItem if window != null else null
	_check(frame != null and frame.is_visible_in_tree(),
		"the main popup's frame (GDR_MAINPOPUP, Style 64) is drawn on the inventory tab")
	panels.call("open", "party")
	await process_frame
	_check(frame != null and frame.is_visible_in_tree(), "... and on the party tab")
	var leader := window.call("node", "GDR_PTY_PARTY_LEADER") as CanvasItem
	_check(leader != null and not leader.visible,
		"a Style-64 control inside a layout (the party leader's mark) stays hidden at creation")
	var storage: Control = panels.call("open", "storage")
	await process_frame
	var sframe := storage.get_node_or_null("RegistryFrame") as CanvasItem if storage != null else null
	_check(sframe != null and sframe.is_visible_in_tree(),
		"the warehouse's frame (GDR_STORAGEROOM, Style 64) is drawn")
	if storage != null:
		storage.hide()
	panels.call("open", "inventory")
	await process_frame

func _avatar_drop_checks(panels: Control) -> void:
	var window: Control = panels.call("open", "inventory")
	for avatar in [true, false]:
		panels.call("set_equipment_avatar_mode", avatar)
		var names: Array = []
		if avatar:
			for id in AVATAR:
				names.append("GDR_AVATAR_SLOT_%02d" % (id - 112))
		else:
			for id in WORN:
				if id != 108:
					names.append("GDR_EQUIPMENT_SLOT_%d" % id)
		for n in names:
			var slot := window.call("node", n) as Control
			var at := slot.get_global_rect().get_center() if slot != null else Vector2(-1, -1)
			_check(bool(panels.call("_over_equipment_pane", at)) and int(panels.call("_bag_slot_at", at)) < 0,
				"%s (%s view) is over the equipment pane, not a bag cell, for an avatar's drop" % [n, "avatar" if avatar else "equipment"])
	var cell := (window.call("node", "GDR_INVENTORY_LATTICE") as Control).get_child(0) as Control
	_check(not bool(panels.call("_over_equipment_pane", cell.get_global_rect().get_center())),
		"a bag cell is not over the equipment pane")
	panels.call("set_equipment_avatar_mode", false)

func _party_mark_checks(panels: Control) -> void:
	# Round 711: the marks follow the client's party state through the party
	# pane (HudPartyPane), not a setter of their own.
	var window: Control = panels.call("open", "party")
	var pane = panels.get("party_pane")
	if pane == null:
		_check(false, "HudPanels builds the party pane with the popup (party_pane)")
		return
	var mark := window.call("node", "GDR_PTY_PARTY_LEADER") as CanvasItem
	var state: PartyState = pane.state
	var info := PartyNet.PartyInfo.new()
	info.mask = 0xff
	info.party_id = 7
	info.leader_jid = 101
	info.flags = 1
	var m := PartyNet.Member.new()
	m.mask = 0xff
	m.jid = 101
	m.member_name = "Aria"
	info.members.append(m)
	state.handle(PartyNet.OP_PARTY_INFO, PartyNet.encode_party_info(info))
	_check(mark != null and mark.is_visible_in_tree(), "in a party the leader mark shows (IFParty 0x6d6640)")
	var gone := PartyNet.Event.new()
	gone.kind = PartyNet.EVENT_DISSOLVED
	state.handle(PartyNet.OP_EVENT, PartyNet.encode_event(gone))
	_check(mark != null and not mark.visible, "out of a party it hides again")
	panels.call("open", "inventory")

func _page_checks(panels: Control, builder: UiBuilder) -> void:
	if not panels.has_method("select_bag_page"):
		_check(false, "HudPanels pages the bag (select_bag_page)")
		return
	for pair in [[0, 1], [1, 1], [32, 1], [33, 2], [64, 2], [65, 3], [96, 3], [200, 3]]:
		_check(int(panels.call("bag_pages", pair[0])) == pair[1],
			"a bag of %d slots has %d page(s)" % pair)
	var window: Control = panels.call("open", "inventory")
	var pane := window.call("node", "GDR_INVENTORY") as Control
	var strip := pane.get_node_or_null("BagPageTabs") as Control if pane != null else null
	_check(strip != null and strip.get_child_count() == 3,
		"with no size from the server the bag shows three tabs")
	# The NetClient autoload, by path: a --script run compiles this file
	# before autoloads are registered.
	var net := root.get_node_or_null("NetClient")
	_check(net != null, "the NetClient autoload is there")
	if net == null:
		return
	net.set("last_inventory_capacity", 40)
	var slots := [_slot(0, 1, 1), _slot(37, 2, 3)]
	panels.call("_fill_inventory_grid", slots)
	await process_frame
	strip = pane.get_node_or_null("BagPageTabs") as Control
	_check(strip != null and strip.get_child_count() == 2, "a size of 40 shows two tabs")
	if strip == null or strip.get_child_count() < 2:
		return
	var t0 := strip.get_child(0) as TextureButton
	var t1 := strip.get_child(1) as TextureButton
	_check(Rect2(t0.position, t0.size) == Rect2(4, -23, 60, 24) and Rect2(t1.position, t1.size) == Rect2(64, -23, 56, 24),
		"the tabs sit at 0x6b6620's rects (got %s, %s)" % [Rect2(t0.position, t0.size), Rect2(t1.position, t1.size)])
	var tex := func(path: String) -> Texture2D: return builder.load_texture(path)
	_check(t0.texture_normal == tex.call("interface\\ifcommon\\com_tab_on.ddj") and t1.texture_normal == tex.call("interface\\ifcommon\\com_short_tab_off.ddj"),
		"page 1 is selected: com_tab_on on the first tab, com_short_tab_off on the second")
	var t0_text := t0.get_node_or_null("Text") as Label
	_check(t0_text != null and t0_text.text == "Page 1", "the first tab reads UIIT_CTL_BELOINGING's text")
	var grid := window.call("node", "GDR_INVENTORY_LATTICE") as Control
	var icon0 := grid.get_child(0).get_node("ItemIcon") as TextureRect
	_check(int(icon0.get_meta("inv_slot", -1)) == 0, "page 1's cell 0 is bag slot 0")
	_check(Rect2(icon0.position, icon0.size) == Rect2(0, 0, 32, 32),
		"a bag icon is the slot's 32x32 at its cell's top-left (got %s)" % Rect2(icon0.position, icon0.size))
	panels.call("select_bag_page", 1)
	await process_frame
	_check(int(panels.call("bag_page")) == 1, "page 2 is shown")
	_check(t1.texture_normal == tex.call("interface\\ifcommon\\com_short_tab_on.ddj") and t0.texture_normal == tex.call("interface\\ifcommon\\com_tab_off.ddj"),
		"the second tab is selected")
	var icon5 := grid.get_child(5).get_node("ItemIcon") as TextureRect
	_check(int(icon5.get_meta("inv_slot", -1)) == 37, "page 2's cell 5 is bag slot 37")
	_check(not icon0.has_meta("inv_slot"), "page 2's cell 0 (slot 32) is empty")
	var icon8 := grid.get_child(8).get_node("ItemIcon") as TextureRect
	_check(bool(icon8.get_meta("inv_locked", false)) and icon8.texture == tex.call("interface\\pet\\pt_block.ddj"),
		"page 2's cell 8 (slot 40, past the size) is locked with pt_block")
	var icon7 := grid.get_child(7).get_node("ItemIcon") as TextureRect
	_check(not bool(icon7.get_meta("inv_locked", true)), "page 2's cell 7 (slot 39) is not locked")
	var c5 := (grid.get_child(5) as Control).get_global_rect().get_center()
	var c8 := (grid.get_child(8) as Control).get_global_rect().get_center()
	_check(int(panels.call("_bag_slot_at", c5)) == 37 and int(panels.call("_bag_slot_at", c8)) == -1,
		"a drop lands on the shown page's slot, and not on a locked one")
	_check(t0.action_mode == BaseButton.ACTION_MODE_BUTTON_PRESS, "a tab acts on the press (0x64cb80 answers 0x201)")
	# With page 2 shown, slot 0 (page 1) still resolves: the drop onto the
	# quickslot and the sounds read the bag list, not the cells.
	_check(int(panels.call("_bag_item_id_at_slot", 0)) == 1 and int(panels.call("_bag_item_id_at_slot", 37)) == 2
		and int(panels.call("_bag_item_id_at_slot", 5)) == -1,
		"an item's id resolves on any page (slot 0 -> 1, slot 37 -> 2, empty slot 5 -> -1)")
	panels.call("select_bag_page", 2)
	_check(int(panels.call("bag_page")) == 1, "a page the size does not have cannot be selected")
	net.set("last_inventory_capacity", 0)

## The seal star (ItemSealEdge): a Rarity 2 or 6 item (0x8ba600) in a bag
## or worn slot gets the edge on its icon; another item, or an emptied slot,
## shows none.
func _seal_edge_checks(panels: Control) -> void:
	var items := {}
	for pair in [[501, 2], [502, 6], [503, 0], [504, 3]]:
		var it := ItemTableReader.Item.new()
		it.id = pair[0]
		it.rarity = pair[1]
		items[it.id] = it
	panels.call("_load_items")
	var known: Dictionary = panels.get("_items")
	known.merge(items, true)
	var net := root.get_node_or_null("NetClient")
	if net != null:
		net.set("last_inventory_capacity", 32)
	var window: Control = panels.call("open", "inventory")
	panels.call("select_bag_page", 0)
	panels.call("_fill_inventory_grid", [_slot(0, 501, 1), _slot(1, 502, 1), _slot(2, 503, 1), _slot(3, 504, 1)])
	await process_frame
	var grid := window.call("node", "GDR_INVENTORY_LATTICE") as Control
	var shown := func(i: int) -> bool:
		var edge := grid.get_child(i).get_node("ItemIcon").get_node_or_null("SealEdge") as CanvasItem
		return edge != null and edge.visible
	_check(shown.call(0) and shown.call(1), "Rarity 2 and 6 items show the seal edge in the bag")
	_check(not shown.call(2) and not shown.call(3), "Rarity 0 and 3 items do not")
	var edge0 := grid.get_child(0).get_node("ItemIcon").get_node("SealEdge")
	var phase := int(edge0.get("counter"))
	panels.call("_fill_inventory_grid", [_slot(0, 501, 1), _slot(2, 503, 1)])
	await process_frame
	_check(shown.call(0) and int(edge0.get("counter")) == phase, "a refill keeps an unchanged seal item's phase")
	_check(not shown.call(1), "an emptied slot hides its edge")
	_check(grid.get_child(0).get_node("ItemIcon").get_child(0) == edge0
		and grid.get_child(0).get_node("CountLabel").get_index() > grid.get_child(0).get_node("ItemIcon").get_index(),
		"the edge draws after the icon and before the count (vslot_013's order)")
	panels.call("_fill_equipment_slots", [_worn(6, 501), _worn(7, 503)])
	var worn := func(i: int) -> bool:
		var slot := window.call("node", "GDR_EQUIPMENT_SLOT_%d" % (100 + i)) as Control
		var edge := slot.get_node("ItemIcon").get_node_or_null("SealEdge") as CanvasItem if slot != null else null
		return edge != null and edge.visible
	_check(worn.call(6) and not worn.call(7), "a worn seal item shows the edge; a worn normal item does not")
	panels.call("_fill_equipment_slots", [])
	_check(not worn.call(6), "an unequipped slot hides it")
	# The held icon: the original draws the held slot itself (0xb9d810 ->
	# vslot_013), so the star rides on the cursor, at the slot's phase.
	panels.call("_fill_inventory_grid", [_slot(0, 501, 1), _slot(2, 503, 1)])
	await process_frame
	var icon0 := grid.get_child(0).get_node("ItemIcon") as TextureRect
	icon0.texture = _texture(32, 32)
	edge0.set("counter", 17)
	panels.call("pick_up_icon", {"kind": "bag", "slot": 0, "item_id": 501, "icon": icon0.texture},
		icon0.texture, icon0, Vector2(100, 100))
	var held = panels.get("held_icon")
	var ghost: Control = held.call("ghost") if held != null else null
	var gedge := ghost.get_node_or_null("SealEdge") as CanvasItem if ghost != null else null
	_check(gedge != null and gedge.visible and int(gedge.get("counter")) == 17,
		"a held seal item shows the star on the cursor, at its slot's phase")
	held.call("cancel")
	var icon2 := grid.get_child(2).get_node("ItemIcon") as TextureRect
	icon2.texture = _texture(32, 32)
	panels.call("pick_up_icon", {"kind": "bag", "slot": 2, "item_id": 503, "icon": icon2.texture},
		icon2.texture, icon2, Vector2(100, 100))
	ghost = held.call("ghost")
	_check(ghost != null and ghost.get_node_or_null("SealEdge") == null, "a held normal item has none")
	held.call("cancel")
	panels.call("_fill_inventory_grid", [])
	if net != null:
		net.set("last_inventory_capacity", 0)
	_store_seal_checks(panels, items)
	_bar_seal_checks()

## The store's goods: 0x6d1ff0 sets a good's +0x28 before its SetItem, so a
## seal good shows the star (READ).
func _store_seal_checks(panels: Control, items: Dictionary) -> void:
	var by_code: Dictionary = panels.get("_items_by_code")
	for id in items:
		var it: ItemTableReader.Item = items[id]
		it.code_name = "ITEM_SEAL_TEST_%d" % id
		it.icon_path = "icon\\item\\etc\\seal_test_%d.ddj" % id
		by_code[it.code_name] = it
	var store := HudWindow.new()
	store.name = "store"
	store.panel_root = Control.new()
	var lat := Control.new()
	lat.name = "GDR_STORE_LAT"
	store.panel_root.add_child(lat)
	store.add_child(store.panel_root)
	for i in range(4):
		var cell := Control.new()
		var icon := TextureRect.new()
		icon.name = "ItemIcon"
		cell.add_child(icon)
		lat.add_child(cell)
	panels.add_child(store)
	var windows: Dictionary = panels.get("_windows")
	var had = windows.get("store")
	windows["store"] = store
	panels.call("_fill_shop_grid", PackedStringArray(["ITEM_SEAL_TEST_501", "ITEM_SEAL_TEST_503", "ITEM_SEAL_TEST_502"]))
	var good := func(i: int) -> bool:
		var edge := lat.get_child(i).get_node("ItemIcon").get_node_or_null("SealEdge") as CanvasItem
		return edge != null and edge.visible
	_check(good.call(0) and good.call(2) and not good.call(1) and not good.call(3),
		"the store's seal goods show the star; a normal good and an empty cell do not")
	panels.call("_fill_shop_grid", PackedStringArray(["ITEM_SEAL_TEST_503"]))
	_check(not good.call(0) and not good.call(2), "a tab without them hides it")
	if had != null:
		windows["store"] = had
	else:
		windows.erase("store")
	store.queue_free()

## The quick slots: an item there is set from its bag item (0x60c430 ->
## 0x6871d0), so a seal item shows the star (READ).
func _bar_seal_checks() -> void:
	var Fixture = load("res://scripts/ui/hud/underbar_fixture.gd")
	var bar := HudUnderbar.new(Fixture.builder(), null, null)
	root.add_child(bar)
	bar.set_slot_item(1, _texture(32, 32))
	bar.set_slot_item(2, _texture(32, 32))
	bar.set_slot_seals({1: 501})
	var on_bar := func(i: int) -> bool:
		var icon := bar.slot_icon_rect(i)
		var edge := icon.get_node_or_null("SealEdge") as CanvasItem if icon != null else null
		return edge != null and edge.visible
	_check(bar.slot_icon_rect(1) != null and on_bar.call(1) and not on_bar.call(2),
		"a seal item on the quick slot bar shows the star; another slot does not")
	bar.set_slot_seals({2: 502})
	_check(not on_bar.call(1) and on_bar.call(2), "it follows the item when the bar changes")
	bar.queue_free()

## One worn item as the equipment reply decodes it (EquipmentNet.Equipped).
func _worn(slot: int, item_id: int) -> EquipmentNet.Equipped:
	var e := EquipmentNet.Equipped.new()
	e.slot = slot
	e.item_id = item_id
	return e

## One bag slot as the list reply decodes it (InventoryNet.Slot).
func _slot(index: int, item_id: int, quantity: int) -> InventoryNet.Slot:
	var sl := InventoryNet.Slot.new()
	sl.slot_index = index
	sl.item_id = item_id
	sl.quantity = quantity
	return sl

func _gold_checks(panels: Control) -> void:
	var gold := load(GOLD_PATH) as GDScript
	var cases := [[0, 0xFFFFFFFF], [9999, 0xFFFFFFFF], [10000, 0xFFFFFA85], [99999, 0xFFFFFA85],
		[100000, 0xFFFFD348], [1000000, 0xFFFFAD5C], [10000000, 0xFFFF9AA1], [100000000, 0xFFEBA1FF],
		[999999999, 0xFFEBA1FF], [1000000000, 0xFFB8BBFF], [10000000000, 0xFF95DEFF],
		[99999999999, 0xFF95DEFF], [100000000000, 0xFF8BFFE5]]
	for c in cases:
		_check(int(gold.call("argb", c[0])) == c[1], "gold %d is 0x%08X (0x5d3df0)" % c)
	if not panels.has_method("_set_money_text"):
		_check(false, "HudPanels colours the purse (_set_money_text)")
		return
	var window: Control = panels.call("open", "inventory")
	var label := panels.call("_set_money_text", window, "GDR_INVENTORY_STA_MONEY", 1500000000) as Label
	_check(label != null and label.text == "1,500,000,000"
		and label.get_theme_color("font_color") == Color8(0xB8, 0xBB, 0xFF),
		"a purse of 1,500,000,000 is drawn in 0xB8BBFF")

func _backdrop_checks(panels: Control) -> void:
	if not panels.has_method("_show_equipment_backdrops"):
		_check(false, "HudPanels draws the equipment backdrops")
		return
	var root := panels.call("_equipment_root") as Control
	var want := {0: Rect2(1, 82, 40, 40), 6: Rect2(0, 0, 56, 56), 7: Rect2(122, 0, 56, 56),
		8: Rect2(137, 304, 40, 40), 9: Rect2(1, 211, 40, 40), 12: Rect2(137, 254, 40, 40)}
	for i in want:
		var bd := root.get_node_or_null("EquipBackdrop%d" % i) as Control
		_check(bd != null and Rect2(bd.position, bd.size) == want[i],
			"worn backdrop %d at %s (got %s)" % [i, want[i], Rect2(bd.position, bd.size) if bd else null])
	var frame := root.get_node("GDR_EQ_FRAME")
	var tile := root.get_node("GDR_EQ_NORMALTILE_BG")
	var bd0 := root.get_node("EquipBackdrop0")
	var slot := root.get_node("GDR_EQUIPMENT_SLOT_100")
	_check(bd0.get_index() > frame.get_index() and bd0.get_index() > tile.get_index() and bd0.get_index() < slot.get_index(),
		"the backdrops draw after the frame and tile and before the slots")
	var em: Variant = panels.call("_equipment_root")
	panels.call("set_equipment_avatar_mode", true)
	var shown := []
	for i in 13:
		if (root.get_node("EquipBackdrop%d" % i) as CanvasItem).visible:
			shown.append(i)
	_check(shown == [8], "avatar mode keeps only worn backdrop 8 (got %s)" % [shown])
	var av := root.get_node_or_null("AvatarBackdrop4") as Control
	_check(av != null and av.visible and Rect2(av.position, av.size) == Rect2(1, 169, 40, 40),
		"avatar backdrop 4 shows at (1,169) 40x40 in avatar mode")
	panels.call("set_equipment_avatar_mode", false)
	_check(not (root.get_node("AvatarBackdrop0") as CanvasItem).visible and (root.get_node("EquipBackdrop0") as CanvasItem).visible,
		"equipment mode hides the avatar backdrops and shows the worn ones")
	_check(em != null, "the equipment pane root exists")

func _rotation_checks(panels: Control) -> void:
	if not panels.has_method("_doll_turn_tick"):
		_check(false, "HudPanels turns the paper doll (_doll_turn_tick)")
		return
	# Round 639 (OURS, the user's request): 36 degrees a click, whatever the
	# frame time, so ten clicks make a full turn; a held arrow repeats the
	# same step at retail's 1000 ms / 50 ms timing.
	var step := deg_to_rad(36.0)
	panels.call("set_paper_doll_yaw", 0.0)
	# The measurement (a log line and the pose line) runs on the press and the
	# release, not on each 50 ms repeat (rounds 633-635 integration review).
	var measured := [0]
	if panels.has_signal("paper_doll_measure_requested"):
		panels.connect("paper_doll_measure_requested", func() -> void: measured[0] += 1)
	panels.call("_doll_turn_start", 1)
	var t0 := int(panels.get("_doll_turn_last_ms"))
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), step), "a press on the right arrow turns 36 degrees (got %.4f)" % float(panels.get("paper_doll_yaw")))
	panels.call("_doll_turn_tick", t0 + 999)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), step), "no repeat before 1000 ms")
	panels.call("_doll_turn_tick", t0 + 1000)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), 2.0 * step), "the first repeat at 1000 ms steps 36 degrees more")
	# Round 639's review (OURS): the hold repeats every 250 ms, not retail's
	# 50 ms -- 144 degrees a second.
	panels.call("_doll_turn_tick", t0 + 1050)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), 2.0 * step), "no repeat 50 ms later (retail's period is not used)")
	panels.call("_doll_turn_tick", t0 + 1249)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), 2.0 * step), "no repeat 249 ms later")
	panels.call("_doll_turn_tick", t0 + 1250)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), 3.0 * step), "the next repeat 250 ms after the first")
	panels.set("_doll_turn_hovered", false)
	panels.call("_doll_turn_tick", t0 + 2000)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), 3.0 * step), "off the button the repeat pauses")
	panels.set("_doll_turn_hovered", true)
	_check(measured[0] == 1, "one measurement for the press and its two repeats (got %d)" % measured[0])
	panels.call("_doll_turn_stop", 1)
	_check(measured[0] == 2, "one more on the release (got %d)" % measured[0])
	panels.call("_doll_turn_tick", t0 + 3000)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), 3.0 * step), "the release stops it")
	panels.call("_doll_turn_start", -1)
	_check(is_equal_approx(float(panels.get("paper_doll_yaw")), 2.0 * step), "the left arrow turns back 36 degrees")
	panels.call("_doll_turn_stop", -1)
	var reset := (panels.call("open", "inventory") as Control).call("node", "GDR_EQ_BTN_ROTATE_RESET") as BaseButton
	if reset != null:
		reset.pressed.emit()
	_check(float(panels.get("paper_doll_yaw")) == 0.0, "the circle sets the yaw to 0")
	# Ten clicks, each a press and a release, make one full turn: the yaw
	# passes through 36, 72 .. 324 degrees and lands back on 0.
	var seen: Array = []
	for i in 10:
		panels.call("_doll_turn_start", 1)
		panels.call("_doll_turn_stop", 1)
		seen.append(snappedf(rad_to_deg(float(panels.get("paper_doll_yaw"))), 0.001))
	_check(seen == [36.0, 72.0, 108.0, 144.0, 180.0, 216.0, 252.0, 288.0, 324.0, 0.0],
		"ten clicks step 36 degrees each and come back to 0 (got %s)" % [seen])
	panels.call("_doll_turn_start", -1)
	panels.call("_doll_turn_stop", -1)
	_check(is_equal_approx(rad_to_deg(float(panels.get("paper_doll_yaw"))), 324.0), "the left arrow from 0 goes to 324 degrees")
	panels.call("set_paper_doll_yaw", 0.0)

func _doll_checks() -> void:
	var doll_script := load(DOLL_PATH) as GDScript
	var doll: SubViewport = doll_script.new()
	if not doll.has_method("use_equipment_view") or not doll.has_method("set_zone_light"):
		_check(false, "PaperDoll has the equipment view lit by the zone (use_equipment_view, set_zone_light)")
		doll.free()
		return
	root.add_child(doll)
	doll.call("use_equipment_view")
	var cam := doll.get("_camera") as Camera3D
	_check(doll.size == Vector2i(176, 318), "the doll renders at the pane's 176x318")
	_check(cam.projection == Camera3D.PROJECTION_PERSPECTIVE and is_equal_approx(cam.fov, 30.0)
		and cam.keep_aspect == Camera3D.KEEP_HEIGHT, "a perspective camera with a 30-degree vertical field")
	# The client's eye (0, 9, -40) in its left-handed space is (0, 9, 40)
	# under the (1, 1, -1) node, looking back at (0, 9, 0).
	_check(cam.position.is_equal_approx(Vector3(0, 9, 40)) and (-cam.transform.basis.z).is_equal_approx(Vector3(0, 0, -1)),
		"the camera stands at the mirrored eye (0, 9, 40) looking at (0, 9, 0) (got %s)" % cam.position)
	var mirror := doll.get("_mirror") as Node3D
	var pivot := doll.get("_pivot") as Node3D
	_check(mirror != null and mirror.scale == Vector3(1, 1, -1) and pivot.get_parent() == mirror,
		"the model hangs under a (1, 1, -1) node, the client's handedness")
	doll.call("set_yaw", 0.5)
	_check(is_equal_approx(pivot.rotation.y, -0.5), "a yaw of 0.5 is a Godot rotation of -0.5 under the mirror")
	# The setter's forward (sin, 0, -cos) at yaw 0.5, through the pivot and the
	# mirror, seen from the camera: the face turns to the screen's right.
	var forward_d3d := Vector3(0, 0, -1)
	var fwd := (mirror.global_transform.basis * pivot.transform.basis * forward_d3d)
	var right := cam.global_transform.basis.x
	_check(fwd.dot(right) > 0.4, "a growing yaw (the right arrow) turns the face toward screen-right (dot %.3f)" % fwd.dot(right))
	# The Bloom row off: channel 2 x 0.6 (round 706, ObjectLight); the static
	# is put back after the doll's checks.
	var bloom_was := ObjectLight.current_bloom
	ObjectLight.current_bloom = false
	doll.call("set_zone_light", Color(0.5, 0.25, 1.4), Color(0.4, 0.4, 0.4))
	var light: Dictionary = doll.call("zone_light")
	_check((light.get("diffuse", Vector3.ZERO) as Vector3).is_equal_approx(Vector3(0.3, 0.15, 0.6))
		and (light.get("ambient", Vector3.ZERO) as Vector3).is_equal_approx(Vector3(0.4, 0.4, 0.4)),
		"the doll's light is the zone's: channel 2 clamped x 0.6, channel 3 (got %s)" % [light])
	var skel := Skeleton3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.588, 0.588, 0.588)
	mi.material_override = sm
	skel.add_child(mi)
	doll.call("set_character", skel)
	var mat := mi.material_override as ShaderMaterial
	_check(mat != null and (mat.get_shader_parameter("light_diffuse") as Vector3).is_equal_approx(Vector3(0.3, 0.15, 0.6)),
		"a body material becomes the zone-lit one, with the zone's diffuse")
	ObjectLight.current_bloom = bloom_was
	_check(doll.render_target_update_mode == SubViewport.UPDATE_DISABLED, "the doll does not render until it is shown")
	doll.call("set_active", true)
	_check(doll.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "shown, it renders every frame")
	doll.call("set_active", false)
	_check(doll.render_target_update_mode == SubViewport.UPDATE_DISABLED, "hidden again, it stops")
	doll.queue_free()

## Round 695: the equipment window's doll renders at the size its picture
## covers on screen in physical pixels -- the pane's 176x318 times the UI
## scale -- so one rendered pixel is one screen pixel (the user's "much lower
## resolution than the game" at 3840x2019, UI scale 2.0). Before, it rendered
## 176x318 at every scale and was magnified.
func _doll_pixel_checks(panels: Control) -> void:
	var doll_script := load(DOLL_PATH) as GDScript
	var doll: SubViewport = doll_script.new()
	root.add_child(doll)
	doll.call("use_equipment_view")
	var takes_viewport := false
	for m in panels.get_method_list():
		if m["name"] == "set_paper_doll_texture":
			takes_viewport = (m["args"] as Array).size() >= 2
	_check(takes_viewport, "HudPanels.set_paper_doll_texture takes the doll's SubViewport, to size it")
	if takes_viewport:
		panels.call("set_paper_doll_texture", doll.get_texture(), doll)
	else:
		panels.call("set_paper_doll_texture", doll.get_texture())
	var rect := panels.find_child("PaperDoll", true, false) as TextureRect
	_check(rect != null, "the paper doll's picture is placed in the equipment pane")
	if rect == null:
		doll.queue_free()
		return
	for k in [1.0, 2.0, 1.5, 1.95, 1.0]:
		root.content_scale_factor = k
		await process_frame
		await process_frame
		var xf := rect.get_viewport().get_final_transform() * rect.get_global_transform_with_canvas()
		var on_screen := rect.size * xf.get_scale().abs()
		var want := Vector2i(roundi(on_screen.x), roundi(on_screen.y))
		# The window's canvas is a whole number of units (1080 / 1.95 -> 553),
		# so the real stretch is within a pixel or two of the nominal scale.
		_check(absi(want.x - roundi(176.0 * k)) <= 2 and absi(want.y - roundi(318.0 * k)) <= 2,
			"at UI scale %.2f the picture covers %s physical pixels (176x318 x scale)" % [k, want])
		_check(doll.size == want, "at UI scale %.2f the doll renders %s for the %s pixels it covers (got %s)" % [k, want, want, doll.size])
		var ratio := float(doll.size.y) / on_screen.y
		_check(absf(ratio - 1.0) < 0.01, "at UI scale %.2f one rendered pixel is one screen pixel (texels per pixel %.3f)" % [k, ratio])
	var head: Vector2 = doll.call("bone_on_screen", "Bip01 Head")
	_check(head == Vector2(-1, -1), "with no model the head is not on screen")
	# The pose log stays in the 176x318 picture's pixels whatever the buffer.
	root.content_scale_factor = 2.0
	await process_frame
	await process_frame
	if doll.has_method("pixel_scale"):
		_check(is_equal_approx(float(doll.call("pixel_scale")), 2.0), "at 2.0 the doll's picture pixel is 2 rendered pixels")
	root.content_scale_factor = 1.0
	await process_frame
	panels.call("set_paper_doll_texture", null)
	doll.queue_free()

func _capacity_checks() -> void:
	var bytes := PackedByteArray()
	bytes.resize(2 + 2 + 2)
	bytes.encode_u16(0, 0)      # error ""
	bytes.encode_u16(2, 0)      # no slots
	bytes.encode_u16(4, 0)      # no durabilities
	var tail := PackedByteArray()
	tail.resize(2)
	tail.encode_u16(0, 64)
	bytes.append_array(tail)
	var r := InventoryNet.decode_list_result(bytes)
	_check(r.error == "" and r.capacity == 64, "the bag list's trailing u16 is its capacity (got %d)" % r.capacity)
	bytes.resize(6)
	_check(InventoryNet.decode_list_result(bytes).capacity == 0, "an older server's list has none")
