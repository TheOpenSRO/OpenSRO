extends RefCounted
class_name MapmTerrainBuilder

## Builds a real, renderable Godot terrain mesh from a parsed .m region
## (MapmReader.ParsedRegion) -- the piece that turns real per-tile height
## data into an actual triangulated ground surface instead of the flat
## placeholder box World3D.tscn ships with.
##
## GRID_WIDTH (17) is a real, mechanistically confirmed constant, not a
## guess: every Shape-A tile's raw Extra bytes carry a per-tile "column"
## uint16 (offset 1-2 of the 11-byte record) that increments by a fixed
## ~4096 step and wraps back to 0 after exactly 17 distinct values in every
## real file checked (confirmed by direct byte inspection of a real 0/0.m,
## not inferred) -- this also matches the T=17 DFT periodicity signal
## already recorded in docs/protocol/MAPM_FORMAT.md. _column_index() below
## decodes that field directly.
##
## What ISN'T confirmed yet: how successive rows/patches are laid out
## relative to each other across the whole file (there's an analogous
## "row"-shaped field that cycles the same way *within* a run of tiles, but
## resets on an irregular schedule across the full file -- not a clean
## single global grid, so it isn't decoded here). Rather than guess at that
## unresolved structure, rows are assigned by real tile order in the file:
## a new row starts every time the real decoded column index wraps back
## down (see _group_into_rows) -- every tile still gets its own real,
## confirmed column and its real height, just grouped into rows by that
## real wrap point rather than a decoded row field. This produces real,
## correctly-shaped terrain within each 17-wide strip; it does not claim to
## place those strips at their true relative world position (see
## docs/protocol/MAPM_FORMAT.md for the open question).
##
## Only Shape-A tiles carry a decoded column field -- Shape-B's two leading
## bytes have no confirmed structure yet (see MAPM_FORMAT.md), so Shape-B
## regions fall back to the same sequential-order column assignment as the
## row axis.
##
## Vertex color: Shape-A's first Extra byte is a real, confirmed-to-exist
## per-tile value (200+ distinct values seen across real files -- see
## MAPM_FORMAT.md) that plausibly encodes a texture/terrain-type index or
## blend weight, but no confirmed mapping from that byte to an actual real
## ground texture exists (checked: Map.pk2 carries no per-region texture
## file, and the real terrain pixel shaders found alongside this project's
## other RE work sample one continuous "terrain color" texture, not a
## tile-type lookup -- so building a fabricated ID-to-texture table isn't
## honest). Rather than leave that real per-tile byte completely unused, or
## invent a texture system this project can't confirm, _terrain_color()
## turns it into real, data-driven vertex-color variation (a natural
## green/brown hue spread, not a claim about what any specific value
## "means") -- real signal, not a texture, but real ground variation
## instead of one flat color.

const GRID_WIDTH := 17

## World-space spacing between adjacent tiles. **Real, confirmed value
## (2026-08-23), superseding an earlier same-day fix that assumed the wrong
## structure** -- see docs/protocol/MAPM_FORMAT.md's real loader-function
## findings for the full derivation. That earlier fix set this to
## `1920.0 / (GRID_WIDTH - 1) = 120.0`, assuming `GRID_WIDTH` (17) columns
## span one *whole* real region. Decompiling the real client loader
## functions (`MapLoader.cpp`/`MapCallBack.cpp`, found the same day) showed
## a real 6x6 outer sub-patch structure with a real 289 (17x17) inner
## bound: **one real region is a 6x6 grid of 17-wide sub-patches sharing
## edge vertices** (6x16+1 = 97 unique vertices per side, the classic
## public "97x97 terrain grid" convention this project's own earlier DFT
## investigation found real evidence for and then wrongly retracted).
## `1920.0 / 96 = 20.0` exactly -- confirming `GRID_WIDTH` spans one
## *sub-patch*, not a whole region, and TILE_SIZE is real, confirmed 20.0 --
## coincidentally the exact value this project's very first, purely
## empirical guess already used, now confirmed for a real reason instead of
## just "looked reasonable." REGION_SPAN (World3D.gd) no longer derives
## from this constant -- it's the independently-confirmed real 1920.0
## region size, unrelated to how many *sub-patches* get rendered inside
## one region (see World3D.gd's SUBPATCH_SPAN for how that gap gets filled).
const TILE_SIZE := 20.0

