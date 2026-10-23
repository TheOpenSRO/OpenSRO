extends SceneTree

## Round 816: a skeletal model's piece with no bone palette stands still in
## the model's own space (SkinnedBsrAssembler.still_piece_mesh; READ, the
## original's palette entry 0 is the identity). Synthetic mesh and skeleton,
## never game data:
## `godot4 --headless --path client --script res://scripts/assets/still_piece_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A chest-like piece with no palette: two triangles well away from the origin.
func _bare_mesh() -> BmsReader.ParsedMesh:
	var mesh := BmsReader.ParsedMesh.new()
	for p in [Vector3(4, 0, 6), Vector3(8, 0, 6), Vector3(4, 5, 6), Vector3(8, 5, 6)]:
		var v := BmsReader.Vertex.new()
		v.position = p
		v.normal = Vector3.BACK
		v.uv = Vector2.ZERO
		mesh.vertices.append(v)
	mesh.indices = PackedInt32Array([0, 1, 2, 2, 1, 3])
	return mesh

## A two-bone skeleton whose child bone sits near the piece -- the bone the
## old rigid path would have hung it from.
func _skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("Bip01")
	skeleton.set_bone_rest(0, Transform3D.IDENTITY)
	skeleton.add_bone("Bip01 R Clavicle")
	skeleton.set_bone_parent(1, 0)
	skeleton.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(6, 3, 6)))
	for i in range(skeleton.get_bone_count()):
		skeleton.reset_bone_pose(i)
	return skeleton

## Where Godot's skinning puts vertex k of `am` under `skin` on `skeleton`'s
## current pose: sum of weight x (bone global pose x bind) x position.
func _skinned(am: ArrayMesh, skin: Skin, skeleton: Skeleton3D, k: int) -> Vector3:
	var arrays := am.surface_get_arrays(0)
	var pos: Vector3 = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)[k]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var out := Vector3.ZERO
	for j in range(4):
		var w := weights[k * 4 + j]
		if w == 0.0:
			continue
		var b := bones[k * 4 + j]
		var bone := skin.get_bind_bone(b)
		out += w * (skeleton.get_bone_global_pose(bone) * skin.get_bind_pose(b) * pos)
	return out

func _init() -> void:
	var mesh := _bare_mesh()
	_check(not mesh.is_skinned(), "the piece has no palette")

	# A one-bind skin, as the assembler builds for a body without canonical.
	var skeleton := _skeleton()
	var skin := Skin.new()
	skin.add_bind(Skeleton3DBuilder._object_space_bone(skeleton), Transform3D.IDENTITY)
	var am := SkinnedBsrAssembler.still_piece_mesh(mesh, 0)
	var arrays := am.surface_get_arrays(0)
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	_check(bones.size() == 16 and weights.size() == 16, "four influences per vertex")
	var whole := true
	for k in range(4):
		whole = whole and bones[k * 4] == 0 and weights[k * 4] == 1.0
		whole = whole and weights[k * 4 + 1] == 0.0 and weights[k * 4 + 2] == 0.0 and weights[k * 4 + 3] == 0.0
	_check(whole, "every vertex wholly on the skin's one bind")
	_check(am.has_meta(BmsReader.KEPT_ARRAYS_META), "the arrays are kept, as to_array_mesh(.., true) keeps them")

	# At rest, and with the nearby bone and the root swung away, every vertex
	# stays where the file put it.
	var before: Array[Vector3] = []
	for k in range(4):
		before.append(_skinned(am, skin, skeleton, k))
	_check(before[0].is_equal_approx(Vector3(4, 0, 6)) and before[3].is_equal_approx(Vector3(8, 5, 6)),
		"at rest the piece is at its own vertices")
	skeleton.set_bone_pose_position(0, Vector3(0, 2.5, 0))
	skeleton.set_bone_pose_rotation(1, Quaternion(Vector3.FORWARD, 0.6))
	skeleton.set_bone_pose_position(1, Vector3(6, 4, 6))
	var still := true
	for k in range(4):
		still = still and _skinned(am, skin, skeleton, k).is_equal_approx(before[k])
	_check(still, "posing the skeleton (root raised, clavicle turned) leaves it in place")

	# Under canonical_skin the vertex names the skeleton's own index of the
	# object-space bone.
	var canon_skel := _skeleton()
	var obj := Skeleton3DBuilder._object_space_bone(canon_skel)
	var canon := Skeleton3DBuilder.canonical_skin(canon_skel)
	var cam := SkinnedBsrAssembler.still_piece_mesh(mesh, obj)
	var cb: PackedInt32Array = cam.surface_get_arrays(0)[Mesh.ARRAY_BONES]
	_check(cb[0] == obj and canon.get_bind_bone(obj) == obj, "canonical: the object-space bone's own index")
	canon_skel.set_bone_pose_position(0, Vector3(0, 2.5, 0))
	_check(_skinned(cam, canon, canon_skel, 1).is_equal_approx(Vector3(8, 0, 6)),
		"canonical: a raised root leaves it in place")

	skeleton.free()
	canon_skel.free()
	print("still_piece_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
