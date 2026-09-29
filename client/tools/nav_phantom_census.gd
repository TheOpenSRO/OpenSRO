extends SceneTree

## Dev tool (round 644): how many object navigation meshes carry an edge that
## the graph's old on-object rule met but the client's own walk never can.
##
## The client walks a mover who is on an object cell to cell
## (`CRTNavMeshObj::FUN_0044add0`): from the current cell it tests only that
## cell's own three edge slots (`CRTNavCellTri::FUN_0045dec0`, filled in
## file order by `RTNavMeshObj::FUN_0045dcf0` from every edge naming the
## cell), and steps into the neighbour through an open internal edge. Until
## round 644 the graph tested EVERY edge of the object in plan view instead.
## The two agree on a single-level mesh, where no edge passes over another
## cell. They disagree wherever a mesh has parts at different heights that
## overlap in plan: a bridge deck over its own piers, an upper floor over a
## lower one. There the old rule met the lower part's outline from the deck
## above -- a wall that is not there (Black Robber Den, round 644), or an
## exit that drops the mover to the terrain.
##
## For every object in the navigation object index this counts:
##   * cells whose edge slots are not exactly three (the walk reads three);
##   * phantom WALLS: (cell, edge) pairs where an edge that is not one of the
##     cell's own crosses the cell's interior in plan and would have stopped
##     a mover there under the old rule (outline 0x02/0x10, internal 0x01/0x02);
##   * phantom EXITS: the same for an open outline edge, which put the mover
##     back on the terrain under the old rule;
## and, over every region's .nvm, how many placements use such objects.
##
## Usage:
##   godot4 --headless --path client --script res://tools/nav_phantom_census.gd -- \
##     --pk2=<Data.pk2> [--show=<n>] [--no-placements]
##     [--where=<model substring>]   only list the regions placing such objects

const NAV_INDEX_PATH := "navmesh\\object.ifo"
const EPS := 1.0e-3

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

## The object's navigation mesh the way World3D._load_object_collision reads it.
func _collision(archive: Pk2Reader, path: String) -> BmsReader.CollisionMesh:
	return NavObjectSource.load_collision(archive, path)

static func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a - o).cross(b - o)

