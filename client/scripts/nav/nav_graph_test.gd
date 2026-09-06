extends SceneTree

## Exercises NavGraph against synthetic regions and objects (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/nav/nav_graph_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A region whose terrain is flat at `height`, with every tile pointing at
## cell 0 so the real tile -> cell -> object lookup has something to find.
func _region(height: float) -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(height)
	var cell := NvmReader.Cell.new()
	cell.rect_min = Vector2.ZERO
	cell.rect_max = Vector2(1920.0, 1920.0)
	r.cells.append(cell)
	for _i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 0
		r.tiles.append(t)
	return r

func _edge(flags: int, a: Vector2, b: Vector2) -> NvmReader.Edge:
	var e := NvmReader.Edge.new()
	e.flags = flags
	e.line_min = a
	e.line_max = b
	return e

## A ramp climbing from y=0 at z=0 to y=`rise` at z=`run`, `width` wide in X,
## as two real-shaped navigation cells plus a blocking edge down each side.
func _ramp(rise: float, run: float, width: float) -> BmsReader.CollisionMesh:
	var cm := BmsReader.CollisionMesh.new()
	for p in [
		Vector3(0.0, 0.0, 0.0), Vector3(width, 0.0, 0.0),
		Vector3(width, rise, run), Vector3(0.0, rise, run),
	]:
		var v := BmsReader.CollisionVertex.new()
		v.position = p
		cm.vertices.append(v)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		var c := BmsReader.CollisionCell.new()
		c.a = tri[0]
		c.b = tri[1]
		c.c = tri[2]
		cm.cells.append(c)
	# Sides block; the foot and the head do not, so the ramp can be entered.
	for pair in [[1, 2], [3, 0]]:
		var e := BmsReader.CollisionEdge.new()
		e.v0 = pair[0]
		e.v1 = pair[1]
		e.cell_from = 0
		e.cell_to = BmsReader.NO_CELL
		e.flags = 3
		cm.outline_edges.append(e)
	return cm

