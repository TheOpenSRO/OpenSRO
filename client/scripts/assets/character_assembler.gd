extends RefCounted
class_name CharacterAssembler

## Assembles a real character body from real .bms body-part meshes onto a
## real Skeleton3D -- the piece that turns Skeleton3DBuilder's bare stick
## figure into an actual (if rigidly-jointed, not smoothly skinned) human
## shape.
##
## Confirmed from real data (server China-man body parts +
## Prim/Skel/Char/China/chinaman_skel.bsk): there's no per-vertex bone
## weight data anywhere in .bms (the whole 44-byte vertex record is
## accounted for by position/normal/UV/a 12-byte field already shown to be
## something else -- see docs/protocol/BMS_FORMAT.md), so this project
## can't do smooth skinning. What real files actually do instead: each
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
}

## Strips a leading "<word>_" gender/race prefix (e.g. "man_thigh" ->
## "thigh", "woman_arm_upper" -> "arm_upper") so BODY_PART_BONES lookups
## don't need one entry per character variant.
static func _strip_prefix(part_name: String) -> String:
	var us := part_name.find("_")
	if us == -1:
		return part_name
	return part_name.substr(us + 1)

## Maps a real equipment-item mesh's trailing 2-letter slot code (e.g.
## "clothes_03_aa" -> "aa") to the bone(s) it plausibly belongs to -- same
## [positive-X, negative-X] convention as BODY_PART_BONES for paired slots.
## Inferred the same way BODY_PART_BONES was (filename convention matched
## against real .bsk bone names, not decompiled), plus a real,
## directly-observed structural signal this project didn't have for body
## parts: a triangle-centroid-X gap scan on 6 real clothes_03_*.bms files
## found "aa"/"fa"/"sa" each split into two disjoint x-ranges (gap >5 units,
## centered near x=0 -- genuinely paired L/R pieces baked into one file,
## the same shape as a body part), while "ba"/"ha"/"la" stayed continuous
## (gap <1 unit, off-center) -- real, unpaired single pieces. Slot-name
## codes themselves (aa=arm, ba=body, fa=foot, ha=head, la=leg, sa=shoulder)
## match the standard 6-piece real armor set convention this project found
## real files for; the specific bone each maps to is still an inferred
## guess, same honesty level as BODY_PART_BONES.
const EQUIPMENT_SLOT_BONES := {
	"ha": ["Bip01 Head"],
	"ba": ["Bip01 Spine1"],
	"la": ["Bip01 Pelvis"],
	"sa": ["Bip01 R Clavicle", "Bip01 L Clavicle"],
	"aa": ["Bip01 R Forearm", "Bip01 L Forearm"],
	"fa": ["Bip01 R Foot", "Bip01 L Foot"],
}

## Real, confirmed limitation found by direct visual verification (color-coded,
## unshaded, non-culled render of each slot in isolation) against a real
## clothes_03 set: "ha"/"ba"/"la"/"fa"/"aa" all land exactly where a real
## character's head/torso/legs/feet/forearms are -- their raw baked vertex
## coordinates are real absolute character-space positions, the same
## confirmed convention body parts use (see this file's top comment) -- but
## "sa" (the shoulder piece) does not: its raw Y range (~0.9-2.3) is roughly
## 13 units below Bip01 Clavicle's real rest height (~15), so it renders
## down near the pelvis instead of at the shoulder. Not yet understood why
## this one real slot's coordinates differ from the other five (a different,
## unconfirmed local-pivot convention for small standalone accessory props
## is the leading guess, not confirmed) -- flagged honestly rather than
## silently mispositioning a real shoulder pad near a character's hip.

