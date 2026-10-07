extends SceneTree

## Exercises Skeleton3DBuilder against a synthetic skeleton + animation
## (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/skeleton3d_builder_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _put_f32(b: PackedByteArray, off: int, v: float) -> void:
	var enc := PackedByteArray()
	enc.resize(4)
	enc.encode_float(0, v)
	for i in range(4):
		b[off + i] = enc[i]

## Builds a real-shaped 88-byte bone transform. A real .bsk carries **both**
## the bone's parent-relative local translation (floats [4..6], offset 0x10)
## and its bind-pose world position (offset 0x2c) -- confirmed 2026-09-02 by
## dumping a real bone's floats beside the matching real .ban keyframe (see
## SkeletonPose.bone_local_position). build_skeleton3d reads the *local* one;
## this fixture writes both so it matches the real layout rather than only
## the field the old, incorrect derivation happened to use.
func _bone_transform_full(local_pos: Vector3, world_pos: Vector3) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(BskReader.BONE_TRANSFORM_LEN)
	# Identity rotation quaternion at 0x00 (x,y,z,w) -- SkeletonPose.
	# bone_rotation() reads this offset for an ordinary (88-byte) bone;
	# leaving it all-zero would be a degenerate, non-unit quaternion once
	# build_skeleton3d started using real bind rotations (2026-08-28).
	_put_f32(t, 0x00, 0.0)
	_put_f32(t, 0x04, 0.0)
	_put_f32(t, 0x08, 0.0)
	_put_f32(t, 0x0c, 1.0)
	_put_f32(t, 0x10, local_pos.x)
	_put_f32(t, 0x14, local_pos.y)
	_put_f32(t, 0x18, local_pos.z)
	_put_f32(t, 0x2c, world_pos.x)
	_put_f32(t, 0x30, world_pos.y)
	_put_f32(t, 0x34, world_pos.z)
	return t

func _make_skeleton() -> BskReader.ParsedSkeleton:
	# Root -> Child1 (10,0,0) -> Child2 (20,0,0), same shape as
	# skeleton_pose_test.gd's fixture, plus deliberately listing Child2
	# before Child1 to exercise the topological-order handling.
	var s := BskReader.ParsedSkeleton.new()
	s.root_name = "Root"

	var c2 := BskReader.Bone.new()
	c2.bone_name = "Child2"
	c2.parent_name = "Child1"
	c2.transform = _bone_transform_full(Vector3(10, 0, 0), Vector3(20, 0, 0))
	s.bones.append(c2)

	var c1 := BskReader.Bone.new()
	c1.bone_name = "Child1"
	c1.parent_name = "Root"
	c1.transform = _bone_transform_full(Vector3(10, 0, 0), Vector3(10, 0, 0))
	s.bones.append(c1)

	return s

func _make_animation() -> BanReader.ParsedAnimation:
	var anim := BanReader.ParsedAnimation.new()
	var track := BanReader.Bone.new()
	track.bone_name = "Child1"

	# A real .ban keyframe is the bone's **full** parent-relative local
	# transform -- rotation *and* translation (confirmed against the real
	# client binary, see docs/protocol/BAN_FORMAT.md). So each keyframe here
	# carries Child1's real local offset from Root, (10,0,0), alongside the
	# rotation; a keyframe with a zero translation would be asserting the
	# bone sits on top of its parent, which is not what this fixture means.
	var k0 := BanReader.Keyframe.new()
	k0.rotation = Quaternion.IDENTITY
	k0.position = Vector3(10, 0, 0)
	track.keyframes.append(k0)

	var k1 := BanReader.Keyframe.new()
	k1.rotation = Quaternion(Vector3.UP, deg_to_rad(90))
	k1.position = Vector3(10, 0, 0)
	track.keyframes.append(k1)

	anim.bones.append(track)
	return anim

