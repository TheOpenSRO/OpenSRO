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

## Round 735's review, finding 1: a broadcast for a player waiting in a zone
## change's arrival list changes only that slot of the kept snapshot, and one
## for a player not yet reachable is kept and replayed once they are.
func _test_arrival_list() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world: Node = world_script.new()
	var snap := WorldNet.EntitySnapshot.new()
	snap.character_id = 5
	snap.equipped = {1: 4842, 6: 3727, 7: 3850}
	snap.pluses = {6: 7}
	(world.get("_arrival_entries") as Dictionary)[5] = snap
	world.set("_arrival_pending", true)
	world.call("_on_other_equipment_changed", 5, 6, 3727, 13)
	_check(snap.equipped.size() == 3 and int(snap.pluses.get(6, 0)) == 13, "arrival: the weapon at +13, the other slots kept (%s %s)" % [str(snap.equipped), str(snap.pluses)])
	_check(not (world.get("_other_equipped") as Dictionary).has(5), "arrival: _other_equipped untouched")
	world.call("_on_other_equipment_changed", 5, 7, 3850, -1)
	_check(not snap.equipped.has(7) and snap.equipped.has(1) and snap.equipped.has(6), "arrival: a 0x3039 takes only its slot")
	# A uid nobody holds yet, during the load: kept, then replayed.
	world.call("_on_other_equipment_changed", 9, 6, 3727, 5)
	_check((world.get("_pending_equip_changes") as Array).size() == 1, "loading: an unknown uid's broadcast is kept")
	var late := WorldNet.EntitySnapshot.new()
	late.character_id = 9
	late.equipped = {1: 4842, 6: 3727}
	(world.get("_arrival_entries") as Dictionary)[9] = late
	world.call("_flush_pending_equip_changes")
	_check(int(late.pluses.get(6, 0)) == 5 and late.equipped.size() == 2, "loading: replayed onto the snapshot that arrived")
	_check((world.get("_pending_equip_changes") as Array).is_empty(), "loading: the buffer is emptied")
	world.free()

func _init() -> void:
	_test_arrival_list()
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
