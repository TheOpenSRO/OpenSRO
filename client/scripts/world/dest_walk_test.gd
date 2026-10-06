extends SceneTree

## Round 749 in the world itself: another player's body walks the 0xB021 it is
## told of (OtherWalk) at its run speed and stops on the point; 0xB023 snaps
## it; a spawn that names a destination walks on; a buff's run speed reaches
## its leg; this player's own echo changes nothing (no rubber-banding) and its
## own 0xB023 is the server's correction. Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## The world is World3D.tscn with crowd_arrival_test.gd's subclass: no _ready,
## a bare Skeleton3D per body.
##
## NEGATIVES: _step_other_bodies easing a legged body as well fails "it walks
## at its run speed"; _on_entity_move_echo applying this player's own echo
## fails "its own echo leaves the player where its walk has it".

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
		_test_walk(world)
		_test_spawned_walking(world)
		_test_own(world)
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
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _build_assembled_character(_equipped: Dictionary = {}, _body: String = \"\", _scale: int = 0x22, _pluses: Dictionary = {}) -> Skeleton3D:",
		"\treturn Skeleton3D.new()",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

func _snap(id: int, at: Vector3) -> WorldNet.EntitySnapshot:
	var s := WorldNet.EntitySnapshot.new()
	s.character_id = id
	s.char_name = "P%d" % id
	s.gender = CharacterNet.GENDER_CHINA_MAN
	s.x = at.x
	s.y = at.y
	s.z = at.z
	return s

func _echo(uid: int, dest: Vector3, source: Vector3) -> DestMoveNet.Echo:
	var e := DestMoveNet.Echo.new()
	e.uid = uid
	e.kind = DestMoveNet.KIND_DESTINATION
	e.dest_world = dest
	e.has_source = true
	e.source_world = source
	return e

func _stop(uid: int, at: Vector3, angle: int) -> DestMoveNet.Stop:
	var s := DestMoveNet.Stop.new()
	s.uid = uid
	s.world = at
	s.angle = angle
	return s

func _frames(world: Node, n: int) -> void:
	for i in n:
		world.call("_step_other_bodies", 1.0 / 60.0, 1)

func _test_walk(world: Node) -> void:
	var bodies: Dictionary = world.get("_other_bodies")
	var legs: Dictionary = world.get("_other_legs")
	world.call("_spawn_result_others", [_snap(301, Vector3(0, 0, 0))], [])
	var body: Node3D = bodies[301]
	world.call("_on_entity_move_echo", _echo(301, Vector3(60, 0, 0), Vector3(0, 0, 0)))
	_check(legs.has(301), "an echo starts the body's leg")
	_frames(world, 30)
	_check(absf(body.position.x - 25.0) < 0.01, "half a second in it has walked 25 at its run speed of 50 (x %.3f)" % body.position.x)
	var gait: Dictionary = (world.get("_other_gaits") as Dictionary).get(301, {})
	_check(gait.is_empty() or bool(gait.get("moving", false)), "and plays its run")
	_frames(world, 60)
	_check(body.position == Vector3(60, 0, 0) and not legs.has(301), "it stops on the point, the leg over (%s)" % str(body.position))
	# A buff's speed reaches the next leg.
	world.call("_note_other_speed", 301, 100)
	world.call("_on_entity_move_echo", _echo(301, Vector3(60, 0, 100), Vector3(60, 0, 0)))
	_frames(world, 30)
	_check(absf(body.position.z - 50.0) < 0.01, "at a buffed 100 it walks 50 in half a second (z %.3f)" % body.position.z)
	# The stop: snapped, facing the message, the leg over.
	world.call("_on_entity_move_stop", _stop(301, Vector3(60, 1, 40), 0))
	_check(body.position == Vector3(60, 1, 40) and not legs.has(301), "0xB023 puts it there and ends the leg")
	_check(is_equal_approx(body.rotation.y, RemoteFacing.yaw_of(RemoteFacing.from_wire_angle(0), 0.0)), "facing the message's angle")
	_frames(world, 10)
	_check(body.position == Vector3(60, 1, 40), "and it stays")
	# A source far from where it is drawn is taken; a near one is not.
	world.call("_on_entity_move_echo", _echo(301, Vector3(200, 0, 40), Vector3(100, 0, 40)))
	_check(body.position == Vector3(100, 0, 40), "a source 40 off puts the body there first")
	world.call("_on_entity_move_echo", _echo(301, Vector3(200, 0, 60), Vector3(110, 0, 40)))
	_check(body.position == Vector3(100, 0, 40), "a source 10 off does not jerk it")
	world.call("_on_entity_left", 301)
	_check(not legs.has(301), "a body that leaves takes its leg")

func _test_spawned_walking(world: Node) -> void:
	var bodies: Dictionary = world.get("_other_bodies")
	var s := _snap(302, Vector3(0, 0, 0))
	s.has_dest = true
	s.dest = Vector3(0, 0, -30)
	s.run_speed = 60.0
	world.call("_spawn_result_others", [s], [])
	_frames(world, 30)
	var body: Node3D = bodies[302]
	_check(absf(body.position.z + 30.0) < 0.01, "a body spawned walking walks on, at the record's run speed of 60: 30 in half a second (z %.3f)" % body.position.z)
	var r := _snap(303, Vector3(0, 0, 0))
	r.run_wire = 0
	world.call("_spawn_result_others", [r], [])
	_frames(world, 60)
	_check(absf((bodies[303] as Node3D).position.x - 50.0) < 0.01, "a body spawned on a heading run runs on (+x at 50: %.3f)" % (bodies[303] as Node3D).position.x)
	world.call("_on_entity_left", 302)
	world.call("_on_entity_left", 303)

func _test_own(world: Node) -> void:
	var player: Node3D = world.get("player")
	var net := root.get_node_or_null("NetClient")
	if net == null:
		_check(false, "the NetClient autoload is in the tree")
		return
	net.set("own_character_id", 777)
	player.position = Vector3(10, 0, 10)
	world.call("_on_entity_move_echo", _echo(777, Vector3(500, 0, 10), Vector3(-100, 0, 10)))
	_check(player.position == Vector3(10, 0, 10), "its own echo leaves the player where its walk has it")
	world.set("_has_move_target", true)
	world.set("_move_target", Vector3(500, 0, 10))
	world.call("_on_entity_move_stop", _stop(777, Vector3(-20, 0, 10), 0))
	_check(Vector2(player.position.x, player.position.z) == Vector2(-20, 10), "its own 0xB023 is the server's correction: put there (%s)" % str(player.position))
	_check(not bool(world.get("_has_move_target")), "its order over")
	var sync: MoveOrderSync = world.get("_move_sync")
	_check(not sync.active and sync.rest == player.position, "and the server is taken to have it there")
	net.set("own_character_id", -1)
