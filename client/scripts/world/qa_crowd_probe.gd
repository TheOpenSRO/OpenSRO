extends Node
class_name QaCrowdProbe

## QA only (round 736): the crowd's cost split. QaLineup spawns N other-player
## bodies through World3D._spawn_or_update_other (the path a server's
## OpEntityEntered takes); this node then steps through a list of switches, one
## at a time, and prints one `QA CROWD` line per step: the frame time and what
## the engine says the frame went on, with that one part of every lineup body
## switched off. Never runs in play: QaLineup makes it only when
## OPENSRO_QA_CROWD_STEPS is set.
##
##   OPENSRO_QA_CROWD_STEPS="base,pose,sound,mesh,labels,collide,fx,shadow,
##                           blobs,overlay,run,move,gone,base"
##   OPENSRO_QA_CROWD_SECONDS=<s>    each step's length (6); its first SETTLE
##                                   seconds are not measured
##   OPENSRO_QA_CROWD_QUIT=1         quit after the last step
##   OPENSRO_QA_CROWD_DELAY=<s>      wait before the first step (4: the bodies'
##                                   2 s appear fade and the build's hitch pass)
##
## The switches (each applies to the lineup bodies only, unless said):
##   base     nothing off
##   pose     no clip posed (World3D's _qa_split_off "pose": the player and the
##            NPCs too -- a few dozen bodies, the same in every step)
##   sound    no clip sound track advanced (the same caveat)
##   mesh     every MeshInstance3D of the bodies hidden (still posed)
##   labels   the name plates off every layer
##   collide  the click bodies out of the tree
##   fx       the EquipFx driver stopped and its holders hidden
##   shadow   no body casts a shadow-map shadow (only shows under Detail)
##   blobs    the bodies out of CharacterBlobs' group (Circle's ten nearest)
##   overlay  the OverlayView SubViewport (the plates' second render) stopped
##            -- every overlay, not the bodies' only
##   run      every body plays its run loop in place (a different clip)
##   move     every body walks to a new spot within 8 units every second
##   net      every body sent a position packet once a second (OPENSRO_QA_CROWD_NET_RATE
##            a body a second, 1; `net20` sends 20 a body a second), through NetClient's own dispatch: the client's
##            share of a moving crowd's traffic (decode, handler, turn, walk)
##   away     the camera turned 180 degrees: the crowd behind it, none in view
##            (what an off-screen crowd costs)
##   gone     every body out of the tree (kept in memory): the scene without them
##   nodraw   mesh + labels + fx + blobs + overlay together
##   ab       (round 747) the same frame drawn with A5 on, then off: the clip,
##            glow and texture clocks held, EquipFx's particles hidden, each
##            frame saved to OPENSRO_QA_CROWD_SHOTS (ab_<n>_gpu.png, then
##            ab_<n>_gpu2.png on the same path as many frames later -- the
##            noise floor -- then ab_<n>_near.png)
##            with the near and far bodies' screen boxes printed (`QA CROWD ab`)
##            for client/tools/frame_ab.py
##   anim=<s> (round 738) CrowdAnim's switches for the step, back on after it:
##            "1" A1 (pose only what is in view), "i" the indexed pose, "3" A3
##            (baked poses), "4" A4 (the far bodies' LOD); "anim=-" all off,
##            which poses another player exactly as before the round. The
##            skins (A2) are the boot's (OPENSRO_QA_CROWD_SKINS=own: per piece)

const SETTLE := 1.5

var world: Node
var bodies: Array = []        # [{id, node}]
var steps: PackedStringArray = PackedStringArray()
var seconds := 6.0
var quit := false
var delay := 4.0

var _i := -1
var _t := 0.0
var _on := false
var _acc := {}
var _last_us := 0
var _frame_ms: PackedFloat32Array = PackedFloat32Array()
var _removed: Dictionary = {}  # node -> [parent, child] for collide / gone
var _homes: Dictionary = {}    # id -> Vector3
var _hidden_meshes: Array = []  # the meshes the mesh switch hid
var _shadowed: Array = []  # [mesh, its cast_shadow] the shadow switch turned off
var _move_t := 0.0
var _rng := RandomNumberGenerator.new()
var _net_due := 0.0
var _net_next := 0
var _net_us := 0
var _net_sent := 0
var net_rate := 1.0
## The switches the boot started with (CrowdAnim.switches()), given back after
## each `anim=` step (round 747: "5" is A5, CrowdGpu).
var _boot_switches := ""

