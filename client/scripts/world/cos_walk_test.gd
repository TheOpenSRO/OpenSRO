extends SceneTree

## Round 851: a COS's drawn leg stops at a tree's trunk as the server's walk
## does (CosWalk), over synthetic data (never real game data):
## `godot4 --headless --path client --script res://scripts/world/cos_walk_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _region() -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(0.0)
	var cell := NvmReader.Cell.new()
	cell.rect_min = Vector2.ZERO
	cell.rect_max = Vector2(1920.0, 1920.0)
	cell.object_indices = [0]
	r.cells.append(cell)
	for _i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 0
		r.tiles.append(t)
	return r

func _cedge(v0: int, v1: int, cell_from: int, cell_to: int, flags: int) -> BmsReader.CollisionEdge:
	var e := BmsReader.CollisionEdge.new()
	e.v0 = v0
	e.v1 = v1
	e.cell_from = cell_from
	e.cell_to = cell_to
	e.flags = flags
	return e

## A 4 x 4 trunk about its origin whose outline blocks from both sides (flag
## 3, every real tree trunk's in Jangan, MEASURED round 851).
func _trunk() -> BmsReader.CollisionMesh:
	var cm := BmsReader.CollisionMesh.new()
	for p in [Vector3(-2, 0, -2), Vector3(2, 0, -2), Vector3(2, 0, 2), Vector3(-2, 0, 2)]:
		var v := BmsReader.CollisionVertex.new()
		v.position = p
		cm.vertices.append(v)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		var c := BmsReader.CollisionCell.new()
		c.a = tri[0]
		c.b = tri[1]
		c.c = tri[2]
		cm.cells.append(c)
	cm.outline_edges.append(_cedge(0, 1, 0, BmsReader.NO_CELL, 3))
	cm.outline_edges.append(_cedge(1, 2, 0, BmsReader.NO_CELL, 3))
	cm.outline_edges.append(_cedge(2, 3, 1, BmsReader.NO_CELL, 3))
	cm.outline_edges.append(_cedge(3, 0, 1, BmsReader.NO_CELL, 3))
	cm.internal_edges.append(_cedge(0, 2, 0, 1, 4))
	return cm

func _walk(st: Dictionary, graph: NavGraph, frames: int) -> bool:
	var walled := false
	for _i in range(frames):
		if not bool(st["moving"]):
			break
		walled = CosWalk.advance(st, graph, Transform3D.IDENTITY, 0.0, 1.0 / 60.0)
		if walled:
			break
		if st["pos"] == st["dest"]:
			st["moving"] = false
	return walled

func _initialize() -> void:
	var placed := NavGraph.place(_trunk(), 0, Vector3(102.0, 0.0, 100.0), 0.0)
	var list: Array[NavGraph.PlacedObject] = [placed]
	var graph := NavGraph.build(_region(), list)

	# Into the trunk: the leg ends at its face, CONTACT_PUSH short.
	var st := {"pos": Vector2(80, 100), "dest": Vector2(130, 100), "speed": 50.0, "moving": true}
	var walled := _walk(st, graph, 600)
	var at: Vector2 = st["pos"]
	_check(walled and not bool(st["moving"]), "a leg into the trunk is stopped by it")
	_check(absf(at.x - (100.0 - NavGraph.CONTACT_PUSH)) < 0.001 and absf(at.y - 100.0) < 1e-4,
		"it stands at the trunk's face (%.4f, %.4f)" % [at.x, at.y])

	# Beside the trunk: the whole leg.
	var beside := {"pos": Vector2(80, 110), "dest": Vector2(130, 110), "speed": 50.0, "moving": true}
	_check(not _walk(beside, graph, 600) and beside["pos"] == Vector2(130, 110), "a leg beside the trunk reaches its end")

	# From the face again: no step into it.
	var again := {"pos": at, "dest": Vector2(130, 100), "speed": 50.0, "moving": true}
	_check(_walk(again, graph, 60) and (again["pos"] as Vector2).x <= at.x + 0.001, "a leg from the face does not enter the trunk")

	# No graph: the straight step, through where the trunk would be.
	var bare := {"pos": Vector2(80, 100), "dest": Vector2(130, 100), "speed": 50.0, "moving": true}
	_check(not _walk(bare, null, 600) and bare["pos"] == Vector2(130, 100), "with no graph the leg is the straight one")

	# NEGATIVE: the straight step alone (MonsterMotion.step, the walk before
	# round 851) runs through the trunk.
	var p := Vector2(80, 100)
	for _i in range(600):
		p = MonsterMotion.step(p, Vector2(130, 100), 50.0, 1.0 / 60.0)
	_check(p == Vector2(130, 100), "NEGATIVE: the straight step alone passes the trunk")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
