extends SceneTree

## Exercises MapmTerrainBuilder against synthetic tile data shaped exactly
## like real Shape-A .m records (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/mapm_terrain_builder_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Builds one synthetic Shape-A-shaped tile: extra[0] = terrain byte,
## extra[1:3] = the real column field encoding col (0..16), extra[3:7] =
## zeroed (unused row field + trailing bytes).
func _make_tile(col: int, height: float, terrain_type: int = -1) -> MapmReader.Tile:
	var t := MapmReader.Tile.new()
	t.height = height
	var extra := PackedByteArray()
	extra.resize(7)
	if terrain_type != -1:
		extra[0] = terrain_type
	var raw := roundi(col * 65535.0 / 16.0)
	extra.encode_u16(1, raw)
	t.extra = extra
	return t

func _make_region(rows: int, height_fn: Callable) -> MapmReader.ParsedRegion:
	var r := MapmReader.ParsedRegion.new()
	r.version = "1000"
	for row in range(rows):
		for col in range(MapmTerrainBuilder.GRID_WIDTH):
			r.tiles.append(_make_tile(col, height_fn.call(row, col)))
	return r

func _init() -> void:
	# Two full rows -- the minimum needed for one strip of triangles.
	var region := _make_region(2, func(row, col): return float(row * 10 + col))
	var mesh := MapmTerrainBuilder.build_mesh(region)
	_check(mesh != null, "builds a mesh from 2 complete real-shaped rows")
	if mesh != null:
		var arrays := mesh.surface_get_arrays(0)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		_check(positions.size() == 2 * MapmTerrainBuilder.GRID_WIDTH, "34 vertices (got %d)" % positions.size())
		_check(indices.size() == 2 * 3 * (MapmTerrainBuilder.GRID_WIDTH - 1), "96 indices for a 2x17 strip (got %d)" % indices.size())

		var v00: Vector3 = positions[0]
		_check(v00.is_equal_approx(Vector3(0, 0, 0)), "row0 col0 at origin with real height 0 (got %s)" % v00)
		var v0_last: Vector3 = positions[MapmTerrainBuilder.GRID_WIDTH - 1]
		_check(v0_last.is_equal_approx(Vector3((MapmTerrainBuilder.GRID_WIDTH - 1) * MapmTerrainBuilder.TILE_SIZE, 16, 0)), "row0 col16 real height 16 at real column x (got %s)" % v0_last)
		var v1_0: Vector3 = positions[MapmTerrainBuilder.GRID_WIDTH]
		_check(v1_0.is_equal_approx(Vector3(0, 10, MapmTerrainBuilder.TILE_SIZE)), "row1 col0 real height 10 at row-wrapped z (got %s)" % v1_0)

	# Vertex colors: driven by the real per-tile terrain-type byte, distinct
	# values should produce distinct (not fabricated-identical) colors, and
	# a tile with no decodable terrain byte should fall back to the fixed
	# mid-tone.
	var colored_region := MapmReader.ParsedRegion.new()
	colored_region.version = "1000"
	for col in range(MapmTerrainBuilder.GRID_WIDTH):
		colored_region.tiles.append(_make_tile(col, float(col), col * 10))
	for col in range(MapmTerrainBuilder.GRID_WIDTH):
		colored_region.tiles.append(_make_tile(col, float(10 + col), 255 - col * 10))
	var colored_mesh := MapmTerrainBuilder.build_mesh(colored_region)
	_check(colored_mesh != null, "builds a mesh from terrain-type-carrying tiles")
	if colored_mesh != null:
		var carrays := colored_mesh.surface_get_arrays(0)
		var colors: PackedColorArray = carrays[Mesh.ARRAY_COLOR]
		_check(colors.size() == 2 * MapmTerrainBuilder.GRID_WIDTH, "vertex color array sized to match vertices (got %d)" % colors.size())
		_check(not colors[0].is_equal_approx(colors[MapmTerrainBuilder.GRID_WIDTH - 1]), "distinct real terrain-type bytes produce distinct colors")

	# A resync-dropped tile mid-row (one tile missing from row 1) should
	# leave that row incomplete and therefore dropped, not silently
	# misaligned -- only 1 complete row remains, below the 2-row minimum.
	var broken := MapmReader.ParsedRegion.new()
	broken.version = "1000"
	for col in range(MapmTerrainBuilder.GRID_WIDTH):
		broken.tiles.append(_make_tile(col, float(col)))
	for col in range(MapmTerrainBuilder.GRID_WIDTH):
		if col == 8:
			continue # simulate a resync-dropped tile
		broken.tiles.append(_make_tile(col, float(100 + col)))
	var broken_mesh := MapmTerrainBuilder.build_mesh(broken)
	_check(broken_mesh == null, "an incomplete row (resync-dropped tile) is dropped, not misaligned")

	# Shape-B-shaped tiles (extra too short for a decoded column) fall back
	# to positional order.
	var positional := MapmReader.ParsedRegion.new()
	positional.version = "1000"
	for row in range(2):
		for col in range(MapmTerrainBuilder.GRID_WIDTH):
			var t := MapmReader.Tile.new()
			t.height = float(row * 10 + col)
			t.extra = PackedByteArray([0, 0, 0]) # Shape-B-shaped: too short for _column_index
			positional.tiles.append(t)
	var positional_mesh := MapmTerrainBuilder.build_mesh(positional)
	_check(positional_mesh != null, "falls back to positional column order for Shape-B-shaped tiles")

	# max_rows caps how many real rows get built -- 5 real rows capped to 3
	# should produce exactly a 3-row mesh, not silently keep all 5.
	var tall_region := _make_region(5, func(row, col): return float(row * 10 + col))
	var capped_mesh := MapmTerrainBuilder.build_mesh(tall_region, 3)
	_check(capped_mesh != null, "builds a mesh from a capped region")
	if capped_mesh != null:
		var capped_positions: PackedVector3Array = capped_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_check(capped_positions.size() == 3 * MapmTerrainBuilder.GRID_WIDTH, "max_rows=3 caps to 3 rows (got %d vertices)" % capped_positions.size())
	var uncapped_mesh := MapmTerrainBuilder.build_mesh(tall_region)
	var uncapped_positions: PackedVector3Array = uncapped_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(uncapped_positions.size() == 5 * MapmTerrainBuilder.GRID_WIDTH, "no max_rows keeps all 5 rows (got %d vertices)" % uncapped_positions.size())

	# build_full_region_mesh: real 2x2-band stitching (using bands_per_side=2
	# instead of the real 6, to keep the synthetic fixture small). Real file
	# order is nested: band_row 0's 2 sub-patches (band_col 0, then 1),
	# then band_row 1's 2 sub-patches -- each sub-patch's height is
	# `band_row*100 + band_col*10 + local_row` so every band's real
	# contribution is distinguishable at every output vertex.
	var GW := MapmTerrainBuilder.GRID_WIDTH
	var two_by_two := MapmReader.ParsedRegion.new()
	two_by_two.version = "1000"
	for band_row in range(2):
		for band_col in range(2):
			for row in range(GW):
				for col in range(GW):
					two_by_two.tiles.append(_make_tile(col, float(band_row * 100 + band_col * 10 + row)))
	var band_mesh := MapmTerrainBuilder.build_full_region_mesh(two_by_two, 2)
	_check(band_mesh != null, "builds a full-region mesh from a 2x2 real band grid")
	if band_mesh != null:
		var band_positions: PackedVector3Array = band_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var expected_size := 2 * (GW - 1) + 1 # 33
		_check(band_positions.size() == expected_size * expected_size, "2x2 bands stitch to a %dx%d grid (got %d vertices)" % [expected_size, expected_size, band_positions.size()])

		# (row 0, col 0): band (0,0)'s own untouched corner -- height 0.
		_check(band_positions[0].y == 0.0, "band (0,0)'s own first row/col is untouched (got %s, want 0.0)" % band_positions[0].y)
		# (row 0, col 16): the shared column boundary between band_col 0 and
		# 1 within band_row 0 -- band_col 1 (height 10) should win.
		var shared_col_h: float = band_positions[16].y
		_check(shared_col_h == 10.0, "band_col 1 overwrites the shared column boundary within band_row 0 (got %s, want 10.0)" % shared_col_h)
		# (row 16, col 0): the shared row boundary between band_row 0 and 1
		# within band_col 0 -- band_row 1 (height 100) should win.
		var shared_row_h: float = band_positions[16 * expected_size].y
		_check(shared_row_h == 100.0, "band_row 1 overwrites the shared row boundary within band_col 0 (got %s, want 100.0)" % shared_row_h)
		# (row 16, col 16): the shared corner of all 4 bands -- the last one
		# consumed in nested file order, band (1,1) (height 110), should win.
		var shared_corner_h: float = band_positions[16 * expected_size + 16].y
		_check(shared_corner_h == 110.0, "band (1,1) overwrites the shared 4-way corner (got %s, want 110.0)" % shared_corner_h)
		# (row 32, col 32): band (1,1)'s own untouched far corner -- local
		# row/col 16, height 100+10+16=126.
		var far_corner_h: float = band_positions[32 * expected_size + 32].y
		_check(far_corner_h == 126.0, "band (1,1)'s own far corner is untouched (got %s, want 126.0)" % far_corner_h)

	# A partial trailing row-band (only 1 of its 2 sub-patches present) is
	# dropped whole, not left with holes -- only the first, fully complete
	# row-band's rows should survive.
	var partial_band := MapmReader.ParsedRegion.new()
	partial_band.version = "1000"
	for band_col in range(2): # band_row 0: both sub-patches present
		for row in range(GW):
			for col in range(GW):
				partial_band.tiles.append(_make_tile(col, float(band_col * 10 + row)))
	for row in range(GW): # band_row 1: only 1 of its 2 sub-patches present
		for col in range(GW):
			partial_band.tiles.append(_make_tile(col, float(100 + row)))
	var partial_mesh := MapmTerrainBuilder.build_full_region_mesh(partial_band, 2)
	_check(partial_mesh != null, "builds from a region with 1 complete row-band + 1 partial row-band")
	if partial_mesh != null:
		var partial_positions: PackedVector3Array = partial_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var expected_size := 2 * (GW - 1) + 1 # the full 2-band-wide column count, only 1 row-band tall
		_check(partial_positions.size() == GW * expected_size, "incomplete row-band dropped whole, only 1 row-band's rows kept (got %d vertices)" % partial_positions.size())

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