static func wanted() -> bool:
	return OS.get_environment("OPENSRO_QA_CROWD_STEPS") != ""

## Round 739: the arrival, measured from the spawn (QaLineup's start) until
## the last body is dressed (World3D._pump_other_builds): one `QA CROWD
## arrival` line with every frame's wall time in it -- the worst, the p95, how
## many were over 100 ms -- before the census and the steps.
var _arriving := true
var _arrival_last_us := 0
var _arrival_start_us := 0
var _arrival_ms: PackedFloat32Array = PackedFloat32Array()

func setup(w: Node, lineup_bodies: Array, spawn_usec: int = 0) -> void:
	world = w
	_arrival_start_us = spawn_usec if spawn_usec > 0 else Time.get_ticks_usec()
	_arrival_last_us = _arrival_start_us
	for b in lineup_bodies:
		var node: Node3D = world._other_bodies.get(b["id"])
		if node != null:
			bodies.append({"id": b["id"], "node": node})
			_homes[b["id"]] = node.position
	steps = OS.get_environment("OPENSRO_QA_CROWD_STEPS").split(",", false)
	var s := OS.get_environment("OPENSRO_QA_CROWD_SECONDS")
	if s.is_valid_float():
		seconds = maxf(float(s), SETTLE + 1.0)
	quit = OS.get_environment("OPENSRO_QA_CROWD_QUIT") != ""
	var nr := OS.get_environment("OPENSRO_QA_CROWD_NET_RATE")
	if nr.is_valid_float():
		net_rate = float(nr)
	var dl := OS.get_environment("OPENSRO_QA_CROWD_DELAY")
	if dl.is_valid_float():
		delay = float(dl)
	_rng.seed = 736
	_boot_switches = CrowdAnim.switches()
	RenderingServer.viewport_set_measure_render_time(world.get_viewport().get_viewport_rid(), true)
	# The pose and sound switches go through the frame split's own (round 664).
	if world._qa_split == null:
		world._qa_split = MonsterCrowd.Split.new(1 << 30)
	print("QA CROWD: %d bodies, steps %s, %.1f s each (%.1f settle), first after %.1f s" % [bodies.size(), ",".join(steps), seconds, SETTLE, delay])

## The arrival's frames (round 739), then the census once every body is dressed.
func _arrival_frame() -> void:
	var now := Time.get_ticks_usec()
	_arrival_ms.append(float(now - _arrival_last_us) / 1000.0)
	_arrival_last_us = now
	var queue = world.get("_other_builds")
	if queue != null and not queue.is_empty():
		return
	_arriving = false
	var sorted := _arrival_ms.duplicate()
	sorted.sort()
	var over := 0
	for v in sorted:
		if v > 100.0:
			over += 1
	print("QA CROWD arrival n=%d frames=%d seconds=%.2f worst_ms=%.1f p50=%.1f p95=%.1f over100=%d" % [
		bodies.size(), sorted.size(), float(now - _arrival_start_us) / 1e6, sorted[-1] if not sorted.is_empty() else 0.0,
		sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0,
		sorted[mini(int(sorted.size() * 0.95), sorted.size() - 1)] if not sorted.is_empty() else 0.0, over])
	_census()

