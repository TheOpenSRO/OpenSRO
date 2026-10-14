extends RefCounted
class_name MapmTerrainBuilder

## Builds a real, renderable Godot terrain mesh from a parsed .m region
## (MapmReader.ParsedRegion) -- the piece that turns real per-vertex height
## data into an actual triangulated ground surface instead of the flat
## placeholder box World3D.tscn ships with.
##
## As of 2026-08-23, MapmReader's block/vertex structure is real and
## deterministic (see docs/protocol/MAPM_FORMAT.md and MapmReader's own top
## comment) -- a region is a real, confirmed 6x6 grid of 36 blocks, each a
## real 17x17 (GRID_WIDTH x GRID_WIDTH) vertex mesh, in real nested file
## order. This builder no longer needs to guess row boundaries from a
## decoded per-tile column field or group raw sequential tiles -- every
## vertex's real block index and real (row, col) position within that
## block are already known from MapmReader itself.
##
## Vertex color: for the real 7-byte-vertex file class, the vertex's Extra
## bytes are a real, confirmed `TextureInfo` `uint16` (a 10-bit texture ID
## into `tile2d.ifo` + a 6-bit scale, per the public format documentation
## cited in MAPM_FORMAT.md) followed by a real `Brightness` byte. **This
## project no longer guesses a per-tile appearance from that ID at all**
## (removed 2026-08-26, see docs/WORLD_ISSUES.md -- an earlier version
## invented a per-TileType color palette, then a green/brown hue sweep,
## neither backed by any real appearance data): every real ground tile
## already has a real texture in Map.pk2's `Tile2D\` folder (confirmed
## 100%, 719/719 real tile2d.ifo entries resolve and parse cleanly), so
## build_full_region_mesh_textured() below is what actually renders real
## ground appearance. _vertex_color() is now only the honest "no real
## texture resolved" fallback -- one flat UNKNOWN_TILE_COLOR, not a guess
## dressed up as data. The real 11-byte-vertex file class's Extra bytes
## don't have a confirmed field layout beyond height; this project doesn't
## invent one for those either.
##
## Real ground textures: corrected 2026-08-23. An earlier, exhaustive-
## looking search only checked Data.pk2/Media.pk2/Particles.pk2 for the
## real `.ddj` files tile2d.ifo references and wrongly concluded they were
## absent from this client install. They actually live in Map.pk2's real
## `Tile2D\` folder -- an archive that search never checked, because
## nothing else this project had found up to that point lived there
## (`.m`/`.o`/`.o2`/`.t` all live at Map.pk2's root, not a named
## subfolder). See docs/protocol/DDJ_FORMAT.md and TILE2D_FORMAT.md for
## the real correction. build_full_region_mesh_textured() below is the
## real per-quad-textured renderer this enables; build_full_region_mesh()
## (the flat-color version) remains for callers with no texture_lookup
## (e.g. no OPENSRO_MAP_PK2_PATH set) or as a fallback per-quad surface.

const GRID_WIDTH := 17

## World-space spacing between adjacent vertices. Real, confirmed value --
## see docs/protocol/MAPM_FORMAT.md's real loader-function findings for
## the full derivation: a whole real region is a real 6x6 grid of 17-wide
## blocks sharing edge vertices (6x16+1 = 97 unique vertices per side), and
## the real, independently-confirmed per-region world size (1920.0 units,
## from CRegionManagerBody) divided by 96 gives exactly 20.0.
const TILE_SIZE := 20.0

## **Removed 2026-08-26** (see docs/WORLD_ISSUES.md): this used to hold an
## invented RGB guess per real TileIndexReader.TileType (a made-up "what
## dirt/grass/etc. plausibly looks like" palette, and before that a
## fabricated green-to-brown hue sweep for anything not in this table) as
## a *rendering* fallback. Flagged as unacceptable: this project has real
## ground textures for every real tile2d.ifo entry (confirmed 100%,
## 719/719, resolving and parsing cleanly -- see TILE2D_FORMAT.md), so
## there is no real case where this project actually needs to invent an
## appearance instead of using the real texture. _vertex_color now returns
## one honest, unmistakably-neutral flat gray whenever a real texture
## isn't available (OPENSRO_MAP_PK2_PATH unset, or a genuinely-missing
## real texture file) instead of pretending a color choice represents
## anything real.

## Real, honest "no real texture available" color -- see this file's
## comment above. Deliberately flat and uniform (not per-type or
## per-ID varied) so it reads as "unknown," not as a guess dressed up as
## real ground variety.
const UNKNOWN_TILE_COLOR := Color(0.5, 0.5, 0.5)

## The flat base surface's render priority, and every opaque pass's (round
## 580, the white ground after a reconnect). The base and the textured
## opaque passes above it are coplanar and drawn at equal depth under
## GL_LEQUAL (drivers/gles3/rasterizer_scene_gles3.cpp, render_scene's
## opaque pass; 4.2.2-stable), so whichever the opaque list draws LAST is
## what shows. Godot 4.2.2 sorts that list with sort_by_key on a two-word
## key whose most significant field is the material's priority and whose
## least significant material field is the material RID's local index
## (drivers/gles3/rasterizer_scene_gles3.h, GeometryInstanceSurface::sort:
## key2 = material_id_hi | shader_id | flags | depth_layer | priority from
## the low bit up, key1's top 16 bits material_id_low; SortByKey compares
## key2 first; _geometry_instance_add_surface_with_material fills it from
## p_mat_src.get_local_index()) -- and the base and the passes share one
## shader, since BaseMaterial3D's shader key has no bit for a texture being
## set (scene/resources/material.h, MaterialKey). Left at the same priority,
## the RID indices decide, and after a world is freed RID_Alloc hands its
## free slots back last-freed-first (core/templates/rid_owner.h), which put
## some regions' base after their passes: the flat grey ground measured on
## the render box after a reconnect (docs/RE_COMPLETION.md, the /groundprobe
## round). A lower priority puts every base before every pass whatever the
## RID indices are. SceneMaterialData::set_render_priority stores
## `priority - RS::MATERIAL_RENDER_PRIORITY_MIN` (-128) in the key's 8 bits
## (drivers/gles3/storage/material_storage.cpp), so -1 sorts below 0.
## Forward+ has the same key layout and the same offset
## (servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h,
## the `sort` union; scene_shader_forward_clustered.cpp,
## MaterialData::set_render_priority) -- read, not run. The alpha overlays
## are in the transparent list, sorted by depth and priority apart from the
## opaque one; they keep the default.
const BASE_RENDER_PRIORITY := -1
const PASS_RENDER_PRIORITY := 0

## Fallback vertex color -- see this file's top comment. This only matters
## when the real per-quad texture (resolved by the caller via a real
## Tile2D\*.ddj lookup -- see build_full_region_mesh_textured) isn't
## available; it's UNKNOWN_TILE_COLOR unconditionally rather than inventing
## a plausible-looking per-tile value.
static func _vertex_color() -> Color:
	return UNKNOWN_TILE_COLOR

## Builds a triangulated ArrayMesh from a single real block (GRID_WIDTH x
## GRID_WIDTH vertices, row-major) -- useful standalone for a quick single
## sub-patch render, or as the unit build_full_region_mesh below stitches
## 36 of together.
static func build_mesh(region: MapmReader.ParsedRegion, block_index: int = 0) -> ArrayMesh:
	if block_index < 0 or block_index >= region.blocks.size():
		push_error("MapmTerrainBuilder: block index %d out of range (region has %d blocks)" % [block_index, region.blocks.size()])
		return null
	var block: MapmReader.Block = region.blocks[block_index]
	var cells := _block_to_cells(block)
	return _build_mesh_from_cells(cells, GRID_WIDTH, GRID_WIDTH)

