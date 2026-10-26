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
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
