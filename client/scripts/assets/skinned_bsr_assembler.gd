extends RefCounted
class_name SkinnedBsrAssembler

## Meta on a body material whose object carries an env-map mod (round 719).
const ENV_MAPPED_META := "opensro_env_mapped"

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
	## Round 738 (A2): the one Skin every mesh skinned to this skeleton shares
	## when it was assembled with `canonical` (Skeleton3DBuilder.canonical_skin);
	## null otherwise.
	var canonical_skin: Skin = null

## Substrings that name a standing-still animation, most specific first.
##
## The fallback for a file with no animation groups. Real files say which
## animation stands still -- the type-0 entry of their `default` group,
## `mangnyang_stand01` for the monster and `chinaquest_priest_basic` for
## the NPC -- and that is read first; these hints are what kept models
## animating before the groups were read, and still cover a file this
## reader cannot parse the groups of.
static var IDLE_ANIMATION_HINTS := ["stand01", "stand", "basic", "idle", "wait"]

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
##
## `canonical` (round 738, A2; CharacterAppearance's bodies): every skinned
## piece shares one Skin naming every bone of the skeleton
## (Skeleton3DBuilder.canonical_skin), its vertices' palette indices turned
## into bone indices -- the same matrices, so the same vertices; one skin
## for the skeleton to write per pose instead of one per piece. The
## skeleton gets its OBJECT_SPACE_BONE first, so every copy of it, and every
## item made on one, has the same bones.
static func assemble_from_archive(
	archive: Pk2Reader, bsr_path: String, with_animation: bool = false, canonical: bool = false
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
	if canonical:
		Skeleton3DBuilder._object_space_bone(skeleton)
		result.canonical_skin = Skeleton3DBuilder.canonical_skin(skeleton)
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
			# The draw rule's object inputs (ObjectLoader.layer_draw_rule,
			# round 625 and its review): the env-map mod governing all its
			# materials, the material's MTRL mod, and the two-pass flag.
			godot_material = ObjectLoader.build_godot_material(
				archive, parsed.material_path, material.layers[layer_idx], {},
				parsed.env_map_flags, parsed.mtrl_mod_for(layer_idx), parsed.two_pass()
			)
			# Round 719: whether the object has an env-map mod. The original's
			# translucent draw takes the fade alone as alpha for such a layer
			# (CRTModEnvMap::vslot_004 ORs 0x60000000 into every material's flag
			# word; CObjRendererVS::FUN_00c428c0 then SELECTARG2 TFACTOR) and
			# texture alpha x fade for any other; the select screen reads it.
			if godot_material != null and parsed.env_map_flags >= 0:
				godot_material.set_meta(ENV_MAPPED_META, true)

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
			var skin := Skeleton3DBuilder.build_skin(skeleton, mesh.bone_names, mesh.object_space_vertices > 0)
			if skin != null:
				var mi := MeshInstance3D.new()
				# Named after the piece and tagged with its index in the file's
				# mesh list, so the body-piece hiding (apply_body_hides) finds it
				# by the index the attachable block names -- a duplicate of this
				# template keeps the meta; an unnamed node's generated name it
				# does not.
				mi.name = piece
				if result.canonical_skin != null:
					mi.mesh = Skeleton3DBuilder.canonical_mesh(mesh, skin)
				else:
					mi.mesh = BmsReader.to_array_mesh(mesh)
				if godot_material != null:
					mi.material_override = godot_material
				skeleton.add_child(mi)
				mi.skin = result.canonical_skin if result.canonical_skin != null else skin
				mi.skeleton = mi.get_path_to(skeleton)
				mi.set_meta(BODY_MESH_META, i)
				var twin := ObjectLoader.add_front_pass(mi)
				if twin != null:
					twin.set_meta(BODY_MESH_META, i)
				result.skinned_pieces += 1
				attached += 1
				continue
		var before := skeleton.get_child_count()
		CharacterAssembler.attach_rigid(
			skeleton, BmsReader.to_array_mesh(mesh), bone_name, godot_material
		)
		if skeleton.get_child_count() > before:
			skeleton.get_child(skeleton.get_child_count() - 1).set_meta(BODY_MESH_META, i)
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
					# The stand entry of `default`, for its sound tracks; an
					# idle found by the name hints belongs to no entry.
					var idle_group := parsed.animation_group_for(BsrReader.AnimationEntry.TYPE_STAND)
					if idle_group != "":
						parsed_anim.set_meta(BsrReader.CLIP_META, [BsrReader.AnimationEntry.TYPE_STAND, idle_group])
	return result

## The meta a body's own mesh node carries: its index in the body `.bsr`'s
## mesh list (BsrReader.ParsedObject.all_mesh_paths()), which is what the
## body's attachable block maps each piece key to (round 687, READ).
const BODY_MESH_META := &"bsr_mesh_index"

## Retail's body-piece hiding (round 687), on an assembled body:
## `CCompChar::FUN_00c1f890` (0x00c1f890), which the client runs when a part
## comes off (vslot_061 0x00c1fa00, vslot_064), and whose second half is what
## attaching runs for one item (`FUN_00c1f790`, from vslot_067 0x00c1fa90 for
## a resource of tag 5, CResAttachable). READ:
##
## 1. show every mesh of the body (`FUN_00c392a0(1)`);
## 2. for every attached part other than the body (part id 1, INFERRED to be
##    the body) whose attachable flag is 1, and every key it lists, switch
##    off each body mesh the BODY's block maps that same key to
##    (`FUN_00c35050(value, 0)`: CRTMesh +0x10 = 0, skipped by the gather
##    FUN_00c38f50).
##
## `body` is the body's parsed `.bsr` (its attachable block names key ->
## mesh index); `items` the attachable blocks (BsrReader.Attachable, nulls
## skipped) of what is worn now. The body's mesh nodes are found under
## `skeleton` by BODY_MESH_META, never by position or name: mesh order
## differs per file (MEASURED across the 53 Figures). Showing first makes it
## safe to call again after any change -- an unequip is a call with the
## remaining items. Returns how many body meshes it hid (a mesh's front-pass
## twin is not counted again).
static func apply_body_hides(skeleton: Skeleton3D, body: BsrReader.ParsedObject, items: Array) -> int:
	if skeleton == null:
		return 0
	for n in skeleton.get_children():
		if n.has_meta(BODY_MESH_META):
			(n as Node3D).visible = true
	var got := hidden_body_nodes(skeleton, body, items)
	for n in got[0]:
		(n as Node3D).visible = false
	return int(got[1])

## apply_body_hides' rule without touching a node (round 756: a body drawn
## far from its templates, CharacterAppearance.far_recipe): the children of
## `skeleton` the worn `items` hide, as node -> true, and how many body meshes
## that is (a mesh's front-pass twin and a rigid piece's attachment are the
## same mesh drawn again, counted once). [Dictionary, int].
static func hidden_body_nodes(skeleton: Skeleton3D, body: BsrReader.ParsedObject, items: Array) -> Array:
	var out := {}
	if skeleton == null or body == null or body.attachable == null:
		return [out, 0]
	var by_index := {}
	for n in skeleton.get_children():
		if n.has_meta(BODY_MESH_META):
			var idx := int(n.get_meta(BODY_MESH_META))
			if not by_index.has(idx):
				by_index[idx] = []
			(by_index[idx] as Array).append(n)
	var hidden := 0
	for item in items:
		var block := item as BsrReader.Attachable
		if block == null or not block.hides_body():
			continue
		for key in block.keys():
			for idx in body.attachable.values_for(key):
				var nodes: Array = by_index.get(idx, [])
				if nodes.is_empty() or out.has(nodes[0]):
					continue
				for n in nodes:
					out[n] = true
				hidden += 1
	return [out, hidden]

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
	## The item file's attachable block (round 687): which body pieces it
	## covers and whether it hides them (apply_body_hides). Null when the
	## block did not parse.
	var attachable: BsrReader.Attachable = null

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
##   the mesh skinned to it, and the whole thing hung from the named body
##   bone by the client's own composition (below).
##
## The second convention is what the shoulder piece needed all along. Its
## vertices are in its own skeleton's space, not the body's, which is why
## reading them as body-space geometry put it near the pelvis.
##
## **How the client composes an own-skeleton item onto the bone** (read from
## `sro_client.exe`, see docs/protocol/BSR_FORMAT.md): `CCompChar::FUN_00c4fc70`
## looks the `.bsr`'s attach-bone name up in the body and makes that bone the
## item ROOT bone's parent socket, in update mode 1; mode 1
## (`CRTBone::FUN_00c48fe0`) is `world_root = local_root x [R(attach.skin) |
## t(attach.world)]`, then `skin_root = invBind_root x world_root`, where
## `attach.skin = invBind_attach x world_attach` is the bone's rotation
## RELATIVE TO ITS BIND. A root's local is its bind, so `invBind_root x
## local_root` cancels: the item's model space lands at the attach bone's
## world position, rotated only by how far that bone has turned from its
## rest -- its axes are the body's at rest, not the bone's. Under a
## BoneAttachment3D (which applies the bone's full global pose) that is the
## constant child transform `(B_rest_attach^-1, 0)`. The item's own root
## rest is left as the file gives it, so its skin is identity at rest.
## Measured (tools/probe_attach.gd): this puts sword, blade and spear -- one
## hand, one set of clips -- on one heading, and the `_sa` collar across the
## shoulders 1.6 above `Bip01 Neck1`, where round 137's "undo the item
## root's rest" only ever fitted `sword_01` (whose root rest happens to
## equal the hand's) and turned the collar front-to-back.
##
## Returns null, having attached nothing, if the file is missing, is not an
## item, or none of its meshes could be loaded.
##
## `missing_bones_to_object_space` passes the client's rule for a palette bone
## the body lacks to Skeleton3DBuilder.build_skin (round 683; off by default,
## so the world draws as before until it opts in).
##
## `canonical` (round 738, A2): the body's shared Skin
## (AssembledCharacter.canonical_skin); a piece weighted onto the body is
## then remapped onto it as the body's own pieces are. An item with its own
## skeleton keeps its own skins: that skeleton is never posed.
static func attach_item_from_archive(
	archive: Pk2Reader, skeleton: Skeleton3D, bsr_path: String,
	missing_bones_to_object_space: bool = false, canonical: Skin = null
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
			# The draw rule's object inputs (ObjectLoader.layer_draw_rule,
			# round 625 and its review): the env-map mod governing all its
			# materials, the material's MTRL mod, and the two-pass flag.
			godot_material = ObjectLoader.build_godot_material(
				archive, parsed.material_path, material.layers[layer_idx], {},
				parsed.env_map_flags, parsed.mtrl_mod_for(layer_idx), parsed.two_pass()
			)
			# Round 719: whether the object has an env-map mod. The original's
			# translucent draw takes the fade alone as alpha for such a layer
			# (CRTModEnvMap::vslot_004 ORs 0x60000000 into every material's flag
			# word; CObjRendererVS::FUN_00c428c0 then SELECTARG2 TFACTOR) and
			# texture alpha x fade for any other; the select screen reads it.
			if godot_material != null and parsed.env_map_flags >= 0:
				godot_material.set_meta(ENV_MAPPED_META, true)
		meshes.append([mesh, godot_material])
	if meshes.is_empty():
		push_error("SkinnedBsrAssembler: %s: none of its %d mesh piece(s) loaded" % [bsr_path, mesh_paths.size()])
		return null

	var result := AttachedItem.new()
	result.attachable = parsed.attachable
	if parsed.skeleton_path == "":
		# Weighted onto the body: one skinned instance per mesh, bound to
		# the body's own bones by name.
		var holder := Node3D.new()
		holder.name = bsr_path.get_file().get_basename()
		skeleton.add_child(holder)
		var any_skinned := false
		for pair in meshes:
			var mesh: BmsReader.ParsedMesh = pair[0]
			var mi := _skinned_instance(skeleton, mesh, pair[1], missing_bones_to_object_space, canonical)
			if mi == null:
				continue
			holder.add_child(mi)
			mi.skeleton = mi.get_path_to(skeleton)
			ObjectLoader.add_front_pass(mi)
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
	# The client's composition (see this function's doc comment): the item's
	# model space sits at the attach bone's position, rotated by the bone's
	# turn away from its rest and nothing else. The BoneAttachment3D applies
	# the bone's full global pose `[B_pose | p]`; multiplying by the inverse
	# of the bone's global REST rotation leaves `[B_pose * B_rest^-1 | p]`,
	# which is `attach.skin`'s rotation at `attach.world`'s position -- mode
	# 1 of CRTBone::FUN_00c48fe0 with the root's own rest cancelled. The
	# item skeleton keeps its file rest, so its root's skin is identity.
	#
	# Round 137 undid the ITEM ROOT's rest here instead. That fitted
	# `sword_01` only because its root rest happens to equal the hand's
	# global rest; it pointed the blade and spear down where the sword
	# pointed forward, and turned the `_sa` collar front-to-back (round
	# 141). tools/probe_attach.gd has the numbers for both.
	item_skeleton.transform = Transform3D(
		skeleton.get_bone_global_rest(bone_idx).basis.inverse(), Vector3.ZERO)
	var any_attached := false
	for pair in meshes:
		var mesh: BmsReader.ParsedMesh = pair[0]
		var mi := _skinned_instance(item_skeleton, mesh, pair[1], missing_bones_to_object_space)
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
		ObjectLoader.add_front_pass(mi)
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
	skeleton: Skeleton3D, mesh: BmsReader.ParsedMesh, material: Material,
	missing_bones_to_object_space: bool = false, canonical: Skin = null
) -> MeshInstance3D:
	if not mesh.is_skinned():
		return null
	var skin := Skeleton3DBuilder.build_skin(skeleton, mesh.bone_names, mesh.object_space_vertices > 0,
		missing_bones_to_object_space)
	if skin == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = mesh.mesh_name if mesh.mesh_name != "" else "piece"
	if canonical != null:
		mi.mesh = Skeleton3DBuilder.canonical_mesh(mesh, skin)
		skin = canonical
	else:
		mi.mesh = BmsReader.to_array_mesh(mesh)
	if material != null:
		mi.material_override = material
	mi.skin = skin
	# The caller sets `mi.skeleton` once the instance is in the tree; a
	# NodePath cannot be taken to a node the instance has no parent under.
	return mi

## Meta on a clip animation_for parsed: its file path, lower case.
const CLIP_PATH_META := "opensro_clip_path"

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
	# The entry the clip was found as, for its sound tracks
	# (BsrReader.CLIP_META; AnimSounds).
	var found := [action_type, assembled.parsed.animation_group_for(action_type, group)]
	if assembled.animation_cache.has(path):
		var cached = assembled.animation_cache[path]
		if cached != null:
			(cached as Object).set_meta(BsrReader.CLIP_META, found)
		return cached
	var bytes := _read(archive, path)
	var anim: BanReader.ParsedAnimation = BanReader.parse(bytes) if not bytes.is_empty() else null
	if anim != null and anim.bones.is_empty():
		anim = null
	if anim != null:
		anim.set_meta(BsrReader.CLIP_META, found)
		# The file it came from (round 738's review, F1): CrowdAnim shares a
		# clip's baked poses between bodies by path, never the clip object,
		# whose entry tag is the body's own.
		anim.set_meta(CLIP_PATH_META, path.to_lower())
	assembled.animation_cache[path] = anim
	return anim

## The bone whose bind position is nearest the mesh's own vertex centroid.
static func _nearest_bone(mesh: BmsReader.ParsedMesh, bone_positions: Dictionary) -> String:
	if mesh.vertex_count() == 0:
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
	# From the packed positions, so a natively parsed mesh never builds its
	# Vertex objects (round 669); the same sum, in the same order.
	var positions := mesh.positions()
	var sum := Vector3.ZERO
	for p in positions:
		sum += p
	return sum / float(positions.size())

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
