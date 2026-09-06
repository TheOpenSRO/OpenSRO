extends RefCounted
class_name ObjectLoader

## Glue layer tying Pk2Reader + BsrReader + BmsReader + BmtReader + DdjReader
## together: given an open pk2 archive and a .bsr path inside it, builds a
## renderable, textured Node3D.
##
## Sub-mesh pieces are added as siblings with no extra transform applied --
## confirmed correct, not a gap: each .bms piece already carries its own
## absolute position baked into its vertex data (see
## docs/protocol/BSR_FORMAT.md, "Sub-mesh pieces need no separate
## transform").
##
## Layer-to-mesh pairing: a real multi-piece object's own real sub-mesh
## .bms files each carry the same real material_name field character body
## parts do (see BMS_FORMAT.md) -- confirmed real by pulling a real
## 27-piece building (`bagh_city_palace.bsr`) and its real 28-layer
## material: every one of 4 real pieces checked had a material_name
## ("Bagh_City_Palace_04", ...) exactly matching a real layer_name in the
## material, in the same file-name-encodes-piece-number convention visible
## in every real layer name. So each piece is matched to its own real
## layer by that name first, the same mechanism already used for character
## parts -- not previously done for .bsr scenery, which only had the
## unconfirmed index-based fallback below. That fallback (pair by index
## when counts match, else layer 0) is now only reached for pieces without
## a matching real layer_name, which is the honest remaining unconfirmed
## case rather than the common one.

## Loads the real object at path within archive and returns a Node3D.
## path is usually a real .bsr (a MeshInstance3D per mesh piece, textured
## where a .bmt/.ddj could be resolved) -- but real object.ifo entries can
## also point at a real .cpd "Compound" object (2026-08-23, found
## live-testing real Jangan palace scenery: `ObjectLoader` previously tried
## to parse these as `.bsr` and failed outright on the real, different
## magic). A real .cpd groups several independent real .bsr references
## under one real name -- see docs/protocol/CPD_FORMAT.md -- so that case
## recurses back into this same function once per real sub-object and
## groups the results under one root Node3D. Returns null (and pushes an
## error) on failure.
static func load_object(archive: Pk2Reader, path: String) -> Node3D:
	if path.to_lower().ends_with(".cpd"):
		return _load_compound_object(archive, path)

	var bsr_path := path
	var bsr_entry := find_file(archive, bsr_path)
	if bsr_entry == null:
		push_error("ObjectLoader: %s not found in archive" % bsr_path)
		return null
	var bsr_data := archive.read_file(bsr_entry)
	var obj := BsrReader.parse(bsr_data)
	if obj == null:
		return null

	var root := Node3D.new()
	root.name = obj.object_name

	# A real, genuine mesh-less object (obj.mesh_path == "") is a real
	# particle-effect-only marker, not a failure -- see BsrReader.parse's
	# own doc comment on this real case (found auditing this project's
	# full real object catalog, 2026-08-25: "*_particle.bsr" files placed
	# over 1,200 times combined across a real client's map). Filtered out
	# here rather than passed to find_file, which would otherwise report a
	# real, spurious "" not found error.
	#
	# **De-duplicated 2026-09-02** (see docs/WORLD_ISSUES.md's forty-seventh
	# round). A real .bsr's own sub-mesh list normally *begins with the very
	# same path* as its primary mesh_path -- confirmed against real data
	# (e.g. `cj_sugi_house_01.bsr` declares mesh_path
	# `...\cj_sugi_house_01.bms` and then lists that identical path again as
	# its first sub-mesh, followed by `_02`/`_03`). Prepending mesh_path
	# unconditionally therefore built the same real mesh twice at the exact
	# same transform, so every such object rendered its main piece as two
	# perfectly coplanar copies -- real z-fighting, which is what made real
	# buildings look visibly wrong. Since this loader applies no per-mesh
	# transform, drawing one real mesh path twice is never meaningful, so
	# de-duplicating while preserving real declaration order is always
	# correct here.
	var mesh_paths: Array = []
	for candidate in ([obj.mesh_path] if obj.mesh_path != "" else []) + obj.sub_mesh_paths:
		var already := false
		for existing in mesh_paths:
			if (existing as String).to_lower() == (candidate as String).to_lower():
				already = true
				break
		if not already:
			mesh_paths.append(candidate)

	var material := load_material(archive, obj.material_path) if obj.material_path != "" else null

	var loaded_count := 0
	for i in range(mesh_paths.size()):
		var entry := find_file(archive, mesh_paths[i])
		if entry == null:
			push_error("ObjectLoader: %s not found in archive" % mesh_paths[i])
			continue
		var bms_data := archive.read_file(entry)
		var mesh := BmsReader.parse(bms_data)
		if mesh == null:
			continue

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = mesh.mesh_name
		var array_mesh := BmsReader.to_array_mesh(mesh)
		mesh_instance.mesh = array_mesh

		# Real static collision. A real .bms may carry its own real
		# navigation mesh (see BmsReader.parse_collision) -- the real
		# walkable surface the client itself uses for the object. When it
		# does, that is what the real game collides against, so it is used
		# here in place of the render geometry; see
		# _add_object_navmesh_collision for what that fixes and what it
		# changes.
		#
		# Otherwise, fall back to a trimesh shape derived directly from the
		# real render mesh, the way World3D's own real terrain collision is
		# built -- added 2026-08-25 after a live render showed the default
		# player camera embedded inside a real building's geometry at spawn:
		# real placed scenery previously had no collision at all, so nothing
		# (camera spring arm, player movement) could ever be blocked by a
		# wall, roof, or any other real object. This is the right fallback
		# rather than "no collision": the great majority of real meshes
		# carry no navigation section at all (465 of 4,000 real meshes
		# sampled do), because the real client only needs one for surfaces a
		# character can stand on or be stopped by.
		#
		# Skipped for meshes with no real geometry (create_trimesh_shape on
		# an empty ArrayMesh is a needless real physics-body cost for
		# nothing).
		var collision := BmsReader.parse_collision(bms_data)
		if collision != null and not collision.cells.is_empty():
			_add_object_navmesh_collision(mesh_instance, collision)
		elif array_mesh.get_surface_count() > 0:
			var body := StaticBody3D.new()
			var shape := CollisionShape3D.new()
			shape.shape = array_mesh.create_trimesh_shape()
			body.add_child(shape)
			mesh_instance.add_child(body)

		if material != null and material.layers.size() > 0:
			var layer_idx := _find_layer_by_name(material.layers, mesh.material_name)
			if layer_idx == -1:
				layer_idx = i if material.layers.size() == mesh_paths.size() else 0
			var godot_material := build_godot_material(archive, obj.material_path, material.layers[layer_idx])
			if godot_material != null:
				mesh_instance.material_override = godot_material

		root.add_child(mesh_instance)
		loaded_count += 1

	if loaded_count == 0 and not mesh_paths.is_empty():
		push_error("ObjectLoader: %s: none of its %d mesh piece(s) could be loaded" % [bsr_path, mesh_paths.size()])
		root.free()
		return null

	return root

