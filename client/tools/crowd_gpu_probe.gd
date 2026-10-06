extends SceneTree

## Dev tool (round 747, crowd scale A5; docs/protocol/crowd_gpu.md section 5,
## item 1): does a far body drawn by CrowdGpu -- a MultiMesh instance skinned
## in its vertex shader from the baked bone texture -- land where the near
## path's Skeleton3D and Godot's skinning pass put it?
##
## Bodies: Figures of both races and sexes with their catalogue kit and a
## weapon (and shield) at +13 (the glow, EquipGlow's shader), at Volume 0, 2
## and 4 (scale bytes 0x02, 0x22, 0x44), standing and running, in a row.
##
## --mode=cpu (headless: remote_godot.sh script res://tools/crowd_gpu_probe.gd
##   -- --pk2=... --media=... --mode=cpu): each body posed by the near path
##   (MonsterCrowd.pose_at, A3's baked frame) and every visible vertex skinned
##   on the CPU from the body's own skins (the sum Godot's pass makes), against
##   CrowdGpu.cpu_skin (the vertex shader's arithmetic on the textures' data).
##   The worst distance is printed; over 1e-3 units is `PARITY FAIL`.
## --mode=pixels (a GPU: xwl_run.sh ... --rendering-method forward_plus, or
##   xvfb-run + vglrun ... --rendering-driver opengl3 for Compatibility): the
##   same row drawn by the near path, then by CrowdGpu, at the same clip
##   times, each frame saved as <out>/<renderer>_<near|far>_<t>.png for
##   client/tools/frame_ab.py. Draw calls and objects of each frame are
##   printed. A shader that fails to compile shows as `SHADER ERROR` in the log.
##
##   --pk2=<Data.pk2> --media=<Media.pk2> [--out=/var/tmp/<lane>] [--count=8]
##   [--times=0.37,1.13] [--action=run|stand] [--mode=cpu|pixels]

var _fails := 0
var _appearance: CharacterAppearance
var _crowd: CrowdGpu
var _rows: Array = []   # [holder, skeleton, anim, phase, label]
var _cam: Camera3D
var _world: Node3D

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _expect(cond: bool, msg: String) -> void:
	if cond:
		print("ok   " + msg)
	else:
		print("PARITY FAIL " + msg)
		_fails += 1

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--mode=cpu|pixels]")
		quit(2)
		return
	_appearance = CharacterAppearance.from_archives(data, media)
	_appearance.canonical = true
	_world = Node3D.new()
	root.add_child(_world)
	_cam = Camera3D.new()
	_world.add_child(_cam)
	_crowd = CrowdGpu.new(root.find_world_3d().scenario)
	_build_row(int(_arg("--count", "8")), _arg("--action", "run"))
	if _arg("--mode", "cpu") == "pixels":
		_pixels.call_deferred()
	else:
		_cpu.call_deferred()

func _build_row(count: int, action: String) -> void:
	var cat := _appearance.catalog()
	var scales := [0x22, 0x02, 0x44]
	var type := BsrReader.AnimationEntry.TYPE_RUN if action == "run" else BsrReader.AnimationEntry.TYPE_STAND
	var i := 0
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			var figs := cat.figures(r, s)
			var nweap := cat.weapons(r, s).size()
			for k in range(2):
				if i >= count or figs.is_empty():
					break
				var fig: CharCatalog.Entry = figs[(k * 5) % figs.size()]
				var kit := cat.sample_kit(r, s, (i * 3) % maxi(nweap, 1))
				for item in kit:
					var slot := CharacterAppearance.visual_slot(_item_types(item["id"]))
					if slot == CharacterAppearance.SLOT_WEAPON or slot == CharacterAppearance.SLOT_SHIELD:
						item["plus"] = 13
				var scale: int = scales[i % scales.size()]
				var body := _appearance.build(fig.id, scale, kit)
				if body == null:
					_expect(false, "Figure %d builds" % fig.id)
					continue
				var anim := _appearance.animation_for(body, type)
				var skel := body.skeleton
				body.remove_child(skel)
				skel.scale = body.scale
				body.free()
				var holder := Node3D.new()
				holder.set_meta("character_id", 9000 + i)
				holder.position = Vector3(float(i) * 14.0, 0.0, 0.0)
				holder.rotation.y = 0.35 * float(i)
				skel.rotation.y = PI
				holder.add_child(skel)
				_world.add_child(holder)
				# What MonsterCrowd.CullCache does for another player's skeleton:
				# posed from A3's baked frames.
				skel.set_meta(CrowdAnim.META_CACHED, true)
				_rows.append([holder, skel, anim, 0.37 * float(i), "%s 0x%02x %s" % [fig.code, scale, action]])
				i += 1
	var mid := float(maxi(_rows.size() - 1, 0)) * 7.0
	_cam.position = Vector3(mid, 14.0, 95.0)
	_cam.look_at(Vector3(mid, 9.0, 0.0))
	_cam.fov = 50.0
	print("PROBE: %d bodies" % _rows.size())

func _item_types(id: int) -> PackedInt32Array:
	var info: Dictionary = _appearance._item_info(id)
	return info.get("type_ids", PackedInt32Array())

func _times() -> Array:
	var out: Array = []
	for t in _arg("--times", "0.37,1.13").split(",", false):
		out.append(float(t))
	return out

