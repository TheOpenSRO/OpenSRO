extends SceneTree

## Exercises NvmCollision against synthetic regions (never real game data),
## run headless:
## `godot4 --headless --path client --script res://scripts/nvm/nvm_collision_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _edge(flags: int, a: Vector2, b: Vector2) -> NvmReader.Edge:
	var e := NvmReader.Edge.new()
	e.flags = flags
	e.line_min = a
	e.line_max = b
	return e

func _flat_region(height: float) -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(height)
	return r

## A flat region whose 36 plane blocks all carry `plane_type` at
## `plane_height`.
func _planed_region(ground: float, plane_type: int, plane_height: float) -> NvmReader.ParsedRegion:
	var r := _flat_region(ground)
	r.plane_types.resize(NvmReader.PLANE_COUNT)
	r.plane_types.fill(plane_type)
	r.plane_heights.resize(NvmReader.PLANE_COUNT)
	r.plane_heights.fill(plane_height)
	return r

## Round 744: Karakoram's frozen lake. The numbers are MEASURED from the real
## files (waterat and a .nvm/.m height comparison on the render box, never
## shipped): region 90/127 has `.nvm` PlaneType 3 at PlaneHeight 800 on all 36
## blocks, and its heightmap at local (960, 960) -- vertex (48, 48), block r3
## c3 -- is 505.81, the lakebed 294 units under the ice. 88/125's oasis is
## plain water: `.nvm` type 1, plane 800, lakebed 663.65 at (960, 960). The
## rule is READ: CRTNavMeshTerrain::vslot_001 (0x004051b0) raises the
## interpolated height to the block's PlaneHeight when PlaneTypeMap & 2.
func _solid_planes() -> void:
	_check(NvmCollision.SOLID_PLANE_BIT == 2, "the solid-plane bit is the client's & 2")

	# The block index, the way vslot_001 forms it: tile = trunc(x / 20),
	# block = tile >> 4, index row * 6 + col with the row from z.
	_check(NvmCollision.plane_index(960.0, 960.0) == 21, "local (960, 960) is block r3 c3")
	_check(NvmCollision.plane_index(319.99, 0.0) == 0 and NvmCollision.plane_index(320.0, 0.0) == 1,
		"a block is 320 wide on x (col)")
	_check(NvmCollision.plane_index(0.0, 320.0) == 6, "z picks the row")
	_check(NvmCollision.plane_index(1919.9, 1919.9) == 35, "the far corner is block 35")
	_check(NvmCollision.plane_index(1920.0, -5.0) == 5, "points off the region clamp to its own blocks")

	var lake := _planed_region(505.81, 3, 800.0)
	_check(absf(NvmCollision.sample_height(lake, 960.0, 960.0) - 505.81) < 0.001,
		"sample_height is still the raw lakebed (505.81)")
	_check(absf(NvmCollision.solid_plane_height(lake, 960.0, 960.0) - 800.0) < 0.001,
		"the ice block's solid plane is at 800")
	_check(absf(NvmCollision.terrain_height(lake, 960.0, 960.0) - 800.0) < 0.001,
		"90/127 at (960, 960): the ground is the ice at 800, not the lakebed (got %.2f)" % NvmCollision.terrain_height(lake, 960.0, 960.0))

	# Ground above the plane wins: the rule is a max, not a replacement.
	var bank := _planed_region(836.86, 3, 800.0)
	_check(absf(NvmCollision.terrain_height(bank, 960.0, 960.0) - 836.86) < 0.001,
		"a bank above the ice keeps its own height (836.86, 90/127's highest in block r3 c2)")

	var ice_only_solid := _planed_region(505.81, 2, 800.0)
	_check(absf(NvmCollision.terrain_height(ice_only_solid, 960.0, 960.0) - 800.0) < 0.001,
		"type 2 (solid, not drawn: 111 real blocks) is stood on too")

	var water := _planed_region(663.65, 1, 800.0)
	_check(is_nan(NvmCollision.solid_plane_height(water, 960.0, 960.0)), "plain water (type 1) has no solid plane")
	_check(absf(NvmCollision.terrain_height(water, 960.0, 960.0) - 663.65) < 0.001,
		"88/125's oasis water (type 1) stays wadeable: the lakebed 663.65")

	var dry := _planed_region(10.0, 0, 800.0)
	_check(absf(NvmCollision.terrain_height(dry, 960.0, 960.0) - 10.0) < 0.001, "type 0 ignores its plane height")
	_check(absf(NvmCollision.terrain_height(_flat_region(12.0), 5.0, 5.0) - 12.0) < 0.001,
		"a region without a plane map falls back to the heightmap")

	# One solid block only: the plane stops at its edge.
	var one := _planed_region(505.81, 0, 800.0)
	one.plane_types[21] = 3
	_check(absf(NvmCollision.terrain_height(one, 959.9, 1000.0) - 505.81) < 0.001
		and absf(NvmCollision.terrain_height(one, 960.0, 1000.0) - 800.0) < 0.001,
		"the plane covers its own block only (x 959.9 lakebed, 960 ice)")

	var faces := NvmCollision.solid_plane_faces(one)
	_check(faces.size() == 6, "one solid block -> one quad, two triangles (got %d verts)" % faces.size())
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for v in faces:
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	_check(lo.is_equal_approx(Vector3(960.0, 800.0, 960.0)) and hi.is_equal_approx(Vector3(1280.0, 800.0, 1280.0)),
		"the quad spans block r3 c3 at the plane height (%s .. %s)" % [lo, hi])
	_check(NvmCollision.solid_plane_faces(lake).size() == 36 * 6, "a whole frozen region is 36 quads")
	_check(NvmCollision.solid_plane_faces(water).is_empty(), "plain water builds no collision")
	_check(NvmCollision.solid_plane_faces(NvmReader.ParsedRegion.new()).is_empty(), "no plane map, no faces")

	# Walls on the ice stand on the ice.
	lake.internal_edges = [_edge(2, Vector2(900.0, 900.0), Vector2(1000.0, 900.0))]
	var wall := NvmCollision.build_wall_triangles(lake, 5.0)
	var wall_lo := INF
	for v in wall:
		wall_lo = minf(wall_lo, v.y)
	_check(absf(wall_lo - 800.0) < 0.001, "a wall on the ice starts at the ice (got %.2f)" % wall_lo)

