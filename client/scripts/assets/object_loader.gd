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
## Guards the static state (missing_count/missing_recent, _mod_shaders): the
## scenery prepare and, since round 661, the monster templates run loader
## functions on WorkerThreadPool tasks beside the main thread (round 661's
## review). Mutex is reentrant.
static var _static_lock := Mutex.new()

static func _missing(what: String) -> void:
	_static_lock.lock()
	missing_count += 1
	missing_recent.append(what)
	if missing_recent.size() > MISSING_RECENT_KEPT:
		missing_recent.pop_front()
	_static_lock.unlock()
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
	# The object's always-on particle effects (round 720): the entries of its
	# `ambient` mod set (AmbientParticles.ambient_entries, READ), kept on the
	# committed node as meta for the world to play where it chooses to.
	var ambient := AmbientParticles.ambient_entries(obj.particle_mods)
	if not ambient.is_empty():
		node["ambient"] = ambient

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
		# Round 774: a light-mapped piece (BmsReader.lightmap_path, READ) --
		# its second texture coordinates and its light map, decoded here.
		_prepare_lightmap(archive, bms_data, mesh, piece, known, prepared)
		# A skinned piece's bone palette, for MapAnimation (round 645) to bind
		# it to the object's skeleton when the object animates.
		if mesh.is_skinned():
			piece["bones"] = mesh.bone_names
			piece["object_space"] = mesh.object_space_vertices > 0

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
			# The draw rule's inputs from the object (round 625 and its
			# review): the env-map mod governing all its materials, this
			# material's MTRL mod, and the two-pass flag.
			piece["material"] = _prepare_material(archive, obj.material_path, material.layers[layer_idx], known, prepared,
				obj.env_map_flags, obj.mtrl_mod_for(layer_idx), obj.two_pass())
			# Its TEXANI mod (round 722, TexAni): the commit starts the material's
			# texture-coordinate animation.
			var texani := obj.texani_for(layer_idx)
			if not texani.is_empty():
				(piece["material"] as Dictionary)["texani"] = texani
			# Its MULTITEX / MULTITEXREV mod (round 786): the second texture
			# the commit puts on stage 1 (or 0, for a REV).
			var multitex := obj.multitex_for(layer_idx)
			if not multitex.is_empty():
				_prepare_multitex(archive, multitex, obj.material_path, piece["material"], known, prepared)

		(node["pieces"] as Array).append(piece)
		loaded_count += 1

	if loaded_count == 0 and not mesh_paths.is_empty():
		missing.append("%s: none of its %d mesh piece(s) could be loaded" % [bsr_path, mesh_paths.size()])
		return null

	# Round 645: a map object whose `.bsr` carries a skeleton and a
	# `default` type-0 clip moves, as retail plays it (MapAnimation).
	MapAnimation.prepare(archive, obj, node, missing)

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
	if node.has("ambient"):
		root.set_meta(AmbientParticles.META_ENTRIES, node["ambient"])
	if node["kind"] == "cpd":
		for child in node["children"]:
			root.add_child(_commit_node(child, texture_cache))
		return root
	# An animated object (round 645) binds its pieces to its skeleton before
	# any two-pass twin is made, so the twin takes the skin too.
	var animated: bool = node.has("anim")
	var bound: Array = []
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
			if godot_material != null and piece.has("lightmap_key"):
				_commit_lightmap(godot_material, texture_cache.get(piece["lightmap_key"], {}).get("texture"))
			if godot_material != null and (piece["material"] as Dictionary).has("multitex"):
				_commit_multitex(godot_material, piece["material"]["multitex"], texture_cache)
			if godot_material != null:
				mesh_instance.material_override = godot_material
				if (piece["material"] as Dictionary).has("texani"):
					TexAni.bind(godot_material, piece["material"]["texani"])
		root.add_child(mesh_instance)
		if animated:
			bound.append([mesh_instance, piece])
		else:
			add_front_pass(mesh_instance)
	if animated:
		MapAnimation.commit(root, node["anim"], bound)
		for pair in bound:
			add_front_pass(pair[0])
	return root

## Round 774: a light-mapped mesh's light map (READ, docs/protocol/
## dungeon.md "Light maps"). CPrimMesh's reader takes the file named after
## the vertex array (BmsReader.lightmap_path) and the record's second
## coordinates; the draw (FUN_00bf1250) puts the light map on stage 1. Here:
## the coordinates as the surface's UV2 and the light map decoded beside the
## material's texture, under its path lower-cased; the commit
## (_commit_lightmap) draws the piece with object.gdshader's LIGHTMAP
## variant. A light map not in the archive is reported and the piece drawn
## as before.
## OPENSRO_QA_NOLIGHTMAP=1 (round 774): no light maps, for the A/B.
static var _qa_no_lightmap := OS.get_environment("OPENSRO_QA_NOLIGHTMAP") != ""

