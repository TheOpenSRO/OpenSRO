extends SceneTree

## Round 732: the item instance record, its trailing block on the bag and
## equipment lists, the (+x%) arithmetic and the magic option table.
##   godot4 --headless --path client --script res://scripts/items/item_instance_test.gd
## The record bytes and the percent cases are the Go tests' own
## (server/internal/session/iteminfo_test.go, internal/durability/quality_test.go).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## +5, options (1, 7) and (16, 100), advanced elixir +3, variance 0x7c1f,
## durability 62, item 3645 -- byte for byte the Go golden record.
const RECORD := [
	0x3d, 0x0e, 0x00, 0x00,
	0x05,
	0x1f, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x3e, 0x00, 0x00, 0x00,
	0x02,
	0x01, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
	0x10, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00,
	0x01, 0x00,
	0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
]

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

func _s64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_s64(0, v)
	return b

func _init() -> void:
	_test_record()
	_test_lists()
	_test_quality()
	_test_magic_options()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % _failures)
	quit(_failures)

func _test_record() -> void:
	var data := PackedByteArray(RECORD)
	data.append(0xaa)
	var rec := ItemInstance.read_record(data, 0)
	_check(rec[0] != null and rec[1] == RECORD.size(), "the golden record reads to its end (offset %s)" % str(rec[1]))
	if rec[0] == null:
		return
	var it: ItemInstance = rec[0]
	_check(it.ref_item_id == 3645 and it.opt_level == 5 and it.variance == 0x7c1f and it.durability == 62,
		"item, OptLevel, variance and durability (%s)" % it.describe())
	_check(it.option_count() == 2 and it.option_id(0) == 1 and it.option_value(0) == 7 and it.option_id(1) == 16 and it.option_value(1) == 100,
		"the two blue options: low u16 the id, high u32 the value")
	_check(it.adv_elixir == 3 and it.effective_plus() == 8, "the advanced elixir adds onto the plus: +5 +3 = +8")
	_check(it.variance_group(0) == 31 and it.variance_group(1) == 0 and it.variance_group(2) == 31, "variance groups 0..2 are 31, 0, 31")
	var bad := PackedByteArray(RECORD)
	bad[17] = 13
	_check(ItemInstance.read_record(bad, 0)[0] == null, "MagParamNum 13 is refused, as the client asserts")
	var cut_ok := true
	for n in RECORD.size():
		if ItemInstance.read_record(PackedByteArray(RECORD).slice(0, n), 0)[0] != null:
			cut_ok = false
	_check(cut_ok, "every truncation of the record is refused")

## A bag list as session/inventory.go sends it: records, durability block,
## capacity, then the instance block.
func _test_lists() -> void:
	var bag := PackedByteArray()
	bag.append_array(_u16(0))  # no error
	bag.append_array(_u16(1))  # one slot
	bag.append_array(_u32(13))
	bag.append_array(_s64(3645))
	bag.append_array(_u32(1))
	bag.append_array(_u16(0))  # no durabilities
	bag.append_array(_u16(45))  # capacity
	bag.append_array(_u16(1))  # one instance
	bag.append_array(_u32(13))
	bag.append_array(PackedByteArray(RECORD))
	var r := InventoryNet.decode_list_result(bag)
	_check(r.error == "" and r.capacity == 45 and r.slots.size() == 1, "the bag list still reads (capacity %d)" % r.capacity)
	_check(r.instances.has(13) and (r.instances[13] as ItemInstance).opt_level == 5 and (r.instances[13] as ItemInstance).slot == 13,
		"the bag's slot 13 carries its instance")
	var old := bag.slice(0, bag.size() - 2 - 4 - RECORD.size())
	var r_old := InventoryNet.decode_list_result(old)
	_check(r_old.capacity == 45 and r_old.instances.is_empty(), "an older server's list has no instances and no error")

	var eq := PackedByteArray()
	eq.append_array(_u16(0))
	eq.append_array(_u16(0))  # no worn records needed for the block
	eq.append_array(_u16(1))  # one durability
	eq.append_array(_u32(6))
	eq.append_array(_u32(30))
	eq.append_array(_u32(62))
	eq.append_array(_u16(1))
	eq.append_array(_u32(6))
	eq.append_array(PackedByteArray(RECORD))
	var e := EquipmentNet.decode_result(eq)
	_check(e.durabilities.size() == 1 and e.instances.has(6) and (e.instances[6] as ItemInstance).adv_elixir == 3,
		"the equipment list's block follows its durability block")

