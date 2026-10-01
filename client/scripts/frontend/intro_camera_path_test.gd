extends SceneTree

## IntroCameraPath (round 678): the title camera's path and the camera it
## drives, READ from the client (docs/protocol/intro_script.md):
##   - at each keyframe's time the path IS that keyframe (position and the
##     four rotation values; angles modulo 2 pi, the fix-up's unwrap);
##   - between keys, the uniform Catmull-Rom through p[i-1..i+2] with the
##     end keys repeated;
##   - the clock clamps at the length (the last keyframe's time) and the
##     camera rests on the last keyframe; the start pose is the last one;
##   - keys out of time order are inserted sorted (FUN_004e6040);
##   - the camera: eye = target - (0,0,dist) * Rz(roll) Rx(pitch) Ry(yaw),
##     row vectors; in the world (z mirrored) pitch 0, yaw 0 looks along -z.
## Synthetic keyframes only (ours).
##
## NEGATIVE: before round 678 there is no IntroCameraPath -- this suite does
## not parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func kf(t: float, pos: Vector3, pitch: float, yaw: float, roll: float, dist: float) -> IntroScript.Keyframe:
	var k := IntroScript.Keyframe.new()
	k.time = t
	k.pos = pos
	k.pitch = pitch
	k.yaw = yaw
	k.roll = roll
	k.distance = dist
	return k

static func ang_eq(a: float, b: float) -> bool:
	return absf(wrapf(a - b, -PI, PI)) < 1e-4

