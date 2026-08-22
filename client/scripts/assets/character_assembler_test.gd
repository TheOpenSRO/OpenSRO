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
	skeleton.force_update_all_bone_transforms()
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
	skeleton2.force_update_all_bone_transforms()

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
	skeleton2b.force_update_all_bone_transforms()
	CharacterAssembler.assemble(skeleton2b, {"woman_arm_fore": mesh})
	var forearm_attachments := 0
	for child in skeleton2b.get_children():
		if child is BoneAttachment3D:
			forearm_attachments += 1
	_check(forearm_attachments == 2, "woman_arm_fore resolves to both real forearm bones like man_arm_lower does (got %d)" % forearm_attachments)

	# Equipment: a paired slot ("aa" -> arm, split by x-sign like a paired
	# body part) and an unpaired slot ("ba" -> body, single bone, no split).
	var skeleton3 := Skeleton3D.new()
	skeleton3.add_bone("Root")
	var root3 := skeleton3.find_bone("Root")
	skeleton3.set_bone_rest(root3, Transform3D.IDENTITY)
	skeleton3.add_bone("Bip01 R Forearm")
	var r_arm := skeleton3.find_bone("Bip01 R Forearm")
	skeleton3.set_bone_parent(r_arm, root3)
	skeleton3.set_bone_rest(r_arm, Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)))
	skeleton3.add_bone("Bip01 L Forearm")
	var l_arm := skeleton3.find_bone("Bip01 L Forearm")
	skeleton3.set_bone_parent(l_arm, root3)
	skeleton3.set_bone_rest(l_arm, Transform3D(Basis.IDENTITY, Vector3(-2, 0, 0)))
	skeleton3.add_bone("Bip01 Spine1")
	var spine1 := skeleton3.find_bone("Bip01 Spine1")
	skeleton3.set_bone_parent(spine1, root3)
	skeleton3.set_bone_rest(spine1, Transform3D(Basis.IDENTITY, Vector3(0, 10, 0)))
	for idx in [root3, r_arm, l_arm, spine1]:
		skeleton3.reset_bone_pose(idx)
	skeleton3.force_update_all_bone_transforms()

	var gauntlet_mesh := _build_mesh() # reuse the paired left/right fixture
	var body_mesh := BmsReader.ParsedMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)]:
		var bv := BmsReader.Vertex.new()
		bv.position = p
		bv.normal = Vector3.UP
		bv.uv = Vector2.ZERO
		body_mesh.vertices.append(bv)
	body_mesh.indices = PackedInt32Array([0, 1, 2])

	CharacterAssembler.assemble_equipment(skeleton3, {
		"clothes_03_aa": gauntlet_mesh,
		"clothes_03_ba": body_mesh,
		"clothes_03_nn": body_mesh, # unrecognized slot code, should be skipped
	})
	var eq_attachments := {}
	for child in skeleton3.get_children():
		if child is BoneAttachment3D:
			eq_attachments[child.bone_name] = child
	_check(eq_attachments.size() == 3, "equipment: paired slot makes 2 attachments + unpaired slot makes 1, unrecognized skipped (got %d)" % eq_attachments.size())
	_check(eq_attachments.has("Bip01 R Forearm") and eq_attachments.has("Bip01 L Forearm"), "equipment: paired 'aa' slot attaches to both forearms")
	_check(eq_attachments.has("Bip01 Spine1"), "equipment: unpaired 'ba' slot attaches to Spine1")

	# Weapon: a single unpaired mesh (no slot-code parsing, unlike
	# equipment) rigidly attaches to the real WEAPON_BONE.
	var skeleton4 := Skeleton3D.new()
	skeleton4.add_bone("Root")
	var root4 := skeleton4.find_bone("Root")
	skeleton4.set_bone_rest(root4, Transform3D.IDENTITY)
	skeleton4.add_bone(CharacterAssembler.WEAPON_BONE)
	var hand_idx := skeleton4.find_bone(CharacterAssembler.WEAPON_BONE)
	skeleton4.set_bone_parent(hand_idx, root4)
	skeleton4.set_bone_rest(hand_idx, Transform3D(Basis.IDENTITY, Vector3(3, 0, 0)))
	for idx in [root4, hand_idx]:
		skeleton4.reset_bone_pose(idx)
	skeleton4.force_update_all_bone_transforms()

	var weapon_mesh := BmsReader.ParsedMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)]:
		var wv := BmsReader.Vertex.new()
		wv.position = p
		wv.normal = Vector3.UP
		wv.uv = Vector2.ZERO
		weapon_mesh.vertices.append(wv)
	weapon_mesh.indices = PackedInt32Array([0, 1, 2])

	CharacterAssembler.assemble_weapon(skeleton4, weapon_mesh)
	var weapon_attachments := 0
	var weapon_mi: MeshInstance3D = null
	for child in skeleton4.get_children():
		if child is BoneAttachment3D and child.bone_name == CharacterAssembler.WEAPON_BONE:
			weapon_attachments += 1
			weapon_mi = child.get_child(0)
	_check(weapon_attachments == 1, "weapon: exactly 1 attachment on the real hand bone (got %d)" % weapon_attachments)
	_check(weapon_mi != null and weapon_mi.position.is_equal_approx(Vector3(-3, 0, 0)), "weapon: mesh instance offset matches -bind position")

	# Shield: same single-unpaired-mesh mechanism as weapon, but the real
	# off-hand bone.
	var skeleton5 := Skeleton3D.new()
	skeleton5.add_bone("Root")
	var root5 := skeleton5.find_bone("Root")
	skeleton5.set_bone_rest(root5, Transform3D.IDENTITY)
	skeleton5.add_bone(CharacterAssembler.SHIELD_BONE)
	var off_hand_idx := skeleton5.find_bone(CharacterAssembler.SHIELD_BONE)
	skeleton5.set_bone_parent(off_hand_idx, root5)
	skeleton5.set_bone_rest(off_hand_idx, Transform3D(Basis.IDENTITY, Vector3(-3, 0, 0)))
	for idx in [root5, off_hand_idx]:
		skeleton5.reset_bone_pose(idx)
	skeleton5.force_update_all_bone_transforms()

	var shield_mesh := BmsReader.ParsedMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)]:
		var sv := BmsReader.Vertex.new()
		sv.position = p
		sv.normal = Vector3.UP
		sv.uv = Vector2.ZERO
		shield_mesh.vertices.append(sv)
	shield_mesh.indices = PackedInt32Array([0, 1, 2])

	CharacterAssembler.assemble_shield(skeleton5, shield_mesh)
	var shield_attachments := 0
	var shield_mi: MeshInstance3D = null
	for child in skeleton5.get_children():
		if child is BoneAttachment3D and child.bone_name == CharacterAssembler.SHIELD_BONE:
			shield_attachments += 1
			shield_mi = child.get_child(0)
	_check(shield_attachments == 1, "shield: exactly 1 attachment on the real off-hand bone (got %d)" % shield_attachments)
	_check(shield_mi != null and shield_mi.position.is_equal_approx(Vector3(3, 0, 0)), "shield: mesh instance offset matches -bind position")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
