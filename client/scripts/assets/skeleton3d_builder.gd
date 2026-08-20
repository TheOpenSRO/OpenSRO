extends RefCounted
class_name Skeleton3DBuilder

## Builds a real Godot Skeleton3D from a parsed .bsk skeleton, and drives it
## with a real .ban animation's rotation keyframes -- the engine-backed
## counterpart to SkeletonPose's manual forward-kinematics math (see
## client/tools/render_skeleton_animated.gd for the manual version this was
## built to go further than).
##
## Bind pose uses only the confirmed *positions* from SkeletonPose
## (converted from the world-space bind positions render_skeleton.gd
## already visually confirmed into Skeleton3D's parent-relative rest
## transforms) with identity rest rotations -- this project hasn't
## confirmed the .bsk rotation quaternion is meant to compose the same way
## Skeleton3D's own rest-rotation hierarchy does, so it isn't used for the
## rest pose. What *is* confirmed and used here is the same thing
## SkeletonPose.apply_rotation already validated: a .ban keyframe rotation,
## taken as a delta relative to that bone's own first keyframe, correctly
## drives a bone and all its descendants when applied as a pose rotation --
## here via Skeleton3D's own real hierarchy propagation instead of manually
## walking descendants.

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

	var bone_index := {} # name -> Skeleton3D bone index
	skeleton.add_bone(skel.root_name) # Skeleton3D.add_bone() returns void; look the index up
	var root_idx := skeleton.find_bone(skel.root_name)
	bone_index[skel.root_name] = root_idx
	skeleton.set_bone_rest(root_idx, Transform3D.IDENTITY)

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

			var parent_world: Vector3 = world_positions.get(parent_name, Vector3.ZERO)
			var local_pos: Vector3 = world_positions[b.bone_name] - parent_world
			skeleton.set_bone_rest(idx, Transform3D(Basis.IDENTITY, local_pos))
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
