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
## (e.g. no SRREVAMP_MAP_PK2_PATH set) or as a fallback per-quad surface.

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
## isn't available (SRREVAMP_MAP_PK2_PATH unset, or a genuinely-missing
## real texture file) instead of pretending a color choice represents
## anything real.

## Real, honest "no real texture available" color -- see this file's
## comment above. Deliberately flat and uniform (not per-type or
## per-ID varied) so it reads as "unknown," not as a guess dressed up as
## real ground variety.
const UNKNOWN_TILE_COLOR := Color(0.5, 0.5, 0.5)

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
	var bands_per_side := MapmReader.BLOCKS_PER_SIDE
	if region.blocks.size() != bands_per_side * bands_per_side:
		push_error("MapmTerrainBuilder: region has %d blocks, want %d" % [region.blocks.size(), bands_per_side * bands_per_side])
		return null
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid := _full_region_cells(region, bands_per_side, full_size)
	return _build_mesh_from_cells(grid, full_size, full_size)

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
static func build_full_region_mesh_textured(region: MapmReader.ParsedRegion, texture_lookup: Dictionary, ao_texture: Texture2D = null) -> ArrayMesh:
	var bands_per_side := MapmReader.BLOCKS_PER_SIDE
	if region.blocks.size() != bands_per_side * bands_per_side:
		push_error("MapmTerrainBuilder: region has %d blocks, want %d" % [region.blocks.size(), bands_per_side * bands_per_side])
		return null
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid := _full_region_cells(region, bands_per_side, full_size)
	return _build_textured_mesh_from_cells(grid, full_size, full_size, texture_lookup, ao_texture)

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

## The real, confirmed-present 6-bit "Scale" field packed into the same
## TextureInfo u16 as the texture ID (see docs/protocol/MAPM_FORMAT.md and
## the public JellyBitz/srodevs-docs jmxvmapm.md ImHex pattern, which names
## this exact field "Scale" at bits 10-15). This project doesn't have an
## independently-confirmed formula for what a given real Scale value means
## in world units, but real sampled data (2026-09-02, server/cmd's ad hoc
## scaleprobe_scratch, deleted after use) found every real value observed
## across several real regions is an exact multiple of 8 (0, 8, 16, 24, 32)
## -- never an arbitrary 0-63 value -- strongly suggesting only the top 3
## bits actually vary and the field is a discrete tiling *level*, not a raw
## multiplier. Interpreted here as a real per-quad texture-repeat doubling:
## level = scale >> 3, repeat multiplier = 2^level. A quad with scale=0
## (repeat x1) therefore tiles its real texture exactly once across the
## quad, which is what real textures appear to be authored for -- see
## BASE_TILE_REPEAT's own comment.
static func _resolve_texture_scale(extra: PackedByteArray) -> int:
	if extra.size() < 2:
		return 0
	return extra.decode_u16(0) >> 10

## Real ground textures tile per quad according to the real `Scale` field
## packed alongside the texture ID (see _resolve_texture_scale).
##
## **Corrected 2026-09-02** (see docs/WORLD_ISSUES.md's fifty-third round).
## This used to be `BASE_TILE_REPEAT (4.0) * 2^level`, where the 4.0 was an
## openly-invented constant added on the theory that real ground textures
## are small high-frequency patterns needing extra repeats. A real
## side-by-side render disproved that: with the multiplier in place a real
## rock formation rendered as a pale crosshatched moire blur and the grass
## carried visible interference patterning, while dropping it resolved the
## same rock into clean, readable stone and smoothed the grass. Real
## textures are authored for roughly one repeat per real quad, so the real
## Scale field alone drives tiling now and no invented factor remains:
## a real scale level of 0 (which is every vertex in real region 98/168)
## means exactly one repeat.
const BASE_TILE_REPEAT := 1.0


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
static func _quad_uv_corners(r: int, c: int, repeat: float = 1.0) -> PackedVector2Array:
	var base: Array[Vector2] = [Vector2(0, 0), Vector2(repeat, 0), Vector2(repeat, repeat), Vector2(0, repeat)]
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
static func _build_textured_mesh_from_cells(cells: Array, row_count: int, col_count: int, texture_lookup: Dictionary, ao_texture: Texture2D) -> ArrayMesh:
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
			var vlevel: int = _resolve_texture_scale(vextra) >> 3
			vertex_repeats[r][c] = BASE_TILE_REPEAT * pow(2.0, float(vlevel))

	# Base surface: one continuous mesh over the whole grid, colored by the
	# real flat-color fallback. Real textured passes are drawn over it.
	var base_colors := PackedColorArray()
	base_colors.resize(positions.size())
	for i in range(base_colors.size()):
		base_colors[i] = _vertex_color()

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
			buf["colors"].append(Color(tint.r, tint.g, tint.b, alphas[i]))
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

			var dom_repeat := BASE_TILE_REPEAT
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
				var repeat := BASE_TILE_REPEAT
				for i in range(4):
					if vertex_keys[corner_r[i]][corner_c[i]] == k:
						alphas[i] = 1.0
						repeat = vertex_repeats[corner_r[i]][corner_c[i]]
				if not blend_buffers.has(k):
					blend_buffers[k] = new_buffer.call()
				emit.call(blend_buffers[k], r, c, idx, alphas, repeat, Color.WHITE)

	var add_surface := func(key: int, buf: Dictionary, is_blend: bool) -> void:
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
		if is_blend:
			# Only the feathered neighbour overlays are transparent; a
			# quad's own texture is opaque (see this function's doc
			# comment). depth_draw_disabled keeps these coplanar overlays
			# from fighting the opaque pass they sit exactly on top of.
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		if ao_texture != null:
			mat.ao_enabled = true
			mat.ao_texture = ao_texture
			mat.ao_light_affect = 1.0
			mat.ao_on_uv2 = true
		array_mesh.surface_set_material(array_mesh.get_surface_count() - 1, mat)

	var keys := buffers.keys()
	keys.sort()
	for key in keys:
		add_surface.call(key, buffers[key], false)

	# Blend overlays last, so they render over every opaque surface above.
	var blend_keys := blend_buffers.keys()
	blend_keys.sort()
	for key in blend_keys:
		add_surface.call(key, blend_buffers[key], true)

	return array_mesh

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
