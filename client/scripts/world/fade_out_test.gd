extends SceneTree

## Characters fade OUT when they leave the world (round 677, AppearFade's
## fade-out). Run headless on the render box: `client/tools/remote_godot.sh
## tests`.
##
## Holds the fade-out to what retail does (READ, CIDecoDisappear: 255 down to
## 0 over 1.5 s, truncated, then the object is deleted) and the world to it:
## a monster that leaves the area (OpMonsterLeft -- also how the server
## removes one that walks into a town), another player who leaves, a dead
## monster once its corpse's DecayTime has run, and a ground item taken away
## all fade out and free themselves; the same monster spawning again mid-fade
## gets a fresh body beside the fading one; the target window clears; the
## fading body can no longer be clicked; its name plate is untouched; nothing
## is left behind.
##
## Everything is SYNTHETIC (one-triangle meshes, a 4 x 4 texture); no game
## data. New API is reached by name, so the suite runs -- and prints its FAIL
## lines -- on a client without it.
##
## NEGATIVE: on the base (dev 55ca5c8, v0.1.468) there is no fade-out, and
## every one of those bodies is freed the frame it leaves.

const AF_PATH := "res://scripts/world/appear_fade.gd"

var _failures := 0
var AF = null

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	AF = load(AF_PATH) if ResourceLoader.exists(AF_PATH) else null
	_check(AF != null, "AppearFade exists (%s)" % AF_PATH)
	if AF != null:
		_test_curve()
		await _test_model_fade_out()
		await _test_in_then_out()
		await _test_free_now()
	var world := _make_world()
	if world != null:
		await _test_world_left(world)
		await _test_world_death(world)
		await _test_world_death_no_decay(world)
		await _test_world_zone_change_corpse(world)
		await _test_world_player(world)
		await _test_ground_item(world)
		var fades = world.get("_appear_fades")
		_check(fades != null and fades.running() == 0 and fades.twin_count() == 0,
			"nothing is left fading and no twin is kept at the end")
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

static func _has_static(script: Script, name: String) -> bool:
	for m in script.get_script_method_list():
		if String(m["name"]) == name:
			return true
	return false

## The alpha a mesh is drawn at: its fade twin's, or 1.0 for an opaque one.
static func _drawn_alpha(mi: MeshInstance3D) -> float:
	var m := mi.material_override
	if m is ShaderMaterial:
		var a = (m as ShaderMaterial).get_shader_parameter("appear_alpha")
		return 1.0 if a == null else float(a)
	if m is BaseMaterial3D:
		var std := m as BaseMaterial3D
		return 1.0 if std.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED else std.albedo_color.a
	return 1.0

static func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.002

func _texture() -> Texture2D:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.4, 0.3, 0.2, 1.0))
	return ImageTexture.create_from_image(image)

## One triangle with that material (an ArrayMesh: the headless renderer has
## no storage for a PrimitiveMesh).
func _box(material: Material) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 1, 0)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2(1, 0), Vector2(0, 1)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	return mi

