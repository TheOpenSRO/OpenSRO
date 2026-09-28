extends SceneTree

## Exercises the water World3D draws, against synthetic regions (never real
## game data), run headless:
## `godot4 --headless --path client --script res://scripts/mapm/mapm_water_test.gd`
##
## The "drawn water" checks go through _drawn(), which uses MapmWater when it
## exists and otherwise the builder World3D drew with before round 627
## (NvmWater, fed the same lake as a navmesh). That keeps this file runnable
## against the older tree, which is how round 627's negative was taken: the
## same assertions, the old builder, real FAIL lines.

var _failures := 0

const MAPM_WATER := "res://scripts/mapm/mapm_water.gd"

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A .m region of 36 dry blocks (PlaneType -1), every vertex at `ground`.
func _mapm_region(ground: float) -> MapmReader.ParsedRegion:
	var r := MapmReader.ParsedRegion.new()
	for _b in range(MapmReader.BLOCK_COUNT):
		var block := MapmReader.Block.new()
		block.plane_type = -1
		block.wave_id = 0
		block.plane_height = 0.0
		for _v in range(MapmReader.VERTEX_COUNT):
			var vert := MapmReader.Vertex.new()
			vert.height = ground
			vert.extra = PackedByteArray([0, 0, 0])
			block.vertices.append(vert)
		r.blocks.append(block)
	return r

## The same lake as the old builder's input: plane cell (col, row) marked
## water (nvm type 1) at `plane`, and every navmesh tile inside it given a
## water texture, so the old builder draws its whole cell.
func _nvm_lake(col: int, row: int, plane: float) -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	var types := PackedByteArray()
	var heights := PackedFloat32Array()
	for _i in range(NvmReader.PLANE_COUNT):
		types.append(0)
		heights.append(0.0)
	types[row * NvmReader.PLANE_MAP_SIDE + col] = 1
	heights[row * NvmReader.PLANE_MAP_SIDE + col] = plane
	r.plane_types = types
	r.plane_heights = heights
	for _i in range(NvmReader.TILE_COUNT):
		r.tiles.append(NvmReader.Tile.new())
	var tside := NvmReader.TILE_MAP_SIDE
	var per := tside / NvmReader.PLANE_MAP_SIDE
	for tr in range(row * per, (row + 1) * per):
		for tc in range(col * per, (col + 1) * per):
			r.tiles[tr * tside + tc].texture_id = 1
	return r

func _tile_table() -> TileIndexReader.Table:
	var t := TileIndexReader.Table.new()
	for i in range(2):
		var e := TileIndexReader.Entry.new()
		e.id = i
		e.type = TileIndexReader.TileType.WATER if i == 1 else TileIndexReader.TileType.GRASS
		t.entries.append(e)
	return t

## The water mesh World3D would draw for this lake.
func _drawn(mapm: MapmReader.ParsedRegion, nvm: NvmReader.ParsedRegion) -> ArrayMesh:
	if ResourceLoader.exists(MAPM_WATER):
		var script: GDScript = load(MAPM_WATER)
		return script.build(mapm).water
	print("note: %s is missing -- checking NvmWater, the builder World3D drew with before round 627" % MAPM_WATER)
	return NvmWater.build_water_mesh(nvm, _tile_table())

## Up/down triangle counts by Godot's own front-face rule: Plane(a, b, c)'s
## normal is the front side. The world's z -> -z mirror leaves this as is
## (Godot flips its cull test for a negative-determinant transform).
func _facing(mesh: ArrayMesh) -> Vector2i:
	var up := 0
	var down := 0
	var arrays := mesh.surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for t in range(0, idx.size(), 3):
		var n := Plane(pos[idx[t]], pos[idx[t + 1]], pos[idx[t + 2]]).normal
		if n.y > 0.0:
			up += 1
		elif n.y < 0.0:
			down += 1
	return Vector2i(up, down)