## How far a real object navigation mesh's own blocking edges are extruded
## upward into wall collision.
##
## This is a project choice, not recovered data, for the same real reason
## World3D.NAVMESH_WALL_HEIGHT is: the real client tests a navigation edge as
## a 2D line rather than as geometry, so nothing in the real format gives a
## wall a height. Matches NAVMESH_WALL_HEIGHT so terrain and object walls
## behave alike.
const OBJECT_NAVMESH_WALL_HEIGHT := 40.0

## Attaches collision built from a real object navigation mesh: the real
## navigable cells as the walkable surface, plus the real blocking edges
## extruded into walls.
##
## This is what makes real staircases, bridges and raised floors climbable.
## The real client never collides a character against a building's render
## geometry -- it walks this real cell/edge graph and takes the character's
## height from the cell underfoot -- so colliding against the render mesh
## instead put a real vertical riser in front of the player at every step,
## which is exactly the "can't climb the temple stairs, but can finagle up
## the sloped edges beside them" failure a real playtest hit.
##
## Both parts go in one shape: the cells alone would let the player walk off
## the object's edge into space, and the walls alone would leave nothing to
## stand on.
##
## Worth knowing about the change in behaviour: an object with a navigation
## mesh is now solid only where the real game says it is solid, so parts a
## character can neither stand on nor be stopped by -- a roof overhead, most
## obviously -- no longer block anything, including the camera spring arm.
## That is what the real client does, and it is the point of using this data,
## but it is a real, visible difference from colliding against render
## geometry rather than a free improvement.
static func _add_object_navmesh_collision(
	mesh_instance: MeshInstance3D, collision: BmsReader.CollisionMesh
) -> void:
	var faces := BmsCollision.surface_triangles(collision)
	faces.append_array(BmsCollision.build_wall_triangles(collision, OBJECT_NAVMESH_WALL_HEIGHT))
	if faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# Required, not a tweak: Godot's ConcavePolygonShape3D is one-sided by
	# default, and with it left off a capsule dropped onto a real staircase's
	# navigation mesh falls straight through. Two-sided is also what this
	# data means -- a real blocking edge stops a character approaching from
	# either side. See BmsCollision.surface_triangles.
	shape.backface_collision = true
	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = shape
	var body := StaticBody3D.new()
	body.name = "NavmeshCollision"
	body.add_child(collision_shape)
	mesh_instance.add_child(body)

