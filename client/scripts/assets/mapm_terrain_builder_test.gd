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

## ArrayMesh vertex colors are stored 8-bit per channel, so a small
## quantization error vs. the exact literal is expected and not a real
## mismatch -- a generous tolerance, same rationale the original version of
## this test file already used.
func _close_to_unknown_color(c: Color) -> bool:
	var u := MapmTerrainBuilder.UNKNOWN_TILE_COLOR
	return absf(c.r - u.r) < 0.01 and absf(c.g - u.g) < 0.01 and absf(c.b - u.b) < 0.01

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

## Round 565's equivalence fixtures: two synthetic regions (never real game
## data) the surfaces path and the ArrayMesh path are held to. Heights are
## off the 0.0001 grid on purpose (the + 0.00003), so the collision-face
## check below can tell a snapped corner from an unsnapped one. TextureInfo
## ID 1 on the western half, 2 on the eastern, 3 (never in a lookup) on the
## last two block rows, so every pass kind is built: the base, opaque passes
## of resolved IDs, the -1 fallback pass, and blend overlays.
func _fixture_region() -> MapmReader.ParsedRegion:
	return _make_region(func(band_row, band_col):
		var tex_info := 1 if band_col < 3 else 2
		if band_row >= 4:
			tex_info = 3
		return _make_block(func(r, c):
			return float((band_row * 16 + r) * 7 + (band_col * 16 + c) * 3) * 0.37 + 0.00003, tex_info))

## The two cases: [lookup, ao texture, light_dir, light_diffuse, light_ambient].
## A: IDs 1 and 2 resolve, no baked light, no lightmap. B: only ID 1
## resolves (2 joins 3 in the fallback), the light is baked (unshaded
## passes) and a lightmap is set (ao on UV2).
func _fixture_cases() -> Array:
	var tex_a := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	var tex_b := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	var ao := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	return [
		[{1: tex_a, 2: tex_b}, null, Vector3.ZERO, Color.WHITE, Color.BLACK],
		[{1: tex_a}, ao, Vector3(0.3, 0.8, -0.5), Color(0.9, 0.85, 0.8), Color(0.2, 0.25, 0.3)],
	]

## One surface's arrays reduced to what the equivalence is about: vertex and
## index counts, the index sum, and the position / UV / UV2 sums in
## thousandths, as integers so the fingerprint prints and compares exactly.
static func _arrays_fingerprint(a: Array) -> Array:
	var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	for p in pos:
		sx += p.x
		sy += p.y
		sz += p.z
	var isum := 0
	for i in idx:
		isum += i
	var su := 0.0
	if a[Mesh.ARRAY_TEX_UV] != null:
		for t in (a[Mesh.ARRAY_TEX_UV] as PackedVector2Array):
			su += t.x + t.y
	var su2 := 0.0
	if a[Mesh.ARRAY_TEX_UV2] != null:
		for t in (a[Mesh.ARRAY_TEX_UV2] as PackedVector2Array):
			su2 += t.x + t.y
	return [pos.size(), idx.size(), isum, roundi(sx * 1000.0), roundi(sy * 1000.0), roundi(sz * 1000.0),
		roundi(su * 1000.0), roundi(su2 * 1000.0)]

## A material reduced to its flags: textured, transparency, shading mode,
## depth draw mode, ao.
static func _material_fingerprint(mat: StandardMaterial3D) -> Array:
	return [mat.albedo_texture != null, mat.transparency, mat.shading_mode, mat.depth_draw_mode, mat.ao_enabled, mat.ao_on_uv2]

static func _mesh_fingerprint(mesh: ArrayMesh) -> Array:
	var out := []
	for i in range(mesh.get_surface_count()):
		out.append(_arrays_fingerprint(mesh.surface_get_arrays(i)) + _material_fingerprint(mesh.surface_get_material(i)))
	return out