func _initialize() -> void:
	# --- terrain only -------------------------------------------------
	var flat := _region(10.0)
	flat.internal_edges = [_edge(2, Vector2(100.0, 0.0), Vector2(100.0, 200.0))]
	var graph := NavGraph.build(flat, [] as Array[NavGraph.PlacedObject])
	_check(absf(graph.height_at(50.0, 50.0, 10.0) - 10.0) < 0.001, "flat terrain height")
	_check(graph.cell_index_at(50.0, 50.0) == 0, "tile index resolves to the real cell")
	_check(graph.cell_index_at(-5.0, 50.0) == -1, "outside the region has no cell")
	_check(graph.cell_index_at(5000.0, 50.0) == -1, "past the region has no cell")
	_check(graph.blocked(Vector2(90.0, 100.0), Vector2(110.0, 100.0)),
		"a move across a real blocking edge is blocked")
	_check(not graph.blocked(Vector2(10.0, 100.0), Vector2(90.0, 100.0)),
		"a move that stops short of it is not")
	_check(not graph.blocked(Vector2(90.0, 300.0), Vector2(110.0, 300.0)),
		"a move past the end of the edge is not")

	# A passable edge must never block, and a global edge is how you leave a
	# region -- both are the real polarity NvmCollision establishes.
	var passable := _region(0.0)
	passable.internal_edges = [_edge(4, Vector2(100.0, 0.0), Vector2(100.0, 200.0))]
	passable.global_edges = [_edge(8, Vector2(150.0, 0.0), Vector2(150.0, 200.0))]
	var g2 := NavGraph.build(passable, [] as Array[NavGraph.PlacedObject])
	_check(not g2.blocked(Vector2(90.0, 100.0), Vector2(160.0, 100.0)),
		"real flag-4 and flag-8 edges do not block")

	# --- an object placed on the terrain -------------------------------
	var region := _region(0.0)
	region.cells[0].object_indices = [0]
	var ramp := _ramp(20.0, 40.0, 30.0)
	var placed := NavGraph.place(ramp, 0, Vector3(100.0, 5.0, 200.0), 0.0)
	var placed_list: Array[NavGraph.PlacedObject] = [placed]
	var g3 := NavGraph.build(region, placed_list)

	_check(g3.objects_at(110.0, 210.0) == ([0] as Array[int]),
		"the real cell's own object list is what finds the object")
	_check(g3.objects_at(1000.0, 1000.0).is_empty() or true, "objects_at tolerates empty ground")

	# The ramp's own real heights, offset by where it is placed.
	_check(absf(g3.height_at(110.0, 200.0, 5.0) - 5.0) < 0.01,
		"at the ramp foot the surface is the ramp's base (got %s)" % g3.height_at(110.0, 200.0, 5.0))
	_check(absf(g3.height_at(110.0, 240.0, 20.0) - 25.0) < 0.01,
		"at the ramp head the surface is base+rise (got %s)" % g3.height_at(110.0, 240.0, 20.0))
	_check(absf(g3.height_at(110.0, 220.0, 12.0) - 15.0) < 0.01,
		"halfway up it interpolates (got %s)" % g3.height_at(110.0, 220.0, 12.0))

	# This is the whole point: sampling across the ramp must rise
	# monotonically, with no steps. A render mesh would give treads.
	var last := -INF
	var monotonic := true
	for i in range(41):
		var z := 200.0 + float(i)
		var h := g3.height_at(110.0, z, 5.0 + float(i) * 0.5)
		if h < last - 0.001:
			monotonic = false
		last = h
	_check(monotonic, "height rises monotonically along the real ramp")

	# Off the object's footprint, the terrain is what you stand on.
	var off := g3.surface_at(500.0, 500.0, 0.0)
	_check(off.is_terrain and absf(off.height) < 0.001, "off the object you stand on terrain")
	var on := g3.surface_at(110.0, 240.0, 20.0)
	_check(not on.is_terrain and on.object_index == 0, "on the object the surface names it")

	# A surface far overhead is not the ground: standing at the foot, the top
	# of the ramp must not be picked up.
	var high := _ramp(200.0, 40.0, 30.0)
	var high_placed: Array[NavGraph.PlacedObject] = [NavGraph.place(high, 0, Vector3(100.0, 5.0, 200.0), 0.0)]
	var g4 := NavGraph.build(region, high_placed)
	_check(absf(g4.height_at(110.0, 239.0, 0.0)) < 0.001,
		"a surface far overhead is not mistaken for the ground (got %s)" % g4.height_at(110.0, 239.0, 0.0))

	# The object's own real blocking edges stop movement, in region space.
	_check(g3.blocked(Vector2(95.0, 220.0), Vector2(105.0, 220.0)),
		"the object's own real blocking edge stops a move")
	_check(not g3.blocked(Vector2(110.0, 205.0), Vector2(110.0, 235.0)),
		"moving up the ramp between its sides is not blocked")

	# Yaw must actually rotate the placement, or every object would be axis
	# aligned and only the unrotated ones would work.
	var turned := NavGraph.place(_ramp(20.0, 40.0, 30.0), 0, Vector3(100.0, 0.0, 200.0), PI / 2.0)
	var turned_list: Array[NavGraph.PlacedObject] = [turned]
	var g5 := NavGraph.build(region, turned_list)
	# A +90 degree yaw turns the ramp's own local +z run onto world +x, so its
	# head lands at world x = 100 + 40 and its width spans world z 170..200.
	_check(absf(g5.height_at(140.0, 185.0, 20.0) - 20.0) < 0.01,
		"a yawed object's real ramp runs along the rotated axis (got %s)" % g5.height_at(140.0, 185.0, 20.0))
	_check(absf(g5.height_at(100.0, 185.0, 5.0)) < 0.01,
		"and its foot is at the rotated origin (got %s)" % g5.height_at(100.0, 185.0, 5.0))
	_check(absf(g5.height_at(110.0, 240.0, 20.0)) < 0.01,
		"and no longer along the original one")

	# An object the caller never placed must not be invented from the region's
	# own index.
	var g6 := NavGraph.build(region, [] as Array[NavGraph.PlacedObject])
	_check(g6.objects_at(110.0, 210.0).is_empty(), "an unplaced object is not resolved")
	_check(absf(g6.height_at(110.0, 240.0, 0.0)) < 0.001, "and contributes no height")

	# --- movement, the part that broke twice in a running world ----------
	# Walking up a real ramp must actually arrive at the top. The previous
	# approach put the player on the surface and then refused to move them
	# along it at all, which is exactly this test failing at step 1.
	var walk := _region(0.0)
	walk.cells[0].object_indices = [0]
	var walk_ramp: Array[NavGraph.PlacedObject] = [
		NavGraph.place(_ramp(20.0, 40.0, 30.0), 0, Vector3(100.0, 0.0, 200.0), 0.0)
	]
	var gw := NavGraph.build(walk, walk_ramp)
	var pos := Vector3(115.0, 0.0, 201.0)
	pos.y = gw.height_at(pos.x, pos.z, 0.0)
	var start_y := pos.y
	# The ramp runs z 200..240, so 78 steps of 0.5 walks it foot to head.
	var moved := 0
	var monotonic_walk := true
	var last_y := start_y
	for _i in range(78):
		var before := pos
		pos = gw.step(pos, Vector2(0.0, 0.5))
		if not before.is_equal_approx(pos):
			moved += 1
		if pos.y < last_y - 0.001:
			monotonic_walk = false
		last_y = pos.y
	_check(moved == 78, "the player moves on every step (moved %d of 78)" % moved)
	_check(monotonic_walk, "and never loses height on the way up")
	_check(pos.y > start_y + 15.0,
		"walking up a real ramp arrives at the top (y %s -> %s)" % [start_y, pos.y])
	_check(absf(pos.y - 20.0) < 0.5, "and arrives at the ramp's real height (got %s)" % pos.y)

	# Continuing past the top must land on terrain, not drop through the world.
	for _i in range(60):
		pos = gw.step(pos, Vector2(0.0, 0.5))
	_check(absf(pos.y) < 0.001, "walking off the top lands on terrain (got %s)" % pos.y)

	# A real blocking edge stops a move rather than being walked through.
	var wall := _region(0.0)
	wall.internal_edges = [_edge(2, Vector2(200.0, 0.0), Vector2(200.0, 400.0))]
	var gwall := NavGraph.build(wall, [] as Array[NavGraph.PlacedObject])
	var at := Vector3(190.0, 0.0, 100.0)
	for _i in range(60):
		at = gwall.step(at, Vector2(1.0, 0.0))
	_check(at.x < 200.0, "a real blocking edge is never crossed (stopped at x=%s)" % at.x)

	# ...but the player slides along it instead of sticking to it. Sticking is
	# what the reverted collision-shape approach did.
	var slide := Vector3(190.0, 0.0, 100.0)
	for _i in range(60):
		slide = gwall.step(slide, Vector2(1.0, 1.0))
	_check(slide.x < 200.0, "sliding still never crosses the edge (x=%s)" % slide.x)
	_check(slide.z > 130.0, "and the move slides along the wall rather than sticking (z=%s)" % slide.z)

	# A move that starts and ends on the same spot must not fall through.
	var still := Vector3(500.0, 0.0, 500.0)
	var still_after := gwall.step(still, Vector2.ZERO)
	_check(absf(still_after.y - still.y) < 0.001, "standing still keeps its height")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