func _init() -> void:
	var skel := _make_skeleton()
	var skeleton := Skeleton3DBuilder.build_skeleton3d(skel)

	_check(skeleton.get_bone_count() == 3, "3 bones in the built Skeleton3D (got %d)" % skeleton.get_bone_count())
	var root_idx := skeleton.find_bone("Root")
	var c1_idx := skeleton.find_bone("Child1")
	var c2_idx := skeleton.find_bone("Child2")
	_check(root_idx != -1 and c1_idx != -1 and c2_idx != -1, "all 3 bones found by name")
	_check(skeleton.get_bone_parent(c1_idx) == root_idx, "Child1's parent is Root")
	_check(skeleton.get_bone_parent(c2_idx) == c1_idx, "Child2's parent is Child1")

	var bind_c1: Vector3 = skeleton.get_bone_global_pose(c1_idx).origin
	var bind_c2: Vector3 = skeleton.get_bone_global_pose(c2_idx).origin
	_check(bind_c1.is_equal_approx(Vector3(10, 0, 0)), "Child1 bind-pose global position matches (got %s)" % bind_c1)
	_check(bind_c2.is_equal_approx(Vector3(20, 0, 0)), "Child2 bind-pose global position matches (got %s)" % bind_c2)

	var anim := _make_animation()
	Skeleton3DBuilder.apply_ban_keyframe(skeleton, anim.bones[0], 1)

	# Same math as skeleton_pose_test.gd's rotation case: a 90-degree
	# rotation around Y, pivoting on Child1 (at world (10,0,0)), should
	# move Child2 (world (20,0,0), i.e. 10 units further out along +X from
	# the pivot) to (10,0,-10) -- verified here via the engine's own
	# Skeleton3D pose propagation, not manual per-bone math.
	var animated_c2: Vector3 = skeleton.get_bone_global_pose(c2_idx).origin
	_check(animated_c2.is_equal_approx(Vector3(10, 0, -10)), "Child2 moved correctly via engine pose propagation (got %s)" % animated_c2)
	var animated_c1: Vector3 = skeleton.get_bone_global_pose(c1_idx).origin
	_check(animated_c1.is_equal_approx(Vector3(10, 0, 0)), "Child1 itself unmoved (it's the pivot) (got %s)" % animated_c1)

	# apply_ban_pose: the real multi-bone player. Reset to bind pose first,
	# then apply the same single-track animation via the whole-pose
	# function and confirm it produces the identical result apply_ban_keyframe
	# already proved correct above -- plus a second, unmatched track that
	# should be silently skipped rather than erroring.
	var skeleton2 := Skeleton3DBuilder.build_skeleton3d(skel)
	var multi_anim := _make_animation()
	var unmatched_track := BanReader.Bone.new()
	unmatched_track.bone_name = "NoSuchBone"
	var uk0 := BanReader.Keyframe.new()
	uk0.rotation = Quaternion.IDENTITY
	unmatched_track.keyframes.append(uk0)
	multi_anim.bones.append(unmatched_track)

	Skeleton3DBuilder.apply_ban_pose(skeleton2, multi_anim, 1)
	var c2_idx2 := skeleton2.find_bone("Child2")
	var pose_c2: Vector3 = skeleton2.get_bone_global_pose(c2_idx2).origin
	_check(pose_c2.is_equal_approx(Vector3(10, 0, -10)), "apply_ban_pose matches apply_ban_keyframe's result (got %s)" % pose_c2)

	# apply_ban_pose_at: the clip's own clock. Two keys a second apart;
	# halfway between them Child1 is rotated 45 degrees, so Child2 sits at
	# (10 + 10 cos 45, 0, -10 sin 45). Past the end a one-shot holds the
	# last key, and a loop is back on the first at exactly one duration.
	multi_anim.duration_ms = 1000
	multi_anim.key_times = PackedInt32Array([0, 1000])
	var skeleton3 := Skeleton3DBuilder.build_skeleton3d(skel)
	var c2_idx3 := skeleton3.find_bone("Child2")
	Skeleton3DBuilder.apply_ban_pose_at(skeleton3, multi_anim, 0.5, false)
	var half: Vector3 = skeleton3.get_bone_global_pose(c2_idx3).origin
	_check(half.is_equal_approx(Vector3(10.0 + 10.0 * cos(deg_to_rad(45)), 0, -10.0 * sin(deg_to_rad(45)))),
		"halfway between two keys blends the rotation (got %s)" % half)
	Skeleton3DBuilder.apply_ban_pose_at(skeleton3, multi_anim, 3.0, false)
	var held: Vector3 = skeleton3.get_bone_global_pose(c2_idx3).origin
	_check(held.is_equal_approx(Vector3(10, 0, -10)), "a one-shot past its end holds the last key (got %s)" % held)
	Skeleton3DBuilder.apply_ban_pose_at(skeleton3, multi_anim, 1.0, true)
	var wrapped: Vector3 = skeleton3.get_bone_global_pose(c2_idx3).origin
	_check(wrapped.is_equal_approx(Vector3(20, 0, 0)), "a loop at one duration is back on its first key (got %s)" % wrapped)

	_check_stored_world_binds()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A bone transform with explicit rotations and both positions: `extra` is 4
