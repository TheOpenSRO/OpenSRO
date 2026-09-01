extends SceneTree

## Exercises MonsterAssembler against a synthetic mesh + skeleton (never
## real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/monster_assembler_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _build_mesh(offset: Vector3) -> BmsReader.ParsedMesh:
	var mesh := BmsReader.ParsedMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)]:
		var v := BmsReader.Vertex.new()
		v.position = p + offset
		v.normal = Vector3.UP
		v.uv = Vector2.ZERO
		mesh.vertices.append(v)
	mesh.indices = PackedInt32Array([0, 1, 2])
	return mesh

func _build_skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("Root")
	var root_idx := skeleton.find_bone("Root")
	skeleton.set_bone_rest(root_idx, Transform3D.IDENTITY)

	skeleton.add_bone("Core")
	var core_idx := skeleton.find_bone("Core")
	skeleton.set_bone_parent(core_idx, root_idx)
	skeleton.set_bone_rest(core_idx, Transform3D(Basis.IDENTITY, Vector3(0, 5, 0)))

	skeleton.add_bone("Limb")
	var limb_idx := skeleton.find_bone("Limb")
	skeleton.set_bone_parent(limb_idx, root_idx)
	skeleton.set_bone_rest(limb_idx, Transform3D(Basis.IDENTITY, Vector3(3, 0, 0)))

	for idx in [root_idx, core_idx, limb_idx]:
		skeleton.reset_bone_pose(idx)
	skeleton.force_update_all_bone_transforms()
	return skeleton

func _init() -> void:
	var skeleton := _build_skeleton()
	var parts := {
		"piece_core": _build_mesh(Vector3(0, 5, 0)),
		"piece_limb": _build_mesh(Vector3(3, 0, 0)),
		"piece_unrecognized": _build_mesh(Vector3.ZERO),
	}
	var piece_bones := {
		"piece_core": "Core",
		"piece_limb": "Limb",
		# "piece_unrecognized" deliberately has no entry.
	}
	var mat := StandardMaterial3D.new()

	MonsterAssembler.assemble(skeleton, parts, piece_bones, mat)

	var attachments: Array[BoneAttachment3D] = []
	for child in skeleton.get_children():
		if child is BoneAttachment3D:
			attachments.append(child)
	_check(attachments.size() == 2, "2 real BoneAttachment3D nodes created for the 2 mapped pieces (got %d)" % attachments.size())

	var bone_names := []
	for a in attachments:
		bone_names.append(a.bone_name)
	_check(bone_names.has("Core") and bone_names.has("Limb"), "attachments target the real mapped bones (got %s)" % [bone_names])

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
