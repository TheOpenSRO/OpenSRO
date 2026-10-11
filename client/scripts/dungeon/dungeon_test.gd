extends SceneTree

## Round 773: dungeons -- the `.dof` and dungeoninfo readers (DofReader), the
## zone label and the one mirror (DungeonWorld), the rooms' walkable graph
## (NavGraph.build_dungeon: unbounded space, no terrain, floors that stack),
## and the dungeon forms on the wire (DestMoveNet, UserSpawnNet). Synthetic
## fixtures only; tools/dof_probe.gd measures the real files.
##   godot4 --headless --path client --script res://scripts/dungeon/dungeon_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_dof()
	_info()
	_block_transform()
	_zone_labels()
	_graph()
	_stitch()
	_wire()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- a synthetic .dof -------------------------------------------------------

class _W:
	var b := PackedByteArray()

	func u8(v: int) -> void:
		b.append(v & 0xff)

	func u32(v: int) -> void:
		var at := b.size()
		b.resize(at + 4)
		b.encode_u32(at, v & 0xffffffff)

	func f(v: float) -> void:
		var at := b.size()
		b.resize(at + 4)
		b.encode_float(at, v)

	func v3(v: Vector3) -> void:
		f(v.x)
		f(v.y)
		f(v.z)

	func s(t: String) -> void:
		var raw := t.to_ascii_buffer()
		u32(raw.size())
		b.append_array(raw)

## One block with one object (flag 4: an extra u32) and one light, a links
## section and the two name lists -- every section ending where the next
## begins, as the real files do.
func _dof_bytes() -> PackedByteArray:
	var w := _W.new()
	w.b.append_array("JMXVDOF 0101".to_ascii_buffer())
	for i in 8:
		w.u32(0) # P0..P7, patched below
	while w.b.size() < 0x44:
		w.u8(0)
	w.v3(Vector3(-100, -10, -200)) # the AABB at P7 = 0x44
	w.v3(Vector3(300, 50, 400))
	while w.b.size() < 0x74:
		w.u8(0)
	var p0 := w.b.size()
	w.u32(1) # one block
	w.s("res\\dun\\room.bsr")
	w.s("room_01")
	w.u32(0)
	w.v3(Vector3(1000, 5, -2000))
	w.f(PI / 2.0)
	w.u32(1) # an entrance
	w.v3(Vector3(-50, 0, -60))
	w.v3(Vector3(50, 20, 60))
	w.u32(0xff565329)
	w.u32(0xff2c2306)
	w.v3(Vector3(-150, 1456, 0.001))
	w.u8(1) # hasA
	for i in 4:
		w.f(1.0)
	w.u8(0) # no B
	w.s("")
	w.u32(0) # room 0
	w.u32(0) # floor 0
	w.u32(1)
	w.u32(7) # neighbours [7]
	w.u32(2)
	w.u32(7)
	w.u32(8) # visible [7, 8]
	w.u32(1) # one object
	w.u32(0) # no obstacle
	w.s("lamp")
	w.s("res\\dun\\lamp.bsr")
	w.v3(Vector3(1010, 6, -1990))
	w.v3(Vector3(0, PI, 0))
	w.v3(Vector3(1, 1, 1))
	w.u32(4)
	w.u32(3)
	w.f(2.5)
	w.u32(99) # flag 4's extra word
	w.u32(1) # one light
	w.s("light01")
	for i in 15:
		w.f(float(i))
	var p1 := w.b.size()
	w.u32(1)
	w.u32(1)
	w.u32(0)
	var p4 := w.b.size()
	w.u32(1)
	w.s("DH_A01_F01_ROOM_01")
	w.u32(1)
	w.s("DH_A01_FLOOR01")
	w.b.encode_u32(12, p0)
	w.b.encode_u32(16, p1)
	w.b.encode_u32(28, p4)
	w.b.encode_u32(40, 0x44)
	return w.b

