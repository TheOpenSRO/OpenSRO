extends SceneTree

## Round 839 (lane S): StallNet on the retail wire -- the bytes the server's
## TestStallWireLayouts and TestStallFullFlow use (session/stall.go), the
## spawn record's stall block (UserSpawnNet), the group table and the price
## format.
##   godot4 --headless --path client --script res://scripts/net/stall_net_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _u16(v: int) -> PackedByteArray:
	var b := PackedByteArray([0, 0])
	b.encode_u16(0, v)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray([0, 0, 0, 0])
	b.encode_u32(0, v)
	return b

func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u64(0, v)
	return b

func _initialize() -> void:
	# The requests.
	_check(StallNet.encode_open("ab") == PackedByteArray([2, 0, 97, 98]), "0x70B1 {str}")
	_check(StallNet.encode_enter(5) == PackedByteArray([5, 0, 0, 0]), "0x70B3 {u32 owner}")
	_check(StallNet.encode_buy(3) == PackedByteArray([3]), "0x70B4 {u8 slot}")
	var add := StallNet.encode_add(1, 2, 5, 1234, 7)
	_check(add == PackedByteArray([2, 1, 15]) + _u16(5) + _u64(1234) + _u32(7) + _u16(0),
		"0x70BA type 2 {slot, bag + 13, u16 count, u64 price, u32 group, u16 net}")
	_check(StallNet.encode_price(1, 5, 99) == PackedByteArray([1, 1]) + _u16(5) + _u64(99) + _u16(0), "0x70BA type 1")
	_check(StallNet.encode_remove(4) == PackedByteArray([3, 4, 0, 0]), "0x70BA type 3 {slot, u16}")
	_check(StallNet.encode_open_state(true) == PackedByteArray([5, 1, 0, 0])
		and StallNet.encode_open_state(false, 3) == PackedByteArray([5, 0, 3, 0]), "0x70BA type 5 {open, u16 net}")
	_check(StallNet.encode_greeting("hi") == PackedByteArray([6, 2, 0, 104, 105]), "0x70BA type 6 {str}")
	_check(StallNet.encode_rename("x") == PackedByteArray([7, 1, 0, 120]), "0x70BA type 7 {str}")
	_check(StallNet.encode_avatar_stall(9, 3847) == _u32(9) + _u32(3847), "0x7160 {u32 key, u32 decoration}")
	# The answers.
	_check(StallNet.decode_result(PackedByteArray([1])) == 1 and StallNet.decode_result(PackedByteArray([2, 0x2a, 0x3c])) == 0x3c2a,
		"{1} / {2, 0x3c2a}")
	ItemInstance.types_of = func(_ref: int) -> PackedInt32Array: return PackedInt32Array([3, 3, 1, 1])
	var rec := PackedByteArray([0, 0, 0, 0, 200, 0, 0, 0, 5, 0])   # rent 0, ref 200, count 5
	var list := PackedByteArray([3]) + rec + PackedByteArray([15]) + _u16(5) + _u64(1234) + PackedByteArray([0xFF])
	var l := StallNet.read_list(list, 0)
	var e: StallNet.Entry = (l[0] as Dictionary).get(3) if l[0] != null else null
	_check(e != null and e.item.ref_item_id == 200 and e.bag_slot == 2 and e.count == 5 and e.price == 1234 and int(l[1]) == list.size(),
		"a list: slot 3, the record, bag slot 2 (15 - 13), 5, 1234, 0xFF")
	var entered := PackedByteArray([1, 5, 0, 0, 0, 2, 0, 104, 105, 1, 2]) + list + PackedByteArray([1, 7, 0, 0, 0])
	var d := StallNet.decode_enter(entered)
	_check(not d.is_empty() and int(d["owner"]) == 5 and String(d["greeting"]) == "hi" and bool(d["open"])
		and int(d["value4"]) == 2 and (d["entries"] as Dictionary).has(3) and d["visitors"] == [7],
		"0xB0B3 {1, owner, greeting, open, value4, list, n, uids}")
	_check(int(StallNet.decode_enter(PackedByteArray([2, 0x2a, 0x3c]))["code"]) == 0x3c2a, "0xB0B3 refused")
	_check(StallNet.decode_buy(PackedByteArray([1, 0])) == {"code": 1, "slot": 0}
		and int(StallNet.decode_buy(PackedByteArray([2, 0x11, 0x3c]))["code"]) == 0x3c11, "0xB0B4 both ways")
	var u5 := StallNet.decode_update(PackedByteArray([1, 5, 1, 0, 0]))
	_check(int(u5["type"]) == 5 and bool(u5["open"]), "0xB0BA type 5")
	var u2 := StallNet.decode_update(PackedByteArray([1, 2, 0, 0]) + list)
	_check(int(u2["type"]) == 2 and (u2["entries"] as Dictionary).size() == 1, "0xB0BA type 2 {u16, list}")
	var u1 := StallNet.decode_update(PackedByteArray([1, 1, 3]) + _u16(5) + _u64(99) + _u16(0))
	_check(int(u1["slot"]) == 3 and int(u1["count"]) == 5 and int(u1["price"]) == 99, "0xB0BA type 1")
	_check(String(StallNet.decode_update(PackedByteArray([1, 6, 2, 0, 104, 105]))["greeting"]) == "hi", "0xB0BA type 6")
	_check(int(StallNet.decode_update(PackedByteArray([1, 7]))["type"]) == 7, "0xB0BA type 7 carries nothing more")
	_check(int(StallNet.decode_update(PackedByteArray([2, 0x2b, 0x3c]))["code"]) == 0x3c2b, "0xB0BA refused")
	_check(StallNet.decode_event(PackedByteArray([2, 9, 0, 0, 0])) == {"kind": 2, "uid": 9}, "0x30B7 kind 2")
	var sold := StallNet.decode_event(PackedByteArray([3, 0, 4, 0, 66, 114, 97, 109, 0xFF]))
	_check(int(sold["kind"]) == 3 and int(sold["slot"]) == 0 and String(sold["buyer"]) == "Bram" and (sold["entries"] as Dictionary).is_empty(),
		"0x30B7 kind 3 {slot, buyer, list}")
	_check(StallNet.decode_appear(PackedByteArray([5, 0, 0, 0, 2, 0, 97, 98, 0x07, 0x0f, 0, 0]))
		== {"owner": 5, "name": "ab", "decoration": 3847}, "0x30B8 {owner, name, decoration}")
	_check(StallNet.decode_gone(PackedByteArray([5, 0, 0, 0, 0x17, 0x3c])) == {"owner": 5, "reason": 0x3c17}, "0x30B9 {owner, reason}")
	_check(StallNet.decode_renamed(PackedByteArray([5, 0, 0, 0, 1, 0, 120])) == {"owner": 5, "name": "x"}, "0x30BB {owner, name}")
	ItemInstance.types_of = Callable()
	# The plate, the price, the group table.
	_check(StallNet.plate_title("Shop") == "[Shop]", "the plate's \"[name]\" (c:0x9dc3a0)")
	_check(StallNet.group_digits(1234567) == "1,234,567" and StallNet.group_digits(12) == "12" and StallNet.group_digits(9999999999) == "9,999,999,999",
		"',' every three digits (c:0x8c1d50(.., 3))")
	_check(StallNet.price_colour(9999) == Color.WHITE and StallNet.price_colour(10000) == Color8(0xff, 0xfa, 0x85)
		and StallNet.price_colour(9999999999) == Color8(0xb8, 0xbb, 0xff) and StallNet.price_colour(10000000000) == Color8(0x95, 0xde, 0xff),
		"the price colours by amount (c:0x5d3df0)")
	_check(StallNet.packed_tid([3, 1, 6, 2]) == ((3 << 2) | (1 << 5) | (6 << 7) | (2 << 11)), "the packed TID (c:0x938370)")
	var groups := StallNet.parse_tid_groups("1\t1\t3\t1\t6\t2\r\n0\t9\t3\t3\t1\t1\r\n1\t7\t3\t3\t1\t1\r\n")
	_check(int(groups.get(StallNet.packed_tid([3, 1, 6, 2]), 0)) == 1 and int(groups.get(StallNet.packed_tid([3, 3, 1, 1]), 0)) == 7
		and groups.size() == 2, "fmntidgroupmapdata: service-1 rows, TidGroupID by the packed TID")
	_check(StallNet.CODE_TEXTS[0x3c11] == "UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD" and StallNet.CODE_TEXTS[0x3c3b] == "UIIT_MSG_FREEMARKET_NOTUSE_JOB"
		and not StallNet.CODE_TEXTS.has(0x3c0f) and not StallNet.CODE_TEXTS.has(0x3c2a),
		"category 10: 0x3c11 and 0x3c3b their keys, 0x3c0f and 0x3c2a nothing (c:0x7b8b40)")
	# The spawn record's stall block (UserSpawnNet.read_record): the name and
	# the booth after the guild block, before the timer and team bytes.
	var r := NpcSpawnNet.Reader.new(_stall_record())
	var u := UserSpawnNet.read_record(r, null)
	_check(u != null and r.error == "" and u.interact == 4 and u.stall_name == "Bram's stall" and u.stall_decoration == 3847
		and r.pos == r.data.size(), "a stalling player's record: interact 4, the name and the booth (c:0x9de103..0x9de1bd)")
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## A bare player record with interact 4 (the server's pcspawn.Append layout).
func _stall_record() -> PackedByteArray:
	var b := PackedByteArray()
	b += _u32(1907)                         # RefObjID
	b += PackedByteArray([0x22, 0, 0, 0])   # scale, hwan, cape, auto invest
	b += PackedByteArray([109, 0])          # inventory size, no items
	b += PackedByteArray([5, 0])            # avatar size, none
	b += PackedByteArray([0])               # no mask
	b += _u32(77) + _u16(0x61a8)            # uid, region
	b += _u32(0) + _u32(0) + _u32(0)        # x, y, z
	b += _u16(0)                            # angle
	b += PackedByteArray([0, 1, 0]) + _u16(0)  # no dest, run flag, command, angle
	b += PackedByteArray([1, 0, 0, 0])      # life, stance, motion, body mode
	b += _u32(0) + _u32(0) + _u32(0)        # walk, run, p140
	b += PackedByteArray([0])               # buffs
	b += _u16(4) + "Bram".to_utf8_buffer()
	b += PackedByteArray([0, 0, 0, 0, 0])   # job kind, level, pvp, ride, battle
	b += PackedByteArray([0, 4, 0])         # teleport, interact 4, trade rank
	b += _u16(0)                            # guild name
	b += _u32(0) + _u16(0) + _u32(0) + _u32(0) + _u32(0) + PackedByteArray([0, 0])  # the guild block
	b += _u16(12) + "Bram's stall".to_utf8_buffer() + _u32(3847)
	b += PackedByteArray([0, 0])            # timer, team
	return b
