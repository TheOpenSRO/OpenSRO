extends SceneTree

## Other players in a crowd (round 738, CrowdAnim; docs/protocol/crowd_scale.md
## lane A). Run headless on the render box: `client/tools/remote_godot.sh
## tests`. Synthetic data only: bare Skeleton3D nodes, hand-made clips and
## meshes, bodies placed by hand; no archive. The real-archive measurements
## (every Figure's skin, every clip's quantum error) are
## client/tools/crowd_anim_probe.gd's.
##
## What it holds the client to:
## - A2: the shared skin binds bone i to the inverse of its global rest (the
##   object-space bone to identity), a remapped mesh names skeleton bones
##   where it named palette entries, and the two skin every vertex to the
##   same place under a pose; Volume is a shared variant per scale that leaves
##   the base and every other body alone, and moves a vertex exactly as the
##   per-piece edit did;
## - A3: a baked frame is the exact pose at its time, a pose between frames is
##   the nearest frame's, a body that stays on a clip is given only the
##   channels the clip moves, and one that changes clip is given them all;
## - A4: the far bodies' bands apply only from 100 characters, and only past
##   900 from the camera;
## - A1 in the world's clip tick: another player is posed iff its sphere is in
##   the camera's frustum, the clock runs on while it is not, the doll is
##   posed whatever the camera does, and with every switch off every body is
##   posed by the old name-searched path, as before the round.
##
## NEGATIVES, on the base (3fc71af2): CrowdAnim and Skeleton3DBuilder's
## canonical_skin do not exist, so every rule check fails; and the world's
## tick poses every other player, in view or not (the A1 checks fail).

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
	var path := "res://scripts/world/crowd_anim.gd"
	_check(ResourceLoader.exists(path), "CrowdAnim exists")
	if ResourceLoader.exists(path) and Skeleton3DBuilder.new().has_method("canonical_skin"):
		_test_canonical_skin()
		_test_volume()
		_test_share_template()
		_test_sound_tags()
		_test_baked_pose()
		_test_lod_bands()
		var world := _make_world()
		if world != null:
			await process_frame
			_test_world_tick(world)
			_test_world_lod_and_range(world)
			root.remove_child(world)
			world.free()
	else:
		_check(false, "Skeleton3DBuilder.canonical_skin exists")
	CrowdAnim.set_switches("1i34")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- A2: one skin per body ----------------------------------------------------

## A body skeleton: Bip01, a spine turned 90 degrees about Z, a thigh, a calf.
func _body() -> Skeleton3D:
	var s := Skeleton3D.new()
	s.add_bone("Bip01")
	s.set_bone_rest(0, Transform3D(Basis(Vector3.UP, 0.3), Vector3(0, 1, 0)))
	s.add_bone("Bip01 Spine")
	s.set_bone_parent(1, 0)
	s.set_bone_rest(1, Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0), Vector3(0, 10, 0)))
	s.add_bone("Bip01 L Thigh")
	s.set_bone_parent(2, 0)
	s.set_bone_rest(2, Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(2, 8, 0)))
	s.add_bone("Bip01 L Calf")
	s.set_bone_parent(3, 2)
	s.set_bone_rest(3, Transform3D(Basis(Vector3(0, 0, 1), 0.2), Vector3(0, 6, 0)))
	for i in range(s.get_bone_count()):
		s.reset_bone_pose(i)
	Skeleton3DBuilder.refresh_global_poses(s)
	return s

## A skinned mesh whose palette is [calf, spine] (not the skeleton's order),
## with single, shared and object-space influences.
func _mesh() -> BmsReader.ParsedMesh:
	var m := BmsReader.ParsedMesh.new()
	m.bone_names = PackedStringArray(["Bip01 L Calf", "Bip01 Spine"])
	var verts: Array[BmsReader.Vertex] = []
	var specs := [[Vector3(2, 3, 0), 0, -1, 1.0], [Vector3(0, 12, 1), 1, -1, 1.0], [Vector3(1, 9, 0.5), 0, 1, 0.3],
		[Vector3(-1, 2, 2), BmsReader.OBJECT_SPACE, 1, 0.6]]
	for sp in specs:
		var v := BmsReader.Vertex.new()
		v.position = sp[0]
		v.normal = Vector3.UP
		v.bone0 = sp[1]
		v.bone1 = sp[2]
		v.weight0 = sp[3]
		v.weight1 = 1.0 - float(sp[3]) if int(sp[2]) != -1 else 0.0
		verts.append(v)
	m.vertices = verts
	m.object_space_vertices = 1
	m.indices = PackedInt32Array([0, 1, 2, 1, 2, 3])
	return m

