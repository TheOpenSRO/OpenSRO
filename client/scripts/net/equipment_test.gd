extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_equip() -> void:
	var encoded := EquipmentNet.encode_equip("Aria", EquipmentNet.SLOT_WEAPON, 3)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow prefix")
	_check(encoded.decode_u32(6) == 6, "slot encodes as 6 (SLOT_WEAPON, seventh in the game's order)")
	_check(encoded.decode_u32(10) == 3, "inventory slot round-trips")

func _test_encode_unequip() -> void:
	var encoded := EquipmentNet.encode_unequip("Aria", EquipmentNet.SLOT_HELM)
	_check(encoded.decode_u32(6) == 0, "slot encodes as 0 (SLOT_HELM, first in the game's order)")

func _build_result(error: String, items: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, items.size())
	out.append_array(count_buf)

	for it in items:
		var buf := PackedByteArray()
		buf.resize(12)
		buf.encode_u32(0, it["slot"])
		buf.encode_s64(4, it["item_id"])
		out.append_array(buf)

	return out

func _test_decode_result() -> void:
	var payload := _build_result("", [{"slot": 0, "item_id": 100}])
	var result := EquipmentNet.decode_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.items.size() == 1, "one item decoded")
	if result.items.size() == 1:
		_check(result.items[0].slot == 0, "slot round-trips")
		_check(result.items[0].item_id == 100, "item id round-trips")

## Round 838: the arrows worn in slot 7 come as an expendable's record, the
## u16 count after the RefItemID (the server's wornItemInfos).
func _test_worn_ammo_record() -> void:
	var was := ItemInstance.types_of
	ItemInstance.types_of = func(_ref: int) -> PackedInt32Array: return PackedInt32Array([3, 3, 4, 1])
	var rec := PackedByteArray()
	rec.resize(10)
	rec.encode_u32(0, 0)
	rec.encode_u32(4, 3823)
	rec.encode_u16(8, 9876)
	var got: Array = ItemInstance.read_record(rec, 0)
	ItemInstance.types_of = was
	_check(got[0] != null and int(got[1]) == 10, "a worn quiver's record reads to its end")
	if got[0] != null:
		_check((got[0] as ItemInstance).count == 9876, "the worn quiver's count is 9876")

## Round 877: a mastery or level refusal and the armour mix raise the banner;
## our own words (a job suit's refusal, a slot error) do not.
func _test_refusal_banner() -> void:
	_check(EquipmentNet.refusal_banner("UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM"), "0x186c raises the banner")
	_check(EquipmentNet.refusal_banner("UIIT_MSG_STRGERR_EU_CANT_MIX_EXCLUSIVE_ARMOR_TYPE"), "0x1832 (Europe) raises the banner")
	_check(EquipmentNet.refusal_banner("UIIT_MSG_STRGERR_CANT_MIX_EXCLUSIVE_ARMOR_TYPE"), "0x1832 (China) raises the banner")
	_check(not EquipmentNet.refusal_banner("that does not go in that slot"), "our own words do not")
	_check(not EquipmentNet.refusal_banner(""), "no error, no banner")

func _init() -> void:
	_test_refusal_banner()
	_test_encode_equip()
	_test_encode_unequip()
	_test_decode_result()
	_test_worn_ammo_record()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
