extends SceneTree

## Round 647: the animated map objects cost less a frame and look the same.
## `godot4 --headless --path client --script res://scripts/world/map_animation_share_test.gd`
##
## 1. Shared poses are exact. Clips that start in the same frame at the same
##    clock draw from one pose (MapAnimation.PoseGroup). Over a scripted run
##    -- all in view, a sector turned out of view and back, one object past
##    the range, a region dropped, everything out of view and back -- every
##    shared object's pieces are compared, each frame, against an object
##    driven on its own the way round 645 drove it (its own player, active
##    while its sector is in view and it is in range): the same clock, the
##    same bone global poses to the bit, the same drawn state.
## 2. The per-sector range decision is exact: against the per-object test
##    for every object, at eye positions around the 2,020 edge.
## 3. A zone change resets the driver and a released region's objects leave
##    it (World3D._clear_region_grid / _release_region_objects).
##
## Built on the synthetic tree (map_animation_fixture.gd), never real game
## data. MapAnimation is reached through load(), so on an older tree this
## suite still runs and prints its FAIL lines.

const MA_PATH := "res://scripts/world/map_animation.gd"
const F := preload("res://scripts/world/map_animation_fixture.gd")

var _failures := 0
var _mismatch := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var MA = load(MA_PATH)
	var archive = F.archive()
	var template := ObjectLoader.load_object(archive, "res\\sway.bsr")
	var once_template := ObjectLoader.load_object(archive, "res\\sway_once.bsr")
	_check(MA != null and template != null and template.has_meta("opensro_map_animated"),
		"the synthetic tree loads animated")
	if MA == null or template == null:
		_finish()
		return
	var probe = MA.Driver.new()
	var sharing: bool = "poses" in probe and "pose_parent" in probe and "share" in probe and probe.has_method("drop_under") \
		and probe.has_method("reset")
	_check(sharing, "r647: the driver shares poses (poses, groups, pose_parent, drop_under and reset exist)")
	await process_frame
	if sharing:
		await _test_shared_poses(MA, template, once_template)
	await _test_sector_bounds(MA, template)
	await _test_world_resets(MA, template)
	await _test_driver_frees(MA, template)
	template.free()
	once_template.free()
	_finish()

## A placed copy of `template` at `at` under `parent`, in the tree.
func _place(template: Node3D, parent: Node3D, at: Vector3) -> Node3D:
	var n := template.duplicate() as Node3D
	n.position = at
	parent.add_child(n)
	return n

## The skeleton `n`'s leaf is drawn from.
func _drawn_skeleton(n: Node3D) -> Skeleton3D:
	var leaf := n.get_node("leaf") as MeshInstance3D
	return leaf.get_node_or_null(leaf.skeleton) as Skeleton3D

## Round 645's driving, kept here as the reference: each object on its own
## player, its sector's view tested, then `dist - radius < 2020`.
func _ref_tick(MA, refs: Array, eye: Vector3, planes: Array) -> void:
	for r in refs:
		if not is_instance_valid(r["node"]):
			continue
		var player: AnimationPlayer = r["player"]
		var node: Node3D = r["node"]
		if not MA.sector_in_view(r["centre"], planes):
			player.active = false
			continue
		var on: bool = MA.in_range(node.global_position, float(node.get_meta(MA.META_RADIUS, 0.0)), eye)
		node.visible = on
		player.active = on

## Compares every live pair; returns false (and says why in _mismatch) at the
## first difference.
func _same(MA, driver, pairs: Array) -> bool:
	for pair in pairs:
		var s: Node3D = pair[0]
		var r: Node3D = pair[1]
		if not is_instance_valid(s) or not is_instance_valid(r):
			continue
		if s.visible != r.visible:
			_mismatch = "%s drawn %s, reference %s" % [s.name, s.visible, r.visible]
			return false
		var got := _drawn_skeleton(s)
		var want := r.get_node(MA.SKELETON_NODE) as Skeleton3D
		for b in range(want.get_bone_count()):
			if got.get_bone_global_pose(b) != want.get_bone_global_pose(b):
				_mismatch = "%s bone %d: %s vs %s" % [s.name, b, got.get_bone_global_pose(b), want.get_bone_global_pose(b)]
				return false
		var o = null
		for x in driver.objects():
			if x.root == s:
				o = x
		var rp := r.get_node(MA.PLAYER_NODE) as AnimationPlayer
		if o == null or o.running != rp.active:
			_mismatch = "%s running %s, reference %s" % [s.name, o.running if o != null else null, rp.active]
			return false
		var clock: float = (o.group.player if o.group != null else o.player).current_animation_position
		if clock != rp.current_animation_position:
			_mismatch = "%s clock %.9f, reference %.9f" % [s.name, clock, rp.current_animation_position]
			return false
	return true

