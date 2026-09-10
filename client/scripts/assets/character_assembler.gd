extends RefCounted
class_name CharacterAssembler

## Rigid assembly of a character body from .bms body-part meshes onto a
## Skeleton3D: each piece hung off one bone, paired pieces split down the
## middle. **This is no longer how the player is drawn.** `.bms` carries
## real per-vertex skinning (BMS_FORMAT.md, hundred-and-tenth round), and
## SkinnedBsrAssembler binds every piece -- body and worn items alike -- by
## its own bone palette. What remains here is `attach_rigid`, the fallback
## for a mesh with no weights, and `assemble`, which the render_character
## dev tool still drives.
##
## The paragraphs below are the reasoning this file was built on, kept
## because the X-sign split and the rigid offset arithmetic are still what
## attach_rigid does. The claim they open with -- that .bms has no bone
## weights -- was wrong: the weights sit in their own section, not in the
## 44-byte vertex record that was audited. What real files do with each
## paired body part (thigh, calf, upper arm, forearm) is ONE .bms file
## containing BOTH left and right sides already baked in as two mirrored,
## non-overlapping vertex/triangle ranges (confirmed by inspecting
## man_thigh.bms directly: vertex 0 at x=+0.872 and vertex 23 at x=-0.872
## are exact mirrors, with no per-vertex tag distinguishing them --
## splitting by which side of x=0 a triangle's centroid falls on is the
## only distinguishing signal found). Unpaired parts (pelvis) are one
## piece, one bone, no split needed -- **corrected 2026-08-28**: this used
## to also claim torso was a single unpaired piece, but a real check of
## `Data.pk2` (`Prim\Mesh\Char\China\<gender>\<gender>_torso_upper.bms` /
## `_torso_lower.bms`) found it's actually two unpaired pieces, each its
## own single bone (`Bip01 Spine`/`Bip01 Spine1` -- see the map below,
## which already handled this correctly; only this comment was stale).
##
## Rigid attachment math: each body-part mesh's vertex positions are baked
## in real absolute character-space coordinates (the same "no extra
## transform" pattern confirmed for .bsr sub-mesh pieces -- see
## docs/protocol/BSR_FORMAT.md), not bone-local coordinates. To keep that
## baked position correct at bind pose while still rotating rigidly with
## the bone as it animates, each mesh piece is attached via a
## BoneAttachment3D with the MeshInstance3D child's own position offset by
## the *negative* of that bone's bind-pose global position (derived here,
## not from SkeletonPose, via Skeleton3D's own get_bone_global_rest()):
## world_position = bone_pose.origin + bone_pose.basis * (mesh_offset + vertex)
##                = bone_rest.origin + bone_pose.basis * (vertex - bone_rest.origin)
## which is exactly "rotate vertex around the bone's own bind position",
## the same rigid-rotation formula SkeletonPose.apply_rotation/
## Skeleton3DBuilder.apply_ban_keyframe already use and have verified.
##
## The body-part-name -> bone-name mapping below is inferred from filename
## substrings matching real .bsk bone names (e.g. "thigh" -> "Bip01 *
## Thigh") -- plausible, not confirmed via decompilation. No file tying a
## specific mesh set to a specific skeleton was found (no per-character
## .bsr or equivalent index -- see docs/protocol/MAPO_FORMAT.md for the
## broader "no resource-ID mapping found" pattern), so this is a
## best-effort heuristic, not a settled fact.

## Maps a body-part-name substring (after stripping a "man_"/"woman_"-style
## gender prefix) to the bone name(s) it plausibly belongs to: a
## single-element array for an unpaired part (attached as-is), or a
## two-element [positive-X bone, negative-X bone] array for a paired part
## (mesh split by triangle-centroid X sign).
const BODY_PART_BONES := {
	"pelvis": ["Bip01 Pelvis"],
	"torso_lower": ["Bip01 Spine"],
	"torso_upper": ["Bip01 Spine1"],
	"thigh": ["Bip01 R Thigh", "Bip01 L Thigh"],
	"calf": ["Bip01 R Calf", "Bip01 L Calf"],
	"arm_upper": ["Bip01 R UpperArm", "Bip01 L UpperArm"],
	# China-man's real forearm mesh is "man_arm_lower"; China-woman's real
	# equivalent is "woman_arm_fore" -- different filename convention, same
	# real "Bip01 R/L Forearm" bones (confirmed directly: chinawoman_skel.bsk
	# carries those exact bone name strings, same as the man skeleton).
	"arm_lower": ["Bip01 R Forearm", "Bip01 L Forearm"],
	"arm_fore": ["Bip01 R Forearm", "Bip01 L Forearm"],
	# A real face and hair are separate meshes from the body, named for the
	# character's style ("chinaman_fighter_face") rather than with the
	# "man_" prefix the body parts use, and both hang off the head bone.
	# Keyed on the suffix alone so one entry covers every style -- see
	# _strip_prefix's own note.
	"face": ["Bip01 Head"],
	"hair": ["Bip01 Head"],
}

