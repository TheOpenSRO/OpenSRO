extends SceneTree

## Round 781: GroundPick -- the walk's click tests the walkable cells, not the
## drawn meshes (retail SWorld::vslot_034). Synthetic geometry only.
##   godot4 --headless --path client --script res://scripts/world/ground_pick_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await process_frame
	_test_cells()
	_test_nearest()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A flat 100 x 100 deck at height `y`, two cells.
func _deck(x0: float, y: float) -> BmsReader.CollisionMesh:
	var cm := BmsReader.CollisionMesh.new()
	for p in [Vector3(x0, y, 0), Vector3(x0 + 100, y, 0), Vector3(x0 + 100, y, 100), Vector3(x0, y, 100)]:
		var v := BmsReader.CollisionVertex.new()
		v.position = p
		cm.vertices.append(v)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		var c := BmsReader.CollisionCell.new()
		c.a = tri[0]
		c.b = tri[1]
		c.c = tri[2]
		cm.cells.append(c)
	return cm

func _test_cells() -> void:
	var placed: Array[NavGraph.PlacedObject] = []
	placed.append(NavGraph.place(_deck(-5000, 10.0), 0, Vector3.ZERO, 0.0))
	placed.append(NavGraph.place(_deck(-5000, 40.0), 1, Vector3.ZERO, 0.0))
	var g := NavGraph.build_dungeon(placed)
	var down := GroundPick.segment_hit_in_graph(g, Vector3(-4950, 100, 50), Vector3(-4950, -100, 50))
	_check(not down.is_empty() and int(down["object"]) == 1 and is_equal_approx((down["position"] as Vector3).y, 40.0),
		"a ray straight down meets the upper deck first, at its height")
	var under := GroundPick.segment_hit_in_graph(g, Vector3(-4950, 30, 50), Vector3(-4950, -100, 50))
	_check(not under.is_empty() and int(under["object"]) == 0 and is_equal_approx((under["position"] as Vector3).y, 10.0),
		"from between them, the lower deck")
	var miss := GroundPick.segment_hit_in_graph(g, Vector3(-3000, 100, 50), Vector3(-3000, -100, 50))
	_check(miss.is_empty(), "nothing where no object has a cell")
	var up := GroundPick.segment_hit_in_graph(g, Vector3(-4950, -100, 50), Vector3(-4950, 100, 50))
	_check(not up.is_empty(), "a cell is met from either side")
	# Through a group (a dungeon's mirrored one): world in, world out.
	var group := Node3D.new()
	group.scale.z = -1.0
	get_root().add_child(group)
	var w := GroundPick.object_cells_hit([[g, group]], Vector3(-4950, 100, -50), Vector3.DOWN, 500.0)
	_check(not w.is_empty() and (w["position"] as Vector3).is_equal_approx(Vector3(-4950, 40, -50)) and is_equal_approx(float(w["distance"]), 60.0),
		"through a mirrored group: the world point and distance (%s)" % str(w))
	group.free()

func _test_nearest() -> void:
	var from := Vector3.ZERO
	var terrain := {"position": Vector3(0, -50, 0)}
	var cells := {"position": Vector3(0, -20, 0), "distance": 20.0, "object": 3}
	_check(int(GroundPick.nearest(from, terrain, cells).get("object", -1)) == 3, "a deck above the ground wins")
	var deep := {"position": Vector3(0, -80, 0), "distance": 80.0, "object": 4}
	_check(GroundPick.nearest(from, terrain, deep) == terrain, "the ground in front of a cell wins")
	_check(GroundPick.nearest(from, {}, {}).is_empty() and GroundPick.nearest(from, terrain, {}) == terrain, "either alone")