## Decodes a Shape-A tile's real per-tile column index (0..GRID_WIDTH-1)
## from its raw Extra bytes -- see this file's top comment. Extra[1:3] is
## the real uint16 field (little-endian), confirmed to take exactly 17
## evenly-spaced values across its full uint16 range in every real Shape-A
## file checked. Requires the full 7-byte Shape-A Extra length (not just
## enough bytes to index into) -- Shape-B's Extra is only 3 bytes and its
## leading bytes have no confirmed meaning, so a shorter Extra always
## falls back to positional order rather than misreading those bytes as a
## column field.
static func _column_index(tile: MapmReader.Tile) -> int:
	if tile.extra.size() < 7:
		return -1
	var raw := tile.extra.decode_u16(1)
	var col := roundi(raw * (GRID_WIDTH - 1.0) / 65535.0)
	return clampi(col, 0, GRID_WIDTH - 1)

## Decodes Shape-A's real per-tile terrain-type/blend-weight byte (Extra[0]
## -- see this file's top comment). Returns -1 for anything shorter (e.g. a
## Shape-B tile), same convention as _column_index.
static func _terrain_type(tile: MapmReader.Tile) -> int:
	if tile.extra.size() < 7:
		return -1
	return tile.extra[0]

## Turns a real terrain-type byte into a real-data-driven (not fabricated)
## ground color -- a green/brown hue spread across the byte's real range,
## not a claim about what any specific value represents (see top comment).
## -1 (no real byte available) gets a fixed mid-tone fallback.
static func _terrain_color(terrain_type: int) -> Color:
	if terrain_type == -1:
		return Color(0.45, 0.5, 0.32)
	var t := terrain_type / 255.0
	# Hue sweeps a natural green-to-brown arc (0.30 = green, 0.08 = brown)
	# rather than the full rainbow, so real variation reads as ground
	# rather than as an arbitrary rainbow gradient.
	var hue := lerpf(0.30, 0.08, t)
	return Color.from_hsv(hue, 0.45, 0.55)

## Groups region's tiles into GRID_WIDTH-wide rows using each tile's real
## decoded column index (see _column_index) rather than blindly trusting
## positional order -- a new row starts whenever the decoded column resets
## to a value at or below the previous tile's column, or a row already has
## GRID_WIDTH tiles. This self-corrects if the resync scan documented in
## MAPM_FORMAT.md ever drops a tile mid-row (confirmed to happen near EOF
## on real files) instead of silently shifting every later column.
## Positional order is used as a fallback for Shape-B tiles, which have no
## confirmed column field.
## Only rows with all GRID_WIDTH columns actually filled by a real tile are
## kept -- an incomplete row (from data loss, not from a design choice) is
## dropped rather than padded with a guessed value.
static func _group_into_rows(tiles: Array) -> Array:
	var rows := []
	var current: Array = []
	current.resize(GRID_WIDTH)
	current.fill(null)
	var prev_col := -1
	var pos_in_row := 0

	for tile in tiles:
		var col := _column_index(tile)
		var starts_new_row := (col <= prev_col) if col != -1 else (pos_in_row >= GRID_WIDTH)

		if starts_new_row:
			rows.append(current)
			current = []
			current.resize(GRID_WIDTH)
			current.fill(null)
			pos_in_row = 0

		var effective_col := col if col != -1 else pos_in_row
		if effective_col >= 0 and effective_col < GRID_WIDTH:
			current[effective_col] = [tile.height, _terrain_type(tile)]
		prev_col = col
		pos_in_row += 1

	rows.append(current)
	return rows.filter(func(row): return not row.has(null))

## Builds a triangulated ArrayMesh from region's real tile heights, grouped
## into real rows via _group_into_rows. Returns null if fewer than 2
## complete rows could be recovered (not enough to form a single triangle
## strip).
##
## max_rows caps how many of the file's real rows get built into the mesh
## (-1, the default, keeps every row -- the original behavior). Without a
## cap, a real region file's rows are simply chained in raw file order (see
## this file's top comment: the true relative layout of rows beyond the
## confirmed 17-wide column cycling isn't known), which produces an
## extremely elongated ribbon rather than anything resembling a real
## region's actual footprint -- confirmed live (2026-08-22) against a real
## 100/100.m, which parsed to 777 rows (a ~320x15,500 unit strip). Capping
## at GRID_WIDTH rows (see World3D.gd's real usage) turns that ribbon into
## an actual square patch using only the same real, already-confirmed
## per-tile data -- a practical reshaping for something walkable and
## multi-region-tileable, not a new claim about the real layout.
static func build_mesh(region: MapmReader.ParsedRegion, max_rows: int = -1) -> ArrayMesh:
	var cells: Array = _group_into_rows(region.tiles)
	if max_rows > 0 and cells.size() > max_rows:
		cells = cells.slice(0, max_rows)
	var row_count := cells.size()
	if row_count < 2:
		push_error("MapmTerrainBuilder: only %d complete row(s) of %d tiles -- need at least 2" % [row_count, GRID_WIDTH])
		return null
	return _build_mesh_from_cells(cells, row_count)