static func _prepare_lightmap(archive: Pk2Reader, bms_data: PackedByteArray, mesh: BmsReader.ParsedMesh,
		piece: Dictionary, known: Dictionary, prepared: Dictionary) -> void:
	if _qa_no_lightmap:
		return
	var path := BmsReader.lightmap_path(bms_data)
	if path == "":
		return
	var uvs := BmsReader.lightmap_uvs(mesh)
	var arrays: Array = piece["arrays"]
	if uvs.size() != (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
		return
	var key := path.to_lower()
	var textures: Dictionary = prepared["textures"]
	if not textures.has(key):
		if known.has(key):
			textures[key] = {"image": null, "four_cc": known[key]["four_cc"], "alpha": (known[key]["alpha"] as Dictionary).duplicate()}
		else:
			var decoded := _decode_lightmap(archive, path, mesh.mesh_name, prepared["missing"])
			if decoded.is_empty():
				return
			textures[key] = decoded
	arrays[Mesh.ARRAY_TEX_UV2] = uvs
	piece["lightmap_key"] = key

## A light map decoded (round 774): as _decode_texture, but a DXT1 one stays
## DXT1 without the transparent-texel scan (DdjReader._dxt1_with_alpha):
## stage 1's alpha is disabled (READ, FUN_00bf1250), so only the colour is
## sampled, and a three-colour block's index 3 is black either way. MEASURED,
## the perf gate at the Dunhuang reeds without the native readers: the scan
## of every light map cost the entry about 1.5 s.
static func _decode_lightmap(archive: Pk2Reader, path: String, mesh_name: String, missing: Array) -> Dictionary:
	var entry := find_file(archive, path)
	if entry == null:
		missing.append("light map %s (of mesh %s) not found in archive" % [path, mesh_name])
		return {}
	var parsed := DdjReader.parse(archive.read_file(entry))
	if parsed == null:
		return {}
	var image: Image
	if parsed.four_cc == "DXT1":
		image = Image.create_from_data(parsed.width, parsed.height, parsed.mip_map_count > 1, Image.FORMAT_DXT1,
			parsed.dds.slice(4 + DdjReader.DDS_HEADER_SIZE))
	else:
		image = DdjReader.to_image(parsed)
	if image == null or image.is_empty():
		return {}
	return {"image": image, "four_cc": parsed.four_cc, "alpha": {}}

## Puts a light map on an object-shader material (round 774): the LIGHTMAP
## variant of its kind, READ (FUN_00bf1250): stage 0 MODULATE -- the
## material's 2X flag 0x1000 cleared (0xbf14a1) -- and stage 1 MODULATE2X
## (the object's +0x260, 5, set by ResourceMgr::FUN_00c32e50 at 0xc331a1)
## of the light map, both clamped; with no material texture stage 0 is
## SELECTARG2 (the lit colour) and stage 1 MODULATE. An MTRL mod's own
## material is left as it is (OURS: none of the light-mapped pieces
## MEASURED carries one).
static func _commit_lightmap(mat: Material, lightmap: Texture2D) -> void:
	var sm := mat as ShaderMaterial
	if lightmap == null or sm == null or sm.shader == null or not sm.shader.has_meta(OBJECT_SHADER_KIND_META):
		return
	var textured := sm.get_shader_parameter("albedo_texture") != null
	sm.shader = object_shader(String(sm.shader.get_meta(OBJECT_SHADER_KIND_META)), false, true)
	sm.set_shader_parameter("lightmap_texture", lightmap)
	sm.set_shader_parameter("lightmap_textured", textured)

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

## THE MATERIAL RULE (round 625): what the client itself does with a layer,
## READ from sro_client.exe rather than guessed from the texture's pixels.
##
## - The layer's flag word (BmtReader.Layer.unknown, the dword the .bmt
##   stores after Power) is read by `CPrimMtrl::FUN_00bf9270` into the
##   runtime material's +0x70. Every draw path of `CObjRendererVS`
##   (FUN_00bf0e20, FUN_00bf1250, FUN_00bf1840, FUN_00bf29a0, FUN_00bf3e00
##   ...) passes `material+0x70 | renderer flags` to `FUN_00c42a60`, which
##   sets the render states, and to `FUN_00c42b40` after the draw, which
##   undoes them:
##     flags & 0x1    -> D3DRS_CULLMODE = D3DCULL_NONE (restored to CCW)
##     flags & 0x200  -> D3DRS_ALPHATESTENABLE = TRUE, D3DRS_ALPHAREF = 0x80,
##                       unless flags & 0x20000000
##   and the renderer's begin (`FUN_00c42860`, CObjRendererVS slot 3) sets
##   D3DRS_ALPHAFUNC = D3DCMP_GREATEREQUAL. The FLAG WORD never blends: a
##   layer without 0x200 and without an MTRL mod is drawn opaque whatever
##   its texture's alpha holds. Blending comes from an MTRL mod (below) or
##   the object-fade path (FUN_00c428c0, a whole object fading).
## - So: LAYER_FLAG_ALPHA_TEST cuts the texture at alpha >= 128/255, and
##   LAYER_FLAG_TWO_SIDED draws both faces. The two are independent: 0x340
##   is an alpha-tested ONE-sided card (pine needles, bamboo leaves), 0x141
##   a two-sided solid one. Until this round bit 0 was read as "alpha" --
##   a correlation that held for the willows and broke on 44 tree models
##   whose 0x340 needle cards drew as solid slabs.
## - An environment-map mod on the object (BsrReader.ParsedObject.
##   env_map_flags, READ from `CRTModEnvMap::vslot_004`) ORs 0x60000000
##   into the flags -- the 0x20000000 that switches the material's own test
##   off -- and turns on its own test, ALPHAREF 1 / GREATEREQUAL, only when
##   its flag word has ENV_MAP_FLAG_ALPHA_TEST. Both happen before the
##   mod's material-index compare, so they govern EVERY material of the
##   object (round 625 review).
## - An MTRL mod on a material (mtrl_mod_for, READ from `CRTModMtrl::
##   vslot_004`) sets that material's own alpha test, blend, z-write and
##   cull, and ORs 0x10000000 so the flag word sets nothing.
## - Header flag bit 1 (two_pass) draws every material back faces then
##   front faces.
## - EQUIPMENT gets no rule of its own (review follow-up; round 626 read
##   it): items carry their own ENVMAP mods, word 1 of 1 at index
##   0xFFFFFFFF, and the object-wide env-map rule above spares their graded
##   gloss alpha from the 0x200 test (602 item files with flag word 1, no
##   test; 465 with 3, a test at 1). ProgEquipPow's override exists too, but
##   only for enhanced gear (FUN_00a5f3e0 -> slot 50, gated per slot).
const LAYER_FLAG_TWO_SIDED := 0x1
const LAYER_FLAG_ALPHA_TEST := 0x200
## D3DRS_ALPHAREF 0x80 against D3DCMP_GREATEREQUAL: a texel is kept when its
## alpha byte is at least 128. Godot's scissor discards below the
## threshold, so the threshold is 128/255. READ (FUN_00c42a60, FUN_00c42860).
const ALPHA_TEST_REF := 0x80
## CRTModEnvMap's own test: ALPHAREF 1, GREATEREQUAL, when bit 1 of the
## mod's flag word (IModData +0x1c) is set. READ.
const ENV_MAP_FLAG_ALPHA_TEST := 0x2
const ENV_MAP_ALPHA_REF := 1

## The object shaders (round 706): the original's object lighting
## (ObjectLight; the body is object.gdshaderinc), built at run time by
## object_shader (one per kind and fade, cached). One per cull
## mode (a compile-time render_mode): FOLIAGE_SHADER a two-sided layer (flag
## 0x1, READ round 625), FOLIAGE_SHADER_ONE_SIDED an alpha-tested one-sided
## layer (the .bms winding is reversed on load, BmsReader.to_arrays, so
## Godot's back-face cull is the client's CCW cull), OBJECT_SHADER a solid
## layer. The names are historical: before round 706 the solid layer was a
## StandardMaterial3D and the two foliage shaders lit with Godot's light.
static var _object_shaders := {}
static var FOLIAGE_SHADER: Shader = object_shader("two")
static var FOLIAGE_SHADER_ONE_SIDED: Shader = object_shader("one")
static var OBJECT_SHADER: Shader = object_shader("solid")
## The (cull, blend, zwrite) a generated MTRL-mod shader was built for, on
## the Shader (round 676): AppearFade asks _mod_shader for its fade twin.
const MOD_SHADER_KEY_META := "opensro_mod_shader_key"
## The kind an object shader was built for (object_shader).
const OBJECT_SHADER_KIND_META := "opensro_object_shader_kind"


## An object shader: `kind` "solid" (no alpha test, back faces culled), "one"
## (alpha-tested, back faces culled) or "two" (no cull); `fade` gives the twin
## a character fading into existence draws with (AppearFade, round 676):
## blended at the fade's alpha, depth_draw_always keeping the model's near
## faces in front of its far ones while it is translucent (OURS).
static func object_shader(kind: String, fade: bool = false, lightmap: bool = false, multitex: bool = false) -> Shader:
	var key := "%s/%s%s%s" % [kind, fade, "/lightmap" if lightmap else "", "/multitex" if multitex else ""]
	_static_lock.lock()
	var cached: Shader = _object_shaders.get(key)
	_static_lock.unlock()
	if cached != null:
		return cached
	var modes := "unshaded, " + ("cull_disabled" if kind == "two" else "cull_back")
	if fade:
		modes += ", blend_mix, depth_draw_always"
	var defs := ""
	if kind == "solid" and not fade:
		defs += "#define OBJECT_SOLID\n"
	if fade:
		defs += "#define APPEAR_FADE\n"
	if lightmap:
		defs += "#define LIGHTMAP\n"
	if multitex:
		defs += "#define MULTITEX\n"
	var sh := Shader.new()
	sh.code = "shader_type spatial;\n// An object layer, kind %s%s%s%s (ObjectLoader.object_shader, round 706).\nrender_mode %s;\n%s#include \"res://scripts/assets/object.gdshaderinc\"\n" % [
		kind, ", fading" if fade else "", ", light-mapped" if lightmap else "", ", two textures (MULTITEX)" if multitex else "", modes, defs]
	sh.set_meta(OBJECT_SHADER_KIND_META, kind)
	_static_lock.lock()
	if _object_shaders.has(key):
		sh = _object_shaders[key]
	else:
		_object_shaders[key] = sh
	_static_lock.unlock()
	return sh

## The shader a character's material is drawn with while it fades into
## existence (AppearFade, round 676), or null for one with no fade twin: an
## object shader's fade twin and a mod shader's `fade` twin.
static func appear_fade_shader(shader: Shader) -> Shader:
	if shader == null:
		return null
	if shader.has_meta(OBJECT_SHADER_KIND_META) and not shader.code.contains("APPEAR_FADE"):
		return object_shader(String(shader.get_meta(OBJECT_SHADER_KIND_META)), true)
	if shader.has_meta(MOD_SHADER_KEY_META):
		var k: Array = shader.get_meta(MOD_SHADER_KEY_META)
		return _mod_shader(String(k[0]), String(k[1]), bool(k[2]), true)
	return null

## Every MTRL mod shader made so far, not counting fade twins (AppearFade
## warms their twins while the world loads; round 676's review).
static func mod_shaders_made() -> Array[Shader]:
	var out: Array[Shader] = []
	_static_lock.lock()
	for key in _mod_shaders.keys():
		if not String(key).ends_with("/fade"):
			out.append(_mod_shaders[key])
	_static_lock.unlock()
	return out

## The scissor threshold of an alpha-tested layer: ALPHA_TEST_REF / 255.
## (The 0.5 it replaced drew the same texels; this is the client's number.)
const FOLIAGE_ALPHA_SCISSOR := float(ALPHA_TEST_REF) / 255.0

## How a layer is drawn, from its flag word and what the object says about
## it -- THE MATERIAL RULE above.
## - `env_map`: the object's env_map_flags (BsrReader.ParsedObject), -1
##   for none. An env-map mod governs EVERY material of its object (READ,
##   round 625 review: the OR and the test precede the index compare).
## - `mtrl`: the MTRL mod for this material (mtrl_mod_for), {} for none.
##   READ, CRTModMtrl::vslot_004: its own alpha test (ref and func), its
##   own blend (factors and stage-0 ops), z-write off, cull none -- and it
##   ORs 0x10000000, so the flag word's own states are not set at all.
## - `two_pass`: the object's header flag bit 1 -- every material drawn
##   back faces first, then front faces (READ, CObjRendererVS FUN_00bf5780).
## Returns {"alpha_ref": 0 for no test or the byte a texel must reach
## (with "alpha_func", a D3DCMPFUNC), "two_sided", "two_pass", "blend": ""
## for none or "mix" / "add" / "add_one" / "mul" / "d3d_<src>_<dest>" (the
## D3DBLEND pair's Godot counterpart), "zwrite", "color_op", "color_arg1",
## "color_arg2", "alpha_op", "alpha_arg1", "alpha_arg2" (D3DTOP / D3DTA;
## 0 when the default modulate applies)}.
static func layer_draw_rule(flags: int, env_map: int = -1, mtrl: Dictionary = {}, two_pass: bool = false) -> Dictionary:
	var rule := {"alpha_ref": 0, "alpha_func": D3DCMP_GREATEREQUAL, "two_sided": false, "two_pass": two_pass,
		"blend": "", "zwrite": true, "color_op": 0, "color_arg1": 0, "color_arg2": 0,
		"alpha_op": 0, "alpha_arg1": 0, "alpha_arg2": 0, "mtrl": not mtrl.is_empty(), "stage_ops": false,
		"src_blend": 0, "dest_blend": 0}
	if not mtrl.is_empty():
		if mtrl.get("alpha_test", false):
			rule["alpha_ref"] = int(mtrl["alpha_ref"])
			rule["alpha_func"] = int(mtrl["alpha_func"])
		rule["two_sided"] = mtrl.get("cull_none", false)
		rule["zwrite"] = not mtrl.get("zwrite_off", false)
		if mtrl.get("blend", false):
			rule["blend"] = blend_mode(int(mtrl["src_blend"]), int(mtrl["dest_blend"]))
			rule["src_blend"] = int(mtrl["src_blend"])
			rule["dest_blend"] = int(mtrl["dest_blend"])
			# All six stage bytes, zeros included: 0 is D3DTA_DIFFUSE, not
			# "unset" (READ: CRTModMtrl::vslot_004 sets the six stage-0
			# states from bytes +0x62..+0x67 only when it blends).
			rule["stage_ops"] = true
			for k in ["color_op", "color_arg1", "color_arg2", "alpha_op", "alpha_arg1", "alpha_arg2"]:
				rule[k] = int(mtrl[k])
	else:
		if flags & LAYER_FLAG_ALPHA_TEST != 0:
			rule["alpha_ref"] = ALPHA_TEST_REF
		if env_map >= 0:
			rule["alpha_ref"] = ENV_MAP_ALPHA_REF if env_map & ENV_MAP_FLAG_ALPHA_TEST != 0 else 0
		rule["two_sided"] = flags & LAYER_FLAG_TWO_SIDED != 0
	# A test that keeps everything is no test: ALWAYS, or GREATEREQUAL 0.
	if rule["alpha_func"] == D3DCMP_ALWAYS or (rule["alpha_func"] == D3DCMP_GREATEREQUAL and int(rule["alpha_ref"]) == 0):
		rule["alpha_ref"] = 0
		rule["alpha_func"] = D3DCMP_GREATEREQUAL
	if two_pass:
		# CW then CCW: both faces, whatever the layer says (READ).
		rule["two_sided"] = true
	return rule

## D3DCMPFUNC (d3d9types.h). An MTRL mod names any of them (census: 258
## GREATEREQUAL, 32 ALWAYS, 10 GREATER, 5 NOTEQUAL, 1 LESSEQUAL); the mod
## shader compares the alpha byte against the ref exactly as named.
const D3DCMP_NEVER := 1
const D3DCMP_LESS := 2
const D3DCMP_EQUAL := 3
const D3DCMP_LESSEQUAL := 4
const D3DCMP_GREATER := 5
const D3DCMP_NOTEQUAL := 6
const D3DCMP_GREATEREQUAL := 7
const D3DCMP_ALWAYS := 8

## D3DBLEND (d3d9types.h).
const D3DBLEND_ZERO := 1
const D3DBLEND_ONE := 2
const D3DBLEND_SRCCOLOR := 3
const D3DBLEND_INVSRCCOLOR := 4
const D3DBLEND_SRCALPHA := 5
const D3DBLEND_INVSRCALPHA := 6
const D3DBLEND_DESTALPHA := 7
const D3DBLEND_DESTCOLOR := 9
const D3DBLEND_INVDESTCOLOR := 10
const D3DBLEND_SRCALPHASAT := 11
const D3DBLEND_BOTHSRCALPHA := 12
const D3DBLEND_BOTHINVSRCALPHA := 13
const D3DBLEND_BLENDFACTOR := 14
const D3DBLEND_INVBLENDFACTOR := 15

## How each D3DBLEND pair an MTRL mod uses (all 18 in the census) is drawn
## with Godot 4.2's fixed blends -- GL Compatibility's, read from its
## source (rasterizer_scene_gles3.cpp): "mix" = SRC_ALPHA / ONE_MINUS_
## SRC_ALPHA, "add" = SRC_ALPHA / ONE (in the transparent pass), "mul" =
## DST_COLOR / ZERO -- by choosing what the shader writes as colour and
## alpha. `color`: 0 the stage colour, 1 the stage colour times itself
## (a SRCCOLOR source factor), 2 zero; `alpha`: 0 the stage alpha, 1 one,
## 2 one minus the stage alpha, 3 the stage alpha with the colour divided by
## it (so mix's C*a gives C). `kind`: "exact" (the same equation), "given"
## (exact under a stated condition: an unlit stage result for the SRCCOLOR
## sources; D3DRS_BLENDFACTOR = white, its D3D
## default -- the client sets it only in Map::FUN_00a1d790, a map pass,
## and whether that value is live when objects draw is OPEN; or destination
## alpha = 1, a back buffer without alpha -- INFERRED, the format was not
## traced), or "ours" (the nearest the three blends reach; the dropped term
## is named). Counts are the review's mtrl.tsv census of blended mods.
const BLEND_EMULATION := {
	"5/6": {"godot": "mix", "color": 0, "alpha": 0, "kind": "exact", "note": "SRCALPHA/INVSRCALPHA (348: leaves, water)"},
	"5/2": {"godot": "add", "color": 0, "alpha": 0, "kind": "exact", "note": "SRCALPHA/ONE (259)"},
	"2/2": {"godot": "add", "color": 0, "alpha": 1, "kind": "exact", "note": "ONE/ONE"},
	"9/1": {"godot": "mul", "color": 0, "alpha": 1, "kind": "exact", "note": "DESTCOLOR/ZERO"},
	"1/3": {"godot": "mul", "color": 0, "alpha": 1, "kind": "exact", "note": "ZERO/SRCCOLOR"},
	"12/2": {"godot": "mix", "color": 0, "alpha": 0, "kind": "exact", "note": "BOTHSRCALPHA: As / 1-As, the destination overridden (2)"},
	"13/6": {"godot": "mix", "color": 0, "alpha": 2, "kind": "exact", "note": "BOTHINVSRCALPHA: 1-As / As, the destination overridden (2)"},
	"3/6": {"godot": "mix", "color": 1, "alpha": 3, "kind": "given", "note": "SRCCOLOR/INVSRCALPHA: src*src + dst*(1-As) (8), exact only for an unlit stage result: a lit one (a DIFFUSE term) is squared before Godot's light, so it is drawn light*L*L, not (light*L)^2; colour clamps where src*src/As > 1"},
	"5/14": {"godot": "add", "color": 0, "alpha": 0, "kind": "given", "note": "SRCALPHA/BLENDFACTOR, factor white (6)"},
	"3/14": {"godot": "add", "color": 1, "alpha": 1, "kind": "given", "note": "SRCCOLOR/BLENDFACTOR, factor white: src*src + dst (10 cobwebs), and exact only for an unlit stage result: cobweb_b's MODULATE2X(DIFFUSE, TEXTURE) is lit, squared before Godot's light (light*L*L, not (light*L)^2)"},
	"15/15": {"godot": "mul", "color": 2, "alpha": 1, "kind": "given", "note": "INVBLENDFACTOR both, factor white: 0 (1, samarkand_potion_etc01)"},
	"5/7": {"godot": "add", "color": 0, "alpha": 0, "kind": "given", "note": "SRCALPHA/DESTALPHA, destination alpha 1 (11 pha_maze)"},
	"2/11": {"godot": "mix", "color": 0, "alpha": 1, "kind": "given", "note": "ONE/SRCALPHASAT: min(As, 1-Ad) = 0 at destination alpha 1 (1)"},
	"5/13": {"godot": "mix", "color": 0, "alpha": 0, "kind": "ours", "note": "SRCALPHA/BOTHINVSRCALPHA: D3D defines BOTHINVSRCALPHA only as a source factor; drawn as mix (50 shadows)"},
	"3/3": {"godot": "mul", "color": 0, "alpha": 1, "kind": "ours", "note": "SRCCOLOR/SRCCOLOR: src*src + dst*src, drawn dst*src -- the src*src term dropped (21 jinsi floors)"},
	"2/4": {"godot": "add", "color": 0, "alpha": 1, "kind": "ours", "note": "ONE/INVSRCCOLOR: src + dst*(1-src), drawn src + dst (5)"},
	"5/5": {"godot": "add", "color": 0, "alpha": 0, "kind": "ours", "note": "SRCALPHA/SRCALPHA: dst*As drawn as dst (3)"},
	"5/4": {"godot": "add", "color": 0, "alpha": 0, "kind": "ours", "note": "SRCALPHA/INVSRCCOLOR: dst*(1-src) drawn as dst (2)"},
	"2/3": {"godot": "add", "color": 0, "alpha": 1, "kind": "ours", "note": "ONE/SRCCOLOR: dst*src drawn as dst (1)"},
	"10/2": {"godot": "add", "color": 0, "alpha": 1, "kind": "ours", "note": "INVDESTCOLOR/ONE: src*(1-dst) drawn as src (1)"},
	"2/9": {"godot": "add", "color": 0, "alpha": 1, "kind": "ours", "note": "ONE/DESTCOLOR: dst*dst drawn as dst (1)"},
}

## The emulation for a D3DBLEND pair (BLEND_EMULATION); a pair outside the
## census falls back to mix, "ours".
static func blend_emulation(src: int, dest: int) -> Dictionary:
	var key := "%d/%d" % [src, dest]
	if BLEND_EMULATION.has(key):
		return BLEND_EMULATION[key]
	return {"godot": "mix", "color": 0, "alpha": 0, "kind": "ours", "note": "unmapped pair %s drawn as mix" % key}

## A name for the blend, for the rule and the census: the Godot blend it is
## drawn with for the common exact pairs ("mix", "add", "add_one", "mul"),
## "d3d_<src>_<dest>" for every other pair.
static func blend_mode(src: int, dest: int) -> String:
	if src == 5 and dest == 6:
		return "mix"
	if src == 5 and dest == 2:
		return "add"
	if src == 2 and dest == 2:
		return "add_one"
	if (src == 9 and dest == 1) or (src == 1 and dest == 3):
		return "mul"
	return "d3d_%d_%d" % [src, dest]

## The material an MTRL mod asks for: a shader built for its cull, Godot
## blend ("opaque" for a mod that tests but does not blend) and depth-write
## (compile-time render modes, so one per combination, cached), with the
## stage-0 ops, the alpha test and the blend emulation as uniforms. `cull`:
## "back", "front" or "disabled". Z-write on is depth_draw_always: a Godot
## transparent draw writes no depth otherwise, and D3D's ZWRITEENABLE does
## (72 tree models blend their leaves with the write on).
##
## Stage 0, READ vs OURS:
## - The six stage bytes are applied as the client sets them (READ,
##   CRTModMtrl::vslot_004), evaluated as d3d9 defines them (d3d9types.h):
##   D3DTOP 2 SELECTARG1, 3 SELECTARG2, 4 MODULATE, 5 MODULATE2X, 6
##   MODULATE4X, 7 ADD, 8 ADDSIGNED, 9 ADDSIGNED2X, 10 SUBTRACT, 20
##   MODULATEINVALPHA_ADDCOLOR (colour), 15 BLENDTEXTUREALPHAPM (alpha) --
##   every op the census's mods use (HANDLED_COLOR_OPS / HANDLED_ALPHA_OPS);
##   any other op is drawn as MODULATE, OURS, and stage_ops_handled says so.
##   D3DTA 0 DIFFUSE, 1 CURRENT (= DIFFUSE at stage 0), 2 TEXTURE, 3 TFACTOR,
##   4 SPECULAR, 5 TEMP, with the 0x20 ALPHAREPLICATE and 0x10 COMPLEMENT
##   modifiers (no census mod sets either). A mod that does not blend sets none of them, so the object
##   renderer's own stage 0 applies: MODULATE2X of TEXTURE and DIFFUSE (READ:
##   CObjRendererVS::vslot_024 / vslot_038 seed flag 0x1000, which
##   FUN_00c42a60 turns into COLOROP 5).
## - DIFFUSE is the lit vertex colour (READ, Shader\vertexshader0.c:
##   saturate(N.L) * c11 + c10). Its alpha is 1: c10.w and c11.w are 1.0 in
##   the renderer's uploads and oD0 saturates (READ). Since round 706 it is
##   computed as the original computes it, per vertex (ObjectLight: c10 =
##   object colour x the light's ambient, c11 = the layer's SECOND colour x
##   the light's diffuse), and the draw is unshaded: the stage result is
##   evaluated in full, value for value. Until then the part multiplying
##   DIFFUSE was drawn as ALBEDO = L x the layer's FIRST colour / 2 and lit
##   by Godot's sun, anchored to the old flag-word path. OURS: TFACTOR is
##   white (the mod's own colour is not passed yet).
## - The tone map: undone on an opaque or "mix" draw's colour (ObjectLight.
##   srr_obj_present), not on an adding or multiplying blend's (its source
##   is a factor on what is under it, not a colour shown) -- OURS.
## - The alpha test reads full-resolution alpha (mip 0), as
##   object.gdshaderinc does and for the same reason: a leaf card's
##   mipmapped alpha falls with distance and the canopy disappears (OURS,
##   the client tests the filtered alpha). The blend still uses the
##   filtered alpha.
static var _mod_shaders := {}

## The D3DTOPs the mod shader evaluates exactly (see above); the census's
## mods use colour ops 2, 4, 5, 6, 7, 8, 9, 20 and alpha ops 2-7, 15.
const HANDLED_COLOR_OPS := [2, 3, 4, 5, 6, 7, 8, 9, 10, 20]
const HANDLED_ALPHA_OPS := [2, 3, 4, 5, 6, 7, 8, 9, 10, 15]

## Whether a rule's stage-0 ops are all evaluated as d3d9 defines them;
## false means one is drawn as MODULATE (OURS).
static func stage_ops_handled(rule: Dictionary) -> bool:
	if not rule.get("stage_ops", false):
		return true
	return int(rule["color_op"]) in HANDLED_COLOR_OPS and int(rule["alpha_op"]) in HANDLED_ALPHA_OPS

## `fade` (round 676) gives the variant a character fading into existence is
## drawn with (AppearFade): the same draw, its alpha multiplied by the
## uniform `appear_alpha`, blended even where the mod is opaque, and writing
## depth (OURS). The world's shaders are built without it, unchanged; each
## keeps its key in MOD_SHADER_KEY_META so AppearFade can ask for its twin.
static func _mod_shader(cull: String, godot_blend: String, zwrite: bool, fade: bool = false) -> Shader:
	var key := "%s/%s/%s" % [cull, godot_blend, zwrite]
	if fade:
		key += "/fade"
	_static_lock.lock()
	var cached: Shader = _mod_shaders.get(key)
	_static_lock.unlock()
	if cached != null:
		return cached
	var opaque := godot_blend == "opaque"
	var modes := ["unshaded", "cull_" + cull]
	if not opaque:
		modes.append("blend_" + godot_blend)
		modes.append("depth_draw_always" if zwrite else "depth_draw_never")
	elif fade:
		modes.append("blend_mix")
		modes.append("depth_draw_always")
	# A blended pass is drawn after the world's fog pass, so it fogs itself
	# (round 702, WorldFog.SHADER_FN); an opaque one is fogged by the pass.
	var blended := not opaque or fade
	var alpha_line := "" if opaque else "ALPHA = clamp(out_a, 0.0, 1.0);"
	if fade:
		alpha_line = "ALPHA = appear_alpha;" if opaque else "ALPHA = clamp(out_a, 0.0, 1.0) * appear_alpha;"
	var shader := Shader.new()
	# One assignment: setting a Shader's code compiles it, so a second set
	# would compile the half-made code first (round 693).
	var code := """shader_type spatial;
render_mode %s;
// An MTRL mod's draw (ObjectLoader._mod_shader; READ from
// CRTModMtrl::vslot_004, OURS where ObjectLoader says so). Raw samples and
// a raw colour, decoded at the end where the output is linear (ShaderColour,
// round 693): the stage arithmetic is the client's gamma-space arithmetic in
// both renderers.
// `albedo` is set as a Color (BmtReader's layer diffuse, the second colour:
// c11's material term, round 706): read through srr_color (ShaderColour).
// DIFFUSE is the original's lit vertex colour (ObjectLight), computed per
// vertex; the draw is unshaded.
uniform vec4 albedo = vec4(1.0);
uniform sampler2D albedo_texture : filter_linear_mipmap, repeat_enable;
// The alpha test: the ref byte / 255 and its D3DCMPFUNC (0 = no test).
uniform float alpha_scissor = 0.0;
uniform int alpha_func = 0;
uniform int color_op = 5;
uniform int color_arg1 = 2;
uniform int color_arg2 = 0;
uniform int alpha_op = 2;
uniform int alpha_arg1 = 2;
uniform int alpha_arg2 = 0;
// The blend emulation (ObjectLoader.BLEND_EMULATION).
uniform int blend_color = 0;
uniform int blend_alpha = 0;
%s
// A MULTITEX mod's second texture on stage 1 (round 786; as the object
// shader's MULTITEX variant -- not named here: CrowdGpu.twin_code tells an
// object shader by its include's name): multitex_op -1 for none, 1 blended by
// its own alpha (BLENDTEXTUREALPHA), 0 by the factor's (BLENDFACTORALPHA).
uniform sampler2D multitex_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int multitex_op = -1;
uniform float multitex_factor = 0.0;
uniform bool multitex_rev = false;
%s
// A stage value split into the part that multiplies DIFFUSE (lit) and the
// part that does not (unlit): value = lit * DIFFUSE + unlit.
struct Split { vec3 lit; vec3 unlit; };

float aarg(int which, vec4 tex) {
	int base = which & 15;
	float v = 1.0;
	if (base == 2) v = tex.a;
	else if (base == 4 || base == 5) v = 0.0;
	return (which & 16) != 0 ? 1.0 - v : v;
}

// D3DTA: the register in the low 4 bits, then the modifiers -- 0x20
// ALPHAREPLICATE (the register's alpha in all three channels), then 0x10
// COMPLEMENT (one minus it). DIFFUSE's and TFACTOR's alpha are 1; TEMP
// reads 0 (d3d9 default); SPECULAR is 0 (the object shader writes no oD1).
Split carg(int which, vec4 tex) {
	int base = which & 15;
	Split s = Split(vec3(0.0), vec3(0.0));
	if ((which & 32) != 0) {
		s = Split(vec3(0.0), vec3(aarg(which & 15, tex)));
	} else if (base == 0 || base == 1) {
		s = Split(vec3(1.0), vec3(0.0));
	} else if (base == 2) {
		s = Split(vec3(0.0), tex.rgb);
	} else if (base == 3) {
		s = Split(vec3(0.0), vec3(1.0));
	}
	if ((which & 16) != 0) {
		s = Split(-s.lit, vec3(1.0) - s.unlit);
	}
	return s;
}

Split cop(int o, Split a, Split b, float a1_alpha) {
	if (o == 2) return a;
	if (o == 3) return b;
	if (o == 7) return Split(a.lit + b.lit, a.unlit + b.unlit);
	if (o == 8) return Split(a.lit + b.lit, a.unlit + b.unlit - vec3(0.5));
	if (o == 9) return Split((a.lit + b.lit) * 2.0, (a.unlit + b.unlit - vec3(0.5)) * 2.0);
	if (o == 10) return Split(a.lit - b.lit, a.unlit - b.unlit);
	// MODULATEINVALPHA_ADDCOLOR: arg1 + (1 - arg1.a) * arg2, with arg1.a
	// passed in (the census's one mod has arg1 = CURRENT, alpha 1).
	if (o == 20) return Split(a.lit + b.lit * (1.0 - a1_alpha), a.unlit + b.unlit * (1.0 - a1_alpha));
	float k = o == 5 ? 2.0 : (o == 6 ? 4.0 : 1.0);
	return Split((a.lit * b.unlit + a.unlit * b.lit + a.lit * b.lit) * k, a.unlit * b.unlit * k);
}


float aop(int o, float a, float b, float tex_a) {
	if (o == 2) return a;
	if (o == 3) return b;
	if (o == 5) return a * b * 2.0;
	if (o == 6) return a * b * 4.0;
	if (o == 7) return a + b;
	if (o == 8) return a + b - 0.5;
	if (o == 9) return (a + b - 0.5) * 2.0;
	if (o == 10) return a - b;
	// BLENDTEXTUREALPHAPM: arg1 + arg2 * (1 - texture alpha).
	if (o == 15) return a + b * (1.0 - tex_a);
	return a * b;
}

bool keep(float a) {
	if (alpha_func == 0) return true;
	float v = round(clamp(a, 0.0, 1.0) * 255.0);
	float r = round(alpha_scissor * 255.0);
	if (alpha_func == 1) return false;
	if (alpha_func == 2) return v < r;
	if (alpha_func == 3) return v == r;
	if (alpha_func == 4) return v <= r;
	if (alpha_func == 5) return v > r;
	if (alpha_func == 6) return v != r;
	if (alpha_func == 7) return v >= r;
	return true;
}

void fragment() {
	// A MULTITEXREV puts the mod's texture on stage 0 (round 786).
	vec4 tex = multitex_rev ? texture(multitex_texture, UV) : texture(albedo_texture, UV);
	vec4 tex0 = multitex_rev ? textureLod(multitex_texture, UV, 0.0) : textureLod(albedo_texture, UV, 0.0);
	if (!keep(clamp(aop(alpha_op, aarg(alpha_arg1, tex0), aarg(alpha_arg2, tex0), tex0.a), 0.0, 1.0))) {
		discard;
	}
	Split c = cop(color_op, carg(color_arg1, tex), carg(color_arg2, tex), aarg(color_arg1, tex));
	float a = clamp(aop(alpha_op, aarg(alpha_arg1, tex), aarg(alpha_arg2, tex), tex.a), 0.0, 1.0);
	vec3 lit = c.lit * srr_od0;
	vec3 stage = clamp(lit + c.unlit, vec3(0.0), vec3(1.0));
	// Stage 1 (round 786, READ CRTModMultiTex): the second texture over the
	// stage-0 colour by its alpha or the factor's; ALPHAOP DISABLE keeps
	// stage 0's alpha.
	if (multitex_op >= 0) {
		vec4 t1 = multitex_rev ? texture(albedo_texture, srr_uv1) : texture(multitex_texture, srr_uv1);
		stage = mix(stage, t1.rgb, multitex_op == 1 ? t1.a : multitex_factor);
	}
	if (blend_color == 1) {
		stage *= stage;
	} else if (blend_color == 2) {
		stage = vec3(0.0);
	}
	float out_a = a;
	if (blend_alpha == 1) out_a = 1.0;
	else if (blend_alpha == 2) out_a = 1.0 - a;
	else if (blend_alpha == 3) {
		float d = max(a, 1.0 / 255.0);
		stage /= d;
	}
	ALBEDO = %s;
	%s
	%s
	%s
}
""" % [", ".join(modes), TexAni.SHADER_UNIFORMS, "uniform float appear_alpha = 1.0;\n" if fade else "",
		# The tone map is undone on what is drawn over (opaque, mix): a
		# multiplying or adding blend's source is a factor, not a colour
		# shown (OURS, ObjectLight).
		"srr_obj_present(clamp(stage, vec3(0.0), vec3(1.0)))" if opaque or godot_blend == "mix" or fade else "clamp(stage, vec3(0.0), vec3(1.0))",
		alpha_line, ShaderColour.DECODE_ALBEDO, WorldFog.SHADER_FOG_LINE if blended else ""]
	# The helpers go before the first function (the stage arithmetic and the
	# vertex colour call them).
	shader.code = code.replace("\nstruct Split {", ShaderColour.DECODE_FN + ObjectLight.SHADER_FN + (WorldFog.SHADER_FN if blended else "")
		+ "\nvoid vertex() {\n\t" + ObjectLight.OD0_LINE + "\n\t" + TexAni.SHADER_LINE + "\n}\n" + "\nstruct Split {")
	shader.set_meta(MOD_SHADER_KEY_META, [cull, godot_blend, zwrite])
	_static_lock.lock()
	if _mod_shaders.has(key):
		shader = _mod_shaders[key] # another thread built it first: one shader per key
	else:
		_mod_shaders[key] = shader
	_static_lock.unlock()
	return shader

## The material for an MTRL mod's rule, and its second pass when the object
## draws back faces then front (two_pass). READ, CObjRendererVS::
## FUN_00bf5780: CULLMODE CW (back faces) for every material, then CCW.
##
## Godot 4.2 does not keep a material's next_pass after it in a
## transparent sort (rasterizer_scene_gles3.h: the sort is not stable), and
## a render_priority on the front pass (the material review follow-up) is
## global: every priority-1 pass drew after every priority-0 transparent
## surface in the scene, over a nearer aura or water (MEASURED, rounds
## 623-628 integration). So the front pass is not attached here: it rides
## on the back pass as metadata (FRONT_PASS_META), and add_front_pass puts
## it on a twin MeshInstance3D with a small sorting_offset, priority 0 --
## ordered after its own back pass by depth, and by depth against the rest.
const FRONT_PASS_META := "opensro_front_pass"
## Enough to order the twin after its back pass (the same AABB, so the same
## sort depth) and far below any real depth difference. OURS.
const FRONT_PASS_SORTING_OFFSET := 0.01

static func _build_mod_material(layer: BmtReader.Layer, tex: Texture2D, rule: Dictionary) -> ShaderMaterial:
	var cull := "disabled" if rule["two_sided"] and not rule["two_pass"] else "back"
	if rule["two_pass"]:
		cull = "front"
	var mat := _mod_pass(layer, tex, rule, cull)
	if rule["two_pass"]:
		mat.set_meta(FRONT_PASS_META, _mod_pass(layer, tex, rule, "back"))
	return mat

## The front-face twin of `mi` when its material carries a two-pass front
## pass (FRONT_PASS_META): the same mesh, skin and transform, a sibling
## under the same parent, drawn with the front pass at priority 0 and
## FRONT_PASS_SORTING_OFFSET. Call once `mi` has its parent (and, when
## skinned, its skeleton path). Returns the twin, or null.
static func add_front_pass(mi: MeshInstance3D) -> MeshInstance3D:
	var mat := mi.material_override
	if mat == null or not mat.has_meta(FRONT_PASS_META) or mi.get_parent() == null:
		return null
	var twin := MeshInstance3D.new()
	twin.name = String(mi.name) + "_front"
	twin.mesh = mi.mesh
	twin.transform = mi.transform
	twin.layers = mi.layers
	twin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	twin.material_override = mat.get_meta(FRONT_PASS_META)
	twin.sorting_offset = mi.sorting_offset + FRONT_PASS_SORTING_OFFSET
	mi.get_parent().add_child(twin)
	if mi.skin != null:
		twin.skin = mi.skin
		var skeleton := mi.get_node_or_null(mi.skeleton)
		if skeleton != null:
			twin.skeleton = twin.get_path_to(skeleton)
	return twin

static func _mod_pass(layer: BmtReader.Layer, tex: Texture2D, rule: Dictionary, cull: String) -> ShaderMaterial:
	var emu := {"godot": "opaque", "color": 0, "alpha": 0}
	if rule["blend"] != "":
		emu = blend_emulation(int(rule["src_blend"]), int(rule["dest_blend"]))
	var mat := ShaderMaterial.new()
	mat.resource_name = layer.layer_name
	mat.shader = _mod_shader(cull, emu["godot"], rule["zwrite"])
	# The layer's second colour, c11's material term (round 706, ObjectLight).
	mat.set_shader_parameter("albedo", layer.diffuse)
	mat.set_shader_parameter("albedo_texture", tex)
	var ref := int(rule["alpha_ref"])
	mat.set_shader_parameter("alpha_scissor", float(ref) / 255.0)
	var func_id := int(rule["alpha_func"])
	var tested := ref > 0 or (func_id != D3DCMP_GREATEREQUAL and func_id != D3DCMP_ALWAYS)
	mat.set_shader_parameter("alpha_func", func_id if tested else 0)
	# Every stage byte when the mod sets them, zeros included (0 is
	# D3DTA_DIFFUSE); the object renderer's MODULATE2X(TEXTURE, DIFFUSE)
	# otherwise (the shader's defaults).
	if rule.get("stage_ops", false):
		for k in ["color_op", "color_arg1", "color_arg2", "alpha_op", "alpha_arg1", "alpha_arg2"]:
			mat.set_shader_parameter(k, int(rule[k]))
	mat.set_shader_parameter("blend_color", int(emu["color"]))
	mat.set_shader_parameter("blend_alpha", int(emu["alpha"]))
	return mat

## The material for a layer the rule draws alpha-tested or two-sided.
static func _build_foliage_material(layer: BmtReader.Layer, tex: Texture2D, alpha_ref: int, two_sided: bool) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = layer.layer_name
	mat.shader = FOLIAGE_SHADER if two_sided else FOLIAGE_SHADER_ONE_SIDED
	# The layer's second colour, c11's material term (round 706, ObjectLight).
	mat.set_shader_parameter("albedo", layer.diffuse)
	if tex != null:
		mat.set_shader_parameter("albedo_texture", tex)
	# 0 means no alpha test (a two-sided solid layer): the shader then keeps
	# every texel.
	mat.set_shader_parameter("alpha_scissor", float(alpha_ref) / 255.0)
	return mat

## `texture_cache`: see load_object. Only a texture that decoded is
## remembered, under its resolved path lower-cased (as find_file compares
## names); a miss reports and is retried next time, as before.
##
## Since round 566 the same two halves as load_object, back to back on the
## caller's thread -- SkinnedBsrAssembler builds its NPC and item pieces'
## materials through here: _prepare_material decodes the texture to an Image,
## _commit_material builds the material from the uploaded texture.
## `env_map`, `mtrl`, `two_pass`: see layer_draw_rule (round 625 and its
## review).
static func build_godot_material(archive: Pk2Reader, bmt_path: String, layer: BmtReader.Layer, texture_cache: Dictionary = {}, env_map: int = -1, mtrl: Dictionary = {}, two_pass: bool = false) -> Material:
	var prepared := {"textures": {}, "missing": [], "log": []}
	var plan := _prepare_material(archive, bmt_path, layer, snapshot_textures(texture_cache), prepared, env_map, mtrl, two_pass)
	for what in prepared["missing"]:
		_missing(what)
	for line in prepared["log"]:
		print(line)
	commit_textures(prepared["textures"], texture_cache)
	return _commit_material(plan, texture_cache)

## A MULTITEX / MULTITEXREV mod's second texture (round 786; READ, BsrReader.
## _read_multitex): resolved, decoded into prepared["textures"] unless the
## commit's cache holds it (`known`), and described on the material's plan as
## `{"op", "factor", "rev", "texture_key"}`. The client loads the path as the
## mod names it (ResourceMgr::FUN_00bcf590 through CRTModMultiTex::
## FUN_00c82cb0); every mod MEASURED names a full archive path
## (`prim\mtrl\etc\...`). A bare name is taken beside the `.bmt`, as a
## layer's texture is (OURS: none exists). A texture not found is reported
## and the material drawn with stage 0 alone.
static func _prepare_multitex(archive: Pk2Reader, mod: Dictionary, bmt_path: String, plan: Dictionary,
		known: Dictionary, prepared: Dictionary) -> void:
	var path: String = mod.get("texture", "")
	if path == "":
		return
	if not (path.contains("\\") or path.contains("/")):
		var dir := bmt_path.replace("\\", "/").get_base_dir()
		path = dir + "/" + path if dir != "" else path
	var key := path.to_lower()
	var textures: Dictionary = prepared["textures"]
	if not textures.has(key):
		if known.has(key):
			textures[key] = {"image": null, "four_cc": known[key]["four_cc"], "alpha": (known[key]["alpha"] as Dictionary).duplicate()}
		else:
			var decoded := _decode_texture(archive, path, bmt_path, prepared["missing"])
			if decoded.is_empty():
				return
			textures[key] = decoded
	plan["multitex"] = {"op": int(mod.get("op", 1)), "factor": int(mod.get("factor", 0)),
		"rev": bool(mod.get("rev", false)), "texture_key": key}

## Puts a MULTITEX mod's texture on a committed material (round 786; READ
## CRTModMultiTex::vslot_004 0xc82ce0 / the op set-ups 0xc82ac0, 0xc82e70):
## an object-shader material moves to its MULTITEX variant; an MTRL mod's
## shader has the stage built in (multitex_op -1 until set). The factor is
## the TEXTUREFACTOR colour's alpha byte / 255 (D3D's BLENDFACTORALPHA reads
## the factor's alpha). Both passes of a two-pass material.
static func _commit_multitex(mat: Material, mt: Dictionary, texture_cache: Dictionary) -> void:
	var tex: Texture2D = texture_cache.get(String(mt.get("texture_key", "")), {}).get("texture")
	var sm := mat as ShaderMaterial
	if tex == null or sm == null:
		return
	var mats: Array = [sm]
	var front = sm.get_meta(FRONT_PASS_META) if sm.has_meta(FRONT_PASS_META) else null
	if front is ShaderMaterial:
		mats.append(front)
	for m_v in mats:
		var m := m_v as ShaderMaterial
		if m.shader != null and m.shader.has_meta(OBJECT_SHADER_KIND_META):
			var lightmapped := m.shader.code.contains("#define LIGHTMAP")
			m.shader = object_shader(String(m.shader.get_meta(OBJECT_SHADER_KIND_META)), false, lightmapped, true)
		m.set_shader_parameter("multitex_texture", tex)
		m.set_shader_parameter("multitex_op", int(mt["op"]))
		m.set_shader_parameter("multitex_factor", float((int(mt["factor"]) >> 24) & 0xFF) / 255.0)
		m.set_shader_parameter("multitex_rev", bool(mt["rev"]))

## The prepare half of a layer's material (round 566): its texture resolved
## and -- unless `known` says the commit's cache holds it -- decoded to an
## Image into prepared["textures"], and the layer's draw rule
## (layer_draw_rule). Returns the plan _commit_material builds from:
## `{"layer", "texture_key", "alpha_ref", "two_sided", "cutout"}` --
## `cutout` is alpha_ref > 0 -- the key "" for a layer drawn without a
## texture (none named, not found, not decodable).
static func _prepare_material(archive: Pk2Reader, bmt_path: String, layer: BmtReader.Layer, known: Dictionary, prepared: Dictionary, env_map: int = -1, mtrl: Dictionary = {}, two_pass: bool = false) -> Dictionary:
	var rule := layer_draw_rule(layer.unknown, env_map, mtrl, two_pass)
	var plan := {"layer": layer, "texture_key": "", "alpha_ref": rule["alpha_ref"],
		"two_sided": rule["two_sided"], "cutout": int(rule["alpha_ref"]) > 0, "rule": rule}
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
	# the two real cases. (The client says it with a byte of its own,
	# BmtReader.Layer.texture_bytes[2], READ in round 625.)
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

	# The decision above needs no pixels. OPENSRO_QA_MATS still reports a
	# texture that is heavily transparent while its layer is drawn without
	# a test -- which the client does too (a gloss or glow mask on an item,
	# an env-map mask), so the line is a pointer for a human, not an error.
	# Gated, so an ordinary run measures nothing.
	if not plan["cutout"] and OS.get_environment("OPENSRO_QA_MATS") != "":
		var fraction := float(_alpha_stat(decoded, "fraction", archive, tex_path, bmt_path, prepared))
		if fraction > _QA_MATS_REPORT_MIN_ALPHA_FRACTION:
			(prepared["log"] as Array).append("QA MAT: %s (%s, %s) is %.1f%% non-opaque, flags 0x%04x, no alpha test%s" % [
				layer.layer_name, tex_path.get_file(), four_cc,
				fraction * 100.0, layer.unknown,
				" (env map 0x%x)" % env_map if env_map >= 0 else ""])
	return plan

## The commit half of a layer's material, on the main thread: the object
## material the layer's rule asks for (round 706: every one lit as the
## original lights objects -- ObjectLight), textured from `texture_cache`
## (commit_textures has put the prepare's upload there): an MTRL mod's own
## draw, the alpha-tested or two-sided foliage shaders, or object.gdshader
## for a solid layer.
static func _commit_material(plan: Dictionary, texture_cache: Dictionary) -> Material:
	var layer: BmtReader.Layer = plan["layer"]
	var godot_tex: Texture2D = null
	var key: String = plan["texture_key"]
	if key != "" and texture_cache.has(key):
		godot_tex = texture_cache[key]["texture"]
	var alpha_ref := int(plan.get("alpha_ref", 0))
	var rule: Dictionary = plan.get("rule", {})
	if godot_tex != null and rule.get("mtrl", false) and (rule.get("blend", "") != "" or int(rule.get("alpha_ref", 0)) > 0
			or int(rule.get("alpha_func", D3DCMP_GREATEREQUAL)) not in [D3DCMP_GREATEREQUAL, D3DCMP_ALWAYS]):
		# An MTRL mod's blend or test (READ): its own blend -- the only
		# per-material blending the client has; the flag word never blends
		# -- and its own alpha func, which may be any D3DCMPFUNC.
		return _build_mod_material(layer, godot_tex, rule)
	if (godot_tex != null and alpha_ref > 0) or plan.get("two_sided", false):
		# A real double-sided card keeps its authored normal on both faces
		# (one vertex colour, object.gdshaderinc), and the alpha test reads
		# full-resolution alpha. An untextured layer has nothing to test.
		return _build_foliage_material(layer, godot_tex, alpha_ref if godot_tex != null else 0, plan.get("two_sided", false))
	return _build_object_material(layer, godot_tex)

## A solid layer's material (object.gdshader): the layer's SECOND colour as
## the material colour c11 multiplies (READ, ObjectLight), its texture or
## none (the shader's white default).
##
## Until round 706 this was a StandardMaterial3D with the layer's FIRST colour
## as its albedo, lit by Godot's sun (energy 0.3, round 43) and ambient: the
## first colour is in no object lighting of the original's (it is
## D3DMATERIAL9.Ambient, which the vertex shader never reads), and round 136's
## reason for preferring it -- Alexandria's 24 of 40 house layers with a 0.14
## second colour drew black -- does not hold for the original's formula,
## whose ambient term (0.6 x La) does not depend on the material at all.
static func _build_object_material(layer: BmtReader.Layer, tex: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = layer.layer_name
	mat.shader = OBJECT_SHADER
	mat.set_shader_parameter("albedo", layer.diffuse)
	if tex != null:
		mat.set_shader_parameter("albedo_texture", tex)
	mat.set_shader_parameter("alpha_scissor", 0.0)
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

## One alpha statistic of a decoded texture -- only `fraction`
## (_real_alpha_fraction) since round 625, which OPENSRO_QA_MATS reports --
## measured on its decoded Image once and remembered in `decoded["alpha"]`,
## which commit_textures carries into the texture cache, so a texture is
## measured once per world. A texture the cache already holds but whose
## statistic was never measured is read and decoded again from the archive
## for it, and an undecodable one measures as 0.0. (Until round 625 the
## material decision itself consulted `binary_cutout` and `variance` too;
## the client decides from the layer's flag word alone.)
##
## OPENSRO_QA_ALPHA_LOG=1 logs every consult -- `QA ALPHA: <file> (<fourCC>)
## <stat> <value> -- from the decoded Image | from a statistic measured
## earlier`.
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
		alpha[stat] = _real_alpha_fraction(image)
		source = "the decoded Image"
	if OS.get_environment("OPENSRO_QA_ALPHA_LOG") != "":
		var value = alpha[stat]
		(prepared["log"] as Array).append("QA ALPHA: %s (%s) %s %s -- from %s" % [
			tex_path.get_file(), decoded["four_cc"] if decoded["four_cc"] != "" else "uncompressed", stat,
			("%.4f" % value) if value is float else str(value), source])
	return alpha[stat]

## How transparent a texture has to be before OPENSRO_QA_MATS bothers
## reporting that it is being drawn without an alpha test.
const _QA_MATS_REPORT_MIN_ALPHA_FRACTION := 0.20

## Fraction of a texture's texels whose alpha is below 250/255 (a
## tolerance for DXT rounding on a fully opaque source) -- what
## OPENSRO_QA_MATS reports, never what decides a material (round 625).
## 0.0 for a texture that can't be decoded. The decoded Image since round
## 566; a copy is decompressed, so the uploaded Image stays as it was.
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
	var pp := ParseProfile.t0()
	var found_entry: Pk2Reader.Entry
	if archive.is_native():
		found_entry = archive.find_native(path)
	else:
		found_entry = _find_file(archive, path)
	ParseProfile.add("pk2.find_file", pp)
	return found_entry

static func _find_file(archive: Pk2Reader, path: String) -> Pk2Reader.Entry:
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
