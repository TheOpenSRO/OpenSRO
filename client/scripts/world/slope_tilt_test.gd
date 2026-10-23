extends SceneTree

## Round 813: monsters and COS lean with the ground (SlopeTilt,
## NvmCollision.terrain_normal, NavGraph.ground_normal_at). Synthetic regions
## and meshes only, no game data. Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## NEGATIVE (by construction): against v0.1.574 SlopeTilt does not exist and
## the suite stops at its first check; with frame()'s factors dropped the
## pitch/roll checks fail; with terrain_normal's split turned the other way
## the triangle checks fail.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: Vector3, b: Vector3, eps: float = 1e-4) -> bool:
	return a.distance_to(b) < eps

func _initialize() -> void:
	if load("res://scripts/world/slope_tilt.gd") == null:
		_check(false, "SlopeTilt exists")
		quit(1)
		return
	_test_factors()
	_test_flat()
	_test_pitch_and_roll()
	_test_eases()
	_test_scene_frames()
	_test_terrain_normal()
	_test_object_normal()
	await _test_body_events()
	print("slope_tilt_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

## Column 80's bytes: pair 0 is (byte 3, byte 2) / 100 (FUN_009c78f0).
func _test_factors() -> void:
	_check(SlopeTilt.factors(0x64146414).is_equal_approx(Vector2(1.0, 0.2)), "a horse's 0x64146414 is (1.0, 0.2)")
	_check(SlopeTilt.factors(0x14141414).is_equal_approx(Vector2(0.2, 0.2)), "a mangnyang's 0x14141414 is (0.2, 0.2)")
	_check(SlopeTilt.factors(0x000041cb).is_equal_approx(Vector2.ZERO), "a tower's 0x000041cb leans (0, 0): its pair 1 is never chosen")
	_check(SlopeTilt.factors(-1).is_equal_approx(Vector2(2.55, 2.55)), "a negative cell reads as its unsigned bytes")

## On flat ground nothing turns, whatever the factors and heading.
func _test_flat() -> void:
	for d in [Vector3(1, 0, 0), Vector3(0.6, 0, -0.8), Vector3(-0.3, 0, 0.9)]:
		_check(SlopeTilt.tilt(Vector3.UP, d, Vector2(1.0, 0.2)).is_equal_approx(Basis.IDENTITY), "flat ground, heading %s: no tilt" % [d])
	_check(SlopeTilt.tilt(Vector3(0.3, 0.9, 0.1).normalized(), Vector3.ZERO, Vector2.ONE).is_equal_approx(Basis.IDENTITY), "no heading: no tilt")

## A slope along the heading pitches the model by atan(k0 tan a); one across
## it rolls the model by atan(k1 tan a) (FUN_009c9400's scaled heights).
func _test_pitch_and_roll() -> void:
	var a := deg_to_rad(30.0)
	var d := Vector3(1, 0, 0)
	# Ground rising along +x: normal (-sin, cos, 0).
	var up_x := Vector3(-sin(a), cos(a), 0)
	var t := SlopeTilt.tilt(up_x, d, Vector2(1.0, 0.2))
	_check(_near(t * d, Vector3(cos(a), sin(a), 0)), "factor 1.0: the front follows the slope (got %s)" % [t * d])
	_check(_near((t * Vector3.UP).normalized(), up_x), "factor 1.0 along the slope: the model stands on the normal")
	var t2 := SlopeTilt.tilt(up_x, d, Vector2(0.2, 0.2))
	var want := Vector3(1.0, 0.2 * tan(a), 0).normalized()
	_check(_near(t2 * d, want), "factor 0.2: the front pitches atan(0.2 tan 30) = %.2f deg" % rad_to_deg(atan(0.2 * tan(a))))
	_check(_near(t * -d, -(t * d)), "the heading's sign does not matter")
	# Ground rising toward -z, across the heading: normal (0, cos, sin).
	var across := Vector3(0, cos(a), sin(a))
	var side0 := Vector3.UP.cross(d).normalized()
	var r := SlopeTilt.tilt(across, d, Vector2(1.0, 0.2))
	var roll := rad_to_deg(asin(absf((r * side0).normalized().y)))
	_check(absf(roll - rad_to_deg(atan(0.2 * tan(a)))) < 0.01, "factor 0.2 across: rolls %.2f deg, not 30" % roll)
	_check(_near(r * d, d), "a slope across the heading leaves the front level")
	var r1 := SlopeTilt.tilt(across, d, Vector2(1.0, 1.0))
	_check(_near((r1 * Vector3.UP).normalized(), across), "factor 1.0 across: the model stands on the normal")
	# READ: never flipped. A face wound downward turns the model over.
	var over := SlopeTilt.tilt(Vector3.DOWN, d, Vector2(1.0, 0.2))
	_check(_near(over * Vector3.UP, Vector3.DOWN) and _near(over * d, d), "a downward normal turns the model over about its front, as the original's rows do")

## The normal eases over 0.3 s, the factors over 0.1 s from (0, 0), both from
## the first normal on; nothing moves before it or after both end.
func _test_eases() -> void:
	var st := SlopeTilt.State.new(0x64146414)
	_check(not st.advance(0.016), "before the first normal nothing is rebuilt")
	var n := Vector3(-0.5, 0.866, 0)
	st.retarget(n)
	_check(st.advance(0.05) and _near(st.n, Vector3.UP.lerp(n, 0.05 / 0.3)), "the normal is a linear lerp, a sixth of the way at 0.05 s")
	_check(st.k.is_equal_approx(Vector2(0.5, 0.1)), "the factors are half way at 0.05 s (got %s)" % [st.k])
	st.advance(0.06)
	_check(st.k.is_equal_approx(Vector2(1.0, 0.2)) and st.k_done, "the factors arrive by 0.1 s")
	st.advance(0.2)
	_check(_near(st.n, n) and st.n_done, "the normal arrives by 0.3 s")
	_check(not st.advance(0.016), "once both arrive nothing is rebuilt")
	# Moving: retargeted every frame, from where it is.
	st.retarget(Vector3.UP)
	st.advance(0.03)
	var expect := n.lerp(Vector3.UP, 0.1)
	_check(_near(st.n, expect), "a new normal eases from the current one")

## In the scene: the terrain group mirrors z. A model facing world +x on
## ground rising toward world +x pitches up toward +x; the same ground in the
## region's frame rises toward region +x too (x is not mirrored).
func _test_scene_frames() -> void:
	var g := Basis.from_scale(Vector3(1, 1, -1))
	var a := deg_to_rad(20.0)
	var n_region := Vector3(-sin(a), cos(a), 0)
	var body := Basis(Vector3.UP, 1.1)
	var front_world := Vector3(1, 0, 0)
	var l := SlopeTilt.in_body(n_region, front_world, Vector2(1.0, 0.2), g, body)
	var world := body * l * body.inverse()
	_check(_near(world * front_world, Vector3(cos(a), sin(a), 0)), "the model's front climbs the slope in the world")
	# Rising toward world -z is rising toward region +z.
	var n2 := Vector3(0, cos(a), -sin(a))
	var l2 := SlopeTilt.in_body(n2, Vector3(0, 0, 1), Vector2(1.0, 0.2), g, Basis.IDENTITY)
	_check(_near(l2 * Vector3(0, 0, -1), Vector3(0, sin(a), -cos(a))), "through the mirror: a front toward world -z climbs ground rising that way")

func _region(fill: float) -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(fill)
	var cell := NvmReader.Cell.new()
	cell.rect_min = Vector2.ZERO
	cell.rect_max = Vector2(1920.0, 1920.0)
	r.cells.append(cell)
	for _i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 0
		r.tiles.append(t)
	return r

## FUN_00403980: the tile's own triangle, split on (x0, z0)-(x1, z1); flat on
## a solid plane the character stands on.
func _test_terrain_normal() -> void:
	var side := NvmReader.HEIGHT_MAP_SIDE
	var r := _region(0.0)
	# Tile (col 1, row 2): only its (x1, z1) corner is raised, by 10.
	r.heights[3 * side + 2] = 10.0
	# (35, 45): x fraction 0.75, z fraction 0.25 -> the (x0,z0),(x1,z0),(x1,z1) triangle.
	var lower := NvmCollision.terrain_normal(r, 35.0, 45.0, 0.0)
	_check(_near(lower, Vector3(0, 400, -200).normalized()), "z fraction below x fraction: (20(h00-h10), 400, -20(h11-h10)) (got %s)" % [lower])
	var upper := NvmCollision.terrain_normal(r, 25.0, 55.0, 0.0)
	_check(_near(upper, Vector3(-200, 400, 0).normalized()), "else: (-20(h11-h01), 400, 20(h00-h01)) (got %s)" % [upper])
	_check(_near(NvmCollision.terrain_normal(r, 300.0, 300.0, 0.0), Vector3.UP), "flat tiles are straight up")
	r.plane_types.resize(NvmReader.PLANE_COUNT)
	r.plane_types.fill(0)
	r.plane_heights.resize(NvmReader.PLANE_COUNT)
	r.plane_heights.fill(5.0)
	r.plane_types[0] = NvmCollision.SOLID_PLANE_BIT
	_check(_near(NvmCollision.terrain_normal(r, 35.0, 45.0, 5.0), Vector3.UP), "on a solid plane, at its height: straight up")
	_check(_near(NvmCollision.terrain_normal(r, 35.0, 45.0, 0.0), lower), "under it, on the ground: the ground's triangle")

## CRTNavCellTri::vslot_004 / FUN_0045c420: the cell's own face normal, from
## its vertices in file order, never flipped; the surface nearest the body's
## height; a dungeon straight up.
func _test_object_normal() -> void:
	var g := NavGraph.build(_region(0.0), _ramp_list([0, 2, 1], [0, 3, 2]))
	# The ramp climbs 10 over 40 toward +z; at z 120 its deck is at 5.
	var on_ramp := g.ground_normal_at(120.0, 120.0, 5.0)
	_check(_near(on_ramp, Vector3(0, 40, -10).normalized()), "on the ramp: its cell's normal (got %s)" % [on_ramp])
	_check(_near(g.ground_normal_at(120.0, 120.0, 0.0), Vector3.UP), "under it on the terrain: the terrain's")
	var down := NavGraph.build(_region(0.0), _ramp_list([0, 1, 2], [0, 2, 3]))
	_check(down.ground_normal_at(120.0, 120.0, 5.0).y < 0.0, "a cell wound the other way points down: never flipped")
	g.dungeon = true
	_check(_near(g.ground_normal_at(120.0, 120.0, 5.0), Vector3.UP), "in a dungeon: straight up")

func _ramp_list(c0: Array, c1: Array) -> Array[NavGraph.PlacedObject]:
	var cm := BmsReader.CollisionMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(40, 0, 0), Vector3(40, 10, 40), Vector3(0, 10, 40)]:
		var v := BmsReader.CollisionVertex.new()
		v.position = p
		cm.vertices.append(v)
	for tri in [c0, c1]:
		var c := BmsReader.CollisionCell.new()
		c.a = tri[0]
		c.b = tri[1]
		c.c = tri[2]
		cm.cells.append(c)
	var out: Array[NavGraph.PlacedObject] = [NavGraph.place(cm, 0, Vector3(100, 0, 100), 0.0)]
	return out

## SlopeTiltBody: a move or a turn files the body in the hot set once (the
## original's slot-15 events); standing still files nothing.
func _test_body_events() -> void:
	var hot := {}
	var body := Node3D.new()
	body.set_script(SlopeTiltBody)
	(body as SlopeTiltBody).hot = hot
	body.set_notify_transform(true)
	root.add_child(body)
	await process_frame
	hot.clear()
	await process_frame
	_check(hot.is_empty(), "a body standing still reports nothing")
	body.position = Vector3(3, 0, 0)
	await process_frame
	_check(hot.has(body.get_instance_id()), "a move reports the body")
	hot.clear()
	body.rotation.y = 1.0
	await process_frame
	_check(hot.has(body.get_instance_id()), "a turn reports the body")
	body.queue_free()