func _initialize() -> void:
	# The real mask recovered from the client's collision traversal, and the
	# real flag values that actually occur -- see NvmCollision's top comment
	# and docs/protocol/NVM_FORMAT.md.
	_check(NvmCollision.BLOCKING_FLAG_MASK == 0x3, "blocking mask is the real & 3")
	_check(NvmCollision.is_blocking(_edge(2, Vector2.ZERO, Vector2.ONE)), "internal flag 2 blocks")
	_check(not NvmCollision.is_blocking(_edge(4, Vector2.ZERO, Vector2.ONE)), "internal flag 4 is passable")
	_check(not NvmCollision.is_blocking(_edge(8, Vector2.ZERO, Vector2.ONE)), "global flag 8 is never blocking")
	_check(not NvmCollision.is_blocking(_edge(0, Vector2.ZERO, Vector2.ONE)), "flag 0 is passable")
	# Bit 0 is inside the mask even though no real file was seen using it.
	_check(NvmCollision.is_blocking(_edge(1, Vector2.ZERO, Vector2.ONE)), "flag 1 is inside the real mask")

	var region := _flat_region(10.0)
	region.internal_edges = [
		_edge(2, Vector2(0.0, 0.0), Vector2(20.0, 0.0)),
		_edge(4, Vector2(0.0, 40.0), Vector2(20.0, 40.0)),
		_edge(2, Vector2(0.0, 80.0), Vector2(20.0, 80.0)),
	]
	# A blocking global edge does not occur in real data, but the mask is
	# what decides, so it must still be collected.
	region.global_edges = [
		_edge(8, Vector2(0.0, 100.0), Vector2(20.0, 100.0)),
		_edge(2, Vector2(0.0, 120.0), Vector2(20.0, 120.0)),
	]
	var blocking := NvmCollision.blocking_edges(region)
	_check(blocking.size() == 3, "collects only the real blocking edges (got %d)" % blocking.size())

	var faces := NvmCollision.build_wall_triangles(region, 5.0)
	_check(faces.size() == 3 * 6, "two triangles per blocking edge (got %d verts)" % faces.size())

	var min_y := INF
	var max_y := -INF
	for v in faces:
		min_y = minf(min_y, v.y)
		max_y = maxf(max_y, v.y)
	_check(absf(min_y - 10.0) < 0.001, "walls start at the real terrain height (got %s)" % min_y)
	_check(absf(max_y - 15.0) < 0.001, "walls rise by exactly the requested height (got %s)" % max_y)

	# A degenerate edge would produce a zero-area quad, which is useless as
	# collision and can upset shape cooking.
	var degenerate := _flat_region(0.0)
	degenerate.internal_edges = [_edge(2, Vector2(5.0, 5.0), Vector2(5.0, 5.0))]
	_check(NvmCollision.build_wall_triangles(degenerate, 5.0).is_empty(), "skips a degenerate edge")

	# Heights must be sampled per endpoint, not taken from one end, or walls
	# on a slope would float or sink.
	var sloped := _flat_region(0.0)
	var side := NvmReader.HEIGHT_MAP_SIDE
	for r_i in range(side):
		for c_i in range(side):
			sloped.heights[r_i * side + c_i] = float(c_i)
	_check(absf(NvmCollision.sample_height(sloped, 0.0, 0.0) - 0.0) < 0.001, "samples the origin height")
	_check(absf(NvmCollision.sample_height(sloped, 20.0, 0.0) - 1.0) < 0.001, "column maps to X")
	_check(absf(NvmCollision.sample_height(sloped, 0.0, 20.0) - 0.0) < 0.001, "row maps to Z")
	_check(absf(NvmCollision.sample_height(sloped, 10.0, 0.0) - 0.5) < 0.001, "interpolates between samples")
	_check(absf(NvmCollision.sample_height(sloped, 99999.0, 0.0) - 96.0) < 0.001, "clamps past the region edge")
	_check(absf(NvmCollision.sample_height(sloped, -50.0, 0.0) - 0.0) < 0.001, "clamps before the region start")

	var empty := NvmReader.ParsedRegion.new()
	_check(NvmCollision.sample_height(empty, 0.0, 0.0) == 0.0, "tolerates a region with no heightmap")
	_check(NvmCollision.build_wall_triangles(empty, 5.0).is_empty(), "an edgeless region builds no walls")

	_solid_planes()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