func _test_shared_poses(MA, template: Node3D, once_template: Node3D) -> void:
	var shared := Node3D.new()
	shared.name = "Shared"
	var ref := Node3D.new()
	ref.name = "Reference"
	var poses := Node3D.new()
	poses.name = "Poses"
	root.add_child(shared)
	root.add_child(ref)
	root.add_child(poses)
	# A region of its own for one object, to drop it mid-run.
	var region2 := Node3D.new()
	shared.add_child(region2)
	var cam := Camera3D.new()
	root.add_child(cam)
	await process_frame
	var driver = MA.Driver.new()
	driver.pose_parent = poses
	# Three sectors: S1 (0..320), S2 (320..640), S3 (960..1280) along x.
	var spots := [Vector3(100, 0, 100), Vector3(200, 0, 150), Vector3(150, 0, 250),
		Vector3(400, 0, 100), Vector3(500, 0, 200), Vector3(600, 0, 300),
		Vector3(1000, 0, 100), Vector3(1100, 0, 200)]
	var pairs: Array = []
	var refs: Array = []
	for i in spots.size():
		var s := _place(template, region2 if i == 1 else shared, spots[i])
		s.name = "S%d" % i
		driver.add(s, false)
		var r := _place(template, ref, spots[i])
		r.name = "R%d" % i
		var rp := r.get_node(MA.PLAYER_NODE) as AnimationPlayer
		MA.start(rp)
		r.visible = false
		refs.append({"node": r, "player": rp, "centre": MA.sector_of(spots[i], Transform3D.IDENTITY)[1]})
		pairs.append([s, r])
	var steps := [
		["all eight in view and range: one clock, one pose", Vector3(400, 0, 1200), 0.0, 6],
		["S3 turned out of view: its two leave the pose, paused", Vector3(400, 0, 1200), 40.0, 6],
		["S3 back: its two start together at their own clock", Vector3(400, 0, 1200), 0.0, 6],
		["S5 past 2,020 while S0..S4 stay in range", Vector3(-1450, 0, 200), -90.0, 6],
		["back: S5 alone, S6 and S7 together", Vector3(400, 0, 1200), 0.0, 6],
		["S1's region dropped", Vector3(400, 0, 1200), 0.0, 6],
		["everything out of view", Vector3(400, 0, 1200), 180.0, 4],
		["everything back (pooled pose nodes reused)", Vector3(400, 0, 1200), 0.0, 6],
	]
	var all_same := true
	var at_start := {}
	var bound_checked := false
	for step in steps:
		cam.position = step[1]
		cam.rotation_degrees = Vector3(0, step[2], 0)
		if String(step[0]).begins_with("S1's region"):
			var dropped: int = driver.drop_under(region2)
			_check(dropped == 1 and driver.size() == spots.size() - 1,
				"r647: drop_under takes the dropped region's object out (dropped %d, %d left)" % [dropped, driver.size()])
			var gone: Node3D = pairs[1][0]
			_check(_drawn_skeleton(gone) == gone.get_node(MA.SKELETON_NODE),
				"r647: and gives it back its own skeleton")
			region2.queue_free()
			(refs[1]["node"] as Node3D).queue_free()
			pairs.remove_at(1)
		for f in range(int(step[3])):
			if not _same(MA, driver, pairs):
				all_same = false
				_check(false, "r647: '%s' frame %d: the shared object draws what the reference draws (%s)" % [step[0], f, _mismatch])
				break
			driver.tick(cam.global_position, cam.get_frustum())
			_ref_tick(MA, refs, cam.global_position, cam.get_frustum())
			if f == 0 and not at_start.has(step[0]):
				at_start[step[0]] = [driver.running, driver.poses, driver.groups]
			await process_frame
		if not all_same:
			break
		if not bound_checked and driver.groups > 0:
			bound_checked = true
			var s0: Node3D = pairs[0][0]
			_check(_drawn_skeleton(s0) != s0.get_node(MA.SKELETON_NODE) and _drawn_skeleton(s0).get_parent().get_parent() == poses,
				"r647: a grouped object's pieces are bound to the group's skeleton, under the pose holder")
	_check(all_same and _same(MA, driver, pairs),
		"r647: over %d scripted frames every shared object has the reference's clock, drawn state and bone poses, to the bit" % [
			steps.reduce(func(acc, s): return acc + int(s[3]), 0)])
	var first: Array = at_start.get(steps[0][0], [0, 0, 0])
	_check(first == [8, 1, 1], "r647: eight clips started together run on ONE pose (running, poses, groups = %s)" % str(first))
	var turned: Array = at_start.get(steps[1][0], [0, 0, 0])
	_check(turned == [6, 1, 1], "r647: a sector out of view leaves the rest on the pose (got %s)" % str(turned))
	var back: Array = at_start.get(steps[2][0], [0, 0, 0])
	_check(back == [8, 2, 2], "r647: its two come back as a pose of their own -- their clock is not the group's (got %s)" % str(back))
	var edge: Array = at_start.get(steps[4][0], [0, 0, 0])
	_check(edge == [8, 3, 2], "r647: a clip that crossed the range alone runs alone (got %s)" % str(edge))
	var s5 = null
	for o in driver.objects():
		if o.root == pairs[4][0]:
			s5 = o
	_check(s5 != null and s5.group == null and _drawn_skeleton(pairs[4][0]) == (pairs[4][0] as Node3D).get_node(MA.SKELETON_NODE),
		"r647: and draws from its own skeleton")

	# A one-shot clip is never shared: at its end the player stops, and a
	# stopped clip's clock is not the looping clock the groups compare.
	var o1 := _place(once_template, shared, Vector3(120, 0, 120))
	var o2 := _place(once_template, shared, Vector3(130, 0, 120))
	var before: int = driver.poses
	driver.add(o1, false)
	driver.add(o2, false)
	driver.tick(cam.global_position, cam.get_frustum())
	_check(driver.poses == before + 2, "r647: two one-shot clips starting together keep a player each (poses %d -> %d)" % [before, driver.poses])

	# OPENSRO_MAP_ANIM_NO_SHARE's path: every clip on its own player.
	var solo = MA.Driver.new()
	solo.pose_parent = poses
	solo.share = false
	var extra: Array = []
	for i in 3:
		var n := _place(template, shared, Vector3(100 + i * 10, 0, 100))
		solo.add(n, false)
		extra.append(n)
	solo.tick(cam.global_position, cam.get_frustum())
	_check(solo.running == 3 and solo.poses == 3 and solo.groups == 0, "r647: with sharing off each clip has its own pose (got %d/%d/%d)" % [
		solo.running, solo.poses, solo.groups])

	var live: int = poses.get_child_count()
	driver.reset()
	await process_frame
	_check(driver.size() == 0 and driver.running == 0 and driver.poses == 0 and driver.groups == 0 and poses.get_child_count() == 0 and live > 0,
		"r647: reset() forgets every clip and frees the %d pose node(s)" % live)
	cam.queue_free()
	shared.queue_free()
	ref.queue_free()
	poses.queue_free()
	await process_frame

