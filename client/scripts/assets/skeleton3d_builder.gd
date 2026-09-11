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

	# The root gets its own real bind transform, not an identity one.
	#
	# It was identity because BskReader read past the root's 92 transform
	# bytes without keeping them. At rest that cannot be seen -- the rigid
	# character attachment contributes inverse(bone_global_rest), so
	# whatever rest a bone is given cancels exactly. Under animation it
	# can: a real `.ban` keyframe is an absolute local transform authored
	# against the root's real bind (confirmed from the client's own
	# RTSkeleton.cpp, see docs/protocol/BAN_FORMAT.md), so posing it over
	# an identity rest displaces everything hanging off the root.
	var root_rotation := Quaternion.IDENTITY
	var root_rest := Transform3D.IDENTITY
	if not skel.root_transform.is_empty():
		var root_bone := BskReader.Bone.new()
		root_bone.bone_name = skel.root_name
		root_bone.transform = skel.root_transform
		root_rotation = SkeletonPose.bone_rotation(root_bone)
		root_rest = Transform3D(Basis(root_rotation), SkeletonPose.bone_local_position(root_bone))
	skeleton.set_bone_rest(root_idx, root_rest)
	world_rotations[skel.root_name] = root_rotation

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
			# **Corrected 2026-09-02** (see docs/WORLD_ISSUES.md's fiftieth
			# round). This used to treat SkeletonPose.bone_rotation() as a
			# *world* rotation and convert it to parent-relative
			# (`parent_world_rot.inverse() * this_world_rot`, with the
			# position derived the same way from world positions). That was
			# wrong: a real .bsk already stores each bone's
			# **parent-relative local** rotation and translation directly,
			# in exactly the same convention real .ban keyframes use.
			# Proved by dumping a real .bsk bone's raw transform floats
			# beside the matching real .ban keyframe -- for `Bip01 Neck`,
			# .bsk floats [0..3] are exactly the .ban keyframe rotation and
			# floats [4..6] are exactly its translation, to 4 decimals.
			# Converting an already-local rotation as if it were global
			# produced a rest pose in a mangled frame, which is why real
			# .ban playback (correctly in the file's own convention) never
			# composed with it and rendered as splayed, scattered limbs.
			# Using the stored local transform directly puts rest and
			# animation in one shared, real convention.
			var local_rot: Quaternion = world_rotations[b.bone_name]
			var local_pos: Vector3 = SkeletonPose.bone_local_position(b)
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
	# Same real semantics as apply_ban_pose (see its comment): a real
	# keyframe already *is* the bone's parent-relative local transform, in
	# the same real convention build_skeleton3d now uses for rest, so it
	# applies directly -- rotation and translation, no delta.
	var kf: BanReader.Keyframe = track.keyframes[frame_idx % track.keyframes.size()]
	skeleton.set_bone_pose_rotation(bone_idx, kf.rotation)
	skeleton.set_bone_pose_position(bone_idx, kf.position)
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
## Builds the Skin that maps a mesh's own bone palette onto skeleton, so a
## skinned .bms can be attached to it.
##
## Each palette entry is bound by name. The bind pose is the inverse of the
## bone's global rest, because .bms vertex positions are baked in absolute
## bind-pose space -- the same convention every other part of this project
## relies on (see BMS_FORMAT.md's "no extra per-piece transform").
##
## Returns null if any palette bone is missing from the skeleton: a skin
## with a wrong binding silently drags geometry to the origin, which is far
## harder to diagnose than a mesh that declines to attach.
static func build_skin(skeleton: Skeleton3D, bone_names: PackedStringArray) -> Skin:
	if skeleton == null or bone_names.is_empty():
		return null
	var skin := Skin.new()
	for i in range(bone_names.size()):
		var bone_idx := skeleton.find_bone(bone_names[i])
		if bone_idx == -1:
			push_warning("Skeleton3DBuilder: skeleton has no bone named %s" % bone_names[i])
			return null
		skin.add_bind(bone_idx, skeleton.get_bone_global_rest(bone_idx).affine_inverse())
	return skin

static func apply_ban_pose(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, frame_idx: int) -> void:
	for track in anim.bones:
		if track.keyframes.is_empty():
			continue
		var bone_idx := skeleton.find_bone(track.bone_name)
		if bone_idx == -1:
			continue
		# A real keyframe is already the bone's parent-relative local
		# transform, in the same real convention build_skeleton3d now uses
		# for rest -- so it applies directly as the bone's pose, with no
		# delta and no space conversion, translation included.
		var kf: BanReader.Keyframe = track.keyframes[frame_idx % track.keyframes.size()]
		skeleton.set_bone_pose_rotation(bone_idx, kf.rotation)
		skeleton.set_bone_pose_position(bone_idx, kf.position)
	skeleton.force_update_all_bone_transforms()

## Poses skeleton at `seconds` into anim on the clip's own clock: the two
## keyframes bracketing that moment in the file's key time table, blended
## by where between them it falls (rotation slerp, position lerp). A
## looping clip wraps at its duration and blends its last keyframe back
## into its first; a one-shot holds the last. Keyframes are sparse -- a
## 2000 ms battle stance has five -- so stepping between them without the
## blend would be a slideshow, and playing them at a fixed rate ran every
## idle several times too fast.
static func apply_ban_pose_at(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, seconds: float, loop: bool) -> void:
	var count := anim.key_times.size()
	if count == 0:
		return
	var duration := float(anim.duration_ms)
	var ms := seconds * 1000.0
	if loop and duration > 0.0:
		ms = fposmod(ms, duration)
	elif ms >= duration or count == 1:
		apply_ban_pose(skeleton, anim, count - 1)
		return
	var i := anim.key_index_at(ms / 1000.0, false)
	var j := i + 1
	var t0 := float(anim.key_times[i])
	var t1: float
	if j < count:
		t1 = float(anim.key_times[j])
	else:
		# Past the last key of a loop: blend back into the first.
		j = 0
		t1 = duration
	var frac := 0.0 if t1 <= t0 else clampf((ms - t0) / (t1 - t0), 0.0, 1.0)
	for track in anim.bones:
		if track.keyframes.is_empty():
			continue
		var bone_idx := skeleton.find_bone(track.bone_name)
		if bone_idx == -1:
			continue
		var a: BanReader.Keyframe = track.keyframes[i % track.keyframes.size()]
		var b: BanReader.Keyframe = track.keyframes[j % track.keyframes.size()]
		skeleton.set_bone_pose_rotation(bone_idx, a.rotation.slerp(b.rotation, frac))
		skeleton.set_bone_pose_position(bone_idx, a.position.lerp(b.position, frac))
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