func _dof() -> void:
	var data := _dof_bytes()
	var d := DofReader.parse(data)
	_check(d != null, "a well-formed .dof parses")
	if d == null:
		return
	_check(d.blocks.size() == 1, "one block")
	var b: DofReader.Block = d.blocks[0]
	_check(b.path == "res\\dun\\room.bsr" and b.name == "room_01", "the block's path and name")
	_check(b.position == Vector3(1000, 5, -2000) and is_equal_approx(b.yaw, PI / 2.0), "the block's position and yaw")
	_check(b.flags == 1 and b.aabb == AABB(Vector3(-50, 0, -60), Vector3(100, 20, 120)), "the entrance flag and the local bounds")
	_check(b.color_a == 0xff565329 and b.color_b == 0xff2c2306 and b.fog == Vector3(-150, 1456, 0.001), "the light, the fog colour and the fog's three floats")
	_check(b.neighbours == PackedInt32Array([7]) and b.visible == PackedInt32Array([7, 8]), "the neighbour and visible lists")
	_check(b.objects.size() == 1 and (b.objects[0] as DofReader.Obj).path == "res\\dun\\lamp.bsr" \
		and (b.objects[0] as DofReader.Obj).flags == 4 and is_equal_approx((b.objects[0] as DofReader.Obj).radius, 2.5),
		"the object, its flag-4 extra word skipped")
	_check(b.lights.size() == 1 and (b.lights[0] as DofReader.Light).position() == Vector3(0, 1, 2), "the light's position")
	_check(d.links.size() == 1 and d.links[0] == PackedInt32Array([0]), "the links section")
	_check(d.floor_name(0) == "DH_A01_FLOOR01" and d.room_names[0] == "DH_A01_F01_ROOM_01", "the floor and room names")
	_check(d.aabb == AABB(Vector3(-100, -10, -200), Vector3(400, 60, 600)), "the dungeon's bounds")
	_check(DofReader.parse(data.slice(0, data.size() - 3)) == null, "a truncated file is refused")
	var shifted := data.duplicate()
	shifted.encode_u32(16, shifted.decode_u32(16) + 4)
	_check(DofReader.parse(shifted) == null, "a section that does not end where the next begins is refused")
	var bad := data.duplicate()
	bad[9] = 0x32 # "0201"
	_check(DofReader.parse(bad) == null, "another magic is refused")

func _info() -> void:
	var text := "// dungeon info\n1\t1\t\"Dungeon\\wchina\\Dunhwang_Cv.dof\"\n0\t2\t\"Dungeon\\off.dof\"\n1\t7\t\"Dungeon\\china\\jinsi_floor01.dof\"\n1\t40000\t\"bad.dof\"\n"
	var ascii := DofReader.parse_info(text.to_ascii_buffer())
	_check(ascii.size() == 2 and ascii.get(0x8001) == "Dungeon\\wchina\\Dunhwang_Cv.dof" and ascii.get(0x8007) == "Dungeon\\china\\jinsi_floor01.dof",
		"dungeoninfo: enabled rows, rid = iRid | 0x8000, quotes stripped, an iRid past 0x7FFF dropped")
	var utf16 := PackedByteArray([0xFF, 0xFE])
	utf16.append_array(text.to_utf16_buffer())
	_check(DofReader.parse_info(utf16) == ascii, "dungeoninfo in UTF-16 with a BOM reads the same")
	_check(DofReader.is_dungeon_region(0x8001) and DofReader.is_dungeon_region(-32767) and not DofReader.is_dungeon_region(0x61A8),
		"bit 15 (or a negative signed short) is a dungeon region")

