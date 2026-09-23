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

func _cedge(v0: int, v1: int, cell_from: int, cell_to: int, flags: int) -> BmsReader.CollisionEdge:
	var e := BmsReader.CollisionEdge.new()
	e.v0 = v0
	e.v1 = v1
	e.cell_from = cell_from
	e.cell_to = cell_to
	e.flags = flags
	return e

## A quad of four points (in order around it) as two real-shaped cells
## [0,1,2] and [0,2,3], with its outline edges carrying the given flags in
## the order 0-1, 1-2, 2-3, 3-0 and the shared diagonal 0-2 as an internal
## edge of `diagonal_flags`.
func _quad(points: Array, outline_flags: Array, diagonal_flags: int = 4) -> BmsReader.CollisionMesh:
	var cm := BmsReader.CollisionMesh.new()
	for p in points:
		var v := BmsReader.CollisionVertex.new()
		v.position = p
		cm.vertices.append(v)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		var c := BmsReader.CollisionCell.new()
		c.a = tri[0]
		c.b = tri[1]
		c.c = tri[2]
		cm.cells.append(c)
	# Edges 0-1 and 1-2 bound cell 0; 2-3 and 3-0 bound cell 1.
	cm.outline_edges.append(_cedge(0, 1, 0, BmsReader.NO_CELL, outline_flags[0]))
	cm.outline_edges.append(_cedge(1, 2, 0, BmsReader.NO_CELL, outline_flags[1]))
	cm.outline_edges.append(_cedge(2, 3, 1, BmsReader.NO_CELL, outline_flags[2]))
	cm.outline_edges.append(_cedge(3, 0, 1, BmsReader.NO_CELL, outline_flags[3]))
	cm.internal_edges.append(_cedge(0, 2, 0, 1, diagonal_flags))
	return cm

## A ramp climbing from y=0 at z=0 to y=`rise` at z=`run`, `width` wide in X,
## as two real-shaped navigation cells: its sides are walls (flag 3, the
## value 81% of real outline edges carry) and its foot and head are open
## (flag 0, the real doorway value), so it can be walked onto and off.
func _ramp(rise: float, run: float, width: float) -> BmsReader.CollisionMesh:
	return _quad([
		Vector3(0.0, 0.0, 0.0), Vector3(width, 0.0, 0.0),
		Vector3(width, rise, run), Vector3(0.0, rise, run),
	], [0, 3, 0, 3])