## Every vertex of `mi` skinned on `s` as the GPU does it: the sum of
## weight x (bone global pose x bind) x vertex over its influences.
func _skinned(mi: MeshInstance3D, s: Skeleton3D) -> PackedVector3Array:
	Skeleton3DBuilder.refresh_global_poses(s)
	var out := PackedVector3Array()
	var arr := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var per := bones.size() / v.size()
	for k in range(v.size()):
		var p := Vector3.ZERO
		for j in range(per):
			var w := weights[k * per + j]
			if w <= 0.0:
				continue
			var b := bones[k * per + j]
			p += (s.get_bone_global_pose(mi.skin.get_bind_bone(b)) * mi.skin.get_bind_pose(b) * v[k]) * w
		out.append(p)
	return out

func _pose(s: Skeleton3D) -> void:
	s.set_bone_pose_rotation(1, Quaternion(Vector3(0.3, 1, 0).normalized(), 0.7))
	s.set_bone_pose_rotation(2, Quaternion(Vector3(1, 0, 0.2).normalized(), -0.9))
	s.set_bone_pose_rotation(3, Quaternion(Vector3(0, 0, 1), 1.1))
	s.set_bone_pose_position(0, Vector3(0.5, 1.5, -0.2))

func _test_canonical_skin() -> void:
	var s := _body()
	Skeleton3DBuilder._object_space_bone(s)
	var canon := Skeleton3DBuilder.canonical_skin(s)
	var binds_ok := canon.get_bind_count() == s.get_bone_count()
	for i in range(canon.get_bind_count()):
		if canon.get_bind_bone(i) != i or not canon.get_bind_pose(i).is_equal_approx(s.get_bone_global_rest(i).affine_inverse()):
			binds_ok = false
	_check(binds_ok, "the shared skin: bind i is bone i at the inverse of its global rest (%d binds)" % canon.get_bind_count())
	_check(canon.get_bind_pose(s.find_bone(Skeleton3DBuilder.OBJECT_SPACE_BONE)) == Transform3D.IDENTITY,
		"the object-space bone's bind is identity, as build_skin's")
	var m := _mesh()
	var palette := Skeleton3DBuilder.build_skin(s, m.bone_names, true)
	var old := MeshInstance3D.new()
	old.mesh = BmsReader.to_array_mesh(m)
	old.skin = palette
	var new := MeshInstance3D.new()
	new.mesh = Skeleton3DBuilder.canonical_mesh(m, palette)
	new.skin = canon
	var bones: PackedInt32Array = new.mesh.surface_get_arrays(0)[Mesh.ARRAY_BONES]
	var obj := s.find_bone(Skeleton3DBuilder.OBJECT_SPACE_BONE)
	_check(bones[0] == s.find_bone("Bip01 L Calf") and bones[4] == s.find_bone("Bip01 Spine") and bones[12] == obj,
		"the remapped mesh names skeleton bones: calf %d, spine %d, object space %d (%s)" % [bones[0], bones[4], bones[12], str(bones.slice(0, 16))])
	_check(old.mesh.surface_get_arrays(0)[Mesh.ARRAY_WEIGHTS] == new.mesh.surface_get_arrays(0)[Mesh.ARRAY_WEIGHTS],
		"its weights are the palette mesh's")
	var at_rest_old := _skinned(old, s)
	var at_rest_new := _skinned(new, s)
	_pose(s)
	var posed_old := _skinned(old, s)
	var posed_new := _skinned(new, s)
	var worst := 0.0
	var moved := 0.0
	for k in range(posed_old.size()):
		worst = maxf(worst, posed_old[k].distance_to(posed_new[k]))
		worst = maxf(worst, at_rest_old[k].distance_to(at_rest_new[k]))
		moved = maxf(moved, posed_old[k].distance_to(at_rest_old[k]))
	_check(moved > 1.0, "the pose moves the vertices (%.2f)" % moved)
	_check(worst < 1e-5, "under the pose every vertex lands where the per-piece skin put it (worst %s)" % str(worst))
	old.free()
	new.free()
	s.free()