func _test_quality() -> void:
	var pd := func(q: int) -> float: return ItemQuality.float_stat(10, 20, q, 1.5, 3)
	var atk := func(q: int) -> int: return ItemQuality.int_stat(10, 20, q, 2.5, 3)
	var cases := [
		["int stat, top", atk.call(31), 27],
		["int stat, q 15", atk.call(15), 21],
		["int stat, bottom", atk.call(0), 17],
		["int stat, no plus", ItemQuality.int_stat(10, 20, 31, 2.5, 0), 20],
		["single, top roll", ItemQuality.single_pct(pd.call(31), 10, 20, 1.5, 3), 100],
		["single, bottom roll", ItemQuality.single_pct(pd.call(0), 10, 20, 1.5, 3), 0],
		["single, q 15", ItemQuality.single_pct(pd.call(15), 10, 20, 1.5, 3), 48],
		["single, empty range", ItemQuality.single_pct(7, 7, 7, 0, 0), 100],
		["single, no plus off", ItemQuality.single_pct(15, 10, 20, 9, 0), 50],
		["range, top and q 15", ItemQuality.range_int_pct(atk.call(31), ItemQuality.int_stat(30, 40, 15, 2.5, 3), 10, 20, 30, 40, 2.5, 3), 70],
		["range, top and middle", ItemQuality.range_int_pct(27, 42, 10, 20, 30, 40, 2.5, 3), 75],
		["range, both bottom", ItemQuality.range_int_pct(17, 37, 10, 20, 30, 40, 2.5, 3), 0],
		["range, the plus bonus truncates", ItemQuality.range_int_pct(22, 42, 10, 20, 30, 40, 2.7, 1), 100],
		["range, an empty end counts 1", ItemQuality.range_int_pct(5, 30, 5, 5, 30, 40, 0, 0), 50],
		["range float (reinforce)", ItemQuality.range_float_pct(1.5, 3.0, 1, 2, 2, 4), 50],
		["durability q 31 shows 99", ItemQuality.durability_pct(31), 99],
		["durability q 0", ItemQuality.durability_pct(0), 0],
		["durability q 15", ItemQuality.durability_pct(15), 48],
	]
	for c in cases:
		_check(int(c[1]) == int(c[2]), "%s: %d (want %d)" % [c[0], int(c[1]), int(c[2])])
	_check(ItemQuality.group_for("weapon", "phys_attack") == 4 and ItemQuality.group_for("shield", "block") == 3
		and ItemQuality.group_for("accessory", "mag_absorption") == 1 and ItemQuality.group_for("armour", "x") == -1,
		"the variance group maps of c:0x8bd980")

## Synthetic rows shaped like magicoption.txt (never the real file).
func _test_magic_options() -> void:
	var rows := [
		"1\t134\tMATTR_ER\t+\t7\t1\t0\t25970\t%d\t%d\t%d\t0" % [(5 << 16) | 10, (20 << 16) | 30, (40 << 16) | 0],
		"1\t200\tMATTR_SOLID\t+\t7\t0.3\t0\t1\t%d\t%d\t%d\t0" % [(1 << 16) | 2, (3 << 16) | 4, (5 << 16) | 6],
		"// a comment",
	]
	var t := MagicOptionTable.new().load(("\n".join(PackedStringArray(rows))).to_utf16_buffer())
	_check(t.size() == 2, "two rows read (got %d)" % t.size())
	var er := t.row(134)
	_check(er != null and er.code == "MATTR_ER" and er.degree == 7 and er.min_value() == 5 and er.max_value() == 40,
		"ER's range runs 5..40 (the last non-zero half-word)")
	_check(MagicOptionTable.blue_pct(er, 40) == 100 and MagicOptionTable.blue_pct(er, 5) == 0 and MagicOptionTable.blue_pct(er, 20) == 42,
		"the blue (+x%): trunc((v - min) / (max - min) * 100)")
	_check(MagicOptionTable.blue_pct(er, 1) == 0, "never below 0")
	var text := func(k: String) -> String:
		return {"PARAM_ER": "Parry rate", "PARAM_INCREASE": "Increase", "PARAM_SOLID": "Steady", "UIIT_STT_COUNT": "Time/times"}.get(k, k)
	_check(MagicOptionTable.format_line("MATTR_ER", 20, 42, text) == "Parry rate 20% Increase (+42%)", "the ER line")
	_check(MagicOptionTable.format_line("MATTR_SOLID", 1, 0, text) == "Steady(1Time/times)", "the Steady line, as the original shows it")
	_check(MagicOptionTable.format_line("MATTR_NOPE", 1, 0, text) == "", "an unlisted option has no line")
