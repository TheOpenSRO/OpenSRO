extends SceneTree

## Dense monster fields (round 664). Run headless on the render box:
## `client/tools/remote_godot.sh tests`. Synthetic data only: bare
## Skeleton3D nodes, a two-key clip and bodies placed by hand; no archive.
##
## What it holds the client to (MonsterCrowd; docs/WORLD_ISSUES.md round 664):
## - the clip tick runs once per rendered frame with every step's time
##   (TickGate), and a frame that ran it does not run it again;
## - a body's clip sounds advance only within the core's 600-unit cull of the
##   listener (READ), a body going out of hearing is rested once, and a
##   rested body comes back without firing what it missed (AnimSounds.rest;
##   the anim_sounds suite holds the key-level rule);
## - the indexed pose (pose_at) is the name-searched one, bone by bone, for a
##   loop, its wrap, a one-shot and a held last key, and its bone map is
##   found once per clip and model;
## - the tick's written-out range and frustum tests give MonsterDraw's
##   verdicts for every body (posed, hidden), and read each skeleton's metas
##   once (CullCache);
## - a body within 300 of the camera is posed every frame, one farther out
##   every second or fourth (the animation LOD, OURS), each on its own slot;
##   a body out of view and hearing is tested every second frame, so one
##   coming into view is posed at most a frame late;
## - the minimap is fed only the bodies that can land in its sign circle.
##
## NEGATIVES, on the base (int/mob 46559e0): MonsterCrowd does not exist, so
## every rule check fails; the world's tick advances every body's sounds
## within 2,020 of the camera (the far body is not rested); the minimap fill
## takes every body.

var _failures := 0

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
	var path := "res://scripts/world/monster_crowd.gd"
	_check(ResourceLoader.exists(path), "MonsterCrowd exists")
	if ResourceLoader.exists(path):
		var crowd: Script = load(path)
		_test_tick_gate(crowd)
		_test_hearing(crowd)
		_test_pose_equal(crowd)
		_test_cull_cache(crowd)
		_test_pose_lod(crowd)
	var world := _make_world()
	if world != null:
		await process_frame
		_test_world_tick(world)
		_test_world_minimap(world)
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- the rules ----------------------------------------------------------------

func _test_tick_gate(crowd: Script) -> void:
	var gate = crowd.TickGate.new()
	var a: float = gate.take(10, 1.0 / 60.0)
	var b: float = gate.take(10, 1.0 / 60.0)
	var c: float = gate.take(10, 1.0 / 60.0)
	var d: float = gate.take(11, 1.0 / 60.0)
	_check(is_equal_approx(a, 1.0 / 60.0), "the first step of a frame ticks with its own time (%.4f)" % a)
	_check(b < 0.0 and c < 0.0, "the frame's second and third steps do not tick (%.2f, %.2f)" % [b, c])
	_check(is_equal_approx(d, 3.0 / 60.0), "the next frame ticks with the two held steps and its own: no time lost (%.4f)" % d)
	_check(gate.take(12, 0.02) > 0.0, "a frame with one step ticks once, as before")

func _test_hearing(crowd: Script) -> void:
	var at := Vector3.ZERO
	_check(crowd.hearable(Vector3(600.0, 0.0, 0.0), at), "600 from the listener: heard (the cull is `> 600`, READ)")
	_check(not crowd.hearable(Vector3(600.5, 0.0, 0.0), at), "600.5 from the listener: not heard")
	_check(not crowd.hearable(Vector3(0.0, 0.0, -2000.0), at), "2,000 away, in the old 2,020 range: not heard")

func _test_pose_lod(crowd: Script) -> void:
	_check(crowd.pose_interval(0.0) == 1 and crowd.pose_interval(299.9) == 1, "within 300 of the camera: every frame")
	_check(crowd.pose_interval(300.0) == 2 and crowd.pose_interval(899.9) == 2, "300 to 900: every second frame")
	_check(crowd.pose_interval(900.0) == 4 and crowd.pose_interval(2019.0) == 4, "900 to the 2,020 range: every fourth frame")
	var hits := 0
	for tick in range(8):
		if crowd.pose_due(tick, 3, 4):
			hits += 1
	_check(hits == 2, "every fourth frame is twice in eight (%d)" % hits)
	var spread := {}
	for slot in range(4):
		for tick in range(4):
			if crowd.pose_due(tick, slot, 4):
				spread[tick] = int(spread.get(tick, 0)) + 1
	_check(spread.size() == 4 and spread.values().max() == 1, "four slots at every fourth frame pose on four different frames (%s)" % str(spread))
	_check(crowd.recheck_due(0, 2) and not crowd.recheck_due(1, 2) and crowd.recheck_due(1, 3),
		"a quiet body is tested every second frame, on its slot's parity")

