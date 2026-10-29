extends SceneTree

## Round 842 (lane T): the stall network's item tooltips against the real
## Media.pk2 (docs/protocol/stall_network.md §3a). A row's icon is a
## CIFSlotWithHelpEx whose CIFSlotWithHelp gets the record's item (c:0x6caa40
## -> 0x6871d0, slot kind 0x0f, window 0x96) and answers the hover with the
## item help every bag slot shows (vslot_019 c:0x667820 -> vslot_048
## c:0x686db0 -> 0x686c50) -- with kind 0x0f's one difference, the durability
## line printing the maximum twice, white (c:0x66d338..0x66d44c). The records
## come through StallNetworkNet.decode_search from wire bytes; the pointer is
## real input pushed into the root viewport, at UI scale 1 and 1.5.
##   godot4 --headless --path client --script res://scripts/ui/hud/stall_network842_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const ICON := 124

var _failures := 0

class FakeNet extends RefCounted:
	var sent: Array = []
	func stall_net_search(mode: int, page: int, group: int, degree: int) -> void:
		sent.append("search %d %d %d %d" % [mode, page, group, degree])
	func stall_net_leave() -> void: sent.append("leave")
	func stall_net_buy(_r) -> void: sent.append("buy")

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
	# push_input needs the root in the tree, which it is only after
	# _initialize returns (hud_click_routing_test's finding).
	await process_frame
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

# --- the wire --------------------------------------------------------------------------

func _u16(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, v)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u64(0, v)
	return b