## Real, precisely-confirmed full-region assembly -- see
## docs/protocol/MAPM_FORMAT.md. A whole region is a real 6x6 grid of
## GRID_WIDTH x GRID_WIDTH blocks (36 total, in real nested file order:
## MapmReader.ParsedRegion.blocks[band_row*6+band_col]), sharing edge
## vertices with their neighbors (stride GRID_WIDTH-1, not GRID_WIDTH, on
## both axes) -- giving `6*(GRID_WIDTH-1)+1 = 97` unique vertices per side.
## The *later* block (in nested file order) wins at a shared boundary,
## matching the real client's own confirmed behavior. Returns null if
## region doesn't have exactly BLOCK_COUNT blocks (MapmReader guarantees
## this on a successful parse, so this should only trip on a malformed
## caller-constructed region).
static func build_full_region_mesh(region: MapmReader.ParsedRegion) -> ArrayMesh:
	var arrays := build_full_region_arrays(region)
	if arrays.is_empty():
		return null
	return arrays_to_mesh(arrays)

## build_full_region_mesh's one surface as plain data (round 565): the
## Mesh.ARRAY_MAX-sized arrays it hands the engine, or [] (after the same
## error) for a region without a real 6x6 block grid. No Mesh is built, so a
## WorkerThreadPool task can call it -- World3D._terrain_prepare does, for a
## region none of whose ground textures resolved.
static func build_full_region_arrays(region: MapmReader.ParsedRegion) -> Array:
	var bands_per_side := MapmReader.BLOCKS_PER_SIDE
	if region.blocks.size() != bands_per_side * bands_per_side:
		push_error("MapmTerrainBuilder: region has %d blocks, want %d" % [region.blocks.size(), bands_per_side * bands_per_side])
		return []
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid := _full_region_cells(region, bands_per_side, full_size)
	return _mesh_arrays_from_cells(grid, full_size, full_size)

## Same real stitched region layout as build_full_region_mesh, but each
## quad is placed on its own real-textured surface instead of a single
## flat-colored one -- see docs/protocol/DDJ_FORMAT.md and
## docs/protocol/TILE2D_FORMAT.md's 2026-08-23 correction: the real ground
## texture files this project previously (wrongly) concluded were absent
## actually live in Map.pk2's real `Tile2D\` folder, not Data.pk2, which
## is where every earlier search this project ran looked. texture_lookup
## maps a real TextureInfo.ID (the same real 10-bit field _vertex_color
## already decodes) to an already-loaded real Texture2D -- built by the
## caller (World3D._terrain_commit, from the Images
## World3D._prepare_ground_textures decoded) since only it can reach the
## real pk2 archive. A quad whose top-left corner's ID isn't in
## texture_lookup falls back to the existing tile-type/hue-sweep vertex
## color on its own separate surface, so a region with only partial real
## texture coverage still renders every quad, just with mixed fidelity.
##
## The tile UV (ARRAY_TEX_UV) is retail's: a texture repeats every four
## quads, scaled by the TextureInfo's top three bits (TEXTURE_MATRIX_SCALES,
## round 610). `lightmap` is the region's lightmap multiplier
## (lightmap_term's Image, uploaded), sampled from the whole-region UV2
## (lightmap_coord) as each material's detail layer.
## `light_dir`, `light_diffuse` and `light_ambient` bake the real client's own
## terrain lighting into vertex colour (see _textured_surfaces_from_cells).
## Leave `light_dir` at Vector3.ZERO to skip it and let the engine light the
## terrain instead, which is what every caller did before 2026-09-07.
static func build_full_region_mesh_textured(region: MapmReader.ParsedRegion, texture_lookup: Dictionary, lightmap: Texture2D = null, light_dir: Vector3 = Vector3.ZERO, light_diffuse: Color = Color.WHITE, light_ambient: Color = Color.BLACK, shadow_map: PackedByteArray = PackedByteArray()) -> ArrayMesh:
	var surfaces := build_full_region_surfaces_textured(region, texture_lookup, light_dir, light_diffuse, light_ambient, shadow_map)
	if surfaces.is_empty():
		return null
	return surfaces_to_mesh(surfaces, texture_lookup, lightmap)

## build_full_region_mesh_textured's surfaces as plain data (round 565), in
## the mesh's own surface order -- one Dictionary per surface:
##   "arrays"      the Mesh.ARRAY_MAX-sized surface arrays (vertex, normal,
##                 uv, uv2, colour, index), exactly what the mesh is built from;
##   "texture_key" the real TextureInfo.ID whose texture the pass samples, or
##                 -1 for none (the flat base, and the pass of quads whose
##                 dominant ID did not resolve);
##   "blend"       whether the pass is an alpha-blended overlay;
##   "unshaded"    whether the real lighting is baked into the vertex colour;
##   "base"        true on the flat base surface only (absent elsewhere),
##                 whose material is drawn first (BASE_RENDER_PRIORITY);
##   "overlay_rank", "overlay_count"  on an overlay only (round 786): its
##                 place in the region's ascending-key overlay order and how
##                 many there are, which set its render priority
##                 (overlay_priority).
## Only Arrays, packed arrays and Dictionaries -- no Mesh, Material or
## Texture, each of which owns a RenderingServer RID -- so World3D's
## WorkerThreadPool task (_terrain_prepare) builds it off the main thread and
## surfaces_to_mesh turns it into the ArrayMesh on the main thread. Of
## texture_lookup only the KEYS are read (which IDs resolved to a texture),
## so the task passes a Dictionary of IDs; surfaces_to_mesh reads the values.
## [] (after the same error build_full_region_mesh_textured has always
## pushed) for a region without a real 6x6 block grid.
## `dynamic` (round 786, TerrainLight): the light is NOT baked -- the vertex
## colour's red, green and blue hold N.L alone (alpha the overlay's fade), each
## surface carries its "tint" and "dynamic": true, and _surface_material
## gives it TerrainLight's material, which applies the day phase's diffuse,
## ambient and shadow itself. light_diffuse / light_ambient are then unused.
static func build_full_region_surfaces_textured(region: MapmReader.ParsedRegion, texture_lookup: Dictionary, light_dir: Vector3 = Vector3.ZERO, light_diffuse: Color = Color.WHITE, light_ambient: Color = Color.BLACK, shadow_map: PackedByteArray = PackedByteArray(), dynamic: bool = false) -> Array:
	var bands_per_side := MapmReader.BLOCKS_PER_SIDE
	if region.blocks.size() != bands_per_side * bands_per_side:
		push_error("MapmTerrainBuilder: region has %d blocks, want %d" % [region.blocks.size(), bands_per_side * bands_per_side])
		return []
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid := _full_region_cells(region, bands_per_side, full_size)
	return _textured_surfaces_from_cells(grid, full_size, full_size, texture_lookup, light_dir, light_diffuse, light_ambient, shadow_map, dynamic)

## The ArrayMesh of `surfaces` (build_full_region_surfaces_textured's
## output), one mesh surface per entry in order, each with the material
## the textured builder has always given it: the pass's texture
## from texture_lookup (none for key -1), the base's lower render priority
## (BASE_RENDER_PRIORITY, round 580), the vertex colour as albedo,
## unshaded when the light is baked, alpha-blended without depth writes for
## an overlay, and `lightmap` (lightmap_term's multiplier, round 610) as a
## MUL detail layer on UV2 when there is one. Main thread only: the mesh and
## every material own RIDs.
static func surfaces_to_mesh(surfaces: Array, texture_lookup: Dictionary, lightmap: Texture2D = null) -> ArrayMesh:
	var array_mesh := ArrayMesh.new()
	for surface in surfaces:
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface["arrays"])
		array_mesh.surface_set_material(array_mesh.get_surface_count() - 1,
			_surface_material(surface, texture_lookup, lightmap))
	return array_mesh

