extends RefCounted
class_name SkinnedBsrAssembler

## Assembles any character model -- NPC, monster or the player's own body
## -- from an open pk2 archive: skeleton, mesh pieces and materials, ready
## to place in the world. And dresses it: `attach_item_from_archive` hangs
## an equippable item's `.bsr` on an assembled skeleton the way the item
## file itself says to.
##
## The player's body is a `.bsr` like an NPC's -- `char\china\
## chinaman_fighter.bsr`, named by characterdata's rows 1907-1932 -- of
## type 0 rather than 1 (see BsrReader.TYPE_PLAYER_CHARACTER). It lists the
## body's skeleton, its nine skinned pieces, its material and 217
## animations, which is everything the character needs and nothing the old
## per-gender path table had to guess.
##
## Two pieces of prior work make this general where it used to be per-model.
##
## **The `.bsr` names its own skeleton.** BMS_FORMAT.md recorded that "no
## file tying a specific mesh set to a specific skeleton was found", which
## is why earlier code was handed a `.bsk` path from outside. The `.bsr` is
## that file: its header's section table addresses a mesh list and a
## skeleton list together (see BSR_FORMAT.md). Nothing here has to be told
## which skeleton a model uses.
##
## **Pieces are skinned by their own weights; the rigid path is the
## fallback.** `.bms` carries per-vertex skinning -- a bone palette and two
## weighted influences per vertex (BMS_FORMAT.md, hundred-and-tenth round)
## -- and a piece that has it is bound to the skeleton by name. A piece
## without it attaches rigidly to the bone nearest its vertex centroid,
## which is the computation MonsterAssembler once held as a hand-derived
## dictionary per creature (7/7 pieces for golem, 3/3 for scorpion,
## `client/tools/check_piece_bones.gd`).
##
## **What the bone choice does and does not affect.** In the bind pose it
## affects nothing: `CharacterAssembler.attach_rigid` cancels the bone's own
## rest transform, so a piece renders exactly at the absolute coordinates
## baked into its vertices no matter which bone it hangs from. The choice
## only starts to matter once the skeleton is animated, and there it is a
## real approximation: a humanoid NPC whose whole lower body is one
## 400-vertex piece gets attached to whichever single bone that piece's
## centroid happens to sit nearest, so animating that bone swings the whole
## piece. Good enough for NPCs standing in a town, which is what NPCs do;
## honestly not a solved skinning model, and flagged as such rather than
## presented as one.

class AssembledCharacter:
	var skeleton: Skeleton3D
	var animation_paths: Array[String] = []
	## The parsed `.bsr`, kept for its animation groups: which animation
	## plays for which action (BsrReader.AnimationEntry).
	var parsed: BsrReader.ParsedObject = null
	## Animations parsed so far, by path.
	var animation_cache: Dictionary = {}
	## The animation to play when this character is just standing there,
	## parsed and ready for Skeleton3DBuilder.apply_ban_pose. Null when the
	## model names no animations, or none of them loaded.
	var idle_animation: BanReader.ParsedAnimation = null
	## Which bone each mesh piece was attached to, and how far its centroid
	## sat from that bone -- the evidence for the mapping, kept so a caller
	## or a dev tool can report it rather than having to recompute it.
	var piece_bones: Dictionary = {}
	var piece_distances: Dictionary = {}
	## How many pieces were attached with real per-vertex skinning rather
	## than rigidly. A model with all of its pieces skinned can be animated;
	## one with none cannot.
	var skinned_pieces: int = 0

## Substrings that name a standing-still animation, most specific first.
##
## The fallback for a file with no animation groups. Real files say which
## animation stands still -- the type-0 entry of their `default` group,
## `mangnyang_stand01` for the monster and `chinaquest_priest_basic` for
## the NPC -- and that is read first; these hints are what kept models
## animating before the groups were read, and still cover a file this
## reader cannot parse the groups of.
const IDLE_ANIMATION_HINTS := ["stand01", "stand", "basic", "idle", "wait"]

## Picks the idle animation from a model's own list, or "" if it has none.
static func idle_animation_path(paths: Array) -> String:
	for hint in IDLE_ANIMATION_HINTS:
		for path in paths:
			if (path as String).to_lower().contains(hint):
				return path
	return paths[0] if not paths.is_empty() else ""

