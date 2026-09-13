extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_buy() -> void:
	var encoded := ShopNet.encode_buy("Aria", 100, 3)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 100, "item id round-trips")
	_check(encoded.decode_u32(14) == 3, "quantity round-trips")

func _test_decode_buy_result_ok() -> void:
	var payload := PackedByteArray([1, 0, 0])
	var result := ShopNet.decode_buy_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")

func _test_decode_buy_result_failure() -> void:
	var reason := "insufficient gold"
	var reason_bytes := reason.to_utf8_buffer()
	var payload := PackedByteArray([0])
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, reason_bytes.size())
	payload.append_array(len_buf)
	payload.append_array(reason_bytes)

	var result := ShopNet.decode_buy_result(payload)
	_check(not result.ok, "ok is false")
	_check(result.reason == reason, "reason round-trips")

func _build_catalog_entry(item_id: int, price: int, item_class: int, phys_attack: float, phys_defense: float) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(16)
	out.encode_s64(0, item_id)
	out.encode_s64(8, price)
	var buf := PackedByteArray()
	buf.resize(12)
	buf.encode_u32(0, item_class)
	buf.encode_float(4, phys_attack)
	buf.encode_float(8, phys_defense)
	out.append_array(buf)
	return out

func _build_list_result(error: String, entries: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	var error_bytes := error.to_utf8_buffer()
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)
	if error != "":
		return out
	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, entries.size())
	out.append_array(count_buf)
	for e in entries:
		out.append_array(_build_catalog_entry(e["id"], e["price"], e["class"], e["attack"], e["defense"]))
	return out

func _test_decode_list_result() -> void:
	var payload := _build_list_result("", [{"id": 100, "price": 250, "class": 3, "attack": 30.5, "defense": 0.0}])
	var result := ShopNet.decode_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.entries.size() == 1, "one entry decoded")
	if result.entries.size() == 1:
		_check(result.entries[0].item_id == 100, "item id round-trips")
		_check(result.entries[0].price == 250, "price round-trips")
		_check(result.entries[0].item_class == 3, "item class round-trips")
		_check(is_equal_approx(result.entries[0].phys_attack_max, 30.5), "phys attack round-trips")

func _test_decode_list_result_error() -> void:
	var payload := _build_list_result("failed to load catalog", [])
	var result := ShopNet.decode_list_result(payload)
	_check(result.error == "failed to load catalog", "error round-trips")
	_check(result.entries.size() == 0, "no entries alongside an error")

func _test_encode_sell() -> void:
	var encoded := ShopNet.encode_sell("Aria", 7, 5)
	_check(encoded.decode_u16(0) == 4, "sell name length prefix is 4")
	_check(encoded.decode_u32(6) == 7, "sell slot round-trips")
	_check(encoded.decode_u32(10) == 5, "sell quantity round-trips")

func _test_decode_sell_result() -> void:
	# ok=1, empty reason, gold_received=42.
	var payload := PackedByteArray([1, 0, 0])
	var gold := PackedByteArray()
	gold.resize(8)
	gold.encode_s64(0, 42)
	payload.append_array(gold)
	var result := ShopNet.decode_sell_result(payload)
	_check(result.error == "", "sell: no decode error")
	_check(result.ok, "sell: ok is true")
	_check(result.gold_received == 42, "sell: gold received round-trips (got %d)" % result.gold_received)

func _test_decode_sell_result_no_gold_tail() -> void:
	# An OK/reason-only payload (no gold tail) still decodes.
	var result := ShopNet.decode_sell_result(PackedByteArray([1, 0, 0]))
	_check(result.error == "" and result.ok and result.gold_received == 0, "sell: tolerates a missing gold tail")

func _init() -> void:
	_test_encode_buy()
	_test_decode_buy_result_ok()
	_test_decode_buy_result_failure()
	_test_decode_list_result()
	_test_decode_list_result_error()
	_test_encode_sell()
	_test_decode_sell_result()
	_test_decode_sell_result_no_gold_tail()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
