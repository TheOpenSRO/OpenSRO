extends RefCounted
class_name Skeleton3DBuilder

## Builds a real Godot Skeleton3D from a parsed .bsk skeleton, and drives it
## with a real .ban animation's rotation keyframes -- the engine-backed
## counterpart to SkeletonPose's manual forward-kinematics math (see
## client/tools/render_skeleton_animated.gd for the manual version this was
## built to go further than).
##
## Bind pose uses both the confirmed *positions* and *rotations* from
## SkeletonPose (see bone_position()/bone_rotation()), converted from
## world-space bind values into Skeleton3D's parent-relative rest
## transforms. **Corrected 2026-08-28** (see docs/WORLD_ISSUES.md's
## twenty-eighth round): this used to use identity rest rotations for every
## bone, on the reasoning that the .bsk rotation quaternion's composition
## convention wasn't confirmed -- that was the real, diagnosed cause of a
## real playtest bug where the assembled player's limbs flew apart the
## instant a .ban animation ran (identity rest means a keyframe's raw
## world-relative delta gets applied as if starting from a T-pose, which is
## wrong for any bone whose real bind rotation isn't already near-identity).
## Visually confirmed via a real .bsk/.ban pair (chinaman_skel.bsk +
## chinaman_fighter_walkforward.ban, rendered headlessly and compared
## frame-by-frame) that treating this quaternion as each bone's *world-space*
## bind rotation -- converted to parent-relative via
## `parent_world_rot.inverse() * this_world_rot` for both the rest rotation
## and (critically) the rest *position* (which must also be expressed in the
## parent's own rotated local frame once the parent has a non-identity rest
## rotation, not a raw world-space delta) -- produces a real, coherent
## walking stride in the legs, a qualitative fix confirmed by comparing
## rendered screenshots, not assumed. Arms stayed close to their bind pose
## in that same real animation at every frame checked; whether that's the
## real animation's own content (a weapon-ready stance that doesn't swing
## much) or a separate, still-unconfirmed gap in the fix wasn't determined --
## flagged honestly, not claimed as fully solved. What's still confirmed and
## used as-is: SkeletonPose.apply_rotation's own validated delta-from-
## keyframe-0 technique, now correctly composing on top of a real rest
## rotation instead of identity.