func _block_transform() -> void:
	var b := DofReader.Block.new()
	b.position = Vector3(1000, 5, -2000)
	b.yaw = PI / 2.0
	b.aabb = AABB(Vector3(-50, 0, -60), Vector3(100, 20, 120))
	# READ FUN_0043d220: local (x, z) -> (x cos - z sin + px, x sin + z cos + pz).
	var p := b.to_dungeon(Vector3(10, 1, 0))
	_check(p.is_equal_approx(Vector3(1000, 6, -1990)), "a block's local +x turns to dungeon +z at a quarter turn")
	_check(b.to_local(p).is_equal_approx(Vector3(10, 1, 0)), "to_local undoes to_dungeon")
	_check(b.contains(Vector3(1000, 10, -2000)) and not b.contains(Vector3(1100, 10, -2000)), "contains tests the turned bounds")
	# The same turn NavGraph.place gives the room's navigation mesh.
	var cm := BmsReader.CollisionMesh.new()
	var v := BmsReader.CollisionVertex.new()
	v.position = Vector3(10, 1, 0)
	cm.vertices.append(v)
	var placed := NavGraph.place(cm, 0, b.position, b.yaw)
	_check(placed.vertices[0].is_equal_approx(p), "NavGraph.place puts a room's vertex where the block transform does")

func _zone_labels() -> void:
	_check(DungeonWorld.rid_of_zone("dungeon/32769") == 0x8001, "dungeon/32769 is 0x8001")
	_check(DungeonWorld.rid_of_zone("dungeon/1") == -1 and DungeonWorld.rid_of_zone("97/168") == -1 \
		and DungeonWorld.rid_of_zone("jangan") == -1 and DungeonWorld.rid_of_zone("dungeon/x") == -1,
		"any other label is not a dungeon")
	_check(DungeonWorld.zone_of(0x8007) == "dungeon/32775", "zone_of is rid_of_zone's inverse")
	_check(DungeonWorld.to_world(Vector3(1011, -11, -862)) == Vector3(1011, -11, 862) \
		and DungeonWorld.to_dungeon(Vector3(1011, -11, 862)) == Vector3(1011, -11, -862), "the one z mirror, both ways")
	_check(DungeonWorld.block_colour(0xff565329) == Color8(0x56, 0x53, 0x29), "a block colour is its RGB bytes")

func _cedge(v0: int, v1: int, cell_from: int, cell_to: int, flags: int) -> BmsReader.CollisionEdge:
	var e := BmsReader.CollisionEdge.new()
	e.v0 = v0
	e.v1 = v1
	e.cell_from = cell_from
	e.cell_to = cell_to
	e.flags = flags
	return e

## A flat square room as two cells, outline edges 0-1, 1-2, 2-3, 3-0 with
## the given flags (as nav_graph_test's _quad).
func _room(points: Array, flags: Array) -> BmsReader.CollisionMesh:
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
	cm.outline_edges.append(_cedge(0, 1, 0, BmsReader.NO_CELL, flags[0]))
	cm.outline_edges.append(_cedge(1, 2, 0, BmsReader.NO_CELL, flags[1]))
	cm.outline_edges.append(_cedge(2, 3, 1, BmsReader.NO_CELL, flags[2]))
	cm.outline_edges.append(_cedge(3, 0, 1, BmsReader.NO_CELL, flags[3]))
	cm.internal_edges.append(_cedge(0, 2, 0, 1, 4))
	return cm

func _square(x0: float, y: float) -> Array:
	return [Vector3(x0, y, 0), Vector3(x0 + 100, y, 0), Vector3(x0 + 100, y, 100), Vector3(x0, y, 100)]

