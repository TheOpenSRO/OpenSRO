extends SceneTree

## Exercises MapmTerrainBuilder against synthetic MapmReader.Block/Region
## data (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/mapm_terrain_builder_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

var GW := 17 # MapmTerrainBuilder.GRID_WIDTH, kept local for brevity

## Builds one real-shaped Block: height_fn(local_row, local_col) for each
## of the block's real GW x GW vertices, and an optional fixed TextureInfo
## uint16 (real confirmed field for the 7-byte-vertex file class) embedded
## in every vertex's Extra bytes.
func _make_block(height_fn: Callable, tex_info: int = -1) -> MapmReader.Block:
	var block := MapmReader.Block.new()
	block.vertices.resize(GW * GW)
	for r in range(GW):
		for c in range(GW):
			var v := MapmReader.Vertex.new()
			v.height = height_fn.call(r, c)
			var extra := PackedByteArray()
			extra.resize(3) # real 7-byte-vertex Extra length (TextureInfo u16 + Brightness byte)
			if tex_info != -1:
				extra.encode_u16(0, tex_info)
			v.extra = extra
			block.vertices[r * GW + c] = v
	return block

## Builds a full, real-shaped 6x6-block region. block_fn(band_row, band_col)
## returns the Block for that real nested-order slot.
func _make_region(block_fn: Callable) -> MapmReader.ParsedRegion:
	var r := MapmReader.ParsedRegion.new()
	r.version = "1000"
	for band_row in range(MapmReader.BLOCKS_PER_SIDE):
		for band_col in range(MapmReader.BLOCKS_PER_SIDE):
			r.blocks.append(block_fn.call(band_row, band_col))
	return r

func _init() -> void:
	# build_mesh: a single real block.
	var region1 := MapmReader.ParsedRegion.new()
	region1.version = "1000"
	region1.blocks.append(_make_block(func(r, c): return float(r * 10 + c)))
	var mesh := MapmTerrainBuilder.build_mesh(region1, 0)
	_check(mesh != null, "builds a mesh from a single real block")
	if mesh != null:
		var arrays := mesh.surface_get_arrays(0)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		_check(positions.size() == GW * GW, "%d vertices (got %d)" % [GW * GW, positions.size()])
		_check(indices.size() == 2 * 3 * (GW - 1) * (GW - 1), "correct index count (got %d)" % indices.size())

		var v00: Vector3 = positions[0]
		_check(v00.is_equal_approx(Vector3(0, 0, 0)), "row0 col0 at origin with real height 0 (got %s)" % v00)
		var v0_last: Vector3 = positions[GW - 1]
		_check(v0_last.is_equal_approx(Vector3((GW - 1) * MapmTerrainBuilder.TILE_SIZE, GW - 1, 0)), "row0 col16 real height at real column x (got %s)" % v0_last)
		var v1_0: Vector3 = positions[GW]
		_check(v1_0.is_equal_approx(Vector3(0, 10, MapmTerrainBuilder.TILE_SIZE)), "row1 col0 real height at row-wrapped z (got %s)" % v1_0)

	_check(MapmTerrainBuilder.build_mesh(region1, 5) == null, "rejects an out-of-range block index")

	# Vertex colors: driven by the real confirmed TextureInfo field,
	# distinct values should produce distinct (not fabricated-identical)
	# colors, and no Extra bytes at all should fall back to the fixed
	# mid-tone.
	var region2 := MapmReader.ParsedRegion.new()
	region2.version = "1000"
	region2.blocks.append(_make_block(func(r, c): return float(c), 100))
	var mesh_a := MapmTerrainBuilder.build_mesh(region2, 0)
	var region3 := MapmReader.ParsedRegion.new()
	region3.version = "1000"
	region3.blocks.append(_make_block(func(r, c): return float(c), 900))
	var mesh_b := MapmTerrainBuilder.build_mesh(region3, 0)
	_check(mesh_a != null and mesh_b != null, "builds meshes from texture-info-carrying blocks")
	if mesh_a != null and mesh_b != null:
		var color_a: Color = mesh_a.surface_get_arrays(0)[Mesh.ARRAY_COLOR][0]
		var color_b: Color = mesh_b.surface_get_arrays(0)[Mesh.ARRAY_COLOR][0]
		_check(not color_a.is_equal_approx(color_b), "distinct real TextureInfo IDs produce distinct colors")

	var region_empty_extra := MapmReader.ParsedRegion.new()
	region_empty_extra.version = "1000"
	var empty_block := MapmReader.Block.new()
	empty_block.vertices.resize(GW * GW)
	for i in range(GW * GW):
		var v := MapmReader.Vertex.new()
		v.height = 0.0
		v.extra = PackedByteArray()
		empty_block.vertices[i] = v
	region_empty_extra.blocks.append(empty_block)
	var mesh_fallback := MapmTerrainBuilder.build_mesh(region_empty_extra, 0)
	_check(mesh_fallback != null, "builds a mesh from vertices with empty Extra")
	if mesh_fallback != null:
		# A generous tolerance: ArrayMesh vertex colors are stored 8-bit
		# per channel, so a small quantization error vs. the exact literal
		# is expected and not a real mismatch.
		var fallback_color: Color = mesh_fallback.surface_get_arrays(0)[Mesh.ARRAY_COLOR][0]
		var close := absf(fallback_color.r - 0.45) < 0.01 and absf(fallback_color.g - 0.5) < 0.01 and absf(fallback_color.b - 0.32) < 0.01
		_check(close, "empty Extra falls back to the fixed mid-tone (got %s)" % fallback_color)

	# build_full_region_mesh: real 6x6-block stitching. Every block is flat
	# (height 0) except (0,0) and (1,1), whose heights are
	# `band_row*100 + band_col*10 + local_row` so every relevant band's
	# real contribution is distinguishable at every output vertex.
	var region_full := _make_region(func(band_row, band_col):
		if (band_row == 0 and band_col == 0) or (band_row == 1 and band_col == 1):
			return _make_block(func(r, c): return float(band_row * 100 + band_col * 10 + r))
		return _make_block(func(r, c): return 0.0))
	var band_mesh := MapmTerrainBuilder.build_full_region_mesh(region_full)
	_check(band_mesh != null, "builds a full-region mesh from a real 6x6 block grid")
	if band_mesh != null:
		var band_positions: PackedVector3Array = band_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var expected_size := MapmReader.BLOCKS_PER_SIDE * (GW - 1) + 1 # 97
		_check(band_positions.size() == expected_size * expected_size, "6x6 blocks stitch to a %dx%d grid (got %d vertices)" % [expected_size, expected_size, band_positions.size()])

		# Block (0,0)'s own untouched first row/col -- height 0.
		_check(band_positions[0].y == 0.0, "block (0,0)'s own first row/col is untouched (got %s, want 0.0)" % band_positions[0].y)
		# Block (1,1)'s own interior (local row/col 8, away from any shared
		# boundary another block could overwrite) -- height 1*100+1*10+8=118.
		var dest_r := 1 * (GW - 1) + 8
		var dest_c := 1 * (GW - 1) + 8
		var interior_h: float = band_positions[dest_r * expected_size + dest_c].y
		_check(interior_h == 118.0, "block (1,1)'s own interior is untouched (got %s, want 118.0)" % interior_h)

	_check(MapmTerrainBuilder.build_full_region_mesh(MapmReader.ParsedRegion.new()) == null, "rejects a region without a real 6x6 block grid")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