func _test_volume() -> void:
	var s := _body()
	Skeleton3DBuilder._object_space_bone(s)
	var canon := Skeleton3DBuilder.canonical_skin(s)
	CharacterAppearance._mark_canonical(canon)
	var a := MeshInstance3D.new()
	a.mesh = BoxMesh.new()
	s.add_child(a)
	a.skin = canon
	a.skeleton = a.get_path_to(s)
	var twin := MeshInstance3D.new()
	twin.mesh = BoxMesh.new()
	s.add_child(twin)
	twin.skin = canon
	twin.skeleton = twin.get_path_to(s)
	var other := s.duplicate() as Skeleton3D
	var scales := {"Bip01 Spine": 1.2, "Bip01 L Thigh": 1.0}
	CharacterAppearance.apply_volume(s, scales)
	_check(a.skin != canon and a.skin == twin.skin, "Volume gives the body's pieces one variant of the shared skin")
	_check(CharacterAppearance.canonical_base(a.skin) == canon, "the variant knows its base")
	var spine := s.find_bone("Bip01 Spine")
	_check(canon.get_bind_pose(spine).is_equal_approx(s.get_bone_global_rest(spine).affine_inverse()), "the base is left as it was")
	var other_mi := other.get_child(0) as MeshInstance3D
	_check(other_mi.skin == canon, "another body on the base keeps it")
	# The per-piece edit (the old path) on a skin of its own, for the same bone.
	var old := Skeleton3DBuilder.build_skin(s, PackedStringArray(["Bip01 Spine"]))
	var piece := MeshInstance3D.new()
	piece.mesh = BoxMesh.new()
	s.add_child(piece)
	piece.skin = old
	piece.skeleton = piece.get_path_to(s)
	CharacterAppearance.apply_volume(s, scales)
	_check(piece.skin.get_bind_pose(0).is_equal_approx(a.skin.get_bind_pose(spine)),
		"the variant's spine bind is the old per-piece edit's (%s)" % str(a.skin.get_bind_pose(spine)))
	_check(a.skin.get_bind_pose(s.find_bone("Bip01 L Thigh")).is_equal_approx(canon.get_bind_pose(s.find_bone("Bip01 L Thigh"))),
		"a bone at factor 1 keeps its plain bind")
	var again := CharacterAppearance.volume_skin(canon, other, scales)
	_check(again == a.skin, "a second body of the same Volume shares the variant")
	CharacterAppearance.apply_volume(s, {"Bip01 Spine": 1.0})
	_check(a.skin == canon, "neutral Volume gives the base back")
	other.free()
	s.free()
	# F3: the base holds its variants weakly, so the two make no cycle: with
	# nothing else holding them, both are freed.
	var s2 := _body()
	var base := Skeleton3DBuilder.canonical_skin(s2)
	CharacterAppearance._mark_canonical(base)
	var variant := CharacterAppearance.volume_skin(base, s2, {"Bip01 Spine": 1.2})
	var held = (base.get_meta(CharacterAppearance.VOLUME_VARIANTS_META) as Dictionary).values()[0]
	_check(held is WeakRef, "the base keeps its variant as a WeakRef")
	var wb: WeakRef = weakref(base)
	var wv: WeakRef = weakref(variant)
	base = null
	variant = null
	held = null
	_check(wb.get_ref() == null and wv.get_ref() == null, "F3: a base skin and its Volume variant are freed once nothing wears them")
	s2.free()

