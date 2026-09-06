extends SceneTree

## Exercises NvmWater against synthetic regions (never real game data), run
## headless:
## `godot4 --headless --path client --script res://scripts/nvm/nvm_water_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _region(types: Array, heights: Array) -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.plane_types = PackedByteArray(types)
	r.plane_heights = PackedFloat32Array(heights)
	if types.size() == NvmReader.PLANE_COUNT:
		for _i in range(NvmReader.TILE_COUNT):
			r.tiles.append(NvmReader.Tile.new())
		# Shape now comes from the real tiles, so a test that says "this plane
		# cell is water" has to put real water tiles in it.
		for row in range(NvmReader.PLANE_MAP_SIDE):
			for col in range(NvmReader.PLANE_MAP_SIDE):
				if types[row * NvmReader.PLANE_MAP_SIDE + col] == NvmWater.PLANE_TYPE_WATER:
					_flood_cell(r, col, row)
	return r

func _flat(type_value: int, height: float) -> NvmReader.ParsedRegion:
	var types: Array = []
	var heights: Array = []
	for _i in range(NvmReader.PLANE_COUNT):
		types.append(type_value)
		heights.append(height)
	return _region(types, heights)


## A synthetic tile2d.ifo table: id 0 is dry ground, id 1 is real water.
func _tile_table() -> TileIndexReader.Table:
	var t := TileIndexReader.Table.new()
	for i in range(2):
		var e := TileIndexReader.Entry.new()
		e.id = i
		e.type = TileIndexReader.TileType.WATER if i == 1 else TileIndexReader.TileType.GRASS
		t.entries.append(e)
	return t

## Marks every real tile inside plane cell (col,row) as water, so a test can
## say "this whole plane cell is covered in real water tiles".
func _flood_cell(region: NvmReader.ParsedRegion, col: int, row: int) -> void:
	var tside := NvmReader.TILE_MAP_SIDE
	var per := tside / NvmReader.PLANE_MAP_SIDE
	for r in range(row * per, (row + 1) * per):
		for c in range(col * per, (col + 1) * per):
			region.tiles[r * tside + c].texture_id = 1

func _initialize() -> void:
	_check(NvmWater.PLANE_TYPE_WATER == 1, "water is the real plane type 1")
	_check(absf(NvmWater.PLANE_CELL_SPAN - 320.0) < 0.001,
		"a real plane cell spans 320 units (got %s)" % NvmWater.PLANE_CELL_SPAN)

	# A region with no water at all builds nothing rather than an empty node.
	var dry := _flat(0, -20.0)
	_check(not NvmWater.has_water(dry), "a dry region reports no water")
	_check(NvmWater.build_water_mesh(dry, _tile_table()) == null, "a dry region builds no mesh")

	# One water cell -> one flat quad at that cell's own plane height.
	var types: Array = []
	var heights: Array = []
	for i in range(NvmReader.PLANE_COUNT):
		types.append(0)
		heights.append(99.0)
	# row 1, col 2
	types[1 * NvmReader.PLANE_MAP_SIDE + 2] = 1
	heights[1 * NvmReader.PLANE_MAP_SIDE + 2] = -3.0
	var one := _region(types, heights)
	_check(NvmWater.has_water(one), "a region with one water cell reports water")
	var mesh := NvmWater.build_water_mesh(one, _tile_table())
	_check(mesh != null, "one water cell builds a mesh")
	if mesh != null:
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var per_cell := (NvmReader.TILE_MAP_SIDE / NvmReader.PLANE_MAP_SIDE) ** 2
		_check(verts.size() == 4 * per_cell,
			"a flooded plane cell is one quad per real water tile (got %d verts)" % verts.size())
		var min_x := INF
		var max_x := -INF
		var min_z := INF
		var max_z := -INF
		for v in verts:
			_check(absf(v.y - (-3.0)) < 0.001, "every vertex sits at the real plane height")
			min_x = minf(min_x, v.x)
			max_x = maxf(max_x, v.x)
			min_z = minf(min_z, v.z)
			max_z = maxf(max_z, v.z)
		# col 2 -> x 640..960, row 1 -> z 320..640 (col is X, row is Z)
		_check(absf(min_x - 640.0) < 0.001 and absf(max_x - 960.0) < 0.001,
			"column maps to X (got %s..%s)" % [min_x, max_x])
		_check(absf(min_z - 320.0) < 0.001 and absf(max_z - 640.0) < 0.001,
			"row maps to Z (got %s..%s)" % [min_z, max_z])

	# Cells keep their own heights rather than being flattened together.
	var two_types: Array = []
	var two_heights: Array = []
	for i in range(NvmReader.PLANE_COUNT):
		two_types.append(0)
		two_heights.append(0.0)
	two_types[0] = 1
	two_heights[0] = -3.0
	two_types[1] = 1
	two_heights[1] = -20.0
	var two := _region(two_types, two_heights)
	var two_mesh := NvmWater.build_water_mesh(two, _tile_table())
	_check(two_mesh != null, "two water cells build a mesh")
	if two_mesh != null:
		var verts2: PackedVector3Array = two_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var per_cell2 := (NvmReader.TILE_MAP_SIDE / NvmReader.PLANE_MAP_SIDE) ** 2
		_check(verts2.size() == 8 * per_cell2,
			"two flooded cells contribute both (got %d verts)" % verts2.size())
		var ys := {}
		for v in verts2:
			ys[snappedf(v.y, 0.01)] = true
		_check(ys.has(-3.0) and ys.has(-20.0),
			"each real body of water keeps its own level (got %s)" % [ys.keys()])

	# A whole-region lake is every cell, and the surface stays flat.
	var lake := _flat(1, -5.0)
	var lake_mesh := NvmWater.build_water_mesh(lake, _tile_table())
	_check(lake_mesh != null, "an all-water region builds a mesh")
	if lake_mesh != null:
		var lv: PackedVector3Array = lake_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_check(lv.size() == NvmReader.TILE_COUNT * 4,
			"an all-water region is one quad per real tile (got %d verts)" % lv.size())
		var flat := true
		for v in lv:
			if absf(v.y - (-5.0)) > 0.001:
				flat = false
		_check(flat, "the whole surface is flat, not following the ground")

	_check(NvmWater.build_water_mesh(null, _tile_table()) == null, "tolerates a null region")
	_check(not NvmWater.has_water(null), "a null region reports no water")
	var truncated := _region([1, 0], [0.0, 0.0])
	_check(NvmWater.build_water_mesh(truncated, _tile_table()) == null, "rejects a short plane map")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
