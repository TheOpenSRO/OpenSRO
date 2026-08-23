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
## project doesn't have `tile2d.ifo` or its referenced ground textures, so
## rather than fabricate a texture lookup, _terrain_color() turns the real
## texture ID into real, data-driven vertex-color variation (a natural
## green/brown hue spread, not a claim about what any specific ID's real
## texture looks like) -- real signal, not a texture, but real ground
## variation instead of one flat color. The real 11-byte-vertex file
## class's Extra bytes don't have a confirmed field layout beyond height,
## so the same decode is applied best-effort (the leading 2 bytes exist in
## both real shapes) rather than treated as a wholly different case.

const GRID_WIDTH := 17

## World-space spacing between adjacent vertices. Real, confirmed value --
## see docs/protocol/MAPM_FORMAT.md's real loader-function findings for
## the full derivation: a whole real region is a real 6x6 grid of 17-wide
## blocks sharing edge vertices (6x16+1 = 97 unique vertices per side), and
## the real, independently-confirmed per-region world size (1920.0 units,
## from CRegionManagerBody) divided by 96 gives exactly 20.0.
const TILE_SIZE := 20.0

## Turns a real per-vertex Extra byte array into real, data-driven vertex
## color -- see this file's top comment. Uses the real confirmed
## TextureInfo uint16's low 10 bits (the real texture ID field) when at
## least 2 Extra bytes are available; falls back to a fixed mid-tone
## otherwise.
static func _vertex_color(extra: PackedByteArray) -> Color:
	if extra.size() < 2:
		return Color(0.45, 0.5, 0.32)
	var tex_info := extra.decode_u16(0)
	var id := tex_info & 0x3ff # real 10-bit TextureInfo.ID field
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

	return _build_mesh_from_cells(grid, full_size, full_size)

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
			var extra: PackedByteArray = cells[r][c][1]
			colors[r * col_count + c] = _vertex_color(extra)

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
