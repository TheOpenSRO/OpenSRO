extends SceneTree

## Dev tool (round 738): the crowd's animation rules against the real archives
## (CrowdAnim, CharacterAppearance's shared skin). Headless:
##
##   client/tools/remote_godot.sh script res://tools/crowd_anim_probe.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2
##
## It measures:
## - **A2, the shared skin.** Every one of the 52 Figures, with the catalogue
##   kit and its race's weapons in rotation, at Volume 0, 2 and 4, built twice:
##   with the per-piece skins (`canonical` off, the old way) and with the one
##   shared skin. Both are posed with the same clip at the same time and every
##   visible skinned vertex is skinned on the CPU (the sum the GPU does); the
##   worst distance between the two builds' vertices is printed, and the skins
##   and binds each build registers on its body skeleton.
## - **A3, the quantum.** For every clip those bodies play standing and
##   running, the worst bone displacement (world units, through the skeleton's
##   chain, Height 1) between the exact pose and the baked one, at the worst
##   time (half a quantum from a frame); and the frames, tracks and moving
##   channels the clip bakes.
## - **A4, a frame's motion.** The worst bone displacement over 1/60 s and
##   1/30 s, and what that is in pixels at 300 and 900 units from the camera
##   (1080 lines, the 60 degree field of view of World3D.CAMERA_FOV_DEG).
## A failed A2 check (a vertex more than 1e-4 from where the per-piece skin
## put it) prints `PARITY FAIL`, which remote_godot.sh turns into exit 1.