## Two body templates on one skeleton file share one skin; their clips stay
## their own (round 738's review, F1).
func _test_share_template() -> void:
	var by_layout := {}
	var made: Array = []
	for n in range(2):
		var t := SkinnedBsrAssembler.AssembledCharacter.new()
		t.skeleton = _body()
		Skeleton3DBuilder._object_space_bone(t.skeleton)
		t.canonical_skin = Skeleton3DBuilder.canonical_skin(t.skeleton)
		t.parsed = BsrReader.ParsedObject.new()
		t.parsed.skeleton_path = "res\\test_skel.bsk"
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		t.skeleton.add_child(mi)
		mi.skin = t.canonical_skin
		mi.skeleton = mi.get_path_to(t.skeleton)
		CharacterAppearance.share_template(t, by_layout)
		made.append(t)
	var a: SkinnedBsrAssembler.AssembledCharacter = made[0]
	var b: SkinnedBsrAssembler.AssembledCharacter = made[1]
	_check(b.canonical_skin == a.canonical_skin and (b.skeleton.get_child(0) as MeshInstance3D).skin == a.canonical_skin,
		"a second template on the same skeleton file takes the first's skin, and so do its pieces")
	_check(CharacterAppearance.canonical_base(a.canonical_skin) == a.canonical_skin, "the shared skin is marked for Volume")
	_check(not is_same(a.animation_cache, b.animation_cache), "each template keeps its own clip cache")
	for t in made:
		(t as SkinnedBsrAssembler.AssembledCharacter).skeleton.free()

## The review's case (F1, MEASURED there: chinaman_merchant_walkforward.ban is
## the Chinese bodies' `1:default` walk, with footsteps, and the European staff
## bodies' `1:onehand_staff` walk, with no sound set). Two Figures play one
## file: each keeps the tag it found the file as, so each hears its own sound
## set however the lookups interleave, and the two share the file's baked
## poses.
func _test_sound_tags() -> void:
	var path := "res\\ani\\merchant_walkforward.ban"
	var china := SkinnedBsrAssembler.AssembledCharacter.new()
	china.parsed = BsrReader.ParsedObject.new()
	var euro := SkinnedBsrAssembler.AssembledCharacter.new()
	euro.parsed = BsrReader.ParsedObject.new()
	for pair in [[china, "default"], [euro, "onehand_staff"]]:
		var t: SkinnedBsrAssembler.AssembledCharacter = pair[0]
		var entry := BsrReader.AnimationEntry.new()
		entry.action_type = BsrReader.AnimationEntry.TYPE_WALK
		entry.path = path
		t.parsed.animation_groups[pair[1]] = [entry]
		var clip := _clip(10, 4, 1166)
		clip.set_meta(SkinnedBsrAssembler.CLIP_PATH_META, path.to_lower())
		t.animation_cache[path] = clip
	var steps := BsrReader.SoundSet.new()
	steps.action_type = BsrReader.AnimationEntry.TYPE_WALK
	steps.name = "default"
	steps.tracks.append(BsrReader.SoundTrack.new())
	china.parsed.sound_sets_by_type["1:default"] = steps
	var by_layout := {}
	CharacterAppearance.share_template(china, by_layout)
	CharacterAppearance.share_template(euro, by_layout)
	var walk := BsrReader.AnimationEntry.TYPE_WALK
	var heard := func(t: SkinnedBsrAssembler.AssembledCharacter, clip: BanReader.ParsedAnimation) -> bool:
		var tag = clip.get_meta(BsrReader.CLIP_META, null)
		return tag != null and t.parsed.sound_set_for(int(tag[0]), String(tag[1])) != null
	var c := SkinnedBsrAssembler.animation_for(null, china, walk, "default")
	var e := SkinnedBsrAssembler.animation_for(null, euro, walk, "onehand_staff")
	_check(c != null and e != null and c != e, "the two Figures hold the file as two clip objects")
	_check(heard.call(china, c) and not heard.call(euro, e), "after the European lookup the Chinese body still hears its footsteps, and the European none")
	SkinnedBsrAssembler.animation_for(null, china, walk, "default")
	_check(heard.call(china, c) and not heard.call(euro, e), "and after the Chinese lookup the European body is still silent")
	var sa := _skeleton(10)
	sa.set_meta(MonsterCrowd.META_LAYOUT, "synthetic|10")
	var sb := _skeleton(10)
	sb.set_meta(MonsterCrowd.META_LAYOUT, "synthetic|10")
	_check(CrowdAnim.frames_for(sa, c) == CrowdAnim.frames_for(sb, e), "and the two share the file's baked poses (by path and layout)")
	CrowdAnim.clear_shared_frames()
	sa.free()
	sb.free()

