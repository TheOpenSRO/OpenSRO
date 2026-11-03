extends SceneTree

## Round 861: the ride camels and the ride donkey are drawn from their trade
## twins (OURS), and no COS is ever a white capsule.
##
## COS_C_CAMEL1..3 and COS_C_DONKEY name `cos\c_camel1..3.bsr` and
## `cos\c_donkey.bsr`, which this version's Data.pk2 does not hold (MEASURED);
## _cos_build_body fell back to an untextured CapsuleMesh, drawn white. The
## original has no name fallback for a missing file (READ, ResourceMgr::
## FUN_00bedba0's "%s Loading Failed." assert; CosModelFallback's header), so
## the twin is ours: `c_` -> `t_`, then the original's Mangyang stand-in, then
## nothing at all.
##
## SYNTHETIC data only (map_animation_fixture.gd's bones, mesh and clip, and
## ride_body860_test.gd's .bsr writer), never game data. Run headless on the
## render box: `client/tools/remote_godot.sh tests`.
##
## NEGATIVES: with base's _cos_build_body (row.model taken as named, and the
## capsule) "the ride camel is drawn from its trade twin" and "a COS with
## nothing to draw shows no capsule" fail; with trade_twin returning "" the
## twin checks fail.

const Fixture = preload("res://scripts/world/map_animation_fixture.gd")
const Ride860 = preload("res://scripts/world/ride_body860_test.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_test_twin()
	_test_resolve()
	_test_icon()
	var world := _make_world()
	if world != null:
		_test_world(world)
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _test_twin() -> void:
	_check(CosModelFallback.trade_twin("cos\\c_camel1.bsr") == "cos\\t_camel1.bsr", "c_camel1 -> t_camel1")
	_check(CosModelFallback.trade_twin("cos\\c_camel3.bsr") == "cos\\t_camel3.bsr", "c_camel3 -> t_camel3")
	_check(CosModelFallback.trade_twin("cos\\c_donkey.bsr") == "cos\\t_donkey.bsr", "c_donkey -> t_donkey")
	_check(CosModelFallback.trade_twin("COS\\C_Camel2.bsr") == "COS\\T_Camel2.bsr", "the case is kept as written")
	_check(CosModelFallback.trade_twin("icon\\cos\\cos_c_camel1.ddj") == "icon\\cos\\cos_t_camel1.ddj",
		"an icon's cos_c_ -> cos_t_")
	_check(CosModelFallback.trade_twin("cos\\p_wolf_01.bsr") == "", "a pet has no twin")
	_check(CosModelFallback.trade_twin("cos\\t_camel1.bsr") == "", "a trade model has no twin of its own")
	_check(CosModelFallback.trade_twin("mob\\china\\cos_c.bsr") == "", "only the file name's prefix counts")

func _has_of(paths: Array) -> Callable:
	var known := {}
	for p in paths:
		known[String(p).to_lower()] = true
	return func(p: String) -> bool: return known.has(p.to_lower())

func _test_resolve() -> void:
	var full := _has_of(["cos\\c_horse1.bsr", "cos\\t_camel1.bsr", "cos\\t_donkey.bsr", CosModelFallback.MANGNYANG])
	var own := CosModelFallback.resolve("cos\\c_horse1.bsr", full)
	_check(own.path == "cos\\c_horse1.bsr" and own.rule == CosModelFallback.RULE_OWN, "a model in the archive is its own")
	var twin := CosModelFallback.resolve("cos\\c_camel1.bsr", full)
	_check(twin.path == "cos\\t_camel1.bsr" and twin.rule == CosModelFallback.RULE_TWIN, "a missing ride camel takes its trade twin")
	var donkey := CosModelFallback.resolve("cos\\c_donkey.bsr", full)
	_check(donkey.path == "cos\\t_donkey.bsr", "a missing ride donkey takes the trade donkey")
	var stand := CosModelFallback.resolve("cos\\c_camel9.bsr", full)
	_check(stand.path == CosModelFallback.MANGNYANG and stand.rule == CosModelFallback.RULE_MANGNYANG,
		"no twin either: the original's Mangyang stand-in")
	var none := CosModelFallback.resolve("cos\\c_camel9.bsr", _has_of([]))
	_check(none.path == "" and none.rule == CosModelFallback.RULE_NONE, "nothing at all: no path")
	_check(CosModelFallback.resolve("", full).path == "", "an empty model stays empty (the Org rule ran before)")
	_check(CosModelFallback.describe("COS_C_CAMEL1", "cos\\c_camel1.bsr", twin).contains("OURS"),
		"the twin is labelled OURS in the log")
	_check(CosModelFallback.describe("COS_C_HORSE1", "cos\\c_horse1.bsr", own) == "", "the own model says nothing")

func _test_icon() -> void:
	var media := _has_of(["icon\\cos\\cos_t_camel1.ddj", "icon\\cos\\cos_c_horse1.ddj"])
	_check(CosModelFallback.icon_path("icon\\cos\\cos_c_camel1.ddj", media) == "icon\\cos\\cos_t_camel1.ddj",
		"a missing ride camel icon takes the trade camel's")
	_check(CosModelFallback.icon_path("icon\\cos\\cos_c_horse1.ddj", media) == "icon\\cos\\cos_c_horse1.ddj",
		"an icon in the archive is its own")
	_check(CosModelFallback.icon_path("icon\\cos\\cos_c_camel7.ddj", media) == "icon\\cos\\cos_c_camel7.ddj",
		"no twin: the icon is left as named")

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

## The archive holds the trade twin only (as the real Data.pk2: t_camel1, no
## c_camel1), and no Mangyang.
func _archive() -> Pk2Reader:
	var a := Fixture.StubArchive.new()
	a.add("res\\cos\\t_synth.bsr", Ride860._body_bsr(6, "prim\\sway.bsk"))
	a.add("prim\\leaf.bms", Fixture.build_bms())
	a.add("prim\\sway.bsk", Fixture.build_bsk())
	a.add("prim\\sway.ban", Fixture.build_ban(2000, true))
	return a

## {skeleton, skinned pieces, capsules, meshes} under a COS body.
static func _census(body: Node3D) -> Dictionary:
	var out := {"skel": null, "pieces": 0, "capsules": 0, "meshes": 0}
	for n in body.find_children("*", "", true, false):
		if n is Skeleton3D and out.skel == null:
			out.skel = n
		if n is MeshInstance3D:
			out.meshes += 1
			if (n as MeshInstance3D).mesh is CapsuleMesh:
				out.capsules += 1
			if (n as MeshInstance3D).skin != null:
				out.pieces += 1
	return out

func _row(table: CosTable, id: int, code: String, model: String) -> void:
	var row := CosTable.Row.new()
	row.id = id
	row.code = code
	row.type4 = 1
	row.model = model
	row.bc = 20
	table.by_id[row.id] = row
	table.by_code[row.code] = row

func _build(world: Node, uid: int, ref_id: int) -> Node3D:
	var rec := CosSpawnNet.Record.new()
	rec.uid = uid
	rec.ref_id = ref_id
	rec.kind = 0
	rec.life = 1
	(world.get("_cos_recs") as Dictionary)[rec.uid] = rec
	world.call("_cos_build_body", rec, Vector3(10, 0, 10))
	return (world.get("_cos_bodies") as Dictionary).get(rec.uid)

func _test_world(world: Node) -> void:
	world.set("_data_pk2", _archive())
	world.set("_monster_async_templates", false)
	world.set("_monster_models_loaded", true)
	var table := CosTable.new()
	_row(table, 2194, "COS_C_SYNTH_CAMEL", "cos\\c_synth.bsr")
	_row(table, 2199, "COS_C_SYNTH_GONE", "cos\\c_gone.bsr")
	world.set("_cos_table", table)
	var resolver := world.has_method("_cos_model_of")
	_check(resolver and String(world.call("_cos_model_of", table.row(2194))) == "cos\\t_synth.bsr",
		"_cos_model_of: the missing ride model resolves to its trade twin")
	var camel := _build(world, 0x7e000011, 2194)
	_check(camel != null, "the camel's body is built")
	if camel != null:
		var c := _census(camel)
		_check(c.skel != null and c.pieces >= 1 and c.capsules == 0,
			"the ride camel is drawn from its trade twin (skeleton %s, %d skinned piece(s), %d capsule(s))" % [
				c.skel != null, c.pieces, c.capsules])
		_check(c.skel != null and (c.skel as Node).get_parent() == camel, "its skeleton hangs under the body (the saddle's)")
		world.call("_cos_free_body", 0x7e000011)
	_check(resolver and String(world.call("_cos_model_of", table.row(2199))) == "", "no twin and no Mangyang: no model")
	var gone := _build(world, 0x7e000012, 2199)
	_check(gone != null, "a COS with nothing to draw still has its body (its collider and plates)")
	if gone != null:
		var g := _census(gone)
		_check(g.capsules == 0 and g.meshes == 0, "a COS with nothing to draw shows no capsule (%d mesh(es), %d capsule(s))" % [
			g.meshes, g.capsules])
		_check(gone.get_node_or_null("Label") != null, "and keeps its name plate")
		world.call("_cos_free_body", 0x7e000012)
