extends SceneTree

## Dev tool: walks a character across a real region's navigation graph,
## headless, and prints what happens -- the position, the footing (terrain
## or which object), every doorway stepped through and every wall met. The
## same NavGraph the running client moves the player on, built from the same
## real files, without a renderer: a movement question answered in seconds
## instead of a two-minute render, and by a trace rather than a picture.
##
## Also lists an object's outline edges near a point, so a walk can be aimed
## at a real doorway or a real wall on purpose.
##
## Usage:
##   godot4 --headless --path client --script res://tools/walk_probe.gd -- \
##     --pk2=<Data.pk2> --map-pk2=<Map.pk2> --region=97/168 \
##     [--from=x,z --heading=deg [--steps=n] [--step=len]]   walk from a local point
##     [--edges=<model substring> [--near=x,z] [--radius=r]]  list an object's outline edges
##     [--objects=<model substring>|*]   list placed objects: placement, flags,
##                               height range, outline flag counts, links
##     [--column=x,z[+x,z...]]   every surface over a column (terrain first) and
##                               which object each belongs to
##     [--traverse=<object index>[:from_edge:to_edge]]  walk an object from one
##                               outline edge to another along its own cells
##                               (default: its first open edge to its last
##                               open or linked one), leg by leg through the
##                               internal edges between, and report every wall
##     [--sweep=n [--seed=s]]    n seeded walks, one line each (diff two builds)
##     [--cross=1]               let a --from walk carry on into neighbouring regions
##     [--ghost=fx,fz:tx,tz:D]   resolve a ground-cast landing (GhostWalk) from
##                               one point toward another with reach D
##
## Coordinates are the region's own local ones (0..1920), the same as QA_AT.

const NAVMESH_PATH_FORMAT := "navmesh\\nv_%04x.nvm"
const OBJECT_INDEX_PATH := "navmesh\\object.ifo"

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _vec2(text: String) -> Vector2:
	var parts := text.split(",")
	if parts.size() < 2:
		return Vector2.INF
	return Vector2(float(parts[0]), float(parts[1]))

## The object's navigation mesh, the same way World3D._load_object_collision
## resolves it: NavObjectSource's one mesh (round 644) where that class
## exists, else -- run against an older build for a before/after trace --
## that build's merge of every mesh the .bsr lists.
const NAV_OBJECT_SOURCE := "res://scripts/nav/nav_object_source.gd"
func _object_collision(archive: Pk2Reader, path: String) -> BmsReader.CollisionMesh:
	if ResourceLoader.exists(NAV_OBJECT_SOURCE):
		return load(NAV_OBJECT_SOURCE).load_collision(archive, path)
	var bsr_entry := ObjectLoader.find_file(archive, path)
	if bsr_entry == null:
		return null
	var bsr := BsrReader.parse(archive.read_file(bsr_entry))
	if bsr == null or bsr.mesh_path == "":
		return null
	var meshes: Array[String] = [bsr.mesh_path]
	for p in bsr.sub_mesh_paths:
		meshes.append(p)
	var parts: Array = []
	for mesh_path in meshes:
		if mesh_path == "":
			continue
		var mesh_entry := ObjectLoader.find_file(archive, mesh_path)
		if mesh_entry == null:
			continue
		var part := BmsReader.parse_collision(archive.read_file(mesh_entry))
		if part != null and not part.cells.is_empty():
			parts.append(part)
	if parts.is_empty():
		return null
	return parts[0] if parts.size() == 1 else BmsCollision.merge(parts)

var _archive: Pk2Reader
var _table: ObjidxReader.Table
var _cache := {}
## Region key -> {graph, names, placed}, for walks that cross regions.
var _graphs := {}

