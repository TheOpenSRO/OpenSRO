extends SceneTree

## Round 735: other players' pluses. The payloads below are the Go server's
## own encoders' output (session.EntitySnapshot.EncodeEntered,
## EnterWorldResult.Encode, ChangeZoneResult.Encode over equip_broadcast_test.go's
## plusSnapshot: slot 1 item 4842 +0, slot 6 item 3727 +7, slot 7 item 3850
## +13), so this decodes what the server actually sends.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _hex(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	for i in range(0, s.length(), 2):
		out.append(("0x" + s.substr(i, 2)).hex_to_int())
	return out

const ENTERED := "09000000000000000400417269610000803f00000040000040400301ea12000000000000068f0e000000000000070a0f0000000000000b006368696e615f776f6d616ebde87307000044020607070d"
const ENTER_WORLD := "010000060039372f3136380000000000000000000000000b00434841525f43485f4d414e0500000009000000020009000000000000000400417269610000803f00000040000040400101ea120000000000000b006368696e615f776f6d616e09000000000000000400417269610000803f00000040000040400301ea12000000000000068f0e000000000000070a0f0000000000000b006368696e615f776f6d616e00000000000200ffbfffbfffbf0000000000020000000000000000000000020000020607070d"
const CHANGE_ZONE := "010000060039372f313638000000000000000000000000020009000000000000000400417269610000803f00000040000040400101ea120000000000000b006368696e615f776f6d616e09000000000000000400417269610000803f00000040000040400301ea12000000000000068f0e000000000000070a0f0000000000000b006368696e615f776f6d616e000000000200ffbfffbf020000000000000000000000020000020607070d"

func _test_entity_entered() -> void:
	var data := _hex(ENTERED)
	var snap := WorldNet.decode_entity_entered(data)
	_check(snap != null, "entered: decodes")
	if snap == null:
		return
	_check(snap.item_in(6) == 3727 and snap.plus_in(6) == 7, "entered: the weapon at +7")
	_check(snap.plus_in(7) == 13, "entered: the shield at +13")
	_check(snap.plus_in(1) == 0 and not snap.pluses.has(1), "entered: the mail at +0, unlisted")
	_check(snap.has_model and snap.ref_obj_id == 1907, "entered: the model before the pluses still reads")
	# An older server's payload -- the same bytes without the tail -- has no pluses.
	var old := WorldNet.decode_entity_entered(data.slice(0, data.size() - 5))
	_check(old != null and old.pluses.is_empty() and old.ref_obj_id == 1907, "entered: no tail, no pluses")
	# A cut tail is ignored, not a crash.
	var cut := WorldNet.decode_entity_entered(data.slice(0, data.size() - 2))
	_check(cut != null and cut.ref_obj_id == 1907, "entered: a cut tail still decodes the snapshot")

func _test_enter_world() -> void:
	var r := WorldNet.decode_enter_world_result(_hex(ENTER_WORLD))
	_check(r.error == "", "enter world: no error (%s)" % r.error)
	_check(r.others.size() == 2, "enter world: two others")
	if r.others.size() == 2:
		_check(r.others[0].pluses.is_empty(), "enter world: the first other has no plus")
		_check(r.others[1].plus_in(6) == 7 and r.others[1].plus_in(7) == 13, "enter world: the second's +7 and +13")

func _test_change_zone() -> void:
	var r := WorldNet.decode_change_zone_result(_hex(CHANGE_ZONE))
	_check(r.error == "", "change zone: no error (%s)" % r.error)
	if r.others.size() == 2:
		_check(r.others[1].plus_in(6) == 7 and r.others[1].plus_in(7) == 13, "change zone: the second's +7 and +13")
	else:
		_check(false, "change zone: two others")

# The retail bytes (equip_broadcast_test.go's golden bytes).
func _test_broadcasts() -> void:
	var on := EquipmentNet.decode_broadcast(_hex("44332211068f0e000007"))
	_check(on != null and on.uid == 0x11223344 and on.slot == 6 and on.ref_item_id == 0xe8f and on.plus == 7, "0x3038: uid, slot, item, +7")
	var off := EquipmentNet.decode_broadcast(_hex("443322110734120000"))
	_check(off != null and off.slot == 7 and off.ref_item_id == 0x1234 and off.plus == -1, "0x3039: no plus")
	_check(EquipmentNet.decode_broadcast(_hex("4433221107341200")) == null, "a cut broadcast is null")

func _init() -> void:
	_test_entity_entered()
	_test_enter_world()
	_test_change_zone()
	_test_broadcasts()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
