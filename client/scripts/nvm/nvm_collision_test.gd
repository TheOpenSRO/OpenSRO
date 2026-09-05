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

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