## One region's graph, built the way World3D._prepare_nav_graph builds it.
func _build(key: int, region: NvmReader.ParsedRegion = null) -> Dictionary:
	if _graphs.has(key):
		return _graphs[key]
	if region == null:
		var bytes := AssetSource.read_bytes(NAVMESH_PATH_FORMAT % key, _archive)
		if bytes.is_empty():
			return {}
		region = NvmReader.parse(bytes)
		if region == null:
			return {}
	var placed: Array[NavGraph.PlacedObject] = []
	var names := {}
	for oi in range(region.objects.size()):
		var obj: NvmReader.MapObject = region.objects[oi]
		var entry = _table.lookup(obj.resource_id)
		if entry == null or entry.path == "":
			continue
		if not _cache.has(obj.resource_id):
			_cache[obj.resource_id] = _object_collision(_archive, entry.path)
		var collision: BmsReader.CollisionMesh = _cache[obj.resource_id]
		if collision == null:
			continue
		var p := NavGraph.place(collision, oi, obj.local_position, obj.yaw)
		var model: String = entry.path.get_file().get_basename()
		p.set_meta("model", model)
		names[oi] = model
		placed.append(p)
	var out := {"graph": NavGraph.build(region, placed), "names": names, "placed": placed}
	_graphs[key] = out
	return out

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var map_path := _arg("--map-pk2")
	var region_text := _arg("--region")
	if pk2_path == "" or region_text == "":
		printerr("usage: --pk2=<Data.pk2> [--map-pk2=<Map.pk2>] --region=x/y [--from=x,z --heading=deg] [--edges=name]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var rp := region_text.split("/")
	if rp.size() != 2:
		printerr("--region wants x/y")
		quit(2)
		return
	var key: int = (int(rp[0]) << 8) | int(rp[1])
	var nvm_bytes := AssetSource.read_bytes(NAVMESH_PATH_FORMAT % key, archive)
	if nvm_bytes.is_empty():
		printerr("no navmesh at ", NAVMESH_PATH_FORMAT % key)
		quit(1)
		return
	var region := NvmReader.parse(nvm_bytes)
	if region == null:
		printerr("could not parse the navmesh")
		quit(1)
		return

	var table: ObjidxReader.Table = null
	if map_path != "":
		var map_archive := Pk2Reader.open(map_path)
		if map_archive != null:
			var e := ObjectLoader.find_file(map_archive, OBJECT_INDEX_PATH)
			if e != null:
				table = ObjidxReader.parse(map_archive.read_file(e))
	if table == null:
		var entry := ObjectLoader.find_file(archive, OBJECT_INDEX_PATH)
		if entry != null:
			table = ObjidxReader.parse(archive.read_file(entry))
	if table == null:
		printerr("no object index")
		quit(1)
		return

	_archive = archive
	_table = table
	var built := _build(key, region)
	var placed: Array[NavGraph.PlacedObject] = built["placed"]
	var names: Dictionary = built["names"]
	var cache := _cache
	var graph: NavGraph = built["graph"]
	print("region %s: %d/%d objects placed, %d terrain blocking edges" % [
		region_text, placed.size(), region.objects.size(), graph.terrain_blocking.size() / 2])

	var list_of := _arg("--objects", "").to_lower()
	if list_of != "":
		# Every placed object whose model name holds the substring ("*" for all):
		# where the region's .nvm places it, its real flags, its surface's
		# height range and how its outline edges are flagged.
		for p in placed:
			var model: String = p.get_meta("model")
			if list_of != "*" and not model.to_lower().contains(list_of):
				continue
			var obj: NvmReader.MapObject = region.objects[p.object_index]
			var ylo := INF
			var yhi := -INF
			for v in p.vertices:
				ylo = minf(ylo, v.y)
				yhi = maxf(yhi, v.y)
			var hist := {}
			var e := 0
			while e < p.edge_flags.size():
				if p.edge_outline[e] != 0:
					var k := "0x%02x" % p.edge_flags[e]
					hist[k] = int(hist.get(k, 0)) + 1
				e += 1
			var listed := 0
			for c in region.cells:
				if c.object_indices.has(p.object_index):
					listed += 1
			var links := []
			for l in obj.linked_edges:
				links.append("%d->%d.%d" % [l.edge_index, l.other_object_index, l.other_edge_index])
			print("object %d %s  at %.1f,%.1f,%.1f yaw %.4f big=%s struct=%s rid=%d/%d  bounds %.1f,%.1f .. %.1f,%.1f  y %.1f..%.1f  cells %d  listed by %d terrain cells  outline %s  links %s" % [
				p.object_index, model, obj.local_position.x, obj.local_position.y, obj.local_position.z, obj.yaw,
				obj.is_big, obj.is_struct, obj.region_id >> 8, obj.region_id & 0xff,
				p.bounds_min.x, p.bounds_min.y, p.bounds_max.x, p.bounds_max.y, ylo, yhi,
				p.cells.size() / 3, listed, hist, links])

	# The region's own terrain cells: which one covers a point and which
	# objects it lists, or every cell listing one object.
	var cell_points := _arg("--cell")
	if cell_points != "":
		for spec in cell_points.split("+", false):
			var c := _vec2(spec)
			var ci := graph.cell_index_at(c.x, c.y)
			if ci < 0 or ci >= region.cells.size():
				print("cell at %.1f, %.1f: none (index %d)" % [c.x, c.y, ci])
				continue
			var cell: NvmReader.Cell = region.cells[ci]
			var listed_names := []
			for oi in cell.object_indices:
				listed_names.append(_name(names, oi))
			print("cell at %.1f, %.1f: #%d  %.1f,%.1f .. %.1f,%.1f  lists %s" % [
				c.x, c.y, ci, cell.rect_min.x, cell.rect_min.y, cell.rect_max.x, cell.rect_max.y, listed_names])
	var cells_of := _arg("--cells-of")
	if cells_of != "":
		var want := int(cells_of)
		for ci in range(region.cells.size()):
			var cell: NvmReader.Cell = region.cells[ci]
			if cell.object_indices.has(want):
				print("cell #%d  %.1f,%.1f .. %.1f,%.1f lists %s" % [
					ci, cell.rect_min.x, cell.rect_min.y, cell.rect_max.x, cell.rect_max.y, _name(names, want)])

	# An object's own edge lookup grid, as its collision section stores it:
	# origin, size, and which outline edges it lists at all.
	var grid_of := _arg("--grid").to_lower()
	if grid_of != "":
		var done := {}
		for oi in range(region.objects.size()):
			var obj: NvmReader.MapObject = region.objects[oi]
			if not names.has(oi) or not String(names[oi]).to_lower().contains(grid_of) or done.has(obj.resource_id):
				continue
			done[obj.resource_id] = true
			var cm: BmsReader.CollisionMesh = cache[obj.resource_id]
			var listed := {}
			var nonempty := 0
			for lst in cm.grid_cells:
				if not lst.is_empty():
					nonempty += 1
				for i in lst:
					listed[i] = int(listed.get(i, 0)) + 1
			print("grid of %s: origin %.1f,%.1f  %dx%d  %d non-empty; outline %d edges, internal %d; indices listed: %s" % [
				names[oi], cm.grid_origin.x, cm.grid_origin.y, cm.grid_width, cm.grid_height, nonempty,
				cm.outline_edges.size(), cm.internal_edges.size(), listed])
			for c in range(cm.cells.size()):
				var cc: BmsReader.CollisionCell = cm.cells[c]
				print("   cell %3d: vertices %d %d %d" % [c, cc.a, cc.b, cc.c])
			for e in range(cm.internal_edges.size()):
				var ie: BmsReader.CollisionEdge = cm.internal_edges[e]
				print("   internal %3d flags 0x%02x  v %d-%d  cells %d -> %d" % [e, ie.flags, ie.v0, ie.v1, ie.cell_from, ie.cell_to])
			for e in range(cm.outline_edges.size()):
				var ce: BmsReader.CollisionEdge = cm.outline_edges[e]
				var a: Vector3 = cm.vertices[ce.v0].position
				var b: Vector3 = cm.vertices[ce.v1].position
				print("   outline %3d flags 0x%02x  v %d-%d cells %d -> %d  model %.1f,%.1f -> %.1f,%.1f  in %d grid list(s)" % [
					e, ce.flags, ce.v0, ce.v1, ce.cell_from, ce.cell_to, a.x, a.z, b.x, b.z, int(listed.get(e, 0))])

	var edges_of := _arg("--edges").to_lower()
	if edges_of != "":
		var near := _vec2(_arg("--near", "0,0"))
		var radius := float(_arg("--radius", "1e9"))
		for p in placed:
			var model: String = p.get_meta("model")
			if not model.to_lower().contains(edges_of):
				continue
			print("object %d %s  bounds %.1f,%.1f .. %.1f,%.1f  terrain_collides=%s" % [
				p.object_index, model, p.bounds_min.x, p.bounds_min.y, p.bounds_max.x, p.bounds_max.y, p.terrain_collides])
			var e := 0
			while e < p.edge_flags.size():
				var a: Vector2 = p.edges[e * 2]
				var b: Vector2 = p.edges[e * 2 + 1]
				var mid := (a + b) * 0.5
				if p.edge_outline[e] != 0 and mid.distance_to(near) <= radius:
					var ya: float = p.vertices[p.edge_v0[e]].y
					var yb: float = p.vertices[p.edge_v1[e]].y
					print("   edge %3d flags 0x%02x  %.1f,%.1f (y %.1f) -> %.1f,%.1f (y %.1f)" % [
						e, p.edge_flags[e], a.x, a.y, ya, b.x, b.y, yb])
				e += 1

	var columns := _arg("--column")
	var mapm: MapmReader.ParsedRegion = null
	if columns != "" and map_path != "":
		var m_archive := Pk2Reader.open(map_path)
		if m_archive != null:
			var m_entry := ObjectLoader.find_file(m_archive, "%s\\%s.m" % [rp[0], rp[1]])
			if m_entry != null:
				mapm = MapmReader.parse(m_archive.read_file(m_entry))
	if columns != "":
		for spec in columns.split("+", false):
			var c := _vec2(spec)
			print("column %.1f, %.1f: terrain %.3f" % [c.x, c.y, NvmCollision.sample_height(region, c.x, c.y)])
			for oi in graph.objects_at(c.x, c.y):
				var p: NavGraph.PlacedObject = graph.objects[oi]
				var h := NavGraph.surface_height_of(p, c.x, c.y)
				if not is_nan(h):
					print("   %s[%d] surface %.3f" % [names.get(oi, "?"), oi, h])
			print("   landing height %.3f" % graph.landing_height_at(c.x, c.y))
			# The drawn water over the column (round 642): the .m block's
			# PlaneType/PlaneHeight, as MapmWater.build draws it -- so a
			# landing spot can be told from a river bed by a number.
			if mapm != null and mapm.blocks.size() == MapmReader.BLOCK_COUNT:
				var bx := clampi(int(floorf(c.x / MapmWater.BLOCK_SPAN)), 0, MapmReader.BLOCKS_PER_SIDE - 1)
				var bz := clampi(int(floorf(c.y / MapmWater.BLOCK_SPAN)), 0, MapmReader.BLOCKS_PER_SIDE - 1)
				var block: MapmReader.Block = mapm.blocks[bz * MapmReader.BLOCKS_PER_SIDE + bx]
				var kind := MapmWater.block_kind(block)
				var drawn := "none drawn" if kind == MapmWater.PLANE_NONE else ("water" if kind == MapmWater.PLANE_WATER else "still")
				print("   water: block %d,%d plane type %d height %.3f (%s)" % [bx, bz, block.plane_type, block.plane_height, drawn])

	var ghost := _arg("--ghost")
	if ghost != "":
		var parts := ghost.split(":")
		var gf := _vec2(parts[0])
		var gt := _vec2(parts[1])
		var reach := float(parts[2]) if parts.size() > 2 else 0.0
		# Region-local space is the world here: an identity group.
		var group := Node3D.new()
		get_root().add_child(group)
		var start := Vector3(gf.x, graph.landing_height_at(gf.x, gf.y), gf.y)
		var pick := Vector3(gt.x, graph.landing_height_at(gt.x, gt.y), gt.y)
		var lookup := func(w: Vector3) -> Array:
			if w.x < 0.0 or w.z < 0.0 or w.x > 1920.0 or w.z > 1920.0:
				return []
			return [graph, group]
		var t0 := Time.get_ticks_usec()
		var landing := GhostWalk.resolve(start, pick, reach, -2, null, lookup)
		var took := Time.get_ticks_usec() - t0
		print("ghost from %.1f, %.1f (y %.2f, on %s) toward %.1f, %.1f (y %.2f) reach %.0f" % [
			start.x, start.z, start.y, _name(names, graph.surface_at(start.x, start.z, start.y).object_index),
			pick.x, pick.z, pick.y, reach])
		print("   clamped %.2f, %.2f, %.2f" % [landing.clamped.x, landing.clamped.y, landing.clamped.z])
		print("   landing %.2f, %.2f, %.2f on %s%s, %.2f from the start; sent %.2f, %.2f, %.2f; %d us" % [
			landing.position.x, landing.position.y, landing.position.z, _name(names, landing.footing),
			(" (stopped at a wall%s)" % (", sent back by the cell's objects" if landing.cancelled else "")) if landing.blocked else "",
			start.distance_to(landing.position), landing.sent.x, landing.sent.y, landing.sent.z, took])

	# --sweep=n: n seeded walks, half starting on a placed object's cell and
	# half on the terrain, each 300 steps of 1.0 on a seeded heading, one line
	# per walk. Run against two builds and diffed, it says which walks a
	# NavGraph change altered and on what (round 644).
	var sweep := int(_arg("--sweep", "0"))
	if sweep > 0:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(_arg("--seed", "644"))
		for w in range(sweep):
			var start := Vector3.ZERO
			var foot := NavGraph.ON_TERRAIN
			if w % 2 == 0 and not placed.is_empty():
				var pobj: NavGraph.PlacedObject = placed[rng.randi_range(0, placed.size() - 1)]
				var ncell := pobj.cells.size() / 3
				var ci := rng.randi_range(0, maxi(ncell - 1, 0))
				var va: Vector3 = pobj.vertices[pobj.cells[ci * 3]]
				var vb: Vector3 = pobj.vertices[pobj.cells[ci * 3 + 1]]
				var vc: Vector3 = pobj.vertices[pobj.cells[ci * 3 + 2]]
				start = (va + vb + vc) / 3.0
				foot = pobj.object_index
			else:
				start = Vector3(rng.randf_range(20.0, 1900.0), 0.0, rng.randf_range(20.0, 1900.0))
				start.y = NvmCollision.sample_height(region, start.x, start.z)
			var hd := rng.randf_range(0.0, TAU)
			var mv := Vector2(sin(hd), cos(hd))
			var p := start
			var f := foot
			var nwalls := 0
			var path := []
			for i in range(300):
				var r := graph.step_tracked(p, mv, f)
				if r.blocked:
					nwalls += 1
				if r.entered != -1 or r.exited != -1:
					path.append("%d:%s>%s" % [i, _name(names, f), _name(names, r.standing_on)])
				p = r.position
				f = r.standing_on
			print("sweep %4d from %.2f,%.2f,%.2f on %s heading %.4f -> %.3f,%.3f,%.3f on %s walls %d %s" % [
				w, start.x, start.y, start.z, _name(names, foot), hd, p.x, p.y, p.z, _name(names, f), nwalls, " ".join(PackedStringArray(path))])

	# --reach=oi:x,z,y: from the object's cell under (x, z) nearest y, every
	# cell its own internal edges let a mover reach, and the outline edges
	# those cells could leave by (not 0x02/0x10) -- whether a spot on an
	# object has any way off it at all.
	var reach := _arg("--reach", "")
	if reach != "":
		var rp2 := reach.split(":")
		var roi := int(rp2[0])
		var xyz := rp2[1].split(",")
		var ro: NavGraph.PlacedObject = graph.objects[roi]
		var start_cells := NavGraph._cells_under(ro, float(xyz[0]), float(xyz[1]), float(xyz[2]))
		var seen_c := {start_cells[0]: true}
		var q: Array[int] = [start_cells[0]]
		var exits := []
		while not q.is_empty():
			var c: int = q.pop_front()
			for k in range(mini(NavGraph.CELL_EDGE_SLOTS, ro.cell_edges[c].size())):
				var e: int = ro.cell_edges[c][k]
				var f: int = ro.edge_flags[e]
				if ro.edge_outline[e] != 0:
					if (f & 0x12) == 0:
						exits.append("%d(0x%02x)" % [e, f])
					continue
				var cf: int = ro.edge_cell_from[e]
				var ct: int = ro.edge_cell_to[e]
				if ((f & 2) != 0 and cf == c) or ((f & 1) != 0 and ct == c):
					continue
				var n: int = ct if cf == c else cf
				if n >= 0 and not seen_c.has(n):
					seen_c[n] = true
					q.append(n)
		print("reach %s from cell %d: %d of %d cells reachable, exits %s" % [_name(names, roi), start_cells[0], seen_c.size(), ro.cells.size() / 3, exits])

	var traverse := _arg("--traverse", "")
	if traverse != "":
		_traverse(graph, names, traverse)

	var from := _vec2(_arg("--from", ""))
	if from != Vector2.INF:
		var heading := deg_to_rad(float(_arg("--heading", "0")))
		var steps := int(_arg("--steps", "200"))
		var step_len := float(_arg("--step", "1.0"))
		var motion := Vector2(sin(heading), cos(heading)) * step_len
		var pos := Vector3(from.x, 0.0, from.y)
		pos.y = graph.landing_height_at(pos.x, pos.z)
		var footing := graph.surface_at(pos.x, pos.z, pos.y).object_index
		print("walk from local %.1f, %.1f (y %.1f, on %s) heading %.0f deg, %d steps of %.1f" % [
			pos.x, pos.z, pos.y, _name(names, footing), rad_to_deg(heading), steps, step_len])
		var walls := 0
		var last_blocked := false
		# --cross: carry on into the neighbouring region's graph when the walk
		# leaves this one, re-settling the footing there from the height the
		# way World3D._move_on_nav_graph does on a graph change.
		var cross := _arg("--cross", "") != ""
		var ry: int = key >> 8
		var rx: int = key & 0xff
		var here := region_text
		var stop_wall := int(_arg("--stop-after-walls", "0"))
		var every := maxi(1, int(_arg("--every", "25")))
		for i in range(steps):
			var r := graph.step_tracked(pos, motion, footing)
			if r.entered != -1:
				print("  step %4d: %s onto %s at %.1f, %.1f (y %.1f)" % [i, here, _name(names, r.entered), r.position.x, r.position.z, r.position.y])
			if r.exited != -1:
				print("  step %4d: %s off %s at %.1f, %.1f (y %.1f)" % [i, here, _name(names, r.exited), r.position.x, r.position.z, r.position.y])
			if r.blocked and not last_blocked:
				print("  step %4d: %s WALL at %.1f, %.1f (on %s)" % [i, here, r.position.x, r.position.z, _name(names, r.standing_on)])
				walls += 1
			last_blocked = r.blocked
			if i % every == 0:
				print("  step %4d: %s %.3f, %.3f  y %.2f  on %s" % [i, here, r.position.x, r.position.z, r.position.y, _name(names, r.standing_on)])
			pos = r.position
			footing = r.standing_on
			if stop_wall > 0 and walls >= stop_wall:
				break
			if cross:
				var dx := 0
				var dz := 0
				if pos.x < 0.0:
					dx = -1
				elif pos.x >= 1920.0:
					dx = 1
				if pos.z < 0.0:
					dz = -1
				elif pos.z >= 1920.0:
					dz = 1
				if dx != 0 or dz != 0:
					rx += dx
					ry += dz
					var next := _build((ry << 8) | rx)
					if next.is_empty():
						print("  step %4d: no navmesh for region %d/%d; stopped" % [i, ry, rx])
						break
					pos.x -= dx * 1920.0
					pos.z -= dz * 1920.0
					graph = next["graph"]
					names = next["names"]
					here = "%d/%d" % [ry, rx]
					var settled := graph.surface_at(pos.x, pos.z, pos.y)
					footing = settled.object_index
					pos.y = settled.height
					print("  step %4d: into region %s at %.1f, %.1f (y %.1f), footing settled on %s" % [
						i, here, pos.x, pos.z, pos.y, _name(names, footing)])
		print("ended in %s at local %.1f, %.1f (y %.1f) on %s after %d wall contact(s)" % [
			here, pos.x, pos.z, pos.y, _name(names, footing), walls])
	quit(0)

## --traverse: see the usage above. The path is the fewest cells from the
## first edge's cell to the last one's through internal edges the object's
## own flags let a mover cross in that direction; the walk then heads for the
## middle of each internal edge on it in turn, starting 3 units outside the
## first edge and ending 3 units past the last.
func _traverse(graph: NavGraph, names: Dictionary, spec: String) -> void:
	var parts := spec.split(":")
	var oi := int(parts[0])
	if not graph.objects.has(oi):
		print("traverse: no object %d" % oi)
		return
	var p: NavGraph.PlacedObject = graph.objects[oi]
	# The path is read off the object's own mesh, not the graph's derived
	# arrays, so this runs unchanged against an older NavGraph (the
	# before/after traces of round 644).
	var cm: BmsReader.CollisionMesh = _cache[graph.region.objects[oi].resource_id]
	var edges: Array[BmsReader.CollisionEdge] = []
	var outline: Array[bool] = []
	for e in cm.outline_edges:
		edges.append(e)
		outline.append(true)
	for e in cm.internal_edges:
		edges.append(e)
		outline.append(false)
	var first := -1
	var last := -1
	if parts.size() >= 3:
		first = int(parts[1])
		last = int(parts[2])
	else:
		for e in range(edges.size()):
			if outline[e] and (edges[e].flags & 0x13) == 0:
				if first < 0:
					first = e
				else:
					last = e
	if first < 0 or last < 0:
		print("traverse: %s has no two open outline edges to walk between" % _name(names, oi))
		return
	var start_cell: int = edges[first].cell_from
	var goal_cell: int = edges[last].cell_from
	var cell_edges := {}
	for e in range(edges.size()):
		for c in [edges[e].cell_from, edges[e].cell_to]:
			if c != BmsReader.NO_CELL:
				if not cell_edges.has(c):
					cell_edges[c] = []
				(cell_edges[c] as Array).append(e)
	# Breadth-first over the cells.
	var came := {start_cell: -1}
	var via := {}
	var queue: Array[int] = [start_cell]
	while not queue.is_empty():
		var c: int = queue.pop_front()
		if c == goal_cell:
			break
		for e in cell_edges.get(c, []):
			if outline[e]:
				continue
			var cf: int = edges[e].cell_from
			var ct: int = edges[e].cell_to
			var f: int = edges[e].flags
			if ((f & 2) != 0 and cf == c) or ((f & 1) != 0 and ct == c):
				continue
			var n: int = ct if cf == c else cf
			if n == BmsReader.NO_CELL or came.has(n):
				continue
			came[n] = c
			via[n] = e
			queue.append(n)
	if not came.has(goal_cell):
		print("traverse: no path through %s's own cells from edge %d to edge %d" % [_name(names, oi), first, last])
		return
	var chain: Array[int] = []
	var c2 := goal_cell
	while c2 != start_cell:
		chain.push_front(via[c2])
		c2 = came[c2]
	var mid_of := func(e: int) -> Vector2:
		var va: Vector3 = p.vertices[edges[e].v0]
		var vb: Vector3 = p.vertices[edges[e].v1]
		return Vector2((va.x + vb.x) * 0.5, (va.z + vb.z) * 0.5)
	var centre_of := func(c: int) -> Vector2:
		var cell: BmsReader.CollisionCell = cm.cells[c]
		var va: Vector3 = p.vertices[cell.a]
		var vb: Vector3 = p.vertices[cell.b]
		var vc: Vector3 = p.vertices[cell.c]
		return Vector2((va.x + vb.x + vc.x) / 3.0, (va.z + vb.z + vc.z) / 3.0)
	var mid0: Vector2 = mid_of.call(first)
	var out0: Vector2 = (mid0 - (centre_of.call(start_cell) as Vector2)).normalized()
	var mid1: Vector2 = mid_of.call(last)
	var out1: Vector2 = (mid1 - (centre_of.call(goal_cell) as Vector2)).normalized()
	var points: Array[Vector2] = [mid0 + out0 * 3.0]
	for e in chain:
		points.append(mid_of.call(e))
	points.append(mid1 - out1 * 0.5)
	points.append(mid1 + out1 * 3.0)
	var pos := Vector3(points[0].x, 0.0, points[0].y)
	pos.y = graph.landing_height_at(pos.x, pos.z)
	var footing := graph.surface_at(pos.x, pos.z, pos.y).object_index
	print("traverse %s from edge %d (flags 0x%02x) to edge %d (flags 0x%02x) through %d cells, %d legs; start %.1f, %.1f (y %.1f) on %s" % [
		_name(names, oi), first, edges[first].flags, last, edges[last].flags, chain.size() + 1, points.size() - 1,
		pos.x, pos.z, pos.y, _name(names, footing)])
	var walls := 0
	var steps := 0
	var last_blocked := false
	for leg in range(1, points.size()):
		var target: Vector2 = points[leg]
		var budget := int((Vector2(pos.x, pos.z).distance_to(target)) * 3.0) + 10
		for _i in range(budget):
			var here := Vector2(pos.x, pos.z)
			var to_go := target - here
			if to_go.length() <= 0.05:
				break
			var mv := to_go.normalized() * minf(1.0, to_go.length())
			var r := graph.step_tracked(pos, mv, footing)
			steps += 1
			if r.entered != -1:
				print("  leg %d step %d: onto %s at %.1f, %.1f (y %.1f)" % [leg, steps, _name(names, r.entered), r.position.x, r.position.z, r.position.y])
			if r.exited != -1:
				print("  leg %d step %d: off %s at %.1f, %.1f (y %.1f)" % [leg, steps, _name(names, r.exited), r.position.x, r.position.z, r.position.y])
			if r.blocked and not last_blocked:
				walls += 1
				print("  leg %d step %d: WALL at %.1f, %.1f (y %.1f, on %s) heading for %.1f, %.1f" % [
					leg, steps, r.position.x, r.position.z, r.position.y, _name(names, r.standing_on), target.x, target.y])
			last_blocked = r.blocked
			pos = r.position
			footing = r.standing_on
	print("traverse ended at %.1f, %.1f (y %.1f) on %s after %d steps, %d wall contact(s); goal %.1f, %.1f" % [
		pos.x, pos.z, pos.y, _name(names, footing), steps, walls, points[points.size() - 1].x, points[points.size() - 1].y])

func _name(names: Dictionary, footing: int) -> String:
	if footing == NavGraph.ON_TERRAIN:
		return "terrain"
	return "%s[%d]" % [names.get(footing, "?"), footing]