func _initialize() -> void:
	# --- The reported lake: plane 50 over a flat bed at -30 (98/159's own
	# numbers), in block row 1, column 2.
	var mapm := _mapm_region(-30.0)
	var lake: MapmReader.Block = mapm.blocks[1 * MapmReader.BLOCKS_PER_SIDE + 2]
	lake.plane_type = 0
	lake.wave_id = 1
	lake.plane_height = 50.0
	var nvm := _nvm_lake(2, 1, 50.0)
	var mesh := _drawn(mapm, nvm)
	_check(mesh != null, "the lake builds a water mesh")
	if mesh != null:
		var f := _facing(mesh)
		_check(f.x > 0 and f.y == 0,
			"every drawn water triangle faces up, the side a player above sees (got %d up, %d down)" % [f.x, f.y])
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for v in verts:
			lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
			hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
		_check(absf(lo.y - 50.0) < 0.001 and absf(hi.y - 50.0) < 0.001,
			"the surface lies flat at the block's PlaneHeight 50 (got %s..%s)" % [lo.y, hi.y])
		_check(absf(lo.x - 640.0) < 0.001 and absf(hi.x - 960.0) < 0.001 and absf(lo.z - 320.0) < 0.001 and absf(hi.z - 640.0) < 0.001,
			"it covers the whole 320-unit block: x 640..960, z 320..640 (got %s..%s)" % [lo, hi])
		var arrays := mesh.surface_get_arrays(0)
		var colors = arrays[Mesh.ARRAY_COLOR]
		_check(colors is PackedColorArray and (colors as PackedColorArray).size() == verts.size(),
			"every vertex carries the shoreline alpha")
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var uv_hi := Vector2(-INF, -INF)
		for uv in uvs:
			uv_hi = Vector2(maxf(uv_hi.x, uv.x), maxf(uv_hi.y, uv.y))
		_check(uv_hi.is_equal_approx(Vector2(4, 4)),
			"the frame repeats 4 times across a block, 0..4 (READ _DAT_00e1b860; got max %s)" % uv_hi)

	if not ResourceLoader.exists(MAPM_WATER):
		_check(false, "MapmWater exists (the rest of this suite needs it)")
		_finish()
		return
	var W: GDScript = load(MAPM_WATER)

	# --- The shoreline rule, READ from Map::FUN_009fb280.
	_check(W.shoreline_nibble(50.0, -30.0) == 15, "80 deep is fully opaque (nibble 15)")
	_check(W.shoreline_nibble(50.0, 50.0) == 0, "ground at the surface is dry (nibble 0)")
	_check(W.shoreline_nibble(50.0, 60.0) == 0, "ground above the surface is dry")
	_check(W.shoreline_nibble(50.0, 44.0) == 3, "6 deep is nibble 3 ((50 - 44) * 0.5)")
	_check(W.shoreline_nibble(50.0, 49.0) == 0, "1 deep is 0.5, which rounds to even: 0")
	_check(W.shoreline_nibble(50.0, 47.0) == 2, "3 deep is 1.5, which rounds to even: 2")
	_check(W.shoreline_nibble(50.0, 19.0) == 15, "31 deep is 15.5, past 15: clamped to 15")
	_check(W.round_half_even(2.5) == 2 and W.round_half_even(3.5) == 4 and W.round_half_even(2.6) == 3, "x87 rounding: half to even")
	_check(absf(W.nibble_alpha(15) - 1.0) < 0.0001 and W.nibble_alpha(0) == 0.0, "nibble 15 is alpha 1, nibble 0 alpha 0")

	# --- Block states, as the client writes block+0x7ee.
	_check(W.block_state(lake) == 1, "a block with no dry vertex is state 1")
	var shore := _mapm_region(-30.0).blocks[0]
	shore.plane_type = 0
	shore.plane_height = 50.0
	for i in range(MapmReader.GRID_WIDTH):
		shore.vertices[i].height = 60.0 # the first row stands above the water
	_check(W.block_state(shore) == 3, "dry and 80 deep is state 3")
	for i in range(MapmReader.GRID_WIDTH, MapmReader.VERTEX_COUNT):
		shore.vertices[i].height = 45.0
	_check(W.block_state(shore) == 2, "dry and 5 deep is state 2")
	var dry := _mapm_region(80.0).blocks[0]
	dry.plane_type = 0
	dry.plane_height = 50.0
	_check(W.block_state(dry) == 0, "all dry is state 0")

	# --- What gets drawn.
	var built = W.build(mapm)
	_check(built.water_blocks == 1 and built.still_blocks == 0 and built.dry_blocks == 0,
		"one animated block, nothing else (got %d/%d/%d)" % [built.water_blocks, built.still_blocks, built.dry_blocks])
	var wv: PackedVector3Array = built.water.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(wv.size() == MapmReader.VERTEX_COUNT, "the block is its 17x17 vertices (got %d)" % wv.size())

	var shore_region := _mapm_region(-30.0)
	var sb: MapmReader.Block = shore_region.blocks[0]
	sb.plane_type = 0
	sb.plane_height = 50.0
	for i in range(MapmReader.GRID_WIDTH):
		sb.vertices[i].height = 60.0
	var shore_built = W.build(shore_region)
	var sc: PackedColorArray = shore_built.water.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var sp: PackedVector3Array = shore_built.water.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var dry_ok := true
	var wet_ok := true
	for i in range(sp.size()):
		if absf(sp[i].z) < 0.001:
			dry_ok = dry_ok and sc[i].a == 0.0
		else:
			wet_ok = wet_ok and absf(sc[i].a - 1.0) < 0.0001
	_check(dry_ok, "the dry bank row is transparent (alpha 0)")
	_check(wet_ok, "the 80-deep rows are opaque (alpha 1)")

	var dry_region := _mapm_region(80.0)
	dry_region.blocks[5].plane_type = 0
	dry_region.blocks[5].plane_height = 50.0
	var dry_built = W.build(dry_region)
	_check(dry_built.water == null and dry_built.dry_blocks == 1, "an all-dry PlaneType-0 block is not drawn, and is counted")

	var still_region := _mapm_region(700.0)
	still_region.blocks[7].plane_type = 1
	still_region.blocks[7].wave_id = 1
	still_region.blocks[7].plane_height = 800.0
	still_region.blocks[8].plane_type = 1
	still_region.blocks[8].wave_id = 0
	still_region.blocks[8].plane_height = 800.0
	var still_built = W.build(still_region)
	_check(still_built.still_blocks == 1 and still_built.water == null,
		"PlaneType 1 draws a still quad only with a non-zero WaveID (got %d)" % still_built.still_blocks)
	if still_built.still != null:
		var stv: PackedVector3Array = still_built.still.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_check(stv.size() == 4 and absf(stv[0].y - 800.0) < 0.001, "the still quad is one flat quad at its plane")
		var sf: Vector2i = W.facing_counts(still_built.still)
		_check(sf.y == 0 and sf.x == 2, "the still quad faces up too (got %s)" % sf)
	_check(W.build(null).water == null and W.build(MapmReader.ParsedRegion.new()).water == null,
		"a null or short region builds nothing")

	# --- The materials: both sides drawn, unshaded, blended.
	var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var mat: StandardMaterial3D = W.water_material(tex, Color(0.2, 1.4, -0.1))
	_check(mat.cull_mode == BaseMaterial3D.CULL_DISABLED, "the water culls neither side (D3DCULL_NONE)")
	_check(mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "the water is unshaded (stage 1 never reads the diffuse)")
	_check(mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and mat.vertex_color_use_as_albedo,
		"the water blends by its vertex (shoreline) alpha")
	_check(mat.albedo_color.is_equal_approx(Color(0.2, 1.0, 0.0, 1.0)), "WaterColor is clamped to [0, 1] and alpha stays 1 (got %s)" % mat.albedo_color)
	var still_mat: StandardMaterial3D = W.still_material(tex)
	_check(still_mat.cull_mode == BaseMaterial3D.CULL_DISABLED, "the still surface culls neither side")
	_check(absf(still_mat.albedo_color.a - 180.0 / 255.0) < 0.0001, "the still surface's alpha is 0xB4")

	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
