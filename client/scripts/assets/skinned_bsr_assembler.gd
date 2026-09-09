extends RefCounted
class_name SkinnedBsrAssembler

## Assembles any character-category (`.bsr` type 1) model -- NPC, monster or
## player body -- from an open pk2 archive: skeleton, mesh pieces and
## materials, ready to place in the world.
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
## **The piece-to-bone mapping is computed, not tabulated.** `.bms` carries
## no per-vertex skinning (BMS_FORMAT.md), so each piece attaches rigidly to
## one bone. MonsterAssembler held that mapping as a hand-derived dictionary
## per creature, which does not scale past the two creatures in it. The
## dictionaries were derived by matching each piece's vertex centroid to the
## nearest bone bind position, and recomputing that at runtime reproduces
## both of them exactly -- 7/7 pieces for golem, 3/3 for scorpion,
## `client/tools/check_piece_bones.gd`. So the tables were only ever a cache
## of this computation, and it is done here directly.
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
## Animation names are not consistent across the archive: a monster calls it
## `mangnyang_stand01.ban`, an NPC calls it `chinaquest_priest_basic.ban`,
## and some carry only `_time` (an idle fidget). Matching in this order and
## falling back to whatever is listed first is what keeps a model animating
## at all rather than only the ones that happen to use one convention.
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
		push_error("SkinnedBsrAssembler: %s is not a character-category .bsr" % bsr_path)
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
		var idle_path := idle_animation_path(result.animation_paths)
		if idle_path != "":
			var ban_bytes := _read(archive, idle_path)
			if not ban_bytes.is_empty():
				var parsed_anim := BanReader.parse(ban_bytes)
				# An animation with no bone tracks would pose nothing; treat
				# it as absent rather than ticking it every frame for free.
				if parsed_anim != null and not parsed_anim.bones.is_empty():
					result.idle_animation = parsed_anim
	return result

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
