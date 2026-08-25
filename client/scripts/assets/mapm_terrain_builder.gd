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
## cited in MAPM_FORMAT.md) followed by a real `Brightness` byte. This
## project has a real `tile2d.ifo` (see docs/protocol/TILE2D_FORMAT.md,
## `TileIndexReader`) giving a real per-ID `TileType` classification
## (grass/sand/snow/water/etc). _vertex_color() uses that real
## classification for a real, semantically-grounded color when a parsed
## tile2d table is passed in, falling back to a data-driven green/brown
## hue spread across the raw ID otherwise -- used as the fallback surface
## color in build_full_region_mesh_textured() below wherever a quad's real
## texture isn't available. The real 11-byte-vertex file class's Extra
## bytes don't have a confirmed field layout beyond height, so the same
## decode is applied best-effort (the leading 2 bytes exist in both real
## shapes) rather than treated as a wholly different case.
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
## (e.g. no SRREVAMP_MAP_PK2_PATH set) or as a fallback per-quad surface.

const GRID_WIDTH := 17

## World-space spacing between adjacent vertices. Real, confirmed value --
## see docs/protocol/MAPM_FORMAT.md's real loader-function findings for
## the full derivation: a whole real region is a real 6x6 grid of 17-wide
## blocks sharing edge vertices (6x16+1 = 97 unique vertices per side), and
## the real, independently-confirmed per-region world size (1920.0 units,
## from CRegionManagerBody) divided by 96 gives exactly 20.0.
const TILE_SIZE := 20.0

## Real, plausible base colors for each real TileIndexReader.TileType --
## see docs/protocol/TILE2D_FORMAT.md. Used only as the fallback surface
## color in build_full_region_mesh_textured() (a real ID with no matching
## real texture in texture_lookup) and by the older, flat-color
## build_full_region_mesh() -- since the real ground texture files
## themselves were found (2026-08-23, see TILE2D_FORMAT.md's
## "Corrected 2026-08-23" section: they live in Map.pk2's Tile2D\ folder),
## these are no longer this project's only real-world-plausible option,
## just the honest fallback for whatever a given region's real texture
## lookup doesn't cover.
static var _type_colors := {
	TileIndexReader.TileType.DIRT: Color(0.42, 0.30, 0.18),
	TileIndexReader.TileType.SAND: Color(0.76, 0.67, 0.42),
	TileIndexReader.TileType.ASHFIELD: Color(0.30, 0.28, 0.27),
	TileIndexReader.TileType.STONE: Color(0.55, 0.55, 0.56),
	TileIndexReader.TileType.METAL: Color(0.5, 0.52, 0.56),
	TileIndexReader.TileType.WOOD: Color(0.45, 0.32, 0.16),
	TileIndexReader.TileType.MUD: Color(0.32, 0.24, 0.14),
	TileIndexReader.TileType.WATER: Color(0.20, 0.45, 0.65),
	TileIndexReader.TileType.DEEP_WATER: Color(0.10, 0.22, 0.45),
	TileIndexReader.TileType.SNOW: Color(0.92, 0.93, 0.95),
	TileIndexReader.TileType.GRASS: Color(0.30, 0.55, 0.22),
	TileIndexReader.TileType.LONG_GRASS: Color(0.22, 0.45, 0.16),
	TileIndexReader.TileType.FOREST: Color(0.14, 0.32, 0.12),
	TileIndexReader.TileType.CLOUD: Color(0.85, 0.87, 0.90),
}

## Turns a real per-vertex Extra byte array into real, data-driven vertex
## color -- see this file's top comment. Uses the real confirmed
## TextureInfo uint16's low 10 bits (the real texture ID field) when at
## least 2 Extra bytes are available. If tile_table (a parsed
## TileIndexReader.Table, e.g. from a real tile2d.ifo) is given and has a
## real entry for that ID, returns that entry's real TileType's plausible
## base color (see _type_colors). Otherwise falls back to a data-driven
## green-to-brown hue sweep across the raw ID -- real variation, not a
## claim about what any specific ID represents. A completely empty Extra
## falls back to a fixed mid-tone.
static func _vertex_color(extra: PackedByteArray, tile_table: TileIndexReader.Table = null) -> Color:
	if extra.size() < 2:
		return Color(0.45, 0.5, 0.32)
	var tex_info := extra.decode_u16(0)
	var id := tex_info & 0x3ff # real 10-bit TextureInfo.ID field

	if tile_table != null:
		var entry := tile_table.lookup(id)
		if entry != null and _type_colors.has(entry.type):
			return _type_colors[entry.type]

	var t := id / 1023.0
	# Hue sweeps a natural green-to-brown arc (0.30 = green, 0.08 = brown)
	# rather than the full rainbow, so real variation reads as ground
	# rather than as an arbitrary rainbow gradient.
	var hue := lerpf(0.30, 0.08, t)
	return Color.from_hsv(hue, 0.45, 0.55)

