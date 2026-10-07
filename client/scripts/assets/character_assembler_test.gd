extends SceneTree

## Exercises CharacterAssembler against a synthetic mesh + skeleton (never
## real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/character_assembler_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A tiny synthetic "paired" mesh: one triangle entirely at x>0 (the "right"
## side) and one triangle entirely at x<0 (the "left" side), mirrored --
## the same shape real man_thigh.bms was confirmed to have.
func _build_mesh() -> BmsReader.ParsedMesh:
	var mesh := BmsReader.ParsedMesh.new()
	var right := [Vector3(1, 0, 0), Vector3(2, 0, 0), Vector3(1, 1, 0)]
	var left := [Vector3(-1, 0, 0), Vector3(-2, 0, 0), Vector3(-1, 1, 0)]
	for p in right + left:
		var v := BmsReader.Vertex.new()
		v.position = p
		v.normal = Vector3.UP
		v.uv = Vector2.ZERO
		mesh.vertices.append(v)
	mesh.indices = PackedInt32Array([0, 1, 2, 3, 4, 5])
	return mesh

func _build_skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("Root")
	var root_idx := skeleton.find_bone("Root")
	skeleton.set_bone_rest(root_idx, Transform3D.IDENTITY)

	skeleton.add_bone("Bip01 R Thigh")
	var r_idx := skeleton.find_bone("Bip01 R Thigh")
	skeleton.set_bone_parent(r_idx, root_idx)
	skeleton.set_bone_rest(r_idx, Transform3D(Basis.IDENTITY, Vector3(1.5, 0, 0)))

	skeleton.add_bone("Bip01 L Thigh")
	var l_idx := skeleton.find_bone("Bip01 L Thigh")
	skeleton.set_bone_parent(l_idx, root_idx)
	skeleton.set_bone_rest(l_idx, Transform3D(Basis.IDENTITY, Vector3(-1.5, 0, 0)))

	for idx in [root_idx, r_idx, l_idx]:
		skeleton.reset_bone_pose(idx)
	Skeleton3DBuilder.refresh_global_poses(skeleton)
	return skeleton

func _init() -> void:
	var skeleton := _build_skeleton()
	var mesh := _build_mesh()

	CharacterAssembler.assemble(skeleton, {"man_thigh": mesh})

	var attachments: Array[BoneAttachment3D] = []
	for child in skeleton.get_children():
		if child is BoneAttachment3D:
			attachments.append(child)
	_check(attachments.size() == 2, "2 BoneAttachment3D nodes created (got %d)" % attachments.size())

	var by_bone := {}
	for a in attachments:
		by_bone[a.bone_name] = a

	_check(by_bone.has("Bip01 R Thigh") and by_bone.has("Bip01 L Thigh"), "attachments target the right bones")

	if by_bone.has("Bip01 R Thigh"):
		var mi: MeshInstance3D = by_bone["Bip01 R Thigh"].get_child(0)
		var am: ArrayMesh = mi.mesh
		var arrays := am.surface_get_arrays(0)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		_check(idx.size() == 3, "right-side mesh has exactly 1 triangle (got %d indices)" % idx.size())
		_check(mi.position.is_equal_approx(Vector3(-1.5, 0, 0)), "right mesh instance offset matches -bind position (got %s)" % mi.position)

	if by_bone.has("Bip01 L Thigh"):
		var mi: MeshInstance3D = by_bone["Bip01 L Thigh"].get_child(0)
		var am: ArrayMesh = mi.mesh
		var arrays := am.surface_get_arrays(0)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		_check(idx.size() == 3, "left-side mesh has exactly 1 triangle (got %d indices)" % idx.size())
		_check(mi.position.is_equal_approx(Vector3(1.5, 0, 0)), "left mesh instance offset matches -bind position (got %s)" % mi.position)

	# An unpaired part (single bone, no split) and an unrecognized part
	# name (skipped, not an error).
	var pelvis_mesh := BmsReader.ParsedMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)]:
		var pv := BmsReader.Vertex.new()
		pv.position = p
		pv.normal = Vector3.UP
		pv.uv = Vector2.ZERO
		pelvis_mesh.vertices.append(pv)
	pelvis_mesh.indices = PackedInt32Array([0, 1, 2])

	var skeleton2 := Skeleton3D.new()
	skeleton2.add_bone("Bip01 Pelvis")
	var p_idx := skeleton2.find_bone("Bip01 Pelvis")
	skeleton2.set_bone_rest(p_idx, Transform3D(Basis.IDENTITY, Vector3(0, 5, 0)))
	skeleton2.reset_bone_pose(p_idx)
	Skeleton3DBuilder.refresh_global_poses(skeleton2)

	CharacterAssembler.assemble(skeleton2, {"man_pelvis": pelvis_mesh, "man_nonsense_part": pelvis_mesh})
	var attachments2 := 0
	for child in skeleton2.get_children():
		if child is BoneAttachment3D:
			attachments2 += 1
	_check(attachments2 == 1, "unpaired part gets exactly 1 attachment, unrecognized part skipped (got %d)" % attachments2)

	# China-woman's real forearm mesh is named "woman_arm_fore", not
	# "..._arm_lower" like China-man's -- confirm it still resolves to the
	# same real paired forearm bones (see BODY_PART_BONES's arm_fore entry).
	var skeleton2b := Skeleton3D.new()
	skeleton2b.add_bone("Bip01 R Forearm")
	skeleton2b.add_bone("Bip01 L Forearm")
	for bone_name in ["Bip01 R Forearm", "Bip01 L Forearm"]:
		var bi := skeleton2b.find_bone(bone_name)
		skeleton2b.set_bone_rest(bi, Transform3D(Basis.IDENTITY, Vector3.ZERO))
		skeleton2b.reset_bone_pose(bi)
	Skeleton3DBuilder.refresh_global_poses(skeleton2b)
	CharacterAssembler.assemble(skeleton2b, {"woman_arm_fore": mesh})
	var forearm_attachments := 0
	for child in skeleton2b.get_children():
		if child is BoneAttachment3D:
			forearm_attachments += 1
	_check(forearm_attachments == 2, "woman_arm_fore resolves to both real forearm bones like man_arm_lower does (got %d)" % forearm_attachments)

	# Equipment: a paired slot ("aa" -> arm, split by x-sign like a paired
	# body part) and an unpaired slot ("ba" -> body, single bone, no split).
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
