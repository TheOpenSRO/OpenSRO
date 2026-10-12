extends SceneTree

## Drawing many monsters (round 655). Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## The world is World3D.tscn with a quiet subclass (height_retry_test.gd's
## pattern): no archive, no network. The species models are SYNTHETIC -- a
## 40-bone skeleton, four skinned pieces of 2,400 vertices and a 256 x 256
## mipmapped texture, built by _synthetic_model -- handed to the world through
## its `_monster_assemble` Callable; no game data is read or shipped. The
## NetClient autoload gets a subclass that counts `list_monsters` calls.
##
## What it holds the world to, with 500 synthetic monster snapshots (the
## densest 5 x 5-region window of the real field spawns holds about 500):
## - a species is assembled ONCE, however many bodies it has, and a cached
##   body costs a fraction of an assembled one (both timed and printed);
## - a 500-monster list is not built in the frame it arrives, and drains
##   over the next frames;
## - no body outside the loaded region cells; built when the cell loads,
##   dropped when it unloads;
## - a hit (OpMonsterDamaged), a kill (OpMonsterDied) and an own attack
##   result ask for no monster list, and the pushed health is applied;
## - a clip is posed only in range and in view (MonsterDraw.pose_wanted);
## - a `_CLON` row with no model takes its Org row's (READ, one level);
## - round 661: a species met for the first time is assembled OFF the main
##   thread -- its first body waits for the template instead of the frame
##   assembling it (a unique's rotation respawn in view froze the game for
##   862 ms, round 661's live check) -- and later bodies of it are immediate.
##
## NEGATIVES, on the base (ab66d9c): no template cache (every body is an
## assembly, and the synthetic hook does not exist, so every body is a
## capsule); the whole list built at once; a monster in an unloaded region
## built at the server's y; a list asked for after every hit, kill and
## result; every clip posed every frame; a `_CLON` drawn as a capsule.

var _failures := 0
var _assembled := 0
var _net_stub: GDScript = null
var _net_original: Script = null

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
	_test_org_rule_table()
	_test_pose_rule()
	var world := _make_world()
	if world != null:
		_stub_net()
		await _test_cache_and_budget(world)
		await _test_region_gate(world)
		await _test_no_list_pulls(world)
		await _test_culling(world)
		_test_org_rule_world(world)
		await _test_class_scale(world)
		await _test_async_template(world)
		await _test_sync_while_pending(world)
		_unstub_net()
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

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
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	world.set("_monster_models_loaded", true)
	var models := {}
	for i in range(5):
		models["MOB_TEST_%d" % i] = "synthetic\\mob_%d.bsr" % i
	world.set("_monster_models_by_code", models)
	world.set("_monster_assemble", _synthetic_model)
	root.add_child(world)
	return world

## A NetClient that counts the monster lists asked for.
func _stub_net() -> void:
	var net := root.get_node_or_null("NetClient")
	if net == null:
		print("info: no NetClient autoload in this run")
		return
	_net_original = net.get_script()
	_net_stub = GDScript.new()
	_net_stub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/net/net_client.gd\"",
		"var monster_lists := 0",
		"var stub_connected := false",
		"func is_connected_to_server() -> bool:",
		"\treturn stub_connected",
		"func list_monsters() -> void:",
		"\tmonster_lists += 1",
		"func list_skills(_n: String) -> void:",
		"\tpass",
		""]))
	_net_stub.reload()
	net.set_script(_net_stub)

func _unstub_net() -> void:
	var net := root.get_node_or_null("NetClient")
	if net != null and _net_original != null:
		net.set_script(_net_original)

func _lists_asked() -> int:
	var net := root.get_node_or_null("NetClient")
	if net == null:
		return -1
	var n = net.get("monster_lists")
	return int(n) if n != null else -1

