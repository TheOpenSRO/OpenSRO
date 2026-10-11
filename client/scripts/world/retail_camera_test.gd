extends SceneTree

## Round 778: the original's third-person camera (RetailCamera; World3D's
## _place_camera, _camera_wheel and _input's orbit). Run headless on the
## render box: `client/tools/remote_godot.sh tests`.
##
## The rules are checked against the values READ from sro_client.exe (the
## addresses are in retail_camera.gd); the world part drives World3D's own
## camera code over a synthetic flat ground (a collision box on the terrain
## layer) with a one-mesh stand-in for the player's model.
##
## NEGATIVE: against dev 53e6ef92 the first line fails (no RetailCamera), the
## world part reports FAIL lines by behaviour (the arm's pitch clamps at -10,
## the zoom range is 20..90 in 15s, the look-at point is a fixed 14.34 and
## the model never fades).

const TICK := 1.0 / 60.0
const TERRAIN_LAYER := 0b1001 # World3D.TERRAIN_COLLISION_LAYER

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _initialize() -> void:
	var rc := load("res://scripts/world/retail_camera.gd") as GDScript
	_check(rc != null, "RetailCamera exists")
	if rc != null:
		_test_constants()
		_test_rules()
		_test_ramp()
		_test_model_fade()
	var world := _make_world()
	if world != null:
		await physics_frame
		await physics_frame
		_test_world(world)
		world.queue_free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _test_constants() -> void:
	# The READ values (float / double reads of the client's .rdata).
	_check(RetailCamera.PITCH_LIMIT == 1.0707963705062866, "the pitch limit is the float at 0xdb8d70, 1.0707964 rad")
	_check(_near(RetailCamera.PITCH_LIMIT_DEGREES, rad_to_deg(RetailCamera.PITCH_LIMIT), 1e-9), "... 61.35 degrees either way")
	_check(RetailCamera.DRAG_RADIANS_PER_PIXEL == 0.005 and _near(RetailCamera.DRAG_DEGREES_PER_PIXEL, rad_to_deg(0.005), 1e-12),
		"0.005 rad (0.2865 deg) of turn per pixel of drag (the double at 0xd986e8)")
	_check(RetailCamera.ZOOM_MIN == 10.0 and RetailCamera.ZOOM_MAX == 150.0, "the zoom runs 10..150 (0xd81a88, 0xdb8d74)")
	_check(RetailCamera.ZOOM_STEP == 6.0, "a wheel notch is 120 / 20 = 6 units (0xe1b830)")
	_check(RetailCamera.FADE_PITCH == -0.9 and RetailCamera.FADE_RATE == 2.0, "the fade starts below -0.9 rad and runs 0.5 s (0xdb8d68, 0xd86ecc)")
	_check(RetailCamera.PLAYER_SIZE_HEIGHT == 20.0, "a player's +0x228 is 20 x size 2 x 0.5")
	_check(RetailCamera.COLLISION_SKIP == 5.0, "the collision ray starts and stops 5 short (0xd81950)")
	var w3d := load("res://scripts/World3D.gd") as GDScript
	var consts: Dictionary = w3d.get_script_constant_map() if w3d != null else {}
	_check(_near(float(consts.get("CAMERA_PITCH_MAX_DEGREES", 0.0)), 61.35211274793701, 1e-6)
		and _near(float(consts.get("CAMERA_PITCH_MIN_DEGREES", 0.0)), -61.35211274793701, 1e-6),
		"World3D's arm pitch runs -61.35..+61.35 (it was -80..-10: no look up at all)")
	_check(float(consts.get("CAMERA_ZOOM_MIN", 0.0)) == 10.0 and float(consts.get("CAMERA_ZOOM_MAX", 0.0)) == 150.0
		and float(consts.get("CAMERA_ZOOM_STEP", 0.0)) == 6.0, "World3D zooms 10..150 by 6 (it was 20..90 by 15)")
	_check(_near(float(consts.get("CAMERA_ORBIT_SENSITIVITY", 0.0)), 0.2864788975654116, 1e-9), "World3D turns 0.2865 deg a pixel (it was 0.3)")