## The fixtures' fingerprints on the PRE-SPLIT builder: BASE d255c92's
## mapm_terrain_builder.gd (with its class_name line removed, loaded beside
## the new one) run through `build_full_region_mesh_textured` on the render
## box, 2026-09-25 (round 565). The ArrayMesh the old builder made and the
## one the surfaces path makes fingerprinted identically in that run; these
## hold both paths to it from here on. Per surface: vertex count, index
## count, index sum, position x/y/z sums, UV and UV2 sums (thousandths), then
## textured, transparency, shading mode, depth draw mode, ao, ao on UV2.
## Case A: base, the -1 fallback pass, opaque 1, opaque 2, blend 2. Case B:
## base, the -1 pass, opaque 1 -- ID 2 unresolved, so no overlay.
const PRE_SPLIT_FINGERPRINTS := [
	[[9409, 55296, 260112384, 9032640000, 1671038683, 9032640000, 0, 9409000, false, 0, 1, 0, false, false],
		[12288, 18432, 113233920, 11796480000, 3200778612, 19660800000, 1572864000, 16384000, false, 0, 1, 0, false, false],
		[12288, 18432, 113233920, 5898240000, 1345782128, 7864320000, 688128000, 7168000, true, 0, 1, 0, false, false],
		[12288, 18432, 113233920, 17694720000, 2000486768, 7864320000, 1277952000, 13312000, true, 0, 1, 0, false, false],
		[256, 384, 48896, 243200000, 34714888, 163840000, 20352000, 212000, true, 1, 1, 2, false, false]],
	[[9409, 55296, 260112384, 9032640000, 1671038683, 9032640000, 0, 9409000, false, 0, 0, 0, true, true],
		[24576, 36864, 452960256, 29491200000, 5201265380, 27525120000, 2850816000, 29696000, false, 0, 0, 0, true, true],
		[12288, 18432, 113233920, 5898240000, 1345782128, 7864320000, 688128000, 7168000, true, 0, 0, 0, true, true]],
]
## The untextured fallback's one surface on the pre-split builder
## (build_full_region_mesh), the same run.
const PRE_SPLIT_FLAT_FINGERPRINT := [9409, 55296, 260112384, 9032640000, 1671038683, 9032640000, 9409000, 0]