## An overlay's render priority (round 786, the ground flicker): its rank
## among the region's overlays -- "overlay_rank", 0 for the lowest tile key,
## retail's pass order -- through WorldFog.ground_overlay_priority, so no two
## overlays of a region tie in Godot's unstable alpha sort (WorldFog's
## GROUND_OVERLAY_PRIORITY note has the cause and the reads).
## OPENSRO_QA_OVERLAY_ORDER (QA only, for the before/after measurement):
## `tie` puts every overlay back at GROUND_OVERLAY_PRIORITY (the build before
## the fix), `desc` reverses the ranks (which pixels the order changes).
static var _qa_overlay_order := OS.get_environment("OPENSRO_QA_OVERLAY_ORDER")

static func overlay_priority(surface: Dictionary) -> int:
	var rank: int = surface.get("overlay_rank", 0)
	match _qa_overlay_order:
		"tie":
			return WorldFog.GROUND_OVERLAY_PRIORITY
		"desc":
			rank = maxi(int(surface.get("overlay_count", 1)) - 1 - rank, 0)
	return WorldFog.ground_overlay_priority(rank)

## One pass's material -- see surfaces_to_mesh. A key the lookup does not
## hold is an error, not a silent untextured pass: an unset sampler draws
## white under GLES3, which is the "white ground" symptom (round 558), and
## the key set came from this same lookup, so a miss means a caller bug.
static func _surface_material(surface: Dictionary, texture_lookup: Dictionary, lightmap: Texture2D) -> Material:
	var key: int = surface["texture_key"]
	if surface.get("dynamic", false):
		# Round 786: the time of day's light (TerrainLight); `lightmap` is the
		# raw lightmap then (no shadow colour added).
		var tex: Texture2D = null
		if key != -1:
			if texture_lookup.has(key):
				tex = texture_lookup[key]
			else:
				push_error("MapmTerrainBuilder: surface texture %d is not in the lookup" % key)
		var priority := PASS_RENDER_PRIORITY
		if surface.get("base", false):
			priority = BASE_RENDER_PRIORITY
		if surface["blend"]:
			priority = overlay_priority(surface)
		return TerrainLight.material(tex, lightmap, surface.get("tint", Color.WHITE), surface["blend"], priority, key)
	var mat := StandardMaterial3D.new()
	# The pass's tile ID, for /groundprobe (GroundProbe, round 579): a pass
	# whose ID missed the lookup and one drawn with no ID at all both have no
	# albedo texture; only the key tells them apart. Metadata only.
	mat.set_meta("terrain_texture_key", key)
	if key != -1:
		if texture_lookup.has(key):
			mat.albedo_texture = texture_lookup[key]
		else:
			push_error("MapmTerrainBuilder: surface texture %d is not in the lookup" % key)
	mat.vertex_color_use_as_albedo = true
	# Display values, as Compatibility reads them; decoded where the output
	# is linear (Forward+), round 693's ShaderColour.
	mat.vertex_color_is_srgb = ShaderColour.VERTEX_COLOR_IS_SRGB
	# The base under every opaque pass in the opaque sort, whatever the
	# materials' RID indices (BASE_RENDER_PRIORITY). The overlays are
	# transparent and sorted apart; they keep the default, as do the passes.
	mat.render_priority = BASE_RENDER_PRIORITY if surface.get("base", false) else PASS_RENDER_PRIORITY
	if surface["unshaded"]:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if surface["blend"]:
		# Only the feathered neighbour overlays are transparent; a quad's own
		# texture is opaque (see _textured_surfaces_from_cells' doc comment).
		# depth_draw_disabled keeps these coplanar overlays from fighting the
		# opaque pass they sit exactly on top of.
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		# Drawn before the fog pass, which then fogs it with the opaque pass
		# under it -- the same depth (round 702, WorldFog) -- and before the
		# water, as retail draws every terrain pass before it (round 780,
		# WorldFog.GROUND_OVERLAY_PRIORITY): at the water's own priority the
		# depth sort put a lake bed's overlays over its water. Each overlay
		# at its own rank's priority (round 786, overlay_priority).
		mat.render_priority = overlay_priority(surface)
	if lightmap != null:
		# Retail's lightmap pass multiplies the drawn ground by the
		# lightmap term (lightmap_term). A detail layer in MUL mode multiplies
		# ALBEDO before any lighting, so it applies whether the light is baked
		# (unshaded) or not -- the AO texture this used before round 610 is a
		# lighting input, which an unshaded material never evaluates, so the
		# `.t` lightmap had no effect on baked terrain at all.
		mat.detail_enabled = true
		mat.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		mat.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
		mat.detail_albedo = lightmap
	return mat