## A synthetic species model: what SkinnedBsrAssembler hands back, built from
## nothing -- a 40-bone chain, four skinned pieces and a textured material.
func _synthetic_model(path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	_assembled += 1
	var skel := Skeleton3D.new()
	for i in range(40):
		skel.add_bone("b%d" % i)
		if i > 0:
			skel.set_bone_parent(i, i - 1)
		skel.set_bone_rest(i, Transform3D(Basis(), Vector3(0.0, 0.0 if i == 0 else 0.1, 0.0)))
		skel.set_bone_pose_position(i, skel.get_bone_rest(i).origin)
	var image := Image.create(256, 256, true, Image.FORMAT_RGBA8)
	image.fill(Color(0.4, 0.3, 0.2))
	image.generate_mipmaps()
	var material := StandardMaterial3D.new()
	material.albedo_texture = ImageTexture.create_from_image(image)
	var skin := skel.create_skin_from_rest_transforms()
	for piece in range(4):
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		var indices := PackedInt32Array()
		var rows := 40
		var cols := 60
		for r in range(rows):
			for c in range(cols):
				var a := TAU * float(c) / float(cols)
				verts.append(Vector3(cos(a) * 0.5, float(r) * 0.1, sin(a) * 0.5 + float(piece)))
				normals.append(Vector3(cos(a), 0.0, sin(a)))
				uvs.append(Vector2(float(c) / cols, float(r) / rows))
				bones.append_array([r % 40, (r + 1) % 40, 0, 0])
				weights.append_array([0.7, 0.3, 0.0, 0.0])
		for r in range(rows - 1):
			for c in range(cols - 1):
				var i0 := r * cols + c
				indices.append_array([i0, i0 + cols, i0 + 1, i0 + 1, i0 + cols, i0 + cols + 1])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = material
		skel.add_child(mi)
		mi.skin = skin
		mi.skeleton = NodePath("..")
	var result := SkinnedBsrAssembler.AssembledCharacter.new()
	result.skeleton = skel
	result.idle_animation = _synthetic_clip()
	return result

## A two-key looping clip turning b1 through 90 degrees.
func _synthetic_clip() -> BanReader.ParsedAnimation:
	var clip := BanReader.ParsedAnimation.new()
	clip.duration_ms = 1000
	clip.cyclic = true
	clip.key_times = PackedInt32Array([0, 500])
	var track := BanReader.Bone.new()
	track.bone_name = "b1"
	var k0 := BanReader.Keyframe.new()
	k0.rotation = Quaternion.IDENTITY
	k0.position = Vector3(0.0, 0.1, 0.0)
	var k1 := BanReader.Keyframe.new()
	k1.rotation = Quaternion(Vector3.RIGHT, PI / 2.0)
	k1.position = Vector3(0.0, 0.1, 0.0)
	track.keyframes.append(k0)
	track.keyframes.append(k1)
	clip.bones.append(track)
	return clip

func _snapshot(id: int, species: int, x: float, z: float) -> CombatNet.MonsterSnapshot:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = id
	snap.code_name = "MOB_TEST_%d" % species
	snap.monster_name = "Test %d" % species
	snap.x = x
	snap.y = 0.0
	snap.z = z
	snap.hp = 50
	snap.max_hp = 50
	return snap

func _pump(world: Node) -> void:
	if world.has_method("_pump_monster_builds"):
		world.call("_pump_monster_builds")

func _clear_monsters(world: Node) -> void:
	world.call("_sync_monster_bodies", [])
	await process_frame

func _test_cache_and_budget(world: Node) -> void:
	var bodies: Dictionary = world.get("_monster_bodies")
	await physics_frame
	var list: Array = []
	for i in range(500):
		list.append(_snapshot(1000 + i, i % 5, float(i % 25) * 8.0, float(i / 25) * 8.0))
	_assembled = 0
	var sw := Time.get_ticks_usec()
	world.call("_sync_monster_bodies", list)
	var first_frame_usec := Time.get_ticks_usec() - sw
	var first_frame := bodies.size()
	_check(first_frame < 500,
		"a 500-monster list is not built in the frame it arrives (%d built in it, %.1f ms)" % [first_frame, first_frame_usec / 1000.0])
	var frames := 1
	while bodies.size() < 500 and frames < 400:
		_pump(world)
		frames += 1
	var total_usec := Time.get_ticks_usec() - sw
	_check(bodies.size() == 500, "all 500 bodies are built over the next frames (%d after %d frames)" % [bodies.size(), frames])
	_check(_assembled == 5, "5 species are assembled 5 times for 500 bodies (got %d)" % _assembled)
	var modelled := 0
	var assembled: Dictionary = world.get("_monster_assembled")
	for id in bodies:
		if assembled.has(id):
			modelled += 1
	_check(modelled == 500, "every body is its species' model, not a capsule (%d of 500)" % modelled)
	# Cached against uncached, per body: an assembly timed directly, against
	# the templates' own instancing clock.
	var n := 10
	var t0 := Time.get_ticks_usec()
	for i in range(n):
		var a := _synthetic_model("synthetic\\timing.bsr")
		a.skeleton.free()
	var uncached := float(Time.get_ticks_usec() - t0) / n
	var templates = world.get("_monster_templates")
	var cached := -1.0
	if templates != null and int(templates.get("instances")) > 0:
		cached = float(templates.get("instance_usec")) / float(templates.get("instances"))
	print("info: per body, uncached (a synthetic assembly) %.0f us, cached (a template duplicate) %.0f us; 500 bodies in %.1f ms over %d frames" % [
		uncached, cached, total_usec / 1000.0, frames])
	_check(cached > 0.0 and cached * 3.0 < uncached,
		"a cached body costs under a third of an assembled one (%.0f us against %.0f us)" % [cached, uncached])
	var queue = world.get("_monster_build_queue")
	_check(queue is Array and (queue as Array).is_empty(), "the build queue drained")
	await _clear_monsters(world)
	_check(bodies.is_empty(), "an empty list removes every body")

func _test_region_gate(world: Node) -> void:
	var bodies: Dictionary = world.get("_monster_bodies")
	var grid = world.get("_grid")
	world.set("_grid_has_origin", true)
	world.set("_grid_origin_world", Vector3.ZERO)
	var cells: Dictionary = grid.get("loaded_cells")
	cells.clear()
	cells["0_0"] = Vector2i(97, 168)
	# Cell (0, 0) is x in [0, 1920), z in (-1920, 0]; (0, 2) is x in [3840, 5760).
	world.call("_sync_monster_bodies", [_snapshot(2001, 0, 100.0, -100.0), _snapshot(2002, 1, 5000.0, -100.0)])
	for i in range(5):
		_pump(world)
	_check(bodies.has(2001), "a monster in a loaded region has a body")
	_check(not bodies.has(2002), "a monster in a region not loaded has no body")
	var deferred = world.get("_monster_deferred")
	_check(deferred is Dictionary and (deferred as Dictionary).has(2002), "and waits for its region")
	world.call("_spawn_or_update_monster", _snapshot(2003, 2, 5100.0, -200.0))
	_check(not bodies.has(2003), "a pushed spawn in a region not loaded has no body either")
	cells["0_2"] = Vector2i(97, 170)
	world.set("_monster_cells_dirty", true)
	_pump(world)
	_pump(world)
	_check(bodies.has(2002) and bodies.has(2003), "both are built when their region loads")
	cells.erase("0_2")
	world.set("_monster_cells_dirty", true)
	_pump(world)
	_check(not bodies.has(2002) and not bodies.has(2003), "and dropped when it unloads")
	var snaps: Dictionary = world.get("_monster_snapshots")
	_check(snaps.has(2002), "keeping the snapshot for when it loads again")
	world.set("_grid_has_origin", false)
	cells.clear()
	await _clear_monsters(world)

func _test_no_list_pulls(world: Node) -> void:
	var bodies: Dictionary = world.get("_monster_bodies")
	world.call("_sync_monster_bodies", [_snapshot(3001, 0, 10.0, 10.0), _snapshot(3002, 1, 30.0, 10.0)])
	for i in range(5):
		_pump(world)
	var before := _lists_asked()
	var damaged := CombatNet.MonsterDamaged.new()
	damaged.monster_id = 3001
	damaged.damage = 20
	damaged.remaining_hp = 30
	world.call("_on_monster_damaged", damaged)
	_check(_lists_asked() == before, "a hit (OpMonsterDamaged) asks for no monster list (%d asked)" % (_lists_asked() - before))
	var snaps: Dictionary = world.get("_monster_snapshots")
	_check(snaps.has(3001) and (snaps[3001] as CombatNet.MonsterSnapshot).hp == 30, "and its health is kept in the snapshot")
	world.call("_on_monster_died", 3002)
	await process_frame
	_check(_lists_asked() == before, "a kill (OpMonsterDied) asks for no monster list (%d asked)" % (_lists_asked() - before))
	_check(not bodies.has(3002), "and the body goes once its death has played (no die clip here: at once)")
	var result := CombatNet.AttackResult.new()
	result.monster_id = 3001
	result.monster_damage = 10
	result.monster_remaining_hp = 20
	world.set("_last_attack_target", 3001)
	world.call("_on_attack_result", result)
	await create_timer(0.3).timeout
	_check(_lists_asked() == before, "an own attack result asks for no monster list (%d asked)" % (_lists_asked() - before))
	_check(snaps.has(3001) and (snaps[3001] as CombatNet.MonsterSnapshot).hp == 20,
		"and the result's health reaches the snapshot (got %s)" % (str((snaps[3001] as CombatNet.MonsterSnapshot).hp) if snaps.has(3001) else "none"))
	# Round 655's review: a zero-damage cast's reply (a stun, a debuff) reports
	# no blow, and an older server sent its health as 0.
	var no_blow := CombatNet.AttackResult.new()
	no_blow.monster_id = 3001
	no_blow.monster_damage = 0
	no_blow.monster_remaining_hp = 0
	world.call("_on_attack_result", no_blow)
	await create_timer(0.3).timeout
	_check(snaps.has(3001) and (snaps[3001] as CombatNet.MonsterSnapshot).hp == 20,
		"a result with no blow (0 damage, not died) leaves the monster's health alone (got %s)" % (str((snaps[3001] as CombatNet.MonsterSnapshot).hp) if snaps.has(3001) else "none"))
	# A server with no spawn push: a death that has played out asks for ONE
	# list, at most once every DEATH_PULL_SECONDS; one with the push, none.
	var net := root.get_node_or_null("NetClient")
	if net != null and world.get("_spawn_push_seen") != null:
		net.set("stub_connected", true)
		world.call("_sync_monster_bodies", [_snapshot(3003, 0, 50.0, 10.0), _snapshot(3004, 0, 60.0, 10.0),
			_snapshot(3005, 0, 70.0, 10.0)])
		for i in range(5):
			_pump(world)
		world.set("_spawn_push_seen", false)
		world.set("_death_pull_msec", -1000000)
		var before_deaths := _lists_asked()
		world.call("_on_monster_died", 3003)
		world.call("_on_monster_died", 3004)
		_check(_lists_asked() - before_deaths == 1,
			"with no spawn push seen, two deaths in a row ask for one list (got %d)" % (_lists_asked() - before_deaths))
		world.set("_spawn_push_seen", true)
		world.set("_death_pull_msec", -1000000)
		var before_push := _lists_asked()
		world.call("_on_monster_died", 3005)
		_check(_lists_asked() == before_push, "with the spawn push seen, a death asks for none")
		net.set("stub_connected", false)
	else:
		_check(false, "the death-pull throttle exists (_spawn_push_seen)")
	await _clear_monsters(world)

func _test_culling(world: Node) -> void:
	var bodies: Dictionary = world.get("_monster_bodies")
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = Vector3(0.0, 10.0, 0.0)
	cam.look_at(Vector3(0.0, 10.0, -100.0))
	cam.make_current()
	# In front and near; behind; in front but past the range.
	world.call("_sync_monster_bodies", [_snapshot(4001, 0, 0.0, -60.0), _snapshot(4002, 0, 0.0, 60.0),
		_snapshot(4003, 0, 0.0, -3000.0)])
	for i in range(5):
		_pump(world)
	await process_frame
	var assembled: Dictionary = world.get("_monster_assembled")
	_check(assembled.has(4001) and assembled.has(4002) and assembled.has(4003), "three bodies built for the culling check")
	if not (assembled.has(4001) and assembled.has(4002) and assembled.has(4003)):
		cam.queue_free()
		return
	var sk: Array = []
	for id in [4001, 4002, 4003]:
		sk.append((assembled[id] as SkinnedBsrAssembler.AssembledCharacter).skeleton)
	world.set("_idle_anim_time", 0.0)
	world.call("_tick_idle_animations", 0.25)
	var turned := func(s: Skeleton3D) -> bool: return not s.get_bone_pose_rotation(1).is_equal_approx(Quaternion.IDENTITY)
	_check(turned.call(sk[0]), "the body in front and near is posed")
	_check(not turned.call(sk[1]), "the body behind the camera is not posed")
	_check(not turned.call(sk[2]), "the body past the range (3000 from the camera) is not posed")
	# Static rule: the sphere against the frustum and the range.
	cam.queue_free()
	await _clear_monsters(world)

func _test_pose_rule() -> void:
	var path := "res://scripts/world/monster_draw.gd"
	_check(ResourceLoader.exists(path), "MonsterDraw exists")
	if not ResourceLoader.exists(path):
		return
	var draw: Script = load(path)
	var eye := Vector3.ZERO
	# A plane facing +Z (outward), the view down -Z.
	var planes := [Plane(Vector3(0, 0, 1), 0.0)]
	_check(draw.call("pose_wanted", Vector3(0, 0, -100), 2.0, eye, planes, 2020.0), "in front, in range: posed")
	_check(not draw.call("pose_wanted", Vector3(0, 0, 100), 2.0, eye, planes, 2020.0), "behind: not posed")
	_check(draw.call("pose_wanted", Vector3(0, 0, 1.5), 2.0, eye, planes, 2020.0), "a sphere straddling the plane: posed")
	_check(not draw.call("pose_wanted", Vector3(0, 0, -2030), 5.0, eye, planes, 2020.0), "2030 away with radius 5: out of range")
	_check(draw.call("pose_wanted", Vector3(0, 0, -2020), 5.0, eye, planes, 2020.0), "2020 away with radius 5: in range (dist - radius < range)")
	_check(not draw.call("pose_wanted", Vector3(0, 0, -2025), 5.0, eye, planes, 2020.0), "2025 away with radius 5: out (strict)")

func _characterdata_bytes(rows: Array) -> PackedByteArray:
	var lines := PackedStringArray()
	for r in rows:
		var cols := PackedStringArray()
		cols.resize(60)
		for i in range(60):
			cols[i] = "0"
		cols[0] = "1"
		cols[1] = str(r[0])
		cols[2] = r[1]
		cols[3] = "xxx"
		cols[4] = r[2]
		cols[52] = r[3]
		lines.append("\t".join(cols))
	# UTF-16LE with its byte-order mark, as the archive's tables are.
	var bytes := PackedByteArray([0xFF, 0xFE])
	bytes.append_array("\n".join(lines).to_utf16_buffer())
	return bytes

func _test_org_rule_table() -> void:
	var reader: Script = load("res://scripts/npc/npc_table_reader.gd")
	var names := []
	for m in reader.get_script_method_list():
		names.append(m["name"])
	_check(names.has("parse_org_codes") and names.has("model_with_org"), "NpcTableReader reads OrgObjCodeName (col 4)")
	if not (names.has("parse_org_codes") and names.has("model_with_org")):
		return
	var bytes := _characterdata_bytes([
		[1, "MOB_A", "xxx", "mob\\a\\a.bsr"],
		[2, "MOB_A_CLON", "MOB_A", "xxx"],
		[3, "MOB_B", "xxx", "mob\\b\\b.bsr"],
		[4, "MOB_B_CLON2", "MOB_B", "xxx"],
		[5, "MOB_B_CLON3", "MOB_B_CLON2", "xxx"],
		[6, "MOB_C", "xxx", "mob\\c\\c1.bsr,mob\\c\\c2.bsr"],
		[7, "MOB_C_OWN", "MOB_A", "mob\\c\\own.bsr"],
		[8, "MOB_D_NONE", "xxx", "xxx"],
	])
	var models: Dictionary = NpcTableReader.parse_models_by_code(bytes, {}, "")
	var orgs: Dictionary = reader.call("parse_org_codes", bytes, {})
	_check(not orgs.has("MOB_A") and not orgs.has("MOB_D_NONE"), "`xxx` names no Org row")
	_check(reader.call("model_with_org", "MOB_A_CLON", models, orgs) == "mob\\a\\a.bsr", "a `_CLON` with `xxx` takes its Org row's model")
	_check(reader.call("model_with_org", "MOB_B_CLON3", models, orgs) == "", "one level only: an Org whose own model is `xxx` gives none (no chain)")
	_check(reader.call("model_with_org", "MOB_C_OWN", models, orgs) == "mob\\c\\own.bsr", "a row with its own model keeps it, whatever its Org")
	_check(models.get("MOB_C", "") == "mob\\c\\c1.bsr", "several files in the model column: the first (got %s)" % models.get("MOB_C", ""))
	_check(reader.call("model_with_org", "MOB_D_NONE", models, orgs) == "", "no model and no Org: none")

## Round 660: a champion is drawn at 1.5, a giant at 3.0 and an elite at 1.7
## (MonsterDraw.class_scale, READ 0x9d3995), its name plate and cull radius
## grown with it; the party flag changes no scale.
func _test_class_scale(world: Node) -> void:
	await _clear_monsters(world)
	var bodies: Dictionary = world.get("_monster_bodies")
	var list: Array = []
	for r in [[0, false], [1, false], [4, true], [6, false]]:
		var snap := _snapshot(9000 + int(r[0]), 0, 40.0 * float(r[0]), 0.0)
		snap.rarity = int(r[0])
		snap.party = bool(r[1])
		list.append(snap)
	world.call("_sync_monster_bodies", list)
	var frames := 0
	while bodies.size() < 4 and frames < 50:
		_pump(world)
		frames += 1
	var scale_of := func(id: int) -> float:
		var body: Node = bodies.get(id)
		if body == null:
			return -1.0
		for c in body.get_children():
			if c is Skeleton3D:
				return (c as Skeleton3D).scale.x
		return -1.0
	var label_y := func(id: int) -> float:
		var body: Node = bodies.get(id)
		return (body.get_node("Label") as Node3D).position.y if body != null else -1.0
	for r in [[0, 1.0], [1, 1.5], [4, 3.0], [6, 1.7]]:
		var got: float = scale_of.call(9000 + int(r[0]))
		_check(is_equal_approx(got, float(r[1])), "rarity %d is drawn at %.1f (got %.2f)" % [r[0], r[1], got])
	var plain: float = label_y.call(9000)
	_check(plain > 0.0 and is_equal_approx(label_y.call(9004), plain * 3.0), "the giant's name sits three times as high (%.1f against %.1f)" % [label_y.call(9004), plain])
	for m in [MonsterDraw.class_scale(0), MonsterDraw.class_scale(3), MonsterDraw.class_scale(5), MonsterDraw.class_scale(7), MonsterDraw.class_scale(8)]:
		_check(m == 1.0, "normal, unique, titan and strong keep 1.0")
	await _clear_monsters(world)

func _test_org_rule_world(world: Node) -> void:
	var models: Dictionary = world.get("_monster_models_by_code")
	models["MOB_CH_GHOST"] = "synthetic\\ghost.bsr"
	world.set("_monster_org_by_code", {"MOB_CH_GHOST_CLON": "MOB_CH_GHOST"})
	var got = world.call("_monster_model_path", "MOB_CH_GHOST_CLON", "Small-eyed Ghost")
	_check(got == "synthetic\\ghost.bsr", "the world draws a `_CLON` with its Org row's model (got '%s')" % got)

## Round 661: the off-thread template. A new species' first monster gets no
## body in the frame it arrives -- its template is assembling on a
## WorkerThreadPool task (MonsterDraw.Templates.pending) -- and gets it a few
## frames later from the pump; a second monster of the species is built at
## once from the template, with no second assembly.
func _test_async_template(world: Node) -> void:
	await _clear_monsters(world)
	var models: Dictionary = world.get("_monster_models_by_code")
	models["MOB_TEST_9"] = "synthetic\\mob_9.bsr"
	world.set("_monster_async_with_hook", true)
	var bodies: Dictionary = world.get("_monster_bodies")
	var templates = world.get("_monster_templates")
	var before := _assembled
	world.call("_sync_monster_bodies", [_snapshot(9001, 9, 4.0, 4.0)])
	_check(not bodies.has(9001), "a new species' first monster has no body in the frame it arrives")
	_check(templates != null and templates.has_method("pending") and bool(templates.call("pending", "synthetic\\mob_9.bsr")),
		"its template is assembling off the main thread")
	var frames := 0
	while not bodies.has(9001) and frames < 300:
		await process_frame
		_pump(world)
		frames += 1
	var assembled: Dictionary = world.get("_monster_assembled")
	_check(bodies.has(9001) and assembled.has(9001),
		"the body is built from the template once it is ready (%d frame(s))" % frames)
	world.call("_sync_monster_bodies", [_snapshot(9001, 9, 4.0, 4.0), _snapshot(9002, 9, 8.0, 4.0)])
	_check(bodies.has(9002), "a second monster of the species is built at once from the template")
	_check(_assembled - before == 1, "the species was assembled once (%d)" % (_assembled - before))
	world.set("_monster_async_with_hook", false)
	await _clear_monsters(world)

## Round 661's review: a synchronous instance() of a model whose off-thread
## assembly is still under way waits for that assembly and adopts it -- one
## assembly, one template -- instead of assembling a second copy and letting
## the finished task overwrite (and leak) the first.
func _test_sync_while_pending(world: Node) -> void:
	var templates = world.get("_monster_templates")
	var before := _assembled
	templates.call("request", "synthetic\\mob_8.bsr", _synthetic_model)
	var body = templates.call("instance", "synthetic\\mob_8.bsr", _synthetic_model)
	var frames := 0
	while bool(templates.call("pending", "synthetic\\mob_8.bsr")) and frames < 300:
		await process_frame
		templates.call("poll")
		frames += 1
	_check(body != null, "a synchronous instance while the assembly is pending gets a body")
	_check(_assembled - before == 1, "the model was assembled once, not twice (%d)" % (_assembled - before))
	if body != null and body.skeleton != null:
		body.skeleton.free()