## What one other player is made of, and how much of it is shared: one line
## for the first body and one for all of them.
func _census() -> void:
	var tot := {"nodes": 0, "meshes": 0, "visible_meshes": 0, "skinned": 0, "surfaces": 0, "shadow": 0, "skeletons": 0, "bones": 0,
		"labels": 0, "bodies3d": 0, "fx": 0, "multimesh": 0, "visible_materials": 0}
	var mats := {}
	var meshes := {}
	var skins := {}
	var first := ""
	for b in bodies:
		var c := {"nodes": 0, "meshes": 0, "visible_meshes": 0, "skinned": 0, "surfaces": 0, "shadow": 0, "skeletons": 0, "bones": 0,
			"labels": 0, "bodies3d": 0, "fx": 0, "multimesh": 0, "visible_materials": 0}
		# Round 739 (B5's write-up): the distinct materials among a body's
		# visible surfaces -- the draws a body would make if its meshes were
		# merged one per material.
		var own_mats := {}
		var stack: Array[Node] = [b["node"]]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			c["nodes"] += 1
			for ch in n.get_children():
				stack.append(ch)
			if n is Skeleton3D:
				c["skeletons"] += 1
				c["bones"] += (n as Skeleton3D).get_bone_count()
			elif n is MeshInstance3D:
				var mi := n as MeshInstance3D
				c["meshes"] += 1
				if mi.visible:
					c["visible_meshes"] += 1
				if mi.skin != null:
					c["skinned"] += 1
					skins[mi.skin.get_instance_id()] = true
				if mi.mesh != null:
					c["surfaces"] += mi.mesh.get_surface_count()
					meshes[mi.mesh.get_instance_id()] = true
					for i in mi.mesh.get_surface_count():
						var m := mi.get_active_material(i)
						if m != null:
							mats[m.get_instance_id()] = true
							if mi.visible:
								own_mats[m.get_instance_id()] = true
				if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and mi.visible:
					c["shadow"] += 1
			elif n is MultiMeshInstance3D:
				c["multimesh"] += 1
			elif n is Label3D:
				c["labels"] += 1
			elif n is CollisionObject3D:
				c["bodies3d"] += 1
			if n is EfpEffect:
				c["fx"] += 1
		c["visible_materials"] = own_mats.size()
		for k in c:
			tot[k] += c[k]
		if first == "":
			first = str(c)
	print("QA CROWD census: first body %s" % first)
	print("QA CROWD census: all %d bodies %s; distinct meshes %d, materials %d, skins %d" % [bodies.size(), str(tot), meshes.size(), mats.size(), skins.size()])
	# Round 738 (A2): what one pose of a body skeleton writes -- every bind of
	# every distinct skin registered on it (Godot 4.2.2 skeleton_3d.cpp:245-297).
	var regs := 0
	var binds := 0
	var posed_skels := 0
	var shown := false
	for b in bodies:
		for sk in (b["node"] as Node).find_children("*", "Skeleton3D", true, false):
			var on := {}
			for mi in CharacterAppearance._skinned_to(sk as Skeleton3D):
				if not on.has(mi.skin):
					on[mi.skin] = []
				(on[mi.skin] as Array).append(String(mi.name))
			if (sk as Skeleton3D).has_meta(MonsterCrowd.META_LAYOUT):
				posed_skels += 1
				regs += on.size()
				for skin in on:
					binds += (skin as Skin).get_bind_count()
				if not shown:
					shown = true
					var parts := PackedStringArray()
					for skin in on:
						parts.append("%d binds: %s" % [(skin as Skin).get_bind_count(), ",".join(PackedStringArray(on[skin]))])
					print("QA CROWD census: the first body skeleton's skins (%d bones): %s" % [(sk as Skeleton3D).get_bone_count(), " | ".join(parts)])
	print("QA CROWD census: body skeletons %d, skins registered on them %d (%.1f a body), binds written per pose %d (%.1f a body)" % [
		posed_skels, regs, float(regs) / maxf(float(posed_skels), 1.0), binds, float(binds) / maxf(float(posed_skels), 1.0)])

func _next() -> void:
	if _i >= 0:
		_switch(steps[_i], false)
	_i += 1
	_t = 0.0
	_on = false
	if _i >= steps.size():
		print("QA CROWD DONE")
		set_process(false)
		if quit:
			world.get_tree().quit()
		return
	_switch(steps[_i], true)

func _process(delta: float) -> void:
	if world == null:
		return
	if _arriving:
		_arrival_frame()
		return
	if _i < 0:
		delay -= delta
		if delay <= 0.0:
			_next()
		return
	if _i >= steps.size():
		return
	_t += delta
	var now := Time.get_ticks_usec()
	if steps[_i].begins_with("net"):
		_net_step(delta, float(steps[_i].substr(3)) if steps[_i].substr(3).is_valid_float() else net_rate)
	if steps[_i] == "move":
		_move_t += delta
		if _move_t >= 1.0:
			_move_t = 0.0
			_scatter()
	if not _on and _t >= SETTLE:
		_on = true
		_frame_ms = PackedFloat32Array()
		_acc = {"frames": 0, "cpu": 0.0, "gpu": 0.0, "proc": 0.0, "phys": 0.0, "draws": 0, "objects": 0, "prims": 0,
			"pose_us": world._qa_split.pose_usec, "sound_us": world._qa_split.sound_usec,
			"idle_us": world._qa_split.idle_usec, "minimap_us": world._qa_split.minimap_usec, "posed": world._qa_split.posed,
			"crowd_us": world._qa_split.crowd_usec, "others_us": world._qa_split.others_usec,
			"steps": world._qa_split.steps, "start_us": now, "net_us": _net_us, "net_sent": _net_sent}
		_last_us = now
		return
	if _on:
		var vp := world.get_viewport().get_viewport_rid()
		_frame_ms.append(float(now - _last_us) / 1000.0)
		_last_us = now
		_acc["frames"] += 1
		_acc["cpu"] += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		_acc["gpu"] += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		_acc["proc"] += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_acc["phys"] += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_acc["draws"] += int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_acc["objects"] += int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		_acc["prims"] += int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	if _t >= seconds:
		_report()
		_next()

