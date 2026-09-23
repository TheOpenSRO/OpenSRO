extends SceneTree

## Exercises NpcFacing against synthetic regions (never real game data), run
## headless:
## `godot4 --headless --path client --script res://scripts/npc/npc_facing_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A flat region, every tile pointing at one cell covering it, with the given
## terrain edges (a blocking edge carries flag 2, as in nav_graph_test).
func _graph(edges: Array) -> NavGraph:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(0.0)
	var cell := NvmReader.Cell.new()
	cell.rect_min = Vector2.ZERO
	cell.rect_max = Vector2(1920.0, 1920.0)
	r.cells.append(cell)
	for _i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 0
		r.tiles.append(t)
	var typed: Array[NvmReader.Edge] = []
	for pair in edges:
		var e := NvmReader.Edge.new()
		e.flags = 2
		e.line_min = pair[0]
		e.line_max = pair[1]
		typed.append(e)
	r.internal_edges = typed
	return NavGraph.build(r, [] as Array[NavGraph.PlacedObject])

func _initialize() -> void:
	# A wall 10 units to the east, long enough to cover every probe: the open
	# side is the west, and the NPC faces the middle of it -- not the edge of
	# the open arc, which the first tied heading would be.
	var east_wall := _graph([[Vector2(100.0, 0.0), Vector2(100.0, 1920.0)]])
	var d := NpcFacing.open_direction(east_wall, Vector3(90.0, 0.0, 900.0), NavGraph.ON_TERRAIN)
	_check(d.distance_to(Vector2(-1.0, 0.0)) < 0.01,
		"a wall on the east faces the NPC west (got %s)" % d)

	# The same wall on the north side faces it south.
	var north_wall := _graph([[Vector2(0.0, 910.0), Vector2(1920.0, 910.0)]])
	d = NpcFacing.open_direction(north_wall, Vector3(900.0, 0.0, 900.0), NavGraph.ON_TERRAIN)
	_check(d.distance_to(Vector2(0.0, -1.0)) < 0.01,
		"a wall on the north (+z) faces the NPC south (got %s)" % d)

	# A corner (walls east and north) faces the open diagonal between them.
	var corner := _graph([
		[Vector2(100.0, 0.0), Vector2(100.0, 1920.0)],
		[Vector2(0.0, 910.0), Vector2(1920.0, 910.0)]])
	d = NpcFacing.open_direction(corner, Vector3(90.0, 0.0, 900.0), NavGraph.ON_TERRAIN)
	_check(d.x < -0.3 and d.y < -0.3,
		"a north-east corner faces the NPC south-west (got %s)" % d)

	# Open on every side at every range: no information, so no facing.
	var open := _graph([])
	d = NpcFacing.open_direction(open, Vector3(900.0, 0.0, 900.0), NavGraph.ON_TERRAIN)
	_check(d == Vector2.ZERO, "an NPC with open space all round gets no facing (got %s)" % d)

	# A wall beyond the first range still decides it, at a longer range.
	var far_wall := _graph([[Vector2(1000.0, 0.0), Vector2(1000.0, 1920.0)]])
	d = NpcFacing.open_direction(far_wall, Vector3(900.0, 0.0, 900.0), NavGraph.ON_TERRAIN)
	_check(d.distance_to(Vector2(-1.0, 0.0)) < 0.01,
		"a wall 100 units east is found at a longer range (got %s)" % d)

	# The holder rotation puts the body's front (its local -Z) along the
	# chosen direction.
	for dir in [Vector2(-1.0, 0.0), Vector2(0.0, -1.0), Vector2(0.6, 0.8)]:
		var b := Basis(Vector3.UP, NpcFacing.holder_yaw(dir))
		var front := b * Vector3(0.0, 0.0, -1.0)
		_check(Vector2(front.x, front.z).distance_to(dir) < 0.001,
			"holder_yaw points the body's front along %s (got %s)" % [dir, front])

	print("%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
