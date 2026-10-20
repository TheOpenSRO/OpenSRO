extends SceneTree

const ErrorText = preload("res://scripts/net/error_text.gd")

## Round 801: the specialty trade's messages as the client reads and writes
## them, from the bytes server/internal/session/specialtytrade.go writes (its
## specialty801_test.go checks the same ones); a good's item record with its
## buyer; the trade-info window's cells; the store line's open id.
## `godot4 --headless --path client --script res://scripts/net/specialty_net_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_check(SpecialtyNet.encode_buy(0x01020304, 0, 2, 100, 0x0a0b0c0d) == PackedByteArray(
		[0x13, 4, 3, 2, 1, 0, 2, 100, 0, 0x0d, 0x0c, 0x0b, 0x0a]), "0x7034 type 0x13")
	_check(SpecialtyNet.encode_sell(7, 0, 100, 9) == PackedByteArray([0x14, 7, 0, 0, 0, 0, 100, 0, 9, 0, 0, 0]),
		"0x7034 type 0x14")
	_check(SpecialtyNet.encode_info(2059) == PackedByteArray([0x0b, 0x08, 0, 0]), "0x74D4")
	var b := SpecialtyNet.decode_result(PackedByteArray([1, 0x13, 5, 0, 0, 0, 0, 2, 1, 0, 100, 0]))
	_check(b["ok"] and b["type"] == 0x13 and b["cos"] == 5 and b["tab"] == 0 and b["slot"] == 2
		and b["dests"] == [0] and b["count"] == 100, "0xB034 type 0x13")
	var s := SpecialtyNet.decode_result(PackedByteArray([1, 0x14, 5, 0, 0, 0, 0, 100, 0, 9, 0, 0, 0, 0xff]))
	_check(s["ok"] and s["slot"] == 0 and s["count"] == 100 and s["npc"] == 9 and s["book"] == 0xff, "0xB034 type 0x14")
	var f := SpecialtyNet.decode_result(PackedByteArray([2, 0x60, 0x18]))
	_check(not f["ok"] and f["code"] == 0x1860, "a refusal")
	var p := SpecialtyNet.decode_prices(PackedByteArray([1, 0x63, 0x08, 0, 0, 0x30, 0x11, 0, 0]))
	_check(p["prices"] == {2147: 4400} and p["order"] == [2147], "0x30E0")
	var info := SpecialtyNet.decode_info(PackedByteArray([1, 0, 0x63, 0x08, 0, 0, 110, 0]))
	_check(info == [{"item": 2147, "percent": 110}], "0xB4D4")
	_check(SpecialtyNet.is_good([3, 3, 8, 1]) and not SpecialtyNet.is_good([3, 3, 1, 1]), "the goods' TypeIDs")
	_check(SpecialtyNet.star_colour(1) == Color8(0x3c, 0x9b, 0xe8) and SpecialtyNet.star_colour(9) == Color8(0xfa, 0x48, 0x48),
		"the stars' tint (0x7a6a28)")
	# A good's record: rent 0, the ref, the count, the buyer's name.
	ItemInstance.types_of = func(_ref: int) -> PackedInt32Array: return PackedInt32Array([3, 3, 8, 1])
	var rec := PackedByteArray([0, 0, 0, 0, 0x63, 0x08, 0, 0, 100, 0, 6, 0])
	rec.append_array("Merchy".to_utf8_buffer())
	var r := ItemInstance.read_record(rec, 0)
	_check(r[0] != null and (r[0] as ItemInstance).count == 100 and (r[0] as ItemInstance).creator == "Merchy"
		and int(r[1]) == rec.size(), "a good's record carries its buyer")
	ItemInstance.types_of = Callable()
	# The store line's open id (c:0x7022d6).
	_check(SpecialtyNet.store_open_id(PackedByteArray([1, 0x0c])) == 0x0c
		and SpecialtyNet.store_open_id(PackedByteArray([1, 2])) == 1, "the store line opens 0xc where it can")
	# The trade-info window.
	var stores := TradeInfoBox.store_list([2010, 7568, 2059], func(ref: int) -> String:
		return {2010: "Jangan Trade center", 2059: "Donwhang Trade center"}.get(ref, ""))
	_check(stores.size() == 2 and stores[1]["ref"] == 2059, "a store with no name is skipped")
	var cells := TradeInfoBox.quote_cells({"item": 2147, "percent": 110}, func(_i: int) -> String: return "Silk",
		func(_i: int) -> String: return "Jangan Trade center")
	_check(cells["GDR_TRADEINFO_SLOT_SPECIALTY_NAME"] == "Silk" and cells["GDR_TRADEINFO_SLOT_STORE_CONDITION"] == "110%"
		and cells["GDR_TRADEINFO_SLOT_STORE_NAME_SELL"] == "Jangan Trade center", "a quotation row")
	_check(TradeInfoBox.quote_cells({}, Callable(), Callable())["GDR_TRADEINFO_SLOT_STORE_CONDITION"] == "",
		"an empty row")
	# The refusals' keys.
	_check(ErrorText.TRADE_UIIT_BY_CODE[0x1865] == "UIIT_MSG_STRGERR_CANT_DEAL_SPECIALTY_SINCE_TOO_FAR_FROM_CART"
		and not ErrorText.TRADE_UIIT_BY_CODE.has(0x1864), "0x1865 has its line, 0x1864 none")
	print("%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
