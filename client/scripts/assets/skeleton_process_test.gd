extends SceneTree

## Round 760: Skeleton3DBuilder.no_physics_step leaves no Skeleton3D with a
## per-frame (or per-step) engine callback, on either engine, and a skeleton
## posed after it still updates: its BoneAttachment3D follows the pose and
## `skeleton_updated` fires (the deferred NOTIFICATION_UPDATE_SKELETON that
## Godot 4.3+ drives from set_bone_pose_*, not from the internal process).
##
## On 4.7.2 every Skeleton3D in the tree has an internal process by default
## (READ skeleton_3d.cpp `_process_changed`, mode Idle), which queued a
## deferred update every frame for each of them (round 757: 38.5 ms of wall a
## frame at 18,035). `godot4 --headless --path client --script
## res://scripts/assets/skeleton_process_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _template() -> Skeleton3D:
	var t := Skeleton3D.new()
	t.add_bone("root")
	t.add_bone("arm")
	t.set_bone_parent(1, 0)
	t.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(10, 0, 0)))
	t.reset_bone_pose(0)
	t.reset_bone_pose(1)
	return t

func _initialize() -> void:
	var v4_3: bool = int(Engine.get_version_info().hex) >= 0x040300
	var t := _template()
	Skeleton3DBuilder.no_physics_step(t)
	# As the client builds bodies: the template's duplicates go in the tree.
	var plain := _template()
	root.add_child(plain)
	var s := t.duplicate() as Skeleton3D
	root.add_child(s)
	var att := BoneAttachment3D.new()
	att.bone_name = "arm"
	s.add_child(att)
	var updates := [0]
	if v4_3:
		s.connect("skeleton_updated", func() -> void: updates[0] += 1)
	await process_frame
	await process_frame

	_check(not s.is_physics_processing_internal(), "a built skeleton's duplicate has no physics-step callback")
	_check(not s.is_processing_internal(), "a built skeleton's duplicate has no per-frame internal process")
	if v4_3:
		_check(int(s.get("modifier_callback_mode_process")) == Skeleton3DBuilder.MODIFIER_CALLBACK_MANUAL,
			"4.3+: the duplicate inherits the Manual modifier callback")
		_check(plain.is_processing_internal(), "probe: an untouched 4.3+ Skeleton3D does process every frame (the cost removed)")
	# Still off after leaving and re-entering the tree (_process_changed runs at ENTER_TREE).
	root.remove_child(s)
	root.add_child(s)
	await process_frame
	_check(not s.is_processing_internal() and not s.is_physics_processing_internal(),
		"re-entering the tree keeps both callbacks off")

	# Unposed frames: no deferred update is queued for it.
	var before: int = updates[0]
	for i in range(5):
		await process_frame
	if v4_3:
		_check(updates[0] == before, "4.3+: no skeleton update in 5 unposed frames (%d)" % (updates[0] - before))

	# A pose still reaches the attachment and the skin through the deferred update.
	s.set_bone_pose_rotation(0, Quaternion(Vector3.UP, PI / 2.0))
	await process_frame
	var p := att.global_transform.origin
	_check(p.distance_to(Vector3(0, 0, -10)) < 0.01, "a posed skeleton moves its attachment (%s)" % str(p))
	if v4_3:
		_check(updates[0] == before + 1, "4.3+: the pose ran exactly one skeleton update (%d)" % (updates[0] - before))

	plain.queue_free()
	s.queue_free()
	t.free()
	await process_frame
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit()
