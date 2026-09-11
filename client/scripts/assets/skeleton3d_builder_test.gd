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

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
