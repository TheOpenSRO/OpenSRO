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
## Round 757: a skeleton the client builds has no physical bones, so it needs
## no callback in every physics step. READ, Godot 4.2.2 skeleton_3d.cpp
## l. 303-315 and 660-671: Skeleton3D's internal physics process only walks
## its bones for PhysicalBone3D children, and `set_animate_physical_bones`
## switches it on for any skeleton outside the editor -- including the setter
## Node.duplicate() calls when it copies the property (default true) onto every
## body and item skeleton duplicated from a template. MEASURED (round 757, the
## 7,000-body lineup): 18,035 Skeleton3Ds were physics-processing, about 5 ms a
## physics step of engine callbacks outside every script (FrameSplit's phys_cb
## less World3D's own). Turned off here, on the template, the copies inherit
## it. On Godot 4.3+ the property moved to PhysicalBoneSimulator3D and a
## Skeleton3D does not physics-process for it: there this does nothing that
## matters (it is a 4.2.2 engine behaviour, not a project workaround for a
## bug).
##
## Round 760 (Godot 4.7.2): the same class of cost, once a frame instead of
## once a step. READ, scene/3d/skeleton_3d.cpp at 4.7.2-stable: every
## Skeleton3D entering the tree gets an internal PhysicalBoneSimulator3D child
## (`setup_simulator`, the deprecated compat path, compiled into the official
## builds), which is a SkeletonModifier3D, so `_find_modifiers` (it walks the
## internal children too) always finds one; `_process_changed` turns the
## internal process on for the default `modifier_callback_mode_process`
## (Idle), and each frame's `advance()` then queues a deferred
## NOTIFICATION_UPDATE_SKELETON (`_update_deferred(UPDATE_FLAG_MODIFIER)`), which
## backs up and restores every bone around the (inactive) simulator. With
## 18,035 skeletons that was 38.5 ms of wall a frame (MEASURED round 757,
## tools/skeleton_process_bench.gd). The client builds no SkeletonModifier3D
## (no IK, look-at or physical bones; MapAnimation's AnimationPlayer sets bone
## poses, it is not a modifier), so the per-frame advance has nothing to run:
## the Manual mode (2) stops it, and `_process_changed` keeps it off at every
## tree entry (a plain set_process_internal(false) would be undone there). A
## posed skeleton is unaffected: set_bone_pose_* marks it dirty and queues the
## same deferred update (`_make_dirty` -> `_update_deferred(UPDATE_FLAG_POSE |
## UPDATE_FLAG_MODIFIER)`), which updates its skin and emits
## `skeleton_updated` for its BoneAttachment3Ds, whatever the mode
## (skeleton_process_test.gd). The property is stored, so a template's
## duplicates inherit it. On 4.2.2 the property does not exist.
static func no_physics_step(skeleton: Skeleton3D) -> void:
	if "animate_physical_bones" in skeleton:
		skeleton.set("animate_physical_bones", false)
	skeleton.set_physics_process_internal(false)
	if "modifier_callback_mode_process" in skeleton:
		skeleton.set("modifier_callback_mode_process", MODIFIER_CALLBACK_MANUAL)
		skeleton.set_process_internal(false)

## Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL (Godot 4.3+; READ
## skeleton_3d.h at 4.7.2-stable), as a number so the script parses on 4.2.2.
const MODIFIER_CALLBACK_MANUAL := 2

static func build_skeleton3d(skel: BskReader.ParsedSkeleton) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	no_physics_step(skeleton)
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
		# Round 648: 11 real skeletons (the Dunhuang reeds, the Tarim rope
		# bridge, thief_boss, planar, elemental...) store an unset root --
		# a local translation of 3.7e24, or NaN. Composed into every bone's
		# rest it put each skin's bind 1e24 away, and the reeds were drawn
		# as streaks across the sand. Their files say where the root is:
		# every bone hung on it stores a world bind equal to its local, so
		# the root is at the origin (root_rest_from_children). Retail never
		# meets the unset value: a keyed bone takes its local from the keys
		# alone (RTSkeleton::FUN_00c49f20's weight test at +0x98), and each
		# skin matrix is the
		# FILE's inverse bind times the bone's world (RTSkeleton::
		# FUN_00c49f20), never an inverse of composed rests (READ, round
		# 648; docs/protocol/BSK_FORMAT.md). This client composes the rests
		# (OURS), so it needs the root the file implies.
		if not root_rest_usable(root_rotation, root_rest.origin):
			var implied := root_rest_from_children(skel)
			root_rest = implied
			root_rotation = implied.basis.get_rotation_quaternion()
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
	Skeleton3DBuilder.refresh_global_poses(skeleton)
	return skeleton