## The collision faces of the mesh built from `surfaces` (round 565), as
## `Mesh.create_trimesh_shape()` would hand them to its ConcavePolygonShape3D:
## every triangle of every surface, surfaces in order and each surface's
## triangles in index order, each corner snapped to 0.0001. Plain data, so
## World3D's WorkerThreadPool task builds it and the main thread only calls
## `ConcavePolygonShape3D.set_faces`, instead of create_trimesh_shape reading
## the arrays back out of the RenderingServer and re-keying every vertex.
##
## Equality with create_trimesh_shape is MEASURED, not read from the engine:
## mapm_terrain_builder_test.gd compares this against
## `surfaces_to_mesh(...).create_trimesh_shape().get_faces()` element by
## element on synthetic regions whose heights sit off the 0.0001 grid, which
## is what shows the snap (the Godot 4.2.2 build this project ships was not
## read for it). Every surface is kept -- the base, the opaque passes and the
## blend overlays repeat the same triangles -- so the shape is the one the
## terrain has always had, duplicates included.
static func surface_faces(surfaces: Array) -> PackedVector3Array:
	var total := 0
	for surface in surfaces:
		total += (surface["arrays"][Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	var faces := PackedVector3Array()
	faces.resize(total)
	var snap := Vector3(0.0001, 0.0001, 0.0001)
	var w := 0
	for surface in surfaces:
		var arrays: Array = surface["arrays"]
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in indices:
			faces[w] = positions[i].snapped(snap)
			w += 1
	return faces

## Shared real 6x6-block stitching behind build_full_region_mesh and
## build_full_region_mesh_textured -- see either's doc comment for the
## real layout (block edge vertices shared with neighbors at stride
## GRID_WIDTH-1, later block in nested file order wins at a shared
## boundary).
static func _full_region_cells(region: MapmReader.ParsedRegion, bands_per_side: int, full_size: int) -> Array:
	var grid: Array = []
	for _i in range(full_size):
		var row_arr: Array = []
		row_arr.resize(full_size)
		grid.append(row_arr)

	for band_row in range(bands_per_side):
		for band_col in range(bands_per_side):
			var block: MapmReader.Block = region.blocks[band_row * bands_per_side + band_col]
			for local_r in range(GRID_WIDTH):
				var dest_r := band_row * (GRID_WIDTH - 1) + local_r
				for local_c in range(GRID_WIDTH):
					var vertex: MapmReader.Vertex = block.vertices[local_r * GRID_WIDTH + local_c]
					grid[dest_r][band_col * (GRID_WIDTH - 1) + local_c] = [vertex.height, vertex.extra]
	return grid

## Converts one real block's real vertices (row-major GRID_WIDTH x
## GRID_WIDTH) into the [height, extra] cell shape _build_mesh_from_cells
## expects.
static func _block_to_cells(block: MapmReader.Block) -> Array:
	var cells: Array = []
	for r in range(GRID_WIDTH):
		var row: Array = []
		for c in range(GRID_WIDTH):
			var vertex: MapmReader.Vertex = block.vertices[r * GRID_WIDTH + c]
			row.append([vertex.height, vertex.extra])
		cells.append(row)
	return cells

## Shared triangulation/vertex-buffer logic behind both build_mesh and
## build_full_region_mesh -- cells is a real per-row array (each row
## col_count [height, extra] pairs), row_count/col_count are
## cells.size()/cells[0].size() (passed separately since callers may have
## already validated/trimmed them).
static func _build_mesh_from_cells(cells: Array, row_count: int, col_count: int) -> ArrayMesh:
	return arrays_to_mesh(_mesh_arrays_from_cells(cells, row_count, col_count))

## One surface's arrays as an ArrayMesh, no material (the untextured path
## sets material_override instead). Main thread only: the mesh owns an RID
## (World3D._terrain_commit builds the untextured fallback with it).
static func arrays_to_mesh(arrays: Array) -> ArrayMesh:
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

## _build_mesh_from_cells' surface arrays, built without a Mesh (round 565).
static func _mesh_arrays_from_cells(cells: Array, row_count: int, col_count: int) -> Array:
	var positions := PackedVector3Array()
	positions.resize(row_count * col_count)
	for r in range(row_count):
		for c in range(col_count):
			var height: float = cells[r][c][0]
			positions[r * col_count + c] = Vector3(c * TILE_SIZE, height, r * TILE_SIZE)

	var normals := PackedVector3Array()
	normals.resize(positions.size())
	for r in range(row_count):
		for c in range(col_count):
			normals[r * col_count + c] = _estimate_normal(cells, row_count, col_count, r, c)

	var uvs := PackedVector2Array()
	uvs.resize(positions.size())
	for r in range(row_count):
		for c in range(col_count):
			uvs[r * col_count + c] = Vector2(float(c) / (col_count - 1), float(r) / (row_count - 1))

	var colors := PackedColorArray()
	colors.resize(positions.size())
	for r in range(row_count):
		for c in range(col_count):
			colors[r * col_count + c] = _vertex_color()

	var indices := PackedInt32Array()
	for r in range(row_count - 1):
		for c in range(col_count - 1):
			var i00 := r * col_count + c
			var i10 := i00 + 1
			var i01 := i00 + col_count
			var i11 := i01 + 1
			indices.append(i00)
			indices.append(i10)
			indices.append(i11)
			indices.append(i00)
			indices.append(i11)
			indices.append(i01)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays

## Returns the real 10-bit TextureInfo.ID a quad's top-left corner encodes,
## or -1 if extra is too short to have one, or the ID has no real texture
## in texture_lookup -- the caller's real fallback-to-color signal.
static func _resolve_texture_id(extra: PackedByteArray, texture_lookup: Dictionary) -> int:
	if extra.size() < 2:
		return -1
	var id: int = extra.decode_u16(0) & 0x3ff
	if texture_lookup.has(id):
		return id
	return -1

## How a ground texture is laid across the terrain, **read from the retail
## client** (round 610; docs/RE_COMPLETION.md has the addresses and the
## assembly). Retail draws the ground with the fixed-function pipeline
## (`Map::FUN_00a18740` sets the vertex declaration and no vertex shader), one
## pass per TextureInfo a block uses (`Map::FUN_00a1fdb0`):
##
##   * the tile texture sits on texture stage 1 and reads TEXCOORD1, which
##     `SWorld::vslot_035` (`0x009efc60`) fills per block vertex as
##     `(col * 0.25, row * 0.25)` -- `fld QWORD PTR ds:0xd83070` (the double
##     0.25) at `0x9f03f0`, stored to the vertex's `+8`/`+0xc`. So a texture
##     repeats once every **4 quads, 80 world units**, not once per quad;
##   * each pass then sets `SetTransform(D3DTS_TEXTURE1, ...)` to one of eight
##     matrices picked by the TextureInfo's **top three bits**
##     (`*puVar14 >> 0xd`, `0xa1fdb0`), with D3DTTFF_COUNT2 on stage 1. The
##     eight are built in `0x00a2f370` (`0xa2fc34`..`0xa2fca2`): the array is
##     zeroed (`_memset(+0x2c50, 0, 0x200)`) and only `_11`/`_22` of the first
##     five are set, to 1.0, 0.5 (`0xe1b7e0`), 0.25 (`0xd9a2b8`), 2.0
##     (`0xd86ecc`) and 4.0 (`0xd8ada8`). Indices 5-7 stay the zero matrix.
##
## So the tile UV of the vertex at region grid (row, col) is
## `(col, row) * TEXCOORD_PER_VERTEX * TEXTURE_MATRIX_SCALES[texinfo >> 13]`.
## A block is 16 quads, and 16 * 0.25 * scale is a whole number for every
## scale, so laying the UV from the region grid (as _quad_uv_corners does)
## gives exactly the per-block UV modulo one repeat.
##
## This replaces round 69's `BASE_TILE_REPEAT := 1.0` (one repeat per quad,
## justified from `c_marble_jang_07`'s slab size), which repeated every ground
## texture four times as often as retail and is what made open dirt read as a
## grid (the round-610 report). Round 69 was right that `2 ^ (scale >> 3)`
## was wrong: the field is an index into the table below, and 16 (index 2)
## makes a texture *larger*, not smaller.
const TEXCOORD_PER_VERTEX := 0.25
static var TEXTURE_MATRIX_SCALES: Array[float] = [1.0, 0.5, 0.25, 2.0, 4.0, 0.0, 0.0, 0.0]

## The tile-UV step per vertex for a vertex's TextureInfo (see
## TEXTURE_MATRIX_SCALES). A vertex with no TextureInfo gets the unscaled
## step.
static func _resolve_texture_repeat(extra: PackedByteArray) -> float:
	if extra.size() < 2:
		return TEXCOORD_PER_VERTEX
	return TEXCOORD_PER_VERTEX * TEXTURE_MATRIX_SCALES[(extra.decode_u16(0) >> 13) & 7]

## The region lightmap's texture coordinate for region grid index `i`
## (0..96), read from the same function: the second texcoord buffer
## (`+0x2f6c`, stride 8) holds `i * 0.25 * (1/24) * 0.998046875 + 0.0009765625`
## (the doubles at `0xd83070`, `0xde48c0`, `0xde48b8`, `0xde48b0`), i.e. the
## region spans the 512-texel lightmap from the first texel's centre to the
## last's.
static func lightmap_coord(i: int) -> float:
	return float(i) / 96.0 * 0.998046875 + 0.0009765625

## The retail terrain's lightmap pass, as the multiplier it applies.
##
## After the tile passes, `Map::FUN_00a1fdb0` draws every block once more
## when the world's `+0x2f30` switch is on (it is initialised to 1 in
## `0x00a2f370`, `mov [esi+0x2f30],ebp` with ebp = 1, and is option slot 56 of
## the `+0x2e50` table), with `Map::FUN_00a18d10`'s states: alpha blending with
## SRCBLEND = ZERO and DESTBLEND = SRCCOLOR -- the framebuffer multiplied by the
## pass's colour -- and stage 0 COLOROP = ADD of the region's `.t` lightmap
## (TEXCOORD0 = lightmap_coord) and D3DRS_TEXTUREFACTOR. The texture factor is
## the world's `+0x6883` colour, which `Map::FUN_00a1baf0` takes from the
## environment record's graph at `+0x1c0`; `Map::FUN_00a1b650` reads the
## record's graphs in file order into `+0x88, +0xbc, +0xf0, +0x124, +0x158,
## +0x18c, +0x1c0` (channels 0-6), so `+0x1c0` is channel 6,
## **TerrainShadowColor**. Fixed-function arithmetic is in bytes and ADD
## saturates, so the multiplier is `min(255, lightmap + round(shadow * 255))`
## per channel.
##
## Multiplying after the blend equals multiplying every pass by it
## (`lerp(a*L, b*L, t) = L*lerp(a, b, t)`), so the builder applies it as each
## terrain material's detail layer in MUL mode on UV2 (_surface_material).
## Returns an RGB8 Image, or null for no lightmap.
static func lightmap_term(lightmap: Image, shadow: Color) -> Image:
	var _pp := ParseProfile.t0()
	var _out := _pp_lightmap_term(lightmap, shadow)
	ParseProfile.add("mapm.lightmap_term", _pp)
	return _out

## The body of lightmap_term, timed by its wrapper above (ParseProfile, round 670).
static func _pp_lightmap_term(lightmap: Image, shadow: Color) -> Image:
	if lightmap == null or lightmap.is_empty():
		return null
	var img := lightmap.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	var add := PackedInt32Array([
		clampi(roundi(shadow.r * 255.0), 0, 255),
		clampi(roundi(shadow.g * 255.0), 0, 255),
		clampi(roundi(shadow.b * 255.0), 0, 255)])
	# The per-byte loop below, in Rust when the native readers are on
	# (SrNativeTerrain.lightmap_add, round 670; tools/native_parity_terrain.gd
	# holds the two to each other on every real `.t`).
	var native := NativeAssets.terrain()
	if native != null:
		var src := img.get_data()
		var out: PackedByteArray = native.call("lightmap_add", src, add[0], add[1], add[2])
		if out.size() == src.size():
			return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8, out)
	var luts: Array[PackedByteArray] = []
	for ch in range(3):
		var lut := PackedByteArray()
		lut.resize(256)
		for v in range(256):
			lut[v] = mini(v + add[ch], 255)
		luts.append(lut)
	var lr := luts[0]
	var lg := luts[1]
	var lb := luts[2]
	var data := img.get_data()
	var n := data.size()
	var i := 0
	while i < n:
		data[i] = lr[data[i]]
		data[i + 1] = lg[data[i + 1]]
		data[i + 2] = lb[data[i + 2]]
		i += 3
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8, data)



