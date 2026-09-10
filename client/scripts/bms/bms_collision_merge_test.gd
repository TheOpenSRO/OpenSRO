extends SceneTree

## Exercises BmsCollision.merge against synthetic meshes (never real game
## data):
##   godot4 --headless --path client --script res://scripts/bms/bms_collision_merge_test.gd
##
## Merging is index arithmetic, which is the kind of thing that fails
## silently: a cell pointing at the wrong vertex still builds a triangle,
## just somewhere else. Every assertion here is about where an index landed.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A mesh of `n` vertices at x = base + i, one cell over the first three,
## one outline edge and one internal edge.
func _mesh(n: int, base: float) -> BmsReader.CollisionMesh:
	var mesh := BmsReader.CollisionMesh.new()
	for i in range(n):
		var v := BmsReader.CollisionVertex.new()
		v.position = Vector3(base + float(i), 0.0, 0.0)
		mesh.vertices.append(v)
	var cell := BmsReader.CollisionCell.new()
	cell.a = 0
	cell.b = 1
	cell.c = 2
	mesh.cells.append(cell)
	var outline := BmsReader.CollisionEdge.new()
	outline.v0 = 0
	outline.v1 = 1
	outline.cell_from = 0
	outline.cell_to = BmsReader.NO_CELL
	# Blocking, so blocking_edges has something to find. Every real outline
	# edge carries NO_CELL on its far side and blocks.
	outline.flags = BmsCollision.BLOCKING_FLAG_MASK
	mesh.outline_edges.append(outline)
	var internal := BmsReader.CollisionEdge.new()
	internal.v0 = 1
	internal.v1 = 2
	internal.cell_from = 0
	internal.cell_to = 0
	mesh.internal_edges.append(internal)
	return mesh

func _init() -> void:
	var a := _mesh(3, 0.0)
	var b := _mesh(4, 100.0)
	var merged := BmsCollision.merge([a, b])

	_check(merged.vertices.size() == 7, "vertices concatenate (got %d)" % merged.vertices.size())
	_check(merged.cells.size() == 2, "cells concatenate (got %d)" % merged.cells.size())

	# The second mesh's cell must point at the second mesh's vertices.
	var second: BmsReader.CollisionCell = merged.cells[1]
	_check(second.a == 3 and second.b == 4 and second.c == 5,
		"the second mesh's cell shifts by the first's vertex count (got %d,%d,%d)"
			% [second.a, second.b, second.c])
	_check(is_equal_approx(merged.vertices[second.a].position.x, 100.0),
		"and lands on the vertex it did before merging (x=%.1f)"
			% merged.vertices[second.a].position.x)

	# The first mesh's indices must not move.
	var first: BmsReader.CollisionCell = merged.cells[0]
	_check(first.a == 0 and first.b == 1 and first.c == 2,
		"the first mesh's cell is untouched (got %d,%d,%d)" % [first.a, first.b, first.c])

	_check(merged.outline_edges.size() == 2 and merged.internal_edges.size() == 2,
		"edges concatenate into their own lists")
	_check(merged.outline_edges[1].v0 == 3 and merged.outline_edges[1].v1 == 4,
		"an outline edge's vertices shift (got %d,%d)"
			% [merged.outline_edges[1].v0, merged.outline_edges[1].v1])
	_check(merged.internal_edges[1].cell_from == 1,
		"an internal edge's cell reference shifts by the cell count (got %d)"
			% merged.internal_edges[1].cell_from)

	# NO_CELL is a marker, not an index. Shifting it would turn a boundary
	# edge into a reference to a real cell -- the far side of a wall
	# becoming walkable.
	_check(merged.outline_edges[1].cell_to == BmsReader.NO_CELL,
		"NO_CELL stays NO_CELL (got %d)" % merged.outline_edges[1].cell_to)

	# Every blocking edge still resolves to a vertex that exists, which is
	# what NavGraph.place silently drops when it does not.
	var blocking := BmsCollision.blocking_edges(merged)
	var in_range := true
	for edge in blocking:
		if edge.v0 >= merged.vertices.size() or edge.v1 >= merged.vertices.size():
			in_range = false
	_check(not blocking.is_empty(), "the merged mesh still has blocking edges (%d)" % blocking.size())
	_check(in_range, "every blocking edge indexes a vertex that exists")

	# Degenerate inputs must not crash the region load.
	_check(BmsCollision.merge([]).cells.is_empty(), "merging nothing gives an empty mesh")
	_check(BmsCollision.merge([null, a]).cells.size() == 1, "a null part is skipped")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