## Does the segment p-q pass through the open interior of triangle a-b-c
## (plan view), rather than only touch its boundary?
static func _through_interior(p: Vector2, q: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var area := _cross(a, b, c)
	if absf(area) < 1.0e-6:
		return false
	var s := 1.0 if area > 0.0 else -1.0
	# Clip the segment against the three half-planes, shrunk by EPS, and ask
	# whether anything of it is left.
	var t0 := 0.0
	var t1 := 1.0
	var sides := [[a, b], [b, c], [c, a]]
	for side in sides:
		var u: Vector2 = side[0]
		var v: Vector2 = side[1]
		var fp := s * _cross(u, v, p) / (u - v).length() - EPS
		var fq := s * _cross(u, v, q) / (u - v).length() - EPS
		if fp < 0.0 and fq < 0.0:
			return false
		if fp < 0.0:
			t0 = maxf(t0, fp / (fp - fq))
		elif fq < 0.0:
			t1 = minf(t1, fp / (fp - fq))
		if t0 > t1:
			return false
	return t1 - t0 > 1.0e-6

func _init() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	var show := int(_arg("--show", "30"))
	if archive == null:
		printerr("could not open the archive")
		quit(1)
		return
	var table := ObjidxReader.parse(archive.read_file(ObjectLoader.find_file(archive, NAV_INDEX_PATH)))
	var examined := 0
	var bad_slots_objects := 0
	var bad_slots_cells := 0
	var wall_objects := {}
	var exit_objects := {}
	var wall_pairs := 0
	var exit_pairs := 0
	var shown := 0
	var seen_paths := {}
	var where := _arg("--where", "").to_lower()
	if where != "":
		# Just the placements of objects whose model name holds `where`.
		var ids := {}
		for entry in table.entries:
			if entry != null and entry.path.to_lower().get_file().contains(where):
				ids[entry.type_id] = entry.path.get_file()
		for ry in range(256):
			for rx in range(256):
				var bytes := AssetSource.read_bytes("navmesh\\nv_%04x.nvm" % ((ry << 8) | rx), archive)
				if bytes.is_empty():
					continue
				var off := 12
				var count := bytes.decode_u16(off)
				off += 2
				for _i in range(count):
					var rid := bytes.decode_u32(off)
					var pos := Vector3(bytes.decode_float(off + 4), bytes.decode_float(off + 8), bytes.decode_float(off + 12))
					var own_region := bytes.decode_u16(off + 28)
					off += 30
					var links := bytes.decode_u16(off)
					off += 2 + links * 6
					if ids.has(rid) and own_region == ((ry << 8) | rx):
						print("%d/%d  %s at %.1f, %.1f, %.1f" % [ry, rx, ids[rid], pos.x, pos.y, pos.z])
		quit(0)
		return
	for entry in table.entries:
		if entry == null or entry.path == "" or not entry.path.to_lower().ends_with(".bsr"):
			continue
		var cm := _collision(archive, entry.path)
		if cm == null:
			continue
		if not seen_paths.has(entry.path):
			examined += 1
		var nv := cm.vertices.size()
		var nc := cm.cells.size()
		# Edge slots per cell, the loader's way: every edge naming the cell,
		# outline list first, in file order.
		var slots: Array = []
		slots.resize(nc)
		for c in range(nc):
			slots[c] = []
		var all_edges: Array = []
		for e in cm.outline_edges:
			all_edges.append([e, true])
		for e in cm.internal_edges:
			all_edges.append([e, false])
		for i in range(all_edges.size()):
			var e: BmsReader.CollisionEdge = all_edges[i][0]
			if e.cell_from != BmsReader.NO_CELL and e.cell_from < nc:
				(slots[e.cell_from] as Array).append(i)
			if e.cell_to != BmsReader.NO_CELL and e.cell_to < nc and e.cell_to != e.cell_from:
				(slots[e.cell_to] as Array).append(i)
		var bad := 0
		for c in range(nc):
			if (slots[c] as Array).size() != 3:
				bad += 1
		if bad > 0:
			bad_slots_objects += 1
			bad_slots_cells += bad
		var walls := 0
		var exits := 0
		var example := ""
		for c in range(nc):
			var cell: BmsReader.CollisionCell = cm.cells[c]
			var pa: Vector3 = cm.vertices[cell.a].position
			var pb: Vector3 = cm.vertices[cell.b].position
			var pc: Vector3 = cm.vertices[cell.c].position
			var a := Vector2(pa.x, pa.z)
			var b := Vector2(pb.x, pb.z)
			var cc := Vector2(pc.x, pc.z)
			var lo := Vector2(minf(a.x, minf(b.x, cc.x)), minf(a.y, minf(b.y, cc.y)))
			var hi := Vector2(maxf(a.x, maxf(b.x, cc.x)), maxf(a.y, maxf(b.y, cc.y)))
			var own: Array = slots[c]
			for i in range(all_edges.size()):
				if own.has(i):
					continue
				var e: BmsReader.CollisionEdge = all_edges[i][0]
				var outline: bool = all_edges[i][1]
				if e.v0 >= nv or e.v1 >= nv:
					continue
				var p3: Vector3 = cm.vertices[e.v0].position
				var q3: Vector3 = cm.vertices[e.v1].position
				var p := Vector2(p3.x, p3.z)
				var q := Vector2(q3.x, q3.z)
				if maxf(p.x, q.x) < lo.x or minf(p.x, q.x) > hi.x or maxf(p.y, q.y) < lo.y or minf(p.y, q.y) > hi.y:
					continue
				var kind := ""
				if outline:
					kind = "wall" if (e.flags & 0x12) != 0 else "exit"
				elif (e.flags & 0x03) != 0:
					kind = "wall"
				if kind == "":
					continue
				if not _through_interior(p, q, a, b, cc):
					continue
				if kind == "wall":
					walls += 1
				else:
					exits += 1
				if example == "":
					example = "cell %d (y %.1f) crossed by %s edge %d flags 0x%02x (y %.1f)" % [
						c, (pa.y + pb.y + pc.y) / 3.0, "outline" if outline else "internal", i, e.flags, (p3.y + q3.y) * 0.5]
		if walls > 0:
			wall_objects[entry.type_id] = entry.path
			wall_pairs += walls
		if exits > 0:
			exit_objects[entry.type_id] = entry.path
			exit_pairs += exits
		if (walls > 0 or exits > 0) and shown < show and not seen_paths.has(entry.path):
			shown += 1
			print("%05d %s: %d phantom wall pair(s), %d phantom exit pair(s); e.g. %s" % [
				entry.type_id, entry.path.get_file(), walls, exits, example])
		seen_paths[entry.path] = true

	print("--- %d distinct object navigation meshes examined" % examined)
	print("    %d objects have a cell whose edge slots are not three (%d cells)" % [bad_slots_objects, bad_slots_cells])
	print("    %d index entries carry a phantom WALL (%d cell/edge pairs)" % [wall_objects.size(), wall_pairs])
	print("    %d index entries carry a phantom EXIT (%d cell/edge pairs)" % [exit_objects.size(), exit_pairs])

	if _arg("--no-placements", "") != "":
		quit(0)
		return
	# Placements over every region's .nvm: read only the object header list.
	# A placement is listed by every region it overlaps and counted once, in
	# the file whose own region id it carries. MEASURED: the archive also
	# holds navmesh files under a second set of names whose object records
	# repeat another file's placements, own-region word and all (the Black
	# Robber Den's bridge appears as nv_5b93 and nv_16b7); placements are
	# therefore also de-duplicated by type and position.
	var files := 0
	var placements := 0
	var wall_placements := 0
	var exit_placements := 0
	var seen_placements := {}
	var wall_names := {}
	for ry in range(256):
		for rx in range(256):
			var bytes := AssetSource.read_bytes("navmesh\\nv_%04x.nvm" % ((ry << 8) | rx), archive)
			if bytes.is_empty():
				continue
			files += 1
			var off := 12
			var count := bytes.decode_u16(off)
			off += 2
			for _i in range(count):
				var rid := bytes.decode_u32(off)
				var key := "%d:%.1f:%.1f:%.1f" % [rid, bytes.decode_float(off + 4), bytes.decode_float(off + 8), bytes.decode_float(off + 12)]
				var own_region := bytes.decode_u16(off + 28)
				off += 30
				var links := bytes.decode_u16(off)
				off += 2 + links * 6
				if own_region != ((ry << 8) | rx) or seen_placements.has(key):
					continue
				seen_placements[key] = true
				placements += 1
				if wall_objects.has(rid):
					wall_placements += 1
					wall_names[String(wall_objects[rid]).get_file()] = int(wall_names.get(String(wall_objects[rid]).get_file(), 0)) + 1
				if exit_objects.has(rid):
					exit_placements += 1
	print("--- %d navmesh files, %d distinct placements" % [files, placements])
	print("    %d placements use an object with a phantom WALL" % wall_placements)
	print("    %d placements use an object with a phantom EXIT" % exit_placements)
	print("    by object: %s" % wall_names)
	quit(0)