## Composes every bone's global pose now, in or out of the scene tree: what
## force_update_all_bone_transforms() alone did under Godot 4.2.2.
##
## From Godot 4.4 Skeleton3D caches each bone's global pose and recomposes
## only bones marked stale, and set_bone_pose_position / _rotation / _scale
## mark them stale only while the skeleton is in the tree (READ,
## scene/3d/skeleton_3d.cpp at 4.7.2-stable: `if (is_inside_tree()) {
## _make_dirty(); _make_bone_global_pose_subtree_dirty(p_bone); }`;
## `bone_global_pose_dirty` is absent from 4.2.2 and 4.3 and present from
## 4.4). So out of the tree -- the far crowd's bake (CrowdGpu._bake_frame),
## the portrait, every headless tool and test -- the first global query
## after the build was cached for ever and every later pose read back the
## old one (MEASURED round 754 on the box: a child of a bone turned 90
## degrees stayed at (20, 0, 0) under 4.7.2, (10, 0, -10) under 4.2.2).
## set_show_rest_only marks every bone stale whatever the tree
## (`_make_bone_global_poses_dirty()`), so writing the same value back is
## the invalidation; in the tree it is not needed and is skipped.
static func refresh_global_poses(skeleton: Skeleton3D) -> void:
	if not skeleton.is_inside_tree():
		skeleton.show_rest_only = skeleton.show_rest_only
	skeleton.force_update_all_bone_transforms()

## Moves every BoneAttachment3D on `skeleton` to the pose just set, now,
## rather than at the skeleton's update later in the frame.
##
## Godot 4.2.2's BoneAttachment3D followed `bone_pose_changed`, emitted as
## each global pose was composed, so the first global-pose query after a pose
## moved the attachments at once; from 4.3 it follows `skeleton_updated`,
## emitted only by the deferred NOTIFICATION_UPDATE_SKELETON (READ,
## scene/3d/bone_attachment_3d.cpp and skeleton_3d.cpp at 4.2.2-stable and
## 4.7.2-stable), so a script reading an attachment's (or its children's)
## transform in the same frame as the pose gets the previous frame's
## (MEASURED round 754: crowd_gpu_test.gd's near weapons 8-14 units off under
## 4.7.2). Running the notification here does the deferred update early: it
## clears the pending flags, so the deferred one does nothing more.
static func flush_attachments(skeleton: Skeleton3D) -> void:
	skeleton.get_bone_global_pose(0)
	if Engine.get_version_info().hex >= 0x040300 and skeleton.is_inside_tree():
		skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)

## The largest root local translation this treats as authored (OURS: a
## bound in the measured gap). MEASURED over Data.pk2's 1,208 skeletons
## (client/tools/census_bsk_bind.gd, round 648): every root is at most
## 4,767 units from its parent frame (roc_event_cam.bsk), or else has a
## component of 2.7e20 or more, or NaN -- 11 files, all of whose root
## children imply the root at the origin.
const ROOT_TRANSLATION_LIMIT := 1.0e6

## Whether a root's stored local transform can be used: finite, a unit
## quaternion, and a translation inside ROOT_TRANSLATION_LIMIT.
static func root_rest_usable(rotation: Quaternion, origin: Vector3) -> bool:
	if not (is_finite(rotation.x) and is_finite(rotation.y) and is_finite(rotation.z) and is_finite(rotation.w)):
		return false
	if absf(rotation.length() - 1.0) > 0.01:
		return false
	for c in [origin.x, origin.y, origin.z]:
		if not is_finite(c) or absf(c) > ROOT_TRANSLATION_LIMIT:
			return false
	return true