## Two rooms side by side far outside one region's [0, 1920) -- joined by a
## linked (0x08) edge, walled elsewhere -- and a third stacked 200 above the
## first.
func _graph() -> void:
	var placed: Array[NavGraph.PlacedObject] = []
	placed.append(NavGraph.place(_room(_square(-5000, 0), [3, 8, 3, 3]), 0, Vector3.ZERO, 0.0))
	placed.append(NavGraph.place(_room(_square(-4900, 0), [3, 3, 3, 8]), 1, Vector3.ZERO, 0.0))
	placed.append(NavGraph.place(_room(_square(-5000, 200), [3, 3, 3, 3]), 2, Vector3.ZERO, 0.0))
	var g := NavGraph.build_dungeon(placed)
	_check(g.dungeon and g.objects_at(-4950, 50).has(0) and g.objects_at(-4850, 50).has(1), "rooms are found by their footprint outside [0, 1920)")
	_check(g.objects_at(30000, 30000).is_empty(), "nothing where no room is")
	_check(is_equal_approx(g.landing_height_at(-4950, 50), 200.0), "no reference: the highest floor")
	_check(is_equal_approx(g.landing_height_at(-4950, 50, 5.0), 0.0) and is_equal_approx(g.landing_height_at(-4950, 50, 190.0), 200.0),
		"a reference height picks the floor nearest it")
	_check(is_equal_approx(g.landing_height_at(0, 0), 0.0) and is_equal_approx(g.landing_height_at(0, 0, 7.0), 7.0),
		"off every room: the reference, or 0 -- never NAN")
	var s := g.surface_at(-4950, 50, 3.0)
	_check(not s.is_terrain and s.object_index == 0, "surface_at finds the room under the mover's own height")
	var walk := g.step_tracked(Vector3(-4950, 0, 50), Vector2(100, 0), 0, true)
	_check(walk.standing_on == 1 and is_equal_approx(walk.position.x, -4850.0) and is_equal_approx(walk.position.y, 0.0),
		"a walk across the linked edge lands on the next room")
	var wall := g.step_tracked(Vector3(-4850, 0, 50), Vector2(100, 0), 1, false)
	_check(wall.blocked and wall.standing_on == 1 and wall.position.x < -4800.0, "a room's wall stops the walk")
	# An open outline edge (0) with no room beyond is the dungeon's edge: a wall.
	var lone: Array[NavGraph.PlacedObject] = []
	lone.append(NavGraph.place(_room(_square(-5000, 0), [3, 3, 3, 0]), 0, Vector3.ZERO, 0.0))
	var g2 := NavGraph.build_dungeon(lone)
	var out := g2.step_tracked(Vector3(-4950, 0, 50), Vector2(-100, 0), 0, false)
	_check(out.blocked and out.standing_on == 0 and out.position.x > -5000.0 and is_equal_approx(out.position.y, 0.0),
		"an open edge with no room beyond does not drop the mover off the rooms")
	var lost := g2.step_tracked(Vector3(30000, 42, 30000), Vector2(10, 0), NavGraph.ON_TERRAIN, true)
	_check(is_equal_approx(lost.position.y, 42.0), "off every room the mover keeps its height (no terrain at 0)")