## The per-sector decision against the per-object test: with the frustum
## off (every sector in view), each object's drawn and running state after a
## tick is exactly `in_range(origin, radius, eye)`, at eyes around the edge.
func _test_sector_bounds(MA, template: Node3D) -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	await process_frame
	var driver = MA.Driver.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 647
	var nodes: Array = []
	for i in 48:
		var n := _place(template, holder, Vector3(rng.randf_range(0, 960), rng.randf_range(-40, 40), rng.randf_range(0, 640)))
		n.scale = Vector3.ONE * rng.randf_range(0.5, 40.0)
		driver.add(n, false)
		nodes.append(n)
	var by_root := {}
	if driver.has_method("objects"):
		for o in driver.objects():
			by_root[o.root] = o
	var wrong := 0
	var trials := 400
	for t in trials:
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(1700.0, 2500.0)
		var eye := Vector3(480 + cos(ang) * dist, rng.randf_range(-100, 300), 320 + sin(ang) * dist)
		# Held still for a second tick now and then: the decided sectors are
		# not visited again, and must still be right.
		for rep in (2 if t % 5 == 0 else 1):
			driver.tick(eye, [])
			for n in nodes:
				var p := n.get_node(MA.PLAYER_NODE) as AnimationPlayer
				var want: bool = MA.in_range(n.global_position, float(n.get_meta(MA.META_RADIUS, 0.0)) * n.scale.x, eye)
				var running: bool = by_root[n].running if by_root.has(n) else p.active
				if n.visible != want or running != want:
					wrong += 1
	_check(wrong == 0, "r647: over %d eyes around the 2,020 edge, 48 objects in 8 sectors, the per-sector decision matches the per-object test (%d wrong)" % [trials, wrong])
	if "sectors_viewed" in driver:
		# The work the bounds save: a camera held still costs no test at
		# all, and sectors wholly out of range whose objects are already
		# off are not view-tested.
		driver.tick(Vector3(480, 0, 320), [])
		driver.tick(Vector3(480, 0, 320), [])
		_check(driver.sectors_viewed == 0 and driver.objects_tested == 0,
			"r647: a camera held still re-tests nothing (viewed %d, tested %d)" % [driver.sectors_viewed, driver.objects_tested])
		driver.tick(Vector3(480, 0, 9000), [])
		driver.tick(Vector3(480, 0, 9001), [])
		_check(driver.sectors_viewed == 0, "r647: sectors all out of range and already off are not view-tested (viewed %d)" % driver.sectors_viewed)
		driver.tick(Vector3(480, 0, 330), [])
		driver.tick(Vector3(480, 0, 331), [])
		_check(driver.objects_tested == 0 and driver.sectors_viewed > 0,
			"r647: sectors all in range, as last frame, are view-tested but their objects are not (viewed %d, tested %d)" % [
				driver.sectors_viewed, driver.objects_tested])
	holder.queue_free()
	await process_frame