## The root rest a skeleton's own file implies when the root's stored local
## is unusable: the first bone hung on the root stores both its local
## (parent-relative) transform and its world bind (READ, the record's first
## and second pairs), so root = world_bind * inverse(local). For each of the
## 11 real skeletons with an unset root, every such bone implies the same
## root, at the origin (MEASURED, census_bsk_bind.gd). Identity when no bone
## hangs on the root or the implied one is not finite.
static func root_rest_from_children(skel: BskReader.ParsedSkeleton) -> Transform3D:
	for b in skel.bones:
		if b.parent_name != "" and b.parent_name != skel.root_name:
			continue
		var local := Transform3D(Basis(SkeletonPose.bone_rotation(b).normalized()), SkeletonPose.bone_local_position(b))
		var implied := SkeletonPose.bone_world_bind(b) * local.affine_inverse()
		if root_rest_usable(implied.basis.get_rotation_quaternion(), implied.origin):
			return implied.orthonormalized()
		break
	return Transform3D.IDENTITY

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
	Skeleton3DBuilder.refresh_global_poses(skeleton) # see build_skeleton3d()'s note on why this is needed

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
##
## `missing_to_object_space` (round 683, off by default; CharacterAppearance
## passes it) applies the client's own rule instead: `ResObject::FUN_00be2f80`
## looks each influence's palette name up in the skeleton (`FUN_00bce230`) and,
## when it is not there, gives that influence entry 0 -- the object's own
## space, OBJECT_SPACE_BONE here -- and leaves its weight out of the vertex's
## sum (READ). The Europe man's heavy legs (`heavy_01_la.bms`) name a `Bone03`
## that europeman_skel.bsk does not have (MEASURED), so without this the legs
## are not drawn at all. The weight half of the rule is not modelled
## (BmsReader normalises over both slots before the skeleton is known): at
## rest the vertex lands in the same place either way, animated it may lag.
## `world_binds` (round 721, bone name -> Transform3D; stored_world_binds)
## binds a bone to the inverse of its STORED world bind, the client's own
## rule (READ, docs/protocol/BSK_FORMAT.md "How the client skins with those
## three matrices": `P = InvBind_file x W`, the file's inverse bind, never
## recomputed). A bone it lacks is bound, as before, to the inverse of the
## rest this builder composes from the locals. The two differ where a
## skeleton's stored locals do not chain to its stored world binds -- the
## Alexandria gate portal's root stores a local of (19.75, 0, 0) while every
## child's world bind puts the root at the origin (MEASURED), and its
## clip keys the root at the origin, so binding to the composed rest drew
## every ring 19.75 off and spun the inner ones about the wrong point.
static func build_skin(skeleton: Skeleton3D, bone_names: PackedStringArray, object_space: bool = false,
		missing_to_object_space: bool = false, world_binds: Dictionary = {}) -> Skin:
	if skeleton == null or bone_names.is_empty():
		return null
	var skin := Skin.new()
	for i in range(bone_names.size()):
		var bone_idx := skeleton.find_bone(bone_names[i])
		if bone_idx == -1 and missing_to_object_space:
			skin.add_bind(_object_space_bone(skeleton), Transform3D.IDENTITY)
			continue
		if bone_idx == -1:
			push_warning("Skeleton3DBuilder: skeleton has no bone named %s" % bone_names[i])
			return null
		if world_binds.has(bone_names[i]):
			skin.add_bind(bone_idx, (world_binds[bone_names[i]] as Transform3D).affine_inverse())
		else:
			skin.add_bind(bone_idx, skeleton.get_bone_global_rest(bone_idx).affine_inverse())
	if object_space:
		# One more bind, at the index BmsReader.to_arrays gives OBJECT_SPACE
		# (one past the palette): a parentless bone at the skeleton's
		# origin that nothing animates, so its skin matrix stays identity
		# and the vertex keeps its bind position in the model's own space --
		# the client's palette entry 0 (BmsReader._parse_skin, round 626).
		skin.add_bind(_object_space_bone(skeleton), Transform3D.IDENTITY)
	return skin

