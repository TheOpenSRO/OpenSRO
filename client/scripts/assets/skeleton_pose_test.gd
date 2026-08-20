extends SceneTree

## Exercises SkeletonPose against a synthetic skeleton (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/skeleton_pose_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _put_u32(b: PackedByteArray, off: int, v: int) -> void:
	b[off] = v & 0xFF
	b[off + 1] = (v >> 8) & 0xFF
	b[off + 2] = (v >> 16) & 0xFF
	b[off + 3] = (v >> 24) & 0xFF

func _put_f32(b: PackedByteArray, off: int, v: float) -> void:
	var enc := PackedByteArray()
	enc.resize(4)
	enc.encode_float(0, v)
	for i in range(4):
		b[off + i] = enc[i]

func _put_quat(b: PackedByteArray, off: int, q: Quaternion) -> void:
	_put_f32(b, off, q.x)
	_put_f32(b, off + 4, q.y)
	_put_f32(b, off + 8, q.z)
	_put_f32(b, off + 12, q.w)

func _root_transform(pos: Vector3, rot: Quaternion = Quaternion.IDENTITY) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(BskReader.ROOT_TRANSFORM_LEN)
	_put_quat(t, 0x04, rot)
	_put_f32(t, 0x30, pos.x)
	_put_f32(t, 0x34, pos.y)
	_put_f32(t, 0x38, pos.z)
	return t

func _bone_transform(pos: Vector3, rot: Quaternion = Quaternion.IDENTITY) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(BskReader.BONE_TRANSFORM_LEN)
	_put_quat(t, 0x00, rot)
	_put_f32(t, 0x2c, pos.x)
	_put_f32(t, 0x30, pos.y)
	_put_f32(t, 0x34, pos.z)
	return t

func _make_skeleton() -> BskReader.ParsedSkeleton:
	var s := BskReader.ParsedSkeleton.new()
	var root := BskReader.Bone.new()
	root.bone_name = "Root"
	root.parent_name = ""
	root.transform = _root_transform(Vector3(0, 0, 0))
	s.bones.append(root)

	var c1 := BskReader.Bone.new()
	c1.bone_name = "Child1"
	c1.parent_name = "Root"
	c1.transform = _bone_transform(Vector3(10, 0, 0), Quaternion(Vector3.UP, deg_to_rad(45)))
	s.bones.append(c1)

	var c2 := BskReader.Bone.new()
	c2.bone_name = "Child2"
	c2.parent_name = "Child1"
	c2.transform = _bone_transform(Vector3(20, 0, 0))
	s.bones.append(c2)

	var other := BskReader.Bone.new()
	other.bone_name = "Other"
	other.parent_name = ""
	other.transform = _root_transform(Vector3(0, 100, 0))
	s.bones.append(other)

	return s

func _init() -> void:
	var skel := _make_skeleton()

	var positions := SkeletonPose.bind_positions(skel)
	_check(positions.size() == 4, "4 bind positions (got %d)" % positions.size())
	_check(positions["Root"] == Vector3(0, 0, 0), "Root position (got %s)" % positions["Root"])
	_check(positions["Child1"] == Vector3(10, 0, 0), "Child1 position (got %s)" % positions["Child1"])
	_check(positions["Child2"] == Vector3(20, 0, 0), "Child2 position (got %s)" % positions["Child2"])

	var c1_bone: BskReader.Bone
	for b in skel.bones:
		if b.bone_name == "Child1":
			c1_bone = b
	var c1_rot := SkeletonPose.bone_rotation(c1_bone)
	_check(c1_rot.is_equal_approx(Quaternion(Vector3.UP, deg_to_rad(45))), "Child1 rotation matches (got %s)" % c1_rot)

	var descendants := SkeletonPose.descendants_of(skel, "Root")
	_check(descendants.size() == 2 and descendants.has("Child1") and descendants.has("Child2"), "Root's descendants are exactly Child1+Child2 (got %s)" % [descendants.keys()])
	_check(not descendants.has("Other"), "Other is not a descendant of Root")

	# Rotate 90 degrees around Y, pivoting on Root (at origin): (10,0,0) -> (0,0,-10).
	var delta := Quaternion(Vector3.UP, deg_to_rad(90))
	var animated := SkeletonPose.apply_rotation(skel, positions, "Root", delta)
	_check(animated["Child1"].is_equal_approx(Vector3(0, 0, -10)), "Child1 rotated correctly (got %s)" % animated["Child1"])
	_check(animated["Child2"].is_equal_approx(Vector3(0, 0, -20)), "Child2 rotated correctly (got %s)" % animated["Child2"])
	_check(animated["Other"] == Vector3(0, 100, 0), "Other unaffected by Root's rotation (got %s)" % animated["Other"])
	_check(animated["Root"] == Vector3(0, 0, 0), "Root itself unmoved (it's the pivot) (got %s)" % animated["Root"])

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