## Extracts a real equipment mesh's trailing 2-letter slot code from its
## name (e.g. "clothes_03_aa" -> "aa"), or "" if the name doesn't end in
## "_XX" shape.
static func _equipment_slot(part_name: String) -> String:
	var us := part_name.rfind("_")
	if us == -1 or part_name.length() - us - 1 != 2:
		return ""
	return part_name.substr(us + 1)

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
		if not BODY_PART_BONES.has(key):
			print("CharacterAssembler: no bone mapping for body part %s (key %s) -- skipped" % [part_name, key])
			continue
		var bones: Array = BODY_PART_BONES[key]
		var mesh: BmsReader.ParsedMesh = parts[part_name]
		var material: Material = materials_by_name.get(mesh.material_name, default_material)

		if bones.size() == 1:
			attach_rigid(skeleton, BmsReader.to_array_mesh(mesh), bones[0], material)
		else:
			attach_rigid(skeleton, _build_side_mesh(mesh, true), bones[0], material)
			attach_rigid(skeleton, _build_side_mesh(mesh, false), bones[1], material)

## Same real mechanism as assemble() (rigid BoneAttachment3D, name-matched
## real material resolution, X-sign split for paired pieces), applied to
## real equipment-item meshes instead of body parts -- see
## EQUIPMENT_SLOT_BONES for the slot-code-to-bone mapping and its real,
## directly-observed evidence for which slots are genuinely paired.
## Unrecognized slot codes are skipped with a printed warning, not an
## error, same as assemble().
static func assemble_equipment(skeleton: Skeleton3D, parts: Dictionary, default_material: Material = null, materials_by_name: Dictionary = {}) -> void:
	for part_name in parts:
		var slot := _equipment_slot(part_name)
		if not EQUIPMENT_SLOT_BONES.has(slot):
			print("CharacterAssembler: no bone mapping for equipment slot %s (part %s) -- skipped" % [slot, part_name])
			continue
		var bones: Array = EQUIPMENT_SLOT_BONES[slot]
		var mesh: BmsReader.ParsedMesh = parts[part_name]
		var material: Material = materials_by_name.get(mesh.material_name, default_material)

		if bones.size() == 1:
			attach_rigid(skeleton, BmsReader.to_array_mesh(mesh), bones[0], material)
		else:
			attach_rigid(skeleton, _build_side_mesh(mesh, true), bones[0], material)
			attach_rigid(skeleton, _build_side_mesh(mesh, false), bones[1], material)

## Real bone a one-handed weapon rigidly attaches to -- confirmed directly
## (not assumed from the 3ds Max Biped naming convention alone) by pulling
## a real chinaman_skel.bsk and finding the exact string "Bip01 R Hand"
## among its real bone names. Unlike body parts and clothes_NN equipment,
## real weapon meshes (Prim\Mesh\Item\China\weapon\*.bms, e.g. "blade_01")
## carry no left/right-paired naming convention -- they're single self-
## contained meshes, one real item per weapon, not split halves.
const WEAPON_BONE := "Bip01 R Hand"

## Attaches one real weapon mesh (already resolved to its own real
## material via mesh.material_name, e.g. a real blade_01.bms's
## material_name "blade1_5" matches a real layer inside a real
## blade1_5.bmt) rigidly to WEAPON_BONE -- the same attach_rigid
## mechanism as body parts and clothing, just for a single unpaired mesh
## with no slot-code parsing needed.
static func assemble_weapon(skeleton: Skeleton3D, mesh: BmsReader.ParsedMesh, material: Material = null) -> void:
	attach_rigid(skeleton, BmsReader.to_array_mesh(mesh), WEAPON_BONE, material)

## Real bone a real shield rigidly attaches to -- the off-hand counterpart
## to WEAPON_BONE, confirmed the same direct way: pulling a real
## chinaman_skel.bsk and finding the exact string "Bip01 L Hand" among its
## real bone names. Real shield meshes (Prim\Mesh\Item\China\weapon\
## shield_*.bms, e.g. "shield_11") are, like weapons, single self-contained
## meshes with no left/right-paired naming convention.
const SHIELD_BONE := "Bip01 L Hand"

## Attaches one real shield mesh (resolved to its own real material via
## mesh.material_name, e.g. a real shield_11.bms's material_name
## "shield_11" matches a real layer inside a real shield_11.bmt) rigidly
## to SHIELD_BONE -- same mechanism as assemble_weapon.
static func assemble_shield(skeleton: Skeleton3D, mesh: BmsReader.ParsedMesh, material: Material = null) -> void:
	attach_rigid(skeleton, BmsReader.to_array_mesh(mesh), SHIELD_BONE, material)