## Every bone's stored world bind, keyed by name -- the binds build_skin's
## `world_binds` takes -- as the inverse of the record's THIRD (quaternion,
## vector) pair, the file's own inverse bind, which is what the client skins
## with (READ, BSK_FORMAT.md: `P = InvBind_file x W`, "the inverse bind is
## the file's, never recomputed; no update or skinning path reads the stored
## world bind"). The third pair is read in the convention bone_world_bind
## reads the second. A bone whose stored inverse is not usable (non-finite,
## not a rotation, or a translation past ROOT_TRANSLATION_LIMIT -- the 11
## skeletons with an unset root store garbage) is left out, so build_skin
## binds it to the composed rest as before (OURS).
static func stored_world_binds(skel: BskReader.ParsedSkeleton) -> Dictionary:
	var out := {}
	if skel == null:
		return out
	var all: Array[BskReader.Bone] = skel.bones.duplicate()
	if not skel.root_transform.is_empty():
		var root_bone := BskReader.Bone.new()
		root_bone.bone_name = skel.root_name
		root_bone.transform = skel.root_transform
		all.append(root_bone)
	for b in all:
		var inv = stored_inverse_bind(b)
		if inv == null:
			continue
		out[b.bone_name] = (inv as Transform3D).affine_inverse()
	return out

## The stored binds (stored_world_binds) when, and only when, they are the
## binds build_skin would compose anyway once the root is re-seated: every
## bone's stored bind equals its composed global rest moved by one rigid
## transform -- the root's own stored local against where its children's
## stored binds put it (root_rest_from_children) -- within BIND_TOLERANCE.
## Otherwise {} (build_skin then binds to the composed rest, as before).
##
## Round 721. The client binds to the stored inverse binds (READ), so where
## the two agree this is exactly the client's skin; the Alexandria gate
## portal (root stored at (19.75, 0, 0), its children's binds at the origin,
## its clip keying the root at the origin) is that case. The CONDITION is
## OURS: the client takes the stored binds always. A skeleton whose stored
## binds differ from its locals by more than a root shift keeps the composed
## bind, which draws it on its mesh at the clip's first key. Eight map models
## are such (tre_willow03, tre_tree01_big, tre_bamboo04, oas_hot_tree_stone,
## the four demon_wall_deco*); by our readers the client's rule would draw
## them off their meshes (the willow 58 units), and the map path's skeleton
## scale is 1.0 (READ, round 721's review: RTSkeleton::FUN_00c513c0 `fld1`
## -> +0xa4; the map never calls CCompChar slot 9), so nothing undoes it.
## Either retail draws them off, or one of our readers is wrong -- OPEN,
## to settle against retail. A skeleton with a non-root bone whose stored
## inverse bind is unusable also keeps the composed bind (no mixing of the
## two bind spaces in one skin).
static func consistent_stored_binds(skeleton: Skeleton3D, skel: BskReader.ParsedSkeleton) -> Dictionary:
	var binds := stored_world_binds(skel)
	if binds.is_empty() or skeleton == null:
		return {}
	var root_idx := skeleton.find_bone(skel.root_name)
	if root_idx == -1:
		return {}
	# Every non-root bone needs a usable stored bind; otherwise the skin would
	# mix shifted stored binds and unshifted composed ones.
	for b in skel.bones:
		if not binds.has(b.bone_name):
			return {}
	var shift := root_rest_from_children(skel) * skeleton.get_bone_global_rest(root_idx).affine_inverse()
	var differs := false
	for name in binds:
		# The root stores its own local as its bind; the shift is defined by
		# where its children put it, so it is not compared (it is kept: a
		# vertex on the root binds to the root's stored inverse, as the client
		# binds it).
		if name == skel.root_name:
			continue
		var idx := skeleton.find_bone(name)
		if idx == -1:
			return {}
		var expected := shift * skeleton.get_bone_global_rest(idx)
		var got: Transform3D = binds[name]
		if expected.origin.distance_to(got.origin) > BIND_TOLERANCE or \
				expected.basis.get_rotation_quaternion().angle_to(got.basis.get_rotation_quaternion()) > deg_to_rad(BIND_TOLERANCE_DEG):
			return {}
		if not expected.is_equal_approx(skeleton.get_bone_global_rest(idx)):
			differs = true
	return binds if differs else {}

## How far a stored bind may sit from the composed one and still count as
## the same (OURS; census_bsk_bind.gd's own tolerance, 0.05 units / 1 degree).
const BIND_TOLERANCE := 0.05
const BIND_TOLERANCE_DEG := 1.0