func _skeleton(bones: int) -> Skeleton3D:
	var skel := Skeleton3D.new()
	for i in range(bones):
		skel.add_bone("b%d" % i)
		if i > 0:
			skel.set_bone_parent(i, i - 1)
	return skel

## A clip over bones b0..b(n-1) with `keys` keys, every key a different
## rotation and position; a track for a bone no skeleton has, and one with
## no keys.
func _clip(n: int, keys: int, duration: int, cyclic: bool) -> BanReader.ParsedAnimation:
	var clip := BanReader.ParsedAnimation.new()
	clip.duration_ms = duration
	clip.cyclic = cyclic
	var times := PackedInt32Array()
	for k in range(keys):
		times.append(int(float(duration) * float(k) / float(keys)))
	clip.key_times = times
	for b in range(n):
		var track := BanReader.Bone.new()
		track.bone_name = "b%d" % b
		for k in range(keys):
			var kf := BanReader.Keyframe.new()
			kf.rotation = Quaternion(Vector3(1.0, float(b % 3), float(k)).normalized(), 0.3 * float(k + b))
			kf.position = Vector3(float(b), float(k) * 0.5, float(b * k) * 0.1)
			track.keyframes.append(kf)
		clip.bones.append(track)
	var ghost := BanReader.Bone.new()
	ghost.bone_name = "not_a_bone"
	var kg := BanReader.Keyframe.new()
	kg.rotation = Quaternion.IDENTITY
	ghost.keyframes.append(kg)
	clip.bones.append(ghost)
	var empty := BanReader.Bone.new()
	empty.bone_name = "b0"
	clip.bones.append(empty)
	return clip

func _same_pose(a: Skeleton3D, b: Skeleton3D) -> bool:
	for i in range(a.get_bone_count()):
		if not a.get_bone_pose_rotation(i).is_equal_approx(b.get_bone_pose_rotation(i)):
			return false
		if not a.get_bone_pose_position(i).is_equal_approx(b.get_bone_pose_position(i)):
			return false
	return true

func _test_pose_equal(crowd: Script) -> void:
	var loop := _clip(12, 7, 1400, true)
	var once := _clip(12, 5, 900, false)
	var slow := _skeleton(14)
	var fast := _skeleton(14)
	fast.set_meta(crowd.META_LAYOUT, "synthetic\\model.bsr")
	var all_same := true
	var cases := [[loop, 0.0, true], [loop, 0.37, true], [loop, 1.39, true], [loop, 2.05, true],
		[once, 0.0, false], [once, 0.44, false], [once, 0.899, false], [once, 5.0, false]]
	for c in cases:
		Skeleton3DBuilder.apply_ban_pose_at(slow, c[0], c[1], c[2])
		crowd.pose_at(fast, c[0], c[1], c[2])
		if not _same_pose(slow, fast):
			all_same = false
			print("  differs at %.3f s (loop %s)" % [c[1], str(c[2])])
	_check(all_same, "the indexed pose equals the name-searched one bone by bone: loop, its wrap, one-shot, held last key")
	var maps: Dictionary = loop.get_meta(crowd.META_BONE_MAPS, {})
	var first: PackedInt32Array = maps.get("synthetic\\model.bsr", PackedInt32Array())
	_check(maps.size() == 1 and first.size() == loop.bones.size() and first[12] == -1 and first[13] == -1,
		"one bone map per clip and model; a missing bone and an empty track map to -1 (%s)" % str(first))
	var other := _skeleton(14)
	other.set_meta(crowd.META_LAYOUT, "synthetic\\other.bsr")
	crowd.pose_at(other, loop, 0.2, true)
	_check((loop.get_meta(crowd.META_BONE_MAPS, {}) as Dictionary).size() == 2, "another model gets its own map")
	var plain := _skeleton(14)
	crowd.pose_at(plain, loop, 0.37, true)
	Skeleton3DBuilder.apply_ban_pose_at(slow, loop, 0.37, true)
	_check(_same_pose(plain, slow), "a skeleton with no layout takes the old path")
	for s in [slow, fast, other, plain]:
		s.free()

