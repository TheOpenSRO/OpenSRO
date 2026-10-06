extends SceneTree

## Round 739 (crowd_scale.md lane B): OtherCrowd's pieces and Detail's ten
## casters (CharacterBlobs.select_detail), on plain data. Run headless on the
## render box: `client/tools/remote_godot.sh tests`.
##
## - B1: the step gate folds a slow frame's physics steps into one tick, and
##   the folded walk lands where the per-step loop did, with the gait test
##   seeing what the old last step saw.
## - B4: the build queue dresses nearest first, within the frame's budget,
##   at least one a frame, and never a body that left.
## - B7: the uid map.
## - B2: under Detail only the ten nearest within 300 cast; the rest are
##   switched off and given back exactly as they were.
##
## NEGATIVES: lerp_factor returning `a` for every k (the old per-frame lerp on
## the summed delta, min(15 x 8/60, 1) = 1: a teleport) fails "8 folded steps";
## pump() ignoring the distance (arrival order) fails "nearest first";
## select_detail without its reach fails "the one at 350 does not cast".

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
	_test_step_gate()
	_test_folded_walk()
	_test_build_queue()
	_test_uids()
	_test_detail()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _test_step_gate() -> void:
	var g := OtherCrowd.StepGate.new()
	var d := 1.0 / 60.0
	_check(g.take() < 0.0 and g.steps == 0, "a frame with no physics step ticks nothing")
	g.add(d)
	_check(is_equal_approx(g.take(), d) and g.steps == 1, "one step: the frame ticks with its delta, one step")
	for i in 8:
		g.add(d)
	var t := g.take()
	_check(is_equal_approx(t, 8.0 * d) and g.steps == 8, "eight steps: one tick after them with all 8 steps' time (got %.4f, %d steps)" % [t, g.steps])
	_check(g.take() < 0.0, "and nothing more until the next step")

## The per-step loop as World3D ran it, against the folded tick.
func _test_folded_walk() -> void:
	var speed := 15.0
	var d := 1.0 / 60.0
	var threshold := 1.4
	for k in [1, 2, 3, 8]:
		var from := Vector3(0, 0, 0)
		var target := Vector3(30, 0, -12)
		var p := from
		var last_gait := false
		for i in k:
			last_gait = p.distance_to(target) > threshold
			p = p.lerp(target, minf(speed * d, 1.0))
		var f := OtherCrowd.lerp_factor(speed, d, k)
		var q := from.lerp(target, f)
		var gait := OtherCrowd.distance_before_last(from.distance_to(target), speed, d, k) > threshold
		_check(q.distance_to(p) < 1e-4, "%d folded step(s) land where %d per-step lerps did (%.5f off)" % [k, k, q.distance_to(p)])
		_check(gait == last_gait, "and the gait is what the last step saw (%s)" % str(gait))
	# The gait's own edge: a body 1.5 from its target walks one step and
	# stands the next; folded over two steps the last step saw 1.125.
	var dist2 := OtherCrowd.distance_before_last(1.5, speed, d, 2)
	_check(is_equal_approx(dist2, 1.125), "two steps from 1.5: the last step saw 1.125 (got %.4f)" % dist2)
	_check(is_equal_approx(OtherCrowd.lerp_factor(speed, d, 1), 0.25), "one step is the old 15 x 1/60 = 0.25")

func _bodies(at: Array) -> Dictionary:
	var out := {}
	for i in at.size():
		var n := Node3D.new()
		n.position = at[i]
		out[100 + i] = n
	return out

func _free_all(bodies: Dictionary) -> void:
	for n in bodies.values():
		if is_instance_valid(n):
			(n as Node).free()

func _test_build_queue() -> void:
	var bodies := _bodies([Vector3(50, 0, 0), Vector3(5, 0, 0), Vector3(20, 0, 0), Vector3(0, 0, 2)])
	var order: Array = []
	var build := func(id: int) -> void: order.append(id)
	var q := OtherCrowd.BuildQueue.new()
	for id in [100, 101, 102, 103]:
		q.queue(id)
	q.budget_usec = 1 << 30
	var made := q.pump(1, Vector3.ZERO, bodies, build)
	_check(made == 4 and order == [103, 101, 102, 100], "with time to spare every body is dressed, nearest first (got %s)" % str(order))
	_check(q.is_empty(), "and the queue is empty")
	# A budget of nothing: one a frame (MIN_BUILDS_PER_FRAME), still nearest first.
	order.clear()
	q.budget_usec = 0
	for id in [100, 101, 102, 103]:
		q.queue(id)
	_check(q.pump(7, Vector3.ZERO, bodies, build) == 1 and order == [103], "with no budget one body a frame, the nearest (got %s)" % str(order))
	_check(q.pump(7, Vector3.ZERO, bodies, build) == 0, "and none more in that frame")
	q.drop(101)
	_check(q.pump(8, Vector3(60, 0, 0), bodies, build) == 1 and order == [103, 100], "the next frame the nearest to where the player is now (got %s)" % str(order))
	# A body that left (its node gone) is dropped, not built.
	(bodies[102] as Node).free()
	_check(q.pump(9, Vector3.ZERO, bodies, build) == 0 and q.is_empty() and not order.has(101) and not order.has(102),
		"a body dropped from the queue or freed is never dressed (got %s)" % str(order))
	_check(q.frames >= 1 and q.built == 2, "the queue counts its frames and bodies (%d frames, %d built)" % [q.frames, q.built])
	_free_all(bodies)