## Side of the real `.t` ShadowMap: 96x96 bytes, one per real terrain tile.
const SHADOW_MAP_SIDE := 96

## The real self-shadow term for the vertex at (r, c), from a region's own real
## `.t` ShadowMap.
##
## This is the `self_shadow_term` of the real terrain equation
## (`Surf_color = (N.L) * terrain_tex * cloud_covering * self_shadow_term`), and
## it is real per-tile data this project parsed from day one and never used.
##
## Measured across real regions, the map holds exactly **five** distinct byte
## values, always the same set: 153, 178, 204, 229, 255 -- which is
## `255 * (0.6, 0.7, 0.8, 0.9, 1.0)`. So it is a real five-level shadow
## multiplier bottoming out at 0.6, not a boolean mask. It matters: in real
## Jangan **56%** of tiles carry the darkest level, ground this project was
## drawing fully lit.
##
## A vertex sits on a corner shared by up to four real tiles, so the four are
## averaged -- the same treatment the flat-colour base surface already gives
## per-quad colour, and what keeps the five levels from reading as hard steps.
##
## ## Why this is not currently applied
##
## Rendering the real map as an image and comparing it against real Jangan's own
## authored minimap art lines the two up **exactly** in position, so the row/col
## orientation above is right. But the polarity is not what a sun shadow would
## give: the **fully lit** (255) tiles are the real building footprints, and the
## **darkest** (0.6) tiles are the open courtyards and streets. Real buildings
## should cast shadow *onto* nearby ground, not be the only lit thing in a town.
##
## That fits the public documentation's own wording better -- "a simplified map
## used to check if an object is inside shadow" -- i.e. a *query* structure for
## deciding whether an **object** standing on a tile is shadowed, rather than a
## multiplier for the terrain's own colour.
##
## Applying it as a terrain multiplier darkens **56%** of real Jangan's ground
## by 40%, which is a large, world-wide change resting on an unsettled reading.
## That is the same shape of mistake as this project's own `2 ^ (scale >> 3)`
## reading of the `.m` Scale field (see docs/WORLD_ISSUES.md's sixty-ninth
## round), so it stays unapplied until its real meaning is confirmed. The
## measurement and the helper are kept because both are real and correct.
static func _shadow_at(shadow_map: PackedByteArray, r: int, c: int) -> float:
	if shadow_map.size() < SHADOW_MAP_SIDE * SHADOW_MAP_SIDE:
		return 1.0
	var total := 0.0
	var n := 0
	for dr in [-1, 0]:
		for dc in [-1, 0]:
			var tr: int = r + dr
			var tc: int = c + dc
			if tr < 0 or tc < 0 or tr >= SHADOW_MAP_SIDE or tc >= SHADOW_MAP_SIDE:
				continue
			total += float(shadow_map[tr * SHADOW_MAP_SIDE + tc]) / 255.0
			n += 1
	return total / float(n) if n > 0 else 1.0

## The real client's own terrain lighting, per vertex:
##
##     mad oD0, N.L, c[VSC_DLIGHT_DIFFUSE], c[VSC_DLIGHT_AMBIENT]
##
## from `Shader\vertexshader0splatting.c`, which the real runtime shader
## generator loads (see docs/RE_MAP_ENGINE.md). `N.L` is clamped at 0 by the
## shader's own `max r1.x, r1.x, c[VSC_UTIL].z`.
##
## Baked into vertex colour rather than left to the engine because that is what
## the real client does -- terrain lighting there is per *vertex*, from a single
## directional term, not per pixel. Doing it here also lets the real
## `TerrainAmbientColor` channel be used, which the engine's single global
## ambient cannot express alongside the object ambient.
static func _lit_vertex_color(normal: Vector3, light_dir: Vector3, diffuse: Color, ambient: Color) -> Color:
	var ndotl := maxf(normal.normalized().dot(light_dir), 0.0)
	return Color(
		clampf(ndotl * diffuse.r + ambient.r, 0.0, 1.0),
		clampf(ndotl * diffuse.g + ambient.g, 0.0, 1.0),
		clampf(ndotl * diffuse.b + ambient.b, 0.0, 1.0))

## The four corner UVs of the quad at grid position (r, c), laid out
## **continuously across the whole region** so a real ground texture flows
## from one quad into the next.
##
## **Rewritten 2026-09-06** (see docs/WORLD_ISSUES.md's sixty-seventh round).
## This used to give every quad its own UV set starting at 0 and running to
## `repeat`, then rotate or mirror it by one of 8 square symmetries chosen
## from a hash of (r, c). Both halves of that were wrong, and together they
## are what made real open ground read as a grid of squares:
##
##   * starting every quad's UVs at 0 stamps the texture once per quad and
##     hard-cuts it at every 20-unit quad edge, so a seam is guaranteed on
##     every boundary no matter how the textures themselves blend;
##   * re-orienting each quad independently then makes neighbouring quads
##     disagree about which way the texture runs, turning those seams into
##     visible tiles.
##
## It was introduced as a disclosed rendering-only technique (never a claim
## about real data) to stop a repeated texture reading as an obviously
## stamped, aligned grid. It produced exactly the artifact it was meant to
## avoid.
##
## UVs now come from the vertex's own absolute position in the region grid,
## so they are continuous everywhere two quads share the real per-vertex
## `Scale` that drives `repeat` -- which is what makes a real texture tile
## across the ground instead of being stamped into it.
static func _quad_uv_corners(r: int, c: int, repeat: float = 1.0) -> PackedVector2Array:
	var u0 := float(c) * repeat
	var u1 := float(c + 1) * repeat
	var v0 := float(r) * repeat
	var v1 := float(r + 1) * repeat
	return PackedVector2Array([
		Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)])