# --- A3: baked poses ----------------------------------------------------------

func _skeleton(bones: int) -> Skeleton3D:
	var skel := Skeleton3D.new()
	for i in range(bones):
		skel.add_bone("b%d" % i)
		if i > 0:
			skel.set_bone_parent(i, i - 1)
	return skel

## A clip over b0..b(n-1): every bone's rotation moves; b0's position moves,
## the others' stay put; one track names no bone of the skeleton.
func _clip(n: int, keys: int, duration: int) -> BanReader.ParsedAnimation:
	var clip := BanReader.ParsedAnimation.new()
	clip.duration_ms = duration
	clip.cyclic = true
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
			kf.position = Vector3(float(b), float(k) * 0.5 if b == 0 else 2.0, 0.0)
			track.keyframes.append(kf)
		clip.bones.append(track)
	var ghost := BanReader.Bone.new()
	ghost.bone_name = "not_a_bone"
	var kg := BanReader.Keyframe.new()
	kg.rotation = Quaternion.IDENTITY
	ghost.keyframes.append(kg)
	clip.bones.append(ghost)
	return clip

## The largest difference between two skeletons' poses: a rotation's as the
## distance between the two unit quaternions (the nearer sign; about half the
## angle, and free of angle_to's acos noise near 1, which reads 1e-3 for two
## float32-equal rotations), a position's in units.
func _max_angle(a: Skeleton3D, b: Skeleton3D) -> float:
	var worst := 0.0
	for i in range(a.get_bone_count()):
		var qa := a.get_bone_pose_rotation(i)
		var qb := b.get_bone_pose_rotation(i)
		worst = maxf(worst, minf((qa - qb).length(), (qa + qb).length()))
		worst = maxf(worst, a.get_bone_pose_position(i).distance_to(b.get_bone_pose_position(i)))
	return worst

