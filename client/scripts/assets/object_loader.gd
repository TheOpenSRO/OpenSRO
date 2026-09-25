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

## What could not be loaded this run -- a count and the last few messages
## -- for the debug panel, which is how a tester on their own archive can
## say "the buildings are black" and read off which textures were missing.
## Static because every loader function is; nothing resets it.
static var missing_count := 0
static var missing_recent: Array[String] = []
const MISSING_RECENT_KEPT := 12

static func _missing(what: String) -> void:
	missing_count += 1
	missing_recent.append(what)
	if missing_recent.size() > MISSING_RECENT_KEPT:
		missing_recent.pop_front()
	push_error("ObjectLoader: %s" % what)

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
##
## `texture_cache` (round 559): `.ddj` path -> the Texture2D decoded for
## it, shared by every material built through the same dictionary, so two
## models -- or two pieces of one -- that name the same texture decode and
## upload it once. The caller owns it and its lifetime: World3D keeps one
## per world (`_object_textures`, freed with the world). A call without one
## gets a fresh dictionary that is dropped with the call: the pieces of
## that one object share their textures, and nothing outlives the call.
## An entry is `{"texture": Texture2D, "four_cc": String, "alpha": {..}}`,
## the last the alpha statistics already measured on its Image (round 566,
## _alpha_stat), so a texture is never read back to be measured again.
##
## Since round 566 this is the two halves below run back to back on the
## caller's thread: `commit_object(prepare_object(...))`.
static func load_object(archive: Pk2Reader, path: String, texture_cache: Dictionary = {}) -> Node3D:
	return commit_object(prepare_object(archive, path, snapshot_textures(texture_cache)), texture_cache)

## An object prepared off the main thread (round 566) -- the PREPARE half of
## load_object.
##
## Everything load_object did that produces plain data: the `.bsr` (or
## `.cpd`) read and parsed, its `.bmt` read and inflated, every `.bms` piece
## read, parsed and turned into its surface arrays (BmsReader.to_arrays) and
## its collision faces (_piece_faces: the list `create_trimesh_shape()` read
## back out of the uploaded mesh until this round), each texture decoded to
## an Image (DdjReader.to_image) and each material's alpha classification
## measured on that Image (_prepare_material). The COMMIT half, commit_object,
## builds what owns a RenderingServer or PhysicsServer RID -- the ArrayMesh,
## the ImageTexture, the materials, the shape -- and the nodes, on the main
## thread. World3D prepares a streamed cell's objects on its WorkerThreadPool
## task beside its terrain (World3D._objects_prepare); until this round all
## of it ran on the main thread, a model at a time, inside the frame the cell
## was committed in -- the load benchmark on round 565's code measured 26-83
## ms of objects a streamed cell at the crossing, and `templates` 1,573 ms of
## the entry's centre (docs/RE_COMPLETION.md, round 566).
##
## Held to THE PREPARE-THREAD RULE (World3D._terrain_prepare;
## client/tools/README.md, "Load benchmark"): no Node and no RID-owning
## Resource -- the result holds Images, packed arrays, Arrays, Dictionaries
## and the readers' RefCounted structs only (object_loader_test.gd walks it)
## -- no scene tree, no server, archive reads only through Pk2Reader (locked
## per handle since round 565), and no write to this class's static state:
## what _missing would report goes in `missing` and QA lines in `log`, for
## the commit to report in order. A reader's own push_error on a malformed
## file is printed from the calling thread, as the terrain prepare's readers'
## are.
##
## `known_textures`: snapshot_textures of the cache the commit will use --
## the textures it already holds, by key, with their four_cc and measured
## statistics and never the Texture2D -- so a texture the world has uploaded
## is not decoded again. `textures`: where the decoded ones go, key ->
## `{"image": Image, "four_cc": String, "alpha": {..}}`; pass one dictionary
## to every prepare of one job and two models naming one texture decode it
## once (World3D does).
##
## Returns `{"path", "root", "textures", "missing", "log"}`; `root` is the
## node description commit_object builds (`{"kind": "bsr", "name", "pieces"}`
## or `{"kind": "cpd", "name", "children"}`), null where load_object returned
## null.
static func prepare_object(archive: Pk2Reader, path: String, known_textures: Dictionary = {}, textures: Dictionary = {}) -> Dictionary:
	var prepared := {"path": path, "root": null, "textures": textures, "missing": [], "log": []}
	prepared["root"] = _prepare_node(archive, path, known_textures, prepared)
	return prepared