## One bone's stored INVERSE bind: the record's third (quaternion, vector)
## pair, at 0x38 / 0x48 (+4 for a root's 92-byte record), or null when it is
## not usable (see stored_world_binds).
static func stored_inverse_bind(b: BskReader.Bone):
	var off := 0x38 + (4 if b.transform.size() > BskReader.BONE_TRANSFORM_LEN else 0)
	if b.transform.size() < off + 28:
		return null
	var q := Quaternion(b.transform.decode_float(off), b.transform.decode_float(off + 4),
		b.transform.decode_float(off + 8), b.transform.decode_float(off + 12))
	var qlen := q.length()
	if not is_finite(qlen) or absf(qlen - 1.0) > 0.01:
		return null
	var t := Vector3(b.transform.decode_float(off + 16), b.transform.decode_float(off + 20), b.transform.decode_float(off + 24))
	var inv := Transform3D(Basis(q.normalized()), t)
	if not root_rest_usable(inv.basis.get_rotation_quaternion(), inv.origin):
		return null
	return inv

## One Skin for every mesh skinned to `skeleton` (round 738, A2; OURS): bind
## i is bone i, at the inverse of its global rest -- exactly the bind
## build_skin gives a palette entry naming that bone (and IDENTITY, which is
## that same inverse, for OBJECT_SPACE_BONE). Godot writes every bind of every
## Skin registered on a skeleton each time it is posed (Godot 4.2.2
## skeleton_3d.cpp:245-297, READ in round 736), so a body of 14 pieces with
## one skin each wrote 14 skeletons; sharing this one writes one.
## Only for skeletons whose pieces bind to the composed rest (no
## `world_binds`): CharacterAppearance's bodies and their worn items.
static func canonical_skin(skeleton: Skeleton3D) -> Skin:
	var skin := Skin.new()
	for i in range(skeleton.get_bone_count()):
		skin.add_bind(i, skeleton.get_bone_global_rest(i).affine_inverse())
	return skin

## `mesh` as BmsReader.to_array_mesh builds it, with each vertex's palette
## index turned into the skeleton bone `palette_skin` binds it to
## (build_skin's skin for the mesh): the mesh canonical_skin draws. Every
## bind of a build_skin skin is canonical_skin's bind for its bone, so each
## vertex is moved by the same matrices it was.
static func canonical_mesh(mesh: BmsReader.ParsedMesh, palette_skin: Skin) -> ArrayMesh:
	var arrays := BmsReader.to_arrays(mesh)
	var bones = arrays[Mesh.ARRAY_BONES]
	if bones is PackedInt32Array:
		var map := PackedInt32Array()
		for i in range(palette_skin.get_bind_count()):
			map.append(palette_skin.get_bind_bone(i))
		var remapped: PackedInt32Array = bones
		for k in range(remapped.size()):
			var p := remapped[k]
			remapped[k] = map[p] if p >= 0 and p < map.size() else map[0]
		arrays[Mesh.ARRAY_BONES] = remapped
	return BmsReader.mesh_from_arrays(arrays)

## The skeleton's OBJECT_SPACE_BONE, added on first use.
static func _object_space_bone(skeleton: Skeleton3D) -> int:
	var obj := skeleton.find_bone(OBJECT_SPACE_BONE)
	if obj == -1:
		obj = skeleton.get_bone_count()
		skeleton.add_bone(OBJECT_SPACE_BONE)
		skeleton.set_bone_rest(obj, Transform3D.IDENTITY)
		skeleton.reset_bone_pose(obj)
	return obj

## The bone build_skin adds for vertices on the client's palette entry 0.
const OBJECT_SPACE_BONE := "__opensro_object_space__"

## False for the OBJECT_SPACE_BONE build_skin adds: a bone of the model's
## own, not of its skeleton, sitting at the origin -- a loop measuring a
## body by its bones (the paper doll's framing, the QA feet report, a
## label's height) must skip it or it reads the origin as a foot.
static func is_skeleton_bone(skeleton: Skeleton3D, bone: int) -> bool:
	return skeleton.get_bone_name(bone) != OBJECT_SPACE_BONE

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
	Skeleton3DBuilder.refresh_global_poses(skeleton)

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
	Skeleton3DBuilder.refresh_global_poses(skeleton)

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