func _initialize() -> void:
	var keys := [
		kf(0.0, Vector3(724.81, 157.25, 687.56), 0.170, 3.765, 0.0, 100.0),
		kf(2.0, Vector3(467.72, 139.59, 355.32), 0.030, 3.875, 0.0, 100.0),
		kf(4.0, Vector3(120.91, 144.35, 94.58), -0.000, 4.245, 0.0, 90.0),
		kf(6.0, Vector3(-274.76, 143.33, -70.05), 0.010, 6.200, 0.2, 80.0),
		kf(8.0, Vector3(-648.14, 158.71, -182.92), 0.025, 0.100, 0.0, 100.0),
	]
	var path := IntroCameraPath.from_keyframes(keys)
	_check(path.key_count() == 5 and is_equal_approx(path.length, 8.0), "five keys, length 8 s")
	var worst_pos := 0.0
	var worst_ang := 0.0
	for k in keys:
		var pose := path.sample(k.time)
		worst_pos = maxf(worst_pos, pose.target.distance_to(k.pos))
		for pair in [[pose.pitch, k.pitch], [pose.yaw, k.yaw], [pose.roll, k.roll]]:
			worst_ang = maxf(worst_ang, absf(wrapf(pair[0] - pair[1], -PI, PI)))
		_check(pose.target.is_equal_approx(k.pos) and ang_eq(pose.pitch, k.pitch) and ang_eq(pose.yaw, k.yaw)
			and ang_eq(pose.roll, k.roll) and is_equal_approx(pose.distance, k.distance),
			"at t=%.1f the path is keyframe %.1f (target %s yaw %.4f dist %.2f)" % [k.time, k.time, str(pose.target), pose.yaw, pose.distance])
	print("path accuracy at the keyframes: position %.6f units, angle %.6f rad" % [worst_pos, worst_ang])

	# Between keys: Catmull-Rom of p[i-1..i+2] (the first segment repeats key 0).
	var mid := path.sample(1.0)
	var want := IntroCameraPath.catmull_rom_vec3(keys[0].pos, keys[0].pos, keys[1].pos, keys[2].pos, 0.5)
	_check(mid.target.is_equal_approx(want), "t=1.0: Catmull-Rom(p0, p0, p1, p2, 0.5) (got %s want %s)" % [str(mid.target), str(want)])
	var hand := 0.5 * (2.0 * 467.72 + (120.91 - 724.81) * 0.25 + (2.0 * 724.81 - 5.0 * 467.72 + 4.0 * 120.91 - (-274.76)) * 0.0625 \
		+ (-724.81 + 3.0 * 467.72 - 3.0 * 120.91 + (-274.76)) * 0.015625)
	_check(absf(path.sample(2.5).target.x - hand) < 1e-2, "t=2.5 x by the READ formula by hand: %.4f (got %.4f)" % [hand, path.sample(2.5).target.x])
	var last_seg := path.sample(7.0)
	var want_last := IntroCameraPath.catmull_rom_vec3(keys[2].pos, keys[3].pos, keys[4].pos, keys[4].pos, 0.5)
	_check(last_seg.target.is_equal_approx(want_last), "the last segment repeats the last key as p3")

	# The yaw fix-up: 6.2 -> 0.1 crosses 2 pi; the interpolated yaw stays near
	# 2 pi rather than swinging back through pi.
	var y7 := path.sample(7.0).yaw
	_check(absf(wrapf(y7, 0.0, TAU) - 0.0) < 0.6 or absf(wrapf(y7, 0.0, TAU) - TAU) < 0.6,
		"t=7.0, between yaw 6.2 and 0.1: near 0 / 2 pi, not near pi (got %.3f)" % y7)
	var unwrapped := [6.2, 0.1, 0.2, 6.0]
	IntroCameraPath.unwrap_angles(unwrapped)
	_check(is_equal_approx(unwrapped[1], 0.1 + IntroCameraPath.ANGLE_TWO_PI) and is_equal_approx(unwrapped[3], 6.0),
		"0x4deee0: 0.1 after 6.2 becomes 0.1 + 2 pi; 6.0 after it stays (got %s)" % str(unwrapped))
	var down := [0.1, 6.2]
	IntroCameraPath.unwrap_angles(down)
	_check(is_equal_approx(down[1], 6.2 - IntroCameraPath.ANGLE_TWO_PI), "6.2 after 0.1 becomes 6.2 - 2 pi (got %s)" % str(down))
	_check(is_equal_approx(path.sample(3.0).distance, IntroCameraPath.catmull_rom(100.0, 100.0, 90.0, 80.0, 0.5)),
		"the distance curve has no angle fix-up and is Catmull-Rom too")

	# The clock: advance clamps at the length; the camera then rests on the
	# last keyframe; before playing, the camera is on the last keyframe.
	_check(path.start_pose().target.is_equal_approx(keys[4].pos), "the start pose is the LAST keyframe (OnCreate)")
	path.time = 0.0
	var p1 := path.advance(3.0)
	_check(is_equal_approx(path.time, 3.0) and not path.finished(), "advance 3 s: time 3, not finished")
	var p2 := path.advance(100.0)
	_check(is_equal_approx(path.time, 8.0) and path.finished(), "advance past the end: clamped to 8 s, finished")
	_check(p2.target.is_equal_approx(keys[4].pos) and ang_eq(p2.yaw, keys[4].yaw), "clamped on the last keyframe")
	path.advance(5.0)
	_check(is_equal_approx(path.time, 8.0), "stays clamped")
	_check(path.sample(-1.0).target.is_equal_approx(keys[0].pos) and path.sample(99.0).target.is_equal_approx(keys[4].pos),
		"before the first key: key 0; after the last: the last")
	var single := IntroCameraPath.from_keyframes([keys[2]])
	_check(is_equal_approx(single.length, 4.0) and not single.finished(), "one keyframe at t=4: length 4, not finished at 0")
	var zero := IntroCameraPath.from_keyframes([kf(0.0, Vector3.ONE, 0, 0, 0, 10)])
	_check(zero.length == 0.0 and zero.finished(),
		"a path of length 0 is finished at once: vslot_012's 'time == length' test brings the login in (READ)")
	var looping := IntroCameraPath.from_keyframes(keys)
	looping.loop = true
	looping.advance(19.0)
	_check(is_equal_approx(looping.time, 3.0), "with +0xec set it would wrap (19 -> 3), the title never sets it (got %.2f)" % looping.time)

	# Out of time order: inserted sorted; the length is still the last in FILE
	# order (FUN_00869b50).
	var shuffled := IntroCameraPath.from_keyframes([keys[0], keys[2], keys[1]])
	_check(shuffled.sample(2.0).target.is_equal_approx(keys[1].pos) and shuffled.sample(4.0).target.is_equal_approx(keys[2].pos),
		"keys out of order are sorted by time (FUN_004e6040)")
	_check(is_equal_approx(shuffled.length, 2.0),
		"the length is the LAST keyframe's time in FILE order (t=2 here), not the largest (FUN_00869b50) (got %.2f)" % shuffled.length)

	# The camera (FUN_00bae580): pitch 0 yaw 0 -> eye straight behind the
	# target along SRO -z; pitch > 0 lifts the eye (looks down).
	var pose := IntroCameraPath.Pose.new()
	pose.target = Vector3(100, 50, 100)
	pose.distance = 10.0
	var etu := IntroCameraPath.sro_eye_target_up(pose)
	_check((etu[0] as Vector3).is_equal_approx(Vector3(100, 50, 90)) and (etu[2] as Vector3).is_equal_approx(Vector3.UP),
		"pitch 0 yaw 0: eye = target - (0,0,dist), up = +y (got %s)" % str(etu))
	pose.pitch = 0.5
	etu = IntroCameraPath.sro_eye_target_up(pose)
	_check((etu[0] as Vector3).y > 50.0, "pitch +0.5 puts the eye above the target (looking down) (got %s)" % str(etu[0]))
	pose.pitch = 0.0
	pose.yaw = PI / 2.0
	etu = IntroCameraPath.sro_eye_target_up(pose)
	_check((etu[0] as Vector3).is_equal_approx(Vector3(90, 50, 100)), "yaw pi/2: the view runs along SRO +x, eye at x - dist (got %s)" % str(etu[0]))

	# Into the world: World3D's frame mapping, and the camera transform.
	var W := load("res://scripts/World3D.gd") as GDScript
	var corner: Vector3 = W.call("_group_position", Vector3.ZERO, 0.0)
	var local := Vector3(724.81, 157.25, 687.56)
	var world: Vector3 = W.call("title_world_from_local", local)
	_check(world.is_equal_approx(corner + Vector3(local.x, local.y, -local.z)),
		"title_world_from_local = the frame region group's corner + (x, y, -z) (got %s)" % str(world))
	_check(world.is_equal_approx(Vector3(724.81 - 960.0, 157.25, 960.0 - 687.56)), "for the frame region, (x - 960, y, 960 - z)")
	var to_world := func(v: Vector3) -> Vector3: return W.call("title_world_from_local", v)
	pose.yaw = 0.0
	var xf := IntroCameraPath.camera_transform(pose, to_world)
	var fwd := -xf.basis.z
	_check(fwd.is_equal_approx(Vector3(0, 0, -1)), "yaw 0 looks along world -z (SRO +z mirrored) (got %s)" % str(fwd))
	_check(xf.origin.is_equal_approx(to_world.call(Vector3(100, 50, 90))), "the camera stands at the eye")
	pose.yaw = 0.3
	pose.pitch = 0.2
	xf = IntroCameraPath.camera_transform(pose, to_world)
	var look_target: Vector3 = xf.origin - xf.basis.z * 10.0
	_check(look_target.is_equal_approx(to_world.call(pose.target)), "the camera looks at the target, 10 units ahead (got %s)" % str(look_target))

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()
