extends SceneTree

## Round 843, lane W: "when using the model switcher, the seal and + glow /
## effects need to stay". A model switcher's item (round 838) is drawn as the
## archive's <code>_SWITCHnn row. The glow and seal effects are looked up by
## the drawn row's code (READ, FUN_00a5f3e0: RefID and plus only), and the
## archive gives the twins of the LOCKED Seal of Nova rows none -- the rows
## an UNLOCKED (_ACTIVE) item is drawn with (MEASURED: the user's own item on
## prod, ITEM_EU_TSWORD_11_A_RARE_ACTIVE +12 -> ITEM_EU_TSWORD_11_A_RARE_
## SWITCH13). OURS: such a row takes the item's own glow and seal; a row with
## rows of its own (the Egyptian sets' twins, MEASURED) keeps them.
##   godot4 --headless --path client --script res://scripts/items/item_switch_glow843_test.gd
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

const LOCKED := "ITEM_TEST_BLADE_11_A_RARE"
const UNLOCKED := "ITEM_TEST_BLADE_11_A_RARE_ACTIVE"
const TWIN := "ITEM_TEST_BLADE_11_A_RARE_SWITCH13"
const SET_BASE := "ITEM_TEST_BLADE_11_SET_A_RARE"
const SET_TWIN := "ITEM_TEST_BLADE_11_SET_A_RARE_SWITCH05"
const ID_LOCKED := 101
const ID_UNLOCKED := 102
const ID_TWIN := 103
const ID_SET := 104
const ID_SET_TWIN := 105

func _tables() -> ItemGlowTables:
	var t := ItemGlowTables.new()
	t.load_options(_bytes(["//_HONOR\ttype_number", UNLOCKED + "\t4", SET_BASE + "\t1", SET_TWIN + "\t3"]))
	var rows: Array = []
	for type_number in [1, 3, 4]:
		for p in [3, 8, 12]:
			rows.append("%d \t%d\t0.005000,-0.005000\tprim\\mtrl\\itemoption\\test%d.ddj\t5\t7\t0.1,0.2,0.3\t0.9,0.8,0.7\t1000\t0" % [
				type_number, p, p])
	t.load_types(_bytes(rows))
	t.load_particles(_bytes(["//Item Code Name\tParticle\tScale\tBone\tOffset",
		UNLOCKED + "\tsystem\\test_nova_01.efp\t230\tai_end\tnone",
		SET_BASE + "\tsystem\\test_egya_01.efp\t185\tai_end\tnone",
		SET_TWIN + "\tsystem\\test_egya_01.efp\t150\tai_end\tnone"]), ItemGlowTables.RARE_PATH)
	t.load_particles(_bytes(["//code\tefp\tscale\tbone",
		UNLOCKED + "\tsystem\\test_enchant_b.efp\t230\tai_start\tnone\t8\t100\t100"]), ItemGlowTables.EFP_PATH)
	return t

func _appearance() -> CharacterAppearance:
	var a := CharacterAppearance.new()
	a.glow_tables = _tables()
	var tids := PackedInt32Array([3, 1, 6, 3])
	for pair in [[ID_LOCKED, LOCKED], [ID_UNLOCKED, UNLOCKED], [ID_TWIN, TWIN], [ID_SET, SET_BASE], [ID_SET_TWIN, SET_TWIN]]:
		a._items[int(pair[0])] = {"models": PackedStringArray(["item\\test_%d.bsr" % int(pair[0])]), "type_ids": tids, "code": String(pair[1])}
	return a

func _wear(a: CharacterAppearance, item: Dictionary) -> Dictionary:
	var wears: Array = a._resolve_wears([item], false, false)[0]
	return wears[0] if not wears.is_empty() else {}

func _initialize() -> void:
	_test_tables()
	_test_glow_source()
	_test_glow_on_the_model()
	_test_wear_item()
	_test_broadcast_trailer()
	_test_observer_fx()
	print("FAILURES: %d" % _failures if _failures > 0 else "all passed")
	quit(1 if _failures > 0 else 0)

func _test_tables() -> void:
	var t := _tables()
	_check(t.has_rows(UNLOCKED) and t.has_rows(SET_TWIN) and t.has_rows(SET_TWIN.to_lower()), "has_rows: the unlocked row and the set's twin")
	_check(not t.has_rows(LOCKED) and not t.has_rows(TWIN), "has_rows: the locked row and its twin have none")

func _test_glow_source() -> void:
	var a := _appearance()
	# The bug: the unlocked +12 item drawn as the locked row's twin.
	var before := _wear(a, {"id": ID_TWIN, "plus": 12})
	_check(CharacterAppearance.glow_code_of(before) == TWIN and a.glow_tables.glow_row(TWIN, 12) == null
		and a.glow_tables.seal_rows(TWIN, 12).is_empty(), "without the item's own id the twin draws no glow and no seal (the bug)")
	var w := _wear(a, {"id": ID_TWIN, "plus": 12, "fx": ID_UNLOCKED})
	_check(String(w["code"]) == TWIN and (w["models"] as PackedStringArray)[0] == "item\\test_%d.bsr" % ID_TWIN,
		"the model is the twin's (%s)" % str(w["models"]))
	_check(CharacterAppearance.glow_code_of(w) == UNLOCKED, "the glow and seal are the unlocked item's own (%s)" % CharacterAppearance.glow_code_of(w))
	# A locked item's twin: the locked row has none either, so nothing (the
	# original draws nothing for the locked row, round 786).
	_check(CharacterAppearance.glow_code_of(_wear(a, {"id": ID_TWIN, "plus": 12, "fx": ID_LOCKED})) == TWIN, "a locked item's twin stays plain")
	# A set twin with rows of its own keeps them (MEASURED: its own glow type
	# and the seal's effects at the twin's own scale).
	_check(CharacterAppearance.glow_code_of(_wear(a, {"id": ID_SET_TWIN, "plus": 12, "fx": ID_SET})) == SET_TWIN, "a set twin keeps its own rows")
	_check(a.glow_source(TWIN, 0) == TWIN and a.glow_source(TWIN, 9999) == TWIN, "no own id, or one no table knows: the drawn row")