## Builds a real multi-surface ArrayMesh, one surface per distinct real
## texture ID actually used (plus one shared "-1" surface for any quad
## with no real texture available) -- see build_full_region_mesh_textured's
## doc comment.
##
## **Reworked 2026-09-06 to real per-vertex splatting** (see
## docs/WORLD_ISSUES.md's sixty-sixth round). Two facts settle how real
## ground is meant to be textured, and neither was being used:
##
##   * the real `.m` vertex record carries a real texture ID **per vertex**,
##     not per quad (see MAPM_FORMAT.md's TextureInfo);
##   * the real client's own terrain pixel shader samples exactly **one**
##     terrain texture per pass -- a real `Data.pk2`'s
##     `Shader\terrainps14.psh` reads `texld r1, TEX_TERRAIN_COLOR`, and
##     `terrainpsn10.psh` does the same, with no multi-texture blend
##     anywhere in the shader.
##
## One texture per pass plus a real per-vertex ID *is* vertex splatting.
## This code previously collapsed the per-vertex ID down to one texture per
## quad and then feathered a fixed alpha along quad edges to hide the seam.
## That is why real open ground read as a plaid of hard-edged squares in a
## real playtest -- the blend could never be smoother than the quad grid it
## was defined on.
##
## Now, per quad: its **dominant** real texture (the one most of its corners
## use) is drawn fully opaque, so real ground is never see-through; then
## every *other* real texture its corners use is drawn again over it, with
## each vertex's alpha 1 where that vertex really uses that texture and 0
## where it does not. The blend therefore spans the whole quad and follows
## the real per-vertex data, instead of being a fixed fade pinned to an edge.
##
## Kept from the 2026-09-02 rework, which fixed a real earlier bug: a quad's
## own texture is opaque rather than faded toward a flat gray base. Fading
## toward gray desaturated real textures unevenly per region, producing the
## washed-out per-region tinting a real playtest reported.
##
## **Data, not a mesh, since round 565.** This was
## `_build_textured_mesh_from_cells`, which built the ArrayMesh and its
## materials itself; it now returns the surfaces as plain data (see
## build_full_region_surfaces_textured for the shape) so a WorkerThreadPool
## task can build them, and surfaces_to_mesh / _surface_material build the
## mesh and the materials on the main thread. The arrays, the surface order
## and every material flag are the ones the mesh was built from before the
## split: mapm_terrain_builder_test.gd holds both paths to fingerprints
## measured on the pre-split builder.
static func _textured_surfaces_from_cells(cells: Array, row_count: int, col_count: int, texture_lookup: Dictionary, light_dir: Vector3 = Vector3.ZERO, light_diffuse: Color = Color.WHITE, light_ambient: Color = Color.BLACK, shadow_map: PackedByteArray = PackedByteArray(), dynamic: bool = false) -> Array:
	var positions := PackedVector3Array()
	positions.resize(row_count * col_count)
	for r in range(row_count):
		for c in range(col_count):
			var height: float = cells[r][c][0]
			positions[r * col_count + c] = Vector3(c * TILE_SIZE, height, r * TILE_SIZE)

	var normals := PackedVector3Array()
	normals.resize(positions.size())
	for r in range(row_count):
		for c in range(col_count):
			normals[r * col_count + c] = _estimate_normal(cells, row_count, col_count, r, c)

	# uv2 is the region lightmap's coordinate, retail's own (lightmap_coord,
	# round 610): one continuous map over the whole region.
	var uv2s := PackedVector2Array()
	uv2s.resize(positions.size())
	for r in range(row_count):
		for c in range(col_count):
			uv2s[r * col_count + c] = Vector2(lightmap_coord(c), lightmap_coord(r))

	# First pass: resolve every quad's real texture key and fallback tone
	# up front (rather than inline in the buffer-building loop below) so
	# both the base surface's per-vertex averaging and the boundary check
	# can look up any quad's neighbors.
	# Real per-VERTEX texture assignment.
	#
	# **Changed 2026-09-06 from per-quad** (see docs/WORLD_ISSUES.md's
	# sixty-sixth round). The real `.m` vertex record carries its own real
	# texture ID and scale -- per *vertex*, not per quad (MAPM_FORMAT.md) --
	# and the real client's own terrain pixel shader samples exactly one
	# terrain texture per pass: a real `Data.pk2`'s `Shader\terrainps14.psh`
	# reads `texld r1, TEX_TERRAIN_COLOR` and its `terrainpsn10.psh`
	# equivalent does the same, with no multi-texture blend anywhere in the
	# shader. One texture per pass plus a real per-vertex ID is vertex
	# splatting: each pass draws the triangles touching one real texture,
	# faded out at the vertices that use a different one.
	#
	# This code previously collapsed that real per-vertex ID to one texture
	# per quad and feathered a fixed alpha along quad edges, which is what
	# made real open ground read as a plaid of hard-edged squares in a real
	# playtest.
	var vertex_keys := []
	var vertex_repeats := []
	vertex_keys.resize(row_count)
	vertex_repeats.resize(row_count)
	for r in range(row_count):
		vertex_keys[r] = []
		vertex_repeats[r] = []
		vertex_keys[r].resize(col_count)
		vertex_repeats[r].resize(col_count)
		for c in range(col_count):
			var vextra: PackedByteArray = cells[r][c][1]
			vertex_keys[r][c] = _resolve_texture_id(vextra, texture_lookup)
			# The tile-UV step retail's texture matrix gives this vertex's
			# TextureInfo (TEXTURE_MATRIX_SCALES, round 610).
			vertex_repeats[r][c] = _resolve_texture_repeat(vextra)

	# Real per-vertex terrain lighting (see _lit_vertex_color). With no real
	# light direction supplied this stays white, i.e. the engine lights the
	# terrain, which is what every caller did before 2026-09-07.
	var lit := PackedColorArray()
	lit.resize(positions.size())
	var bake_light := light_dir.length_squared() > 0.0
	var light_n := light_dir.normalized() if bake_light else Vector3.UP
	# Round 786: the dynamic terrain keeps N.L alone (a diffuse of 1 and no
	# ambient give clamp(N.L) = N.L, N.L being >= 0 already).
	dynamic = dynamic and bake_light
	if dynamic:
		light_diffuse = Color.WHITE
		light_ambient = Color.BLACK
	# **The real `.t` ShadowMap is deliberately NOT applied** -- see _shadow_at
	# for the measurement and for why its meaning is not settled.
	for i in range(lit.size()):
		lit[i] = _lit_vertex_color(normals[i], light_n, light_diffuse, light_ambient) if bake_light else Color.WHITE

	# Base surface: one continuous mesh over the whole grid, colored by the
	# real flat-color fallback. Real textured passes are drawn over it.
	var base_colors := PackedColorArray()
	base_colors.resize(positions.size())
	for i in range(base_colors.size()):
		var fallback := _vertex_color()
		if dynamic:
			base_colors[i] = lit[i]
		else:
			base_colors[i] = Color(fallback.r * lit[i].r, fallback.g * lit[i].g, fallback.b * lit[i].b) if bake_light else fallback

	var base_indices := PackedInt32Array()
	for r in range(row_count - 1):
		for c in range(col_count - 1):
			var i00 := r * col_count + c
			var i10 := i00 + 1
			var i01 := i00 + col_count
			var i11 := i01 + 1
			base_indices.append_array(PackedInt32Array([i00, i10, i11, i00, i11, i01]))

	var surfaces: Array = []
	var base_arrays := []
	base_arrays.resize(Mesh.ARRAY_MAX)
	base_arrays[Mesh.ARRAY_VERTEX] = positions
	base_arrays[Mesh.ARRAY_NORMAL] = normals
	base_arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	base_arrays[Mesh.ARRAY_COLOR] = base_colors
	base_arrays[Mesh.ARRAY_INDEX] = base_indices
	# The base's material: the vertex colour as albedo, and -- real lighting
	# being already in the vertex colour, so the engine must not light it a
	# second time -- unshaded when baked (_surface_material).
	# "base" marks it for its render priority (BASE_RENDER_PRIORITY).
	var base_surface := {"arrays": base_arrays, "texture_key": -1, "blend": false, "unshaded": bake_light, "base": true}
	if dynamic:
		base_surface["dynamic"] = true
		base_surface["tint"] = _vertex_color()
	surfaces.append(base_surface)

	# `buffers` holds each quad's own dominant real texture, drawn fully
	# opaque so the ground is never see-through; `blend_buffers` holds every
	# other real texture the quad's corners use, faded per vertex. Together
	# they reproduce the real client's own multi-pass blend.
	var buffers := {}
	var blend_buffers := {}

	var new_buffer := func() -> Dictionary:
		return {
			"positions": PackedVector3Array(),
			"normals": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"uv2s": PackedVector2Array(),
			"colors": PackedColorArray(),
			"indices": PackedInt32Array(),
		}

	var emit := func(buf: Dictionary, r: int, c: int, idx: PackedInt32Array,
			alphas: PackedFloat32Array, repeat: float, tint: Color) -> void:
		var base: int = buf["positions"].size()
		for i in range(4):
			buf["positions"].append(positions[idx[i]])
			buf["normals"].append(normals[idx[i]])
			buf["uv2s"].append(uv2s[idx[i]])
			# Real per-vertex lighting modulates the tint, so a real texture is
			# drawn as tex * (N.L * diffuse + ambient) exactly as the real
			# terrain pixel shader does.
			var l: Color = lit[idx[i]]
			if dynamic:
				# N.L alone; the tint is the surface's (TerrainLight).
				buf["colors"].append(Color(l.r, l.g, l.b, alphas[i]))
			else:
				buf["colors"].append(Color(tint.r * l.r, tint.g * l.g, tint.b * l.b, alphas[i]))
		buf["tint"] = tint
		buf["uvs"].append_array(_quad_uv_corners(r, c, repeat))
		buf["indices"].append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

	for r in range(row_count - 1):
		for c in range(col_count - 1):
			var corner_r := [r, r, r + 1, r + 1]
			var corner_c := [c, c + 1, c + 1, c]
			var idx := PackedInt32Array([
				r * col_count + c, r * col_count + c + 1,
				(r + 1) * col_count + c + 1, (r + 1) * col_count + c])

			var counts := {}
			for i in range(4):
				var k: int = vertex_keys[corner_r[i]][corner_c[i]]
				counts[k] = int(counts.get(k, 0)) + 1

			# The quad's dominant real texture carries the opaque pass.
			var dominant := -1
			var best := 0
			for k in counts:
				if k == -1:
					continue
				if int(counts[k]) > best:
					best = int(counts[k])
					dominant = k

			var dom_repeat := TEXCOORD_PER_VERTEX
			for i in range(4):
				if vertex_keys[corner_r[i]][corner_c[i]] == dominant:
					dom_repeat = vertex_repeats[corner_r[i]][corner_c[i]]
					break
			if not buffers.has(dominant):
				buffers[dominant] = new_buffer.call()
			var opaque_alphas := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
			var tint: Color = Color.WHITE if dominant != -1 else _vertex_color()
			emit.call(buffers[dominant], r, c, idx, opaque_alphas, dom_repeat, tint)

			# Every other real texture this quad's own corners use, faded to
			# nothing at the vertices that use a different one. This is the
			# real blend: it spans the whole quad rather than feathering a
			# fixed amount along its edge.
			for k in counts:
				if k == dominant or k == -1:
					continue
				var alphas := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
				var repeat := TEXCOORD_PER_VERTEX
				for i in range(4):
					if vertex_keys[corner_r[i]][corner_c[i]] == k:
						alphas[i] = 1.0
						repeat = vertex_repeats[corner_r[i]][corner_c[i]]
				if not blend_buffers.has(k):
					blend_buffers[k] = new_buffer.call()
				emit.call(blend_buffers[k], r, c, idx, alphas, repeat, Color.WHITE)

	# One surface per pass; its material (the pass's texture, the vertex
	# colour as albedo, unshaded when baked, alpha-blended without depth
	# writes for an overlay, the lightmap on UV2) is _surface_material's.
	var add_surface := func(key: int, buf: Dictionary, is_blend: bool) -> void:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf["positions"]
		arrays[Mesh.ARRAY_NORMAL] = buf["normals"]
		arrays[Mesh.ARRAY_TEX_UV] = buf["uvs"]
		arrays[Mesh.ARRAY_TEX_UV2] = buf["uv2s"]
		arrays[Mesh.ARRAY_COLOR] = buf["colors"]
		arrays[Mesh.ARRAY_INDEX] = buf["indices"]
		var surface := {"arrays": arrays, "texture_key": key, "blend": is_blend, "unshaded": bake_light}
		if dynamic:
			surface["dynamic"] = true
			surface["tint"] = buf.get("tint", Color.WHITE)
		surfaces.append(surface)

	var keys := buffers.keys()
	keys.sort()
	for key in keys:
		add_surface.call(key, buffers[key], false)

	# Blend overlays last, so they render over every opaque surface above.
	# Ascending key, retail's pass order; each carries its rank, which fixes
	# its place among the region's overlays (round 786, overlay_priority).
	var blend_keys := blend_buffers.keys()
	blend_keys.sort()
	for key in blend_keys:
		add_surface.call(key, blend_buffers[key], true)
		surfaces[-1]["overlay_rank"] = blend_keys.find(key)
		surfaces[-1]["overlay_count"] = blend_keys.size()

	return surfaces