## The COMMIT half of load_object (round 566), on the main thread: reports
## what the prepare recorded (_missing, the QA lines), uploads the textures
## it decoded that `texture_cache` does not hold yet (commit_textures), and
## builds the node tree load_object has always returned -- a Node3D named
## after the object, a MeshInstance3D per piece with its StaticBody3D and
## trimesh shape and its material, a compound's sub-objects under its root.
## Null where load_object returned null. Safe to call again on the same
## prepared object: it builds a new tree and uploads nothing twice.
static func commit_object(prepared: Dictionary, texture_cache: Dictionary = {}) -> Node3D:
	for what in prepared["missing"]:
		_missing(what)
	for line in prepared["log"]:
		print(line)
	commit_textures(prepared["textures"], texture_cache)
	var root = prepared["root"]
	if root == null:
		return null
	return _commit_node(root, texture_cache)

## `texture_cache` as prepare_object's `known_textures`: key -> `{"four_cc",
## "alpha"}` (a copy), never the Texture2D. Main thread, like the cache.
static func snapshot_textures(texture_cache: Dictionary) -> Dictionary:
	var known := {}
	for key in texture_cache:
		var entry: Dictionary = texture_cache[key]
		known[key] = {"four_cc": entry["four_cc"], "alpha": (entry.get("alpha", {}) as Dictionary).duplicate()}
	return known

## Puts what a prepare decoded into `texture_cache`, on the main thread: an
## ImageTexture for each Image the cache does not hold yet -- a texture
## another commit uploaded first is kept, not replaced -- and every alpha
## statistic the prepare measured, so none is measured twice.
static func commit_textures(textures: Dictionary, texture_cache: Dictionary) -> void:
	for key in textures:
		var decoded: Dictionary = textures[key]
		if texture_cache.has(key):
			var entry: Dictionary = texture_cache[key]
			if not entry.has("alpha"):
				entry["alpha"] = {}
			for stat in decoded["alpha"]:
				entry["alpha"][stat] = decoded["alpha"][stat]
			continue
		var image: Image = decoded["image"]
		if image == null:
			continue
		var texture := ImageTexture.create_from_image(image)
		if texture == null:
			continue
		texture_cache[key] = {"texture": texture,
			"four_cc": decoded["four_cc"], "alpha": (decoded["alpha"] as Dictionary).duplicate()}

## One node of the object: a `.cpd` compound (_prepare_compound) or a `.bsr`
## (below), described as data. Null, with what _missing would have said in
## prepared["missing"], where load_object returned null.
static func _prepare_node(archive: Pk2Reader, path: String, known: Dictionary, prepared: Dictionary) -> Variant:
	if path.to_lower().ends_with(".cpd"):
		return _prepare_compound(archive, path, known, prepared)

	var missing: Array = prepared["missing"]
	var bsr_path := path
	var bsr_entry := find_file(archive, bsr_path)
	if bsr_entry == null:
		missing.append("%s not found in archive" % bsr_path)
		return null
	var bsr_data := archive.read_file(bsr_entry)
	var obj := BsrReader.parse(bsr_data)
	if obj == null:
		return null

	var node := {"kind": "bsr", "name": obj.object_name, "pieces": []}

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

	var material := _read_material(archive, obj.material_path, missing) if obj.material_path != "" else null

	var loaded_count := 0
	for i in range(mesh_paths.size()):
		var entry := find_file(archive, mesh_paths[i])
		if entry == null:
			missing.append("%s not found in archive" % mesh_paths[i])
			continue
		var bms_data := archive.read_file(entry)
		var mesh := BmsReader.parse(bms_data)
		if mesh == null:
			continue

		var arrays := BmsReader.to_arrays(mesh)
		var piece := {"name": mesh.mesh_name, "arrays": arrays, "faces": _piece_faces(arrays), "material": null}

		# Real static collision, a trimesh shape derived directly from the
		# real render mesh, the way World3D's own real terrain collision is
		# built -- added 2026-08-25 after a live render showed the default
		# player camera embedded inside a real building's geometry at spawn:
		# real placed scenery previously had no collision at all, so nothing
		# (camera spring arm, player movement) could ever be blocked by a
		# wall, roof, or any other real object.
		#
		# A real .bms may also carry its own real navigation mesh (see
		# BmsReader.parse_collision) -- the real walkable surface the client
		# itself uses, and the real reason real staircases are climbable in
		# the real game. Driving Godot collision from it was tried and
		# **reverted 2026-09-06**: in-world the player lands on the surface
		# and then cannot move along it at all (six simultaneous slide
		# collisions against the ramp's own face, zero displacement). See
		# docs/WORLD_ISSUES.md's sixty-third round. The parsing, the
		# geometry helpers and their tests are kept, because the format work
		# is sound and independently verified -- it is only the "make it a
		# physics surface" step that is wrong, and the real client does not
		# do that either: it walks the cell/edge graph directly.
		#
		# Skipped for meshes with no real geometry (create_trimesh_shape on
		# an empty ArrayMesh is a needless real physics-body cost for
		# nothing) -- decided by the commit, which uploads the surface
		# (_commit_node); the faces the shape is built from are the prepare's.

		if material != null and material.layers.size() > 0:
			var layer_idx := _find_layer_by_name(material.layers, mesh.material_name)
			if layer_idx == -1:
				layer_idx = i if material.layers.size() == mesh_paths.size() else 0
			piece["material"] = _prepare_material(archive, obj.material_path, material.layers[layer_idx], known, prepared)

		(node["pieces"] as Array).append(piece)
		loaded_count += 1

	if loaded_count == 0 and not mesh_paths.is_empty():
		missing.append("%s: none of its %d mesh piece(s) could be loaded" % [bsr_path, mesh_paths.size()])
		return null

	return node