## Loads a real .cpd "Compound" object -- see load_object's doc comment
## and docs/protocol/CPD_FORMAT.md. Recurses into load_object once per
## real sub-object path (which may itself recursively be another real
## .cpd, though none seen in this project's real samples so far), grouping
## the results as children of one root Node3D named after the real
## compound name. No per-piece transform is applied -- confirmed correct,
## not a gap: live-rendering a real decorated Christmas tree
## (x_mas_tree_b.cpd, 9 real sub-objects) this way produced a genuinely
## correct result, the trunk/candles/ornaments all landing in their real,
## sensible positions purely from each real .bms piece's own baked
## absolute vertex data -- the same real convention load_object's own doc
## comment already establishes for .bsr sub-mesh pieces, now confirmed for
## .cpd too. See CPD_FORMAT.md.
static func _load_compound_object(archive: Pk2Reader, cpd_path: String) -> Node3D:
	var cpd_entry := find_file(archive, cpd_path)
	if cpd_entry == null:
		push_error("ObjectLoader: %s not found in archive" % cpd_path)
		return null
	var compound := CpdReader.parse(archive.read_file(cpd_entry))
	if compound == null:
		return null

	var root := Node3D.new()
	root.name = compound.name

	var loaded_count := 0
	for sub_path in compound.bsr_paths:
		var child := load_object(archive, sub_path)
		if child == null:
			continue
		root.add_child(child)
		loaded_count += 1

	if loaded_count == 0:
		push_error("ObjectLoader: %s: none of its %d real compound piece(s) could be loaded" % [cpd_path, compound.bsr_paths.size()])
		root.free()
		return null

	return root

## Loads and parses the .bmt at path within archive. Returns null (and
## pushes an error) on failure.
static func load_material(archive: Pk2Reader, bmt_path: String) -> BmtReader.ParsedMaterial:
	var entry := find_file(archive, bmt_path)
	if entry == null:
		push_error("ObjectLoader: %s not found in archive" % bmt_path)
		return null
	return BmtReader.parse(archive.read_file(entry))

## Real DDS FourCCs that carry a genuine per-pixel alpha channel Godot's
## decoder actually preserves (DXT1 has no alpha in Godot's built-in
## decoder even though the format nominally supports 1-bit punch-through
## alpha, so it's deliberately not included here -- see this function's
## own doc comment for how this was confirmed, and DDJ_FORMAT.md).
## **DXT1 added 2026-09-02** (see docs/WORLD_ISSUES.md's fifty-second
## round). BC1/DXT1 carries a real 1-bit alpha channel and real foliage uses
## it: a real willow's own leaf textures (`tre_willow02_leaf01`/`_leaf02`)
## are DXT1 with **79%** of their texels below opaque, but DXT1 being absent
## here meant they never got cutout and rendered as huge solid rectangles --
## the real dark slabs standing behind real trees in a live render, traced
## to `tre_willow03_leaf01` by raycasting into them.
const _ALPHA_FOURCCS := ["DXT1", "DXT3", "DXT5"]

## Minimum fraction of a real texture's texels that must be below opaque
## before a real **DXT1** texture is treated as a cutout.
##
## DXT3/DXT5 carry graded alpha, where even a small amount is meaningful, so
## they keep the original "any texel below opaque" rule. DXT1's alpha is
## 1-bit -- a real texture either uses it clearly or not at all -- and real
## measurements separate the two cases cleanly, with no middle ground: real
## willow leaves 79%, real grass 79%, against real palace wall and roof
## DXT1 textures at exactly **0%**. Requiring a real fraction rather than a
## single stray texel keeps genuinely solid real masonry solid even if a
## block decodes with one imperfect texel.
const _DXT1_CUTOUT_MIN_ALPHA_FRACTION := 0.05

