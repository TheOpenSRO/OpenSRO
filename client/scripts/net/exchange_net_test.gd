extends SceneTree

## Round 834: ExchangeNet on the retail wire -- the bytes the server's
## TestExchangeWireLayouts and TestExchangeFullFlow use.
##   godot4 --headless --path client --script res://scripts/net/exchange_net_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_check(ExchangeNet.encode_request(7) == PackedByteArray([7, 0, 0, 0]), "0x7081 {u32 target}")
	_check(ExchangeNet.encode_answer(true) == PackedByteArray([1, 1]) and ExchangeNet.encode_answer(false) == PackedByteArray([1, 0]),
		"0x3080 answer: {1, 1} accepts, {1, 0} refuses")
	_check(ExchangeNet.encode_add(0) == PackedByteArray([4, 13]), "0x7034 {4, slot + 13}")
	_check(ExchangeNet.encode_remove(3) == PackedByteArray([5, 3]), "0x7034 {5, index}")
	_check(ExchangeNet.encode_gold(100) == PackedByteArray([0x0d, 100, 0, 0, 0, 0, 0, 0, 0]), "0x7034 {0xd, u64}")
	_check(ExchangeNet.encode_gold(5000000000).decode_u64(1) == 1000000000, "the gold clamped to 1e9 (c:0x7923ee)")
	_check(ExchangeNet.decode_request_result(PackedByteArray([1, 9, 0, 0, 0])) == [true, 9]
		and ExchangeNet.decode_request_result(PackedByteArray([2, 4, 0])) == [false, 4], "0xB081 both ways")
	_check(ExchangeNet.decode_result(PackedByteArray([1])) == 1 and ExchangeNet.decode_result(PackedByteArray([2, 0x1f, 0x18])) == 0x181f,
		"0xB082 {1} / {2, 0x181f}")
	# 0x308C: the owner's own form carries the bag slot; the partner's not.
	# Item 200 is an expendable (3/3/1): its record is the u16 count.
	ItemInstance.types_of = func(_ref: int) -> PackedInt32Array: return PackedInt32Array([3, 3, 1, 1])
	var rec := PackedByteArray([0, 0, 0, 0, 200, 0, 0, 0, 5, 0])   # rent 0, ref 200, count 5 (an expendable)
	var own := PackedByteArray([5, 0, 0, 0, 1, 15, 0]) + rec
	var other := PackedByteArray([5, 0, 0, 0, 1, 0]) + rec
	var d1 := ExchangeNet.decode_offer(own, 5)
	var d2 := ExchangeNet.decode_offer(other, 6)
	_check(not d1.is_empty() and bool(d1["own"]) and (d1["items"] as Array).size() == 1
		and (d1["items"][0] as ExchangeNet.Offered).bag_slot == 2 and (d1["items"][0] as ExchangeNet.Offered).index == 0,
		"0x308C to the owner: bag slot 2 (15 - 13), index 0")
	_check(not d2.is_empty() and not bool(d2["own"]) and (d2["items"][0] as ExchangeNet.Offered).bag_slot == -1,
		"0x308C to the partner: no bag slot")
	_check(ExchangeNet.decode_gold_update(PackedByteArray([2, 100, 0, 0, 0, 0, 0, 0, 0])) == 100, "0x3089 kind 2")
	_check(ExchangeNet.decode_move_result(PackedByteArray([1, 4, 13, 0])) == {"type": 4, "slot": 0, "index": 0}
		and ExchangeNet.decode_move_result(PackedByteArray([1, 5, 2])) == {"type": 5, "index": 2}
		and int(ExchangeNet.decode_move_result(PackedByteArray([1, 0x0d, 100, 0, 0, 0, 0, 0, 0, 0]))["gold"]) == 100,
		"0xB034's exchange forms")
	_check(ExchangeNet.decode_move_result(PackedByteArray([1, 0, 13, 14, 1, 0, 0])).is_empty(), "another move's 0xB034 is not the exchange's")
	_check(ExchangeNet.CODE_TEXTS[0x18fa] == "UIIT_CTL_NASRUN_NOT_TRADE" and 0x183a in ExchangeNet.CODE_BANNER
		and not (0x1828 in ExchangeNet.CODE_BANNER) and not ExchangeNet.CODE_TEXTS.has(0x1811),
		"the category-1 table: 0x18fa's own key, 0x183a with the banner, 0x1828 a line only, 0x1811 nothing")
	ItemInstance.types_of = Callable()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
