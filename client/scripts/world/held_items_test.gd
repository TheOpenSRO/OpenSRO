extends SceneTree

## Round 850: HeldItems, the rule that takes a character's weapon and shield
## away for an emote and a stall (READ: FUN_009c8900's op 3, CCompChar slot 22
## 0xc29bd0), on synthetic nodes.
##
##   godot4 --headless --path client --script res://scripts/world/held_items_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_kinds()
	_test_states()
	_test_emotes()
	_test_nodes()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_kinds() -> void:
	for k in [6, 7, 14, 15]:
		_check(HeldItems.kind_hidden(k), "attachable kind %d is hidden (0xc29bd0, which 0)" % k)
	for k in [0, 1, 2, 3, 4, 5, 8, 16, -1, 4294967295]:
		_check(not HeldItems.kind_hidden(k), "attachable kind %d stays (armour, accessories, avatars, job suits)" % k)
	_check(HeldItems.VISUAL_SLOT_META == CharacterAppearance.VISUAL_SLOT_META
		and HeldItems.ATTACH_KIND_META == CharacterAppearance.ATTACH_KIND_META
		and HeldItems.SLOT_WEAPON == CharacterAppearance.SLOT_WEAPON
		and HeldItems.SLOT_SHIELD == CharacterAppearance.SLOT_SHIELD
		and HeldItems.FX_MARKER_META == WornItemFx.MARKER_META, "the metas and slots are the builder's own")

func _test_states() -> void:
	var E := HeldItems.STATE_EMOTE_MASK
	var V := HeldItems.STATE_VENDOR_MASK
	# The emote (state 13), normal play.
	_check(HeldItems.state_effect(true, E, 0) == HeldItems.HIDE, "an emote's enter hides")
	_check(HeldItems.state_effect(false, E, 0) == HeldItems.SHOW, "an emote's leave shows")
	_check(HeldItems.state_effect(true, E, HeldItems.EMOTE_RUSH) == HeldItems.NO_CHANGE, "Rush's enter changes nothing")
	_check(HeldItems.state_effect(false, E, HeldItems.EMOTE_RUSH) == HeldItems.NO_CHANGE, "Rush's leave changes nothing")
	# The Camera console toggle makes Rush hide too.
	_check(HeldItems.state_effect(true, E, HeldItems.EMOTE_RUSH, true, false, true) == HeldItems.HIDE, "Rush hides under Camera")
	# A skill visual change that keeps the weapon hidden (+0x768 bit 0).
	_check(HeldItems.state_effect(true, E, 0, true, true) == HeldItems.HIDE, "kept hidden: an emote hides")
	_check(HeldItems.state_effect(false, E, 0, true, true) == HeldItems.HIDE, "kept hidden: an emote's leave keeps it hidden")
	_check(HeldItems.state_effect(true, E, HeldItems.EMOTE_RUSH, true, true) == HeldItems.SHOW, "kept hidden: Rush shows it")
	_check(HeldItems.state_effect(false, E, HeldItems.EMOTE_RUSH, true, true) == HeldItems.HIDE, "kept hidden: Rush's leave hides it again")
	# The vendor pose (state 15).
	_check(HeldItems.state_effect(true, V, 0) == HeldItems.HIDE, "a stall's vendor pose hides")
	_check(HeldItems.state_effect(false, V, 0) == HeldItems.SHOW, "the stall's close shows")
	_check(HeldItems.state_effect(true, V, 0, false) == HeldItems.NO_CHANGE, "a pet's vendor pose touches nothing (not a CICUser)")
	# Any other state.
	for mask in [1 << 3, 1 << 6, 1 << 9, 1 << 10]:
		_check(HeldItems.state_effect(true, mask, 0) == HeldItems.NO_CHANGE, "state mask 0x%x touches nothing" % mask)

func _test_emotes() -> void:
	# The action window's emotes (ActionCommands.EMOTE_BYTE): all but Rush.
	for id in ActionCommands.EMOTE_BYTE:
		var b: int = ActionCommands.EMOTE_BYTE[id]
		_check(HeldItems.emote_hides(b) == (id != 4004), "emote %d (byte %d) %s the weapon" % [id, b, "hides" if id != 4004 else "keeps"])

func _item(name: String, slot: int, kind: int) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.set_meta(HeldItems.VISUAL_SLOT_META, slot)
	if kind != -99:
		n.set_meta(HeldItems.ATTACH_KIND_META, kind)
	var mi := MeshInstance3D.new()
	n.add_child(mi)
	return n

func _test_nodes() -> void:
	var skel := Skeleton3D.new()
	var weapon := _item("sword", 6, 7)
	var shield := _item("shield", 7, 6)
	var chest := _item("chest", 1, 1)
	var wings := _item("wings", 100, 16)
	var old := _item("old_weapon", 6, -99) # no kind: by its slot
	var fx := Node3D.new()
	fx.set_meta(HeldItems.FX_MARKER_META, weapon.get_instance_id())
	var fx_other := Node3D.new()
	fx_other.set_meta(HeldItems.FX_MARKER_META, chest.get_instance_id())
	for n in [weapon, shield, chest, wings, old, fx, fx_other]:
		skel.add_child(n)
	_check(HeldItems.state_of(skel) == "shown", "a dressed body's held items start shown")
	var n := HeldItems.set_shown(skel, false)
	_check(n == 3, "three held items hidden (sword, shield, an item with no kind by its slot): %d" % n)
	_check(not weapon.visible and not shield.visible and not old.visible, "the weapon and shield nodes are hidden")
	_check(chest.visible and wings.visible, "armour and an avatar stay drawn")
	_check(not fx.visible and fx_other.visible, "the weapon's own particles go with it, the chest's stay")
	_check(HeldItems.state_of(skel) == "hidden", "state_of says hidden")
	HeldItems.set_shown(skel, true)
	_check(weapon.visible and shield.visible and old.visible and fx.visible, "shown again: every held item and its particles")
	weapon.visible = false
	_check(HeldItems.state_of(skel) == "mixed", "state_of tells a mixed body")
	var bare := Skeleton3D.new()
	_check(HeldItems.state_of(null) == "none" and HeldItems.state_of(bare) == "none", "no skeleton or no items: none")
	bare.free()
	skel.free()