## Builds a Godot StandardMaterial3D from a parsed material layer, resolving
## its texture (a bare filename) against the same directory bmt_path lives
## in. bmt_path is only used for that directory resolution. Returns a
## colors-only material (no albedo texture) if the layer has no texture or
## it can't be found/decoded.
##
## Real alpha-cutout foliage (2026-08-23): confirmed by pulling a real leaf
## card material (`tre_leaf01.bmt` -> `tre_leaf_01.ddj`) and finding its
## real DDS FourCC is DXT3 -- a format with a genuine per-pixel alpha
## channel -- while this function previously never set any transparency
## mode at all, so Godot rendered the full opaque RGB data (including the
## parts real alpha is supposed to cut out), showing as a solid dark
## quad/cross around the leaf card instead of a cutout leaf cluster. Now
## enables real alpha-scissor transparency (a hard cutout, matching how a
## real leaf card's alpha channel is used -- fully in or fully out, not a
## soft blend) and disables backface culling whenever the real decoded
## texture format carries real alpha, since a real foliage/leaf card is
## meant to be visible from both sides. `layer.unknown`'s real BMT_FORMAT.md
## meaning remains unconfirmed and isn't used here -- the real DDS FourCC
## the texture file itself already carries is a directly confirmed, more
## reliable signal.
## Real cutout foliage shader -- see foliage.gdshader's own top comment for
## why a real double-sided leaf card cannot be a StandardMaterial3D and
## still light the way the real client lights it.
const FOLIAGE_SHADER := preload("res://scripts/assets/foliage.gdshader")

## Real alpha-cutout threshold. A real leaf card's alpha is used fully in
## or fully out, so the exact midpoint is the natural cut.
const FOLIAGE_ALPHA_SCISSOR := 0.5

