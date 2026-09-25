extends SceneTree

## A monster body -- or a ground item -- whose height ray found no ground when
## it was placed keeps trying until the ground commits (round 572, the
## user's "Mangyangs are now floating"). Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## The world is World3D.tscn itself, with the script swapped for a subclass
## whose _ready, _physics_process and input callbacks do nothing: the scene's
## nodes answer every @onready path, and the World3D is in the tree, so its
## own terrain ray fires in the test tree's physics space. Nothing opens an
## archive or the network. The scene's stand-in floors are left as the scene
## has them -- the placeholder Ground (layer 9, a 200 x 1 x 200 box at the
## origin, top at y 0.5) on, as it is until the first terrain commit, and
## VoidCatchFloor (top at y -1995) -- so the world starts with no TERRAIN,
## a region whose collision has not committed yet. The ground that "commits"
## is a plain box on World3D's TERRAIN_COLLISION_LAYER, its top at y -50, for
## the retry; and, for the heightfield's grid lines, a real region's
## HeightMapShape3D placed where World3D places the frame origin's region
## (TerrainCollision.place_group).
##
## NEGATIVES: before round 572 a body placed with no ground under it stayed at
## the server's y for good -- nothing but another monster list re-rayed a
## standing body (_step_monster_bodies returned at once with no leg to walk)
## -- and a ground item took NAN from a ray that had no answer. Before round
## 572's second pass: a body listed over the placeholder was placed on it
## (0.898) and never waited; a body on a heightfield grid vertex where the
## plain vertical ray misses waited for ever; and 32 monster bodies that
## could never resolve left the ground items no retries at all.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## World3D.gd names the NetClient autoload, which a --script suite registers
## only after _init (monster_motion_test.gd's pattern).
func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	# The root enters the tree only after _initialize returns.
	await process_frame
	var world := _make_world()
	if world != null:
		await _test_monster_heights(world)
		await _test_budget(world)
		await _test_stand_in_floors(world)
		await _test_grid_vertices(world)
		await _test_fair_share(world)
		root.remove_child(world)
		world.free()
	_test_ground_items()
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
	_check(scene != null, "World3D.tscn loads")
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	# The species tables are never read: every body is the labelled capsule.
	world.set("_monster_models_loaded", true)
	root.add_child(world)
	return world

func _snapshot(id: int, x: float, y: float, z: float) -> CombatNet.MonsterSnapshot:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = id
	snap.monster_name = "Fixture"
	snap.x = x
	snap.y = y
	snap.z = z
	snap.hp = 10
	snap.max_hp = 10
	return snap

## A flat slab on the terrain layer, its top at `top`, under the whole fixture.
func _ground(layer: int, top: float) -> StaticBody3D:
	var shape := BoxShape3D.new()
	shape.size = Vector3(4000.0, 2.0, 4000.0)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var sb := StaticBody3D.new()
	sb.collision_layer = layer
	sb.collision_mask = 0
	sb.add_child(cs)
	sb.position = Vector3(0.0, top - 1.0, 0.0)
	return sb

func _pending(world: Node) -> Dictionary:
	var p = world.get("_monster_heights_pending")
	return p if p is Dictionary else {}

