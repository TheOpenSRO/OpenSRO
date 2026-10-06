extends SceneTree

## Round 698: the ring on the ground -- the click destination marker and the
## selection circle, one object as in retail (GroundMarkers; READ addresses
## in its header and docs/protocol/ground_markers.md). Run headless on the
## render box: `client/tools/remote_godot.sh tests`.
##
## Checked, on a bare GroundMarkers:
## - the texture per selected class (CICMonster/CICCos 3, CICUser 2, else 1;
##   a ground click 0) and the four Media.pk2 paths;
## - the drape: 3 x 3 cells round the point for size 12, two triangles a
##   cell on the terrain's own vertices + DRAPE_LIFT, UV (0.5, 0.5) under the
##   point, a cell with an unknown corner left out, the still-water quad;
## - the state rules: a ground click shows texture 0 following nothing; a
##   heading move hides; a selection follows; the followed object gone or
##   hidden hides it; a ground click after a selection moves the ring off the
##   selected object; standing still on the point (arrival) keeps it.
## And in the world (World3D.tscn under a subclass whose frame hooks do
## nothing, friend_cast_test.gd's pattern), on a synthetic region whose
## heights are a plane -- never game data:
## - a ground click through _move_by_pick_ray shows the ring at the hit
##   point, draped on the region's vertices, and a sky click (a heading run)
##   hides it; a click under the 5-unit filter still moves it;
## - a monster click (_ring_on_monster) puts texture 3 under it and a cast's
##   _show_target does not move a ring a ground click moved, _select_character
##   texture 2 under the player, _select_self no ring; deselecting
##   (_clear_target) leaves the ring (READ: FUN_00778650(0) clears the id
##   only); the monster's body going (a despawn) hides it on the next step;
## - a zone change hides it and forgets the cached heights.
## Round 698's review:
## - the height cache holds only heights: a region the grid prunes is freed
##   and leaves the cache on the next step;
## - a ground click within 20 units of an NPC neither walks nor moves the ring
##   (READ, FUN_009ec570), a gate does not block, one at 25 units does not;
## - the mesh is rebuilt only when the 3 x 3 window changes: a body moving
##   inside it moves the shader's origin, one crossing a cell edge rebuilds.
##
## Round 701, the ring on a placed floor (OURS, the user's decision of
## 2026-10-03):
## - the floor test: more than 1 above the terrain AND the short ray meets a
##   placed object (layer 1 without the terrain-only bit); a terrain body, no
##   hit, or a point near the ground is the terrain;
## - the floor drape: a 2-unit grid at the hit heights + 0.05; a missed or
##   far-dropped sample and a step over 1 leave their triangles out;
## - in the world: a click on a synthetic deck drapes the deck (centre, edges,
##   nothing past its side), a roof 4 above it is never hit, a click on the
##   ground beside it is the terrain drape unchanged, an NPC standing on the
##   deck gets the floor ring, and a point moving inside one 6-unit cell keeps
##   the mesh while samples are reused across cells.
##
## NEGATIVE: against dev e1ccf792 GroundMarkers does not exist; the suite
## loads it by path and reports one FAIL line and stops. Against dev 34286d92
## (MEASURED) the suite does not parse: floor_choice, floor_drape_arrays,
## floor_sample_ok and FLOOR_MAX_RISE are not in GroundMarkers.