## World3D: a zone change (the grid cleared) resets the driver, and a region
## streaming out takes its objects out of it.
func _test_world_resets(MA, template: Node3D) -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S == null:
		return
	var w: Node = S.new()
	var region := Node3D.new()
	region.name = "RealMapObjects_97_168"
	root.add_child(region)
	await process_frame
	var drv = w.get("_map_animations")
	var obj := _place(template, region, Vector3(100, 0, 100))
	drv.add(obj, false)
	(w.get("_object_containers") as Dictionary)["_97_168"] = region
	w.call("_release_region_objects", "_97_168")
	_check(drv.size() == 0, "r647: a region streaming out takes its animated objects out of the driver (got %d registered)" % drv.size())
	region.queue_free()
	await process_frame

	# A zone change: the old zone's objects are still registered when the
	# grid is cleared, and the new zone's object lands on the same spot.
	var old_zone := Node3D.new()
	root.add_child(old_zone)
	await process_frame
	var old_obj := _place(template, old_zone, Vector3(100, 0, 100))
	drv.add(old_obj, false)
	drv.tick(Vector3(160, 0, 600), [])
	w.call("_clear_region_grid")
	_check(drv.size() == 0 and drv.running == 0, "r647: a zone change resets the driver (got %d registered, %d running)" % [drv.size(), drv.running])
	var new_zone := Node3D.new()
	root.add_child(new_zone)
	await process_frame
	var new_obj := _place(template, new_zone, Vector3(100, 0, 100))
	drv.add(new_obj, false)
	_check(drv.size() == 1, "r647: the new zone's object is the only one registered, in a sector of its own (got %d)" % drv.size())
	old_zone.queue_free()
	new_zone.queue_free()
	w.free()
	await process_frame

## Round 685: a driver that goes (its World3D freed) or resets (a zone
## change) lets its objects, sectors and pose groups go too. Each Obj names
## its Sector and PoseGroup and they list it back -- RefCounted cycles that
## outlived the driver: every front-end backdrop freed left +559 objects and
## +1.3 MB (MEASURED, client/tools/measure_create_cycles.gd).
func _test_driver_frees(MA, template: Node3D) -> void:
	for how in ["dropped", "reset"]:
		var holder := Node3D.new()
		root.add_child(holder)
		var poses := Node3D.new()
		root.add_child(poses)
		await process_frame
		var drv = MA.Driver.new()
		drv.pose_parent = poses
		for i in range(3):
			drv.add(_place(template, holder, Vector3(100 + i, 0, 100)), false)
		drv.tick(Vector3(160, 0, 600), [])
		await process_frame
		drv.tick(Vector3(160, 0, 600), [])
		var refs: Array = []
		for o in drv.objects():
			refs.append(weakref(o))
			if o.sector != null and refs.size() == 1:
				refs.append(weakref(o.sector))
			if o.group != null and refs.size() <= 2:
				refs.append(weakref(o.group))
		var grouped: bool = drv.groups > 0
		if how == "reset":
			drv.reset()
		else:
			drv = null
		await process_frame
		var alive := 0
		for r in refs:
			if (r as WeakRef).get_ref() != null:
				alive += 1
		_check(refs.size() >= 4 and grouped and alive == 0,
			"r685: a driver %s frees its objects, sectors and pose groups (%d tracked, %d still alive, groups formed %s)" % [how, refs.size(), alive, grouped])
		drv = null
		holder.queue_free()
		poses.queue_free()
		await process_frame

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
