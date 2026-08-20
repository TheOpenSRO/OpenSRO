extends RefCounted
class_name SkeletonPose

## Bind-pose extraction and simple forward-kinematics for a parsed .bsk
## skeleton. Promoted out of client/tools/render_skeleton{,_animated}.gd
## (real, working dev tools) into tested library code, since the position
## math there is a real, reusable capability, not just a one-off demo.
##
## See docs/protocol/BSK_FORMAT.md for the byte-level derivation of the
## position-field offset used here.

## Returns bone name -> bind-pose world position for every bone in skel.
static func bind_positions(skel: BskReader.ParsedSkeleton) -> Dictionary:
	var positions := {}
	for b in skel.bones:
		positions[b.bone_name] = bone_position(b)
	return positions

## Extracts one bone's position from its raw transform bytes. Offset is
## 0x30 for a root-attached (92-byte) bone, 0x2c for an ordinary (88-byte)
## bone -- root-attached bones have one extra leading 4-byte field shifting
## everything after it by +4 (confirmed in docs/protocol/BSK_FORMAT.md).
static func bone_position(b: BskReader.Bone) -> Vector3:
	var off := 0x30 if b.transform.size() > BskReader.BONE_TRANSFORM_LEN else 0x2c
	return Vector3(
		b.transform.slice(off, off + 4).decode_float(0),
		b.transform.slice(off + 4, off + 8).decode_float(0),
		b.transform.slice(off + 8, off + 12).decode_float(0))

## Extracts one bone's local rotation from its raw transform bytes. Offset
## is 0x04 for a root-attached (92-byte) bone, 0x00 for an ordinary
## (88-byte) bone -- same +4 shift as bone_position(). See
## docs/protocol/BSK_FORMAT.md ("Transform data").
static func bone_rotation(b: BskReader.Bone) -> Quaternion:
	var off := 0x04 if b.transform.size() > BskReader.BONE_TRANSFORM_LEN else 0x00
	return Quaternion(
		b.transform.slice(off, off + 4).decode_float(0),
		b.transform.slice(off + 4, off + 8).decode_float(0),
		b.transform.slice(off + 8, off + 12).decode_float(0),
		b.transform.slice(off + 12, off + 16).decode_float(0))

## Returns the set of bone names transitively parented (directly or
## indirectly) under root_bone_name, by walking every bone's parent chain.
static func descendants_of(skel: BskReader.ParsedSkeleton, root_bone_name: String) -> Dictionary:
	var bone_by_name := {}
	for b in skel.bones:
		bone_by_name[b.bone_name] = b

	var result := {}
	for b in skel.bones:
		var cur := b.bone_name
		var guard := 0
		while cur != "" and guard < 100:
			var cb: BskReader.Bone = bone_by_name.get(cur)
			if cb == null:
				break
			if cb.parent_name == root_bone_name:
				result[b.bone_name] = true
				break
			cur = cb.parent_name
			guard += 1
	return result

## Applies a rotation delta to pivot_bone_name and every one of its
## descendants (per descendants_of), by rotating each descendant's
## bind-pose position around the pivot bone's own bind-pose position.
## Returns a new name -> Vector3 dictionary (positions not covered by the
## rotation are copied through unchanged). Simple forward kinematics, not a
## full skeletal transform stack -- see
## client/tools/render_skeleton_animated.gd for how this is meant to be
## used (applying a .ban keyframe rotation delta to visualize movement).
static func apply_rotation(skel: BskReader.ParsedSkeleton, positions: Dictionary, pivot_bone_name: String, delta: Quaternion) -> Dictionary:
	var out := positions.duplicate()
	if not positions.has(pivot_bone_name):
		return out
	var pivot: Vector3 = positions[pivot_bone_name]
	var affected := descendants_of(skel, pivot_bone_name)
	for name in affected:
		if positions.has(name):
			var p: Vector3 = positions[name]
			out[name] = pivot + delta * (p - pivot)
	return out