var _failures := 0
var _GM: GDScript
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))

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
	_GM = load("res://scripts/world/ground_markers.gd") if ResourceLoader.exists("res://scripts/world/ground_markers.gd") else null
	_check(_GM != null, "ground_markers.gd exists")
	if _GM != null:
		_test_textures()
		_test_drape()
		_test_states()
		_test_floor_rules()
		await _test_world()
	print("ground_markers_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _test_textures() -> void:
	_check(_GM.texture_index_for(GroundMarkers.Kind.MONSTER) == 3, "a monster's ring is texture 3 (select_04)")
	_check(_GM.texture_index_for(GroundMarkers.Kind.COS) == 3, "a pet / horse / transport (CICCos) is texture 3 too")
	_check(_GM.texture_index_for(GroundMarkers.Kind.PLAYER) == 2, "a player's ring is texture 2 (select_03)")
	_check(_GM.texture_index_for(GroundMarkers.Kind.NPC) == 1, "an NPC's ring is texture 1 (select_02)")
	_check(_GM.texture_index_for(GroundMarkers.Kind.ITEM) == 1, "anything else is texture 1")
	_check(GroundMarkers.TEXTURE_PATHS == ["effect\\select_01.ddj", "effect\\select_02.ddj", "effect\\select_03.ddj", "effect\\select_04.ddj"],
		"the four paths are Media.pk2's effect\\select_01..04.ddj in slot order")
	_check(GroundMarkers.SIZE == 12.0 and GroundMarkers.CELL == 20.0, "size 12, cell 20 (0xd8ace0, 0xe1b830)")

## A plane: h = 0.5 x + 0.25 z + 3 (local units), so every interpolation is exact.
func _plane(col: int, row: int) -> float:
	return 0.5 * col * 20.0 + 0.25 * row * 20.0 + 3.0

func _test_drape() -> void:
	_check(GroundMarkers.cell_reach(12.0) == 1, "size 12 reaches one cell each way (trunc(12 / 20 + 1))")
	_check(GroundMarkers.cell_reach(40.0) == 3, "size 40 reaches three (trunc(40 / 20 + 1))")
	var c := Vector2(105.0, 207.0)
	var d: Dictionary = GroundMarkers.drape_arrays(c, 12.0, _plane, 0.05)
	var v: PackedVector3Array = d["vertices"]
	var uv: PackedVector2Array = d["uvs"]
	_check(v.size() == 9 * 6 and uv.size() == v.size(), "3 x 3 cells, two triangles each (got %d vertices)" % v.size())
	var xs := {}
	var zs := {}
	var on_plane := true
	for p in v:
		xs[p.x] = true
		zs[p.z] = true
		if absf(p.y - (0.5 * p.x + 0.25 * p.z + 3.0 + 0.05)) > 1e-4:
			on_plane = false
	_check(xs.keys().min() == 80.0 and xs.keys().max() == 140.0 and zs.keys().min() == 180.0 and zs.keys().max() == 240.0,
		"the cells are 80..140 x 180..240, round cell (5, 10) under (105, 207)")
	_check(on_plane, "every corner is the terrain's own vertex height + the lift")
	var h := GroundMarkers.drape_height_at(d, c.x, c.y)
	_check(absf(h - (0.5 * c.x + 0.25 * c.y + 3.0 + 0.05)) < 1e-3, "the drape under the point is the ground + 0.05 (%.4f)" % h)
	# UV of the point itself, interpolated like the height.
	var u_at := _uv_at(d, c.x, c.y)
	_check(u_at.distance_to(Vector2(0.5, 0.5)) < 1e-4, "the art's centre is under the point (uv %s)" % str(u_at))
	var corner := _uv_at(d, c.x + 6.0, c.y + 6.0)
	_check(corner.distance_to(Vector2(1.0, 1.0)) < 1e-4, "the art spans 12 units: (+6, +6) is uv (1, 1)")
	# A corner the terrain cannot answer drops its cells only.
	var holey := func(col: int, row: int) -> float:
		return NAN if col == 7 and row == 12 else _plane(col, row)
	var dh: Dictionary = GroundMarkers.drape_arrays(c, 12.0, holey, 0.05)
	_check((dh["vertices"] as PackedVector3Array).size() == 8 * 6, "a cell with an unknown corner is left out (8 of 9 drawn)")
	var q: Dictionary = GroundMarkers.water_quad_arrays(c, 12.0, 10.1)
	var qv: PackedVector3Array = q["vertices"]
	_check(qv.size() == 6 and qv[0] == Vector3(99, 10.1, 201) and qv[2] == Vector3(111, 10.1, 213), "the still-water quad is 12 x 12 at the given height")
	var b := MapmReader.Block.new()
	b.plane_type = 1
	b.wave_id = 1
	_check(GroundMarkers.block_has_still_water(b), "PlaneType 1 with a WaveID draws the water quad")
	b.wave_id = 0
	_check(not GroundMarkers.block_has_still_water(b), "PlaneType 1 with WaveID 0 does not")
	b.plane_type = 0
	b.wave_id = 2
	_check(not GroundMarkers.block_has_still_water(b), "animated water (PlaneType 0) does not")
	var n1 := Node3D.new()
	root.add_child(n1)
	n1.position = Vector3(10, 0, 0)
	_check(GroundMarkers.npc_blocking(Vector3(25, 0, 0), [n1]) == n1, "an NPC 15 from the click blocks it (under 20)")
	_check(GroundMarkers.npc_blocking(Vector3(30, 0, 0), [n1]) == null, "one exactly 20 away does not (400 is not under 400)")
	n1.scale = Vector3.ZERO
	_check(GroundMarkers.npc_blocking(Vector3(25, 0, 0), [n1]) == null, "an NPC at scale 0 (+0xc4 == 0) does not")
	n1.queue_free()

func _test_floor_rules() -> void:
	if not _GM.has_method("floor_choice"):
		_check(false, "GroundMarkers has the placed-floor branch (floor_choice)")
		return
	var placed := StaticBody3D.new()
	placed.collision_layer = 0b1
	var ground := StaticBody3D.new()
	ground.collision_layer = 0b1001
	_check(GroundMarkers.floor_choice(3.0, {"collider": placed}), "3 above the terrain on a placed object: a floor")
	_check(not GroundMarkers.floor_choice(0.8, {"collider": placed}), "0.8 above (not more than 1): the terrain")
	_check(not GroundMarkers.floor_choice(3.0, {"collider": ground}), "3 above but the ray meets a terrain body: the terrain")
	_check(not GroundMarkers.floor_choice(3.0, {}), "3 above and the short ray meets nothing: the terrain (retail's drape)")
	_check(not GroundMarkers.floor_choice(NAN, {"collider": placed}), "no terrain height known: the terrain path")
	# Round 745: on Karakoram's ice (a .nvm solid plane, round 744) the short ray
	# meets the terrain layer's SolidPlanes 294 over the lakebed: the flat quad only.
	_check(GroundMarkers.plane_choice(294.0, {"collider": ground}), "294 above the height map on a terrain body: the solid plane (flat quad only)")
	_check(not GroundMarkers.plane_choice(294.0, {"collider": placed}), "294 above on a placed object: not the plane branch (the floor branch)")
	_check(not GroundMarkers.plane_choice(0.5, {"collider": ground}), "on the height map itself: the drape")
	_check(not GroundMarkers.plane_choice(294.0, {}), "high above with nothing under the point: not the plane branch")
	placed.free()
	ground.free()
	# A flat floor at 10 over the 10 x 10 grid: 81 cells, 162 triangles at 10.05.
	var flat := func(_i: int, _j: int) -> float: return 10.0
	var d: Dictionary = GroundMarkers.floor_drape_arrays(Vector2i(-3, -3), 10, 2.0, GroundMarkers.floor_heights(Vector2i(-3, -3), 10, flat), 10.0, 0.05)
	var v: PackedVector3Array = d["vertices"]
	var level := true
	for p in v:
		if absf(p.y - 10.05) > 1e-5:
			level = false
	_check(v.size() == 162 * 3 and level, "a flat floor: 162 triangles, every corner at the hit + 0.05 (%d vertices)" % v.size())
	_check(v[0] == Vector3(-6, 10.05, -6), "the grid starts at index * 2 (%s)" % str(v[0]))
	# Samples off the floor's side (a miss) and far below the point drop their
	# triangles only.
	var edge := func(i: int, _j: int) -> float: return NAN if i >= 4 else 10.0
	d = GroundMarkers.floor_drape_arrays(Vector2i(-3, -3), 10, 2.0, GroundMarkers.floor_heights(Vector2i(-3, -3), 10, edge), 10.0, 0.05)
	var max_x := -INF
	for p in d["vertices"]:
		max_x = maxf(max_x, (p as Vector3).x)
	_check((d["vertices"] as PackedVector3Array).size() == 6 * 9 * 2 * 3 and max_x <= 6.0,
		"missed samples (x >= 8) leave out their cells: 6 of 9 columns drawn, nothing past x 6 (max %.1f)" % max_x)
	var drop := func(i: int, _j: int) -> float: return 7.5 if i >= 4 else 10.0
	d = GroundMarkers.floor_drape_arrays(Vector2i(-3, -3), 10, 2.0, GroundMarkers.floor_heights(Vector2i(-3, -3), 10, drop), 10.0, 0.05)
	_check((d["vertices"] as PackedVector3Array).size() == 6 * 9 * 2 * 3, "samples 2.5 below the point (past the 2 drop) are left out the same way")
	# A step of 1.5 inside the drop: both levels drawn, nothing across the step.
	var step := func(i: int, _j: int) -> float: return 8.5 if i >= 4 else 10.0
	d = GroundMarkers.floor_drape_arrays(Vector2i(-3, -3), 10, 2.0, GroundMarkers.floor_heights(Vector2i(-3, -3), 10, step), 10.0, 0.05)
	var sv: PackedVector3Array = d["vertices"]
	var stretched := false
	for t in range(0, sv.size(), 3):
		var hi := maxf(sv[t].y, maxf(sv[t + 1].y, sv[t + 2].y))
		var lo := minf(sv[t].y, minf(sv[t + 1].y, sv[t + 2].y))
		if hi - lo > 1.0:
			stretched = true
	_check(sv.size() == 8 * 9 * 2 * 3 and not stretched, "a 1.5 step: both levels drawn, the 9 cells across it left out, no triangle stretched (%d vertices)" % sv.size())
	_check(GroundMarkers.floor_sample_ok(11.9, 10.0) and not GroundMarkers.floor_sample_ok(12.1, 10.0),
		"a sample above the ray's start (2 over the point) is not on the floor")

func _uv_at(d: Dictionary, x: float, z: float) -> Vector2:
	var v: PackedVector3Array = d["vertices"]
	var uv: PackedVector2Array = d["uvs"]
	for i in range(0, v.size() - 2, 3):
		var a := v[i]
		var b := v[i + 1]
		var c := v[i + 2]
		var den := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(den) < 1e-9:
			continue
		var w0 := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / den
		var w1 := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / den
		var w2 := 1.0 - w0 - w1
		if w0 >= -1e-6 and w1 >= -1e-6 and w2 >= -1e-6:
			return uv[i] * w0 + uv[i + 1] * w1 + uv[i + 2] * w2
	return Vector2(-1, -1)

func _test_states() -> void:
	var at := {"k": Vector3(5, 0, 5)}
	var gm: GroundMarkers = _GM.new()
	gm.setup(null, null, func(_p: String) -> Texture2D: return _tex, func(key: String) -> Variant: return at.get(key))
	root.add_child(gm)
	_check(not gm.shown, "no ring before anything happens")
	gm.place_at(Vector3(10, 2, 30))
	_check(gm.shown and gm.texture_index == 0 and gm.follow_key == "" and gm.center == Vector3(10, 2, 30),
		"a ground click shows texture 0 at the point, following nothing")
	for i in 5:
		gm.step()
	_check(gm.shown and gm.center == Vector3(10, 2, 30), "standing on the point (arrival) keeps the ring there")
	gm.heading_move()
	_check(not gm.shown, "a heading move (the arrow keys' walk, a sky-click run) hides it")
	gm.attach("k", GroundMarkers.Kind.MONSTER)
	_check(gm.shown and gm.texture_index == 3 and gm.follow_key == "k" and gm.center == Vector3(5, 0, 5),
		"selecting a monster shows texture 3 where it stands")
	at["k"] = Vector3(8, 1, 9)
	gm.step()
	_check(gm.center == Vector3(8, 1, 9), "the ring follows the selected object as it moves")
	gm.place_at(Vector3(40, 0, 40))
	_check(gm.texture_index == 0 and gm.follow_key == "" and gm.center == Vector3(40, 0, 40),
		"a ground click with a monster selected moves the ring off it to the point")
	gm.attach("k", GroundMarkers.Kind.PLAYER)
	_check(gm.texture_index == 2, "selecting a player shows texture 2")
	gm.attach("k", GroundMarkers.Kind.NPC)
	_check(gm.texture_index == 1, "selecting an NPC shows texture 1")
	at.erase("k")
	gm.step()
	_check(not gm.shown and gm.follow_key == "", "the followed object gone (or hidden) hides the ring and drops it")
	gm.queue_free()

# --- in the world ----------------------------------------------------------

const MOB := 4711
const OTHER := 5151

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
		"func _exit_tree() -> void:",
		"\tpass",
		"var test_tex: Texture2D = ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))",
		"func _marker_texture(_path: String) -> Texture2D:",
		"\treturn test_tex",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

## A synthetic region "1_1": every block's 17 x 17 vertices on the plane
## h = 0.02 x + 0.01 z + 4 (region-local), block 0 still water when asked.
func _region(still_water: bool) -> MapmReader.ParsedRegion:
	var region := MapmReader.ParsedRegion.new()
	for row in 6:
		for col in 6:
			var block := MapmReader.Block.new()
			block.plane_type = -1
			for r in 17:
				for c in 17:
					var vert := MapmReader.Vertex.new()
					var x := (col * 16 + c) * 20.0
					var z := (row * 16 + r) * 20.0
					vert.height = 0.02 * x + 0.01 * z + 4.0
					block.vertices.append(vert)
			region.blocks.append(block)
	if still_water:
		region.blocks[0].plane_type = 1
		region.blocks[0].wave_id = 1
	return region

func _test_world() -> void:
	var world := _make_world()
	if world == null:
		return
	var grid: RegionGridState = world.get("_grid")
	grid.parsed_heightmaps["1_1"] = _region(true)
	# The terrain group as World3D builds one: mirrored on z (scale.z = -1).
	var group := Node3D.new()
	group.name = "RealTerrain_1_1"
	group.position = Vector3(1920.0, 0.0, 0.0)
	group.scale = Vector3(1, 1, -1)
	world.add_child(group)
	# A floor the pick ray can hit, on the terrain layer.
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = world.get("TERRAIN_COLLISION_LAYER")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(2000, -1, -1000)
	world.add_child(floor_body)
	var player: CharacterBody3D = world.get("player")
	player.global_position = Vector3(2000, 0, -100)
	await physics_frame
	await physics_frame
	var space: PhysicsDirectSpaceState3D = (world as Node3D).get_world_3d().direct_space_state

	# A ground click 30 ahead: the ring at the hit point, draped on the region.
	var took: String = world.call("_move_by_pick_ray", Vector3(2000, 50, -130), Vector3(0, -1, 0), space)
	var gm: GroundMarkers = world.get("_ground_markers")
	_check(gm != null, "a ground click made the ring")
	if gm == null:
		world.queue_free()
		return
	_check(took == "walk" and gm.shown and gm.texture_index == 0 and gm.center.distance_to(Vector3(2000, 0, -130)) < 0.01,
		"a ground click shows texture 0 at the hit point (took %s, centre %s)" % [took, str(gm.center)])
	gm.step()
	var drape: Dictionary = gm.last_drape
	_check(not drape.is_empty() and drape["group"] == group, "the ring is draped in the region under the point")
	if not drape.is_empty():
		var local: Vector3 = drape["local"]
		_check(local.distance_to(Vector3(80, 0, 130)) < 0.01, "region-local (80, 130) under world (2000, -130) (got %s)" % str(local))
		var dh := GroundMarkers.drape_height_at(drape["arrays"], local.x, local.z)
		var ground := 0.02 * local.x + 0.01 * local.z + 4.0
		_check(absf(dh - (ground + GroundMarkers.DRAPE_LIFT)) < 1e-3, "the drape there is the region's ground + 0.05 (%.3f vs %.3f)" % [dh, ground])
		var nverts := (drape["arrays"]["vertices"] as PackedVector3Array).size()
		_check(nverts == 54, "nine cells drawn (%d vertices)" % nverts)
		_check(drape["water"] == true, "block 0 is still water: the flat quad is drawn too")
	var ring := gm.get_node_or_null("Ring") as MeshInstance3D
	_check(ring != null and ring.visible and ring.mesh != null, "the ring's mesh is drawn")
	var mat := ring.material_override as ShaderMaterial
	_check(mat != null and (mat.get_shader_parameter("origin") as Vector2).distance_to(Vector2(74, 124)) < 0.01,
		"the art's origin is the point's local (80, 130) less 6 (got %s)" % (str(mat.get_shader_parameter("origin")) if mat != null else "no material"))
	_check(ring.global_transform.is_equal_approx(group.global_transform), "the mesh is drawn in the region's own frame")
	_check(gm.cached_regions() == 1, "one region's heights are cached")
	# A click under the 5-unit filter with no order in effect still moves it.
	world.set("_player_move_order", false)
	player.global_position = Vector3(2000, 0, -100)
	took = world.call("_move_by_pick_ray", Vector3(2002, 50, -101), Vector3(0, -1, 0), space)
	_check(took == "ignore" and gm.center.distance_to(Vector3(2002, 0, -101)) < 0.01,
		"a click the filter ignores still moves the ring (READ: no branch before FUN_00a631e0) (took %s)" % took)
	# Moving inside the window keeps the mesh; crossing a cell edge rebuilds it.
	gm.step()
	var mesh_before: Mesh = ring.mesh
	gm.place_at(Vector3(2003, 0, -103))
	gm.step()
	_check(ring.mesh == mesh_before, "a point 3 units on, in the same cell window, keeps the mesh")
	gm.place_at(Vector3(2030, 0, -103))
	gm.step()
	_check(ring.mesh != mesh_before, "a point in the next cell builds a new window")
	# An NPC 10 units from the click: nothing walks, the ring stays where it was.
	var npc := Node3D.new()
	npc.set_meta("npc_name", "Clerk")
	group.add_child(npc)
	npc.global_position = Vector3(2010, 0, -150)
	var ring_was := gm.center
	took = world.call("_move_by_pick_ray", Vector3(2010, 50, -160), Vector3(0, -1, 0), space)
	_check(took == "npc_near" and gm.center == ring_was, "a click 10 from an NPC neither walks nor moves the ring (took %s)" % took)
	took = world.call("_move_by_pick_ray", Vector3(2010, 50, -175), Vector3(0, -1, 0), space)
	_check(took == "walk" and gm.center.distance_to(Vector3(2010, 0, -175)) < 0.01, "a click 25 from it walks (took %s)" % took)
	npc.set_meta("gate_point_id", 7)
	took = world.call("_move_by_pick_ray", Vector3(2010, 50, -155), Vector3(0, -1, 0), space)
	_check(took != "npc_near", "a teleport gate (not a CICNPC) does not block (took %s)" % took)
	npc.queue_free()
	await process_frame
	# A sky click: a heading run hides the ring.
	took = world.call("_move_by_pick_ray", Vector3(2000, 50, -100), Vector3(0, 1, 0), space)
	_check(took == "run" and not gm.shown, "a sky click's heading run hides the ring (took %s)" % took)

	# A monster selected: texture 3 under it.
	var mob := Node3D.new()
	world.add_child(mob)
	mob.global_position = Vector3(2010, 0, -120)
	(world.get("_monster_bodies") as Dictionary)[MOB] = mob
	world.call("_show_target", MOB)
	world.call("_ring_on_monster", MOB)
	gm.step()
	_check(gm.shown and gm.texture_index == 3 and gm.follow_key == "monster:%d" % MOB and gm.center == mob.global_position,
		"clicking a monster puts texture 3 under it")
	# A ground click moves the ring off it; a cast at the still-selected
	# monster re-shows the target window (_show_target) but does not reselect.
	took = world.call("_move_by_pick_ray", Vector3(2005, 50, -140), Vector3(0, -1, 0), space)
	world.call("_show_target", MOB)
	gm.step()
	_check(gm.follow_key == "" and gm.texture_index == 0, "a cast's _show_target leaves a ring the ground click moved")
	world.call("_ring_on_monster", MOB)
	gm.step()
	world.call("_clear_target")
	gm.step()
	_check(gm.shown and gm.follow_key == "monster:%d" % MOB, "deselecting leaves the ring under it (READ: FUN_00778650(0) clears the id only)")
	mob.visible = false
	gm.step()
	_check(not gm.shown, "the monster hidden (vslot 0x50 says no) hides the ring")
	mob.visible = true
	world.call("_ring_on_monster", MOB)
	(world.get("_monster_bodies") as Dictionary).erase(MOB)
	mob.queue_free()
	await process_frame
	gm.step()
	_check(not gm.shown, "the monster's body going (a despawn) hides the ring on the next step")

	# Another player: texture 2; yourself: no ring.
	var other := Node3D.new()
	world.add_child(other)
	other.global_position = Vector3(1990, 0, -90)
	(world.get("_other_bodies") as Dictionary)[OTHER] = other
	world.call("_select_character", OTHER, "Bram")
	gm.step()
	_check(gm.shown and gm.texture_index == 2 and gm.center == other.global_position, "selecting a player puts texture 2 under them")
	gm.hide_marker("test")
	world.call("_select_self")
	_check(not gm.shown, "selecting yourself shows no ring (READ: FUN_00780ee0 writes the id only)")

	# The cache does not keep a pruned region alive.
	grid.parsed_heightmaps["1_1"] = _region(false)
	var held: WeakRef = weakref(grid.parsed_heightmaps["1_1"])
	gm.place_at(Vector3(2000, 0, -130))
	gm.step()
	_check(gm.cached_regions() == 1, "the re-parsed region's heights are cached")
	grid.parsed_heightmaps.erase("1_1")
	gm.step()
	_check(gm.cached_regions() == 0, "a region pruned from the grid leaves the cache")
	_check(held.get_ref() == null, "and the pruned ParsedRegion is freed (nothing else holds it)")
	grid.parsed_heightmaps["1_1"] = _region(false)
	await _test_world_floor(world, group, space)
	# A zone change hides it.
	world.call("_select_character", OTHER, "Bram")
	world.call("_reload_zone_assets", "")
	_check(not gm.shown and gm.cached_regions() == 0, "a zone change hides the ring and forgets the heights")
	world.queue_free()
	await process_frame

func _box(world: Node, layer: int, size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	world.add_child(body)
	return body

## Round 701: a deck (layer 1) 5 above the synthetic terrain, a roof 4 over
## it, a lower step beside it.
func _test_world_floor(world: Node, group: Node3D, space: PhysicsDirectSpaceState3D) -> void:
	if not _GM.has_method("floor_choice"):
		_check(false, "the world test has the placed-floor branch")
		return
	var gm: GroundMarkers = world.get("_ground_markers")
	# World (2100, -300) is region-local (180, 300): terrain 0.02 * 180 + 0.01 * 300 + 4 = 10.6.
	var terrain := 10.6
	var top := terrain + 5.0
	var deck := _box(world, 0b1, Vector3(10, 1, 10), Vector3(2100, top - 0.5, -300))
	var roof := _box(world, 0b1, Vector3(30, 1, 30), Vector3(2100, top + 4.5, -300))
	await physics_frame
	await physics_frame
	var took: String = world.call("_move_by_pick_ray", Vector3(2100, top + 3.0, -300), Vector3(0, -1, 0), space)
	_check(took == "walk" and absf(gm.center.y - top) < 0.01, "a click under the roof lands on the deck (took %s, y %.2f)" % [took, gm.center.y])
	gm.step()
	var drape: Dictionary = gm.last_drape
	_check(gm.on_floor and bool(drape.get("floor", false)), "the point 5 above the terrain on a placed object takes the floor drape")
	var arrays: Dictionary = drape.get("arrays", {})
	var local: Vector3 = drape.get("local", Vector3.ZERO)
	var verts: PackedVector3Array = arrays.get("vertices", PackedVector3Array())
	var dh := GroundMarkers.drape_height_at(arrays, local.x, local.z)
	_check(absf(dh - (top + GroundMarkers.DRAPE_LIFT)) < 1e-3, "the drape at the centre is the deck + 0.05 (%.3f, deck %.2f)" % [dh, top])
	var on_deck := true
	var inside := true
	for p in verts:
		if absf(p.y - (top + GroundMarkers.DRAPE_LIFT)) > 1e-3:
			on_deck = false
		if absf(p.x - 180.0) > 5.01 or absf(p.z - 300.0) > 5.01:
			inside = false
	_check(verts.size() > 0 and on_deck, "every corner is on the deck, none on the roof 4 above (%d vertices)" % verts.size())
	_check(inside, "nothing past the deck's sides: every corner within its 10 x 10")
	_check(is_nan(GroundMarkers.drape_height_at(arrays, local.x + 5.5, local.z)) and not is_nan(GroundMarkers.drape_height_at(arrays, local.x + 3.5, local.z)),
		"the art's edge: drawn 3.5 out on the deck, nothing 5.5 out past its side")
	var ring := gm.get_node("Ring") as MeshInstance3D
	_check(ring.visible and ring.global_transform.is_equal_approx(group.global_transform)
		and ((ring.material_override as ShaderMaterial).get_shader_parameter("origin") as Vector2).distance_to(Vector2(local.x, local.z) - Vector2(6, 6)) < 1e-3,
		"the floor ring is drawn in the region's frame with the same shader origin")
	# Inside the same 6-unit cell: the same mesh. The next cell: a new one, the
	# overlapping samples reused.
	var mesh_before: Mesh = ring.mesh
	var rays_before: int = gm.floor_rays
	gm.place_at(gm.center + Vector3(0.5, 0, -0.5))
	gm.step()
	_check(ring.mesh == mesh_before and gm.floor_rays == rays_before, "a point 0.7 on in the same 6-unit cell keeps the mesh and fires no ray")
	gm.place_at(Vector3(2099.5, top, -300))
	gm.step()
	_check(ring.mesh != mesh_before and gm.floor_rays - rays_before <= 30,
		"the next cell builds a new mesh with %d new rays (the other 70 samples reused)" % (gm.floor_rays - rays_before))
	# A lower step beside the deck, 1.5 down: drawn on its own, nothing across.
	var low := _box(world, 0b1, Vector3(10, 1, 10), Vector3(2110, top - 2.0, -300))
	await physics_frame
	gm.zone_changed()
	gm.place_at(Vector3(2103.0, top, -300))
	gm.step()
	var sv: PackedVector3Array = (gm.last_drape["arrays"] as Dictionary)["vertices"]
	var stretched := false
	var lower := false
	for t in range(0, sv.size(), 3):
		var hi := maxf(sv[t].y, maxf(sv[t + 1].y, sv[t + 2].y))
		var lo := minf(sv[t].y, minf(sv[t + 1].y, sv[t + 2].y))
		stretched = stretched or hi - lo > GroundMarkers.FLOOR_MAX_RISE + 1e-4
		lower = lower or absf(hi - (top - 1.5 + GroundMarkers.DRAPE_LIFT)) < 1e-3
	_check(not stretched and lower, "a step 1.5 down beside the deck: drawn on it too, no triangle down the deck's side")
	low.free()
	# A click on the ground beside the deck: the terrain drape, unchanged.
	took = world.call("_move_by_pick_ray", Vector3(2130, 50, -300), Vector3(0, -1, 0), space)
	gm.step()
	_check(not gm.on_floor and not bool(gm.last_drape.get("floor", true)) and (gm.last_drape["arrays"]["vertices"] as PackedVector3Array).size() == 54,
		"a click on the terrain floor box (layer 0b1001) beside it keeps retail's terrain drape")
	# An NPC standing on the deck: its ring on the deck.
	var npc := Node3D.new()
	npc.set_meta("npc_name", "Deckhand")
	group.add_child(npc)
	npc.global_position = Vector3(2101, top, -301)
	gm.attach("npc:%d" % npc.get_instance_id(), GroundMarkers.Kind.NPC, npc.global_position)
	gm.step()
	_check(gm.on_floor and absf(GroundMarkers.drape_height_at(gm.last_drape["arrays"], (gm.last_drape["local"] as Vector3).x, (gm.last_drape["local"] as Vector3).z) - (top + 0.05)) < 1e-3,
		"an NPC selected on the deck gets the ring on the deck")
	npc.queue_free()
	# Round 701's review: objects streaming in drop the samples (L7) ...
	gm.place_at(Vector3(2100, top, -300))
	gm.step()
	var rays_then: int = gm.floor_rays
	gm.step()
	_check(gm.floor_rays == rays_then, "a still point fires no ray")
	gm.objects_changed()
	gm.step()
	_check(gm.floor_rays > rays_then and gm.on_floor, "objects streaming in re-sample the floor (%d new rays)" % (gm.floor_rays - rays_then))
	for i in 3:
		gm.step()
	deck.free()
	roof.free()
	# ... and a floor whose every triangle is rejected falls back to the
	# terrain drape: a 1 x 1 post top between the 2-unit samples.
	var post := _box(world, 0b1, Vector3(1, 1, 1), Vector3(2101, top - 0.5, -301))
	await physics_frame
	await physics_frame
	gm.zone_changed()
	gm.place_at(Vector3(2101, top, -301))
	gm.step()
	_check(not gm.on_floor and (gm.last_drape["arrays"]["vertices"] as PackedVector3Array).size() == 54,
		"a floor with no triangle left falls back to the terrain drape (54 vertices)")
	post.free()
	gm.hide_marker("test")