func _test_baked_pose() -> void:
	var clip := _clip(10, 6, 1500)
	var exact := _skeleton(10)
	var baked := _skeleton(10)
	baked.set_meta(MonsterCrowd.META_LAYOUT, "synthetic|10")
	exact.set_meta(MonsterCrowd.META_LAYOUT, "synthetic|10")
	var q := CrowdAnim.QUANTUM_MS / 1000.0
	var on_frame := 0.0
	for f in [0, 1, 7, 60, 179]:
		var t := float(f) * q
		MonsterCrowd.pose_at(exact, clip, t, true)
		CrowdAnim.pose_cached(baked, clip, t, true)
		on_frame = maxf(on_frame, _max_angle(exact, baked))
	_check(on_frame < 1e-5, "on a frame's time the baked pose is the exact one (worst %s)" % str(on_frame))
	var fr := CrowdAnim.frames_for(baked, clip)
	_check(fr.count == 180 and fr.bones.size() == 10, "a 1500 ms clip bakes 180 frames of 10 bones (%d, %d)" % [fr.count, fr.bones.size()])
	_check(fr.moving_rot.size() == 10 and fr.moving_pos.size() == 1, "every rotation moves, one position does (%d, %d)" % [fr.moving_rot.size(), fr.moving_pos.size()])
	_check(fr.baked <= 5, "frames are baked as bodies need them (%d of %d)" % [fr.baked, fr.count])
	# Between frames: the nearest frame's pose (a third of a quantum past frame 9).
	var t := 9.33 * q
	CrowdAnim.pose_cached(baked, clip, t, true)
	MonsterCrowd.pose_at(exact, clip, 9.0 * q, true)
	_check(_max_angle(exact, baked) < 1e-5, "a body between frames takes the nearest frame's pose")
	MonsterCrowd.pose_at(exact, clip, t, true)
	var off := _max_angle(exact, baked)
	_check(off > 0.0 and off < 0.05, "and differs from the exact pose by what a third of a quantum moves (%.4f)" % off)
	# The wrap: a loop's time past its end is its start.
	CrowdAnim.pose_cached(baked, clip, 1.5 + 2.0 * q, true)
	MonsterCrowd.pose_at(exact, clip, 2.0 * q, true)
	_check(_max_angle(exact, baked) < 1e-5, "a loop past its end wraps to its start")
	# Only the moving channels while the body stays on the clip.
	var sentinel := Vector3(9, 9, 9)
	baked.set_bone_pose_position(4, sentinel)
	CrowdAnim.pose_cached(baked, clip, 0.5, true)
	_check(baked.get_bone_pose_position(4) == sentinel, "a body that stays on the clip is not given the channels it does not move")
	var other := _clip(10, 3, 900)
	CrowdAnim.pose_cached(baked, other, 0.2, true)
	CrowdAnim.pose_cached(baked, clip, 0.5, true)
	MonsterCrowd.pose_at(exact, clip, 0.5, true)
	_check(baked.get_bone_pose_position(4) == Vector3(4, 2, 0) and _max_angle(exact, baked) < 1e-5,
		"a body that comes back from another clip is given every channel (%s)" % str(baked.get_bone_pose_position(4)))
	# The one-shot: held at its end.
	clip.cyclic = false
	CrowdAnim.pose_cached(baked, clip, 5.0, false)
	MonsterCrowd.pose_at(exact, clip, 5.0, false)
	_check(_max_angle(exact, baked) < 1e-5, "a one-shot past its end holds its last key")
	# The world's dispatch: a skeleton the cull cache marked goes through the
	# baked frames, or with the switches off through the old path.
	var marked := _skeleton(10)
	marked.set_meta(MonsterCrowd.META_LAYOUT, "synthetic|10")
	marked.set_meta(CrowdAnim.META_CACHED, true)
	MonsterCrowd.pose_at(marked, clip, 0.31, true)
	_check(marked.has_meta(CrowdAnim.META_LAST) and marked.get_meta(CrowdAnim.META_LAST) == CrowdAnim.frames_for(marked, clip), "pose_at poses a marked skeleton from the baked frames")
	CrowdAnim.set_switches("-")
	var plain := _skeleton(10)
	Skeleton3DBuilder.apply_ban_pose_at(plain, clip, 0.31, true)
	MonsterCrowd.pose_at(marked, clip, 0.31, true)
	_check(_max_angle(plain, marked) < 1e-6, "with the switches off a marked skeleton is posed by the old path, exactly")
	CrowdAnim.set_switches("1i34")
	for s in [exact, baked, marked, plain]:
		s.free()
	# A clip parsed for one cast (World3D._play_other_cast_anim parses one per
	# cast) goes when its last holder does: its baked frames hold no reference
	# back to it.
	var cast := _clip(10, 4, 600)
	var watch: WeakRef = weakref(cast)
	var caster := _skeleton(10)
	caster.set_meta(MonsterCrowd.META_LAYOUT, "synthetic|10")
	CrowdAnim.pose_cached(caster, cast, 0.2, false)
	caster.free()
	cast = null
	_check(watch.get_ref() == null, "a cast clip and its baked frames are freed once nothing holds the clip")

func _test_lod_bands() -> void:
	_check(CrowdAnim.pose_interval(2000.0, 99) == 1, "99 characters: every body every frame, however far (the original's count > 99, READ)")
	_check(CrowdAnim.pose_interval(300.0, 100) == 1 and CrowdAnim.pose_interval(899.0, 1000) == 1,
		"100 characters: near and mid-range (within 900) every frame, as before")
	_check(CrowdAnim.pose_interval(900.0, 100) == 2 and CrowdAnim.pose_interval(1799.0, 500) == 2, "900 to 1,800: every second frame")
	_check(CrowdAnim.pose_interval(1800.0, 1000) == 4, "past 1,800: every fourth")
	CrowdAnim.set_switches("1i3")
	_check(CrowdAnim.pose_interval(2000.0, 1000) == 1, "A4 off: every frame")
	CrowdAnim.set_switches("1i34")