## Real, precisely-confirmed (2026-08-23) full-region assembly -- see
## docs/protocol/MAPM_FORMAT.md's loader-function findings. **Corrects a
## same-day mistake in this function's first version**: that version only
## stitched sub-patches along one axis (the "row-band" loop, `iStack_205c`
## in the real decompiled code), treating a region as a single 17-wide,
## 97-row-long strip. Decoding the real destination-buffer offset formula
## precisely (`(iStack_205c*0x10 + puStack_2070*0x610 + fStack_206c*0x61 +
## fStack_2078) * 0xc`, from the real `MapLoader.cpp` decompilation) showed
## it factors exactly as `(band_row*16 + local_row)*97 + (band_col*16 +
## local_col)` for a 97-wide row-major grid -- i.e. there are real **two**
## nested 6-iteration band loops (`puStack_2070` outer, `iStack_205c`
## inner), one per axis, not one. A whole region is therefore a real 6x6
## grid of 17x17 sub-patches covering **both** width and depth (97x97
## unique vertices total, 36 sub-patches, `6x6x289 = 10404` real tiles),
## not a 97-long single-file strip.
##
## Sub-patches arrive in the real file in nested order (all 6 column-bands
## of row-band 0, then all 6 of row-band 1, ...) -- confirmed via the same
## real, non-reordering buffered reader (`FUN_00410f90`) as the row-only
## version. Consecutive sub-patches share their boundary row *and* column
## (stride 16, not 17, on both axes), so the *later* sub-patch's copy wins
## at both kinds of shared boundary, matching the real client exactly.
##
## Falls back to fewer output row-bands if a region's real data runs out
## before a row-band's own 6 sub-patches are all available -- an honest
## partial-data case (a partially-consumed row-band is dropped whole rather
## than left with holes). Returns null if fewer than 2 output rows result.
static func build_full_region_mesh(region: MapmReader.ParsedRegion, bands_per_side: int = 6) -> ArrayMesh:
	var raw_rows: Array = _group_into_rows(region.tiles)
	var full_size := bands_per_side * (GRID_WIDTH - 1) + 1
	var grid: Array = []
	for _i in range(full_size):
		var row_arr: Array = []
		row_arr.resize(full_size)
		grid.append(row_arr)

	var consumed := 0
	var completed_row_bands := 0
	for band_row in range(bands_per_side):
		var row_band_complete := true
		for band_col in range(bands_per_side):
			if raw_rows.size() < consumed + GRID_WIDTH:
				row_band_complete = false
				break
			for local_r in range(GRID_WIDTH):
				var src_row: Array = raw_rows[consumed + local_r]
				var dest_r := band_row * (GRID_WIDTH - 1) + local_r
				for local_c in range(GRID_WIDTH):
					grid[dest_r][band_col * (GRID_WIDTH - 1) + local_c] = src_row[local_c]
			consumed += GRID_WIDTH
		if not row_band_complete:
			break
		completed_row_bands += 1

	var row_count := 0 if completed_row_bands == 0 else completed_row_bands * (GRID_WIDTH - 1) + 1
	if row_count < 2:
		push_error("MapmTerrainBuilder: only %d real full-region row(s) recovered -- need at least 2" % row_count)
		return null
	var cells: Array = grid.slice(0, row_count)
	return _build_mesh_from_cells(cells, row_count, full_size)

## Shared triangulation/vertex-buffer logic behind both build_mesh and
## build_full_region_mesh -- cells is a real per-row array (each row
## col_count [height, terrain_type] pairs, see _group_into_rows/
## build_full_region_mesh), row_count/col_count are cells.size()/cells[0]
## .size() (passed separately since callers may have already validated/
## trimmed them). col_count defaults to GRID_WIDTH for build_mesh's single
## fixed-width-strip case.
static func _build_mesh_from_cells(cells: Array, row_count: int, col_count: int = GRID_WIDTH) -> ArrayMesh:
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
			var terrain_type: int = cells[r][c][1]
			colors[r * col_count + c] = _terrain_color(terrain_type)

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