func _test_cull_cache(crowd: Script) -> void:
	var cache = crowd.CullCache.new()
	var culled := _skeleton(2)
	culled.set_meta(MonsterDraw.META_CULL, true)
	culled.set_meta(MonsterDraw.META_RADIUS, 12.5)
	culled.set_meta(MonsterDraw.META_HIDE, true)
	var npc := _skeleton(2)
	npc.set_meta(MonsterDraw.META_CULL, true)
	var doll := _skeleton(2)
	var info: Array = cache.info(culled)
	_check(info.slice(0, 3) == [12.5, 1.0, 0.0] and info.size() == 5 and info[4] == 0.0, "a culled monster: its radius, it hides, not resting, a slot, not quiet (%s)" % str(info))
	info[2] = 1.0
	_check((cache.info(culled) as Array)[2] == 1.0, "the cache's array is kept: a write sticks")
	_check((cache.info(npc) as Array).slice(0, 3) == [1.0, 0.0, 0.0], "an NPC: radius 1 by default, does not hide")
	_check((cache.info(doll) as Array).is_empty(), "a skeleton with no cull meta: nothing to test")
	doll.free()
	for i in range(600):
		cache.tick()
	_check(cache.size() == 2, "a freed skeleton's entry is dropped on the 600th tick (%d left)" % cache.size())
	culled.free()
	npc.free()

# --- the world ----------------------------------------------------------------

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

## A two-key loop turning b1 through 90 degrees at 500 ms.
func _turn_clip() -> BanReader.ParsedAnimation:
	var clip := BanReader.ParsedAnimation.new()
	clip.duration_ms = 1000
	clip.cyclic = true
	clip.key_times = PackedInt32Array([0, 500])
	var track := BanReader.Bone.new()
	track.bone_name = "b1"
	var k0 := BanReader.Keyframe.new()
	k0.rotation = Quaternion.IDENTITY
	var k1 := BanReader.Keyframe.new()
	k1.rotation = Quaternion(Vector3.RIGHT, PI / 2.0)
	track.keyframes.append(k0)
	track.keyframes.append(k1)
	clip.bones.append(track)
	return clip