## Builds a Skeleton3D with one bone per skel.bones entry, in a valid
## parent-before-child order (topologically sorted, since real .bsk bone
## records aren't guaranteed to be in that order -- see
## docs/protocol/BSK_FORMAT.md). The skeleton's own root bone (skel.root_name)
## is added first with an identity rest transform (its own bind-pose
## transform bytes are parsed but not retained by BskReader -- see
## bsk_reader.gd).
static func build_skeleton3d(skel: BskReader.ParsedSkeleton) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var world_positions := SkeletonPose.bind_positions(skel)
	var world_rotations := {}
	for b in skel.bones:
		world_rotations[b.bone_name] = SkeletonPose.bone_rotation(b)

	var bone_index := {} # name -> Skeleton3D bone index
	skeleton.add_bone(skel.root_name) # Skeleton3D.add_bone() returns void; look the index up
	var root_idx := skeleton.find_bone(skel.root_name)
	bone_index[skel.root_name] = root_idx
	skeleton.set_bone_rest(root_idx, Transform3D.IDENTITY)
	world_rotations[skel.root_name] = Quaternion.IDENTITY

	var remaining: Array[BskReader.Bone] = skel.bones.duplicate()
	var guard := 0
	while not remaining.is_empty() and guard < 10000:
		guard += 1
		var progressed := false
		var still_remaining: Array[BskReader.Bone] = []
		for b in remaining:
			var parent_name: String = b.parent_name if b.parent_name != "" else skel.root_name
			if not bone_index.has(parent_name):
				still_remaining.append(b)
				continue
			var parent_idx: int = bone_index[parent_name]
			skeleton.add_bone(b.bone_name)
			var idx := skeleton.find_bone(b.bone_name)
			skeleton.set_bone_parent(idx, parent_idx)
			bone_index[b.bone_name] = idx

			# See this file's top comment: rest rotation/position both derive
			# from each bone's real .bsk world-space bind transform, not
			# identity -- the local position must be expressed in the
			# parent's own rotated local frame (parent_world_rot.inverse() *
			# world delta), not a raw world-space delta, once the parent has
			# a non-identity rest rotation.
			var parent_world: Vector3 = world_positions.get(parent_name, Vector3.ZERO)
			var parent_world_rot: Quaternion = world_rotations.get(parent_name, Quaternion.IDENTITY)
			var this_world_rot: Quaternion = world_rotations[b.bone_name]
			var local_rot: Quaternion = parent_world_rot.inverse() * this_world_rot
			var local_pos: Vector3 = parent_world_rot.inverse() * (world_positions[b.bone_name] - parent_world)
			skeleton.set_bone_rest(idx, Transform3D(Basis(local_rot), local_pos))
			progressed = true
		remaining = still_remaining
		if not progressed:
			break # bones whose parent never resolves (a real, documented .bsk gap) are dropped

	# Skeleton3D tracks "rest" (bind pose) and "pose" (animated offset from
	# rest) separately -- get_bone_global_pose() reflects only the pose
	# side, which starts uninitialized/identity rather than defaulting to
	# rest, so every bone needs an explicit reset_bone_pose() to sync pose
	# to rest before any global-pose query is meaningful. Skeleton3D also
	# lazily caches global transforms and only refreshes them on its own
	# process step, which never happens for a Skeleton3D outside the scene
	# tree (true for callers doing headless/offline work, e.g. this
	# project's dev tools and tests) -- force_update_all_bone_transforms()
	# makes get_bone_global_pose() correct immediately instead.
	for name in bone_index:
		skeleton.reset_bone_pose(bone_index[name])
	skeleton.force_update_all_bone_transforms()
	return skeleton

## Applies a real .ban Bone track's keyframe[frame_idx] rotation -- taken
## as a delta relative to that track's own keyframe[0] -- to the matching
## Skeleton3D bone, via the engine's own pose-rotation propagation (every
## descendant bone moves with it automatically, the same result
## SkeletonPose.apply_rotation computes by hand). No-op if track_bone_name
## isn't found in the skeleton.
static func apply_ban_keyframe(skeleton: Skeleton3D, track: BanReader.Bone, frame_idx: int) -> void:
	if track.keyframes.is_empty():
		return
	var bone_idx := skeleton.find_bone(track.bone_name)
	if bone_idx == -1:
		return
	var rest_rot: Quaternion = track.keyframes[0].rotation
	var target_rot: Quaternion = track.keyframes[frame_idx].rotation
	var delta: Quaternion = target_rot * rest_rot.inverse()
	skeleton.set_bone_pose_rotation(bone_idx, delta)
	skeleton.force_update_all_bone_transforms() # see build_skeleton3d()'s note on why this is needed

## Applies every real bone track in a full .ban animation (BanReader.
## ParsedAnimation.bones) at frame_idx, the same per-bone delta-rotation
## technique as apply_ban_keyframe -- that function only ever drove one
## single bone (used for World3D's standalone decoration-skeleton demo);
## this is the real multi-bone player used to actually animate an assembled
## character's whole body (e.g. a walk cycle), skipping any track whose
## bone isn't found in skeleton (a real, expected mismatch -- not every
## bone every .ban file names is necessarily present on every real .bsk
## skeleton it's paired with) rather than failing the whole pose. A single
## force_update_all_bone_transforms() at the end, not one per bone, since
## Skeleton3D's own transform propagation already handles the parent-child
## chain once every bone's local pose rotation is set.
static func apply_ban_pose(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, frame_idx: int) -> void:
	for track in anim.bones:
		if track.keyframes.is_empty():
			continue
		var bone_idx := skeleton.find_bone(track.bone_name)
		if bone_idx == -1:
			continue
		var frame := frame_idx % track.keyframes.size()
		var rest_rot: Quaternion = track.keyframes[0].rotation
		var target_rot: Quaternion = track.keyframes[frame].rotation
		var delta: Quaternion = target_rot * rest_rot.inverse()
		skeleton.set_bone_pose_rotation(bone_idx, delta)
	skeleton.force_update_all_bone_transforms()