func _test_rules() -> void:
	# Drag: down raises the camera (retail pitch up), clamped.
	_check(_near(RetailCamera.drag_pitch(0.0, 10.0), 0.05), "10 pixels down raises the retail pitch by 0.05")
	_check(RetailCamera.drag_pitch(1.0, 100.0) == RetailCamera.PITCH_LIMIT and RetailCamera.drag_pitch(-1.0, -100.0) == -RetailCamera.PITCH_LIMIT,
		"the pitch clamps at +-1.0708")
	# Wheel.
	_check(RetailCamera.wheel(45.0, 1.0) == 39.0 and RetailCamera.wheel(45.0, -1.0) == 51.0, "a notch forward zooms in 6, back out 6")
	_check(RetailCamera.wheel(12.0, 1.0) == 10.0 and RetailCamera.wheel(148.0, -1.0) == 150.0, "the wheel clamps at 10 and 150")
	# The look-up limit: 150 level, 62.9 at 30 deg up, 40 at 0.9 rad, 44.8 at the limit.
	_check(RetailCamera.look_up_max(0.0) == INF and _near(RetailCamera.look_up_max(-0.00001), 150.0, 0.01), "no limit at level, 150 just below")
	_check(_near(RetailCamera.look_up_max(deg_to_rad(-30.0)), 62.90, 0.01), "62.9 at 30 degrees up")
	_check(_near(RetailCamera.look_up_max(-0.9), 40.0, 1e-4), "40 at 0.9 rad up")
	_check(_near(RetailCamera.look_up_max(-RetailCamera.PITCH_LIMIT), 44.85, 0.01), "44.85 at the 61.35-degree limit")
	# settle: below level the distance is pulled in; at or above it goes back out.
	_check(_near(RetailCamera.settle(150.0, 150.0, -0.9), 40.0), "looking up 0.9 rad pulls 150 in to 40")
	_check(RetailCamera.settle(30.0, 30.0, -0.9) == 30.0, "a distance under the limit is kept")
	_check(RetailCamera.settle(40.0, 150.0, 0.5) == 150.0, "looking down again goes back out to the distance asked for")
	_check(RetailCamera.settle(45.0, 45.0, 0.7) == 45.0, "at rest it stays")
	# The look-at height: 14.2 at 150, h - 3.8 = 16.2 at 10.
	_check(_near(RetailCamera.target_height(150.0), 14.2) and _near(RetailCamera.target_height(10.0), 16.2)
		and _near(RetailCamera.target_height(45.0), 15.7), "the look-at point is 14.2 over the feet at 150, 15.7 at 45, 16.2 at 10")
	_check(RetailCamera.collided(20.0) == 15.0, "a hit 20 out puts the camera at 15")
	_check(RetailCamera.fades(-0.91) and not RetailCamera.fades(-0.9) and not RetailCamera.fades(0.5), "the model fades below -0.9 only")
	_check(_near(RetailCamera.retail_pitch(-42.0), deg_to_rad(42.0)) and _near(RetailCamera.arm_pitch_degrees(deg_to_rad(42.0)), -42.0),
		"an arm pitch of -42 (above, looking down) is a retail pitch of +0.733")

func _test_ramp() -> void:
	var r := RetailCamera.Ramp.new()
	_check(r.step(0.1) == 255 and r.done, "at rest the ramp holds 255")
	r.set_hidden(true)
	_check(r.step(0.125) == 191, "0.125 s into the fade out: 255 - 0.25 x 255 = 191 (truncated 191.25)")
	r.set_hidden(true)
	_check(r.step(0.125) == 127, "a repeated set does not restart it: 0.25 s -> 127 (truncated 127.5)")
	_check(r.step(0.25) == 0 and r.done, "0.5 s: 0, and done")
	r.set_hidden(false)
	_check(r.step(0.25) == 127, "back in: 0.25 s -> 127")
	r.set_hidden(true)
	_check(r.start == 127 and r.step(0.25) == 63, "turned round mid-way, it ramps from where it was over a new 0.5 s (127 -> 63 at 0.25 s)")
	_check(r.step(1.0) == 0, "and ends at 0")