## Builds a triangulated ArrayMesh from a single real block (GRID_WIDTH x
## GRID_WIDTH vertices, row-major) -- useful standalone for a quick single
## sub-patch render, or as the unit build_full_region_mesh below stitches
## 36 of together.
static func build_mesh(region: MapmReader.ParsedRegion, block_index: int = 0, tile_table: TileIndexReader.Table = null) -> ArrayMesh:
	if block_index < 0 or block_index >= region.blocks.size():
		push_error("MapmTerrainBuilder: block index %d out of range (region has %d blocks)" % [block_index, region.blocks.size()])
		return null
	var block: MapmReader.Block = region.blocks[block_index]
	var cells := _block_to_cells(block)
	return _build_mesh_from_cells(cells, GRID_WIDTH, GRID_WIDTH, tile_table)

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
static func build_full_region_mesh(region: MapmReader.ParsedRegion, tile_table: TileIndexReader.Table = null) -> ArrayMesh:
	var bands_per_side := MapmReader.BLOCKS_PER_SIDE
	if region.blocks.size() != bands_per_side * bands_per_side:
		push_error("MapmTerrainBuilder: region has %d blocks, want %d" % [region.blocks.size(), bands_per_side * bands_per_side])
		return null
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid := _full_region_cells(region, bands_per_side, full_size)
	return _build_mesh_from_cells(grid, full_size, full_size, tile_table)

## Same real stitched region layout as build_full_region_mesh, but each
## quad is placed on its own real-textured surface instead of a single
## flat-colored one -- see docs/protocol/DDJ_FORMAT.md and
## docs/protocol/TILE2D_FORMAT.md's 2026-08-23 correction: the real ground
## texture files this project previously (wrongly) concluded were absent
## actually live in Map.pk2's real `Tile2D\` folder, not Data.pk2, which
## is where every earlier search this project ran looked. texture_lookup
## maps a real TextureInfo.ID (the same real 10-bit field _vertex_color
## already decodes) to an already-loaded real Texture2D -- built by the
## caller (World3D._load_real_ground_textures) since only it can reach the
## real pk2 archive. A quad whose top-left corner's ID isn't in
## texture_lookup falls back to the existing tile-type/hue-sweep vertex
## color on its own separate surface, so a region with only partial real
## texture coverage still renders every quad, just with mixed fidelity.
##
## Each quad gets its own local 0..1 UV (ARRAY_TEX_UV) so its real texture
## isn't stretched across the whole region -- one real texture tile per
## real quad, matching the real per-vertex granularity the format actually
## encodes. ao_texture (the real .t lightmap, shared for the whole region)
## is sampled from a second, whole-region-spanning UV channel
## (ARRAY_TEX_UV2) instead, since it needs the opposite: one continuous
## real shadow map stretched over the entire mesh, not repeated per quad.
static func build_full_region_mesh_textured(region: MapmReader.ParsedRegion, tile_table: TileIndexReader.Table, texture_lookup: Dictionary, ao_texture: Texture2D = null) -> ArrayMesh:
	var bands_per_side := MapmReader.BLOCKS_PER_SIDE
	if region.blocks.size() != bands_per_side * bands_per_side:
		push_error("MapmTerrainBuilder: region has %d blocks, want %d" % [region.blocks.size(), bands_per_side * bands_per_side])
		return null
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid := _full_region_cells(region, bands_per_side, full_size)
	return _build_textured_mesh_from_cells(grid, full_size, full_size, tile_table, texture_lookup, ao_texture)

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
static func _build_mesh_from_cells(cells: Array, row_count: int, col_count: int, tile_table: TileIndexReader.Table = null) -> ArrayMesh:
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
			var extra: PackedByteArray = cells[r][c][1]
			colors[r * col_count + c] = _vertex_color(extra, tile_table)

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

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

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

