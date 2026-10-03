extends SceneTree

## Round 701: a press of the left button over the world is one click -- one
## destination and one ring placement -- and holding it, moving the mouse
## with it held, or letting it go does nothing more (READ: CGInterface::
## vslot_017 case 0x201 at 0x77c4a7 runs the pick 0x793570 on WM_LBUTTONDOWN;
## WM_LBUTTONUP (case 0x202 -> 0x78e5d0) and WM_MOUSEMOVE (case 0x200) do not
## walk; timer 7 (0x777b90) re-plots a sky run's heading, not the click). The
## events go through World3D's own _unhandled_input, the camera aimed over a
## synthetic flat box (never game data). Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## NEGATIVE (MEASURED): against dev 34286d92 the press sets nothing and makes
## no ring (2 FAIL lines: the click went on the release, and a drag past 6
## pixels made the release no click at all but a steer that re-picked under
## the cursor in _physics_process -- which this subclass does not run, so the
## drag checks pass there for that reason; the live xdotool run is their
## measurement).

const TERRAIN_LAYER := 0b1001 # World3D.TERRAIN_COLLISION_LAYER

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
	var world := _make_world()
	if world != null:
		await process_frame
		await physics_frame
		await physics_frame
		_test_hold(world)
		world.queue_free()
		await process_frame
	print("click_hold_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

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

func _button(index: int, pressed: bool, pos: Vector2, mask: int) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = index
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = mask
	return ev

func _motion(pos: Vector2, rel: Vector2, mask: int) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = rel
	ev.button_mask = mask
	return ev

## Where a screen point's camera ray meets the pick layers (the scene's own
## ground bodies and the box): a second probe of the same point, fired here
## rather than through World3D.
func _ground_under(cam: Camera3D, screen: Vector2) -> Vector3:
	var from := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 1000.0, TERRAIN_LAYER)
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(query)
	return hit["position"] if not hit.is_empty() else Vector3(INF, INF, INF)

func _test_hold(world: Node) -> void:
	var cam: Camera3D = world.get("camera_3d")
	var player: CharacterBody3D = world.get("player")
	if cam == null or player == null:
		_check(false, "the world has its camera and player")
		return
	cam.current = true
	cam.global_position = Vector3(0.0, 40.0, 30.0)
	cam.look_at(Vector3(0.0, 0.0, -30.0), Vector3.UP)
	player.global_position = Vector3.ZERO
	world.set("_player_move_order", false)
	var size := cam.get_viewport().get_visible_rect().size
	var press_at := size / 2.0
	var expected := _ground_under(cam, press_at)
	var left := MOUSE_BUTTON_MASK_LEFT

	# The press: one destination and one ring, at once.
	world.call("_unhandled_input", _button(MOUSE_BUTTON_LEFT, true, press_at, left))
	var target: Vector3 = world.get("_move_target")
	var gm: GroundMarkers = world.get("_ground_markers")
	_check(bool(world.get("_has_move_target")) and target.distance_to(expected) < 0.05,
		"the press itself sets the destination at the point under the cursor (%s, expected %s)" % [str(target), str(expected)])
	_check(gm != null and gm.shown and gm.center.distance_to(expected) < 0.05,
		"and puts the ring there (%s)" % (str(gm.center) if gm != null else "no ring"))
	if gm == null:
		return
	var ring_at := gm.center

	# Held, the mouse dragged 200 pixels across the ground in steps.
	var pos := press_at
	for i in 10:
		var step := Vector2(20.0, 8.0)
		pos += step
		var mv := _motion(pos, step, left)
		world.call("_input", mv)
		world.call("_unhandled_input", mv)
	var moved_to := _ground_under(cam, pos)
	_check(moved_to.distance_to(expected) > 20.0, "the drag ends over ground %.1f from the press point (a real move of the cursor)" % moved_to.distance_to(expected))
	_check((world.get("_move_target") as Vector3).distance_to(target) < 1e-4 and gm.center.distance_to(ring_at) < 1e-4,
		"holding and dragging moves neither the destination nor the ring (target %s, ring %s)" % [str(world.get("_move_target")), str(gm.center)])
	_check(not ("_left_steering" in world), "there is no held-button steer left to run in _physics_process")

	# Arrived, then the button let go over other ground: nothing walks.
	world.set("_has_move_target", false)
	world.call("_unhandled_input", _button(MOUSE_BUTTON_LEFT, false, pos, 0))
	_check(not bool(world.get("_has_move_target")) and gm.center.distance_to(ring_at) < 1e-4,
		"the release is not a click: no new walk, the ring stays (READ: case 0x202 -> 0x78e5d0)")
	_check(not bool(world.get("_left_button_held")), "the release clears the held state")

	# A new press is what moves them.
	world.call("_unhandled_input", _button(MOUSE_BUTTON_LEFT, true, pos, left))
	_check(bool(world.get("_has_move_target")) and (world.get("_move_target") as Vector3).distance_to(moved_to) < 0.05
		and gm.center.distance_to(moved_to) < 0.05, "a second press walks to and rings the new point")
	world.call("_unhandled_input", _button(MOUSE_BUTTON_LEFT, false, pos, 0))

	# The right button still orbits, also with the left held, and the left drag
	# does not (READ: case 0x200 reads the right byte, or the middle with +0x4f9).
	var arm: SpringArm3D = world.get("camera_arm")
	if arm != null:
		world.set("_camera_view", world.get("CAMERA_VIEW_FREE"))
		var yaw0 := arm.rotation_degrees.y
		var mv_left := _motion(pos + Vector2(30, 0), Vector2(30, 0), left)
		world.call("_input", mv_left)
		world.call("_unhandled_input", mv_left)
		_check(is_equal_approx(arm.rotation_degrees.y, yaw0), "a left drag turns no camera")
		world.call("_unhandled_input", _button(MOUSE_BUTTON_RIGHT, true, pos, MOUSE_BUTTON_MASK_RIGHT))
		world.call("_unhandled_input", _button(MOUSE_BUTTON_LEFT, true, pos, MOUSE_BUTTON_MASK_RIGHT | left))
		var mv_both := _motion(pos + Vector2(30, 0), Vector2(30, 0), MOUSE_BUTTON_MASK_RIGHT | left)
		world.call("_input", mv_both)
		_check(not is_equal_approx(arm.rotation_degrees.y, yaw0), "a right drag still orbits with the left held too (yaw %.2f -> %.2f)" % [yaw0, arm.rotation_degrees.y])
		world.call("_unhandled_input", _button(MOUSE_BUTTON_LEFT, false, pos, MOUSE_BUTTON_MASK_RIGHT))
		world.call("_unhandled_input", _button(MOUSE_BUTTON_RIGHT, false, pos, 0))
		_check(not bool(world.get("_camera_orbiting")), "the right release ends the orbit")