func _near(t: float) -> void:
	_crowd.release_all()
	_crowd.flush(t)
	for r in _rows:
		var skel: Skeleton3D = r[1]
		skel.visible = true
		MonsterCrowd.pose_at(skel, r[2], t + float(r[3]), true)

func _far(t: float) -> int:
	var added := 0
	for r in _rows:
		var entry := [r[1], r[2], 2, r[3], true, 0.0, null]
		if not _crowd.can_draw(r[1], entry):
			_crowd.bake_all()
		if _crowd.add(r[0], r[1], entry, t):
			added += 1
	_crowd.bake_all()
	_crowd.flush(t)
	return added

# --- cpu ---------------------------------------------------------------------------

## The near path's vertices of every visible part, in the world, from the
## body's own skins: a mesh skinned to the body at the skeleton's global
## transform, one hung from a BoneAttachment3D (skinned to its item's own
## skeleton, or rigid) at its own global transform.
func _near_vertices(skel: Skeleton3D) -> Array:
	skel.get_bone_global_pose(0)
	var out: Array = []
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not CrowdGpu._shown_under(mi, skel) or mi.mesh == null:
			continue
		var arr := mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var pts := PackedVector3Array()
		var target: Node = mi.get_node_or_null(mi.skeleton) if mi.skin != null else null
		var xf: Array[Transform3D] = []
		var sk := target as Skeleton3D
		if sk != null:
			sk.get_bone_global_pose(0)
			for i in range(mi.skin.get_bind_count()):
				xf.append(sk.get_bone_global_pose(mi.skin.get_bind_bone(i)) * mi.skin.get_bind_pose(i))
		var place := skel.global_transform if target == skel else mi.global_transform
		var bones = arr[Mesh.ARRAY_BONES]
		var weights = arr[Mesh.ARRAY_WEIGHTS]
		var per := int(bones.size() / v.size()) if bones != null and not xf.is_empty() else 0
		for k in range(v.size()):
			var p := v[k]
			if per > 0:
				var sp := Vector3.ZERO
				for j in range(per):
					var w: float = weights[k * per + j]
					if w > 0.0:
						sp += (xf[int(bones[k * per + j])] * p) * w
				p = sp
			pts.append(place * p)
		out.append(pts)
	return out

func _cpu() -> void:
	await process_frame
	var worst := 0.0
	var vertices := 0
	for t in _times():
		_near(t)
		var near: Array = []
		for r in _rows:
			near.append(_near_vertices(r[1]))
		var added := _far(t)
		_expect(added == _rows.size(), "t=%.2f: %d of %d bodies drawn far" % [t, added, _rows.size()])
		for i in range(_rows.size()):
			var r: Array = _rows[i]
			var far := _crowd.cpu_skin(r[1], t)
			var n: Array = near[i]
			if far.size() != n.size():
				_expect(false, "%s: %d parts far, %d near" % [r[4], far.size(), n.size()])
				continue
			var body_worst := 0.0
			for p in range(n.size()):
				var a: PackedVector3Array = n[p]
				var b: PackedVector3Array = far[p]
				if a.size() != b.size():
					_expect(false, "%s part %d: %d vertices far, %d near" % [r[4], p, b.size(), a.size()])
					continue
				for k in range(a.size()):
					body_worst = maxf(body_worst, a[k].distance_to(b[k]))
				vertices += a.size()
			print("PROBE cpu t=%.2f %s: %d parts, worst %.6f units" % [t, r[4], n.size(), body_worst])
			worst = maxf(worst, body_worst)
	_expect(worst < 1e-3, "A5 cpu: %d vertices, near (Godot's skin sum) against far (the shader's arithmetic): worst %.6f units" % [vertices, worst])
	print("PROBE crowd: %s" % _crowd.describe())
	_finish()

# --- pixels ------------------------------------------------------------------------

func _pixels() -> void:
	var out := _arg("--out", "/var/tmp/crowd_gpu_probe")
	DirAccess.make_dir_recursive_absolute(out)
	var renderer := String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))
	if RenderingServer.get_rendering_device() == null:
		renderer = "gl_compatibility"
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	# The glow's clock (EquipGlow._tick_clock, every process frame) held still,
	# so the two frames of a pair differ only by the path that drew them:
	# connected after EquipGlow's, it runs after it.
	process_frame.connect(func() -> void: RenderingServer.global_shader_parameter_set(EquipGlow.CLOCK_GLOBAL, 1.0))
	for i in range(4):
		await process_frame
	for t in _times():
		_near(t)
		await _settle()
		_save(out, renderer, "near", t)
		var added := _far(t)
		await _settle()
		_save(out, renderer, "far", t)
		print("PROBE pixels t=%.2f: %d of %d bodies far; %s" % [t, added, _rows.size(), _crowd.describe()])
	_finish()

func _settle() -> void:
	for i in range(3):
		await process_frame
	await RenderingServer.frame_post_draw

func _save(out: String, renderer: String, side: String, t: float) -> void:
	var img := root.get_texture().get_image()
	var path := "%s/%s_%s_%.2f.png" % [out, renderer, side, t]
	img.save_png(path)
	print("PROBE frame %s draws=%d objects=%d prims=%d" % [path,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))])

func _finish() -> void:
	_crowd.release_all()
	_crowd = null
	_appearance.free_templates()
	print("RESULT: %s (%d failing)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0)