## Assembles the model at bsr_path. Returns null if the file isn't a
## character, if its skeleton is missing, or if no mesh piece could be
## loaded -- a partially-loaded body is still returned, with the pieces that
## did load, since a missing accessory shouldn't discard the whole NPC.
##
## with_animation parses the model's idle animation too. Off by default
## because a caller that only wants to look at geometry should not pay for
## it, and because a .ban that fails to parse should not cost a whole model.
static func assemble_from_archive(
	archive: Pk2Reader, bsr_path: String, with_animation: bool = false
) -> AssembledCharacter:
	var bsr_data := _read(archive, bsr_path)
	if bsr_data.is_empty():
		push_error("SkinnedBsrAssembler: %s not found in archive" % bsr_path)
		return null
	var parsed := BsrReader.parse(bsr_data)
	if parsed == null:
		return null
	if not parsed.is_character:
		push_error("SkinnedBsrAssembler: %s is not a character .bsr (type %d)" % [bsr_path, parsed.object_type])
		return null

	var bsk_data := _read(archive, parsed.skeleton_path)
	if bsk_data.is_empty():
		push_error("SkinnedBsrAssembler: skeleton %s not found in archive" % parsed.skeleton_path)
		return null
	var parsed_skeleton := BskReader.parse(bsk_data)
	if parsed_skeleton == null:
		return null
	var skeleton := Skeleton3DBuilder.build_skeleton3d(parsed_skeleton)
	if skeleton == null or skeleton.get_bone_count() == 0:
		push_error("SkinnedBsrAssembler: %s built an empty skeleton" % parsed.skeleton_path)
		return null

	# Every bone's bind position, in the same absolute space .bms bakes its
	# vertices into.
	var bone_positions := {}
	for i in range(skeleton.get_bone_count()):
		bone_positions[skeleton.get_bone_name(i)] = skeleton.get_bone_global_rest(i).origin

	var material := ObjectLoader.load_material(archive, parsed.material_path) if parsed.material_path != "" else null

	var result := AssembledCharacter.new()
	result.skeleton = skeleton
	result.animation_paths = parsed.animation_paths
	result.parsed = parsed

	var mesh_paths := parsed.all_mesh_paths()
	var attached := 0
	for i in range(mesh_paths.size()):
		var bms_data := _read(archive, mesh_paths[i])
		if bms_data.is_empty():
			push_error("SkinnedBsrAssembler: mesh %s not found in archive" % mesh_paths[i])
			continue
		var mesh := BmsReader.parse(bms_data)
		if mesh == null:
			continue

		var bone_name := _nearest_bone(mesh, bone_positions)
		if bone_name == "":
			continue
		var piece := mesh_paths[i].get_file().get_basename()
		result.piece_bones[piece] = bone_name
		result.piece_distances[piece] = _centroid(mesh).distance_to(bone_positions[bone_name])

		# Same layer selection ObjectLoader uses for scenery: match the
		# mesh's own material_name against the .bmt's layer names, and fall
		# back to position only when the counts line up.
		var godot_material: Material = null
		if material != null and material.layers.size() > 0:
			var layer_idx := ObjectLoader._find_layer_by_name(material.layers, mesh.material_name)
			if layer_idx == -1:
				layer_idx = i if material.layers.size() == mesh_paths.size() else 0
			godot_material = ObjectLoader.build_godot_material(
				archive, parsed.material_path, material.layers[layer_idx]
			)

		# Real skinning when the mesh carries weights, rigid attachment when
		# it does not.
		#
		# `.bms` **does** carry per-vertex skinning -- a bone palette plus
		# two weighted influences per vertex, in its own section rather than
		# in the vertex record, which is why an audit of the 44-byte vertex
		# layout concluded there was none. With it, a humanoid deforms
		# properly and can be animated; without it, every piece hangs
		# rigidly off one bone and animating tears the model apart.
		if mesh.is_skinned():
			var skin := Skeleton3DBuilder.build_skin(skeleton, mesh.bone_names)
			if skin != null:
				var mi := MeshInstance3D.new()
				mi.mesh = BmsReader.to_array_mesh(mesh)
				if godot_material != null:
					mi.material_override = godot_material
				skeleton.add_child(mi)
				mi.skin = skin
				mi.skeleton = mi.get_path_to(skeleton)
				result.skinned_pieces += 1
				attached += 1
				continue
		CharacterAssembler.attach_rigid(
			skeleton, BmsReader.to_array_mesh(mesh), bone_name, godot_material
		)
		attached += 1

	if attached == 0:
		push_error("SkinnedBsrAssembler: %s: none of its %d mesh piece(s) loaded" % [bsr_path, mesh_paths.size()])
		skeleton.free()
		return null

	if with_animation:
		# The file says which of its animations is the standing one: the
		# type-0 entry of its `default` animation group (BsrReader
		# .AnimationEntry). The name hints below are the fallback for a
		# file with no groups.
		var idle_path := parsed.animation_for(BsrReader.AnimationEntry.TYPE_STAND)
		if idle_path == "":
			idle_path = idle_animation_path(result.animation_paths)
		if idle_path != "":
			var ban_bytes := _read(archive, idle_path)
			if not ban_bytes.is_empty():
				var parsed_anim := BanReader.parse(ban_bytes)
				# An animation with no bone tracks would pose nothing; treat
				# it as absent rather than ticking it every frame for free.
				if parsed_anim != null and not parsed_anim.bones.is_empty():
					result.idle_animation = parsed_anim
	return result