# --- A1: the world's clip tick ------------------------------------------------

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

## Another player's body as World3D._spawn_or_update_other builds one: a
## holder carrying `character_id`, the skeleton (with its layout) under it and
## a mesh reaching 3 units, registered in the clip tick.
func _other_player(world: Node, holder: Node3D, at: Vector3, id: int, clip: BanReader.ParsedAnimation) -> Skeleton3D:
	var node := Node3D.new()
	node.position = at
	node.set_meta("character_id", id)
	var skel := _skeleton(3)
	skel.set_meta(MonsterCrowd.META_LAYOUT, "synthetic|3")
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	mi.mesh = box
	skel.add_child(mi)
	node.add_child(skel)
	holder.add_child(node)
	(world.get("_animated") as Array).append([skel, clip, 2, float(id) * 0.37, true, 0.0, null])
	return skel

func _test_world_tick(world: Node) -> void:
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = Vector3(0.0, 20.0, 0.0)
	cam.look_at(Vector3(0.0, 0.0, -100.0))
	cam.far = 4000.0
	cam.make_current()
	var player := world.get("player") as Node3D
	if player != null:
		player.global_position = Vector3.ZERO
	var holder := Node3D.new()
	world.add_child(holder)
	var clip := _turn_clip()
	var rng := RandomNumberGenerator.new()
	rng.seed = 738
	# 60 other players around the camera, within 280 of it (fewer than 100
	# characters, and inside the LOD's near band: A4 does not apply).
	var skels: Array = []
	for i in range(60):
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(20.0, 280.0)
		skels.append(_other_player(world, holder, Vector3(cos(a) * d, 0.0, sin(a) * d), 1000 + i, clip))
	# The character window's doll stands for any animated skeleton that is not
	# another player's: behind the camera, it is posed all the same.
	var doll_node := Node3D.new()
	doll_node.position = Vector3(0.0, 0.0, 60.0)
	var doll := _skeleton(3)
	doll_node.add_child(doll)
	holder.add_child(doll_node)
	(world.get("_animated") as Array).append([doll, clip, 2, 0.0, true, 0.0, null])
	var sentinel := Quaternion(Vector3.UP, 1.234)
	var reset := func() -> void:
		for s in skels:
			(s as Skeleton3D).set_bone_pose_rotation(1, sentinel)
		doll.set_bone_pose_rotation(1, sentinel)
	var turned := func(skel: Skeleton3D) -> bool: return not skel.get_bone_pose_rotation(1).is_equal_approx(sentinel)
	var in_view := func(skel: Skeleton3D) -> bool:
		var r := CrowdAnim.player_radius(skel)
		for plane in cam.get_frustum():
			if (plane as Plane).distance_to(skel.global_position) > r:
				return false
		return true
	# The bodies' first tick poses each once wherever it is (the review's F2,
	# tested below); A1 is what the ticks after it do.
	world.call("_tick_idle_animations", 0.0)
	reset.call()
	world.set("_idle_anim_time", 0.25)
	world.call("_tick_idle_animations", 0.0)
	var wrong := 0
	var seen := 0
	for s in skels:
		if in_view.call(s):
			seen += 1
		if in_view.call(s) != turned.call(s):
			wrong += 1
	_check(seen > 3 and seen < 57, "the scene has other players both in view and not (%d of 60 in view)" % seen)
	_check(wrong == 0, "A1: another player is posed iff its sphere is in the frustum (%d differ)" % wrong)
	_check(turned.call(doll), "the doll, out of the camera's view, is posed all the same")
	_check(int(world.get("_anim_posed_last")) == seen + 1, "the tick counts %d posed (the seen and the doll)" % int(world.get("_anim_posed_last")))
	# The camera turns round: a body now in view is posed where its clip has
	# got to, not where it was left.
	reset.call()
	cam.look_at(Vector3(0.0, 0.0, 100.0))
	world.set("_idle_anim_time", 0.6)
	world.call("_tick_idle_animations", 0.0)
	var late := 0
	var at_time := 0
	for i in range(skels.size()):
		var s: Skeleton3D = skels[i]
		if in_view.call(s) and not turned.call(s):
			late += 1
		if in_view.call(s):
			var want := _skeleton(3)
			Skeleton3DBuilder.apply_ban_pose_at(want, clip, 0.6 + float(1000 + i) * 0.37, true)
			if want.get_bone_pose_rotation(1).angle_to(s.get_bone_pose_rotation(1)) < 0.02:
				at_time += 1
			want.free()
	_check(late == 0, "after the turn every body now in view is posed at once (%d late)" % late)
	_check(at_time > 3, "and posed at its clip's current time, within the quantum (%d)" % at_time)
	# Every switch off: every body posed, as before the round.
	CrowdAnim.set_switches("-")
	reset.call()
	world.call("_tick_idle_animations", 0.0)
	var unposed := 0
	for s in skels:
		if not turned.call(s):
			unposed += 1
	_check(unposed == 0, "with the switches off every other player is posed, in view or not (%d not)" % unposed)
	CrowdAnim.set_switches("1i34")
	cam.queue_free()
	holder.queue_free()
	(world.get("_animated") as Array).clear()