## Round 778: two rooms whose linked edges do not quite meet -- the next
## room starts 0.04 past the first's edge (MEASURED: most of the tomb B3
## seams that stopped the player, tools/dungeon_wall_census.gd) -- and a pair
## 6 apart, beyond the stitch reach. READ FUN_0043ed30 / FUN_0045ec80: ends
## within 5.0 pair the edges; the walk hands the mover to the partner's cell.
func _stitch() -> void:
	var gap := 0.04
	var placed: Array[NavGraph.PlacedObject] = []
	placed.append(NavGraph.place(_room(_square(-5000, 0), [3, 8, 3, 3]), 0, Vector3.ZERO, 0.0))
	placed.append(NavGraph.place(_room(_square(-4900 + gap, 0), [3, 3, 3, 8]), 1, Vector3.ZERO, 0.0))
	var g := NavGraph.build_dungeon(placed, {0: PackedInt32Array([1]), 1: PackedInt32Array([0])})
	_check(g.dungeon_links.get(Vector2i(0, 1)) == Vector2i(1, 3) and g.dungeon_links.get(Vector2i(1, 3)) == Vector2i(0, 1),
		"each linked edge is stitched to its neighbour's (either way round)")
	var walk := g.step_tracked(Vector3(-4910, 0, 50), Vector2(20, 0), 0, false)
	# The hand-off nudges the mover up to 0.2 toward the partner cell's
	# centre (READ FUN_0045dc60), so the end point moves by at most that.
	_check(not walk.blocked and walk.standing_on == 1 and Vector2(walk.position.x, walk.position.z).distance_to(Vector2(-4890, 50)) <= 0.21,
		"a walk over the stitched seam lands on the next room (%s on %d)" % [walk.position, walk.standing_on])
	var back := g.step_tracked(Vector3(-4890, 0, 50), Vector2(-20, 0), 1, false)
	_check(not back.blocked and back.standing_on == 0 and Vector2(back.position.x, back.position.z).distance_to(Vector2(-4910, 50)) <= 0.21,
		"and back (%s on %d)" % [back.position, back.standing_on])
	# Not a neighbour: no stitch (the list is the client's +0x108).
	var g_nolist := NavGraph.build_dungeon(placed, {0: PackedInt32Array(), 1: PackedInt32Array()})
	_check(g_nolist.dungeon_links.is_empty(), "only the block's listed neighbours are stitched")
	# Ends 6 apart: past the 5.0 reach, unstitched; the floor beyond is
	# within DUNGEON_SEAM_REACH only when the gap is.
	var far: Array[NavGraph.PlacedObject] = []
	far.append(NavGraph.place(_room(_square(-5000, 0), [3, 8, 3, 3]), 0, Vector3.ZERO, 0.0))
	far.append(NavGraph.place(_room(_square(-4894, 0), [3, 3, 3, 8]), 1, Vector3.ZERO, 0.0))
	var gf := NavGraph.build_dungeon(far, {0: PackedInt32Array([1]), 1: PackedInt32Array([0])})
	_check(gf.dungeon_links.is_empty(), "edges whose ends are 6 apart are not stitched")
	var wall := gf.step_tracked(Vector3(-4910, 0, 50), Vector2(30, 0), 0, false)
	_check(wall.blocked and wall.standing_on == 0, "and a 6-unit gap stays a wall")
	var near: Array[NavGraph.PlacedObject] = []
	near.append(NavGraph.place(_room(_square(-5000, 0), [3, 8, 3, 3]), 0, Vector3.ZERO, 0.0))
	near.append(NavGraph.place(_room(_square(-4899.5, 0), [3, 3, 3, 8]), 1, Vector3.ZERO, 0.0))
	var gn := NavGraph.build_dungeon(near)
	var over := gn.step_tracked(Vector3(-4910, 0, 50), Vector2(20, 0), 0, false)
	_check(not over.blocked and over.standing_on == 1, "an unstitched linked edge hands over to floor within DUNGEON_SEAM_REACH")

func _wire() -> void:
	var m := DestMoveNet.encode_dungeon_destination(0x8001, 1011.7, -11.2, -862.9)
	_check(m.size() == 15 and m[0] == 1 and m.decode_u16(1) == 0x8001 and m.decode_s32(3) == 1011 \
		and m.decode_s32(7) == -11 and m.decode_s32(11) == -862, "0x7021's dungeon form: rid, three i32 truncated")
	var e := PackedByteArray()
	e.resize(4)
	e.encode_u32(0, 77)
	e.append_array(m.slice(0, 15))
	e.append(1)
	var src := PackedByteArray()
	src.resize(14)
	src.encode_u16(0, 0x8001)
	src.encode_s32(2, 10117)
	src.encode_float(6, -11.5)
	src.encode_s32(10, -8629)
	e.append_array(src)
	var echo := DestMoveNet.decode_echo(e)
	_check(echo.error == "" and echo.region == 0x8001 and echo.local == Vector3i(1011, -11, -862), "0xB021's dungeon destination")
	_check(echo.has_source and echo.source_region == 0x8001 and echo.source_local.is_equal_approx(Vector3(1011.7, -11.5, -862.9)),
		"0xB021's dungeon source: i32 tenths")
	# The autoload's script, statically (no autoload under --script).
	(load("res://scripts/net/net_client.gd") as GDScript).resolve_echo(echo, Vector2i(-1, -1))
	_check(echo.dest_world == Vector3(1011, -11, 862) and echo.source_world.is_equal_approx(Vector3(1011.7, -11.5, 862.9)),
		"the echo's world points are dungeon space mirrored, whatever the frame")
	_check(UserSpawnNet.world_xz(0x8001, 5.0, 7.0, Vector2i(97, 168)) == Vector2(5, -7), "a dungeon record's position is (x, -z)")
	_check(UserSpawnNet.world_xz(0x61A8, 960.0, 960.0, Vector2i(97, 168)) == Vector2.ZERO, "a field record's is unchanged")
