extends SceneTree

## Round 837: MallNet on the retail wire -- the bytes of item_mall_wire.md
## §3.5's example round trip, and the chest's OURS messages.
##   godot4 --headless --path client --script res://scripts/net/mall_net_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _hex(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	for t in s.split(" ", false):
		out.append(t.hex_to_int())
	return out

func _initialize() -> void:
	var b := MallNet.Buy.new()
	b.group = 1051
	b.shop_index = 0
	b.tab = 0
	b.slot = 0
	b.package_code = "PACKAGE_MALL_ITEM_ETC_ARCHEMY_MAGICSTONE_ASTRAL_11"
	b.count = 1
	b.points = 0
	b.package_id = 85592
	var want := _hex("18 1b 04 00 00 00 32 00") + b.package_code.to_utf8_buffer() + _hex("01 00 00 00 00 00 00 00 00 00 58 4e 01 00")
	_check(MallNet.encode_buy(b) == want, "0x7034 type 0x18: the wire spec's example (got %s)" % MallNet.encode_buy(b).hex_encode())
	var r := MallNet.decode_buy_result(_hex("01 18 1b 04 00 00 00 01 0d 01 00 00 00 00 00"))
	_check(bool(r.get("ok", false)) and int(r["group"]) == 1051 and r["slots"] == [0] and int(r["count"]) == 1 and not bool(r["chest"]),
		"0xB034 {1, 0x18}: group 1051, bag slot 13 -> index 0, count 1 (got %s)" % str(r))
	var chest := MallNet.decode_buy_result(_hex("01 18 1b 04 00 00 00 00 01 00"))
	_check(bool(chest.get("chest", false)) and (chest["slots"] as Array).is_empty(), "n = 0: the purchase went to the chest (OURS)")
	_check(MallNet.decode_buy_result(_hex("01 08 00")).is_empty(), "another move's 0xB034 is not the mall's")
	_check(MallNet.decode_failure(_hex("02 80 18")) == 0x1880, "{2, 0x1880}")
	_check(MallNet.decode_silk(_hex("ab 03 00 00 75 0e 00 00 00 00 00 00")) == [939, 3701, 0], "0x3153: own 939, gift 3701, point 0")
	_check(MallNet.decode_silk_changed(_hex("02 00 64 00 00 00")) == {"reason": 2, "type": 0, "offset": 100}, "0x3154")
	_check(MallNet.encode_history(1, 2) == PackedByteArray([1, 2]) and MallNet.encode_open(1051) == PackedByteArray([0x1b, 4]), "0x711a, 0x7121")
	var h := MallNet.decode_history(_hex("01 00 00 02 00 1e 00 00 00 10 00 00 00 05 00 00 00 20 00 00 00"))
	_check(int(h["kind"]) == 1 and h["rows"] == [[30, 16], [5, 32]], "0xB11A: two rows (got %s)" % str(h))
	_check((MallNet.decode_history(_hex("01 00 01"))["rows"] as Array).is_empty(), "0xB11A result != 0: no rows")
	var from := "Item Mall".to_utf8_buffer()
	var lst := _hex("01 00  07 00 00 00  a3 0e 00 00  0b 00 00 00") + _hex("09 00") + from + _hex("00 e1 f5 05")
	var e := MallNet.decode_chest_list(lst)
	_check(e.size() == 1 and int(e[0]["entry"]) == 7 and int(e[0]["item"]) == 3747 and int(e[0]["count"]) == 11
		and String(e[0]["from"]) == "Item Mall" and int(e[0]["date"]) == 100000000, "0x00D1 (got %s)" % str(e))
	var lg := _hex("01 00  a3 0e 00 00  0b 00 00 00") + _hex("09 00") + from + _hex("00 e1 f5 05  01 e1 f5 05")
	var l := MallNet.decode_chest_log(lg)
	_check(l.size() == 1 and int(l[0]["taken"]) == 100000001, "0x00D5")
	_check(MallNet.encode_chest_take(0) == PackedByteArray([0, 0, 0, 0]), "0x00D2 {0}: take all")
	_check(MallNet.decode_chest_received(_hex("a3 0e 00 00 02 00 00 00")) == {"item": 3747, "count": 2}, "0x00D6")
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