## Real full-region wrapper around build_water_mesh, same real 6x6-block
## stitching as build_full_region_mesh/build_full_region_mesh_textured --
## see either's doc comment. Returns null (no real work done) if region
## doesn't have exactly BLOCK_COUNT blocks, same guard as those two.
static func build_full_region_water_mesh(region: MapmReader.ParsedRegion, tile_table: TileIndexReader.Table) -> ArrayMesh:
	var bands_per_side := MapmReader.BLOCKS_PER_SIDE
	if region.blocks.size() != bands_per_side * bands_per_side:
		return null
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid := _full_region_cells(region, bands_per_side, full_size)
	return build_water_mesh(grid, full_size, full_size, tile_table)

## Builds a real, separate water-surface mesh covering only the quads whose
## real TileType (via tile_table, the same real classification
## _vertex_color already uses) is WATER or DEEP_WATER -- see
## docs/protocol/TILE2D_FORMAT.md. Returns null if tile_table is null or no
## real water quads are found in this region, so a caller can skip adding
## an empty/pointless node. Positions use the same real per-vertex heights
## as the main terrain mesh (so the water surface sits exactly at the real
## water tile's own height, seamlessly matching the surrounding ground --
## not an artificially flattened "lake level", which this project has no
## real per-body-of-water reference height to compute anyway), with each
## quad given its own repeating 0..1 UV so a real animated water texture
## tiles naturally across it, the same per-quad-texture convention
## build_full_region_mesh_textured already uses for ordinary ground.
static func build_water_mesh(cells: Array, row_count: int, col_count: int, tile_table: TileIndexReader.Table) -> ArrayMesh:
	if tile_table == null:
		return null

	var positions := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for r in range(row_count - 1):
		for c in range(col_count - 1):
			var extra: PackedByteArray = cells[r][c][1]
			if extra.size() < 2:
				continue
			var id: int = extra.decode_u16(0) & 0x3ff
			var entry := tile_table.lookup(id)
			if entry == null:
				continue
			if entry.type != TileIndexReader.TileType.WATER and entry.type != TileIndexReader.TileType.DEEP_WATER:
				continue

			var h00: float = cells[r][c][0]
			var h10: float = cells[r][c + 1][0]
			var h01: float = cells[r + 1][c][0]
			var h11: float = cells[r + 1][c + 1][0]
			var base := positions.size()
			positions.append_array(PackedVector3Array([
				Vector3(c * TILE_SIZE, h00, r * TILE_SIZE),
				Vector3((c + 1) * TILE_SIZE, h10, r * TILE_SIZE),
				Vector3((c + 1) * TILE_SIZE, h11, (r + 1) * TILE_SIZE),
				Vector3(c * TILE_SIZE, h01, (r + 1) * TILE_SIZE),
			]))
			uvs.append_array(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))
			indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

	if positions.is_empty():
		return null

	var normals := PackedVector3Array()
	normals.resize(positions.size())
	normals.fill(Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

## The real height at row 0, column GRID_WIDTH/2 of a full stitched region
## mesh -- the same real vertex World3D uses as its near-row vertical
## alignment anchor (see World3D._try_load_real_terrain's doc comment).
## Reads directly from the parsed region rather than the built mesh, so it
## gives the same real answer regardless of which mesh builder (flat-color
## or per-quad-textured, which can split row 0 across several surfaces) a
## caller used.
static func near_row_middle_height(region: MapmReader.ParsedRegion) -> float:
	var block: MapmReader.Block = region.blocks[0]
	return block.vertices[GRID_WIDTH / 2].height

## The real terrain height at a region-local (x, z), read straight from a
## region's own heightmap and interpolated between the four surrounding
## real vertices.
##
## Independent of any mesh this builder produces, so it can answer "what
## does this region's data say the ground is here" for a region that is
## not, or not yet, built -- which is what deciding **which** region an
## object belongs to needs (see World3D's own use of it). Returns NAN for
## a position outside the region or a region that did not parse.
static func height_at(region: MapmReader.ParsedRegion, x: float, z: float) -> float:
	if region == null or region.blocks.size() < MapmReader.BLOCK_COUNT:
		return NAN
	var span := float(MapmReader.BLOCKS_PER_SIDE) * float(GRID_WIDTH - 1) * TILE_SIZE
	if x < 0.0 or z < 0.0 or x >= span or z >= span:
		return NAN

	var fx := x / TILE_SIZE
	var fz := z / TILE_SIZE
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var h00 := _vertex_height(region, x0, z0)
	var h10 := _vertex_height(region, x0 + 1, z0)
	var h01 := _vertex_height(region, x0, z0 + 1)
	var h11 := _vertex_height(region, x0 + 1, z0 + 1)
	if is_nan(h00) or is_nan(h10) or is_nan(h01) or is_nan(h11):
		return NAN
	return (h00 * (1.0 - tx) + h10 * tx) * (1.0 - tz) + (h01 * (1.0 - tx) + h11 * tx) * tz

## Does a region's heightmap actually carry ground at (x, z), as opposed to
## an unauthored patch of zeroes?
##
## **Not currently used to decide anything.** It was written to stop
## zero-filled bands winning World3D's region-ownership comparison, and it
## does -- but wiring it in made the visible result worse rather than
## better (see docs/WORLD_ISSUES.md's eighty-sixth round), so it is kept
## for the fact it records rather than for a decision it drives.
##
## Real regions contain bands where every vertex height is exactly 0.0 --
## real 96/168 reads 0.00 across its whole z 1700-1850 band while reading
## -38.42 and -60.02 elsewhere. That is absence of data, not flat ground at
## sea level, and it matters because anything comparing regions by "whose
## ground best matches this height" would otherwise let a zero-filled patch
## win every object authored near zero. A real heightmap varies; four
## surrounding vertices all at exactly 0.0 do not happen by accident.
static func has_real_ground_at(region: MapmReader.ParsedRegion, x: float, z: float) -> bool:
	if region == null:
		return false
	var span := float(MapmReader.BLOCKS_PER_SIDE) * float(GRID_WIDTH - 1) * TILE_SIZE
	if x < 0.0 or z < 0.0 or x >= span or z >= span:
		return false
	var x0 := int(floor(x / TILE_SIZE))
	var z0 := int(floor(z / TILE_SIZE))
	for dz in [0, 1]:
		for dx in [0, 1]:
			var h := _vertex_height(region, x0 + (dx as int), z0 + (dz as int))
			if is_nan(h):
				return false
			if h != 0.0:
				return true
	return false

## One vertex of the stitched region grid, addressed the same way
## _full_region_cells stitches it: block edges are shared with the
## neighbouring block at stride GRID_WIDTH - 1.
static func _vertex_height(region: MapmReader.ParsedRegion, vx: int, vz: int) -> float:
	var stride := GRID_WIDTH - 1
	var last := MapmReader.BLOCKS_PER_SIDE - 1
	var bx := vx / stride
	var bz := vz / stride
	var ix := vx % stride
	var iz := vz % stride
	if bx > last:
		bx = last
		ix = stride
	if bz > last:
		bz = last
		iz = stride
	var block_index := bz * MapmReader.BLOCKS_PER_SIDE + bx
	if block_index < 0 or block_index >= region.blocks.size():
		return NAN
	var block: MapmReader.Block = region.blocks[block_index]
	var vi := iz * GRID_WIDTH + ix
	if vi < 0 or vi >= block.vertices.size():
		return NAN
	return block.vertices[vi].height

## A simple central-difference normal from neighboring real heights, same
## technique any heightmap renderer uses -- clamps to the grid edge rather
## than wrapping or fabricating an out-of-bounds neighbor.
static func _estimate_normal(cells: Array, row_count: int, col_count: int, r: int, c: int) -> Vector3:
	var c0 := maxi(c - 1, 0)
	var c1 := mini(c + 1, col_count - 1)
	var r0 := maxi(r - 1, 0)
	var r1 := mini(r + 1, row_count - 1)

	var hL: float = cells[r][c0][0]
	var hR: float = cells[r][c1][0]
	var hD: float = cells[r0][c][0]
	var hU: float = cells[r1][c][0]

	var dx := (c1 - c0) * TILE_SIZE
	var dz := (r1 - r0) * TILE_SIZE
	if dx == 0.0 or dz == 0.0:
		return Vector3.UP

	var slope_x := (hR - hL) / dx
	var slope_z := (hU - hD) / dz
	return Vector3(-slope_x, 1.0, -slope_z).normalized()
