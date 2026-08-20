extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_request() -> void:
	var encoded := TradeNet.encode_request("Aria", "Bram")
	_check(encoded.decode_u16(0) == 4, "character name length prefix is 4")
	_check(encoded.decode_u16(6) == 4, "target name length prefix is 4")

func _test_encode_respond() -> void:
	var encoded := TradeNet.encode_respond("Bram", "Aria", true)
	_check(encoded[encoded.size() - 1] == 1, "accept flag is 1")

func _test_encode_set_offer() -> void:
	var encoded := TradeNet.encode_set_offer("Aria", 50, 0, 1)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	var offer_offset := 2 + 4
	_check(encoded.decode_s64(offer_offset) == 50, "gold round-trips")
	_check(encoded.decode_u32(offer_offset + 8) == 0, "item slot round-trips")
	_check(encoded.decode_u32(offer_offset + 12) == 1, "quantity round-trips")

func _test_encode_set_offer_no_item() -> void:
	var encoded := TradeNet.encode_set_offer("Aria", 0, TradeNet.ITEM_SLOT_NONE, 0)
	var offer_offset := 2 + 4
	# -1 as u32 is 0xFFFFFFFF.
	_check(encoded.decode_u32(offer_offset + 8) == 4294967295, "item slot -1 encodes as 0xFFFFFFFF")

func _build_named(name: String) -> PackedByteArray:
	var bytes := name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

func _test_decode_invite() -> void:
	var i := TradeNet.decode_invite(_build_named("Aria"))
	_check(i != null, "decodes successfully")
	if i != null:
		_check(i.requester_name == "Aria", "requester name round-trips")

func _test_decode_started() -> void:
	var s := TradeNet.decode_started(_build_named("Bram"))
	_check(s != null, "decodes successfully")
	if s != null:
		_check(s.partner_name == "Bram", "partner name round-trips")

func _test_decode_declined() -> void:
	var d := TradeNet.decode_declined(_build_named("Aria"))
	_check(d != null, "decodes successfully")
	if d != null:
		_check(d.target_name == "Aria", "target name round-trips")

func _test_decode_cancelled() -> void:
	var c := TradeNet.decode_cancelled(_build_named("Bram"))
	_check(c != null, "decodes successfully")
	if c != null:
		_check(c.cancelled_by_name == "Bram", "cancelled-by name round-trips")

func _build_offer_fields(gold: int, item_slot: int, quantity: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, gold)
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_u32(0, item_slot)
	buf.encode_u32(4, quantity)
	out.append_array(buf)
	return out

func _test_decode_offer_updated() -> void:
	var payload := _build_offer_fields(100, 3, 2)
	var u := TradeNet.decode_offer_updated(payload)
	_check(u != null, "decodes successfully")
	if u != null:
		_check(u.offer.gold == 100, "gold round-trips")
		_check(u.offer.item_slot == 3, "item slot round-trips")
		_check(u.offer.quantity == 2, "quantity round-trips")

func _test_decode_completed() -> void:
	var out := PackedByteArray()
	out.resize(16)
	out.encode_s64(0, 100)
	out.encode_s64(8, 200)
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_u32(0, 3)
	out.append_array(buf)
	var c := TradeNet.decode_completed(out)
	_check(c != null, "decodes successfully")
	if c != null:
		_check(c.received_gold == 100, "received gold round-trips")
		_check(c.received_item_id == 200, "received item id round-trips")
		_check(c.received_quantity == 3, "received quantity round-trips")

func _init() -> void:
	_test_encode_request()
	_test_encode_respond()
	_test_encode_set_offer()
	_test_encode_set_offer_no_item()
	_test_decode_invite()
	_test_decode_started()
	_test_decode_declined()
	_test_decode_cancelled()
	_test_decode_offer_updated()
	_test_decode_completed()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