## Round 738's review, F2 and F6: a crowd of 110 far bodies (A4 is live).
## Every body is posed at its first tick wherever it is (none left in the
## bind pose); a body's first tick back in view is never skipped by the LOD;
## and a body past Character Sight Range is not posed.
func _test_world_lod_and_range(world: Node) -> void:
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = Vector3(0.0, 20.0, 0.0)
	cam.look_at(Vector3(0.0, 0.0, -100.0))
	cam.far = 6000.0
	cam.make_current()
	var holder := Node3D.new()
	world.add_child(holder)
	var clip := _turn_clip()
	var skels: Array = []
	for i in range(110):
		var x := float(i % 11) * 40.0 - 200.0
		var z := -1000.0 - float(i / 11) * 100.0
		skels.append(_other_player(world, holder, Vector3(x, 0.0, z), 2000 + i, clip))
	# One body behind the camera: never in view.
	var behind := _other_player(world, holder, Vector3(0.0, 0.0, 300.0), 3000, clip)
	var sentinel := Quaternion(Vector3.UP, 1.234)
	var reset := func() -> void:
		for sk in skels:
			(sk as Skeleton3D).set_bone_pose_rotation(1, sentinel)
		behind.set_bone_pose_rotation(1, sentinel)
	var turned := func(skel: Skeleton3D) -> bool: return not skel.get_bone_pose_rotation(1).is_equal_approx(sentinel)
	var count_turned := func() -> int:
		var n := 0
		for sk in skels:
			if turned.call(sk):
				n += 1
		return n
	reset.call()
	world.call("_tick_idle_animations", 0.0)
	_check(count_turned.call() == 110 and turned.call(behind),
		"F2: every body's first tick poses it, the one behind the camera too (%d of 110)" % count_turned.call())
	reset.call()
	world.call("_tick_idle_animations", 0.0)
	var steady: int = count_turned.call()
	_check(steady < 110 and not turned.call(behind), "the next tick the far LOD skips some (%d of 110 posed) and the one behind is not posed" % steady)
	# Out of view for a tick, then back: the first tick back poses all.
	cam.look_at(Vector3(0.0, 0.0, 100.0))
	world.call("_tick_idle_animations", 0.0)
	cam.look_at(Vector3(0.0, 0.0, -100.0))
	reset.call()
	world.call("_tick_idle_animations", 0.0)
	_check(count_turned.call() == 110, "F2: the first tick back in view poses every body, whatever its LOD slot (%d of 110)" % count_turned.call())
	# Character Sight Range 600: these bodies, 1,000 and more away, draw
	# nothing and are not posed.
	world.set("_character_range", 600.0)
	reset.call()
	world.call("_tick_idle_animations", 0.0)
	world.call("_tick_idle_animations", 0.0)
	_check(count_turned.call() == 0, "F6: past Character Sight Range no body is posed (%d)" % count_turned.call())
	world.set("_character_range", 0.0)
	cam.queue_free()
	holder.queue_free()
	(world.get("_animated") as Array).clear()
