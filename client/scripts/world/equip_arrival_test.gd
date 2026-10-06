extends SceneTree

## Round 735's review fix 1: other players' equipment broadcasts against a zone
## change's arrival list (World3D._on_other_equipment_changed).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Round 735's review, finding 1: a broadcast for a player waiting in a zone
## change's arrival list changes only that slot of the kept snapshot, and one
## for a player not yet reachable is kept and replayed once they are.
func _test_arrival_list() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var ok := world_script != null and world_script.can_instantiate()
	_check(ok, "World3D compiles")
	if not ok:
		return
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

## Round 734's review, F2: a 0x3038 that changes only the plus of the item
## drawn in its slot redraws the glow on the body as it stands
## (CharacterAppearance.reglow), and one that changes the item rebuilds the
## body (_redress_other). NEGATIVE on cf11fefa: both rebuilt the body.
func _test_plus_only() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world: Node = world_script.new()
	var app := CharacterAppearance.new()
	world.set("_appearance", app)
	var node := Node3D.new()
	var skel := Skeleton3D.new()
	node.add_child(skel)
	var wears := [{"slot": CharacterAppearance.SLOT_WEAPON, "code": "ITEM_TEST_SWORD", "plus": 7, "nodes": []}]
	skel.set_meta(CharacterAppearance.GLOW_WEARS_META, wears)
	skel.set_meta("glow_pluses", {6: 7})
	(world.get("_other_bodies") as Dictionary)[5] = node
	(world.get("_other_gaits") as Dictionary)[5] = {"skeleton": skel, "body": "", "scale": CharacterAppearance.DEFAULT_SCALE}
	(world.get("_other_equipped") as Dictionary)[5] = {1: 4842, 6: 3727}
	(world.get("_other_pluses") as Dictionary)[5] = {6: 7}
	world.call("_on_other_equipment_changed", 5, 6, 3727, 13)
	var gait: Dictionary = (world.get("_other_gaits") as Dictionary)[5]
	_check(gait.get("skeleton") == skel and is_instance_valid(skel) and not skel.is_queued_for_deletion(), "plus only: the body is kept, not rebuilt")
	_check(int((wears[0] as Dictionary)["plus"]) == 13 and (skel.get_meta("glow_pluses") as Dictionary) == {6: 13},
		"plus only: the glow is redrawn at +13 (reglow) and the body marked with it")
	_check(int(((world.get("_other_pluses") as Dictionary)[5] as Dictionary).get(6, 0)) == 13, "plus only: _other_pluses at +13")
	# Another item in the slot: the body is rebuilt (_redress_other; with no
	# archives it builds nothing, so the old body stays with its mark).
	world.call("_on_other_equipment_changed", 5, 6, 3728, 13)
	_check(int((wears[0] as Dictionary)["plus"]) == 13 and int(((world.get("_other_equipped") as Dictionary)[5] as Dictionary)[6]) == 3728,
		"another item: no reglow, the slot's item changed for the rebuild")
	world.call("_on_other_equipment_changed", 5, 6, 3728, 0)
	_check(int((wears[0] as Dictionary)["plus"]) == 0 and not ((world.get("_other_pluses") as Dictionary)[5] as Dictionary).has(6),
		"plus only, to +0: the glow taken off on the standing body")
	node.free()
	world.free()

func _initialize() -> void:
	_test_arrival_list()
	_test_plus_only()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