func _report() -> void:
	var f := maxf(float(_acc.get("frames", 0)), 1.0)
	var wall := float(Time.get_ticks_usec() - int(_acc["start_us"])) / 1000.0 / f
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var p50 := sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0
	var p95 := sorted[mini(int(sorted.size() * 0.95), sorted.size() - 1)] if not sorted.is_empty() else 0.0
	var sp: MonsterCrowd.Split = world._qa_split
	var cam: Camera3D = world.get_viewport().get_camera_3d()
	var in_view := 0
	for b in bodies:
		var n: Node3D = b["node"]
		if cam != null and is_instance_valid(n) and n.is_inside_tree() and cam.is_position_in_frustum(n.global_position + Vector3(0, 8, 0)):
			in_view += 1
	var fx_line := ""
	var vp0 := world.get_viewport()
	if vp0.has_meta(EquipFx.DRIVER_META) and is_instance_valid(vp0.get_meta(EquipFx.DRIVER_META)):
		var d: EquipFx = vp0.get_meta(EquipFx.DRIVER_META)
		fx_line = " fx_hosts=%d fx_shown=%d fx_kinds=%d" % [int(d.stats["hosts"]), int(d.stats["shown"]), int(d.stats["kinds"])]
	var gpu_line := ""
	var crowd = world.get("_crowd_gpu")
	if crowd != null:
		gpu_line = " gpu: " + (crowd as CrowdGpu).describe() + " gpu_ms=%.2f" % (float(sp.crowd_usec - int(_acc["crowd_us"])) / 1000.0 / f)
	gpu_line += " others_ms=%.2f" % (float(sp.others_usec - int(_acc["others_us"])) / 1000.0 / f)
	print("QA CROWD step %-8s n=%d in_view=%d frames=%d frame_ms=%.2f p50=%.2f p95=%.2f render_cpu_ms=%.2f render_gpu_ms=%.2f process_ms=%.2f physics_ms=%.2f idle_ms=%.2f pose_ms=%.2f sound_ms=%.2f minimap_ms=%.2f posed_per_frame=%.0f steps_per_frame=%.2f draws=%d objects=%d prims=%d nodes=%d anim=%s baked=%d static_mb=%.1f%s%s" % [
		steps[_i], bodies.size(), in_view, int(f), wall, p50, p95,
		_acc["cpu"] / f, _acc["gpu"] / f, _acc["proc"] / f, _acc["phys"] / f,
		float(sp.idle_usec - int(_acc["idle_us"])) / 1000.0 / f,
		float(sp.pose_usec - int(_acc["pose_us"])) / 1000.0 / f,
		float(sp.sound_usec - int(_acc["sound_us"])) / 1000.0 / f,
		float(sp.minimap_usec - int(_acc["minimap_us"])) / 1000.0 / f,
		float(sp.posed - int(_acc["posed"])) / f,
		float(sp.steps - int(_acc["steps"])) / f,
		int(_acc["draws"] / f), int(_acc["objects"] / f), int(_acc["prims"] / f),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), CrowdAnim.switches(), CrowdAnim.baked_frames,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, fx_line, gpu_line])
	if steps[_i].begins_with("net"):
		var sent := _net_sent - int(_acc["net_sent"])
		print("QA CROWD net: %d packets in %d frames, %.2f ms a frame in NetClient._dispatch, %.1f us a packet" % [
			sent, int(f), float(_net_us - int(_acc["net_us"])) / 1000.0 / f, float(_net_us - int(_acc["net_us"])) / maxf(float(sent), 1.0)])

func _meshes(node: Node) -> Array:
	return node.find_children("*", "MeshInstance3D", true, false)

