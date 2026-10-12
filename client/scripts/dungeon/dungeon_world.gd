extends RefCounted
class_name DungeonWorld

## A dungeon's world (round 773): its rooms and their objects placed from the
## `.dof` (DofReader), and one walkable graph over the rooms' own navigation
## meshes (NavGraph.build_dungeon). No terrain, no `.nvm`, no region grid.
##
## Space: dungeon space is the `.dof`'s (and teleportdata's, npcpos's,
## objectstring's for a dungeon row). The world draws it under one group with
## the field's single z -> -z mirror (`scale.z = -1`), so a server world point
## in a dungeon is (dx, dy, -dz) -- the server's contract (round 773,
## worldmap.DungeonZone) -- and the group's local space IS dungeon space, as a
## terrain group's local space is region-local in the field.
##
## Rooms: each block's `.bsr` at the block's position, turned by its yaw the
## way a field object is (`rotation.y = NavGraph.godot_yaw(yaw)`): the block
## transform READ in RTNavMeshDungeon FUN_0043d220 is the same row-vector Y
## rotation as the field's FUN_0043cda0 (DofReader.Block.to_dungeon), and
## MEASURED by `stitch_census`: the rooms' linked (0x08) outline edges meet
## their neighbours' under this sign (tools/dof_probe.gd --stitch).
## Objects: each block object's `.bsr` at its dungeon-space position, its
## Euler y turned the same way (INFERRED from the rooms: the objects' x and z
## angles are 0 in every file MEASURED, y a multiple of pi/2) and its scale.

const ZONE_PREFIX := "dungeon/"

## The dungeon region id a zone label names ("dungeon/32769" -> 0x8001), or
## -1 for any other label. The label is the server's (round 773).
static func rid_of_zone(zone: String) -> int:
	if not zone.begins_with(ZONE_PREFIX):
		return -1
	var tail := zone.substr(ZONE_PREFIX.length())
	if not tail.is_valid_int():
		return -1
	var rid := int(tail)
	return rid if rid >= DofReader.DUNGEON_FLAG and rid <= 0xFFFF else -1

static func zone_of(rid: int) -> String:
	return ZONE_PREFIX + str(rid & 0xFFFF)

## A server world point in a dungeon to dungeon space, and back: the one
## mirror (see the class comment).
static func to_dungeon(world: Vector3) -> Vector3:
	return Vector3(world.x, world.y, -world.z)

static func to_world(dungeon: Vector3) -> Vector3:
	return Vector3(dungeon.x, dungeon.y, -dungeon.z)