## for the root's 92-byte record (every field shifted by 4), 0 otherwise.
func _bone_bytes(size: int, extra: int, local_pos: Vector3, world_pos: Vector3) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(size)
	for q_off in [0x00, 0x1c, 0x38]:
		_put_f32(t, extra + q_off + 0x0c, 1.0) # identity (x, y, z, w)
	# The third pair, the inverse bind: with an identity rotation, -world.
	_put_f32(t, extra + 0x48, -world_pos.x)
	_put_f32(t, extra + 0x4c, -world_pos.y)
	_put_f32(t, extra + 0x50, -world_pos.z)
	_put_f32(t, extra + 0x10, local_pos.x)
	_put_f32(t, extra + 0x14, local_pos.y)
	_put_f32(t, extra + 0x18, local_pos.z)
	_put_f32(t, extra + 0x2c, world_pos.x)
	_put_f32(t, extra + 0x30, world_pos.y)
	_put_f32(t, extra + 0x34, world_pos.z)
	return t

## Round 721: the Alexandria gate portal's shape. Its root stores a local of
## (19.75, 0, 0), every child's stored world bind puts the root at the origin,
## and the clip keys the root at the origin. The client skins with the file's
## inverse bind (READ, BSK_FORMAT.md), so a ring around a spinning bone stays
## centred on it; binding to the rest composed from the locals carried the
## stored 19.75 into the bind and swung the ring around the bone at that
## radius.
func _check_stored_world_binds() -> void:
	var s := BskReader.ParsedSkeleton.new()
	s.root_name = "Root"
	s.root_transform = _bone_bytes(BskReader.ROOT_TRANSFORM_LEN, 4, Vector3(20, 0, 0), Vector3(20, 0, 0))
	var spin := BskReader.Bone.new()
	spin.bone_name = "Spin"
	spin.parent_name = "Root"
	spin.transform = _bone_bytes(BskReader.BONE_TRANSFORM_LEN, 0, Vector3(0, 10, 0), Vector3(0, 10, 0))
	s.bones.append(spin)
	var skeleton := Skeleton3DBuilder.build_skeleton3d(s)
	var binds := Skeleton3DBuilder.stored_world_binds(s)
	_check(binds.has("Spin") and (binds["Spin"] as Transform3D).origin.is_equal_approx(Vector3(0, 10, 0)),
		"stored_world_binds reads Spin's stored world bind at (0, 10, 0) (got %s)" % str(binds.get("Spin")))
	var consistent := Skeleton3DBuilder.consistent_stored_binds(skeleton, s)
	_check(consistent.has("Spin"), "a skeleton off only by its root's stored local takes its stored binds")
	var new_skin := Skeleton3DBuilder.build_skin(skeleton, PackedStringArray(["Spin"]), false, false, consistent)
	var old_skin := Skeleton3DBuilder.build_skin(skeleton, PackedStringArray(["Spin"]))
	var root_idx := skeleton.find_bone("Root")
	var spin_idx := skeleton.find_bone("Spin")
	skeleton.set_bone_pose_position(root_idx, Vector3.ZERO) # the clip's root key
	var centre := Vector3(0, 10, 0)
	var rim := Vector3(5, 10, 0)
	var centre_ok := true
	var old_moves := false
	for deg in [0.0, 90.0, 180.0, 270.0]:
		skeleton.set_bone_pose_rotation(spin_idx, Quaternion(Vector3.UP, deg_to_rad(deg)))
		Skeleton3DBuilder.refresh_global_poses(skeleton)
		var pose := skeleton.get_bone_global_pose(spin_idx)
		if not (pose * new_skin.get_bind_pose(0) * centre).is_equal_approx(centre):
			centre_ok = false
		if not (pose * old_skin.get_bind_pose(0) * centre).is_equal_approx(centre):
			old_moves = true
	_check(centre_ok, "bound to the stored world binds, a ring's centre on the spinning bone stays put at every angle")
	_check(old_moves, "bound to the composed rest, the same centre swings (the bug the stored binds fix)")
	skeleton.set_bone_pose_rotation(spin_idx, Quaternion(Vector3.UP, deg_to_rad(90.0)))
	Skeleton3DBuilder.refresh_global_poses(skeleton)
	var rim_posed := skeleton.get_bone_global_pose(spin_idx) * new_skin.get_bind_pose(0) * rim
	_check(rim_posed.is_equal_approx(Vector3(0, 10, -5)), "a rim vertex turns 90 degrees about the bone (got %s)" % rim_posed)
	# A chain whose stored binds are its locals scaled (as the willow
	# tre_willow03's measure, 1.793 below its first bone) is not a root shift:
	# it keeps the composed bind (OURS; why the willow's binds differ is OPEN).
	var scaled := BskReader.ParsedSkeleton.new()
	scaled.root_name = "Root"
	scaled.root_transform = _bone_bytes(BskReader.ROOT_TRANSFORM_LEN, 4, Vector3.ZERO, Vector3.ZERO)
	var b1 := BskReader.Bone.new()
	b1.bone_name = "B1"
	b1.parent_name = "Root"
	b1.transform = _bone_bytes(BskReader.BONE_TRANSFORM_LEN, 0, Vector3(0, 10, 0), Vector3(0, 10, 0))
	scaled.bones.append(b1)
	var b2 := BskReader.Bone.new()
	b2.bone_name = "B2"
	b2.parent_name = "B1"
	b2.transform = _bone_bytes(BskReader.BONE_TRANSFORM_LEN, 0, Vector3(0, 80, 0), Vector3(0, 10 + 80 * 1.793, 0))
	scaled.bones.append(b2)
	var scaled_skel := Skeleton3DBuilder.build_skeleton3d(scaled)
	_check(Skeleton3DBuilder.consistent_stored_binds(scaled_skel, scaled).is_empty(),
		"a chain whose stored binds are scaled keeps the composed bind")
	_check(Skeleton3DBuilder.consistent_stored_binds(skeleton, _make_skeleton()).is_empty(),
		"a skeleton with no usable stored inverse binds keeps the composed bind")
	scaled_skel.free()
	# An unusable stored bind (the unset roots' garbage) is left out: the
	# bone binds to its composed rest as before.
	var bad := BskReader.ParsedSkeleton.new()
	bad.root_name = "Root"
	bad.root_transform = _bone_bytes(BskReader.ROOT_TRANSFORM_LEN, 4, Vector3(3.7e24, 0, 0), Vector3(3.7e24, 0, 0))
	_check(not Skeleton3DBuilder.stored_world_binds(bad).has("Root"), "a root whose stored bind is 3.7e24 away is not used")
	skeleton.free()