## Strips a leading "<word>_" gender/race prefix (e.g. "man_thigh" ->
## "thigh", "woman_arm_upper" -> "arm_upper") so BODY_PART_BONES lookups
## don't need one entry per character variant.
static func _strip_prefix(part_name: String) -> String:
	var us := part_name.find("_")
	if us == -1:
		return part_name
	return part_name.substr(us + 1)

## Attaches one real paired mesh to its two real bones, positive-X half to
## the **left** bone and negative-X half to the right.
##
## That looks backwards against BODY_PART_BONES,
## which list the right bone first, and it was written the other way round
## for exactly that reason. It is wrong: in a real body part's own bind
## space, **+X is the character's left**.
##
## The mistake is invisible in the bind pose, because a real bind pose is
## symmetric -- each half lands where the other would have, so the
## character assembles correctly and nothing looks amiss. It only shows
## once something drives the two bones differently, which is why it
## survived until animation playback was attempted: with the halves
## crossed, each arm is pulled toward the other's bone and the character
## renders with both arms swung up over its head. Swapping the pairing
## gives a correct standing pose, arms at the sides, on the very frame
## that previously showed arms overhead.
##
## Every link either side of this had already been measured and found
## correct -- posed bone globals matching the same animation applied
## offline exactly, each BoneAttachment3D sitting on its own bone, each
## piece's transform equal to inverse(bone_global_rest) to the last digit
## -- see docs/WORLD_ISSUES.md's ninety-third and ninety-fourth rounds.
static func _attach_paired(
	skeleton: Skeleton3D, mesh: BmsReader.ParsedMesh, bones: Array, material: Material
) -> void:
	attach_rigid(skeleton, _build_side_mesh(mesh, true), bones[1], material)
	attach_rigid(skeleton, _build_side_mesh(mesh, false), bones[0], material)