func _switch(step: String, off: bool) -> void:
	if step.begins_with("net"):
		step = "net"
	if step.begins_with("anim="):
		CrowdAnim.set_switches(step.substr(5) if off else _boot_switches)
		return
	match step:
		"pose", "sound":
			var arr: PackedStringArray = world._qa_split_off
			if off and not arr.has(step):
				arr.append(step)
			elif not off and arr.has(step):
				arr.remove_at(arr.find(step))
			world._qa_split_off = arr
		"mesh":
			# Only the meshes that were showing: a body hides the parts its
			# armour covers (CharacterAppearance), and those stay hidden.
			if off:
				_hidden_meshes.clear()
				for b in bodies:
					for mi in _meshes(b["node"]):
						if (mi as MeshInstance3D).visible:
							(mi as MeshInstance3D).visible = false
							_hidden_meshes.append(mi)
			else:
				for mi in _hidden_meshes:
					if is_instance_valid(mi):
						(mi as MeshInstance3D).visible = true
				_hidden_meshes.clear()
		"labels":
			for b in bodies:
				var plate := (b["node"] as Node).get_node_or_null("Name") as VisualInstance3D
				if plate != null:
					plate.layers = 0 if off else OverlayView.BIT
		"collide":
			for b in bodies:
				var n: Node3D = b["node"]
				if off:
					var click := n.get_node_or_null("PlayerClickBody")
					if click != null:
						n.remove_child(click)
						_removed[click] = n
				else:
					for c in _removed.keys():
						if _removed[c] == n:
							n.add_child(c)
							_removed.erase(c)
		"fx":
			var vp := world.get_viewport()
			if vp.has_meta(EquipFx.DRIVER_META) and is_instance_valid(vp.get_meta(EquipFx.DRIVER_META)):
				var d: EquipFx = vp.get_meta(EquipFx.DRIVER_META)
				d.process_mode = Node.PROCESS_MODE_DISABLED if off else Node.PROCESS_MODE_INHERIT
				for k in d._kinds.values():
					(k.master as Node).set_process(not off)
				for h in d._hosts.values():
					if h.holder != null and is_instance_valid(h.holder):
						h.holder.visible = false if off else h.holder.visible
		"shadow":
			# Only what was casting, and only that given back (round 739: the
			# first version turned every mesh's shadow on after, the EquipFx
			# particles' and Detail's switched-off ones included).
			if off:
				_shadowed.clear()
				for b in bodies:
					for gi in (b["node"] as Node).find_children("*", "GeometryInstance3D", true, false):
						if (gi as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
							_shadowed.append([gi, (gi as GeometryInstance3D).cast_shadow])
							(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else:
				for pair in _shadowed:
					if is_instance_valid(pair[0]):
						(pair[0] as GeometryInstance3D).cast_shadow = pair[1]
				_shadowed.clear()
		"blobs":
			for b in bodies:
				var n: Node = b["node"]
				if off:
					n.remove_from_group(CharacterBlobs.GROUP)
				else:
					n.add_to_group(CharacterBlobs.GROUP)
		"overlay":
			var ov = world._overlay_view
			if ov != null and is_instance_valid(ov):
				(ov._viewport as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED if off else SubViewport.UPDATE_ALWAYS
		"run":
			for b in bodies:
				world._set_other_gait(b["id"], off)
		"move", "net":
			if step == "net":
				_net_due = 0.0
				if off:
					return
			if off:
				_move_t = 0.0
				_scatter()
			else:
				for b in bodies:
					world._other_body_targets[b["id"]] = _homes[b["id"]]
					(b["node"] as Node3D).position = _homes[b["id"]]
					world._set_other_gait(b["id"], false)
		"away":
			var arm: Node3D = world.camera_arm
			arm.rotation_degrees.y += 180.0 if off else -180.0
		"gone":
			for b in bodies:
				var n: Node3D = b["node"]
				if off:
					_removed[n] = n.get_parent()
					n.get_parent().remove_child(n)
				elif _removed.has(n):
					(_removed[n] as Node).add_child(n)
					_removed.erase(n)
		"nodraw":
			for s in ["mesh", "labels", "fx", "blobs", "overlay"]:
				_switch(s, off)
		"base":
			pass
		"ab":
			if off:
				_ab.call_deferred()
		_:
			push_warning("QA CROWD: unknown step %s" % step)

## The `ab` step (round 747): one frame with the far bodies on the GPU, one
## with every body on the full path, at the same held clocks.
var _ab_n := 0

func _ab() -> void:
	var dir := OS.get_environment("OPENSRO_QA_CROWD_SHOTS")
	if dir == "":
		dir = "/var/tmp/qa_crowd_ab"
	DirAccess.make_dir_recursive_absolute(dir)
	_ab_n += 1
	var tag := "ab_%d" % _ab_n
	var tree := world.get_tree()
	var hold := func() -> void: RenderingServer.global_shader_parameter_set(EquipGlow.CLOCK_GLOBAL, EquipGlow.clock)
	world._qa_anim_hold = true
	EquipGlow.hold = true
	TexAni.hold = true
	tree.process_frame.connect(hold)
	_switch("fx", true)
	for i in range(3):
		await tree.process_frame
	var boxes := _ab_boxes()
	await RenderingServer.frame_post_draw
	var a := world.get_viewport().get_texture().get_image()
	var pa := dir.path_join(tag + "_gpu.png")
	a.save_png(pa)
	# The noise floor: the same path again after as many frames -- what moves
	# anyway (the sky, the trees, the local player, who is not held).
	for i in range(3):
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var a2 := world.get_viewport().get_texture().get_image()
	a2.save_png(dir.path_join(tag + "_gpu2.png"))
	CrowdGpu.enabled = false
	for i in range(3):
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var b := world.get_viewport().get_texture().get_image()
	var pb := dir.path_join(tag + "_near.png")
	b.save_png(pb)
	print("QA CROWD ab %s far=%d near=%d far_box=%s near_box=%s files %s %s" % [tag, int(boxes[0]), int(boxes[1]),
		_box_arg(boxes[2]), _box_arg(boxes[3]), pa, pb])
	CrowdGpu.enabled = true
	_switch("fx", false)
	tree.process_frame.disconnect(hold)
	TexAni.hold = false
	EquipGlow.hold = false
	world._qa_anim_hold = false

## [far count, near count, far bodies' screen Rect2, near bodies' screen Rect2]:
## each body's feet and a point 20 units above, through the camera.
func _ab_boxes() -> Array:
	var cam: Camera3D = world.get_viewport().get_camera_3d()
	var crowd = world.get("_crowd_gpu")
	var far := Rect2()
	var near := Rect2()
	var nf := 0
	var nn := 0
	for b in bodies:
		var n: Node3D = b["node"]
		var gait: Dictionary = world._other_gaits.get(b["id"], {})
		if cam == null or not is_instance_valid(n) or gait.is_empty() or not cam.is_position_in_frustum(n.global_position):
			continue
		var p0 := cam.unproject_position(n.global_position)
		var p1 := cam.unproject_position(n.global_position + Vector3(0, 20, 0))
		var r := Rect2(p0, Vector2.ZERO).expand(p1).grow(8.0)
		if crowd != null and (crowd as CrowdGpu).has(gait["skeleton"]):
			far = r if nf == 0 else far.merge(r)
			nf += 1
		else:
			near = r if nn == 0 else near.merge(r)
			nn += 1
	return [nf, nn, far, near]

static func _box_arg(r: Rect2) -> String:
	return "%d,%d,%d,%d" % [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]

## The position packets due this frame, round robin over the bodies, each a
## new spot within 8 units of its home, through NetClient's own dispatch.
func _net_step(delta: float, rate: float) -> void:
	_net_due += delta * rate * bodies.size()
	var t0 := Time.get_ticks_usec()
	while _net_due >= 1.0 and not bodies.is_empty():
		_net_due -= 1.0
		var b: Dictionary = bodies[_net_next % bodies.size()]
		_net_next += 1
		var home: Vector3 = _homes[b["id"]]
		var payload := PackedByteArray()
		payload.resize(21)
		payload.encode_s64(0, int(b["id"]))
		payload.encode_float(8, home.x + _rng.randf_range(-8.0, 8.0))
		payload.encode_float(12, home.y)
		payload.encode_float(16, home.z + _rng.randf_range(-8.0, 8.0))
		payload[20] = 0
		NetClient._dispatch(Packet.new(WorldNet.OP_ENTITY_MOVED, payload))
		_net_sent += 1
	_net_us += Time.get_ticks_usec() - t0

## Every body to a new spot within 8 units of its home (the interpolation walks
## it there with its run loop, as a server's position update does).
func _scatter() -> void:
	for b in bodies:
		var home: Vector3 = _homes[b["id"]]
		world._other_body_targets[b["id"]] = home + Vector3(_rng.randf_range(-8.0, 8.0), 0.0, _rng.randf_range(-8.0, 8.0))