var _fails := 0
var _shown_extra := false

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
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2>")
		quit(2)
		return
	var own := CharacterAppearance.from_archives(data, media)
	own.canonical = false
	own.glow_enabled = false
	var shared := CharacterAppearance.from_archives(data, media)
	shared.canonical = true
	shared.glow_enabled = false
	var clips := {}  # clip file path -> [ParsedAnimation, skeleton (a shared-skin body's), name]
	_measure_skins(own, shared, clips)
	_measure_clips(clips, shared)
	own.free_templates()
	shared.free_templates()
	print("RESULT: %s (%d failing)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0)

# --- A2 ---------------------------------------------------------------------------

## Every visible skinned vertex of the meshes skinned to `skel`, CPU-skinned,
## in the skeleton's space, in mesh order.
func _skin_all(skel: Skeleton3D) -> PackedVector3Array:
	Skeleton3DBuilder.refresh_global_poses(skel)
	var out := PackedVector3Array()
	for mi in CharacterAppearance._skinned_to(skel):
		if String(mi.name).ends_with("_front") or not mi.visible or not (mi.get_parent() as Node3D).visible:
			continue
		var skin: Skin = mi.skin
		var xf: Array[Transform3D] = []
		for i in range(skin.get_bind_count()):
			xf.append(skel.get_bone_global_pose(skin.get_bind_bone(i)) * skin.get_bind_pose(i))
		var arr := mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones = arr[Mesh.ARRAY_BONES]
		var weights = arr[Mesh.ARRAY_WEIGHTS]
		if bones == null or weights == null or v.is_empty():
			continue
		var per := int(bones.size() / v.size())
		for k in range(v.size()):
			var p := Vector3.ZERO
			for j in range(per):
				var w: float = weights[k * per + j]
				if w <= 0.0:
					continue
				p += (xf[int(bones[k * per + j])] * v[k]) * w
			out.append(p)
	return out

func _skin_census(skel: Skeleton3D) -> Vector2i:
	var on := {}
	for mi in CharacterAppearance._skinned_to(skel):
		on[mi.skin] = true
	var binds := 0
	for s in on:
		binds += (s as Skin).get_bind_count()
	return Vector2i(on.size(), binds)

func _measure_skins(own: CharacterAppearance, shared: CharacterAppearance, clips: Dictionary) -> void:
	var cat := shared.catalog()
	var worst := 0.0
	var vertices := 0
	var bodies := 0
	var own_skins := 0
	var own_binds := 0
	var shared_skins := 0
	var shared_binds := 0
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			var figs := cat.figures(r, s)
			var nweap := cat.weapons(r).size()
			for i in range(figs.size()):
				var kit := cat.sample_kit(r, s, i % maxi(nweap, 1))
				for scale in [0x02, 0x22, 0x44]:
					var a := own.build(figs[i].id, scale, kit)
					var b := shared.build(figs[i].id, scale, kit)
					if a == null or b == null:
						_expect(false, "Figure %d builds both ways" % figs[i].id)
						continue
					var body_worst := 0.0
					for action in [BsrReader.AnimationEntry.TYPE_STAND, BsrReader.AnimationEntry.TYPE_RUN]:
						var ca := own.animation_for(a, action)
						var cb := shared.animation_for(b, action)
						if ca == null or cb == null:
							continue
						var ckey: String = String(cb.get_meta(SkinnedBsrAssembler.CLIP_PATH_META, str(cb.get_instance_id())))
						if scale == 0x22 and not clips.has(ckey):
							var keep := b.skeleton.duplicate() as Skeleton3D
							for c in keep.get_children():
								keep.remove_child(c)
								c.free()
							clips[ckey] = [cb, keep, "%s %s %s" % [figs[i].code, b.weapon_group, "stand" if action == BsrReader.AnimationEntry.TYPE_STAND else "run"]]
						for t in [0.0, 0.37, 1.13]:
							Skeleton3DBuilder.apply_ban_pose_at(a.skeleton, ca, t, true)
							Skeleton3DBuilder.apply_ban_pose_at(b.skeleton, cb, t, true)
							var va := _skin_all(a.skeleton)
							var vb := _skin_all(b.skeleton)
							if va.size() != vb.size():
								_expect(false, "%s: the two builds skin %d and %d vertices" % [figs[i].code, va.size(), vb.size()])
								continue
							for k in range(va.size()):
								body_worst = maxf(body_worst, va[k].distance_to(vb[k]))
							vertices += va.size()
					worst = maxf(worst, body_worst)
					var ca2 := _skin_census(a.skeleton)
					var cb2 := _skin_census(b.skeleton)
					if cb2.x > 1 and not _shown_extra:
						_shown_extra = true
						for mi in CharacterAppearance._skinned_to(b.skeleton):
							if CharacterAppearance.canonical_base(mi.skin) == null:
								print("A2: %s scale 0x%02x: %s (under %s) keeps a skin of its own, %d binds" % [figs[i].code, scale, mi.name, mi.get_parent().name, mi.skin.get_bind_count()])
					own_skins += ca2.x
					own_binds += ca2.y
					shared_skins += cb2.x
					shared_binds += cb2.y
					bodies += 1
					if body_worst > 1e-4:
						_expect(false, "%s scale 0x%02x: a vertex is %s from the per-piece skin's" % [figs[i].code, scale, str(body_worst)])
					a.free()
					b.free()
	_expect(bodies == 156 and worst <= 1e-4, "A2: %d bodies (52 Figures x Volume 0/2/4), %d vertices skinned both ways under stand and run: worst distance %s units" % [bodies, vertices, str(worst)])
	print("A2: skins registered on a body skeleton: per piece %.2f (%.1f binds written per pose), shared %.2f (%.1f binds)" % [
		float(own_skins) / bodies, float(own_binds) / bodies, float(shared_skins) / bodies, float(shared_binds) / bodies])

# --- A3 / A4 ------------------------------------------------------------------------

## Every bone's global position, after the pose.
func _globals(skel: Skeleton3D) -> PackedVector3Array:
	Skeleton3DBuilder.refresh_global_poses(skel)
	var out := PackedVector3Array()
	for i in range(skel.get_bone_count()):
		out.append(skel.get_bone_global_pose(i).origin)
	return out

func _worst(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var w := 0.0
	for i in range(a.size()):
		w = maxf(w, a[i].distance_to(b[i]))
	return w

## The bone `_worst` found, and the worst displacement once the root bone's own
## move is taken out (the body's shape, not its place).
func _worst_bone(a: PackedVector3Array, b: PackedVector3Array) -> int:
	var w := -1.0
	var at := -1
	for i in range(a.size()):
		if a[i].distance_to(b[i]) > w:
			w = a[i].distance_to(b[i])
			at = i
	return at

func _worst_shape(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var w := 0.0
	for i in range(a.size()):
		w = maxf(w, (a[i] - a[0]).distance_to(b[i] - b[0]))
	return w

func _measure_clips(clips: Dictionary, shared: CharacterAppearance) -> void:
	var q := CrowdAnim.QUANTUM_MS / 1000.0
	var worst_q := 0.0
	var worst_q_name := ""
	var worst_60 := 0.0
	var worst_30 := 0.0
	var worst_60_name := ""
	var frames := 0
	var tracks := 0
	var mov_rot := 0
	var mov_pos := 0
	var by_name := {}
	var worst_q_bone := ""
	var worst_shape := 0.0
	for clip in clips:
		var anim: BanReader.ParsedAnimation = clips[clip][0]
		var keep: Skeleton3D = clips[clip][1]
		var exact := keep.duplicate() as Skeleton3D
		var baked := keep.duplicate() as Skeleton3D
		var fr := CrowdAnim.frames_for(baked, anim)
		frames += fr.count
		tracks += fr.bones.size()
		mov_rot += fr.moving_rot.size()
		mov_pos += fr.moving_pos.size()
		by_name[anim.animation_name] = true
		var clip_q := 0.0
		var clip_60 := 0.0
		var clip_30 := 0.0
		for f in range(fr.count):
			var t := (float(f) + 0.49) * q
			Skeleton3DBuilder.apply_ban_pose_at(exact, anim, t, true)
			var ge := _globals(exact)
			CrowdAnim.pose_cached(baked, anim, t, true)
			var gb := _globals(baked)
			var wq := _worst(ge, gb)
			if wq > clip_q:
				clip_q = wq
				if wq > worst_q:
					worst_q_bone = baked.get_bone_name(_worst_bone(ge, gb))
			worst_shape = maxf(worst_shape, _worst_shape(ge, gb))
			if f % 4 == 0:
				Skeleton3DBuilder.apply_ban_pose_at(exact, anim, t + 1.0 / 60.0, true)
				clip_60 = maxf(clip_60, _worst(ge, _globals(exact)))
				Skeleton3DBuilder.apply_ban_pose_at(exact, anim, t + 1.0 / 30.0, true)
				clip_30 = maxf(clip_30, _worst(ge, _globals(exact)))
		if clip_q > worst_q:
			worst_q = clip_q
			worst_q_name = clips[clip][2]
		if clip_60 > worst_60:
			worst_60 = clip_60
			worst_60_name = clips[clip][2]
		worst_30 = maxf(worst_30, clip_30)
		exact.free()
		baked.free()
		keep.free()
	var n := maxi(clips.size(), 1)
	print("A3: %d clips (%d distinct names) played standing and running by the 52 Figures; %d frames baked at %.2f ms (%.0f a clip), %.1f tracks a clip, %.1f moving rotations, %.1f moving positions" % [
		clips.size(), by_name.size(), frames, CrowdAnim.QUANTUM_MS, float(frames) / n, float(tracks) / n, float(mov_rot) / n, float(mov_pos) / n])
	var upp := func(d: float) -> float: return 2.0 * d * tan(deg_to_rad(30.0)) / 1080.0
	print("A3: worst bone displacement between the exact and the baked pose (half a quantum off a frame): %.4f units (%s, %s); %.2f px at 90 units from the camera, %.2f px at 30; with the root bone's own move taken out %.4f units (%.2f px at 90)" % [
		worst_q, worst_q_name, worst_q_bone, worst_q / upp.call(90.0), worst_q / upp.call(30.0), worst_shape, worst_shape / upp.call(90.0)])
	print("A4: worst bone displacement in 1/60 s: %.3f units (%s), in 1/30 s: %.3f; one pose skipped (a second frame) at 300 units moves a bone up to %.2f px, at 900 three skipped up to %.2f px (1080 lines, 60 degrees)" % [
		worst_60, worst_60_name, worst_30, worst_60 / upp.call(300.0), (worst_30 * 1.5) / upp.call(900.0)])