## Builds an ArrayMesh from only the triangles of mesh whose centroid x is
## on the requested side (>= 0 for positive, < 0 for negative). Vertices
## aren't compacted/remapped -- unused ones are simply never referenced by
## the filtered index list, which Godot handles fine.
static func _build_side_mesh(mesh: BmsReader.ParsedMesh, positive_side: bool) -> ArrayMesh:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	positions.resize(mesh.vertices.size())
	normals.resize(mesh.vertices.size())
	uvs.resize(mesh.vertices.size())
	for i in range(mesh.vertices.size()):
		positions[i] = mesh.vertices[i].position
		normals[i] = mesh.vertices[i].normal
		uvs[i] = mesh.vertices[i].uv

	var indices := PackedInt32Array()
	var tri_count := mesh.indices.size() / 3
	for t in range(tri_count):
		var i0 := mesh.indices[t * 3]
		var i1 := mesh.indices[t * 3 + 1]
		var i2 := mesh.indices[t * 3 + 2]
		var centroid_x := (mesh.vertices[i0].position.x + mesh.vertices[i1].position.x + mesh.vertices[i2].position.x) / 3.0
		var on_positive_side := centroid_x >= 0.0
		if on_positive_side == positive_side:
			indices.append(i0)
			indices.append(i1)
			indices.append(i2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

## Attaches one real ArrayMesh rigidly to bone_name on skeleton via a
## BoneAttachment3D, offsetting the mesh instance so the mesh's own baked
## absolute-space vertex positions land correctly at bind pose and rotate
## rigidly around that bone's bind position as it animates -- see this
## file's top comment for the derivation. Public (2026-09-01) -- also used
## by MonsterAssembler; see monster_assembler.gd's own top comment for
## whether the same real convention was confirmed to hold for monster
## meshes too.
static func attach_rigid(skeleton: Skeleton3D, array_mesh: ArrayMesh, bone_name: String, material: Material) -> void:
	var bone_idx := skeleton.find_bone(bone_name)
	if bone_idx == -1:
		push_error("CharacterAssembler: skeleton has no bone named %s" % bone_name)
		return

	var attachment := BoneAttachment3D.new()
	attachment.bone_name = bone_name
	skeleton.add_child(attachment)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = array_mesh
	if material != null:
		mesh_instance.material_override = material
	# **Corrected 2026-09-02** (see docs/WORLD_ISSUES.md's forty-eighth
	# round): was `mesh_instance.position = -get_bone_global_rest(idx).origin`,
	# which cancels only the bone's rest *translation*. A BoneAttachment3D
	# applies the bone's full global pose -- rotation included -- so
	# cancelling just the translation left every piece spuriously rotated by
	# its own bone's rest rotation. That was harmless while bone rest
	# rotations were all identity, but stopped being harmless on 2026-08-28
	# when Skeleton3DBuilder began using each bone's real .bsk bind rotation:
	# from then on the real assembled character rendered as detached limbs
	# splayed outward (measured 21.1 units wide against only 12.8 tall -- a
	# real humanoid is far taller than wide). It went unnoticed because the
	# character was simultaneously being drawn ~10x too small to see, for the
	# unrelated reason corrected in World3D's REAL_CHARACTER_NATIVE_HEIGHT.
	#
	# Cancelling the *whole* rest transform is the correct inverse: the
	# attachment contributes bone_global_pose, this contributes
	# inverse(bone_global_rest), so at rest the two cancel exactly and each
	# real mesh stays at the absolute bind-pose coordinates its own vertices
	# are already expressed in -- while still moving rigidly with the bone
	# once a real animation drives the pose away from rest.
	mesh_instance.transform = skeleton.get_bone_global_rest(bone_idx).affine_inverse()
	attachment.add_child(mesh_instance)

## Assembles every part in parts (body-part-name -> ParsedMesh, e.g. from
## BmsReader.parse() on "man_thigh.bms" keyed by "thigh") onto skeleton,
## splitting paired parts by X sign and attaching each piece rigidly to its
## matching bone per BODY_PART_BONES. Unrecognized part names are skipped
## with a printed warning, not an error -- a real, incomplete part list
## (e.g. missing hands/feet/head meshes) is expected, not a failure.
##
## Each part's real material is resolved by its own mesh.material_name (a
## real field baked into every .bms file) against materials_by_name -- e.g.
## a real man_thigh.bms's material_name reads "chinaman_body", which is also
## the real layer_name found inside a real chinaman_warrior.bmt, confirmed
## by inspecting both files directly (see docs/protocol/BMT_FORMAT.md). This
## is a real name-matched pairing, not the index-based guess ObjectLoader
## falls back to for .bsr pieces. Falls back to default_material (or no
## material at all) for any part whose material_name isn't in the map, so
## this still works with a single flat color for callers that don't have a
## resolved .bmt (see World3D.gd for a caller that does).
static func assemble(skeleton: Skeleton3D, parts: Dictionary, default_material: Material = null, materials_by_name: Dictionary = {}) -> void:
	for part_name in parts:
		var key := _strip_prefix(part_name)
		# A style-named head mesh ("chinaman_fighter_face") reduces to
		# "fighter_face" here, which no mapping can list for every style;
		# its suffix is what identifies it.
		if key.ends_with("face"):
			key = "face"
		elif key.ends_with("hair"):
			key = "hair"
		if not BODY_PART_BONES.has(key):
			print("CharacterAssembler: no bone mapping for body part %s (key %s) -- skipped" % [part_name, key])
			continue
		var bones: Array = BODY_PART_BONES[key]
		var mesh: BmsReader.ParsedMesh = parts[part_name]
		var material: Material = materials_by_name.get(mesh.material_name, default_material)

		if bones.size() == 1:
			attach_rigid(skeleton, BmsReader.to_array_mesh(mesh), bones[0], material)
		else:
			_attach_paired(skeleton, mesh, bones, material)
