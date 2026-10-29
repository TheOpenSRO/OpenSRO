extends SceneTree

## Round 840 (lane N): StallNetworkNet on the retail wire -- the bytes the
## server's stallnet840_test.go encodes (session/stallnet.go), the commission
## figure the owner's client prints (c:0x87a4bf..) and the category tree.
##   godot4 --headless --path client --script res://scripts/net/stall_network_net_test.gd

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

func _str(s: String) -> PackedByteArray:
	return _u16(s.to_utf8_buffer().size()) + s.to_utf8_buffer()

func _initialize() -> void:
	# The requests.
	_check(StallNetworkNet.encode_search(1, 0, 7, 3) == PackedByteArray([1, 0]) + _u32(7) + PackedByteArray([3]),
		"0x7461 {u8 mode, u8 page, u32 group, u8 degree}")
	_check(StallNetworkNet.encode_search(3, 12, 0x1234, 0) == PackedByteArray([3, 12]) + _u32(0x1234) + PackedByteArray([0]),
		"0x7461 a page (mode 3)")
	var r := StallNetworkNet.Record.new()
	r.owner = 0x01020304
	r.slot = 9
	r.price = 1234567890123
	r.count = 250
	r.level = 64
	r.serial = 0x0a0b0c0d0e0f
	_check(StallNetworkNet.encode_buy(r) == _u32(0x01020304) + PackedByteArray([9]) + _u64(1234567890123) + _u16(250)
		+ PackedByteArray([64]) + _u64(0x0a0b0c0d0e0f), "0x7463 {u32 owner, u8 slot, u64 price, u16 count, u8 level, u64 serial}")
	# The answers.
	_check(StallNetworkNet.decode_result(PackedByteArray([1])) == 1
		and StallNetworkNet.decode_result(PackedByteArray([2, 0x4f, 0x3c])) == 0x3c4f, "{1} / {2, 0x3c4f}")
	ItemInstance.types_of = func(_ref: int) -> PackedInt32Array: return PackedInt32Array([3, 3, 1, 1])
	var item := PackedByteArray([0, 0, 0, 0, 200, 0, 0, 0, 5, 0])   # rent 0, ref 200, count 5
	var rec1 := item + _u32(77) + _str("Seller") + PackedByteArray([2]) + _u16(5) + PackedByteArray([30]) + _u64(4500) + _u64(99)
	var rec2 := item + _u32(78) + _str("B") + PackedByteArray([0]) + _u16(5) + PackedByteArray([1]) + _u64(0) + _u64(100)
	var d := StallNetworkNet.decode_search(PackedByteArray([1, 2, 3]) + rec1 + rec2, 1)
	_check(int(d.get("code", 0)) == 1 and int(d.get("pages", 0)) == 3 and (d.get("records", []) as Array).size() == 2,
		"0xB461 {1, n 2, pages 3, records}")
	if (d.get("records", []) as Array).size() == 2:
		var a: StallNetworkNet.Record = d["records"][0]
		var b: StallNetworkNet.Record = d["records"][1]
		_check(a.item.ref_item_id == 200 and a.owner == 77 and a.seller == "Seller" and a.slot == 2 and a.count == 5
			and a.level == 30 and a.price == 4500 and a.serial == 99, "a record: item, owner, seller, slot, count, level, price, serial")
		_check(a.number == 16 and b.number == 17, "Number = page * 15 + i (c:0x6c99a4), from 1")
		_check(b.seller == "B" and b.price == 0 and b.serial == 100, "the second record")
	_check(StallNetworkNet.decode_search(PackedByteArray([1, 0, 0])).get("records", null) is Array
		and int(StallNetworkNet.decode_search(PackedByteArray([1, 0, 0]))["pages"]) == 0, "{1, 0, 0}: nothing found")
	_check(int(StallNetworkNet.decode_search(PackedByteArray([2, 0x49, 0x3c]))["code"]) == 0x3c49, "{2, 0x3c49}")
	_check(StallNetworkNet.decode_search(PackedByteArray([1, 1, 1]) + item).is_empty(), "a cut record does not parse")
	# The static lambda must not outlive this script (a freed capture at exit, as stall_net_test).
	ItemInstance.types_of = Callable()
	# The commission (c:0x87a4bf: ftol(price * 0.01f), 1..100000; nothing for 0).
	var table := [[0, 0], [1, 1], [99, 1], [100, 1], [101, 1], [199, 1], [200, 1], [201, 2], [1000, 9], [1001, 10], [10000, 99],
		[100000, 999], [123456789, 100000], [10000000, 99999], [10000002, 100000], [9999999999, 100000]]
	var all_ok := true
	for row in table:
		var got := StallNetworkNet.commission(int(row[0]))
		if got != int(row[1]):
			all_ok = false
			print("  commission(%d) = %d, want %d" % [int(row[0]), got, int(row[1])])
	_check(all_ok, "the commission table (the float 0.01's truncation: 200 -> 1, 1000 -> 9, 10,000,000 -> 99,999)")
	# 0xB0BA's answer values.
	_check(StallNetworkNet.update_net_ok(StallNet.UPDATE_PRICE, 4) and StallNetworkNet.update_net_ok(StallNet.UPDATE_ADD, 2)
		and StallNetworkNet.update_net_ok(StallNet.UPDATE_REMOVE, 5) and StallNetworkNet.update_net_ok(StallNet.UPDATE_PRICE, 0)
		and not StallNetworkNet.update_net_ok(StallNet.UPDATE_ADD, 0x3c41), "0xB0BA types 1/2/3 accept 4/2/5 and 0 (c:0x8783f2..)")
	# The tree.
	var tree := "1\tWK_CH_WEAPON\tUIIT_CTL_WK_CH_WEAPON\txxx\t0\t0\r\n" \
		+ "1\tWK_CH_WEAPON_SWORD\tUIIT_CTL_WK_CH_WEAPON_SWORD\tWK_CH_WEAPON\t1\t11\r\n" \
		+ "1\tWK_CH_WEAPON_BLADE\tUIIT_CTL_WK_CH_WEAPON_BLADE\tWK_CH_WEAPON\t2\t11\r\n" \
		+ "2\tWK_OTHER\tX\txxx\t0\t0\r\n" \
		+ "1\tWK_ETC\tUIIT_CTL_WK_ETC\txxx\t0\t0\r\n1\tWK_ETC_ETC\tUIIT_CTL_WK_ETC_ETC\tWK_ETC\t57\t0\r\n"
	var classes := StallNetworkNet.parse_tree(tree)
	_check(classes.size() == 2 and (classes[0] as StallNetworkNet.Category).types.size() == 2
		and ((classes[0] as StallNetworkNet.Category).types[1] as StallNetworkNet.Category).group == 2
		and ((classes[0] as StallNetworkNet.Category).types[0] as StallNetworkNet.Category).degrees == 11
		and ((classes[1] as StallNetworkNet.Category).types[0] as StallNetworkNet.Category).group == 57,
		"the tree: classes (parent xxx) with their types, group and degrees; Service 1 only")
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