func _test_glow_on_the_model() -> void:
	var a := _appearance()
	var w := _wear(a, {"id": ID_TWIN, "plus": 12, "fx": ID_UNLOCKED})
	var node := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var plain := ShaderMaterial.new()
	plain.shader = ObjectLoader.OBJECT_SHADER
	mi.material_override = plain
	node.add_child(mi)
	w["nodes"] = [node]
	a._apply_glow(w)
	_check(int(w["glow"]) == 12 and EquipGlow.is_glow(mi.material_override), "the twin's mesh glows at the item's +12 row")
	var far := a._far_glow(w, [node])
	_check(far.size() == 1, "the crowd's far recipe glows too (%d)" % far.size())
	EquipGlow.clear(node)
	# reglow keeps the item's own code (a plus change on the standing body).
	var body := CharacterAppearance.Body.new()
	var skel := Skeleton3D.new()
	body.skeleton = skel
	body.worn = [w]
	a._note_glow_wears(body)
	var listed: Array = skel.get_meta(CharacterAppearance.GLOW_WEARS_META)
	_check(listed.size() == 1 and CharacterAppearance.glow_code_of(listed[0]) == UNLOCKED, "the glow list keeps the item's own code for reglow")
	a.reglow(skel, {CharacterAppearance.SLOT_WEAPON: 8})
	_check(EquipGlow.is_glow(mi.material_override), "reglow at +8: still glowing")
	EquipGlow.clear(node)
	skel.free()
	body.free()
	node.free()

func _test_wear_item() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var item: Dictionary = world_script.call("_wear_item", ID_TWIN, 6, {6: 12}, {6: ID_UNLOCKED})
	_check(item == {"id": ID_TWIN, "plus": 12, "fx": ID_UNLOCKED}, "World3D._wear_item: the own id rides as fx (%s)" % str(item))
	var plain: Dictionary = world_script.call("_wear_item", ID_UNLOCKED, 6, {6: 12}, {})
	_check(plain == {"id": ID_UNLOCKED, "plus": 12}, "no model: the item dict is what it was (%s)" % str(plain))

func _test_broadcast_trailer() -> void:
	# u32 uid 0x11223344, slot 6, ref 62220, plus 12, own 62652 (the server's
	# TestRound843EquipBroadcastOwnTrailer bytes).
	var b := PackedByteArray([0x44, 0x33, 0x22, 0x11, 0x06, 0x0c, 0xf3, 0x00, 0x00, 0x0c, 0xbc, 0xf4, 0x00, 0x00])
	var eb := EquipmentNet.decode_broadcast(b)
	_check(eb != null and eb.ref_item_id == 62220 and eb.plus == 12 and eb.own_ref == 62652, "0x3038 with the own id after the plus")
	var retail := EquipmentNet.decode_broadcast(b.slice(0, 10))
	_check(retail != null and retail.plus == 12 and retail.own_ref == 0, "retail's ten bytes: no own id")

func _test_observer_fx() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world: Node = world_script.new()
	var app := CharacterAppearance.new()
	world.set("_appearance", app)
	var node := Node3D.new()
	var skel := Skeleton3D.new()
	node.add_child(skel)
	var wears := [{"slot": CharacterAppearance.SLOT_WEAPON, "code": TWIN, "plus": 12, "nodes": []}]
	skel.set_meta(CharacterAppearance.GLOW_WEARS_META, wears)
	skel.set_meta("glow_pluses", {6: 12})
	(world.get("_other_bodies") as Dictionary)[5] = node
	world.get("_other_uids").add(5)
	(world.get("_other_gaits") as Dictionary)[5] = {"skeleton": skel, "body": "", "scale": CharacterAppearance.DEFAULT_SCALE}
	(world.get("_other_equipped") as Dictionary)[5] = {6: ID_TWIN}
	(world.get("_other_pluses") as Dictionary)[5] = {6: 12}
	# The spawn's after frame: the same row and plus, the own id after them.
	world.call("_on_other_equipment_changed", 5, 6, ID_TWIN, 12, ID_UNLOCKED)
	_check(((world.get("_other_fx") as Dictionary).get(5, {}) as Dictionary) == {6: ID_UNLOCKED}, "the own id is kept for the slot")
	# A plain 0x3038 for the slot (another item, or the Default switcher and a
	# re-equip): the own id goes.
	world.call("_on_other_equipment_changed", 5, 6, ID_UNLOCKED, 12, 0)
	_check(not (world.get("_other_fx") as Dictionary).has(5), "a plain 0x3038 clears it")
	world.call("_on_other_equipment_changed", 5, 6, ID_TWIN, 12, ID_UNLOCKED)
	world.call("_on_other_equipment_changed", 5, 6, ID_TWIN, -1, 0)
	_check(not (world.get("_other_fx") as Dictionary).has(5), "a 0x3039 clears it")
	node.free()
	world.free()