## Deterministically picks one of the 8 real square symmetries (4
## rotations x optional mirror) for a quad's own UV corners, keyed by its
## own (r, c) grid position. Purely a rendering choice, not a claim about
## the original game's own real per-quad UV data (not recoverable at this
## granularity from what this project has) -- a standard, honest technique
## for keeping a real, repeated ground texture from reading as an
## obviously stamped, uniformly-aligned grid, the same real visual problem
## flagged as a known limitation when per-quad texturing first shipped
## (see docs/PROGRESS.md). Every quad still gets exactly one real texture
## tile, unchanged -- this only varies its orientation.
static func _quad_uv_corners(r: int, c: int) -> PackedVector2Array:
	var base: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var h: int = absi((r * 73856093) ^ (c * 19349663))
	var variant := h % 8
	var rot := variant % 4
	var mirror := variant >= 4
	var corners := PackedVector2Array()
	corners.resize(4)
	for i in range(4):
		var uv: Vector2 = base[(i + rot) % 4]
		if mirror:
			uv = Vector2(uv.y, uv.x)
		corners[i] = uv
	return corners

## Builds a real multi-surface ArrayMesh, one surface per distinct real
## texture ID actually used (plus one shared "-1" surface for any quad
## with no real texture available) -- see build_full_region_mesh_textured's
## doc comment.
##
## Since each quad only ever carries one real texture ID (the format has no
## real per-vertex blend weights this project has found), a naive render
## shows a hard, obviously rectangular edge everywhere two differently-
## textured quads meet. To soften that (2026-08-24, flagged as looking
## "inconsistent" from a live screenshot pass), this also builds a base
## surface spanning the whole grid with each vertex colored by averaging
## its surrounding quads' own real per-tile tone (_vertex_color) --
## Godot's normal vertex-color interpolation then gives a smooth gradient
## between differently-toned areas everywhere, not just at a hard line.
## Quads adjacent to a different real texture ID are then rendered with
## partial alpha over that smooth base instead of full opacity, so the
## seam reads as a soft, muted transition band about one quad wide rather
## than a stamped-looking rectangle edge. Still exactly one real texture
## per quad -- this only changes how its edges blend into its neighbors.
static func _build_textured_mesh_from_cells(cells: Array, row_count: int, col_count: int, tile_table: TileIndexReader.Table, texture_lookup: Dictionary, ao_texture: Texture2D) -> ArrayMesh:
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

	# uv2 is the same whole-region 0..1 span build_full_region_mesh's UV
	# uses -- kept only for ao_texture, which needs one continuous real
	# shadow map, not a per-quad repeat.
	var uv2s := PackedVector2Array()
	uv2s.resize(positions.size())
	for r in range(row_count):
		for c in range(col_count):
			uv2s[r * col_count + c] = Vector2(float(c) / (col_count - 1), float(r) / (row_count - 1))

	# First pass: resolve every quad's real texture key and fallback tone
	# up front (rather than inline in the buffer-building loop below) so
	# both the base surface's per-vertex averaging and the boundary check
	# can look up any quad's neighbors.
	var quad_keys := []
	var quad_colors := []
	quad_keys.resize(row_count - 1)
	quad_colors.resize(row_count - 1)
	for r in range(row_count - 1):
		quad_keys[r] = []
		quad_colors[r] = []
		quad_keys[r].resize(col_count - 1)
		quad_colors[r].resize(col_count - 1)
		for c in range(col_count - 1):
			var extra: PackedByteArray = cells[r][c][1]
			quad_keys[r][c] = _resolve_texture_id(extra, texture_lookup)
			quad_colors[r][c] = _vertex_color(extra, tile_table)

	# Base surface: one continuous mesh over the whole grid, each vertex
	# colored by averaging the (up to 4) quads that touch it -- see this
	# function's own doc comment.
	var base_colors := PackedColorArray()
	base_colors.resize(positions.size())
	for r in range(row_count):
		for c in range(col_count):
			var sum := Color(0, 0, 0, 0)
			var n := 0
			for dr in [-1, 0]:
				for dc in [-1, 0]:
					var qr: int = r + dr
					var qc: int = c + dc
					if qr >= 0 and qr < row_count - 1 and qc >= 0 and qc < col_count - 1:
						sum += quad_colors[qr][qc]
						n += 1
			base_colors[r * col_count + c] = (sum / n) if n > 0 else Color(0.45, 0.5, 0.32)

	var base_indices := PackedInt32Array()
	for r in range(row_count - 1):
		for c in range(col_count - 1):
			var i00 := r * col_count + c
			var i10 := i00 + 1
			var i01 := i00 + col_count
			var i11 := i01 + 1
			base_indices.append_array(PackedInt32Array([i00, i10, i11, i00, i11, i01]))

	var array_mesh := ArrayMesh.new()
	var base_arrays := []
	base_arrays.resize(Mesh.ARRAY_MAX)
	base_arrays[Mesh.ARRAY_VERTEX] = positions
	base_arrays[Mesh.ARRAY_NORMAL] = normals
	base_arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	base_arrays[Mesh.ARRAY_COLOR] = base_colors
	base_arrays[Mesh.ARRAY_INDEX] = base_indices
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, base_arrays)
	var base_mat := StandardMaterial3D.new()
	base_mat.vertex_color_use_as_albedo = true
	if ao_texture != null:
		base_mat.ao_enabled = true
		base_mat.ao_texture = ao_texture
		base_mat.ao_light_affect = 1.0
		base_mat.ao_on_uv2 = true
	array_mesh.surface_set_material(0, base_mat)

	# One growable vertex/index buffer per real texture ID (or -1 for the
	# color-fallback surface), layered on top of the base surface above,
	# built up quad by quad.
	var buffers := {}

	for r in range(row_count - 1):
		for c in range(col_count - 1):
			var key: int = quad_keys[r][c]
			if not buffers.has(key):
				buffers[key] = {
					"positions": PackedVector3Array(),
					"normals": PackedVector3Array(),
					"uvs": PackedVector2Array(),
					"uv2s": PackedVector2Array(),
					"colors": PackedColorArray(),
					"indices": PackedInt32Array(),
				}
			var buf: Dictionary = buffers[key]

			var i00 := r * col_count + c
			var i10 := i00 + 1
			var i01 := i00 + col_count
			var i11 := i01 + 1
			var base: int = buf["positions"].size()

			var color: Color = Color.WHITE if key != -1 else quad_colors[r][c]
			var is_boundary: bool = (
				(r > 0 and quad_keys[r - 1][c] != key)
				or (r < row_count - 2 and quad_keys[r + 1][c] != key)
				or (c > 0 and quad_keys[r][c - 1] != key)
				or (c < col_count - 2 and quad_keys[r][c + 1] != key)
			)
			color.a = 0.55 if is_boundary else 1.0

			var quad_positions: PackedVector3Array = [positions[i00], positions[i10], positions[i11], positions[i01]]
			var quad_normals: PackedVector3Array = [normals[i00], normals[i10], normals[i11], normals[i01]]
			var quad_uv2s: PackedVector2Array = [uv2s[i00], uv2s[i10], uv2s[i11], uv2s[i01]]
			buf["positions"].append_array(quad_positions)
			buf["normals"].append_array(quad_normals)
			buf["uvs"].append_array(_quad_uv_corners(r, c))
			buf["uv2s"].append_array(quad_uv2s)
			buf["colors"].append_array(PackedColorArray([color, color, color, color]))
			buf["indices"].append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

	var keys := buffers.keys()
	keys.sort()
	for key in keys:
		var buf: Dictionary = buffers[key]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf["positions"]
		arrays[Mesh.ARRAY_NORMAL] = buf["normals"]
		arrays[Mesh.ARRAY_TEX_UV] = buf["uvs"]
		arrays[Mesh.ARRAY_TEX_UV2] = buf["uv2s"]
		arrays[Mesh.ARRAY_COLOR] = buf["colors"]
		arrays[Mesh.ARRAY_INDEX] = buf["indices"]
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		var mat := StandardMaterial3D.new()
		if key != -1:
			mat.albedo_texture = texture_lookup[key]
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if ao_texture != null:
			mat.ao_enabled = true
			mat.ao_texture = ao_texture
			mat.ao_light_affect = 1.0
			mat.ao_on_uv2 = true
		array_mesh.surface_set_material(array_mesh.get_surface_count() - 1, mat)

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