func _test_uids() -> void:
	var u := OtherCrowd.UidIndex.new()
	var big := (7 << 32) | 1234
	u.add(big)
	u.add(55)
	_check(u.find(1234) == big, "a uid finds the character id whose low 32 bits it is")
	_check(u.find(55) == 55 and u.find(56) == -1, "and nothing for an unknown uid")
	u.remove(big)
	_check(u.find(1234) == -1 and u.size() == 1, "a departure takes it out")

## Detail's casters: 12 characters in a line from the player, one past 300,
## one with a mesh its builder set not to cast, and a plate.
func _test_detail() -> void:
	var blobs := CharacterBlobs.new()
	root.add_child(blobs)
	var casters: Array = []
	var dists := [0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 110.0, 350.0]
	for d in dists:
		var n := Node3D.new()
		n.position = Vector3(d, 0, 0)
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		n.add_child(mi)
		var plate := Label3D.new()
		plate.text = "x"
		n.add_child(plate)
		root.add_child(n)
		casters.append(n)
	var no_cast := MeshInstance3D.new()
	no_cast.mesh = BoxMesh.new()
	no_cast.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(casters[11] as Node).add_child(no_cast)
	var plate12 := (casters[12] as Node).get_child(1) as GeometryInstance3D
	plate12.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	blobs.select_detail(casters, Vector3.ZERO, CharacterBlobs.DETAIL_RANGE)
	_check(_casting(casters) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], "under Detail the ten nearest within 300 cast (got %s)" % str(_casting(casters)))
	_check(blobs.detail_chosen().size() == 10, "ten are chosen")
	_check(plate12.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "a plate is left alone on a body switched off")
	# The player walks to 230: the ten nearest within 300 are 140..? -- the
	# ones at 0..110 within 230 and the one at 350 (120 away).
	blobs.select_detail(casters, Vector3(230, 0, 0), CharacterBlobs.DETAIL_RANGE)
	var now := _casting(casters)
	_check(now.has(12) and not now.has(0) and now.size() == 10, "from 230 the one at 350 casts and the one at 0 does not (got %s)" % str(now))
	_check(no_cast.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a mesh set not to cast stays off when its body is chosen")
	# From the far side only the one at 350 is within 300 of 650... none else.
	blobs.select_detail(casters, Vector3(640, 0, 0), CharacterBlobs.DETAIL_RANGE)
	_check(_casting(casters) == [12], "from 640 only the one at 350 is within 300 (got %s)" % str(_casting(casters)))
	blobs.select_detail(casters, Vector3(-400, 0, 0), CharacterBlobs.DETAIL_RANGE)
	_check(_casting(casters).is_empty(), "the one at 350 does not cast from 750 away, nor any other past 300")
	# A redress: the new meshes take the body's state at once.
	var fresh := MeshInstance3D.new()
	fresh.mesh = BoxMesh.new()
	(casters[5] as Node).add_child(fresh)
	CharacterBlobs.refresh_detail(casters[5])
	_check(fresh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a rebuilt body that is not one of the ten has its new mesh switched off")
	blobs.select_detail(casters, Vector3(-400, 0, 0), CharacterBlobs.DETAIL_RANGE)
	_check(fresh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "and it stays off on the next pass")
	blobs.select_detail(casters, Vector3(50, 0, 0), CharacterBlobs.DETAIL_RANGE)
	_check(fresh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON and _casting(casters).has(5), "and given back when its body is chosen")
	# Every mesh given back is exactly what it was: back near the start, the
	# originally off mesh is still off and every other is on.
	blobs.select_detail(casters, Vector3(1000, 0, 0), CharacterBlobs.DETAIL_RANGE)
	for n in casters:
		CharacterBlobs.set_casting(n, true)
	var on := 0
	for n in casters:
		for gi in (n as Node).find_children("*", "MeshInstance3D", true, false):
			if (gi as GeometryInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
				on += 1
	_check(on == casters.size() + 1 and no_cast.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"given back, every mesh casts as its builder set it (%d on)" % on)
	for n in casters:
		(n as Node).free()
	blobs.free()

## Which casters' first mesh casts now (indices).
func _casting(casters: Array) -> Array:
	var out: Array = []
	for i in casters.size():
		var mi := (casters[i] as Node).get_child(0) as GeometryInstance3D
		if mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
			out.append(i)
	return out