## What attaching one item produced, for a caller that wants to report it.
class AttachedItem:
	## The node that was added under the body's skeleton: a skinned
	## MeshInstance3D for an item weighted onto the body, or a
	## BoneAttachment3D carrying the item's own skeleton otherwise.
	var node: Node3D
	## The body bone an item with its own skeleton hangs from, "" for one
	## weighted onto the body.
	var attach_bone: String = ""
	var skinned: bool = false

## Hangs one equippable item on skeleton, the way its own `.bsr` says.
##
## Two conventions, and the file states which applies:
##
## - **Weighted onto the body.** A suit, trousers, a hat, boots or
##   wristlets name no skeleton; their mesh's bone palette names the body's
##   own bones (`clothes_01_ba.bms` lists nine, `Bip01 Neck1` first), so the
##   mesh is skinned to the body's skeleton exactly as a body piece is and
##   deforms with it.
## - **A skeleton of its own, hung from one body bone.** A weapon names
##   `blade_01.bsk` and `Bip01 R HandMid`; a shoulder piece `clothes_sa.bsk`
##   and `Bip01 Neck1`. Its mesh is weighted onto *that* skeleton
##   (`blade_01.bms`'s palette is `Bone01`), so the item's skeleton is built,
##   the mesh skinned to it, and the whole thing put under a
##   BoneAttachment3D on the named body bone at identity -- the item's own
##   root sits where the body bone is.
##
## The second convention is what the shoulder piece needed all along. Its
## vertices are in its own skeleton's space, not the body's, which is why
## reading them as body-space geometry put it near the pelvis.
##
## Returns null, having attached nothing, if the file is missing, is not an
## item, or none of its meshes could be loaded.
static func attach_item_from_archive(
	archive: Pk2Reader, skeleton: Skeleton3D, bsr_path: String
) -> AttachedItem:
	var bsr_data := _read(archive, bsr_path)
	if bsr_data.is_empty():
		push_error("SkinnedBsrAssembler: item %s not found in archive" % bsr_path)
		return null
	var parsed := BsrReader.parse(bsr_data)
	if parsed == null:
		return null
	if not parsed.is_item():
		push_error("SkinnedBsrAssembler: %s is not an item .bsr (type %d)" % [bsr_path, parsed.object_type])
		return null

	var material := ObjectLoader.load_material(archive, parsed.material_path) if parsed.material_path != "" else null
	var mesh_paths := parsed.all_mesh_paths()
	var meshes: Array = []
	for i in range(mesh_paths.size()):
		var bms_data := _read(archive, mesh_paths[i])
		if bms_data.is_empty():
			push_error("SkinnedBsrAssembler: item mesh %s not found in archive" % mesh_paths[i])
			continue
		var mesh := BmsReader.parse(bms_data)
		if mesh == null:
			continue
		var godot_material: Material = null
		if material != null and material.layers.size() > 0:
			var layer_idx := ObjectLoader._find_layer_by_name(material.layers, mesh.material_name)
			if layer_idx == -1:
				layer_idx = i if material.layers.size() == mesh_paths.size() else 0
			godot_material = ObjectLoader.build_godot_material(
				archive, parsed.material_path, material.layers[layer_idx]
			)
		meshes.append([mesh, godot_material])
	if meshes.is_empty():
		push_error("SkinnedBsrAssembler: %s: none of its %d mesh piece(s) loaded" % [bsr_path, mesh_paths.size()])
		return null

	var result := AttachedItem.new()
	if parsed.skeleton_path == "":
		# Weighted onto the body: one skinned instance per mesh, bound to
		# the body's own bones by name.
		var holder := Node3D.new()
		holder.name = bsr_path.get_file().get_basename()
		skeleton.add_child(holder)
		var any_skinned := false
		for pair in meshes:
			var mesh: BmsReader.ParsedMesh = pair[0]
			var mi := _skinned_instance(skeleton, mesh, pair[1])
			if mi == null:
				continue
			holder.add_child(mi)
			mi.skeleton = mi.get_path_to(skeleton)
			any_skinned = true
		if not any_skinned:
			holder.free()
			push_error("SkinnedBsrAssembler: %s names no skeleton and its mesh is not weighted onto the body" % bsr_path)
			return null
		result.node = holder
		result.skinned = true
		return result

	# A skeleton of its own, hung from a body bone.
	var bone_idx := skeleton.find_bone(parsed.attach_bone)
	if bone_idx == -1:
		push_error("SkinnedBsrAssembler: %s hangs from %s, which the body has no bone by" % [bsr_path, parsed.attach_bone])
		return null
	var bsk_data := _read(archive, parsed.skeleton_path)
	if bsk_data.is_empty():
		push_error("SkinnedBsrAssembler: item skeleton %s not found in archive" % parsed.skeleton_path)
		return null
	var parsed_skeleton := BskReader.parse(bsk_data)
	if parsed_skeleton == null:
		return null
	var item_skeleton := Skeleton3DBuilder.build_skeleton3d(parsed_skeleton)
	if item_skeleton == null or item_skeleton.get_bone_count() == 0:
		return null
	item_skeleton.name = bsr_path.get_file().get_basename()

	var attachment := BoneAttachment3D.new()
	attachment.name = "%s@%s" % [item_skeleton.name, parsed.attach_bone]
	attachment.bone_name = parsed.attach_bone
	skeleton.add_child(attachment)
	attachment.add_child(item_skeleton)
	var any_attached := false
	for pair in meshes:
		var mesh: BmsReader.ParsedMesh = pair[0]
		var mi := _skinned_instance(item_skeleton, mesh, pair[1])
		if mi == null:
			# An item mesh with no weights renders at its own origin, which
			# is the item skeleton's root -- rigid, but in the right place.
			mi = MeshInstance3D.new()
			mi.mesh = BmsReader.to_array_mesh(mesh)
			if pair[1] != null:
				mi.material_override = pair[1]
			item_skeleton.add_child(mi)
		else:
			item_skeleton.add_child(mi)
			mi.skeleton = mi.get_path_to(item_skeleton)
		any_attached = true
	if not any_attached:
		attachment.free()
		return null
	result.node = attachment
	result.attach_bone = parsed.attach_bone
	result.skinned = true
	return result