func _test_world_tick(world: Node) -> void:
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = Vector3(0.0, 60.0, 0.0)
	cam.look_at(Vector3(0.0, 0.0, -400.0))
	cam.far = 4000.0
	cam.make_current()
	var player := world.get("player") as Node3D
	if player != null:
		player.global_position = Vector3(0.0, 0.0, 0.0)
	var holder := Node3D.new()
	world.add_child(holder)
	var clip := _turn_clip()
	var rng := RandomNumberGenerator.new()
	rng.seed = 664
	var skels: Array = []
	var radii: Array = []
	for i in range(400):
		var body := Node3D.new()
		body.position = Vector3(rng.randf_range(-2600.0, 2600.0), 0.0, rng.randf_range(-2600.0, 2600.0))
		var skel := _skeleton(3)
		var radius := rng.randf_range(2.0, 60.0)
		skel.set_meta(MonsterDraw.META_CULL, true)
		skel.set_meta(MonsterDraw.META_RADIUS, radius)
		skel.set_meta(MonsterDraw.META_HIDE, true)
		skel.set_meta("opensro_crowd_layout", "synthetic") # MonsterCrowd.META_LAYOUT, spelled out so the base parses
		body.add_child(skel)
		holder.add_child(body)
		world.call("_animate_skeleton", skel, clip)
		skels.append(skel)
		radii.append(radius)
	# One near and one far body with sound owners: 300 and 700 from the
	# player (the listener), both in front of the camera and in range.
	var sounds = world.get("_anim_sounds")
	var near_body := Node3D.new()
	near_body.position = Vector3(0.0, 0.0, -300.0)
	var near_skel := _skeleton(3)
	var far_body := Node3D.new()
	far_body.position = Vector3(0.0, 0.0, -700.0)
	var far_skel := _skeleton(3)
	for pair in [[near_body, near_skel], [far_body, far_skel]]:
		var skel: Skeleton3D = pair[1]
		skel.set_meta(MonsterDraw.META_CULL, true)
		skel.set_meta(MonsterDraw.META_RADIUS, 5.0)
		(pair[0] as Node3D).add_child(skel)
		holder.add_child(pair[0])
		var owner := AnimSounds.Owner.new()
		owner.label = "test"
		owner.node = pair[0]
		sounds.register(skel, owner)
		world.call("_animate_skeleton", skel, clip)
	# b1 starts at a rotation the clip never takes (it turns about +x): a
	# body is posed iff its b1 no longer holds it. (Identity would not do:
	# a body whose phase puts its clip at 0 ms is posed at identity.)
	var sentinel := Quaternion(Vector3.UP, 1.234)
	for skel in skels:
		(skel as Skeleton3D).set_bone_pose_rotation(1, sentinel)
	world.set("_idle_anim_time", 0.0)
	world.call("_tick_idle_animations", 0.25)
	var eye := cam.global_position
	var planes := cam.get_frustum()
	var turned := func(skel: Skeleton3D) -> bool: return not skel.get_bone_pose_rotation(1).is_equal_approx(sentinel)
	# One tick: every wanted body within 300 of the camera is posed; of the
	# farther wanted ones, some wait for their frame (the LOD).
	var near_missed := 0
	var far_wanted := 0
	var far_posed := 0
	var unwanted_posed := 0
	for i in range(skels.size()):
		var skel: Skeleton3D = skels[i]
		var want := MonsterDraw.pose_wanted(skel.global_position, radii[i], eye, planes)
		var dist := skel.global_position.distance_to(eye)
		if want and dist < 300.0 and not turned.call(skel):
			near_missed += 1
		if want and dist >= 300.0:
			far_wanted += 1
			if turned.call(skel):
				far_posed += 1
		if not want and turned.call(skel):
			unwanted_posed += 1
	_check(near_missed == 0, "one tick: every wanted body within 300 of the camera is posed (%d missed)" % near_missed)
	_check(far_wanted > 10 and far_posed < far_wanted, "one tick: of %d wanted bodies farther out, %d are posed -- the rest wait for their frame" % [far_wanted, far_posed])
	_check(unwanted_posed == 0, "one tick: no body out of range or out of view is posed (%d)" % unwanted_posed)
	# Three more ticks at the same clip time: every wanted body has had its
	# frame (every fourth at most), and still none of the others.
	for k in range(3):
		world.call("_tick_idle_animations", 0.0)
	var wrong_pose := 0
	var wrong_hide := 0
	var expected := 0
	for i in range(skels.size()):
		var skel: Skeleton3D = skels[i]
		var origin := skel.global_position
		var want := MonsterDraw.pose_wanted(origin, radii[i], eye, planes)
		if want:
			expected += 1
		if want != turned.call(skel):
			wrong_pose += 1
			print("  differs: body %d at %s, %.1f from the camera, radius %.1f, wanted %s" % [i, str(origin), origin.distance_to(eye), radii[i], str(want)])
		if skel.visible != MonsterDraw.in_range(origin, radii[i], eye):
			wrong_hide += 1
	_check(expected > 5 and expected < 395, "the scene has bodies both posed and not (%d of 400 posed by MonsterDraw's rule)" % expected)
	_check(wrong_pose == 0, "four ticks: the tick has posed exactly the bodies MonsterDraw.pose_wanted names (%d differ)" % wrong_pose)
	_check(wrong_hide == 0, "and hides exactly those out of range (%d differ)" % wrong_hide)
	# The camera turns round: bodies that were quiet (out of view) come into
	# view. Within two ticks (the quiet recheck) and four more (the LOD) every
	# body now wanted has been posed.
	for skel in skels:
		(skel as Skeleton3D).set_bone_pose_rotation(1, sentinel)
	cam.look_at(Vector3(0.0, 0.0, 400.0))
	eye = cam.global_position
	planes = cam.get_frustum()
	world.call("_tick_idle_animations", 0.0)
	var late_after_one := 0
	for i in range(skels.size()):
		var skel: Skeleton3D = skels[i]
		if MonsterDraw.pose_wanted(skel.global_position, radii[i], eye, planes) and not turned.call(skel):
			late_after_one += 1
	for k in range(5):
		world.call("_tick_idle_animations", 0.0)
	var turned_wrong := 0
	for i in range(skels.size()):
		var skel: Skeleton3D = skels[i]
		if MonsterDraw.pose_wanted(skel.global_position, radii[i], eye, planes) != turned.call(skel):
			turned_wrong += 1
	_check(late_after_one > 0, "one tick after the turn, some bodies now in view still wait for their recheck or LOD frame (%d)" % late_after_one)
	_check(turned_wrong == 0, "six ticks after the turn every body now in view is posed and none out of it (%d differ)" % turned_wrong)
	var state: Dictionary = sounds.get("_state")
	_check(state.get(near_skel.get_instance_id()) is Array, "a body 300 from the listener has its sounds advanced")
	_check(state.has(far_skel.get_instance_id()) and state[far_skel.get_instance_id()] == null,
		"a body 700 from the listener (in the old 2,020 range) is rested, not advanced (%s)" % str(state.get(far_skel.get_instance_id(), "absent")))
	cam.queue_free()
	holder.queue_free()

func _test_world_minimap(world: Node) -> void:
	var bodies := {}
	var holder := Node3D.new()
	world.add_child(holder)
	for i in range(10):
		var body := Node3D.new()
		body.position = Vector3(float(i) * 100.0, 0.0, 0.0)
		holder.add_child(body)
		bodies[i] = body
	var out: Array = []
	var args := [bodies, out, Vector3.ZERO, 450.0]
	world.callv("_minimap_fill_positions", args)
	_check(out.size() == 5, "the minimap is fed the bodies within its sign reach: 5 of 10 within 450 (%d)" % out.size())
	holder.free()
