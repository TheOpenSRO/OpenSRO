extends SceneTree

## Round 838: a tool used on another item (ItemTargetPick), the worn and bag
## lists' models block (ItemInstance.decode_block) and the CanUse byte.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _item(types: Array, can_use: int, code: String = "") -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.type_ids = PackedInt32Array(types)
	it.can_use = can_use
	it.code_name = code
	return it

## One equipment record with no options: rent 0, ref, plus, variance, dur,
## 0 options, the two empty binding blocks.
func _record(ref: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4 + 4 + 1 + 8 + 4 + 1)
	b.encode_u32(4, ref)
	b.append_array(PackedByteArray([1, 0, 2, 0]))
	return b

func _block(entries: Array, models: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, entries.size())
	for e in entries:
		var at := PackedByteArray()
		at.resize(4)
		at.encode_u32(0, int(e[0]))
		b.append_array(at)
		b.append_array(_record(int(e[1])))
	if not models.is_empty():
		var m := PackedByteArray()
		m.resize(2 + 8 * models.size())
		m.encode_u16(0, models.size())
		for i in models.size():
			m.encode_u32(2 + 8 * i, int(models[i][0]))
			m.encode_u32(6 + 8 * i, int(models[i][1]))
		b.append_array(m)
	return b

func _init() -> void:
	# The pick: 3/3/13/8 with CanUse 0x81 (MEASURED 129 on every such row).
	_check(ItemTargetPick.is_pick_tool(_item([3, 3, 13, 8], 129)), "a 3/3/13/8 tool with CanUse 129 picks a target")
	_check(not ItemTargetPick.is_pick_tool(_item([3, 3, 13, 8], 1)), "CanUse without 0x80 does not")
	_check(not ItemTargetPick.is_pick_tool(_item([3, 3, 13, 9], 129)), "3/3/13/9 (the skin change) does not")
	_check(not ItemTargetPick.is_pick_tool(_item([3, 3, 1, 1], 129)), "a potion does not")
	_check(not ItemTargetPick.is_pick_tool(null), "no row, no pick")
	# The box's OK (SendItem_HandleUseItem case 8).
	var armour := PackedInt32Array([3, 1, 3, 3])
	var sword := PackedInt32Array([3, 1, 6, 2])
	var tg := "ITEM_MALL_EQUIP_TRANSGENDER_4"
	_check(ItemTargetPick.check(tg, ItemTargetPick.KIND_WORN, armour) == 0x1882, "a worn target: 0x1882")
	_check(ItemTargetPick.check(tg, ItemTargetPick.KIND_BAG, sword) == 0x1884, "retail's tool on a weapon: 0x1884")
	_check(ItemTargetPick.check(tg, ItemTargetPick.KIND_BAG, armour) == 0, "retail's tool on bag armour: sent")
	_check(ItemTargetPick.check(tg, ItemTargetPick.KIND_AVATAR, armour) == -1, "an avatar slot: nothing")
	_check(ItemTargetPick.check("ITEM_MODEL_16", ItemTargetPick.KIND_BAG, sword) == 0, "a model switcher on a weapon: sent")
	_check(ItemTargetPick.check("ITEM_EU_AXE_SWITCHER", ItemTargetPick.KIND_BAG, sword) == 0, "a type switcher: sent")
	_check(ItemTargetPick.check("ITEM_AVATAR_SWITCHER", ItemTargetPick.KIND_WORN, sword) == 0x1882, "a private tool on a worn item: 0x1882")
	_check(ItemTargetPick.is_private_tool("ITEM_GDF_SWITCHER") and not ItemTargetPick.is_private_tool("ITEM_EVENT_EQUIP_TRANSGENDER_1"),
		"the private and retail codes")
	# The models block after the entries.
	var with_models := ItemInstance.decode_block(_block([[3, 101], [5, 25611]], [[5, 61449]]), 0)
	_check(with_models.size() == 2, "two entries (got %d)" % with_models.size())
	_check(with_models.has(5) and (with_models[5] as ItemInstance).model == 61449, "slot 5's model is read")
	_check(with_models.has(5) and (with_models[5] as ItemInstance).display_ref() == 61449, "slot 5 is drawn as its model")
	_check(with_models.has(3) and (with_models[3] as ItemInstance).model == 0 and (with_models[3] as ItemInstance).display_ref() == 101,
		"slot 3 keeps its own model")
	var plain := ItemInstance.decode_block(_block([[3, 101]], []), 0)
	_check(plain.size() == 1 and (plain[3] as ItemInstance).model == 0, "a block without models reads as before")
	# The CanUse column (24) in the GDScript reader.
	var cols := PackedStringArray()
	cols.resize(160)
	for i in cols.size():
		cols[i] = "0"
	cols[0] = "1"
	cols[1] = "23352"
	cols[2] = "ITEM_MALL_EQUIP_TRANSGENDER_4"
	cols[3] = "Final defense gender switch tool"
	cols[9] = "3"
	cols[10] = "3"
	cols[11] = "13"
	cols[12] = "8"
	cols[24] = "129"
	var text := "\t".join(cols) + "\r\n"
	var data := PackedByteArray([0xff, 0xfe])
	data.append_array(text.to_utf16_buffer())
	var rows := {}
	ItemTableReader.parse(data, rows)
	var row: ItemTableReader.Item = rows.get(23352)
	_check(row != null and row.can_use == 129, "the reader keeps CanUse 129 (got %s)" % [row.can_use if row != null else "no row"])
	_check(ItemTargetPick.is_pick_tool(row), "and the parsed row picks a target")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		quit(1)
