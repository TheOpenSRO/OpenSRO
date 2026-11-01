extends SceneTree

## Round 851: a COS's drawn leg stops at a tree's trunk as the server's walk
## does; round 852: every body's (BodyWalk -- another player, its horse or
## transport, a pet, a monster), walked as World3D walks them: OtherWalk.step
## and, for a leg BodyWalk.meets_wall finds walled, BodyWalk.step. Over
## synthetic data (never real game data):
## `godot4 --headless --path client --script res://scripts/world/body_walk_test.gd`

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

## Walks `leg` (OtherWalk) from `at` as World3D._step_other_legs does, up to
## `frames` frames at 60 a second: [where it stands, whether a wall ended it,
## frames walked].
func _walk(leg: Dictionary, at: Vector3, graph: NavGraph, frames: int) -> Array:
	leg["walled"] = true
	if not bool(leg.get("run", false)):
		var dest: Vector3 = leg["dest"]
		var p := BodyWalk.plan(graph, Transform3D.IDENTITY, at, Vector2(dest.x, dest.z))
		leg["walled"] = int(p["kind"]) == BodyWalk.FRAMES
		if int(p["kind"]) == BodyWalk.STOP:
			# World3D._plan_body_leg: the leg ends at the wall's stop.
			var stop: Vector2 = p["stop"]
			leg["dest"] = Vector3(stop.x, dest.y, stop.y)
			leg["wall"] = true
	for i in range(frames):
		var r := OtherWalk.step(leg, at, 1.0 / 60.0)
		var next: Vector3 = r["pos"]
		if bool(leg["walled"]):
			var w := BodyWalk.step(leg, graph, Transform3D.IDENTITY, at, Vector2(next.x, next.z))
			next = Vector3(w.x, at.y, w.y)
			if bool(leg["blocked"]):
				return [next, true, i + 1]
		at = next
		if bool(r["done"]):
			return [at, bool(leg.get("wall", false)), i + 1]
	return [at, false, frames]

