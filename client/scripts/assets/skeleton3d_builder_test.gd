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

func _bone_transform(pos: Vector3) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(BskReader.BONE_TRANSFORM_LEN)
	_put_f32(t, 0x2c, pos.x)
	_put_f32(t, 0x30, pos.y)
	_put_f32(t, 0x34, pos.z)
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
	c2.transform = _bone_transform(Vector3(20, 0, 0))
	s.bones.append(c2)

	var c1 := BskReader.Bone.new()
	c1.bone_name = "Child1"
	c1.parent_name = "Root"
	c1.transform = _bone_transform(Vector3(10, 0, 0))
	s.bones.append(c1)

	return s

func _make_animation() -> BanReader.ParsedAnimation:
	var anim := BanReader.ParsedAnimation.new()
	var track := BanReader.Bone.new()
	track.bone_name = "Child1"

	var k0 := BanReader.Keyframe.new()
	k0.rotation = Quaternion.IDENTITY
	track.keyframes.append(k0)

	var k1 := BanReader.Keyframe.new()
	k1.rotation = Quaternion(Vector3.UP, deg_to_rad(90))
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

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