func _test_model_fade() -> void:
	var model := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mi.material_override = mat
	model.add_child(mi)
	var mf := RetailCamera.ModelFade.new()
	mf.apply(model, 255)
	_check(mi.material_override == mat, "at 255 the model draws its own material")
	mf.apply(model, 128)
	var twin := mi.material_override
	_check(twin != mat and twin != null and twin.has_meta(AppearFade.TWIN_META), "below 255 it draws a fade twin")
	_check(twin is ShaderMaterial and _near(float((twin as ShaderMaterial).get_shader_parameter("appear_alpha")), 128.0 / 255.0),
		"... at the ramp's alpha")
	mf.apply(model, 0)
	_check(_near(float((twin as ShaderMaterial).get_shader_parameter("appear_alpha")), 0.0), "... down to 0")
	mf.apply(model, 255)
	_check(mi.material_override == mat and not mi.has_meta(AppearFade.ORIGINAL_META), "back at 255 it has its own material again")
	model.free()

# --- The world -----------------------------------------------------------------

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

## Runs the world's camera step `n` times.
func _steps(world: Node, n: int) -> void:
	for i in n:
		world.call("_follow_with_camera", TICK)

func _test_world(world: Node) -> void:
	var player: CharacterBody3D = world.get("player")
	var arm: SpringArm3D = world.get("camera_arm")
	var cam: Camera3D = world.get("camera_3d")
	if player == null or arm == null or cam == null or not world.has_method("_place_camera"):
		_check(false, "the world has its player, arm, camera and _place_camera")
		return
	# The pivot, as _ready makes it.
	var pivot := Node3D.new()
	world.add_child(pivot)
	world.set("_camera_pivot", pivot)
	arm.reparent(pivot, false)
	arm.set_physics_process_internal(false)
	player.global_position = Vector3.ZERO
	var skel := Skeleton3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mi.material_override = mat
	skel.add_child(mi)
	player.add_child(skel)
	world.set("_player_skeleton", skel)

	# Looking down 42 degrees at 45: nothing in the way.
	arm.rotation_degrees = Vector3(-42.0, 180.0, 0.0)
	arm.spring_length = 45.0
	_steps(world, 2)
	_check(_near(cam.position.z, 45.0, 1e-3) and _near(arm.position.y, 15.7, 1e-3),
		"looking down at 45: the camera 45 out, the look-at point 15.7 over the feet (z %.3f, y %.3f)" % [cam.position.z, arm.position.y])
	var eye_y := cam.global_position.y
	_check(_near(eye_y, 15.7 + 45.0 * sin(deg_to_rad(42.0)), 1e-2), "the eye is 15.7 + 45 sin 42 over the feet (%.3f)" % eye_y)

	# The wheel: one notch in is 6.
	world.call("_camera_wheel", 1.0)
	_steps(world, 1)
	_check(_near(float(world.get("_camera_current")), 39.0) and _near(cam.position.z, 39.0, 1e-3), "a notch in: 39")
	for i in 10:
		world.call("_camera_wheel", 1.0)
	_steps(world, 1)
	_check(_near(cam.position.z, 10.0, 1e-3) and _near(arm.position.y, 16.2, 1e-3), "zoomed all the way in: 10, looking at 16.2 over the feet")
	_check(int((world.get("_self_fade") as RetailCamera.Ramp).alpha) == 255 and mi.material_override == mat,
		"close in from above the model does not fade (no distance test)")

	# Looking up 55 degrees from 150: pulled to the look-up limit, then cut by the ground.
	for i in 30:
		world.call("_camera_wheel", -1.0)
	arm.rotation_degrees.x = 55.0
	_steps(world, 3)
	var limit := RetailCamera.look_up_max(deg_to_rad(-55.0))
	_check(_near(float(world.get("_camera_current")), limit, 1e-3), "looking up 55 deg the distance in force is the limit %.2f" % limit)
	var hit := float(world.get("_camera_hit"))
	var look := arm.position.y
	# The ground under the arm, by a ray of the test's own (the scene's own
	# placeholder floor is on the same layer as the fixture's box).
	var target := arm.global_position
	var down := arm.global_transform.basis.z.normalized()
	var q := PhysicsRayQueryParameters3D.create(target + down * 5.0, target + down * 200.0, arm.collision_mask, [player.get_rid()])
	var got := (world as Node3D).get_world_3d().direct_space_state.intersect_ray(q)
	var expect_hit := target.distance_to(got["position"]) - 5.0 if not got.is_empty() else NAN
	_check(hit > 0.0 and _near(hit, expect_hit, 0.05) and _near(cam.position.z, hit, 1e-4),
		"the ground cuts it short: camera at %.2f (|hit| - 5 = %.2f), look-at %.3f" % [cam.position.z, expect_hit, look])
	_check(cam.global_position.y > 0.0, "the eye stays above the ground (%.2f)" % cam.global_position.y)
	_check(_near(look, RetailCamera.target_height(hit), 0.05), "the look-at height follows the collided distance")

	# The fade: 0.5 s to nothing, the model on a twin.
	_steps(world, 15)
	var ramp := world.get("_self_fade") as RetailCamera.Ramp
	_check(ramp.alpha > 0 and ramp.alpha < 255 and mi.material_override != mat, "a quarter second in the model is part faded (%d)" % ramp.alpha)
	_steps(world, 20)
	_check(ramp.alpha == 0 and mi.material_override != mat, "after 0.5 s it is gone")
	# Back down: it fades in and gets its own material back; the zoom goes back out.
	arm.rotation_degrees.x = -30.0
	_steps(world, 35)
	_check(ramp.alpha == 255 and mi.material_override == mat, "looking down again it fades back in 0.5 s, own material back")
	_check(_near(float(world.get("_camera_current")), 150.0), "and the camera goes back out to the 150 asked for")

	# A QA hook's write to spring_length is a new zoom; collision_mask 0 is QA_FREE.
	arm.spring_length = 77.0
	arm.collision_mask = 0
	arm.rotation_degrees.x = 40.0
	_steps(world, 1)
	_check(_near(cam.position.z, minf(77.0, RetailCamera.look_up_max(deg_to_rad(-40.0))), 1e-3) and float(world.get("_camera_hit")) < 0.0,
		"a QA distance is taken and a zero mask turns the ray off (%.2f)" % cam.position.z)

	# The orbit: the third-person view takes the pitch and keeps the yaw.
	world.set("_camera_view", world.get("CAMERA_VIEW_THIRD_PERSON"))
	world.set("_camera_orbiting", true)
	arm.rotation_degrees = Vector3(-20.0, 180.0, 0.0)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(50.0, 20.0)
	drag.button_mask = MOUSE_BUTTON_MASK_RIGHT
	world.call("_input", drag)
	_check(_near(arm.rotation_degrees.y, 180.0, 1e-4) and _near(arm.rotation_degrees.x, -20.0 - 20.0 * RetailCamera.DRAG_DEGREES_PER_PIXEL, 1e-4),
		"third person: the drag turns the pitch only")
	world.set("_camera_view", world.get("CAMERA_VIEW_QUARTER"))
	world.call("_input", drag)
	_check(_near(arm.rotation_degrees.y, 180.0 - 50.0 * RetailCamera.DRAG_DEGREES_PER_PIXEL, 1e-4), "quarter: the drag turns the yaw")
	world.set("_camera_view", world.get("CAMERA_VIEW_FREE"))
	drag.relative = Vector2(0.0, -1000.0)
	world.call("_input", drag)
	_check(_near(arm.rotation_degrees.x, 61.35211274793701, 1e-4), "free: dragging up looks up, to +61.35 at most")
	world.set("_camera_orbiting", false)