func _initialize() -> void:
	var placed := NavGraph.place(_trunk(), 0, Vector3(102.0, 0.0, 100.0), 0.0)
	var list: Array[NavGraph.PlacedObject] = [placed]
	var graph := NavGraph.build(_region(), list)

	# The plan: a leg through the trunk meets a wall, one beside it does not;
	# no graph, an end outside the region and a heading run are walked a frame
	# at a time.
	_check(BodyWalk.meets_wall(graph, Transform3D.IDENTITY, Vector3(80, 0, 100), Vector2(130, 100)), "a leg through the trunk meets a wall")
	_check(not BodyWalk.meets_wall(graph, Transform3D.IDENTITY, Vector3(80, 0, 110), Vector2(130, 110)), "a leg beside the trunk meets none")
	_check(int(BodyWalk.plan(null, Transform3D.IDENTITY, Vector3(80, 0, 110), Vector2(130, 110))["kind"]) == BodyWalk.FRAMES, "no graph: walked a frame at a time")
	_check(int(BodyWalk.plan(graph, Transform3D.IDENTITY, Vector3(1900, 0, 110), Vector2(1990, 110))["kind"]) == BodyWalk.FRAMES, "an end beyond the region: walked a frame at a time")

	# Another player (or a rider: its root walks its mount's legs) into the
	# trunk: the leg ends at its face, CONTACT_PUSH short, and is over.
	var leg := OtherWalk.to_point(Vector3(130, 0, 100), 50.0)
	var r := _walk(leg, Vector3(80, 0, 100), graph, 600)
	var at: Vector3 = r[0]
	_check(bool(r[1]), "a leg into the trunk is ended by it")
	_check(absf(at.x - (100.0 - NavGraph.CONTACT_PUSH)) < 0.001 and absf(at.z - 100.0) < 1e-4,
		"it stands at the trunk's face (%.4f, %.4f)" % [at.x, at.z])
	# Round 846's catch-up walks into the same face, sooner.
	var fast := OtherWalk.to_point(Vector3(130, 0, 100), 50.0, OtherWalk.CATCH_UP_MAX)
	var rf := _walk(fast, Vector3(80, 0, 100), graph, 600)
	_check(bool(rf[1]) and (rf[0] as Vector3).is_equal_approx(at) and int(rf[2]) < int(r[2]),
		"caught up x3 it stops at the same face (%d frames against %d)" % [int(rf[2]), int(r[2])])

	# The plan's stop is the frame-by-frame walk's (the leg walked through
	# the graph every frame, as for a leg the plan cannot answer).
	var frames_leg := OtherWalk.to_point(Vector3(130, 0, 100), 50.0)
	var fat := Vector3(80, 0, 100)
	for _i in range(600):
		var fr := OtherWalk.step(frames_leg, fat, 1.0 / 60.0)
		var fw := BodyWalk.step(frames_leg, graph, Transform3D.IDENTITY, fat, Vector2((fr["pos"] as Vector3).x, (fr["pos"] as Vector3).z))
		fat = Vector3(fw.x, 0, fw.y)
		if bool(frames_leg["blocked"]):
			break
	_check(bool(frames_leg["blocked"]) and fat.is_equal_approx(at), "the plan's stop is the frame-by-frame walk's (%.4f against %.4f)" % [at.x, fat.x])
	var plan := BodyWalk.plan(graph, Transform3D.IDENTITY, Vector3(80, 0, 100), Vector2(130, 100))
	_check(int(plan["kind"]) == BodyWalk.STOP, "the plan of a leg into the trunk is a stop")

	# Beside the trunk: the whole leg, landing on its point (round 846).
	var beside := OtherWalk.to_point(Vector3(130, 0, 110), 50.0)
	var rb := _walk(beside, Vector3(80, 0, 110), graph, 600)
	_check(not bool(rb[1]) and not bool(beside["walled"]) and not beside.has("wall") and (rb[0] as Vector3).is_equal_approx(Vector3(130, 0, 110)),
		"a leg beside the trunk is the straight one and lands on its point")

	# From the face again: no step into it.
	var again := OtherWalk.to_point(Vector3(130, 0, 100), 50.0)
	var ra := _walk(again, at, graph, 60)
	_check(bool(ra[1]) and (ra[0] as Vector3).x <= at.x + 0.001, "a leg from the face does not enter the trunk")

	# The server's stop just past the face (its f32 point): the body at the
	# face walks toward it and stays (no snap through the trunk).
	var stop := OtherWalk.to_point(Vector3(100.3, 0, 100), 50.0, OtherWalk.CATCH_UP_MAX)
	var rs := _walk(stop, at, graph, 60)
	_check((rs[0] as Vector3).x <= at.x + 0.001, "a stop named inside the trunk leaves the body at its face")

	# A heading run (the arrow keys) into the trunk ends at its face.
	var heading := OtherWalk.on_heading(0, 50.0)
	heading["dir"] = Vector2(1, 0)
	var rh := _walk(heading, Vector3(80, 0, 100), graph, 600)
	_check(bool(rh[1]) and absf((rh[0] as Vector3).x - (100.0 - NavGraph.CONTACT_PUSH)) < 0.001, "a heading run into the trunk ends at its face")

	# No graph: the straight step, through where the trunk would be.
	var bare := OtherWalk.to_point(Vector3(130, 0, 100), 50.0)
	var rn := _walk(bare, Vector3(80, 0, 100), null, 600)
	_check(not bool(rn[1]) and (rn[0] as Vector3).is_equal_approx(Vector3(130, 0, 100)), "with no graph the leg is the straight one")

	# A monster's leg (World3D._step_monster_bodies: MonsterMotion.step, then
	# BodyWalk.step for a walled leg) stops at the same face.
	var p := Vector2(80, 100)
	var mob_plan := BodyWalk.plan(graph, Transform3D.IDENTITY, Vector3(80, 0, 100), Vector2(130, 100))
	var mob_dest: Vector2 = mob_plan["stop"] if int(mob_plan["kind"]) == BodyWalk.STOP else Vector2(130, 100)
	for _i in range(600):
		p = MonsterMotion.step(p, mob_dest, 50.0, 1.0 / 60.0)
		if p == mob_dest:
			break
	_check(absf(p.x - at.x) < 0.001 and absf(p.y - 100.0) < 1e-4, "a monster's leg stops at the same face")

	# NEGATIVE: the straight step alone (OtherWalk before round 852, every
	# observer's body) runs through the trunk.
	var q := Vector3(80, 0, 100)
	var straight := OtherWalk.to_point(Vector3(130, 0, 100), 50.0)
	for _i in range(600):
		var rr := OtherWalk.step(straight, q, 1.0 / 60.0)
		q = rr["pos"]
		if bool(rr["done"]):
			break
	_check(q.is_equal_approx(Vector3(130, 0, 100)), "NEGATIVE: the straight step alone passes the trunk")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