## READ: CIDecoDisappear::FUN_00a49970 / vslot_009 -- from 255.0 down by
## 255 / 1.5 a second, set truncated while >= 0, deleted below 0.
func _test_curve() -> void:
	_check(AF.DISAPPEAR_SECONDS == 1.5, "the despawn fade-out is 1.5 s (READ, float 0xd819ec)")
	if not _has_static(AF, "out_alpha_at") or not _has_static(AF, "out_done_at"):
		_check(false, "AppearFade has the fade-out's curve (out_alpha_at, out_done_at)")
		return
	_check(AF.out_alpha_at(0.0) == 255, "alpha 255 at t = 0 (READ: the deco starts at 255.0, float 0xd85284)")
	_check(AF.out_alpha_at(0.5) == 170, "170 at 0.5 s")
	_check(AF.out_alpha_at(0.75) == 127, "127 at 0.75 s, half way (127.5 truncated: READ, rounding control chop at 0xa49ac5)")
	_check(AF.out_alpha_at(1.0) == 85, "85 at 1.0 s")
	_check(AF.out_alpha_at(1.4) == 17, "17 at 1.4 s (17.0)")
	_check(AF.out_alpha_at(1.5) == 0, "0 at 1.5 s (0.0 is still >= 0: set, not yet deleted)")
	_check(not AF.out_done_at(1.5) and AF.out_done_at(1.501), "the object goes once the value is below 0, just after 1.5 s")
	_check(AF.out_done_at(0.001, 0.0), "a 0 s fade-out (the CICMonster +0x7b0 branch) ends at the first step")
	var linear := true
	for i in range(0, 150):
		var t := float(i) / 100.0
		if AF.out_alpha_at(t) != int(255.0 - 170.0 * t):
			linear = false
	_check(linear, "linear and truncated: int(255 - 170 x t) at every 10 ms")

func _test_model_fade_out() -> void:
	var std := StandardMaterial3D.new()
	std.albedo_texture = _texture()
	var fol := ShaderMaterial.new()
	fol.shader = ObjectLoader.FOLIAGE_SHADER
	fol.set_shader_parameter("albedo_texture", std.albedo_texture)
	var model := Node3D.new()
	var a := _box(std)
	var b := _box(fol)
	model.add_child(a)
	model.add_child(b)
	var plate := Label3D.new()
	plate.text = "name"
	model.add_child(plate)
	root.add_child(model)
	var fades = AF.Fades.new()
	if not fades.has_method("start_out"):
		_check(false, "Fades.start_out exists")
		model.free()
		return
	var done := []
	fades.start_out(model, AF.DISAPPEAR_SECONDS, func(m: Node) -> void: done.append(m))
	_check(fades.fading_out(model) and fades.running_out() == 1, "the model is fading out")
	_check(a.material_override != std and _near(_drawn_alpha(a), 1.0) and _near(_drawn_alpha(b), 1.0),
		"each piece draws with a blended twin, at alpha 255 the moment it starts")
	fades.step(0.75)
	_check(_near(_drawn_alpha(a), 127.0 / 255.0) and _near(_drawn_alpha(b), 127.0 / 255.0), "half way at 0.75 s (alpha 127)")
	_check(fades.alpha_of(model) == 127, "alpha_of says 127")
	_check(plate.modulate == Color(1, 1, 1, 1), "the name plate is not faded (READ: drawn at 0xff while the object exists)")
	fades.step(0.75)
	_check(is_instance_valid(model) and not model.is_queued_for_deletion() and _near(_drawn_alpha(a), 0.0),
		"at 1.5 s it is drawn at 0 and still there")
	fades.step(0.02)
	_check(done.size() == 1 and done[0] == model, "past 1.5 s its callback runs once, with the model")
	_check(model.is_queued_for_deletion(), "and it is freed")
	_check(fades.running() == 0 and fades.twin_count() == 0, "the fade is over and its twins are dropped")
	await process_frame
	_check(not is_instance_valid(model), "it is gone the next frame")
	fades.step(1.0)
	_check(done.size() == 1, "a later step runs nothing again")

## A body fading in when it is despawned stops fading in and fades out from
## 255 (INFERRED: the later deco's write is the one drawn).
func _test_in_then_out() -> void:
	var std := StandardMaterial3D.new()
	var model := Node3D.new()
	var mi := _box(std)
	model.add_child(mi)
	root.add_child(model)
	var fades = AF.Fades.new()
	fades.start(model)
	fades.step(1.0)
	_check(_near(_drawn_alpha(mi), 127.0 / 255.0), "fading in, 127 at 1.0 s")
	if not fades.has_method("start_out"):
		_check(false, "Fades.start_out exists")
		model.free()
		return
	fades.start_out(model)
	_check(fades.fading_out(model) and not _in_cohort(fades, model), "a despawn mid-fade-in ends the fade-in and starts the fade-out")
	_check(_near(_drawn_alpha(mi), 1.0), "from 255")
	fades.start(model)
	_check(fades.fading_out(model) and fades.running() == 1, "a fade-in is not started on a body fading out")
	fades.step(1.6)
	_check(model.is_queued_for_deletion() and fades.twin_count() == 0, "and it goes at 1.5 s with nothing kept")
	await process_frame