## A bare Skeleton3D has no visual representation of its own -- there's no
## confirmed real bone-weight/skinning data in .bms yet to bind a real mesh
## to it (see docs/protocol/BMS_FORMAT.md), so this builds the same
## joint-sphere/bone-cylinder debug visualization
## client/tools/render_skeleton3d_animated.gd already uses, as a reusable
## child of the given skeleton. Call update_debug_visualization() after
## changing the skeleton's pose (e.g. apply_ban_keyframe()) to reposition
## it.
static func build_debug_visualization(skeleton: Skeleton3D, color: Color = Color(1, 0.8, 0.2)) -> Node3D:
	var viz := Node3D.new()
	viz.name = "DebugVisualization"
	skeleton.add_child(viz)

	var bone_count := skeleton.get_bone_count()
	var min_pos := Vector3.INF
	var max_pos := -Vector3.INF
	for i in range(bone_count):
		var pos: Vector3 = skeleton.get_bone_global_pose(i).origin
		min_pos = Vector3(min(min_pos.x, pos.x), min(min_pos.y, pos.y), min(min_pos.z, pos.z))
		max_pos = Vector3(max(max_pos.x, pos.x), max(max_pos.y, pos.y), max(max_pos.z, pos.z))
	var extent := (max_pos - min_pos).length()
	if extent < 1.0:
		extent = 100.0
	var joint_radius: float = clamp(extent * 0.015, 0.5, 6.0)

	var joint_mesh := SphereMesh.new()
	joint_mesh.radius = joint_radius
	joint_mesh.height = joint_radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color

	for i in range(bone_count):
		var joint := MeshInstance3D.new()
		joint.mesh = joint_mesh
		joint.material_override = mat
		joint.set_meta("bone_idx", i)
		viz.add_child(joint)

		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx != -1:
			var cyl := CylinderMesh.new()
			cyl.top_radius = joint_radius * 0.5
			cyl.bottom_radius = joint_radius * 0.5
			cyl.height = 1.0 # updated per-frame in update_debug_visualization()
			var bone_instance := MeshInstance3D.new()
			bone_instance.mesh = cyl
			bone_instance.material_override = mat
			bone_instance.set_meta("bone_idx", i)
			bone_instance.set_meta("parent_idx", parent_idx)
			viz.add_child(bone_instance)

	update_debug_visualization(viz, skeleton)
	return viz

## Repositions a Node3D built by build_debug_visualization() to match
## skeleton's current pose. Call this after every pose change (e.g. each
## apply_ban_keyframe()) to keep the visualization animated.
static func update_debug_visualization(viz: Node3D, skeleton: Skeleton3D) -> void:
	for child in viz.get_children():
		var bone_idx: int = child.get_meta("bone_idx")
		var pos: Vector3 = skeleton.get_bone_global_pose(bone_idx).origin
		if child.has_meta("parent_idx"):
			var parent_idx: int = child.get_meta("parent_idx")
			var parent_pos: Vector3 = skeleton.get_bone_global_pose(parent_idx).origin
			var seg := parent_pos - pos
			var length := seg.length()
			child.visible = length > 0.01
			if child.visible:
				child.position = (pos + parent_pos) / 2.0
				child.mesh.height = length
				if seg.normalized().is_equal_approx(Vector3.UP):
					child.transform.basis = Basis.IDENTITY
				else:
					child.transform.basis = Basis.IDENTITY.looking_at(seg.normalized(), Vector3.UP) \
						* Basis(Vector3.RIGHT, deg_to_rad(90))
		else:
			child.position = pos
