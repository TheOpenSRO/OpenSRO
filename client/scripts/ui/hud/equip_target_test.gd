extends SceneTree

## Round 829: EquipTarget, CIFEquipment::vslot_028's slot rule (0x6ad180,
## READ) and 0x60b850's equip-or-use split.
##   godot4 --headless --path client --script res://scripts/ui/hud/equip_target_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _t(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])

func _initialize() -> void:
	var none := func(_s: int) -> bool: return false
	var worn := {}
	var has := func(s: int) -> bool: return worn.has(s)
	_check(EquipTarget.worn_slot_for(_t(3, 1, 6, 8), none) == 6 and EquipTarget.worn_slot_for(_t(3, 1, 6, 6), none) == 6,
		"every weapon (a two-handed sword, a bow) goes to 6")
	_check(EquipTarget.worn_slot_for(_t(3, 1, 4, 1), none) == 7 and EquipTarget.worn_slot_for(_t(3, 1, 4, 2), none) == 7
		and EquipTarget.worn_slot_for(_t(3, 3, 4, 1), none) == 7, "shields and ammo go to 7")
	_check(EquipTarget.worn_slot_for(_t(3, 1, 7, 1), none) == 8, "a job suit goes to 8")
	var armour := [[1, 0], [2, 2], [3, 1], [4, 4], [5, 3], [6, 5]]
	var ok := true
	for tid3 in [1, 2, 3, 9, 10, 11]:
		for p in armour:
			ok = ok and EquipTarget.worn_slot_for(_t(3, 1, tid3, p[0]), none) == p[1]
	_check(ok, "armour by TypeID4: head 0, shoulder 2, mail 1, pants 4, gauntlet 3, boots 5, both races")
	_check(EquipTarget.worn_slot_for(_t(3, 1, 5, 1), none) == 9 and EquipTarget.worn_slot_for(_t(3, 1, 12, 2), none) == 10,
		"earring 9, necklace 10")
	_check(EquipTarget.worn_slot_for(_t(3, 1, 12, 3), has) == 11, "a ring with both ring slots empty: 11")
	worn[11] = true
	_check(EquipTarget.worn_slot_for(_t(3, 1, 12, 3), has) == 12, "11 worn: 12")
	worn[12] = true
	_check(EquipTarget.worn_slot_for(_t(3, 1, 5, 3), has) == 11, "both worn: 11 again (it swaps the left ring)")
	worn.erase(11)
	_check(EquipTarget.worn_slot_for(_t(3, 1, 12, 3), has) == 11, "only 12 worn: 11")
	_check(EquipTarget.worn_slot_for(_t(3, 1, 13, 1), none) == -1 and EquipTarget.worn_slot_for(_t(3, 3, 1, 1), none) == -1
		and EquipTarget.worn_slot_for(PackedInt32Array(), none) == -1, "avatars (their own storage), potions and unknowns: none")
	_check(EquipTarget.equips_from_quick_slot(_t(3, 1, 6, 9)) and EquipTarget.equips_from_quick_slot(_t(3, 1, 4, 2))
		and EquipTarget.equips_from_quick_slot(_t(3, 3, 4, 1)) and EquipTarget.equips_from_quick_slot(_t(3, 1, 13, 1)),
		"a quick slot equips weapons, shields, ammo and avatars")
	_check(not EquipTarget.equips_from_quick_slot(_t(3, 3, 1, 1)) and not EquipTarget.equips_from_quick_slot(_t(3, 2, 1, 1))
		and not EquipTarget.equips_from_quick_slot(_t(3, 3, 3, 2)), "and uses potions, scrolls and pet items")
	_swap_keeps_both_keys()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## Round 830: key 1 holds sword 71 (worn), key 2 sword 3632 in bag slot 20.
## Key 2 is pressed: the server's worn list (3632 in 6) comes first, the bag
## list (71 in 20) after it.
func _swap_keeps_both_keys() -> void:
	var KEEP := EquipTarget.KEEP_INERT
	var old_bag := {20: 3632}
	var new_bag := {20: 71}
	var worn_after := {3632: 6}
	# The worn list's resync, still on the old bag: 71 is neither in the bag
	# nor worn, and must not be cleared.
	_check(EquipTarget.quick_slot_binding(71, -1, old_bag, worn_after, {}, true, false) == KEEP,
		"the worn list's resync keeps the swapped-out item's key (the bag is stale)")
	_check(EquipTarget.quick_slot_binding(3632, 20, old_bag, worn_after, {}, true, false) == 20,
		"(the stale bag still shows the new weapon in 20)")
	# The bag list's resync: 71 follows to 20, 3632 goes inert.
	_check(EquipTarget.quick_slot_binding(71, -1, new_bag, worn_after, {}, true, true) == 20,
		"the bag list puts the swapped-out item's key on its new bag slot")
	_check(EquipTarget.quick_slot_binding(3632, 20, new_bag, worn_after, {}, true, true) == KEEP,
		"and the worn item's key goes inert")
	# A two-hander's displaced shield (key 3, item 500) lands in bag slot 25.
	_check(EquipTarget.quick_slot_binding(500, -1, {20: 71}, {9001: 6}, {}, true, false) == KEEP
		and EquipTarget.quick_slot_binding(500, -1, {20: 71, 25: 500}, {9001: 6}, {}, true, true) == 25,
		"a displaced shield's key survives the worn list and follows the bag list")
	# An item truly gone (sold, dropped) is cleared by a bag list.
	_check(EquipTarget.quick_slot_binding(71, 20, {}, {}, {}, true, true) == EquipTarget.CLEAR,
		"an item in neither a fresh bag nor the worn list is cleared")
	_check(EquipTarget.quick_slot_binding(71, 20, {}, {}, {71: true}, true, true) == KEEP
		and EquipTarget.quick_slot_binding(71, 20, {}, {}, {}, false, true) == KEEP,
		"(not while its equip is pending, nor before the first worn list)")
