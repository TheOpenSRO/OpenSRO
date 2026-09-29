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
##     [--column=x,z[+x,z...]]   every surface over a column (terrain first) and
##                               which object each belongs to
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

## The object's navigation mesh across every mesh of its .bsr, the same way
## World3D._load_object_collision resolves it.
func _object_collision(archive: Pk2Reader, path: String) -> BmsReader.CollisionMesh:
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

	var placed: Array[NavGraph.PlacedObject] = []
	var names := {}
	var cache := {}
	for oi in range(region.objects.size()):
		var obj: NvmReader.MapObject = region.objects[oi]
		var entry = table.lookup(obj.resource_id)
		if entry == null or entry.path == "":
			continue
		if not cache.has(obj.resource_id):
			cache[obj.resource_id] = _object_collision(archive, entry.path)
		var collision: BmsReader.CollisionMesh = cache[obj.resource_id]
		if collision == null:
			continue
		var p := NavGraph.place(collision, oi, obj.local_position, obj.yaw)
		var model: String = entry.path.get_file().get_basename()
		p.set_meta("model", model)
		names[oi] = model
		placed.append(p)
	var graph := NavGraph.build(region, placed)
	print("region %s: %d/%d objects placed, %d terrain blocking edges" % [
		region_text, placed.size(), region.objects.size(), graph.terrain_blocking.size() / 2])

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
		for i in range(steps):
			var r := graph.step_tracked(pos, motion, footing)
			if r.entered != -1:
				print("  step %4d: onto %s at %.1f, %.1f (y %.1f)" % [i, _name(names, r.entered), r.position.x, r.position.z, r.position.y])
			if r.exited != -1:
				print("  step %4d: off %s at %.1f, %.1f (y %.1f)" % [i, _name(names, r.exited), r.position.x, r.position.z, r.position.y])
			if r.blocked and not last_blocked:
				print("  step %4d: wall at %.1f, %.1f (on %s)" % [i, r.position.x, r.position.z, _name(names, r.standing_on)])
				walls += 1
			last_blocked = r.blocked
			if i % 25 == 0:
				print("  step %4d: %.1f, %.1f  y %.1f  on %s" % [i, r.position.x, r.position.z, r.position.y, _name(names, r.standing_on)])
			pos = r.position
			footing = r.standing_on
		print("ended at local %.1f, %.1f (y %.1f) on %s after %d wall contact(s)" % [
			pos.x, pos.z, pos.y, _name(names, footing), walls])
	quit(0)

func _name(names: Dictionary, footing: int) -> String:
	if footing == NavGraph.ON_TERRAIN:
		return "terrain"
	return "%s[%d]" % [names.get(footing, "?"), footing]