## The collision faces of one piece's surface, as `create_trimesh_shape()`
## read them back out of the uploaded ArrayMesh until round 566 -- every
## index's vertex, in index order, snapped to 0.0001: the list
## MapmTerrainBuilder.surface_faces builds for the terrain, whose equality
## with the engine's is measured in mapm_terrain_builder_test.gd (round 565)
## and, for a `.bms` piece, in object_loader_test.gd. It matches Godot
## 4.2's own code (read, round 566, from the 4.2-stable sources:
## `Mesh::generate_triangle_mesh` copies `vr[index]` for every index of an
## indexed triangle surface, `TriangleMesh::create` snaps each corner to
## 0.0001 and skips no triangle, `TriangleMesh::get_faces` rebuilds them from
## the snapped corners). Null -- the commit then reads the mesh back as
## before -- for the two shapes that code handles differently and a `.bms`
## is not expected to have: a surface with no index array (the engine reads
## the vertices as the triangle list) and an index outside the vertex array.
static func _piece_faces(arrays: Array) -> Variant:
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if indices.is_empty():
		return null
	var count := positions.size()
	for index in indices:
		if index < 0 or index >= count:
			return null
	return MapmTerrainBuilder.surface_faces([{"arrays": arrays}])

## Builds one node description on the main thread: a compound's root and its
## sub-objects, or a `.bsr`'s root with a MeshInstance3D per piece -- its
## ArrayMesh uploaded from the prepared arrays, a StaticBody3D with the
## trimesh shape when the surface uploaded, and its material.
static func _commit_node(node: Dictionary, texture_cache: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = node["name"]
	if node["kind"] == "cpd":
		for child in node["children"]:
			root.add_child(_commit_node(child, texture_cache))
		return root
	for piece in node["pieces"]:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = piece["name"]
		var array_mesh := BmsReader.mesh_from_arrays(piece["arrays"])
		mesh_instance.mesh = array_mesh
		# The collision load_object has built since 2026-08-25 -- see the
		# prepare's comment in _prepare_node for why it exists and why the
		# object's own navigation mesh is not used instead.
		if array_mesh.get_surface_count() > 0:
			var body := StaticBody3D.new()
			var shape := CollisionShape3D.new()
			shape.shape = _trimesh_shape(piece["faces"], array_mesh)
			body.add_child(shape)
			mesh_instance.add_child(body)
		if piece["material"] != null:
			var godot_material := _commit_material(piece["material"], texture_cache)
			if godot_material != null:
				mesh_instance.material_override = godot_material
		root.add_child(mesh_instance)
	return root

## The piece's trimesh from the prepared faces -- `create_trimesh_shape()`'s
## shape without reading the mesh back (Mesh::create_trimesh_shape, 4.2:
## `set_faces` on a new ConcavePolygonShape3D, or null when there are no
## faces) -- or, where the prepare left none (_piece_faces), the old readback.
static func _trimesh_shape(faces: Variant, array_mesh: ArrayMesh) -> Shape3D:
	if faces == null:
		return array_mesh.create_trimesh_shape()
	var face_list: PackedVector3Array = faces
	if face_list.is_empty():
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(face_list)
	return shape

## How far a real object navigation mesh's own blocking edges are extruded
## upward into wall collision.
##
## This is a project choice, not recovered data, for the same real reason
## World3D.NAVMESH_WALL_HEIGHT is: the real client tests a navigation edge as
## a 2D line rather than as geometry, so nothing in the real format gives a
## wall a height. Matches NAVMESH_WALL_HEIGHT so terrain and object walls
## behave alike.
const OBJECT_NAVMESH_WALL_HEIGHT := 40.0

## Builds collision from a real object navigation mesh: the real navigable
## cells as the walkable surface, plus the real blocking edges extruded into
## walls.
##
## **Not currently called** -- see load_object's own comment and
## docs/WORLD_ISSUES.md's sixty-third round. Driving Godot collision from
## this data was tried and reverted: in-world the player lands on the surface
## and then cannot move along it, and the two-sided shape a mirrored world
## transform forces is what pins it. Kept, with its tests, because the format
## work underneath is sound and independently verified, and because the real
## fix is to walk the real cell/edge graph rather than to hand it to the
## physics engine at all.
static func _add_object_navmesh_collision(
	mesh_instance: MeshInstance3D, collision: BmsReader.CollisionMesh
) -> void:
	var faces := BmsCollision.surface_triangles(collision)
	faces.append_array(BmsCollision.build_wall_triangles(collision, OBJECT_NAVMESH_WALL_HEIGHT))
	if faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# Godot's ConcavePolygonShape3D is one-sided by default, and one-sided is
	# not usable here: real placed objects sit under the world's mirrored
	# transform (see docs/WORLD_ISSUES.md's sixty-first round), which flips
	# which face is front, so a fixed winding holds the player up in isolation
	# and drops them through in-world.
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
##
## Prepared as data since round 566 (_prepare_node recurses once per
## sub-object; _commit_node builds the tree), with what it would report in
## prepared["missing"].
static func _prepare_compound(archive: Pk2Reader, cpd_path: String, known: Dictionary, prepared: Dictionary) -> Variant:
	var missing: Array = prepared["missing"]
	var cpd_entry := find_file(archive, cpd_path)
	if cpd_entry == null:
		missing.append("%s not found in archive" % cpd_path)
		return null
	var compound := CpdReader.parse(archive.read_file(cpd_entry))
	if compound == null:
		return null

	var node := {"kind": "cpd", "name": compound.name, "children": []}

	var loaded_count := 0
	for sub_path in compound.bsr_paths:
		var child = _prepare_node(archive, sub_path, known, prepared)
		if child == null:
			continue
		(node["children"] as Array).append(child)
		loaded_count += 1

	if loaded_count == 0:
		missing.append("%s: none of its %d real compound piece(s) could be loaded" % [cpd_path, compound.bsr_paths.size()])
		return null

	return node

## Loads and parses the .bmt at path within archive. Returns null (and
## pushes an error) on failure.
static func load_material(archive: Pk2Reader, bmt_path: String) -> BmtReader.ParsedMaterial:
	var missing: Array = []
	var material := _read_material(archive, bmt_path, missing)
	for what in missing:
		_missing(what)
	return material

## load_material for a prepare (round 566): a missing file goes in `missing`
## for the commit to report, not to _missing.
static func _read_material(archive: Pk2Reader, bmt_path: String, missing: Array) -> BmtReader.ParsedMaterial:
	var entry := find_file(archive, bmt_path)
	if entry == null:
		missing.append("%s not found in archive" % bmt_path)
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
## **DXT2 added 2026-09-08.** DdjReader decodes DXT2 as DXT3 -- the two are
## bit-identical block formats, differing only in whether colour is
## premultiplied by alpha -- but this list did not say so, so any texture
## whose real fourCC is literally `DXT2` was drawn opaque no matter what its
## alpha held. Found by reporting every texture about to be drawn opaque
## despite carrying transparency (SRREVAMP_QA_MATS): real
## `c_swamp_tree02_01.ddj` is DXT2 with **75.5%** of its texels below
## opaque, which is a leaf card rendered as a solid slab -- exactly the
## black cards a real playtest reported standing in the fields.
const _ALPHA_FOURCCS := ["DXT1", "DXT2", "DXT3", "DXT5"]

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
	# The ambient colour, for the reason build_godot_material gives.
	mat.set_shader_parameter("albedo", layer.ambient)
	mat.set_shader_parameter("albedo_texture", tex)
	mat.set_shader_parameter("alpha_scissor", FOLIAGE_ALPHA_SCISSOR)
	return mat

## `texture_cache`: see load_object. Only a texture that decoded is
## remembered, under its resolved path lower-cased (as find_file compares
## names); a miss reports and is retried next time, as before.
##
## Since round 566 the same two halves as load_object, back to back on the
## caller's thread -- SkinnedBsrAssembler builds its NPC and item pieces'
## materials through here: _prepare_material decodes the texture to an Image
## and classifies its alpha on that Image, _commit_material builds the
## material from the uploaded texture.
static func build_godot_material(archive: Pk2Reader, bmt_path: String, layer: BmtReader.Layer, texture_cache: Dictionary = {}) -> Material:
	var prepared := {"textures": {}, "missing": [], "log": []}
	var plan := _prepare_material(archive, bmt_path, layer, snapshot_textures(texture_cache), prepared)
	for what in prepared["missing"]:
		_missing(what)
	for line in prepared["log"]:
		print(line)
	commit_textures(prepared["textures"], texture_cache)
	return _commit_material(plan, texture_cache)

## The prepare half of a layer's material (round 566): its texture resolved
## and -- unless `known` says the commit's cache holds it -- decoded to an
## Image into prepared["textures"], and whether the layer is an alpha
## cutout, decided on that Image. Returns the plan _commit_material builds
## from: `{"layer", "texture_key", "cutout"}`, the key "" for a layer drawn
## without a texture (none named, not found, not decodable -- exactly the
## cases the one-piece build_godot_material returned its colours-only
## material for).
static func _prepare_material(archive: Pk2Reader, bmt_path: String, layer: BmtReader.Layer, known: Dictionary, prepared: Dictionary) -> Dictionary:
	var plan := {"layer": layer, "texture_key": "", "cutout": false}
	if layer.texture_path == "":
		return plan

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
	var cache_key := tex_path.to_lower()
	var textures: Dictionary = prepared["textures"]
	var decoded: Dictionary
	if textures.has(cache_key):
		decoded = textures[cache_key]
	elif known.has(cache_key):
		# Uploaded already: named, not decoded again. Its measured
		# statistics come with it; one it lacks is measured from the file
		# (_alpha_stat).
		decoded = {"image": null, "four_cc": known[cache_key]["four_cc"],
			"alpha": (known[cache_key]["alpha"] as Dictionary).duplicate()}
		textures[cache_key] = decoded
	else:
		decoded = _decode_texture(archive, tex_path, bmt_path, prepared["missing"])
		if decoded.is_empty():
			return plan
		textures[cache_key] = decoded
	plan["texture_key"] = cache_key
	var four_cc: String = decoded["four_cc"]

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
	# The material itself says whether this layer is an alpha layer --
	# see LAYER_FLAG_ALPHA. Everything below it is the older
	# guess-from-the-pixels path, kept only for layers whose flag word
	# does not look like a real flag word. Since round 566 the pixels are
	# the decoded Image's, not a readback of the uploaded texture
	# (_alpha_stat): the same rules and thresholds on the same texels.
	var needs_cutout := false
	if layer.unknown & LAYER_FLAG_MASK != 0:
		needs_cutout = layer.unknown & LAYER_FLAG_ALPHA != 0
	elif _ALPHA_FOURCCS.has(four_cc):
		if four_cc == "DXT1":
			needs_cutout = float(_alpha_stat(decoded, "fraction", archive, tex_path, bmt_path, prepared)) >= _DXT1_CUTOUT_MIN_ALPHA_FRACTION
		else:
			needs_cutout = bool(_alpha_stat(decoded, "variance", archive, tex_path, bmt_path, prepared))
	elif four_cc == "":
		needs_cutout = bool(_alpha_stat(decoded, "binary_cutout", archive, tex_path, bmt_path, prepared))
	# Says so whenever a texture that plainly carries transparency is
	# nonetheless about to be drawn opaque, which is what a leaf card
	# rendering as a solid black rectangle looks like from here.
	# Gated so an ordinary run costs nothing.
	# Surfaces the case worth a human look: a texture that is heavily
	# transparent while its own layer flag says the layer is solid.
	# Some disagreement is expected and correct -- a gloss ramp is
	# mostly non-opaque and rightly not a cutout -- so the bar is set
	# well above that. Gated, so an ordinary run costs nothing.
	if not needs_cutout and OS.get_environment("SRREVAMP_QA_MATS") != "":
		var fraction := float(_alpha_stat(decoded, "fraction", archive, tex_path, bmt_path, prepared))
		if fraction > _QA_MATS_REPORT_MIN_ALPHA_FRACTION:
			(prepared["log"] as Array).append("QA MAT: %s (%s, %s) is %.1f%% non-opaque, flags 0x%04x, no cutout" % [
				layer.layer_name, tex_path.get_file(), four_cc,
				fraction * 100.0, layer.unknown])
	plan["cutout"] = needs_cutout
	return plan

## The commit half of a layer's material, on the main thread: the
## StandardMaterial3D the layer's colours make, textured from
## `texture_cache` (commit_textures has put the prepare's upload there), or
## the cutout foliage material when the prepare classified the layer so.
static func _commit_material(plan: Dictionary, texture_cache: Dictionary) -> Material:
	var layer: BmtReader.Layer = plan["layer"]
	var mat := StandardMaterial3D.new()
	mat.resource_name = layer.layer_name
	# The layer's colours are a D3DMATERIAL9 -- ambient, diffuse, specular,
	# emissive, power, in that order -- and the fixed-function pipeline
	# multiplies the *ambient* light by the ambient colour and only the
	# directional light by the diffuse. This used to set the albedo from
	# the diffuse, which is the same 0.59 as the ambient on every Jangan
	# layer measured and so never showed -- until Alexandria, where 24 of
	# the houses' 40 layers carry diffuse 0.14 against ambient 0.59 and
	# every wall came out black (docs/WORLD_ISSUES.md, round 136). The
	# ambient is the term a mostly-ambient scene is lit by. What this still
	# gets wrong: a StandardMaterial3D scales the sun by the same colour, so
	# a sunlit face of such a layer draws brighter here than in the original
	# by diffuse/ambient; an exact split needs a shader's light() function.
	mat.albedo_color = layer.ambient

	var key: String = plan["texture_key"]
	if key == "" or not texture_cache.has(key):
		return mat
	var godot_tex: Texture2D = texture_cache[key]["texture"]
	if godot_tex == null:
		return mat
	mat.albedo_texture = godot_tex
	if plan["cutout"]:
		# Not a StandardMaterial3D: a real double-sided card has to keep
		# its authored normal on both faces to light the way the real
		# client lights it, which StandardMaterial3D cannot express.
		# See foliage.gdshader.
		return _build_foliage_material(layer, godot_tex)
	return mat

## A texture read and decoded for a prepare: `{"image", "four_cc", "alpha":
## {}}`, or empty -- nothing to draw with, as when the one-piece loader's
## ImageTexture came out null -- with a file that is not there reported in
## `missing`. An Image the decoder could not fill (Image.create_from_data
## leaves it empty on a size mismatch) is refused here, where the old
## `ImageTexture.create_from_image` refused it, so it is never cached --
## without a line of this function's own, where create_from_image printed
## the engine's "Invalid image" error (round 566's review; the material comes
## out the same, untextured, only the log differs).
static func _decode_texture(archive: Pk2Reader, tex_path: String, bmt_path: String, missing: Array) -> Dictionary:
	var tex_entry := find_file(archive, tex_path)
	if tex_entry == null:
		missing.append("texture %s (referenced by %s) not found in archive" % [tex_path, bmt_path])
		return {}
	var parsed_tex := DdjReader.parse(archive.read_file(tex_entry))
	if parsed_tex == null:
		return {}
	var image := DdjReader.to_image(parsed_tex)
	if image == null or image.is_empty():
		return {}
	return {"image": image, "four_cc": parsed_tex.four_cc, "alpha": {}}

## One alpha statistic of a decoded texture -- `binary_cutout`
## (_alpha_is_binary_cutout), `variance` (_has_real_alpha_variance) or
## `fraction` (_real_alpha_fraction) -- measured on its decoded Image once
## and remembered in `decoded["alpha"]`, which commit_textures carries into
## the texture cache, so a texture is measured once per world. Until round
## 566 each probe read the uploaded texture back (`Texture2D.get_image()`,
## RenderingServer.texture_2d_get: a readback from the GPU on the GL
## renderer) on every material that consulted it, which a WorkerThreadPool
## task may not do and which the decoded Image makes unnecessary: the probes
## scan the texels that Image was uploaded from. A texture the cache already
## holds but whose statistic was never measured is read and decoded again
## from the archive for it (the layer flag decides almost every real layer,
## LAYER_FLAG_MASK, so this is rare), and an undecodable one measures as
## the probes' own "no" (false, 0.0).
##
## SRREVAMP_QA_ALPHA_LOG=1 logs every consult -- `QA ALPHA: <file> (<fourCC>)
## <stat> <value> -- from the decoded Image | from a statistic measured
## earlier` -- the benchmark's count of alpha probes in the load path, all
## of them on Images (client/tools/README.md, "Load benchmark").
static func _alpha_stat(decoded: Dictionary, stat: String, archive: Pk2Reader, tex_path: String, bmt_path: String, prepared: Dictionary) -> Variant:
	var alpha: Dictionary = decoded["alpha"]
	var source := "a statistic measured earlier"
	if not alpha.has(stat):
		var image: Image = decoded["image"]
		if image == null:
			var again := _decode_texture(archive, tex_path, bmt_path, [])
			if not again.is_empty():
				image = again["image"]
				decoded["image"] = image
		match stat:
			"binary_cutout":
				alpha[stat] = _alpha_is_binary_cutout(image)
			"variance":
				alpha[stat] = _has_real_alpha_variance(image)
			_:
				alpha[stat] = _real_alpha_fraction(image)
		source = "the decoded Image"
	if OS.get_environment("SRREVAMP_QA_ALPHA_LOG") != "":
		var value = alpha[stat]
		(prepared["log"] as Array).append("QA ALPHA: %s (%s) %s %s -- from %s" % [
			tex_path.get_file(), decoded["four_cc"] if decoded["four_cc"] != "" else "uncompressed", stat,
			("%.4f" % value) if value is float else str(value), source])
	return alpha[stat]

## Bit 0 of a real .bmt layer's own flag word: **this layer is an alpha
## layer**, i.e. its texture's alpha is a cutout mask to be honoured rather
## than ignored.
##
## The field was recorded in BMT_FORMAT.md as "unconfirmed meaning
## (observed values 64, 321, 832, 833 -- not obviously a flags bitmask)".
## Written in hex those are 0x040, 0x141, 0x340, 0x341, which is plainly a
## bitmask: bit 6 always set, bits 8/9 varying, and bit 0 varying
## independently of both.
##
## Bit 0 separates real alpha layers from real solid ones with no
## exceptions across every real material checked:
##
## | layer | flag | measured alpha |
## |---|---|---|
## | `tre_willow02_leaf01`/`_leaf02` | 0x341 | 79% below opaque |
## | `c_swamp_tree02_01`/`_02` | 0x341 | 75.5% |
## | `tre_tree02_01` (leaf card) | 0x341 | 68,299 texels transparent |
## | `tre_dry02` | 0x341 | 39,749 transparent |
## | `CJ_w_alpha` (a gate's alpha mesh) | 0x341 | -- |
## | `CJ_pal_bigdoor_roof02_al`/`roof03_al` | 0x341 | -- |
## | `tre_willow02_will01` (branches) | 0x340 | solid |
## | `tre_tree02_02`/`_03` (bark) | 0x140 | solid |
## | `blade_14` (a graded gloss ramp, **not** a cutout) | 0x340 | 97.8% *partial* |
## | `CJ_w_wall01`..`05`, `CJ_w_stair`, `cj_pal_bigdoor_wall01` | 0x140 | solid |
##
## The authored naming corroborates it independently: every real layer
## whose name ends in `_al` -- the artists' own abbreviation for alpha --
## has bit 0 set, and no solid layer does. It also draws the line the
## pixels cannot: `blade_14` is 97.8% non-opaque yet is not an alpha
## layer, because that alpha is a gloss ramp rather than a mask.
##
## **Not yet confirmed against the client binary.** The correlation is
## across ~25 real layers in four unrelated real materials with zero
## contradictions, plus the naming convention, which is why it is used --
## but reading the flag out of the real material loader would settle it,
## and that is worth doing.
const LAYER_FLAG_ALPHA := 0x1

## Bit 6 is set in every real flag word observed, so a layer whose word has
## it is one this project knows how to read. A layer whose word does not
## look like a real flag word at all falls back to inspecting the texture,
## rather than being silently treated as solid.
const LAYER_FLAG_MASK := 0x40

## How transparent a texture has to be before SRREVAMP_QA_MATS bothers
## reporting that it is being drawn solid.
const _QA_MATS_REPORT_MIN_ALPHA_FRACTION := 0.20

## Is an **uncompressed** texture's alpha a cutout mask rather than a
## graded blend?
##
## Uncompressed real textures carry a full 8-bit alpha channel, so unlike
## the block formats their fourCC says nothing at all about intent -- the
## same channel holds a leaf card's punch-out mask and a blade's gloss
## ramp. Treating every one of them as cutout would chop up real weapons;
## treating none of them as cutout is what this project was doing, and it
## drew real foliage cards as solid slabs.
##
## Real measurements separate the two with no overlap. A real
## `grs_weed07.ddj` is **7,600 opaque, 57,936 fully transparent, 0
## partial** -- a perfectly binary mask. A real `blade_14.ddj` is **1,459
## opaque, 0 fully transparent, 64,077 partial** -- entirely graded, with
## no punched-out texels at all. A real `shield_16.ddj` sits at 27,984 /
## 5,116 / 32,436, graded despite having some transparent texels. So a
## cutout is recognised by having a real share of *fully* transparent
## texels **and** essentially no partial ones, which admits the weed and
## rejects both the blade and the shield by wide margins.
##
## Measured on the decoded Image since round 566 (_alpha_stat), not on a
## `Texture2D.get_image()` readback of the uploaded texture; a copy is
## decompressed, so the Image the texture is uploaded from stays as it was.
static func _alpha_is_binary_cutout(source: Image) -> bool:
	if source == null:
		return false
	var image := source.duplicate() as Image
	if image.is_compressed() and image.decompress() != OK:
		return false
	if image.get_format() != Image.FORMAT_RGBA8:
		return false
	var data := image.get_data()
	var transparent := 0
	var partial := 0
	var total := 0
	var i := 3
	while i < data.size():
		if data[i] <= _ALPHA_TRANSPARENT_MAX:
			transparent += 1
		elif data[i] < _ALPHA_OPAQUE_MIN:
			partial += 1
		total += 1
		i += 4
	if total == 0:
		return false
	var opaque := total - transparent - partial
	var transparent_fraction := float(transparent) / float(total)
	var partial_fraction := float(partial) / float(total)
	var opaque_fraction := float(opaque) / float(total)
	# A cutout has to leave something behind once it is cut. A texture with
	# no opaque texels at all is either degenerate or a fully-blended
	# effect -- a real waterfall's own textures are 100% non-opaque -- and
	# neither is a card to punch holes in.
	return transparent_fraction >= _UNCOMPRESSED_CUTOUT_MIN_TRANSPARENT \
		and partial_fraction <= _UNCOMPRESSED_CUTOUT_MAX_PARTIAL \
		and opaque_fraction >= _UNCOMPRESSED_CUTOUT_MIN_OPAQUE

## Alpha byte at or below which a texel counts as fully punched out, and at
## or above which it counts as fully opaque. Anything between the two is a
## graded texel, which is what distinguishes a blend map from a cutout mask.
const _ALPHA_TRANSPARENT_MAX := 5
const _ALPHA_OPAQUE_MIN := 250

## Thresholds for _alpha_is_binary_cutout. The measured real textures are
## nowhere near either boundary -- the weed is 88.4% transparent with 0%
## partial, the blade 0% transparent with 97.8% partial -- so these sit in
## a wide empty gap rather than being tuned to a sample.
const _UNCOMPRESSED_CUTOUT_MIN_TRANSPARENT := 0.05
const _UNCOMPRESSED_CUTOUT_MAX_PARTIAL := 0.01
## ...and it must keep a real share of solid texels: the measured weed card
## is 11.6% opaque, while a fully-blended effect texture is 0%.
const _UNCOMPRESSED_CUTOUT_MIN_OPAQUE := 0.01

## Decodes texture's real pixel data and returns true only if at least one
## real texel's alpha is meaningfully below fully opaque -- see
## build_godot_material's own doc comment for why format alone
## (_ALPHA_FOURCCS) isn't a reliable signal that a real texture actually
## needs cutout transparency. 250/255 (not a stricter 255) as the opaque
## threshold tolerates real DXT compression's own lossy rounding on a
## genuinely fully-opaque real source image. The decoded Image since round
## 566 (see _alpha_is_binary_cutout); only a compressed one is copied, to
## decompress, as before.
static func _has_real_alpha_variance(source: Image) -> bool:
	var image := source
	if image == null:
		return false
	if image.is_compressed():
		image = image.duplicate() as Image
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
## The decoded Image since round 566 (see _alpha_is_binary_cutout).
static func _real_alpha_fraction(source: Image) -> float:
	if source == null:
		return 0.0
	var image := source.duplicate() as Image
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
		_missing("%s not found in archive" % bms_path)
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
