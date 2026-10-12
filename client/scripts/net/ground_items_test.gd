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

	# A pick of a drop that is gone answers the engine's 3 (round 493), a code
	# of its own -- not CanPick's 0x1839 -- so the refusal line can tell them apart.
	pr.encode_s64(0, 3)
	var gone := GroundItemsNet.decode_pick_up_result(pr)
	_check(gone != null and gone.code == GroundItemsNet.ERR_NOT_THERE and GroundItemsNet.ERR_NOT_THERE != GroundItemsNet.ERR_CANNOT_PICK, "a not-there result decodes as ERR_NOT_THERE (3)")

	var req := GroundItemsNet.encode_pick_up("Aria", 7)
	_check(req.size() == 2 + 4 + 8 and req.decode_u16(0) == 4 and req.decode_s64(6) == 7, "pick-up request is name then s64 id")

	# Round 785: retail 0x3036, u32 the picker, u8 the angle (the server's
	# session.PickUpMotion; 193 is its byte for an item due +z of the picker).
	_check(GroundItemsNet.OP_PICK_UP_MOTION == 0x3036, "the pick-up motion is retail's 0x3036")
	var pm := PackedByteArray([0x04, 0x03, 0x02, 0x01, 193])
	var motion := GroundItemsNet.decode_pick_up_motion(pm)
	_check(motion != null and motion.object_id == 0x01020304 and motion.angle == 193, "pick-up motion decodes id and angle")
	_check(GroundItemsNet.decode_pick_up_motion(PackedByteArray([1, 2, 3, 4])) == null, "a 4-byte pick-up motion is null")
	# FUN_008a78b0: byte / 255 * 360 degrees, plus FUN_009c40b0's quarter turn.
	# The server's bytes for an item due +x (0), -z (63), -x (127) and +z (193)
	# read back as the headings toward them -- pi/2, pi, 3 pi/2 and 0 -- to the
	# byte's steps (session.TestPickUpMotionAngle holds the server's side).
	var want := {0: PI / 2.0, 63: PI, 127: 1.5 * PI, 193: 0.0}
	for b in want:
		var got := GroundItemsNet.heading_of_pickup_angle(int(b))
		var off: float = absf(wrapf(got - float(want[b]), -PI, PI))
		_check(off <= 2.0 * TAU / 255.0 + 1e-5, "angle byte %d reads as heading %.3f (want %.3f)" % [int(b), got, float(want[b])])
	_check(is_equal_approx(GroundItemsNet.heading_of_pickup_angle(0), RemoteFacing.WIRE_QUARTER_TURN), "byte 0 is the quarter turn exactly")
	_check(BsrReader.AnimationEntry.TYPE_PICKUP == 38, "the pick-up clip is action type 38")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURES" % _failures)
	quit(1 if _failures > 0 else 0)