static func _in_cohort(fades, model: Node) -> bool:
	return fades.fading(model) and not fades.fading_out(model)

func _test_free_now() -> void:
	var model := Node3D.new()
	model.add_child(_box(StandardMaterial3D.new()))
	root.add_child(model)
	var fades = AF.Fades.new()
	if not fades.has_method("free_out_now"):
		_check(false, "Fades.free_out_now exists")
		model.free()
		return
	fades.start_out(model)
	fades.step(0.3)
	_check(fades.free_out_now() == 1 and model.is_queued_for_deletion() and fades.running() == 0,
		"a zone change frees a body still fading out at once")
	await process_frame

# --- The world --------------------------------------------------------------

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _show_loading_screen() -> int:",
		"\treturn 0",
		"func _reload_zone_assets(_zone: String, _frame: String = \"\") -> void:",
		"\tpass",
		"func _place_at_zone_spawn(_zone: String) -> bool:",
		"\treturn true",
		"func _drain_initial_load(_started: int, _frames: int = 0) -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	world.set("_monster_models_loaded", true)
	world.set("_monster_models_by_code", {"MOB_FADE_TEST": "synthetic\\fade.bsr"})
	world.set("_monster_assemble", _synthetic_model)
	root.add_child(world)
	return world

func _synthetic_model(_path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	var skel := Skeleton3D.new()
	skel.add_bone("root")
	skel.add_bone("top")
	skel.set_bone_parent(1, 0)
	skel.set_bone_rest(1, Transform3D(Basis(), Vector3(0.0, 2.0, 0.0)))
	skel.set_bone_pose_position(1, Vector3(0.0, 2.0, 0.0))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _texture()
	skel.add_child(_box(mat))
	var result := SkinnedBsrAssembler.AssembledCharacter.new()
	result.skeleton = skel
	return result

func _step(world: Node, seconds: float) -> void:
	var fades = world.get("_appear_fades")
	if fades != null:
		fades.step(seconds)

func _mesh_of(body: Node) -> MeshInstance3D:
	var found := body.find_children("*", "MeshInstance3D", true, false)
	return found[0] as MeshInstance3D if not found.is_empty() else null

func _snap(id: int) -> CombatNet.MonsterSnapshot:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = id
	snap.code_name = "MOB_FADE_TEST"
	snap.monster_name = "Fade test"
	snap.max_hp = 10
	snap.hp = 10
	return snap

## A monster built and done fading in.
func _built(world: Node, id: int) -> Node3D:
	world.call("_spawn_or_update_monster", _snap(id))
	_step(world, 2.1)
	return (world.get("_monster_bodies") as Dictionary).get(id)

## A monster that leaves the area -- the same message the server sends for
## one that walked into a town (round 674).
func _test_world_left(world: Node) -> void:
	var body := _built(world, 77001)
	_check(body != null, "the monster's body is built")
	if body == null:
		return
	var mi := _mesh_of(body)
	world.set("_last_attack_target", 77001)
	world.call("_on_monster_left", [77001])
	var bodies: Dictionary = world.get("_monster_bodies")
	_check(not bodies.has(77001), "OpMonsterLeft: the body is no longer the monster's")
	_check(is_instance_valid(body) and not body.is_queued_for_deletion(), "but it is not freed at once")
	_check(mi != null and is_instance_valid(mi) and _near(_drawn_alpha(mi), 1.0), "it draws at alpha 255 as the fade starts")
	_check(int(world.get("_last_attack_target")) == -1, "the target window is cleared")
	var label := body.get_node_or_null("Label") as Label3D
	_check(label != null and label.modulate.a == 1.0, "its name plate stays, unfaded")
	await process_frame
	_check(is_instance_valid(body) and body.get_node_or_null("ClickBody") == null, "its click body is gone: it cannot be clicked or attacked")
	_step(world, 0.75)
	_check(is_instance_valid(body) and mi != null and _near(_drawn_alpha(mi), 127.0 / 255.0), "127 at 0.75 s")
	# The same monster comes back into view mid-fade: a fresh body.
	world.call("_spawn_or_update_monster", _snap(77001))
	var again = bodies.get(77001)
	_check(again != null and again != body and is_instance_valid(body),
		"spawned again mid-fade, it gets a fresh body; the old one keeps fading")
	var again_mi := _mesh_of(again) if again != null else null
	_check(again_mi != null and _near(_drawn_alpha(again_mi), 0.0), "the fresh body fades in from 0")
	_step(world, 0.8)
	# Round 762: a finished fade-out's model is freed from World3D's departure
	# free queue in its next frame (a frame's share at a time), not in the step.
	await process_frame
	_check(body.is_queued_for_deletion() if is_instance_valid(body) else true, "the old body is freed past 1.5 s")
	await process_frame
	_check(not is_instance_valid(body), "and gone")
	_check(again != null and is_instance_valid(again) and bodies.get(77001) == again and not (again as Node).is_queued_for_deletion(),
		"the fresh body is the monster's, alone")
	world.call("_on_monster_left", [77001])
	_step(world, 1.6)
	await process_frame

## A dead monster: its corpse lies for its species' DecayTime (READ, the
## server's CGObj::Update), then fades out.
func _test_world_death(world: Node) -> void:
	world.set("_monster_decay_ms_by_code", {"MOB_FADE_TEST": 200})
	var body := _built(world, 77002)
	if body == null:
		_check(false, "the dying monster's body is built")
		return
	_check(world.has_method("_monster_corpse_seconds") and _near(float(world.call("_monster_corpse_seconds", 77002)), 0.2),
		"its corpse time is its DecayTime, 200 ms -> 0.2 s")
	world.call("_on_monster_died", 77002)
	var bodies: Dictionary = world.get("_monster_bodies")
	_check(bodies.get(77002) == body and is_instance_valid(body) and not body.is_queued_for_deletion(),
		"the corpse lies there after the death")
	var click := body.get_node_or_null("ClickBody") as CollisionObject3D
	_check(click == null or (click.collision_layer == 0 and click.is_queued_for_deletion()),
		"the corpse cannot be clicked or targeted from its death (round 677's review: not for its whole DecayTime)")
	await create_timer(0.35).timeout
	_check(not bodies.has(77002), "past its DecayTime it is no longer the monster's")
	_check(is_instance_valid(body) and not body.is_queued_for_deletion() and _near(_drawn_alpha(_mesh_of(body)), 1.0),
		"and fades out from 255 instead of vanishing")
	_step(world, 1.6)
	# Two frames: resumed from a timer, which the tree runs after this frame's
	# delete queue, a queue_free lands at the end of the next frame.
	await process_frame
	await process_frame
	_check(not is_instance_valid(body), "gone once the fade-out has run")

## No DecayTime known (no Media.pk2, no row): the corpse goes after its clip
## (none here), still fading.
func _test_world_death_no_decay(world: Node) -> void:
	world.set("_monster_decay_ms_by_code", {})
	var body := _built(world, 77003)
	if body == null:
		return
	world.call("_on_monster_died", 77003)
	await process_frame
	_check(is_instance_valid(body) and not (world.get("_monster_bodies") as Dictionary).has(77003),
		"with no DecayTime and no clip it fades out at once rather than vanishing")
	_step(world, 1.6)
	await process_frame
	_check(not is_instance_valid(body), "and is gone after 1.5 s")

func _test_world_player(world: Node) -> void:
	world.call("_spawn_or_update_other", 77004, "Leaver", Vector3(10.0, 0.0, 10.0))
	var others: Dictionary = world.get("_other_bodies")
	var body: Node3D = others.get(77004)
	if body == null:
		_check(false, "another player's body is built")
		return
	_step(world, 2.1)
	world.call("_on_entity_left", 77004)
	_check(not others.has(77004) and is_instance_valid(body) and not body.is_queued_for_deletion(),
		"another player who leaves fades out instead of vanishing")
	await process_frame
	# Round 762: its click body leaves every layer at once and goes with the
	# holder (the departure's free queue).
	var click := body.get_node_or_null("PlayerClickBody") as CollisionObject3D if is_instance_valid(body) else null
	_check(is_instance_valid(body) and (click == null or click.collision_layer == 0), "and can no longer be clicked")
	world.call("_spawn_or_update_other", 77004, "Leaver", Vector3(10.0, 0.0, 10.0))
	var again = others.get(77004)
	_check(again != null and again != body, "coming back mid-fade is a fresh body")
	_step(world, 1.6)
	await process_frame
	_check(not is_instance_valid(body) and is_instance_valid(again), "the old one is gone after 1.5 s, the new one stays")
	world.call("_on_entity_left", 77004)
	_step(world, 1.6)
	await process_frame

func _test_ground_item(world: Node) -> void:
	var items := GroundItems.new()
	items.setup(null, {}, Callable(), Callable(), Callable())
	root.add_child(items)
	var snap := GroundItemsNet.Snapshot.new()
	snap.id = 77005
	snap.item_id = 1
	snap.quantity = 1
	items.spawn(snap)
	var node: Node3D = items.get_node_or_null("GroundItem_77005")
	_check(node != null, "a ground item is drawn")
	var fade_out = Callable(world, "_fade_out_body")
	if not world.has_method("_fade_out_body"):
		_check(false, "World3D has _fade_out_body")
		items.free()
		return
	items.call("remove", 77005, fade_out)
	_check(not items.has(77005) and node != null and is_instance_valid(node) and not node.is_queued_for_deletion(),
		"a ground item taken away fades out instead of vanishing (READ: CIItem's vslot 0x4c makes the 1.5 s deco)")
	await process_frame
	_check(node != null and is_instance_valid(node) and node.get_node_or_null("ClickBody") == null, "and cannot be picked")
	_step(world, 1.6)
	await process_frame
	_check(not is_instance_valid(node), "and is gone after 1.5 s")
	items.free()

## A zone change during a corpse hold (round 677's review): the holds are
## cleared, and the old hold's timer does not forget a same-id monster the new
## zone lists.
func _test_world_zone_change_corpse(world: Node) -> void:
	world.set("_monster_decay_ms_by_code", {"MOB_FADE_TEST": 300})
	var body := _built(world, 77007)
	if body == null:
		return
	world.call("_on_monster_died", 77007)
	_check((world.get("_dying_until") as Dictionary).has(77007), "the corpse is held")
	var zone := WorldNet.ChangeZoneResult.new()
	zone.ok = true
	zone.zone = "donwhang"
	await world.call("_on_change_zone_result", zone)
	_check(not (world.get("_dying_until") as Dictionary).has(77007), "a zone change clears the old zone's corpse holds")
	# The new zone lists a monster with the same id (not built yet).
	var snaps: Dictionary = world.get("_monster_snapshots")
	snaps[77007] = _snap(77007)
	await create_timer(0.45).timeout
	_check(snaps.has(77007), "the old corpse's timer does not forget the new zone's monster of the same id")
	world.call("_forget_monster", 77007)
	_step(world, 1.6)
	await process_frame
	await process_frame