func _test_monster_heights(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var layer: int = consts["TERRAIN_COLLISION_LAYER"]
	var lift: float = 0.05 * float(consts["PLAYER_SCALE_RATIO"])
	var bodies: Dictionary = world.get("_monster_bodies")
	await physics_frame

	# Two monsters listed with no ground under them, at the server's y 0.
	world.call("_spawn_or_update_monster", _snapshot(7, 100.0, 0.0, 200.0))
	world.call("_spawn_or_update_monster", _snapshot(8, -100.0, 0.0, 200.0))
	var b7: Node3D = bodies.get(7)
	_check(b7 != null and b7.position.y == 0.0, "a monster listed with no ground under it is drawn at the server's y 0 for now")
	_check(_pending(world).has(7) and _pending(world).has(8), "and both such bodies wait for ground (got %s)" % str(_pending(world).keys()))

	# The next list drops 8 and re-lists 7, still with no ground.
	world.call("_sync_monster_bodies", [_snapshot(7, 100.0, 0.0, 200.0)])
	_check(not bodies.has(8) and not _pending(world).has(8), "a body removed while it waits leaves the wait list too")
	_check(_pending(world).has(7) and b7.position.y == 0.0, "a standing refresh with still no ground keeps it waiting at y 0")

	# A step with no ground: still waiting.
	await physics_frame
	world.call("_step_monster_bodies", 1.0 / 60.0)
	_check(_pending(world).has(7) and b7.position.y == 0.0, "a retry that finds no ground leaves the body where it is, still waiting")

	# The ground commits.
	var ground := _ground(layer, -50.0)
	root.add_child(ground)
	var q := PhysicsRayQueryParameters3D.create(Vector3(100.0, 1000.0, 200.0), Vector3(100.0, -1000.0, 200.0))
	q.collision_mask = consts["TERRAIN_ONLY_COLLISION_MASK"]
	var same_frame := root.get_world_3d().direct_space_state.intersect_ray(q)
	print("info: the terrain ray in the frame the ground body was added %s" % [
		"hits at y %.2f" % same_frame.position.y if not same_frame.is_empty() else "finds nothing"])
	await physics_frame
	var spent = world.call("_step_monster_bodies", 1.0 / 60.0)
	_check(absf(b7.position.y - (-50.0 + lift)) < 0.001,
		"one physics frame after the ground is added the waiting body stands on it, at -50 + the lift %.3f (got y %.3f)" % [lift, b7.position.y])
	_check(not _pending(world).has(7), "and no longer waits")
	_check(spent is int and spent == 1, "that retry was one ray of the frame's budget (got %s)" % str(spent))

	# Listed after the ground is there: placed at once, never waiting.
	world.call("_spawn_or_update_monster", _snapshot(9, 0.0, 0.0, 300.0))
	var b9: Node3D = bodies.get(9)
	_check(b9 != null and absf(b9.position.y - (-50.0 + lift)) < 0.001 and not _pending(world).has(9),
		"a body whose ray hits when it is listed is placed on the ground and never waits")

	# A body with a leg, waiting: the leg's own rule (navmesh first -- none is
	# loaded here -- then the terrain ray) resolves it.
	ground.collision_layer = 0
	await physics_frame
	world.call("_spawn_or_update_monster", _snapshot(10, 50.0, 0.0, 250.0))
	var b10: Node3D = bodies.get(10)
	(world.get("_monster_motion") as Dictionary)[10] = {"pos": Vector2(50.0, 250.0), "dest": Vector2(50.0, 250.0),
		"speed": 8.0, "mode": 0, "moving": false, "stop": false, "h_xz": Vector2(50.0, 250.0), "log_frames": 0}
	_check(_pending(world).has(10) and b10.position.y == 0.0, "a body listed while the ground is gone again waits")
	ground.collision_layer = layer
	await physics_frame
	world.call("_step_monster_bodies", 1.0 / 60.0)
	_check(absf(b10.position.y - (-50.0 + lift)) < 0.001 and not _pending(world).has(10),
		"a waiting body with a leg entry is resolved by the step's own rule once the ground is there (got y %.3f)" % b10.position.y)

	for id in [7, 9, 10]:
		(bodies[id] as Node).free()
		bodies.erase(id)
	(world.get("_monster_motion") as Dictionary).clear()
	root.remove_child(ground)
	ground.free()

## More bodies waiting than MonsterMotion.MAX_HEIGHT_RESOLVES_PER_FRAME: the
## retry takes the budget, not a second loop of its own, and the rest go the
## next frame.
func _test_budget(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var budget: int = MonsterMotion.MAX_HEIGHT_RESOLVES_PER_FRAME
	var bodies: Dictionary = world.get("_monster_bodies")
	var n := budget + 8
	await physics_frame
	for i in range(n):
		world.call("_spawn_or_update_monster", _snapshot(100 + i, float(i) * 3.0, 0.0, -400.0))
	_check(_pending(world).size() == n, "%d bodies listed with no ground all wait (got %d)" % [n, _pending(world).size()])
	var ground := _ground(consts["TERRAIN_COLLISION_LAYER"], -50.0)
	root.add_child(ground)
	await physics_frame
	var spent = world.call("_step_monster_bodies", 1.0 / 60.0)
	_check(spent is int and spent == budget and _pending(world).size() == n - budget,
		"one frame resolves %d, the budget, and leaves %d (spent %s, left %d)" % [budget, n - budget, str(spent), _pending(world).size()])
	await physics_frame
	world.call("_step_monster_bodies", 1.0 / 60.0)
	_check(_pending(world).is_empty(), "the next frame resolves the rest (left %d)" % _pending(world).size())
	var floating := 0
	for i in range(n):
		if (bodies[100 + i] as Node3D).position.y >= 0.0:
			floating += 1
	_check(floating == 0, "no body is left at the server's y (%d are)" % floating)
	for i in range(n):
		(bodies[100 + i] as Node).free()
		bodies.erase(100 + i)
	root.remove_child(ground)
	ground.free()

## Every monster body dropped the way the next list drops them, and the
## frees flushed.
func _clear_bodies(world: Node) -> void:
	world.call("_sync_monster_bodies", [])
	await process_frame

## The scene's stand-in floors are not ground (round 572's second pass): the
## placeholder answered the terrain-only ray until the first terrain commit
## switched it off, so a body listed within 100 of the origin on the
## loading-screen path was placed on it for good.
func _test_stand_in_floors(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var lift: float = 0.05 * float(consts["PLAYER_SCALE_RATIO"])
	var bodies: Dictionary = world.get("_monster_bodies")
	await physics_frame
	var placeholder := world.get_node_or_null("Ground/Collision") as CollisionShape3D
	_check(placeholder != null and not placeholder.disabled and (world.get_node("Ground") as StaticBody3D).collision_layer == 9,
		"the scene's placeholder Ground is on, on layer 9, as it is until the first terrain commit")
	# What it answered: a plain terrain-only ray over it stops on its top.
	var space := root.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(50.0, 1000.0, 50.0), Vector3(50.0, -1000.0, 50.0))
	q.collision_mask = consts["TERRAIN_ONLY_COLLISION_MASK"]
	var plain := space.intersect_ray(q)
	_check(not plain.is_empty() and absf((plain.position as Vector3).y - 0.5) < 0.001,
		"NEGATIVE: a plain terrain-only ray at (50, 50) stops on the placeholder's top, y 0.5 (%s)" % [
			"none" if plain.is_empty() else "%.3f" % (plain.position as Vector3).y])
	var at_placeholder = world.call("_terrain_hit_height", Vector3(50.0, 0.0, 50.0))
	_check(at_placeholder is float and is_nan(at_placeholder),
		"_terrain_hit_height passes through it: no terrain at (50, 50) yet (got %s)" % str(at_placeholder))
	world.call("_spawn_or_update_monster", _snapshot(20, 50.0, 0.0, 50.0))
	world.call("_spawn_or_update_monster", _snapshot(21, -90.0, 0.0, 90.0))
	var b20: Node3D = bodies.get(20)
	var b21: Node3D = bodies.get(21)
	_check(b20 != null and b20.position.y == 0.0 and b21 != null and b21.position.y == 0.0,
		"monsters listed over the placeholder before any terrain are drawn at the server's y 0, not on it at 0.5 + the lift (got %s, %s)" % [
			"?" if b20 == null else "%.3f" % b20.position.y, "?" if b21 == null else "%.3f" % b21.position.y])
	_check(_pending(world).has(20) and _pending(world).has(21), "and both wait for ground")
	# The void catch: a monster listed at y -1500 is rayed from -500 down to
	# -2500, through VoidCatchFloor's top at -1995.
	world.call("_spawn_or_update_monster", _snapshot(22, 500.0, -1500.0, 500.0))
	var b22: Node3D = bodies.get(22)
	_check(b22 != null and b22.position.y == -1500.0 and _pending(world).has(22),
		"a monster listed at y -1500 is not placed on the void catch's top at -1995: it waits at -1500 (got %s)" % [
			"?" if b22 == null else "%.2f" % b22.position.y])
	# The terrain commits under the placeholder, which is still on.
	var ground := _ground(consts["TERRAIN_COLLISION_LAYER"], -50.0)
	root.add_child(ground)
	await physics_frame
	world.call("_step_monster_bodies", 1.0 / 60.0)
	_check(absf(b20.position.y - (-50.0 + lift)) < 0.001 and absf(b21.position.y - (-50.0 + lift)) < 0.001,
		"when terrain appears under them they resolve onto it, the placeholder above it passed through (got %.3f, %.3f)" % [
			b20.position.y, b21.position.y])
	_check(not _pending(world).has(20) and not _pending(world).has(21), "and no longer wait")
	await _clear_bodies(world)
	_check(_pending(world).is_empty(), "the next list's drop empties the wait list (left %d)" % _pending(world).size())
	root.remove_child(ground)
	ground.free()

## A real region's heightfield where World3D puts the frame origin's region
## (TerrainCollision.place_group at offset 0), on the terrain layer, and the
## scene's placeholder switched off as _terrain_commit switches it: bodies,
## the player's snap and a ground item at grid vertices where the PLAIN
## vertical ray finds nothing (the NEGATIVE, checked here for each column
## used) all land on the ground through TerrainCollision.vertical_ray.
func _test_grid_vertices(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var lift: float = 0.05 * float(consts["PLAYER_SCALE_RATIO"])
	var mask: int = consts["TERRAIN_ONLY_COLLISION_MASK"]
	var side: int = TerrainCollision.SIDE
	var tile: float = MapmTerrainBuilder.TILE_SIZE
	var group := Node3D.new()
	TerrainCollision.place_group(group, Vector3.ZERO, 30.0)
	root.add_child(group)
	var heights := PackedFloat32Array()
	heights.resize(side * side)
	for z in range(side):
		for x in range(side):
			heights[z * side + x] = 6.0 * sin(float(z) * 0.3) * cos(float(x) * 0.2)
	var body := StaticBody3D.new()
	body.collision_layer = consts["TERRAIN_COLLISION_LAYER"]
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = TerrainCollision.make_shape(heights)
	cs.transform = TerrainCollision.shape_transform()
	body.add_child(cs)
	group.add_child(body)
	var placeholder := world.get_node("Ground/Collision") as CollisionShape3D
	placeholder.disabled = true
	await physics_frame
	await physics_frame
	var space := root.get_world_3d().direct_space_state
	# Vertices outside the placeholder's footprint where the plain ray misses.
	var columns: Array = []
	for r in range(10, side - 10, 3):
		for c in range(10, side - 10, 3):
			if columns.size() >= 6:
				break
			var w := group.to_global(Vector3(float(c) * tile, heights[(side - 1 - r) * side + c], float(r) * tile))
			if absf(w.x) < 150.0 and absf(w.z) < 150.0:
				continue
			var q := PhysicsRayQueryParameters3D.create(Vector3(w.x, 1000.0, w.z), Vector3(w.x, -1000.0, w.z))
			q.collision_mask = mask
			if space.intersect_ray(q).is_empty():
				columns.append(w)
	_check(columns.size() == 6, "NEGATIVE: 6 grid vertices of the frame origin's region where the plain vertical ray finds nothing (found %d)" % columns.size())
	var bodies: Dictionary = world.get("_monster_bodies")
	var placed := 0
	var worst := 0.0
	for k in range(columns.size()):
		var w: Vector3 = columns[k]
		world.call("_spawn_or_update_monster", _snapshot(40 + k, w.x, 0.0, w.z))
		var b: Node3D = bodies.get(40 + k)
		if b != null and not _pending(world).has(40 + k):
			placed += 1
			worst = maxf(worst, absf(b.position.y - (w.y + lift)))
	# The vertex's height against the one the helper read 0.01 off it: this
	# field's steepest triangle rises well under 1 a unit.
	_check(placed == columns.size() and worst < 0.02,
		"monsters listed on those vertices are placed at once, at the vertex's height + the lift (%d of %d, worst %.4f off)" % [
			placed, columns.size(), worst])
	# The player's snap (lift only): from 20 under the first vertex.
	var player := world.get("player") as CharacterBody3D
	var w0: Vector3 = columns[0]
	var before := player.position
	player.position = Vector3(w0.x, w0.y - 20.0, w0.z)
	world.call("_snap_player_onto_terrain")
	_check(absf(player.position.y - (w0.y + lift)) < 0.02,
		"the player's snap on such a vertex lifts the player onto the ground (y %.3f, the vertex %.3f + the lift)" % [player.position.y, w0.y])
	player.position = before
	player.velocity = Vector3.ZERO
	# A ground item on one, through World3D's own height function (which
	# lifts an item as it lifts a body).
	var items := GroundItems.new()
	items.setup(null, {}, Callable(), Callable(), Callable(world, "_terrain_hit_height"))
	var w1: Vector3 = columns[1]
	items.spawn(_item(9, w1.x, 0.0, w1.z))
	var item_y := (items.get_node("GroundItem_9") as Node3D).position.y
	_check(not items.is_pending(9) and absf(item_y - (w1.y + lift)) < 0.02,
		"a ground item on such a vertex is placed at once, on the ground (y %.3f, the vertex %.3f + the lift)" % [item_y, w1.y])
	items.free()
	await _clear_bodies(world)
	placeholder.disabled = false
	root.remove_child(group)
	group.free()

## Ground items and monster bodies share the frame's budget
## (World3D._step_heights, MonsterMotion.monster_height_share): 40 monster
## bodies that can never resolve (no ground within their ray) no longer take
## every retry from the ground items. Before round 572's second pass the items
## got what the monsters left -- 32 - 32 = 0 -- here.
func _test_fair_share(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var budget: int = MonsterMotion.MAX_HEIGHT_RESOLVES_PER_FRAME
	await physics_frame
	for i in range(40):
		world.call("_spawn_or_update_monster", _snapshot(200 + i, 100000.0 + float(i) * 3.0, 0.0, 0.0))
	_check(_pending(world).size() == 40, "40 bodies with no ground within their ray all wait (%d)" % _pending(world).size())
	var items := GroundItems.new()
	items.setup(null, {}, Callable(), Callable(), Callable(world, "_terrain_hit_height"))
	for i in range(3):
		items.spawn(_item(300 + i, 500.0 + float(i) * 7.0, 0.0, 500.0))
	_check(items.pending_count() == 3, "3 ground items listed before the ground wait (%d)" % items.pending_count())
	world.set("_ground_items", items)
	var ground := _ground(consts["TERRAIN_COLLISION_LAYER"], -50.0)
	root.add_child(ground)
	await physics_frame
	var retries_before: int = world.get("_mob_height_retries")
	var resolves_before: int = world.get("_mob_height_resolves")
	world.call("_step_heights", 1.0 / 60.0)
	_check(items.pending_count() == 0,
		"one frame: the 3 items all come down though 40 monster bodies wait for ever (left %d)" % items.pending_count())
	var retried: int = int(world.get("_mob_height_retries")) - retries_before
	_check(retried == budget - 3, "and the monsters took the rest of the budget, %d retries (got %d)" % [budget - 3, retried])
	_check(int(world.get("_mob_height_resolves")) == resolves_before,
		"the retries are counted apart from the walking resolves (resolves +%d)" % [int(world.get("_mob_height_resolves")) - resolves_before])
	# Many items waiting as well: an even split.
	for i in range(20):
		items.spawn(_item(400 + i, 600.0 + float(i) * 7.0, 0.0, 99000.0))
	_check(items.pending_count() == 20, "20 more items with no ground under them wait (%d)" % items.pending_count())
	retries_before = world.get("_mob_height_retries")
	world.call("_step_heights", 1.0 / 60.0)
	retried = int(world.get("_mob_height_retries")) - retries_before
	_check(retried == budget / 2, "both queues wanting more than half: the monsters take half the budget (%d, got %d)" % [budget / 2, retried])
	world.set("_ground_items", null)
	items.free()
	await _clear_bodies(world)
	root.remove_child(ground)
	ground.free()

func _item(id: int, x: float, y: float, z: float) -> GroundItemsNet.Snapshot:
	var snap := GroundItemsNet.Snapshot.new()
	snap.id = id
	snap.item_id = 1
	snap.quantity = 1
	snap.x = x
	snap.y = y
	snap.z = z
	return snap

## GroundItems takes World3D._terrain_hit_height; here a stand-in that has no
## answer until `ground` is set.
func _test_ground_items() -> void:
	var items := GroundItems.new()
	var ground := {"at": NAN}
	items.setup(null, {}, Callable(), Callable(), func(_pos: Vector3) -> float: return float(ground["at"]))
	items.spawn(_item(1, 10.0, 0.0, 10.0))
	items.spawn(_item(2, 20.0, 0.0, 10.0))
	items.spawn(_item(3, 30.0, 0.0, 10.0))
	var y1 := (items.get_node("GroundItem_1") as Node3D).position.y
	_check(y1 == 0.0, "a ground item with no ground under it is drawn at the server's y 0, not NAN (got %s)" % str(y1))
	var has_retry := items.has_method("resolve_pending") and items.has_method("pending_count")
	_check(has_retry, "GroundItems has a retry for items with no ground under them")
	if not has_retry:
		items.free()
		return
	_check(items.pending_count() == 3, "all three wait (got %d)" % items.pending_count())
	items.remove(3)
	_check(items.pending_count() == 2 and not items.is_pending(3), "an item removed while it waits leaves the wait list")
	_check(items.resolve_pending(8) == 2 and items.pending_count() == 2, "a retry with no ground fires once per item and they keep waiting")
	ground["at"] = -50.0
	_check(items.resolve_pending(1) == 1 and items.pending_count() == 1, "a budget of 1 resolves one item a frame")
	_check(items.resolve_pending(1) == 1 and items.pending_count() == 0, "and the other the next")
	for id in [1, 2]:
		var y := (items.get_node("GroundItem_%d" % id) as Node3D).position.y
		_check(y == -50.0, "item %d stands on the ground at -50 (got %.2f)" % [id, y])
	items.spawn(_item(4, 40.0, 0.0, 10.0))
	_check(not items.is_pending(4) and (items.get_node("GroundItem_4") as Node3D).position.y == -50.0,
		"an item whose ray hits when it is listed never waits")
	items.free()
