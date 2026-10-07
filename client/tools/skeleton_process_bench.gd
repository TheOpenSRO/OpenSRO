extends SceneTree
## Round 757: what 18,035 skeletons cost the main loop when nothing poses them -- the 7,000-body
## lineup's count (bodies and their item skeletons) -- on any engine. Each is a duplicate of one
## 49-bone template, as the client builds bodies. Two markers at the ends of the physics and
## process orders time every callback between them, in three phases: as Godot leaves them, with
## Skeleton3DBuilder.no_physics_step's change, and with the internal process off too.
##
##   remote_godot.sh script res://tools/skeleton_process_bench.gd
##   (or any Godot binary: --headless --path <a project> --script <this file>)
##
## MEASURED (round 757): 4.2.2 as built 5.15 ms of physics callbacks a step, 0.002 after; 4.7.2
## 2.5 ms of process callbacks a frame and 38.5 ms of wall a frame, 6.9 with the internal process
## off. docs/rounds/r757.md, section 3.5.
const N := 18035
var skels: Array = []
var phys_us := 0
var proc_us := 0
var steps := 0
var frames := 0
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
		else:
			proc_us += now - _t_proc
			frames += 1
func _phase(label: String, secs: float) -> void:
	phys_us = 0; proc_us = 0; steps = 0; frames = 0
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < int(secs * 1e6):
		await process_frame
	print("BENCH %s %s: physics callbacks %.3f ms a step (%d steps), process callbacks %.3f ms a frame (%d frames)" % [
		Engine.get_version_info().string, label, float(phys_us) / 1000.0 / maxf(steps, 1), steps, float(proc_us) / 1000.0 / maxf(frames, 1), frames])
func _initialize() -> void:
	var a := Mark.new(); a.bench = self; a.process_priority = -1000000; a.process_physics_priority = -1000000
	var b := Mark.new(); b.bench = self; b.last = true; b.process_priority = 1000000; b.process_physics_priority = 1000000
	root.add_child(a); root.add_child(b)
	var t := Skeleton3D.new()
	for i in range(49):
		t.add_bone("b%d" % i)
		if i > 0:
			t.set_bone_parent(i, i - 1)
	for i in range(N):
		var s := t.duplicate() as Skeleton3D
		root.add_child(s)
		skels.append(s)
	await process_frame
	await _phase("as built", 3.0)
	for s in skels:
		if "animate_physical_bones" in s:
			s.set("animate_physical_bones", false)
		s.set_physics_process_internal(false)
	await _phase("no_physics_step", 3.0)
	for s in skels:
		s.set_process_internal(false)
	await _phase("no internal process either", 3.0)
	quit()