## A block's ambient colour (the first of its two ARGB words; which of the two
## is the ambient light is OPEN -- MEASURED the first looks like one: grey-blue
## in the cave, warm in the tomb).
static func block_colour(argb: int) -> Color:
	return Color8((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF)

class Built:
	var rid: int
	var path: String
	var dof: DofReader.Dof
	var group: Node3D
	var graph: NavGraph
	var rooms := 0
	var rooms_without_nav := 0
	var objects := 0
	var missing := PackedStringArray()

## The `.dof` path dungeoninfo.txt names for `rid`, or "".
static func dof_path(data: Pk2Reader, rid: int) -> String:
	if data == null:
		return ""
	var e := ObjectLoader.find_file(data, "Dungeon\\dungeoninfo.txt")
	if e == null:
		return ""
	return String(DofReader.parse_info(data.read_file(e)).get(rid, ""))

## Builds the dungeon `rid` from Data.pk2: null when dungeoninfo names no
## `.dof` for it or the file does not parse. `instance` makes one placed copy
## of a `.bsr` (World3D's ObjectTemplateCache); an invalid Callable builds
## the walkable graph only (tests, probes).
##
## `progress` (round 785), when valid, is called with the fraction of the
## build done (0..1) after each step -- the loading screen's gauge through a
## build that holds the main thread (World3D._load_dungeon; the client
## reports its dungeon load's parts the same way, SWorld::vslot_000 0xa2acd0,
## READ). The steps, each one unit, are OURS: a room's walkable mesh, its
## model, each of its objects, and the walkable graph at the end.
static func build(data: Pk2Reader, rid: int, instance: Callable = Callable(), with_objects: bool = true, progress: Callable = Callable()) -> Built:
	var path := dof_path(data, rid)
	if path == "":
		return null
	var fe := ObjectLoader.find_file(data, path)
	if fe == null:
		return null
	var dof := DofReader.parse(data.read_file(fe))
	if dof == null:
		return null
	var built := Built.new()
	built.rid = rid
	built.path = path
	built.dof = dof
	built.group = Node3D.new()
	built.group.name = "Dungeon_%d" % rid
	built.group.scale.z = -1.0
	var placed: Array[NavGraph.PlacedObject] = []
	var nav_cache := {}
	# The steps the progress counts (above): a walkable mesh per room, the
	# graph, and -- when models are built -- a model per room and its objects.
	var total := dof.blocks.size() + 1
	if instance.is_valid():
		total += dof.blocks.size()
		if with_objects:
			for b_v in dof.blocks:
				total += (b_v as DofReader.Block).objects.size()
	var done := 0
	for i in dof.blocks.size():
		var b: DofReader.Block = dof.blocks[i]
		var key := b.path.to_lower()
		if not nav_cache.has(key):
			nav_cache[key] = NavObjectSource.load_collision(data, b.path)
		var coll: BmsReader.CollisionMesh = nav_cache[key]
		if coll != null:
			var po := NavGraph.place(coll, i, b.position, b.yaw)
			po.set_meta("model", "%s (room %d)" % [b.path.get_file(), i])
			placed.append(po)
		else:
			built.rooms_without_nav += 1
		done += 1
		if progress.is_valid():
			progress.call(float(done) / float(total))
		if instance.is_valid():
			var node: Node3D = instance.call(b.path)
			if node == null:
				built.missing.append(b.path)
			else:
				node.name = "Room_%d" % i
				node.position = b.position
				node.rotation.y = NavGraph.godot_yaw(b.yaw)
				built.group.add_child(node)
				built.rooms += 1
			done += 1
			if progress.is_valid():
				progress.call(float(done) / float(total))
			if with_objects:
				for o in b.objects:
					var ob: DofReader.Obj = o
					var on: Node3D = instance.call(ob.path)
					done += 1
					if on == null:
						built.missing.append(ob.path)
					else:
						on.position = ob.position
						on.rotation = Vector3(ob.rotation.x, NavGraph.godot_yaw(ob.rotation.y), ob.rotation.z)
						on.scale = ob.scale
						built.group.add_child(on)
						built.objects += 1
					if progress.is_valid():
						progress.call(float(done) / float(total))
	var neighbours := {}
	for i in dof.blocks.size():
		neighbours[i] = (dof.blocks[i] as DofReader.Block).neighbours
	built.graph = NavGraph.build_dungeon(placed, neighbours)
	if progress.is_valid():
		progress.call(1.0)
	return built

## The block (room) index under a dungeon-space point at about that height,
## or -1: the room whose walkable surface is nearest `y` there, else the
## block whose bounds hold the point.
static func block_under(built: Built, p: Vector3) -> int:
	if built == null:
		return -1
	var s := built.graph.surface_at(p.x, p.z, p.y)
	if not s.is_terrain:
		return s.object_index
	return built.dof.block_at(p, 5.0)

## MEASURED check of the room transform (tools/dof_probe.gd --stitch): of the
## rooms' linked (0x08) outline edges, how many have a linked outline edge of
## ANOTHER room within `tolerance` at both ends (either direction, 2D, and
## within `tolerance` in height). Returns {"linked": n, "met": m}.
static func stitch_census(graph: NavGraph, tolerance: float = 0.5) -> Dictionary:
	var ends := {} # quantised endpoint -> [[object, edge], ...]
	var q := func(v: Vector2) -> Vector2i: return Vector2i(roundi(v.x / tolerance), roundi(v.y / tolerance))
	for oi in graph.objects:
		var po: NavGraph.PlacedObject = graph.objects[oi]
		for e in po.edge_flags.size():
			if po.edge_outline[e] == 0 or (po.edge_flags[e] & NavGraph.EDGE_LINKED) == 0:
				continue
			var k: Vector2i = q.call(po.edges[e * 2])
			if not ends.has(k):
				ends[k] = []
			(ends[k] as Array).append([oi, e])
	var linked := 0
	var met := 0
	for oi in graph.objects:
		var po: NavGraph.PlacedObject = graph.objects[oi]
		for e in po.edge_flags.size():
			if po.edge_outline[e] == 0 or (po.edge_flags[e] & NavGraph.EDGE_LINKED) == 0:
				continue
			linked += 1
			var a: Vector2 = po.edges[e * 2]
			var b: Vector2 = po.edges[e * 2 + 1]
			var ya := po.vertices[po.edge_v0[e]].y
			var found := false
			# Candidates share an endpoint with a or b (within a quantum).
			for end in [a, b]:
				var k: Vector2i = q.call(end)
				for dx in [-1, 0, 1]:
					for dz in [-1, 0, 1]:
						var kk := Vector2i(k.x + int(dx), k.y + int(dz))
						if not ends.has(kk):
							continue
						for cand in ends[kk]:
							if int(cand[0]) == oi:
								continue
							var other: NavGraph.PlacedObject = graph.objects[cand[0]]
							var ce: int = cand[1]
							var c: Vector2 = other.edges[ce * 2]
							var d: Vector2 = other.edges[ce * 2 + 1]
							var same := (a.distance_to(c) <= tolerance and b.distance_to(d) <= tolerance) \
								or (a.distance_to(d) <= tolerance and b.distance_to(c) <= tolerance)
							if same and absf(other.vertices[other.edge_v0[ce]].y - ya) <= 2.0 * tolerance + 1.0:
								found = true
								break
						if found:
							break
					if found:
						break
				if found:
					break
			if found:
				met += 1
	return {"linked": linked, "met": met}