## Builds the real cutout-foliage material for a real texture that carries
## real alpha, in place of the StandardMaterial3D used for everything else.
static func _build_foliage_material(layer: BmtReader.Layer, tex: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = layer.layer_name
	mat.shader = FOLIAGE_SHADER
	mat.set_shader_parameter("albedo", layer.diffuse)
	mat.set_shader_parameter("albedo_texture", tex)
	mat.set_shader_parameter("alpha_scissor", FOLIAGE_ALPHA_SCISSOR)
	return mat

static func build_godot_material(archive: Pk2Reader, bmt_path: String, layer: BmtReader.Layer) -> Material:
	var mat := StandardMaterial3D.new()
	mat.resource_name = layer.layer_name
	mat.albedo_color = layer.diffuse

	if layer.texture_path == "":
		return mat

	# Real texture_path is usually a bare filename (resolve against
	# bmt_path's own directory, per this function's doc comment) -- but a
	# real Jangan palace material (2026-08-23 live-testing) was found to
	# carry a real *full path* instead (e.g.
	# "prim\mtrl\bldg\china\dunhuang\buildings\naru_obj.ddj", pointing at a
	# completely different real directory than the .bmt referencing it).
	# Prefixing that with the .bmt's own directory produced a nonsensical
	# double path that could never resolve. A real path already contains a
	# separator; a bare filename never does, so that's what distinguishes
	# the two real cases.
	var tex_path: String
	if layer.texture_path.contains("\\") or layer.texture_path.contains("/"):
		tex_path = layer.texture_path
	else:
		var dir := bmt_path.replace("\\", "/").get_base_dir()
		tex_path = dir + "/" + layer.texture_path if dir != "" else layer.texture_path
	var tex_entry := find_file(archive, tex_path)
	if tex_entry == null:
		push_error("ObjectLoader: texture %s (referenced by %s) not found in archive" % [tex_path, bmt_path])
		return mat

	var parsed_tex := DdjReader.parse(archive.read_file(tex_entry))
	if parsed_tex == null:
		return mat
	var godot_tex := DdjReader.to_texture(parsed_tex)
	if godot_tex != null:
		mat.albedo_texture = godot_tex
		# **Corrected 2026-08-26** (see docs/WORLD_ISSUES.md): this used to
		# trigger cutout transparency + disabled backface culling purely
		# from the texture's real compression *format* (DXT3/DXT5) -- but
		# that format only means the format *supports* an alpha channel,
		# not that this specific real texture actually uses it for cutout.
		# A real, fully-opaque DXT3/DXT5 texture (an ordinary, unremarkable
		# format choice for plain opaque art, e.g. real character skin) was
		# getting backface culling disabled for no real reason -- on a real
		# closed/solid body mesh, that lets a viewer see straight through
		# to the mesh's own real back-facing surface, showing the wrong
		# side's real texture region (a real, reported bug: front/back
		# appearing swapped depending on viewing angle). Now actually
		# decodes the real pixel data and only applies cutout+no-culling if
		# a real texel's alpha is genuinely below opaque, instead of
		# assuming from the format alone.
		var needs_cutout := false
		if _ALPHA_FOURCCS.has(parsed_tex.four_cc):
			if parsed_tex.four_cc == "DXT1":
				needs_cutout = _real_alpha_fraction(godot_tex) >= _DXT1_CUTOUT_MIN_ALPHA_FRACTION
			else:
				needs_cutout = _has_real_alpha_variance(godot_tex)
		if needs_cutout:
			# Not a StandardMaterial3D: a real double-sided card has to keep
			# its authored normal on both faces to light the way the real
			# client lights it, which StandardMaterial3D cannot express.
			# See foliage.gdshader.
			return _build_foliage_material(layer, godot_tex)

	return mat

## Decodes texture's real pixel data and returns true only if at least one
## real texel's alpha is meaningfully below fully opaque -- see
## build_godot_material's own doc comment for why format alone
## (_ALPHA_FOURCCS) isn't a reliable signal that a real texture actually
## needs cutout transparency. 250/255 (not a stricter 255) as the opaque
## threshold tolerates real DXT compression's own lossy rounding on a
## genuinely fully-opaque real source image.
static func _has_real_alpha_variance(tex: Texture2D) -> bool:
	var image := tex.get_image()
	if image == null:
		return false
	if image.is_compressed():
		image = image.duplicate()
		if image.decompress() != OK:
			return false
	var data := image.get_data()
	var format := image.get_format()
	if format != Image.FORMAT_RGBA8 and format != Image.FORMAT_RGBAF and format != Image.FORMAT_RGBAH:
		return false
	# RGBA8 is the real, common case decompress() actually produces here --
	# a bare byte-stride scan is far cheaper than per-pixel get_pixel()
	# calls for a real texture that can be hundreds of pixels per side.
	if format == Image.FORMAT_RGBA8:
		var i := 3
		while i < data.size():
			if data[i] < 250:
				return true
			i += 4
		return false
	# A real non-RGBA8 decompressed format (uncommon here) -- fall back to
	# the slower but always-correct per-pixel path.
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a < 250.0 / 255.0:
				return true
	return false

## Fraction of a real texture's texels whose alpha is below opaque -- the
## real signal _DXT1_CUTOUT_MIN_ALPHA_FRACTION is compared against. Same
## real 250/255 opaque threshold _has_real_alpha_variance uses (tolerating
## real DXT block-compression rounding), just counted rather than
## short-circuited on the first hit. Returns 0.0 for a texture that can't be
## decoded, so an undecodable real texture is never treated as a cutout.
static func _real_alpha_fraction(texture: Texture2D) -> float:
	if texture == null:
		return 0.0
	var image := texture.get_image()
	if image == null:
		return 0.0
	image = image.duplicate()
	image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		return 0.0
	var data := image.get_data()
	var below := 0
	var total := 0
	var i := 3
	while i < data.size():
		if data[i] < 250:
			below += 1
		total += 1
		i += 4
	return float(below) / float(maxi(total, 1))

## Loads a single .bms mesh at path within archive and returns a
## MeshInstance3D. Returns null (and pushes an error) on failure.
static func load_mesh(archive: Pk2Reader, bms_path: String) -> MeshInstance3D:
	var entry := find_file(archive, bms_path)
	if entry == null:
		push_error("ObjectLoader: %s not found in archive" % bms_path)
		return null
	var data := archive.read_file(entry)
	var mesh := BmsReader.parse(data)
	if mesh == null:
		return null

	var instance := MeshInstance3D.new()
	instance.name = mesh.mesh_name
	instance.mesh = BmsReader.to_array_mesh(mesh)
	return instance

## Returns the index of the layer in layers whose real layer_name exactly
## matches material_name (a real .bms mesh's own material_name field), or
## -1 if none match (an empty material_name from a mesh with no such field
## never matches). See this file's top comment for how this real
## name-matching mechanism was confirmed for .bsr sub-mesh pieces.
static func _find_layer_by_name(layers: Array[BmtReader.Layer], material_name: String) -> int:
	if material_name == "":
		return -1
	for i in range(layers.size()):
		if layers[i].layer_name == material_name:
			return i
	return -1

## Resolves a Windows-style backslash path (as stored in .bsr/.bms files)
## against an already-open pk2 archive, walking one directory level at a
## time. Returns null if any component isn't found.
static func find_file(archive: Pk2Reader, path: String) -> Pk2Reader.Entry:
	var parts := path.replace("\\", "/").split("/")
	var entries := archive.read_dir()
	for i in range(parts.size()):
		var part := parts[i]
		var found: Pk2Reader.Entry = null
		for e in entries:
			if e.name.to_lower() == part.to_lower():
				found = e
				break
		if found == null:
			return null
		if i == parts.size() - 1:
			return found
		if not found.is_dir:
			return null
		entries = archive.read_dir_at(found)
	return null