## Round 565: the textured terrain is built in two halves -- the surfaces as
## plain data (build_full_region_surfaces_textured, on a WorkerThreadPool task
## in World3D) and the ArrayMesh from them (surfaces_to_mesh, main thread) --
## plus the collision faces from the same data (surface_faces). Held here:
## both paths reproduce the pre-split builder's fingerprints; the surfaces'
## arrays are exactly what the mesh reads back; the materials match; and the
## faces equal what `create_trimesh_shape()` gives the ConcavePolygonShape3D,
## element by element, which is what lets the commit skip it.
func _test_surfaces_path() -> void:
	var region := _fixture_region()
	var cases := _fixture_cases()
	for n in range(cases.size()):
		var c: Array = cases[n]
		var surfaces := MapmTerrainBuilder.build_full_region_surfaces_textured(region, c[0], c[2], c[3], c[4])
		var mesh := MapmTerrainBuilder.build_full_region_mesh_textured(region, c[0], c[1], c[2], c[3], c[4])
		var golden: Array = PRE_SPLIT_FINGERPRINTS[n]
		_check(_mesh_fingerprint(mesh) == golden,
			"case %d: build_full_region_mesh_textured still builds the pre-split mesh (got %s)" % [n, str(_mesh_fingerprint(mesh))])
		var from_data := []
		for surface in surfaces:
			from_data.append(_arrays_fingerprint(surface["arrays"])
				+ _material_fingerprint(MapmTerrainBuilder._surface_material(surface, c[0], c[1])))
		_check(from_data == golden,
			"case %d: the surfaces as data carry the pre-split surfaces, in order, with their materials (got %s)" % [n, str(from_data)])
		_check(surfaces.size() == mesh.get_surface_count(), "case %d: one surface entry per mesh surface" % n)
		var exact := true
		var colours := true
		var worst := 0.0
		for i in range(mini(surfaces.size(), mesh.get_surface_count())):
			var data: Array = surfaces[i]["arrays"]
			var back := mesh.surface_get_arrays(i)
			for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_INDEX, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
				if data[slot] != back[slot]:
					exact = false
			var dc: PackedColorArray = data[Mesh.ARRAY_COLOR]
			var bc: PackedColorArray = back[Mesh.ARRAY_COLOR]
			if dc.size() != bc.size():
				colours = false
			else:
				# Stored 8 bits a channel (this file's own tolerance note):
				# within one step of 1/255.
				for k in range(dc.size()):
					worst = maxf(worst, maxf(maxf(absf(dc[k].r - bc[k].r), absf(dc[k].g - bc[k].g)),
						maxf(absf(dc[k].b - bc[k].b), absf(dc[k].a - bc[k].a))))
				if worst > 1.0 / 255.0:
					colours = false
			var textured: bool = surfaces[i]["texture_key"] != -1
			var mat := mesh.surface_get_material(i) as StandardMaterial3D
			if textured and mat.albedo_texture != c[0][surfaces[i]["texture_key"]]:
				exact = false
		_check(exact, "case %d: every surface's positions, indices, UVs and texture are exactly what the mesh holds" % n)
		_check(colours, "case %d: every surface's vertex colours are the mesh's, to 8-bit storage (worst channel difference %.5f)" % [n, worst])
		var faces := MapmTerrainBuilder.surface_faces(surfaces)
		var trimesh: PackedVector3Array = mesh.create_trimesh_shape().get_faces()
		_check(faces == trimesh,
			"case %d: surface_faces is create_trimesh_shape's face list, element for element (%d vs %d corners)" % [n, faces.size(), trimesh.size()])
	# The off-grid heights are what make the face check mean something: an
	# unsnapped corner differs from the trimesh's at the fifth decimal.
	var raw: PackedVector3Array = MapmTerrainBuilder.build_full_region_surfaces_textured(region, cases[0][0])[0]["arrays"][Mesh.ARRAY_VERTEX]
	_check(raw[1] != raw[1].snapped(Vector3(0.0001, 0.0001, 0.0001)),
		"the fixture's heights sit off the 0.0001 grid (so the face check sees the snap)")

	# The untextured fallback: one surface of arrays, the same mesh and faces.
	var arrays := MapmTerrainBuilder.build_full_region_arrays(region)
	_check(_arrays_fingerprint(arrays) == PRE_SPLIT_FLAT_FINGERPRINT,
		"build_full_region_arrays carries the pre-split flat surface (got %s)" % str(_arrays_fingerprint(arrays)))
	var flat := MapmTerrainBuilder.build_full_region_mesh(region)
	_check(flat != null and _arrays_fingerprint(flat.surface_get_arrays(0)) == PRE_SPLIT_FLAT_FINGERPRINT,
		"build_full_region_mesh still builds the pre-split flat mesh")
	if flat != null:
		_check(MapmTerrainBuilder.surface_faces([{"arrays": arrays}]) == flat.create_trimesh_shape().get_faces(),
			"surface_faces of the flat arrays is the flat mesh's trimesh face list")
	_check(MapmTerrainBuilder.build_full_region_surfaces_textured(MapmReader.ParsedRegion.new(), {}).is_empty(),
		"build_full_region_surfaces_textured rejects a region without a real 6x6 block grid")
	_check(MapmTerrainBuilder.build_full_region_arrays(MapmReader.ParsedRegion.new()).is_empty(),
		"build_full_region_arrays rejects a region without a real 6x6 block grid")

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

	# Vertex colors (2026-08-26, see docs/WORLD_ISSUES.md): this project no
	# longer invents a per-TextureInfo-ID color guess -- build_mesh/
	## build_full_region_mesh's flat-color path is honest "no real texture
	# resolved here" scaffolding, not a real-looking render, so every
	# vertex gets the same real UNKNOWN_TILE_COLOR regardless of its real
	# TextureInfo ID (distinct IDs are NOT supposed to produce distinct
	# colors here anymore -- the real per-quad texture path,
	# build_full_region_mesh_textured, is what actually renders real
	# ground appearance).
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
		_check(color_a.is_equal_approx(color_b), "distinct real TextureInfo IDs no longer produce an invented distinct color (got %s vs %s)" % [color_a, color_b])
		_check(_close_to_unknown_color(color_a), "fallback color is the one honest UNKNOWN_TILE_COLOR (got %s)" % color_a)

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
		var fallback_color: Color = mesh_fallback.surface_get_arrays(0)[Mesh.ARRAY_COLOR][0]
		_check(_close_to_unknown_color(fallback_color), "empty Extra also falls back to UNKNOWN_TILE_COLOR (got %s)" % fallback_color)

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

	_check(MapmTerrainBuilder.near_row_middle_height(region_full) == 0.0, "near_row_middle_height reads block (0,0)'s own real vertex")

	# _quad_uv_corners lays a real ground texture out continuously across the
	# region, so it flows from one quad into the next instead of being
	# stamped once per quad. The property that matters is that adjacent quads
	# agree on the UV along the edge they share -- without that, every quad
	# boundary is a visible seam, which is what made real ground read as a
	# grid of squares (see the function's own doc comment).
	var uv_here := MapmTerrainBuilder._quad_uv_corners(3, 5, 1.0)
	var uv_east := MapmTerrainBuilder._quad_uv_corners(3, 6, 1.0)
	var uv_south := MapmTerrainBuilder._quad_uv_corners(4, 5, 1.0)
	# Corner order is [ (r,c), (r,c+1), (r+1,c+1), (r+1,c) ].
	_check(uv_here[1].is_equal_approx(uv_east[0]) and uv_here[2].is_equal_approx(uv_east[3]),
		"UVs are continuous across the shared edge with the quad to the east")
	_check(uv_here[3].is_equal_approx(uv_south[0]) and uv_here[2].is_equal_approx(uv_south[1]),
		"UVs are continuous across the shared edge with the quad to the south")
	_check(uv_here[0] == Vector2(5.0, 3.0),
		"a quad's UV origin is its own real position in the region grid (got %s)" % uv_here[0])
	_check(MapmTerrainBuilder._quad_uv_corners(3, 5, 1.0) == MapmTerrainBuilder._quad_uv_corners(3, 5, 1.0),
		"_quad_uv_corners is deterministic for the same (r, c)")
	# A larger real repeat tiles the texture more times across the same quad.
	var uv_rep2 := MapmTerrainBuilder._quad_uv_corners(3, 5, 2.0)
	_check(absf((uv_rep2[1].x - uv_rep2[0].x) - 2.0) < 0.001,
		"the real per-vertex Scale drives how many times a texture repeats per quad")

	# build_full_region_mesh_textured: half the region's vertices carry
	# TextureInfo ID 1 (resolved via texture_lookup to a real texture), the
	# other half ID 2 (no entry in texture_lookup, so it must fall back to
	# the flat-color surface) -- covers both branches with one region.
	var fake_texture := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	var fake_texture_b := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	# Two *resolved* textures meeting, which is the real case: real ground is
	# a mosaic of real tile textures, and the interesting behaviour is how one
	# fades into another. (An unresolved ID has no texture to fade, so it can
	# never exercise the blend.)
	var texture_lookup := {1: fake_texture, 2: fake_texture_b}
	var region_textured := _make_region(func(band_row, band_col):
		var tex_info := 1 if band_col < 3 else 2
		return _make_block(func(r, c): return 0.0, tex_info))
	var textured_mesh := MapmTerrainBuilder.build_full_region_mesh_textured(region_textured, texture_lookup)
	_check(textured_mesh != null, "builds a textured full-region mesh")
	if textured_mesh != null:
		# Surface 0 is the whole-grid flat-color base; then one **opaque**
		# surface per real texture that is dominant in some quad; then one
		# **alpha-blended** surface per real texture that appears in a quad
		# without dominating it. See _textured_surfaces_from_cells'
		# doc comment (reworked 2026-09-06 to real per-vertex splatting).
		_check(textured_mesh.get_surface_count() >= 4,
			"base + an opaque surface per real texture + at least one blend surface (got %d)" % textured_mesh.get_surface_count())
		var expected_size := MapmReader.BLOCKS_PER_SIDE * (GW - 1) + 1
		var expected_quad_indices := 2 * 3 * (expected_size - 1) * (expected_size - 1)
		var base_arrays := textured_mesh.surface_get_arrays(0)
		_check(base_arrays[Mesh.ARRAY_INDEX].size() == expected_quad_indices, "base surface alone covers every real quad (got %d indices)" % base_arrays[Mesh.ARRAY_INDEX].size())

		# Split the textured surfaces into opaque and blended, then check
		# each group's real invariants.
		var opaque_indices := 0
		var blend_indices := 0
		var blend_alphas := {}
		for i in range(1, textured_mesh.get_surface_count()):
			var mat: StandardMaterial3D = textured_mesh.surface_get_material(i)
			var arrays := textured_mesh.surface_get_arrays(i)
			_check(mat.vertex_color_use_as_albedo, "textured surface uses vertex color as albedo")
			if mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				opaque_indices += arrays[Mesh.ARRAY_INDEX].size()
			else:
				blend_indices += arrays[Mesh.ARRAY_INDEX].size()
				_check(mat.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED,
					"the blend overlay does not write depth (it is coplanar with the opaque pass)")
				for col in arrays[Mesh.ARRAY_COLOR]:
					blend_alphas[snappedf(col.a, 0.02)] = true

		# Every real quad is drawn opaque exactly once, so the ground is
		# never see-through no matter how its textures are mixed.
		_check(opaque_indices == expected_quad_indices,
			"every real quad is covered exactly once across the opaque surfaces (got %d of %d)" % [opaque_indices, expected_quad_indices])
		_check(blend_indices > 0 and blend_indices < expected_quad_indices,
			"blend surfaces cover only real mixed quads, not the whole grid (got %d of %d)" % [blend_indices, expected_quad_indices])

		# The real point of the rework: a blend vertex is fully on or fully
		# off, because it is that *vertex's* own real texture or it is not.
		# The old per-quad code instead faded a fixed fraction along a quad
		# edge, which is what made real ground read as hard-edged squares.
		var alpha_values: Array = blend_alphas.keys()
		alpha_values.sort()
		var only_binary := true
		for a2 in alpha_values:
			if absf(a2) > 0.02 and absf(a2 - 1.0) > 0.02:
				only_binary = false
		_check(only_binary and alpha_values.size() == 2,
			"blend vertex alpha is per-vertex 0 or 1, not a fixed edge feather (got %s)" % [alpha_values])

	_check(MapmTerrainBuilder.build_full_region_mesh_textured(MapmReader.ParsedRegion.new(), {}) == null, "build_full_region_mesh_textured rejects a region without a real 6x6 block grid")

	# build_full_region_water_mesh: a synthetic tile table where ID 1 is
	# real WATER and ID 2 is real GRASS -- only ID-1 quads should produce
	# real water geometry.
	var water_entry := TileIndexReader.Entry.new()
	water_entry.id = 1
	water_entry.type = TileIndexReader.TileType.WATER
	var grass_entry := TileIndexReader.Entry.new()
	grass_entry.id = 2
	grass_entry.type = TileIndexReader.TileType.GRASS
	var tile_table := TileIndexReader.Table.new()
	tile_table.entries = [TileIndexReader.Entry.new(), water_entry, grass_entry] # index 0 unused, real lookup is by ID

	var region_water := _make_region(func(band_row, band_col):
		var tex_info := 1 if band_col < 3 else 2
		return _make_block(func(r, c): return 0.0, tex_info))
	var water_mesh := MapmTerrainBuilder.build_full_region_water_mesh(region_water, tile_table)
	_check(water_mesh != null, "builds a real water mesh when real WATER-classified quads exist")
	if water_mesh != null:
		var water_indices: PackedInt32Array = water_mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
		_check(water_indices.size() > 0 and water_indices.size() % 6 == 0, "water mesh has a whole number of real quads (got %d indices)" % water_indices.size())

	var region_no_water := _make_region(func(band_row, band_col):
		return _make_block(func(r, c): return 0.0, 2)) # every quad is real GRASS
	_check(MapmTerrainBuilder.build_full_region_water_mesh(region_no_water, tile_table) == null, "returns null when a real region has no WATER/DEEP_WATER quads at all")
	_check(MapmTerrainBuilder.build_full_region_water_mesh(region_water, null) == null, "returns null with no real tile table to classify against")
	_check(MapmTerrainBuilder.build_full_region_water_mesh(MapmReader.ParsedRegion.new(), tile_table) == null, "rejects a region without a real 6x6 block grid")

	_test_surfaces_path()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