## An equipment record (round 732's layout, c:0x8be4f0): rent 0, ref, plus,
## variance, durability, the options (id | value << 32), the two empty
## binding blocks.
func _equip(ref: int, plus: int, variance: int, dur: int, options: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.append_array(_u32(0))
	b.append_array(_u32(ref))
	b.append(plus)
	b.append_array(_u64(variance))
	b.append_array(_u32(dur))
	b.append(options.size())
	for o in options:
		b.append_array(_u64(int(o[0]) | (int(o[1]) << 32)))
	b.append_array(PackedByteArray([1, 0, 2, 0]))
	return b

## An expendable's record: rent 0, ref, the u16 count.
func _expendable(ref: int, count: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.append_array(_u32(0))
	b.append_array(_u32(ref))
	b.append_array(_u16(count))
	return b

## The record's tail (c:0x6c98e0): owner, seller, slot, count, level, price, serial.
func _tail(owner: int, seller: String, slot: int, count: int, level: int, price: int, serial: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.append_array(_u32(owner))
	var s := seller.to_utf8_buffer()
	b.append_array(_u16(s.size()))
	b.append_array(s)
	b.append(slot)
	b.append_array(_u16(count))
	b.append(level)
	b.append_array(_u64(price))
	b.append_array(_u64(serial))
	return b

func _answer(pages: int, records: Array) -> PackedByteArray:
	var b := PackedByteArray([1, records.size(), pages])
	for r in records:
		b.append_array(r)
	return b

# --- the run ----------------------------------------------------------------------------

func _motion(at: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	root.push_input(m, true)

func _texts(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		out.append(String((l as Dictionary)["text"]))
	return out

func _find(panels: Control, pred: Callable) -> ItemTableReader.Item:
	var items: Dictionary = panels.get("_items")
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
	var magic := ObjectLoader.find_file(pk2, MagicOptionTable.PATH)
	MagicOptionTable.shared = MagicOptionTable.new().load(pk2.read_file(magic)) if magic != null else null
	MagicOptionTable.shared_text = func(key: String) -> String: return table.get_text(key, key)
	_check(MagicOptionTable.shared != null and MagicOptionTable.shared.size() > 0, "magicoption.txt loads")
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	panels.call("_load_items")
	ItemInstance.types_of = func(ref: int) -> PackedInt32Array: return panels.call("item_types", ref)

	var weapon := _find(panels, func(it: ItemTableReader.Item) -> bool:
		return it.family() == ItemTooltipLines.WEAPON_FAMILY and not ItemTooltipLines.is_seal(it) \
			and it.durability > 0 and it.code_name.begins_with("ITEM_CH_SWORD_"))
	var seal := _find(panels, func(it: ItemTableReader.Item) -> bool:
		return it.family() == ItemTooltipLines.WEAPON_FAMILY and ItemTooltipLines.is_seal(it) and it.durability > 0)
	var potion := _find(panels, func(it: ItemTableReader.Item) -> bool:
		return it.code_name == "ITEM_ETC_HP_POTION_01")
	var avatar := _find(panels, func(it: ItemTableReader.Item) -> bool: return it.is_avatar())
	_check(weapon != null and seal != null and potion != null and avatar != null,
		"the archive's items: a sword %s, a seal weapon %s, %s, an avatar %s" % [
			weapon.code_name if weapon else "?", seal.code_name if seal else "?",
			potion.code_name if potion else "?", avatar.code_name if avatar else "?"])
	if weapon == null or seal == null or potion == null or avatar == null:
		return
	var str_row: MagicOptionTable.Row = MagicOptionTable.shared.record("MATTR_STR", 1)
	var int_row: MagicOptionTable.Row = MagicOptionTable.shared.record("MATTR_INT", 1)
	_check(str_row != null and int_row != null, "MATTR_STR / MATTR_INT degree-1 rows")
	if str_row == null or int_row == null:
		return

	# The comparison: the same instance as a bag slot shows it (the lookup
	# a site with no NetClient list takes).
	var cmp_inst: Array = [null]
	panels.set("item_instance_lookup", func(where: String, _slot: int, item_id: int) -> Dictionary:
		if where != "cmp" or cmp_inst[0] == null:
			return {}
		return ItemTooltipInstance.fields(panels.get("_items")[item_id], cmp_inst[0]))

	var c: StallNetworkController = panels.call("_stall_network")
	var net := FakeNet.new()
	c.net = net
	_check(c.open(true, false) == "opened", "the window opens")
	await process_frame
	var w := c.window
	w.choose(StallNetworkWindow.ID_CLASS, 1)
	w.choose(StallNetworkWindow.ID_TYPE, 1)
	w.choose(StallNetworkWindow.ID_DEGREE, 1)
	w.press_search()

	# Page 0: the +7 sword with two blue options and 20 durability, 30 HP
	# potions, the avatar with STR, the seal weapon.
	var variance := 0
	for k in 12:
		variance |= (20 + k % 5) << (5 * k)
	var page0 := _answer(2, [
		_equip(weapon.id, 7, variance, 20, [[str_row.id, 3], [int_row.id, 2]]) + _tail(101, "SellA", 0, 1, 8, 7000, 9001),
		_expendable(potion.id, 30) + _tail(102, "SellB", 1, 30, 1, 900, 9002),
		_equip(avatar.id, 0, 0, 0, [[str_row.id, 1]]) + _tail(103, "SellC", 2, 1, 1, 50000, 9003),
		_equip(seal.id, 3, variance, 40, []) + _tail(104, "SellD", 3, 1, 1, 123456, 9004),
	])
	var d := StallNetworkNet.decode_search(page0, 0)
	var recs: Array = d.get("records", [])
	_check(recs.size() == 4, "0xB461 decodes four records (got %d)" % recs.size())
	if recs.size() != 4:
		return
	var r0: StallNetworkNet.Record = recs[0]
	_check(r0.item.ref_item_id == weapon.id and r0.item.opt_level == 7 and r0.item.variance == variance
		and r0.item.durability == 20 and r0.item.option_count() == 2 and r0.item.option_id(0) == str_row.id
		and r0.item.option_value(0) == 3 and r0.price == 7000 and r0.seller == "SellA",
		"decode_search keeps the sword's whole record: +7, the variance, durability 20, both options, the tail")
	var r1: StallNetworkNet.Record = recs[1]
	_check(not r1.item.is_equipment and r1.item.count == 30 and r1.count == 30, "the potion's record: count 30")
	c.on_searched(d)

	for scale in [1.0, 1.5]:
		root.content_scale_factor = scale
		await process_frame
		w.place_centred()
		await process_frame
		var host0 := w.control([120, ICON])
		var host1 := w.control([129, ICON])
		var host2 := w.control([137, ICON])
		var host3 := w.control([145, ICON])
		var host5 := w.control([162, ICON])
		var tag := "UI scale %.1f: " % scale

		# Away, then onto row 0's icon: the sword's help.
		_motion(Vector2(4, 4))
		await process_frame
		_check(panels.call("item_tip_shown").is_empty(), tag + "no tooltip away from the rows")
		_motion(host0.get_global_rect().get_center())
		await process_frame
		var shown: Array = panels.call("item_tip_shown")
		cmp_inst[0] = r0.item
		var bag: Array = panels.call("item_tip_lines", weapon.id, "cmp", 0)
		var want := _texts(bag)
		var dur_key: String = panels.call("_tip_text", "PARAM_DUR", "Durability")
		var dmax := -1
		for k in want.size():
			if want[k].begins_with(dur_key + " "):
				var figs := want[k].substr(dur_key.length() + 1).get_slice(" ", 0)
				dmax = int(figs.get_slice("/", 1))
				_check(int(figs.get_slice("/", 0)) == 20, tag + "the bag's line is cur/max: %s" % want[k])
				want[k] = want[k].replace(figs, "%d/%d" % [dmax, dmax])
		var got := _texts(shown)
		_check(dmax > 0 and got == want, tag + "row 0's icon: the bag's item help with the durability line max/max\n    got  %s\n    want %s" % [
			" | ".join(got), " | ".join(want)])
		var name0 := String((shown[0] as Dictionary)["text"]) if not shown.is_empty() else ""
		_check(name0.ends_with("(+7)") and (shown[0] as Dictionary)["color"] == ItemTooltipLines.CYAN,
			tag + "the name with (+7), cyan for the blue options (got %s)" % name0)
		var blues := 0
		var dur_white := false
		for l in shown:
			if (l as Dictionary)["color"] == ItemTooltipLines.CYAN:
				blues += 1
			if String((l as Dictionary)["text"]).begins_with(dur_key + " "):
				dur_white = (l as Dictionary)["color"] == ItemTooltipLines.WHITE
		_check(blues == 3 and dur_white, tag + "two cyan option lines under the cyan name; the durability line white")
		var bubble: Control = panels.call("item_tip_bubble")
		_check(bubble != null and bubble.visible and bubble.position.x >= host0.get_global_rect().end.x - 1.0,
			tag + "the bubble right of the icon (%s, icon ends at %.0f)" % [str(bubble.position) if bubble else "-", host0.get_global_rect().end.x])

		# A click on the row selects it; the help stays (the bar is all 0x6cb110 changes).
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = host0.get_global_rect().get_center()
		click.global_position = click.position
		root.push_input(click, true)
		var up := click.duplicate() as InputEventMouseButton
		up.pressed = false
		root.push_input(up, true)
		await process_frame
		_check(w.row_selected(0) and _texts(panels.call("item_tip_shown")) == got, tag + "a click selects the row; the help is unchanged")

		# The potion and the avatar, as the bag shows them.
		_motion(host1.get_global_rect().get_center())
		await process_frame
		cmp_inst[0] = r1.item
		_check(_texts(panels.call("item_tip_shown")) == _texts(panels.call("item_tip_lines", potion.id, "cmp", 1)),
			tag + "row 1: the potion's help, as the bag's (%s)" % " | ".join(_texts(panels.call("item_tip_shown"))))
		_motion(host2.get_global_rect().get_center())
		await process_frame
		var r2: StallNetworkNet.Record = recs[2]
		cmp_inst[0] = r2.item
		var av := _texts(panels.call("item_tip_shown"))
		_check(not av.is_empty() and av == _texts(panels.call("item_tip_lines", avatar.id, "cmp", 2)),
			tag + "row 2: the avatar's help, as the bag's (%s)" % " | ".join(av))
		# The seal weapon: its star on the icon, its +3.
		var edge := host3.get_node_or_null("Icon/" + ItemSealEdge.NODE_NAME) as ItemSealEdge
		_check(edge != null and edge.visible, tag + "row 3's seal weapon has the seal star (0x6871d0 -> 0x666610)")
		_motion(host3.get_global_rect().get_center())
		await process_frame
		var s3: Array = panels.call("item_tip_shown")
		_check(not s3.is_empty() and String(s3[0]["text"]).ends_with("(+3)") and s3[0]["color"] == ItemTooltipLines.GOLD,
			tag + "row 3: gold name with (+3)")
		# An empty row shows nothing.
		_motion(host5.get_global_rect().get_center())
		await process_frame
		_check(panels.call("item_tip_shown").is_empty(), tag + "an empty row's icon shows nothing")

		# Paging under a still pointer on row 0's icon: page 1 asked (mode 3),
		# answered -- the help is page 1's row 0 at once; back to page 0 (the
		# cache) -- the sword's again.
		_motion(host0.get_global_rect().get_center())
		await process_frame
		w.page_changed(1)
		if w.awaiting:
			c.on_searched(StallNetworkNet.decode_search(_answer(2, [
				_expendable(potion.id, 7) + _tail(105, "SellE", 4, 7, 1, 70, 9005)]), 1))
		await process_frame
		var p1 := _texts(panels.call("item_tip_shown"))
		_check(not p1.is_empty() and p1[0] == _texts(panels.call("item_tip_lines", potion.id, "cmp", 0))[0],
			tag + "page 2 under the pointer: row 0's new item (%s)" % (p1[0] if not p1.is_empty() else "nothing"))
		w.page_changed(0)
		await process_frame
		_check(_texts(panels.call("item_tip_shown")) == got, tag + "page 1 again: the sword's help")
		# The sort (0x6c6f70) re-fills the rows the same way: under the
		# pointer the help follows the row's new record.
		w.press_sort(StallNetworkWindow.SORT_PRICE)
		await process_frame
		var cheapest: StallNetworkNet.Record = w.shown_records[0]
		var sorted := _texts(panels.call("item_tip_shown"))
		_check(cheapest.price == 900 and not sorted.is_empty()
			and sorted[0] == _texts(panels.call("item_tip_lines", potion.id, "cmp", 0))[0],
			tag + "sorted by price under the pointer: row 0 is the potion and so is the help")
		w.press_sort(StallNetworkWindow.SORT_NUMBER)
		await process_frame
		_motion(Vector2(4, 4))
		await process_frame
		_check(panels.call("item_tip_shown").is_empty(), tag + "the leave hides it (0x400a)")

	# The buy box: its icon is a CNIFStatic (26) over a plain CNIFWnd (27),
	# given a texture, never an item (c:0x6bc7a0, 0x6bf370): no help.
	root.content_scale_factor = 1.0
	await process_frame
	w.select_row(0)
	w.press_buy()
	await process_frame
	_check(c.box != null and c.box.visible, "Purchase shows the buy box")
	if c.box != null:
		var bi := c.box.control([27])
		if bi == null:
			bi = c.box.control([26])
		_motion(bi.get_global_rect().get_center() if bi != null else c.box.get_global_rect().get_center())
		await process_frame
		_check(panels.call("item_tip_shown").is_empty(), "the buy box's icon shows no tooltip")
		c.box.visible = false

	# Closing the window under a shown help hides it.
	_motion(w.control([120, ICON]).get_global_rect().get_center())
	await process_frame
	_check(not panels.call("item_tip_shown").is_empty(), "the help is up before the close")
	w._on_close_pressed()
	await process_frame
	await process_frame
	_check(panels.call("item_tip_shown").is_empty(), "the window's close hides the help")
	ItemInstance.types_of = Callable()
	MagicOptionTable.shared = null
	MagicOptionTable.shared_text = Callable()
	panels.queue_free()
