extends SceneTree

## Round 860: the return scroll's hold (ScrollHold; READ server side, the PC's
## message filter s:0x4296a0, group 11 value 1 -- scrollhold.go). While this
## player's own 0x30BF kind 0xb value is 1, a ground click walks nowhere, an
## arrow turns nothing, no attack walks into reach; the state's 0 releases it,
## and the thief-den scrolls' value 2 holds nothing. The events go through
## World3D's own _unhandled_input over a synthetic flat box (never game data).
## Run headless on the render box: `client/tools/remote_godot.sh tests`.

const TERRAIN_LAYER := 0b1001 # World3D.TERRAIN_COLLISION_LAYER
const OWN_ID := 7

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
	_test_rule()
	var world := _make_world()
	if world != null:
		await process_frame
		await physics_frame
		_test_hold(world)
		world.queue_free()
		await process_frame
	print("scroll_hold860_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _test_rule() -> void:
	_check(ScrollHold.HOLD_VALUE == 1, "the held value is 1 (group 11's one record)")
	_check(ScrollHold.holds(1), "state 1 holds")
	_check(not ScrollHold.holds(0) and not ScrollHold.holds(2) and not ScrollHold.holds(3),
		"0, 2 (the thief-den scrolls) and 3 hold nothing")

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
		"func _own_id() -> int:",
		"\treturn %d" % OWN_ID,
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
	var ground := StaticBody3D.new()
	ground.collision_layer = TERRAIN_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0.0, -0.5, 0.0)
	root.add_child(ground)
	return world

func _press(world: Node, pos: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		ev.global_position = pos
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		world.call("_unhandled_input", ev)

func _state(world: Node, object_id: int, value: int) -> void:
	var c := WorldNet.StateChange.new()
	c.object_id = object_id
	c.kind = 0xb
	c.value = value
	world.call("_on_teleport_state", c)

func _reset_walk(world: Node) -> void:
	world.set("_has_move_target", false)
	world.set("_player_move_order", false)
	(world.get("player") as Node3D).global_position = Vector3.ZERO

func _test_hold(world: Node) -> void:
	var cam: Camera3D = world.get("camera_3d")
	var player: CharacterBody3D = world.get("player")
	if cam == null or player == null:
		_check(false, "the world has its camera and player")
		return
	cam.current = true
	cam.global_position = Vector3(0.0, 40.0, 30.0)
	cam.look_at(Vector3(0.0, 0.0, -30.0), Vector3.UP)
	var at := cam.get_viewport().get_visible_rect().size / 2.0

	# Another player's state 1 holds nothing here.
	_reset_walk(world)
	_state(world, OWN_ID + 1, 1)
	_check(not bool(world.call("_scroll_hold")), "another player's state 1 does not hold this one")

	# This player's state 1: held.
	_state(world, OWN_ID, 1)
	_check(bool(world.call("_scroll_hold")) and bool(world.call("_own_move_blocked")), "this player's state 1 holds it (the move gate shut)")
	_press(world, at)
	_check(not bool(world.get("_has_move_target")), "a ground click while held walks nowhere")
	_check(not bool(world.call("_arrow_send_allowed")), "the arrow keys send nothing while held")
	var turned: String = world.call("_arrow_turn", 1, true)
	world.call("_arrow_turn", 1, false)
	_check(turned.begins_with("refused"), "an arrow turn is refused while held (%s)" % turned)
	world.call("_attack_monster", 99)
	_check((world.get("_pending_attack") as Dictionary).is_empty() and not bool(world.get("_has_move_target")),
		"an attack while held neither walks nor waits to be sent")
	_check((world.call("_start_heading_run", Vector3(0.0, 0.5, -1.0).normalized()) as String) == "ignore",
		"a sky click (heading run) while held is ignored")

	# The state's 0 releases it.
	_state(world, OWN_ID, 0)
	_check(not bool(world.call("_scroll_hold")), "the state's 0 releases the hold")
	_reset_walk(world)
	_press(world, at)
	_check(bool(world.get("_has_move_target")), "after the 0 a ground click walks again")

	# The thief-den scrolls' state 2 holds nothing (no record for 2).
	_state(world, OWN_ID, 2)
	_reset_walk(world)
	_press(world, at)
	_check(bool(world.get("_has_move_target")), "state 2 (a thief-den scroll) does not hold: the click walks")
	_state(world, OWN_ID, 0)
