extends SceneTree
## Round 757: what 18,035 skeletons cost the main loop when nothing poses them -- the 7,000-body
## lineup's count (bodies and their item skeletons) -- on any engine. Each is a duplicate of one
## 49-bone template, as the client builds bodies. Two markers at the ends of the physics and
## process orders time every callback between them, in phases: as Godot leaves them, with round
## 757's no_physics_step (the physics callback off), with the internal process off by hand, and
## (round 760) with Skeleton3DBuilder.no_physics_step as it is now, on a fresh set duplicated
## from a template it was applied to (as the client builds them); in that phase 100 of them are
## posed every frame, and their attachments are checked to follow.
##
##   remote_godot.sh script res://tools/skeleton_process_bench.gd
##   (or any Godot binary: --headless --path <a project> --script <this file>)
##
## MEASURED (round 757): 4.2.2 as built 5.15 ms of physics callbacks a step, 0.002 after; 4.7.2
## 2.5 ms of process callbacks a frame and 38.5 ms of wall a frame, 6.9 with the internal process
## off. docs/rounds/r757.md, section 3.5; round 760: docs/rounds/r760.md.
const N := 18035
const POSED := 100
var skels: Array = []
var phys_us := 0
var proc_us := 0
var steps := 0
var frames := 0
var posing: Array = []
var pose_angle := 0.0
var attachments: Array = []
class Mark extends Node:
	var bench
	var last := false
	func _physics_process(_d: float) -> void:
		bench.mark(true, last)
	func _process(_d: float) -> void:
		bench.mark(false, last)
var _t_phys := 0
var _t_proc := 0
func mark(physics: bool, last: bool) -> void:
	var now := Time.get_ticks_usec()
	if physics:
		if not last:
			_t_phys = now
		else:
			phys_us += now - _t_phys
			steps += 1
	else:
		if not last:
			_t_proc = now
			if not posing.is_empty():
				pose_angle += 0.1
				for s in posing:
					(s as Skeleton3D).set_bone_pose_rotation(0, Quaternion(Vector3.UP, pose_angle))
		else:
			proc_us += now - _t_proc
			frames += 1
func _phase(label: String, secs: float) -> void:
	phys_us = 0; proc_us = 0; steps = 0; frames = 0
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < int(secs * 1e6):
		await process_frame
	var wall := float(Time.get_ticks_usec() - t0) / 1000.0 / maxf(frames, 1)
	print("BENCH %s %s: physics callbacks %.3f ms a step (%d steps), process callbacks %.3f ms a frame (%d frames), wall %.2f ms a frame" % [
		Engine.get_version_info().string, label, float(phys_us) / 1000.0 / maxf(steps, 1), steps, float(proc_us) / 1000.0 / maxf(frames, 1), frames, wall])
func _template() -> Skeleton3D:
	var t := Skeleton3D.new()
	for i in range(49):
		t.add_bone("b%d" % i)
		if i > 0:
			t.set_bone_parent(i, i - 1)
			t.set_bone_rest(i, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)))
	for i in range(49):
		t.reset_bone_pose(i)
	return t
func _fill(t: Skeleton3D) -> void:
	for s in skels:
		s.queue_free()
	skels = []
	await process_frame
	for i in range(N):
		var s := t.duplicate() as Skeleton3D
		root.add_child(s)
		skels.append(s)
	await process_frame
func _initialize() -> void:
	var a := Mark.new(); a.bench = self; a.process_priority = -1000000; a.process_physics_priority = -1000000
	var b := Mark.new(); b.bench = self; b.last = true; b.process_priority = 1000000; b.process_physics_priority = 1000000
	root.add_child(a); root.add_child(b)
	await _fill(_template())
	await _phase("as built", 3.0)
	for s in skels:
		if "animate_physical_bones" in s:
			s.set("animate_physical_bones", false)
		s.set_physics_process_internal(false)
	await _phase("r757 no_physics_step", 3.0)
	for s in skels:
		s.set_process_internal(false)
	await _phase("no internal process either", 3.0)
	var t := _template()
	Skeleton3DBuilder.no_physics_step(t)
	await _fill(t)
	t.free()
	var procs := 0
	for s in skels:
		if (s as Node).is_processing_internal() or (s as Node).is_physics_processing_internal():
			procs += 1
	print("BENCH r760 no_physics_step: %d of %d skeletons still process" % [procs, skels.size()])
	await _phase("r760 no_physics_step", 3.0)
	for i in range(POSED):
		var s: Skeleton3D = skels[i]
		var att := BoneAttachment3D.new()
		att.bone_name = "b1"
		s.add_child(att)
		attachments.append(att)
		posing.append(s)
	await _phase("r760 no_physics_step, %d posed a frame" % POSED, 3.0)
	# The pose of the last frame (set at its start) has reached every attachment by now.
	var want := Transform3D(Basis(Quaternion(Vector3.UP, pose_angle)), Vector3.ZERO) * Vector3(1, 0, 0)
	var bad := 0
	for att in attachments:
		if (att as Node3D).global_transform.origin.distance_to(want) > 0.001:
			bad += 1
	print("BENCH r760 posed attachments off their bone: %d of %d" % [bad, attachments.size()])
	quit()
