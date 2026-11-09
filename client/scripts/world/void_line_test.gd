extends SceneTree

## The void recovery (World3D.void_line_step, round 871): a player below
## WORLD_FLOOR_Y with no terrain under it at all fell through a gap in the
## grid and is put back on its last ground; a player standing on an object's
## walkable surface far above its terrain is not. Run headless on the render
## box: `client/tools/remote_godot.sh tests`.
##
## The prod sequence (v0.1.642, the server's -single-frame): a hole used in
## Jangan, the gate clicked, its line taken; the zone change put the player on
## the Wrecked Ship's deck (local -779.12) at scene -776.63 in Jangan's frame,
## the sea floor's terrain ~1,020 below it. The ground check found that
## terrain more than 20 below the feet (not grounded) and the y under -500,
## and put the player back at its last ground -- the gate's spot in Jangan,
## (215, -31.9, -265) -- on every step: the ship's region left the window and
## was unloaded, and the player stood on nothing.
##
## NEGATIVE: before round 871 the deck case was put back too. The world is
## World3D.tscn with a quiet subclass (height_retry_test.gd's pattern): the
## scene's VoidCatchFloor (top -1995, terrain-only layer) is there, and the
## sea floor is a plain slab on World3D's TERRAIN_COLLISION_LAYER.

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
	var world := _make_world()
	if world != null:
		await _test_void_line(world)
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
	root.add_child(world)
	return world

func _slab(layer: int, top: float, at: Vector3) -> StaticBody3D:
	var shape := BoxShape3D.new()
	shape.size = Vector3(400.0, 2.0, 400.0)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var sb := StaticBody3D.new()
	sb.collision_layer = layer
	sb.collision_mask = 0
	sb.add_child(cs)
	sb.position = Vector3(at.x, top - 1.0, at.z)
	return sb

func _test_void_line(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var player := world.get("player") as Node3D
	_check(player != null, "the scene's player")
	if player == null:
		return
	# The ground in the scene is its own placeholder at the origin; the deck's
	# spot is well away from it.
	var gate_spot := Vector3(215.0, -31.9, -265.0)
	var deck := Vector3(3000.0, -776.63, 3000.0)
	world.set("_last_grounded_position", gate_spot)
	player.position = deck
	await physics_frame

	# A gap: below the line with no terrain under it (VoidCatchFloor alone).
	_check(not bool(world.call("void_has_terrain_below", deck)),
		"no terrain under the deck's spot yet: VoidCatchFloor does not count (it would answer every gap)")
	_check(bool(world.call("void_line_step")) and player.position.is_equal_approx(gate_spot),
		"a player at -776.63 over no terrain at all is put back on its last ground (got %s)" % str(player.position))

	# The Wrecked Ship: the sea floor's terrain under the deck, ~1,021 below.
	var sea_floor := _slab(consts["TERRAIN_COLLISION_LAYER"], -1797.5, deck)
	root.add_child(sea_floor)
	await physics_frame
	world.set("_last_grounded_position", gate_spot)
	player.position = deck
	_check(bool(world.call("void_has_terrain_below", deck)), "the sea floor lies under the deck")
	var put_back := bool(world.call("void_line_step"))
	_check(not put_back and player.position.is_equal_approx(deck),
		"a player on the deck at -776.63, the sea floor below, stays there (got %s; before round 871 it went back to %s)" % [
			str(player.position), str(gate_spot)])
	for i in 5:
		world.call("void_line_step")
		await physics_frame
	_check(player.position.is_equal_approx(deck), "and stays over five steps (got %s)" % str(player.position))
	root.remove_child(sea_floor)
	sea_floor.free()