## A MeshInstance3D skinned to skeleton by the mesh's own bone palette, or
## null when the mesh carries no weights or names a bone the skeleton
## does not have.
static func _skinned_instance(
	skeleton: Skeleton3D, mesh: BmsReader.ParsedMesh, material: Material
) -> MeshInstance3D:
	if not mesh.is_skinned():
		return null
	var skin := Skeleton3DBuilder.build_skin(skeleton, mesh.bone_names)
	if skin == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = mesh.mesh_name if mesh.mesh_name != "" else "piece"
	mi.mesh = BmsReader.to_array_mesh(mesh)
	if material != null:
		mi.material_override = material
	mi.skin = skin
	# The caller sets `mi.skeleton` once the instance is in the tree; a
	# NodePath cannot be taken to a node the instance has no parent under.
	return mi

## The animation an assembled character plays for one action type in one
## group -- the file's own table (BsrReader.ParsedObject.animation_for),
## parsed on first use. Null when the file lists none for it.
static func animation_for(
	archive: Pk2Reader, assembled: AssembledCharacter, action_type: int, group: String = "default"
) -> BanReader.ParsedAnimation:
	if assembled == null or assembled.parsed == null:
		return null
	var path := assembled.parsed.animation_for(action_type, group)
	if path == "":
		return null
	if assembled.animation_cache.has(path):
		return assembled.animation_cache[path]
	var bytes := _read(archive, path)
	var anim: BanReader.ParsedAnimation = BanReader.parse(bytes) if not bytes.is_empty() else null
	if anim != null and anim.bones.is_empty():
		anim = null
	assembled.animation_cache[path] = anim
	return anim

## The bone whose bind position is nearest the mesh's own vertex centroid.
static func _nearest_bone(mesh: BmsReader.ParsedMesh, bone_positions: Dictionary) -> String:
	if mesh.vertices.is_empty():
		return ""
	var centre := _centroid(mesh)
	var best_bone := ""
	var best_distance := INF
	for bone_name in bone_positions:
		var d: float = centre.distance_to(bone_positions[bone_name])
		if d < best_distance:
			best_distance = d
			best_bone = bone_name
	return best_bone

static func _centroid(mesh: BmsReader.ParsedMesh) -> Vector3:
	var sum := Vector3.ZERO
	for v in mesh.vertices:
		sum += v.position
	return sum / float(mesh.vertices.size())

## Reads a path that may or may not carry the "res\" prefix the server
## tables omit and object.ifo includes -- same accommodation ObjectLoader
## and the dev tools make.
static func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	if path == "":
		return PackedByteArray()
	var entry := ObjectLoader.find_file(archive, path)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + path)
	if entry == null:
		return PackedByteArray()
	return archive.read_file(entry)
