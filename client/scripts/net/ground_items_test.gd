extends SceneTree

## GroundItemsNet decoders against byte layouts built the way the server's
## session/grounditem.go Encode() writes them.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _snapshot_bytes(id: int, item_id: int, qty: int, gold: bool, x: float, y: float, z: float, owner: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(41)
	b.encode_s64(0, id)
	b.encode_s64(8, item_id)
	b.encode_u32(16, qty)
	b.encode_u8(20, 1 if gold else 0)
	b.encode_float(21, x)
	b.encode_float(25, y)
	b.encode_float(29, z)
	b.encode_s64(33, owner)
	return b

func _initialize() -> void:
	# A list of two: a potion stack owned by 9, and a gold pile anyone may take.
	var list := PackedByteArray()
	list.resize(2)
	list.encode_u16(0, 2)
	list.append_array(_snapshot_bytes(7, 4, 2, false, 1.5, -2.0, 3.25, 9))
	list.append_array(_snapshot_bytes(8, 3, 57, true, 0.0, 0.0, 0.0, 0))
	var res := GroundItemsNet.decode_list_result(list)
	_check(res.error == "" and res.items.size() == 2, "list decodes two items")
	if res.items.size() == 2:
		var a: GroundItemsNet.Snapshot = res.items[0]
		var g: GroundItemsNet.Snapshot = res.items[1]
		_check(a.id == 7 and a.item_id == 4 and a.quantity == 2 and not a.gold and a.owner_id == 9, "potion fields")
		_check(is_equal_approx(a.x, 1.5) and is_equal_approx(a.y, -2.0) and is_equal_approx(a.z, 3.25), "potion position")
		_check(g.id == 8 and g.item_id == 3 and g.quantity == 57 and g.gold and g.owner_id == 0, "gold pile fields")
	var truncated := GroundItemsNet.decode_list_result(list.slice(0, 20))
	_check(truncated.error != "", "a truncated list reports an error rather than reading past the end")

	var spawned := GroundItemsNet.decode_snapshot(_snapshot_bytes(11, 6, 1, false, 5, 6, 7, 2))
	_check(spawned != null and spawned.id == 11 and spawned.item_id == 6 and spawned.owner_id == 2, "spawned snapshot decodes")

	var removed_bytes := PackedByteArray()
	removed_bytes.resize(24)
	removed_bytes.encode_s64(0, 7)
	removed_bytes.encode_s64(8, GroundItemsNet.REMOVED_PICKED)
	removed_bytes.encode_s64(16, 9)
	var removed := GroundItemsNet.decode_removed(removed_bytes)
	_check(removed != null and removed.id == 7 and removed.reason == GroundItemsNet.REMOVED_PICKED and removed.picker_id == 9, "removed decodes")
	_check(GroundItemsNet.decode_removed(removed_bytes.slice(0, 10)) == null, "a truncated removed is null")

	var rel := PackedByteArray()
	rel.resize(8)
	rel.encode_s64(0, 7)
	_check(GroundItemsNet.decode_owner_released(rel) == 7, "owner-released decodes the id")

	var pr := PackedByteArray()
	pr.resize(29)
	pr.encode_s64(0, GroundItemsNet.ERR_TOO_FAR)
	pr.encode_s64(8, 7)
	pr.encode_s64(16, 4)
	pr.encode_u32(24, 2)
	pr.encode_u8(28, 0)
	var result := GroundItemsNet.decode_pick_up_result(pr)
	_check(result != null and result.code == GroundItemsNet.ERR_TOO_FAR and result.ground_id == 7 and result.item_id == 4 and result.quantity == 2 and not result.gold, "pick-up result decodes")

	var req := GroundItemsNet.encode_pick_up("Aria", 7)
	_check(req.size() == 2 + 4 + 8 and req.decode_u16(0) == 4 and req.decode_s64(6) == 7, "pick-up request is name then s64 id")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURES" % _failures)
	quit(1 if _failures > 0 else 0)
