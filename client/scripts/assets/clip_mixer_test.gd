extends SceneTree

## Round 808: ClipMixer holds the client's mix (READ addresses in its header):
## a loop restarts from frame 0 and fades linearly; a one-shot fades in, plays,
## holds its last frame while it fades out; the one-shots are committed over the
## loops; the other bodies' change of clip weighs the two the same way.
## Synthetic clips of one bone, never game data. Run headless on the render box:
## `client/tools/remote_godot.sh tests`.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_loops()
	_test_shots()
	_test_mix()
	_test_fades()
	print("clip_mixer_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

## A clip of one bone "B" turning about Y from `a0` to `a1` degrees over `ms`.
func _clip(ms: int, a0: float, a1: float, cyclic: bool) -> BanReader.ParsedAnimation:
	var c := BanReader.ParsedAnimation.new()
	c.duration_ms = ms
	c.cyclic = cyclic
	c.key_times = PackedInt32Array([0, ms])
	var bone := BanReader.Bone.new()
	bone.bone_name = "B"
	for a in [a0, a1]:
		var k := BanReader.Keyframe.new()
		k.rotation = Quaternion(Vector3.UP, deg_to_rad(a))
		k.position = Vector3(a, 0, 0)
		bone.keyframes.append(k)
	c.bones.append(bone)
	return c

func _w(m: ClipMixer, clip: BanReader.ParsedAnimation) -> float:
	for l in m.loops + m.shots:
		if (l as ClipMixer.Layer).clip == clip:
			return (l as ClipMixer.Layer).w
	return -1.0

func _test_loops() -> void:
	var idle := _clip(2000, 0, 0, true)
	var run := _clip(666, 0, 90, true)
	var m := ClipMixer.new()
	m.play_loop(idle, 0.0)
	m.step(500.0)
	_check(is_equal_approx(_w(m, idle), 1.0) and is_equal_approx(m.time_ms(idle), 500.0), "a loop played with no fade is at weight 1 and runs")
	# A move: the idle stops over 200, the run fades in over 100 from frame 0.
	m.stop_loops_except(run, ClipMixer.STOP_MS)
	m.play_loop(run, ClipMixer.RUN_IN_MS)
	_check(m.time_ms(run) == 0.0 and _w(m, run) == 0.0, "the run starts at t = 0, weight 0 (0xc74170)")
	m.step(50.0)
	_check(is_equal_approx(_w(m, run), 0.5) and is_equal_approx(_w(m, idle), 0.75), "50 ms in: run 0.5, idle 0.75 (linear)")
	m.step(50.0)
	_check(is_equal_approx(_w(m, run), 1.0) and is_equal_approx(_w(m, idle), 0.5), "100 ms in: run 1, idle 0.5")
	m.step(100.0)
	_check(_w(m, idle) == -1.0 and m.loops.size() == 1, "200 ms in: the idle is gone")
	_check(is_equal_approx(m.time_ms(run), 200.0), "and the run is 200 ms into its stride")
	m.step(500.0)
	_check(is_equal_approx(m.time_ms(run), 34.0), "a loop wraps at its length (700 of 666 -> 34)")
	# Played again: from its start (also when already on the list).
	m.play_loop(run, ClipMixer.RUN_IN_MS)
	_check(m.time_ms(run) == 0.0 and _w(m, run) == 0.0 and m.loops.size() == 1, "a loop played again restarts, one layer")

func _test_shots() -> void:
	var idle := _clip(2000, 0, 0, true)
	var up := _clip(1600, 0, 40, false)
	var m := ClipMixer.new()
	m.play_loop(idle, 0.0)
	m.play_once(up, ClipMixer.SNAP_IN_MS, ClipMixer.SHOT_OUT_MS)
	_check(_w(m, up) == 1.0, "a one-shot with A = 0 is at weight 1 at once")
	m.step(1600.0)
	_check(is_equal_approx(_w(m, up), 1.0) and is_equal_approx(m.time_ms(up), 1600.0), "at its end it holds its last frame")
	m.step(50.0)
	_check(is_equal_approx(_w(m, up), 0.75) and is_equal_approx(m.time_ms(up), 1600.0), "then fades out over B, still on its last frame")
	m.step(150.0)
	_check(_w(m, up) == -1.0, "and is dropped at 0")
	var emote := _clip(1000, 0, 10, false)
	m.play_once(emote, ClipMixer.SHOT_IN_MS, ClipMixer.SHOT_OUT_MS)
	m.step(100.0)
	_check(is_equal_approx(_w(m, emote), 0.5), "a one-shot with A = 200 is at 0.5 100 ms in")
	m.stop(emote, 200.0)
	m.step(100.0)
	_check(is_equal_approx(_w(m, emote), 0.25), "a stop fades it linearly from where it was")
	var die := _clip(500, 0, 10, false)
	m.play_once(die, 0.0, 200.0, 1.0, true)
	m.step(2000.0)
	_check(is_equal_approx(_w(m, die), 1.0), "a held one-shot (OURS) never fades")

func _test_mix() -> void:
	var sk := Skeleton3D.new()
	sk.add_bone("B")
	var a := _clip(1000, 0, 0, true)
	var b := _clip(1000, 90, 90, true)
	var m := ClipMixer.new()
	m.play_loop(a, 0.0)
	m.play_loop(b, 0.0, 1.0, 1.0)
	m.step(1.0)
	m.apply(sk)
	var yaw := rad_to_deg(sk.get_bone_pose_rotation(0).get_euler().y)
	_check(absf(yaw - 45.0) < 0.5, "two loops at weight 1 average evenly (%.1f)" % yaw)
	var s := _clip(1000, 0, 0, false)
	m.play_once(s, 0.0, 200.0)
	m.step(1.0)
	m.apply(sk)
	yaw = rad_to_deg(sk.get_bone_pose_rotation(0).get_euler().y)
	_check(absf(yaw) < 0.5, "a one-shot at weight 1 hides the loops (%.1f)" % yaw)
	var lone := ClipMixer.new()
	lone.play_loop(b, 200.0)
	lone.step(10.0)
	lone.apply(sk)
	yaw = rad_to_deg(sk.get_bone_pose_rotation(0).get_euler().y)
	_check(absf(yaw - 90.0) < 0.5, "a lone clip shows fully at any weight (%.1f)" % yaw)
	sk.free()

func _test_fades() -> void:
	# A move (run in 100, stand out 200): the run's share 0.4 / 0.667 / 1.
	_check(absf(ClipMixer.fade_share(50.0, 100.0, 200.0, true) - 0.4) < 1e-4, "50 ms into a run: share 0.4")
	_check(absf(ClipMixer.fade_share(100.0, 100.0, 200.0, true) - 2.0 / 3.0) < 1e-4, "100 ms: 0.667")
	_check(ClipMixer.fade_share(200.0, 100.0, 200.0, true) == 1.0, "200 ms: all run")
	# A stop (stand in 200, run out 200): halfway at 100.
	_check(absf(ClipMixer.fade_share(100.0, 200.0, 200.0, true) - 0.5) < 1e-4, "a stop is even at 100 ms")
	# A one-shot handing back: the loops show by 1 - its weight.
	_check(absf(ClipMixer.fade_share(50.0, 0.0, 200.0, false) - 0.25) < 1e-4, "a hand-back is 0.25 of the loop 50 ms in")
	var sk := Skeleton3D.new()
	sk.add_bone("B")
	var old := _clip(1000, 0, 0, true)
	var f := ClipMixer.Fade.new()
	f.from = old
	f.at = 10.0
	f.in_ms = 100.0
	f.out_ms = 200.0
	sk.set_bone_pose_rotation(0, Quaternion(Vector3.UP, deg_to_rad(90)))
	_check(ClipMixer.blend_from(sk, f, 10.05), "a change 50 ms old is in progress")
	var yaw := rad_to_deg(sk.get_bone_pose_rotation(0).get_euler().y)
	_check(absf(yaw - 36.0) < 0.5, "the new pose (90) weighs 0.4 against the old (0): %.1f" % yaw)
	_check(not ClipMixer.blend_from(sk, f, 10.3), "and it is over at 200 ms")
	# A fidget fading in over its stand: its share is its own weight.
	_check(absf(ClipMixer.fade_share(100.0, 400.0, 400.0, true, true) - 0.25) < 1e-4, "a fidget 100 ms into its 400 ms fade-in shows 0.25")
	var over := ClipMixer.Fade.new()
	over.from = old
	over.over = true
	over.in_ms = 400.0
	over.at = 0.0
	_check(not over.done(0.3) and over.done(0.4), "and its change is over at 400 ms")
	# A one-shot cut short goes on from where it was, to its last frame.
	var cut := ClipMixer.Fade.new()
	cut.from = _clip(1000, 0, 100, false)
	cut.from_loop = false
	cut.from_ms = 500.0
	cut.in_ms = 0.0
	cut.out_ms = 200.0
	cut.at = 0.0
	sk.set_bone_pose_rotation(0, Quaternion.IDENTITY)
	ClipMixer.blend_from(sk, cut, 0.1)
	yaw = rad_to_deg(sk.get_bone_pose_rotation(0).get_euler().y)
	_check(absf(yaw - 30.0) < 0.5, "a cut one-shot 100 ms on: at 60 degrees, half of it over the new pose (%.1f)" % yaw)
	sk.free()
