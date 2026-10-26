extends SceneTree

## Round 786: "plus glows and seal effects on equipment" -- the rules as the
## original reads them (docs/protocol/equip_glow_seal.md):
## - the plus to the glow row: none at +0, the highest threshold <= plus, a u8;
## - a piece to its seal effect: the item's own itemrare.txt rows, at every
##   plus, one piece at a time; no Rarity, ItemClass or piece count is read;
## - a Seal item with no row in the three tables (the archive's LOCKED Seal of
##   Nova rows, which the Test Items NPC sold) draws nothing, at any plus;
## - armour has no rows and no glow slot.
##   godot4 --headless --path client --script res://scripts/items/item_glow_seal786_test.gd
## The table lines are made up in the files' format (no game data).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _bytes(lines: Array) -> PackedByteArray:
	return "\r\n".join(PackedStringArray(lines)).to_ascii_buffer()

const THRESHOLDS := [3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
## A made-up locked row, its unlocked twin, and an unlocked armour piece, in
## the shape the archive's rows have (MEASURED: the unlocked weapon has a glow
## type, three itemrare.txt rows and one +8..+100 itemoptionefp.txt row; the
## locked one and every armour piece have none).
const LOCKED := "ITEM_TEST_BLADE_11_A_RARE"
const UNLOCKED := "ITEM_TEST_BLADE_11_A_RARE_ACTIVE"
const ARMOUR := "ITEM_TEST_M_HEAVY_11_HA_A_RARE_ACTIVE"

func _tables() -> ItemGlowTables:
	var t := ItemGlowTables.new()
	t.load_options(_bytes(["//_HONOR\ttype_number", UNLOCKED + "\t1"]))
	var rows: Array = []
	for p in THRESHOLDS:
		rows.append("1 \t%d\t0.005000,-0.005000\tprim\\mtrl\\itemoption\\test%d.ddj\t%d\t%d\t0.1,0.2,0.3\t0.9,0.8,0.7\t%d\t0" % [
			p, p, 4 if p == 3 else 5, 9 if p == 13 else 7, 700 if p == 14 else 1000])
	t.load_types(_bytes(rows))
	t.load_particles(_bytes(["//Item Code Name\tParticle\tScale\tBone\tOffset",
		UNLOCKED + "\tsystem\\test_nova_01.efp\t250\tai_end\tnone",
		UNLOCKED + "\tsystem\\test_nova_02.efp\t250\tai_end\tnone",
		UNLOCKED + "\tsystem\\test_nova_03.efp\t250\tai_end\tnone"]), ItemGlowTables.RARE_PATH)
	t.load_particles(_bytes(["//code\tefp\tscale\tbone",
		UNLOCKED + "\tsystem\\test_enchant_b.efp\t250\tai_start\tnone\t8\t100\t100"]), ItemGlowTables.EFP_PATH)
	return t

func _initialize() -> void:
	_test_plus_to_glow()
	_test_piece_to_seal()
	_test_locked_and_armour()
	_test_inherited_copies()
	_test_appearance()
	_test_dual_models()
	_test_effective_plus()
	await _test_driver_while_readying()
	print("FAILURES: %d" % _failures if _failures > 0 else "all passed")
	quit(1 if _failures > 0 else 0)

## READ: FUN_00a5f3e0 asks for a row only when plus != 0, and FUN_00a93900
## keeps the row with the highest threshold <= plus.
func _test_plus_to_glow() -> void:
	var t := _tables()
	for pair in [[0, 0], [1, 0], [2, 0], [3, 3], [4, 3], [5, 5], [8, 8], [11, 11], [12, 12], [13, 13], [14, 14], [20, 14], [255, 14], [256 + 12, 12]]:
		var r := t.glow_row(UNLOCKED, pair[0])
		var got := r.plus if r != null else 0
		_check(got == pair[1], "+%d -> glow row +%d (got +%d)" % [pair[0], pair[1], got])
	var r12 := t.glow_row(UNLOCKED, 12)
	_check(r12 != null and r12.type_number == 1 and r12.op0 == ItemGlowTables.OP_MODULATE2X and r12.op1 == ItemGlowTables.OP_ADD
		and r12.period_ms == 1000, "+12: the type's +12 row, MODULATE2X then ADD, 1000 ms a half-pulse")
	_check(t.glow_row(UNLOCKED, 3).op0 == ItemGlowTables.OP_MODULATE and t.glow_row(UNLOCKED, 13).op1 == ItemGlowTables.OP_ADDSIGNED2X
		and t.glow_row(UNLOCKED, 14).period_ms == 700, "the ops and the period come from the row, per tier")

## The seal effect is the item's itemrare.txt rows: at every plus, ahead of the
## +8 sparkle (READ: FUN_00aa0270 called with itemrare.txt first; the particle
## loop runs outside the plus test).
func _test_piece_to_seal() -> void:
	var t := _tables()
	for p in [0, 1, 7, 8, 12, 100, 255]:
		_check(t.seal_rows(UNLOCKED, p).size() == 3, "unlocked +%d: the three seal effects" % p)
	_check(t.particle_rows(UNLOCKED, 7).size() == 3 and t.particle_rows(UNLOCKED, 8).size() == 4
		and t.particle_rows(UNLOCKED, 100).size() == 4 and t.particle_rows(UNLOCKED, 101).size() == 3,
		"the +8 sparkle (itemoptionefp.txt) joins at +8..+100 only")
	var rows := t.particle_rows(UNLOCKED, 12)
	_check((rows[0] as ItemGlowTables.ParticleRow).from_file == ItemGlowTables.RARE_PATH
		and (rows[3] as ItemGlowTables.ParticleRow).from_file == ItemGlowTables.EFP_PATH
		and (rows[3] as ItemGlowTables.ParticleRow).efp == "system\\test_enchant_b.efp",
		"the order is the client's: the seal rows, then the plus row")
	_check(is_equal_approx((rows[0] as ItemGlowTables.ParticleRow).scale, 2.5) and (rows[0] as ItemGlowTables.ParticleRow).bone == "ai_end",
		"scale col3 / 100 and the bone, as written")
	_check(t.describe(UNLOCKED, 12).contains("type 1 row +12") and t.describe(UNLOCKED, 12).contains("3 seal effect(s)")
		and t.describe(UNLOCKED, 12).contains("1 plus effect(s)"), "describe: %s" % t.describe(UNLOCKED, 12))

## MEASURED (equip_glow_seal.md): the archive's locked Seal of Nova rows have
## no glow type and no particle row, nor does any armour piece, locked or not.
func _test_locked_and_armour() -> void:
	var t := _tables()
	for code in [LOCKED, ARMOUR]:
		for p in [0, 8, 12, 14]:
			_check(t.glow_row(code, p) == null and t.particle_rows(code, p).is_empty() and t.seal_rows(code, p).is_empty(),
				"%s +%d: no glow and no effect" % [code, p])
	_check(t.describe(LOCKED, 12).contains("no glow type in itemoption.txt") and t.describe(LOCKED, 12).contains("draws nothing"),
		"describe says why: %s" % t.describe(LOCKED, 12))
	_check(t.describe(UNLOCKED, 0).contains("glow none") and t.describe(UNLOCKED, 0).contains("3 seal effect(s)"),
		"unlocked +0: no glow, the seal effects still (%s)" % t.describe(UNLOCKED, 0))

func _item(id: int, code: String, org: String, ty: Array) -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.id = id
	it.code_name = code
	it.org_code_name = org
	it.type_ids = PackedInt32Array(ty)
	return it

## READ (round 740, §1.4): an event copy takes its Org item's type and list.
## A copy of the locked row gets nothing, as the locked row has nothing; a copy
## of the unlocked row shares its seal effects.
func _test_inherited_copies() -> void:
	var t := _tables()
	var items := {}
	for it in [_item(1, LOCKED, "", [3, 1, 6, 5]), _item(2, UNLOCKED, "", [3, 1, 6, 5]),
			_item(3, "ITEM_EVENT_TEST_BLADE_11_A_RARE", LOCKED, [3, 1, 6, 5]),
			_item(4, "ITEM_EVENT_TEST_BLADE_11_A_RARE_ACTIVE", UNLOCKED, [3, 1, 6, 5]),
			_item(5, "ITEM_EVENT_" + ARMOUR, ARMOUR, [3, 1, 3, 1])]:
		items[(it as ItemTableReader.Item).id] = it
	t.inherit(items)
	_check(t.glow_row("ITEM_EVENT_TEST_BLADE_11_A_RARE", 12) == null and t.seal_rows("ITEM_EVENT_TEST_BLADE_11_A_RARE", 12).is_empty(),
		"a copy of the locked row: nothing")
	_check(t.glow_row("ITEM_EVENT_TEST_BLADE_11_A_RARE_ACTIVE", 12).plus == 12 and t.seal_rows("ITEM_EVENT_TEST_BLADE_11_A_RARE_ACTIVE", 0).size() == 3,
		"a copy of the unlocked row: its type and its seal effects")
	_check(t.glow_row("ITEM_EVENT_" + ARMOUR, 12) == null, "armour joins no group (the type-word gate: weapons and shields only)")

## The slot rule (READ: only FUN_00a60a90's kind-1 attachments, the weapon and
## the shield): a +12 unlocked piece glows in slot 6 or 7, nowhere else; the
## locked piece glows nowhere.
## Round 828 (READ, CObjCharacter::FUN_00a60a90 -> FUN_00a5f3e0 twice, once a
## part): a dual axe's or dagger's `_r` and `_l` models each take every row
## whose bone their own skeleton has; a single model takes it once.
func _item_model(bones: Array) -> Node3D:
	var node := Node3D.new()
	var sk := Skeleton3D.new()
	for b in bones:
		sk.add_bone(b)
	node.add_child(sk)
	return node

func _test_dual_models() -> void:
	var r := _item_model(["Bone01", "Bone03"])
	var l := _item_model(["Bone01", "Bone03"])
	var hosts := EquipGlow.bone_hosts([r, l], "Bone03")
	_check(hosts.size() == 2 and hosts[0].get_parent() == r and hosts[1].get_parent() == l,
		"a dual weapon's Bone03 row goes on both models, _r then _l")
	_check(EquipGlow.bone_hosts([r], "Bone03").size() == 1, "a single model takes it once")
	var bare := _item_model(["Bone01"])
	_check(EquipGlow.bone_hosts([r, bare], "Bone03").size() == 1 and EquipGlow.bone_hosts([r, l], "ai_end").is_empty(),
		"a model without the bone takes none (FUN_00c816c0 returns 0)")
	for n in [r, l, bare]:
		n.free()

func _test_appearance() -> void:
	var t := _tables()
	var a := CharacterAppearance.new()
	a.glow_tables = t
	var node := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var plain := ShaderMaterial.new()
	plain.shader = ObjectLoader.OBJECT_SHADER
	mi.material_override = plain
	node.add_child(mi)
	var locked := {"slot": CharacterAppearance.SLOT_WEAPON, "code": LOCKED, "plus": 12, "nodes": [node]}
	a._apply_glow(locked)
	_check(int(locked["glow"]) == 0 and int(locked["glow_fx"]) == 0 and mi.material_override == plain, "the locked +12 weapon is drawn plain")
	for slot in [CharacterAppearance.SLOT_CHEST, CharacterAppearance.SLOT_HEAD, CharacterAppearance.SLOT_LEGS]:
		var w := {"slot": slot, "code": UNLOCKED, "plus": 12, "nodes": [node]}
		a._apply_glow(w)
		_check(int(w["glow"]) == 0 and mi.material_override == plain, "slot %d: no glow, whatever the item" % slot)
	for slot in [CharacterAppearance.SLOT_WEAPON, CharacterAppearance.SLOT_SHIELD]:
		var w := {"slot": slot, "code": UNLOCKED, "plus": 12, "nodes": [node]}
		a._apply_glow(w)
		_check(int(w["glow"]) == 12 and EquipGlow.is_glow(mi.material_override), "slot %d: the +12 row" % slot)
		EquipGlow.clear(node)
	node.free()

## A node that asks for the viewport's EquipFx driver in its own _ready while
## the viewport readies its children -- the dressed player built in World3D's
## _ready when World3D is the main scene, every QA run (MEASURED: the offline
## +12 Nova shots had the glow and no particle; the log's "Parent node is busy
## setting up children, add_child() failed" from driver_for).
class AsksInReady extends Node:
	var got: EquipFx = null
	func _ready() -> void:
		got = EquipFx.driver_for(get_viewport())

func _test_driver_while_readying() -> void:
	# The tree is live from the first frame (before it, nothing is readied).
	await process_frame
	var vp := SubViewport.new()
	var asker := AsksInReady.new()
	vp.add_child(asker)
	root.add_child(vp)
	_check(asker.got != null and vp.get_meta(EquipFx.DRIVER_META) == asker.got, "the driver is made and kept while the viewport readies")
	await process_frame
	_check(is_instance_valid(asker.got) and asker.got.get_parent() == vp and asker.got.is_inside_tree(),
		"... and joins the viewport once it is free (before round 786 it never did: no particle for the run)")
	_check(EquipFx.driver_for(vp) == asker.got, "the same driver is returned after")
	var vp2 := SubViewport.new()
	root.add_child(vp2)
	await process_frame
	var d2 := EquipFx.driver_for(vp2)
	_check(d2.get_parent() == vp2, "a ready viewport takes its driver at once, as before")
	vp.queue_free()
	vp2.queue_free()
	await process_frame

## The plus the glow is chosen by: OptLevel + the advanced elixir, a u8 (READ,
## round 734: the item's +0x8c byte), as World3D._player_pluses takes it.
func _test_effective_plus() -> void:
	var it := ItemInstance.new()
	it.opt_level = 12
	_check(it.effective_plus() == 12, "OptLevel 12: +12")
	it.adv_elixir = 3
	_check(it.effective_plus() & 0xFF == 15, "OptLevel 12 + elixir 3: +15, the +14 row")