func _placed_list(placed: NavGraph.PlacedObject) -> Array[NavGraph.PlacedObject]:
	var out: Array[NavGraph.PlacedObject] = [placed]
	return out

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
	var g3 := NavGraph.build(region, _placed_list(placed))

	_check(g3.objects_at(110.0, 210.0) == ([0] as Array[int]),
		"the real cell's own object list is what finds the object")
	_check(placed.edge_flags.size() == 5 and placed.edge_outline.count(1) == 4,
		"every edge is kept with its list (%d edges, %d outline)" % [placed.edge_flags.size(), placed.edge_outline.count(1)])

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
	var g4 := NavGraph.build(region, _placed_list(NavGraph.place(high, 0, Vector3(100.0, 5.0, 200.0), 0.0)))
	_check(absf(g4.height_at(110.0, 239.0, 0.0)) < 0.001,
		"a surface far overhead is not mistaken for the ground (got %s)" % g4.height_at(110.0, 239.0, 0.0))

	# --- the client's own rule: walls block from both sides, doorways let
	# you on, and only the object you stand on has a say ------------------
	# An object's wall (flag 3) stops someone standing on it...
	_check(g3.blocked(Vector2(105.0, 220.0), Vector2(95.0, 220.0), 0),
		"the object's own real wall stops someone standing on it")
	_check(not g3.blocked(Vector2(110.0, 205.0), Vector2(110.0, 235.0), 0),
		"moving up the ramp between its sides is not blocked")
	# ...and someone on the terrain walking into it. This is what the real
	# entry test does (bit 0 of the edge's flags), and it is what used to be
	# missing: a terrain mover was let through the wall whenever the floor
	# behind it was within reach, then trapped by the same wall from inside.
	_check(g3.blocked(Vector2(95.0, 220.0), Vector2(105.0, 220.0), NavGraph.ON_TERRAIN),
		"the same wall stops someone on the terrain walking in through it")
	_check(g4.blocked(Vector2(95.0, 220.0), Vector2(105.0, 220.0), NavGraph.ON_TERRAIN),
		"however high the floor behind it is")
	# ...but not someone standing on a *different* object: the real walk
	# tests only the current object's edges. This is what keeps the real
	# Jangan palace gate open, where the palace interior's own walls used to
	# close the gateway (docs/WORLD_ISSUES.md's seventy-fifth round).
	var two := _region(0.0)
	two.cells[0].object_indices = [0, 1]
	var gate_floor := NavGraph.place(_quad([
		Vector3(0.0, 0.0, 0.0), Vector3(60.0, 0.0, 0.0), Vector3(60.0, 0.0, 60.0), Vector3(0.0, 0.0, 60.0),
	], [0, 0, 0, 0]), 1, Vector3(80.0, 0.0, 190.0), 0.0)
	var pair_list: Array[NavGraph.PlacedObject] = [placed, gate_floor]
	var g_two := NavGraph.build(two, pair_list)
	_check(not g_two.blocked(Vector2(95.0, 220.0), Vector2(105.0, 220.0), 1),
		"another object's wall does not stop someone standing on a neighbouring object")
	# ...unless that object keeps terrain collision (the "event" marker).
	var pad_mesh := _quad([
		Vector3(0.0, 0.0, 0.0), Vector3(60.0, 0.0, 0.0), Vector3(60.0, 0.0, 60.0), Vector3(0.0, 0.0, 60.0),
	], [0, 0, 0, 0])
	pad_mesh.events.append("EVENT")
	var pad := NavGraph.place(pad_mesh, 1, Vector3(80.0, 0.0, 190.0), 0.0)
	_check(pad.terrain_collides, "an object naming an \"EVENT\" keeps terrain collision")
	var pad_list: Array[NavGraph.PlacedObject] = [placed, pad]
	var g_pad := NavGraph.build(two, pad_list)
	_check(g_pad.blocked(Vector2(95.0, 220.0), Vector2(105.0, 220.0), 1),
		"...and then a neighbour's wall does stop someone standing on it")

	# Terrain's own blocking edges apply on the terrain, and not to someone
	# on an object (the real walk consults only that object's mesh).
	var tw := _region(0.0)
	tw.cells[0].object_indices = [0]
	tw.internal_edges = [_edge(2, Vector2(110.0, 0.0), Vector2(110.0, 400.0))]
	var gtw := NavGraph.build(tw, _placed_list(NavGraph.place(_ramp(0.0, 40.0, 30.0), 0, Vector3(100.0, 0.0, 200.0), 0.0)))
	_check(gtw.blocked(Vector2(105.0, 100.0), Vector2(115.0, 100.0), NavGraph.ON_TERRAIN),
		"a real terrain blocking edge stops someone on terrain")
	_check(not gtw.blocked(Vector2(105.0, 220.0), Vector2(115.0, 220.0), 0),
		"and not someone standing on an object that crosses it")

	# An edge marked 0x10 is passed beneath by someone on the terrain and is a
	# wall for someone on the object -- a city wall's walkway over its arch.
	var arch := NavGraph.place(_quad([
		Vector3(0.0, 40.0, 0.0), Vector3(30.0, 40.0, 0.0), Vector3(30.0, 40.0, 40.0), Vector3(0.0, 40.0, 40.0),
	], [0x10, 3, 0x10, 3]), 0, Vector3(100.0, 0.0, 200.0), 0.0)
	var g_arch := NavGraph.build(region, _placed_list(arch))
	var under := g_arch.step_tracked(Vector3(115.0, 0.0, 190.0), Vector2(0.0, 60.0), NavGraph.ON_TERRAIN)
	_check(under.standing_on == NavGraph.ON_TERRAIN and absf(under.position.z - 250.0) < 0.01 and absf(under.position.y) < 0.001,
		"someone on the terrain walks under a 0x10 edge and stays on the terrain (z %.1f, on %d)" % [under.position.z, under.standing_on])
	var on_wall := g_arch.step_tracked(Vector3(115.0, 40.0, 220.0), Vector2(0.0, 30.0), 0)
	_check(on_wall.blocked and on_wall.standing_on == 0 and on_wall.position.z < 240.0,
		"someone on the walkway is stopped by the same edge (z %.2f)" % on_wall.position.z)

	# A one-way internal edge: value 1 stops a mover on the edge's cell_to
	# side, value 2 one on its cell_from side. The diagonal 0-2 has cell 0
	# (the +x/-z half) as its from side.
	var one_way := NavGraph.place(_quad([
		Vector3(0.0, 0.0, 0.0), Vector3(40.0, 0.0, 0.0), Vector3(40.0, 0.0, 40.0), Vector3(0.0, 0.0, 40.0),
	], [3, 3, 3, 3], 4 | 1), 0, Vector3(100.0, 0.0, 200.0), 0.0)
	var g_one := NavGraph.build(region, _placed_list(one_way))
	_check(not g_one.blocked(Vector2(130.0, 210.0), Vector2(110.0, 230.0), 0),
		"a flag-5 internal edge lets a mover cross from its cell_from side")
	_check(g_one.blocked(Vector2(110.0, 230.0), Vector2(130.0, 210.0), 0),
		"and stops one crossing back from its cell_to side")

	# The yaw convention is the game's own, read from its matrix builder
	# (FUN_0043cda0 via MapLoader::FUN_0042b8b0; see NavGraph.godot_yaw): a
	# row-vector Y rotation that sends local +X to (cos, 0, sin) and local +Z
	# to (-sin, 0, cos). Pinned directly, at 90 degrees and at an angle with
	# no symmetry to hide behind.
	var b90 := Basis(Vector3.UP, NavGraph.godot_yaw(PI / 2.0))
	_check((b90 * Vector3(1.0, 0.0, 0.0)).is_equal_approx(Vector3(0.0, 0.0, 1.0)),
		"a 90-degree yaw sends local +X to world +Z, as the game's matrix does (got %s)" % (b90 * Vector3(1.0, 0.0, 0.0)))
	_check((b90 * Vector3(0.0, 0.0, 1.0)).is_equal_approx(Vector3(-1.0, 0.0, 0.0)),
		"and local +Z to world -X (got %s)" % (b90 * Vector3(0.0, 0.0, 1.0)))
	var t30 := deg_to_rad(30.0)
	var b30 := Basis(Vector3.UP, NavGraph.godot_yaw(t30))
	_check((b30 * Vector3(1.0, 0.0, 0.0)).is_equal_approx(Vector3(cos(t30), 0.0, sin(t30))),
		"a 30-degree yaw sends local +X to (cos, 0, sin) (got %s)" % (b30 * Vector3(1.0, 0.0, 0.0)))
	_check((b30 * Vector3(0.0, 0.0, 1.0)).is_equal_approx(Vector3(-sin(t30), 0.0, cos(t30))),
		"and local +Z to (-sin, 0, cos) (got %s)" % (b30 * Vector3(0.0, 0.0, 1.0)))

	# Yaw must actually rotate the placement, or every object would be axis
	# aligned and only the unrotated ones would work.
	var turned := NavGraph.place(_ramp(20.0, 40.0, 30.0), 0, Vector3(100.0, 0.0, 200.0), PI / 2.0)
	var g5 := NavGraph.build(region, _placed_list(turned))
	# A 90-degree yaw turns the ramp's own local +z run onto world -x and its
	# local +x width onto world +z (the game's matrix, above), so its head
	# lands at world x = 100 - 40 and its width spans world z 200..230. Until
	# round 506 this test expected the opposite turn -- x = 140, z 170..200 --
	# because it pinned the project's convention rather than the game's.
	_check(absf(g5.height_at(60.0, 215.0, 20.0) - 20.0) < 0.01,
		"a yawed object's real ramp runs along the rotated axis (got %s)" % g5.height_at(60.0, 215.0, 20.0))
	_check(absf(g5.height_at(80.0, 215.0, 10.0) - 10.0) < 0.01,
		"and is halfway up halfway along it (got %s)" % g5.height_at(80.0, 215.0, 10.0))
	_check(absf(g5.height_at(100.0, 215.0, 5.0)) < 0.01,
		"and its foot is at the rotated origin (got %s)" % g5.height_at(100.0, 215.0, 5.0))
	_check(absf(g5.height_at(140.0, 185.0, 20.0)) < 0.01,
		"and it is not where the old, opposite turn put it")
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
	var gw := NavGraph.build(walk, _placed_list(NavGraph.place(_ramp(20.0, 40.0, 30.0), 0, Vector3(100.0, 0.0, 200.0), 0.0)))
	var pos := Vector3(115.0, 0.0, 201.0)
	pos.y = gw.height_at(pos.x, pos.z, 0.0)
	var start_y := pos.y
	# The ramp runs z 200..240, so 76 steps of 0.5 walks it from z=201 to
	# z=239, one step short of the open head edge.
	var moved := 0
	var monotonic_walk := true
	var last_y := start_y
	for _i in range(76):
		var before := pos
		pos = gw.step(pos, Vector2(0.0, 0.5))
		if not before.is_equal_approx(pos):
			moved += 1
		if pos.y < last_y - 0.001:
			monotonic_walk = false
		last_y = pos.y
	_check(moved == 76, "the player moves on every step (moved %d of 76)" % moved)
	_check(monotonic_walk, "and never loses height on the way up")
	_check(pos.y > start_y + 15.0,
		"walking up a real ramp arrives at the top (y %s -> %s)" % [start_y, pos.y])
	_check(absf(pos.y - 19.5) < 0.5, "and arrives at the ramp's real height there (got %s)" % pos.y)

	# Continuing past the top must land on terrain, not drop through the world.
	for _i in range(60):
		pos = gw.step(pos, Vector2(0.0, 0.5))
	_check(absf(pos.y) < 0.001, "walking off the top lands on terrain (got %s)" % pos.y)

	# The same walk with the footing tracked the way the client tracks it:
	# from the terrain in front of the foot, through the open foot edge (on),
	# up, and out through the open head edge (off).
	var tracked := NavGraph.StepResult.new()
	tracked.position = Vector3(115.0, 0.0, 195.0)
	tracked.standing_on = NavGraph.ON_TERRAIN
	var entered_at := -1.0
	var exited_at := -1.0
	var peak := -INF
	for i in range(120):
		tracked = gw.step_tracked(tracked.position, Vector2(0.0, 0.5), tracked.standing_on)
		if tracked.entered == 0 and entered_at < 0.0:
			entered_at = tracked.position.z
		if tracked.exited == 0 and exited_at < 0.0:
			exited_at = tracked.position.z
		peak = maxf(peak, tracked.position.y)
	_check(absf(entered_at - 200.0) < 0.6, "the tracked walk steps onto the ramp at its open foot (z %.2f)" % entered_at)
	_check(peak > 19.0, "climbs to its head (peak y %.2f)" % peak)
	_check(absf(exited_at - 240.0) < 0.6, "steps off through its open head edge (z %.2f)" % exited_at)
	_check(tracked.standing_on == NavGraph.ON_TERRAIN and absf(tracked.position.y) < 0.001,
		"and is back on the terrain (on %d, y %.2f)" % [tracked.standing_on, tracked.position.y])

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

	# --- the building trap, as measured in Alexandria (round 162) ---------
	# A floor a few units above the terrain, walled on three sides with a
	# doorway on the fourth. Walking at a wall must stop at the wall -- not
	# pass through it onto the floor -- and the doorway must work both ways.
	var house_mesh := _quad([
		Vector3(0.0, 5.5, 0.0), Vector3(40.0, 5.5, 0.0), Vector3(40.0, 5.5, 40.0), Vector3(0.0, 5.5, 40.0),
	], [3, 3, 3, 0]) # the doorway is the 3-0 edge, along x=0
	var house := _region(0.0)
	house.cells[0].object_indices = [0]
	var gh := NavGraph.build(house, _placed_list(NavGraph.place(house_mesh, 0, Vector3(100.0, 0.0, 200.0), 0.0)))
	var at_wall := gh.step_tracked(Vector3(120.0, 0.0, 190.0), Vector2(0.0, 20.0), NavGraph.ON_TERRAIN)
	_check(at_wall.blocked and at_wall.standing_on == NavGraph.ON_TERRAIN and at_wall.position.z < 200.0 and absf(at_wall.position.y) < 0.001,
		"a terrain mover walking at the house wall stops outside it, on the ground (z %.2f, y %.2f, on %d)" % [
			at_wall.position.z, at_wall.position.y, at_wall.standing_on])
	var through_door := gh.step_tracked(Vector3(90.0, 0.0, 220.0), Vector2(20.0, 0.0), NavGraph.ON_TERRAIN)
	_check(through_door.entered == 0 and through_door.standing_on == 0 and absf(through_door.position.y - 5.5) < 0.01,
		"walking in through the doorway steps onto the floor (y %.2f, on %d)" % [through_door.position.y, through_door.standing_on])
	var inside_wall := gh.step_tracked(through_door.position, Vector2(0.0, -40.0), 0)
	_check(inside_wall.blocked and inside_wall.standing_on == 0 and inside_wall.position.z > 200.0,
		"inside, the wall stops the mover from the other side too (z %.2f)" % inside_wall.position.z)
	var back_out := gh.step_tracked(through_door.position, Vector2(-30.0, 0.0), 0)
	_check(back_out.exited == 0 and back_out.standing_on == NavGraph.ON_TERRAIN and absf(back_out.position.y) < 0.001,
		"and the doorway leads back out onto the ground (y %.2f, on %d)" % [back_out.position.y, back_out.standing_on])

	# Two decks sharing an open edge: stepping off one lands on the other,
	# not on the terrain between them for a frame.
	var seam := _region(0.0)
	seam.cells[0].object_indices = [0, 1]
	var deck_a := NavGraph.place(_quad([
		Vector3(0.0, 10.0, 0.0), Vector3(40.0, 10.0, 0.0), Vector3(40.0, 10.0, 40.0), Vector3(0.0, 10.0, 40.0),
	], [3, 0, 3, 3]), 0, Vector3(100.0, 0.0, 200.0), 0.0)
	var deck_b := NavGraph.place(_quad([
		Vector3(0.0, 10.0, 0.0), Vector3(40.0, 10.0, 0.0), Vector3(40.0, 10.0, 40.0), Vector3(0.0, 10.0, 40.0),
	], [3, 3, 3, 0]), 1, Vector3(140.0, 0.0, 200.0), 0.0)
	var decks: Array[NavGraph.PlacedObject] = [deck_a, deck_b]
	var g_seam := NavGraph.build(seam, decks)
	var across := g_seam.step_tracked(Vector3(130.0, 10.0, 220.0), Vector2(20.0, 0.0), 0)
	_check(across.standing_on == 1 and absf(across.position.y - 10.0) < 0.01,
		"stepping across a shared edge hands the footing to the next deck (on %d, y %.2f)" % [across.standing_on, across.position.y])

	# Landing is a different question from walking. A deck just over
	# SURFACE_REACH_UP above the terrain is correctly refused by height_at
	# -- you cannot step up onto it -- but something placed into the world
	# arrives from above and must come to rest on top of it. Jangan's
	# octagonal plaza sits 13.8 units above the terrain against a reach of
	# 12.0, which put the player and every NPC on the town square inside it.
	var deck_rise := NavGraph.SURFACE_REACH_UP + 1.8
	var deck := _ramp(0.0, 40.0, 30.0)
	var g_deck := NavGraph.build(region, _placed_list(NavGraph.place(deck, 0, Vector3(100.0, deck_rise, 200.0), 0.0)))
	var walking := g_deck.height_at(110.0, 239.0, 0.0)
	_check(absf(walking) < 0.001,
		"height_at refuses a deck %.1f up against a reach of %.1f (got %.2f)" % [
			deck_rise, NavGraph.SURFACE_REACH_UP, walking])
	var landing := g_deck.landing_height_at(110.0, 239.0)
	_check(landing > NavGraph.SURFACE_REACH_UP,
		"landing_height_at comes to rest on top of it instead (got %.2f)" % landing)

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
