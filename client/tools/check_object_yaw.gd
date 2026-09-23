extends SceneTree

## Dev tool: measures which yaw convention places real map objects where the
## region's own navigation data says they are.
##
## An object's placement carries one angle (the `.o`/`.o2`/`.nvm` yaw), and how
## that angle becomes a rotation is a convention that has to be right. A wrong
## convention still produces a plausible-looking town -- objects at 0 and 180
## degrees agree under a sign flip -- so a picture cannot settle it. The
## region's `.nvm` can, twice over, without any rendering:
##
##   1. Every terrain cell lists the objects whose navigation meshes overlap it
##      (`NvmReader.Cell.object_indices`). Place each object's own navigation
##      mesh under a candidate convention: under the right one, every listed
##      object's mesh reaches into the cell that lists it ("listed hit"), and
##      the mesh's triangles fall in cells that list it ("footprint precision").
##   2. `MapObject.linked_edges` stitches an edge of one object to an edge of
##      another (bridge spans). Under the right convention the two edges land
##      on the same segment; the reported number is the mean distance between
##      their midpoints.
##
## Everything is measured in the region's own (engine, un-mirrored) coordinate
## space -- the space World3D's terrain group and NavGraph both work in before
## the group's global `z -> -z` mirror, which applies to cells and objects alike
## and so cannot change which convention agrees.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_object_yaw.gd -- \
##     --pk2=/path/Data.pk2 --map=/path/Map.pk2 --regions=97/168,98/168

const NAVMESH_PATH_FORMAT := "navmesh\\nv_%04x.nvm"
const MAP_OBJECT_INDEX_PATH := "object.ifo"
const OBJECT_INDEX_PATH := "navmesh\\object.ifo"

## Candidate conventions: a name and the angle each turns a stored yaw into.
const CANDIDATES := [
	["+yaw", 1.0, 0.0],
	["-yaw", -1.0, 0.0],
	["+yaw+90", 1.0, PI / 2.0],
	["+yaw-90", 1.0, -PI / 2.0],
	["-yaw+90", -1.0, PI / 2.0],
	["-yaw-90", -1.0, -PI / 2.0],
	["+yaw+180", 1.0, PI],
	["-yaw+180", -1.0, PI],
]

var _collision_cache := {}
var _bsr_bounds := {}

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _collision(archive: Pk2Reader, table: ObjidxReader.Table, resource_id: int) -> BmsReader.CollisionMesh:
	if _collision_cache.has(resource_id):
		return _collision_cache[resource_id]
	_collision_cache[resource_id] = null
	var entry = table.lookup(resource_id)
	if entry == null:
		return null
	var bsr_entry := ObjectLoader.find_file(archive, entry.path)
	if bsr_entry == null:
		return null
	var bsr := BsrReader.parse(archive.read_file(bsr_entry))
	if bsr == null or bsr.mesh_path == "":
		return null
	if bsr.has_bounds:
		_bsr_bounds[resource_id] = [bsr.bounds_min, bsr.bounds_max]
	var meshes: Array[String] = [bsr.mesh_path]
	for path in bsr.sub_mesh_paths:
		meshes.append(path)
	var parts: Array = []
	for path in meshes:
		if path == "":
			continue
		var mesh_entry := ObjectLoader.find_file(archive, path)
		if mesh_entry == null:
			continue
		var part := BmsReader.parse_collision(archive.read_file(mesh_entry))
		if part != null and not part.cells.is_empty():
			parts.append(part)
	if parts.is_empty():
		return null
	var merged: BmsReader.CollisionMesh = parts[0] if parts.size() == 1 else BmsCollision.merge(parts)
	_collision_cache[resource_id] = merged
	return merged

## The object's navigation-mesh triangles placed in region space, as flat
## triples of 2-D (x, z) points.
func _placed_triangles(col: BmsReader.CollisionMesh, pos: Vector3, angle: float) -> PackedVector2Array:
	var basis := Basis(Vector3.UP, angle)
	var out := PackedVector2Array()
	for cell in col.cells:
		for vi in [cell.a, cell.b, cell.c]:
			var p: Vector3 = pos + basis * col.vertices[vi].position
			out.append(Vector2(p.x, p.z))
	return out

func _in_rect(p: Vector2, lo: Vector2, hi: Vector2) -> bool:
	return p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y

func _sign(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)

func _in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := _sign(p, a, b)
	var d2 := _sign(p, b, c)
	var d3 := _sign(p, c, a)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)

func _segments_cross(p1: Vector2, p2: Vector2, q1: Vector2, q2: Vector2) -> bool:
	var d1 := _sign(q1, q2, p1)
	var d2 := _sign(q1, q2, p2)
	var d3 := _sign(p1, p2, q1)
	var d4 := _sign(p1, p2, q2)
	return ((d1 > 0.0) != (d2 > 0.0)) and ((d3 > 0.0) != (d4 > 0.0))

## Whether any placed triangle overlaps the axis-aligned rectangle [lo, hi].
func _overlaps_rect(tris: PackedVector2Array, lo: Vector2, hi: Vector2) -> bool:
	var corners := [lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)]
	for t in range(0, tris.size(), 3):
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		if _in_rect(a, lo, hi) or _in_rect(b, lo, hi) or _in_rect(c, lo, hi):
			return true
		for k in range(4):
			if _in_triangle(corners[k], a, b, c):
				return true
		for e in [[a, b], [b, c], [c, a]]:
			for k in range(4):
				if _segments_cross(e[0], e[1], corners[k], corners[(k + 1) % 4]):
					return true
	return false

func _initialize() -> void:
	var data_path := _arg("--pk2")
	var map_path := _arg("--map")
	var regions := _arg("--regions")
	if data_path == "" or map_path == "" or (regions == "" and _arg("--scan") == ""):
		printerr("usage: --pk2=<Data.pk2> --map=<Map.pk2> --regions=97/168,...")
		quit(2)
		return
	var data := Pk2Reader.open(data_path)
	var map := Pk2Reader.open(map_path)
	if data == null or map == null:
		printerr("could not open the archives")
		quit(1)
		return
	var idx_bytes := AssetSource.read_bytes(MAP_OBJECT_INDEX_PATH, map)
	if idx_bytes.is_empty():
		idx_bytes = AssetSource.read_bytes(OBJECT_INDEX_PATH, data)
	var table := ObjidxReader.parse(idx_bytes)
	if table == null:
		printerr("could not parse the object index")
		quit(1)
		return

	var n := CANDIDATES.size()
	var listed_hit: Array = []
	var listed_total := 0
	var fp_in: Array = []
	var fp_total: Array = []
	var link_dist: Array = []
	var link_n := 0
	var dfp_in: Array = []
	var dfp_total: Array = []
	var bb_both: Array = []
	var bb_only_box: Array = []
	var bb_only_list: Array = []
	var coincide: Array = []
	var box_both: Array = []
	var box_only: Array = []
	var box_list_only: Array = []
	for i in range(2 * n):
		box_both.append(0)
		box_only.append(0)
		box_list_only.append(0)
	for i in range(n):
		coincide.append(0)
		listed_hit.append(0)
		fp_in.append(0)
		fp_total.append(0)
		link_dist.append(0.0)
		dfp_in.append(0)
		dfp_total.append(0)
		bb_both.append(0)
		bb_only_box.append(0)
		bb_only_list.append(0)
	var yaw_bins := [0, 0, 0, 0, 0] # near 0, 90, 180, 270 degrees (within 1 deg), other
	var objects_seen := 0
	var objects_placed := 0

	var specs: Array = []
	for spec in regions.split(","):
		if spec.strip_edges() != "":
			specs.append(spec.strip_edges())
	# --scan=x0:x1:step,y0:y1:step,max -- every region on that lattice with a
	# navmesh carrying at least 20 objects, up to max regions.
	var scan := _arg("--scan")
	if scan != "":
		var sp := scan.split(",")
		var xs := sp[0].split(":")
		var ys := sp[1].split(":")
		var cap := int(sp[2])
		var found := 0
		for x in range(int(xs[0]), int(xs[1]) + 1, int(xs[2])):
			for y in range(int(ys[0]), int(ys[1]) + 1, int(ys[2])):
				if found >= cap:
					break
				var k := (x << 8) | y
				var b := AssetSource.read_bytes(NAVMESH_PATH_FORMAT % k, data)
				if b.is_empty():
					continue
				var probe := NvmReader.parse(b)
				if probe == null or probe.objects.size() < 20:
					continue
				specs.append("%d/%d" % [x, y])
				found += 1
	for spec in specs:
		var parts: PackedStringArray = String(spec).strip_edges().split("/")
		if parts.size() != 2:
			continue
		var key := (int(parts[0]) << 8) | int(parts[1])
		var bytes := AssetSource.read_bytes(NAVMESH_PATH_FORMAT % key, data)
		if bytes.is_empty():
			print("%s: no navmesh nv_%04x" % [spec, key])
			continue
		var nvm := NvmReader.parse(bytes)
		if nvm == null:
			print("%s: navmesh did not parse" % spec)
			continue
		# Per object: its placed triangles under each candidate.
		var placed: Array = [] # [object index] -> Array of PackedVector2Array per candidate, or null
		for oi in range(nvm.objects.size()):
			var obj: NvmReader.MapObject = nvm.objects[oi]
			objects_seen += 1
			var deg := fposmod(rad_to_deg(obj.yaw), 360.0)
			var bin := 4
			for b in range(4):
				var d := absf(deg - 90.0 * b)
				if d < 1.0 or absf(d - 360.0) < 1.0:
					bin = b
			yaw_bins[bin] += 1
			var col := _collision(data, table, obj.resource_id)
			if _arg("--list") != "" and bin != 0 and bin != 2:
				var le = table.lookup(obj.resource_id)
				print("%s obj%d %s yaw %.1f at %.1f,%.1f" % [spec, oi, le.path.get_file() if le != null else "?", deg, obj.local_position.x, obj.local_position.z])
			if col == null:
				placed.append(null)
				continue
			objects_placed += 1
			var per: Array = []
			for c in CANDIDATES:
				per.append(_placed_triangles(col, obj.local_position, c[1] * obj.yaw + c[2]))
			placed.append(per)

		# Which objects can tell conventions apart at all: a yaw within 1 degree
		# of 0 or 180 is (nearly) unchanged by negation.
		var discriminating := {}
		for oi in range(nvm.objects.size()):
			var dd := fposmod(rad_to_deg(nvm.objects[oi].yaw), 180.0)
			if dd > 1.0 and dd < 179.0 and placed[oi] != null:
				discriminating[oi] = true

		# Metric 4: does the engine list a cell exactly when the placed mesh's
		# axis-aligned bounds overlap it? Recall and precision of that rule,
		# over the discriminating objects only.
		for oi in discriminating:
			var listing := {}
			for ci in range(nvm.cells.size()):
				if nvm.cells[ci].object_indices.has(oi):
					listing[ci] = true
			for i in range(n):
				var tris: PackedVector2Array = placed[oi][i]
				var lo := Vector2(INF, INF)
				var hi := Vector2(-INF, -INF)
				for q in tris:
					lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
					hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
				for ci in range(nvm.cells.size()):
					var cell: NvmReader.Cell = nvm.cells[ci]
					var over := lo.x < cell.rect_max.x and hi.x > cell.rect_min.x and lo.y < cell.rect_max.y and hi.y > cell.rect_min.y
					if over and listing.has(ci):
						bb_both[i] += 1
					elif over:
						bb_only_box[i] += 1
					elif listing.has(ci):
						bb_only_list[i] += 1

		# Metric 5: vertex coincidence. Adjacent authored pieces (wall runs,
		# rows of houses, bridge spans) share exact vertices. Under the right
		# convention placed vertices of DIFFERENT objects coincide (0.05-unit
		# grid, 3-D); under a wrong one the coincidences involving any object
		# not at 0/180 degrees disappear. Counted as grid keys that hold
		# vertices of two or more objects, at least one of them discriminating.
		for i in range(n):
			var c = CANDIDATES[i]
			var owners := {} # quantised key -> {object index: true}
			for oi in range(nvm.objects.size()):
				if placed[oi] == null:
					continue
				var obj: NvmReader.MapObject = nvm.objects[oi]
				var col2: BmsReader.CollisionMesh = _collision_cache[obj.resource_id]
				var basis2 := Basis(Vector3.UP, c[1] * obj.yaw + c[2])
				for v in col2.vertices:
					var p3: Vector3 = obj.local_position + basis2 * v.position
					var qk := "%d,%d,%d" % [roundi(p3.x * 20.0), roundi(p3.y * 20.0), roundi(p3.z * 20.0)]
					if not owners.has(qk):
						owners[qk] = {}
					owners[qk][oi] = true
			for qk in owners:
				var who: Dictionary = owners[qk]
				if who.size() < 2:
					continue
				var any_disc := false
				for oi in who:
					if discriminating.has(oi):
						any_disc = true
				if any_disc:
					coincide[i] += 1

		# Metric 6: rotated local boxes. For each object take a local box --
		# (a) its navigation mesh's own local bounds, (b) its .bsr's declared
		# bounds -- rotate the four corners under each candidate, take the
		# world-aligned bounds, and compare the cells it overlaps with the
		# cells that list the object. All objects (the 0/180 ones cannot
		# separate the candidates but also cannot hide a wrong rule).
		for oi in range(nvm.objects.size()):
			if placed[oi] == null:
				continue
			var obj: NvmReader.MapObject = nvm.objects[oi]
			var col3: BmsReader.CollisionMesh = _collision_cache[obj.resource_id]
			var boxes: Array = []
			var lmin := Vector3(INF, INF, INF)
			var lmax := Vector3(-INF, -INF, -INF)
			for v in col3.vertices:
				var vp: Vector3 = v.position
				lmin = Vector3(minf(lmin.x, vp.x), minf(lmin.y, vp.y), minf(lmin.z, vp.z))
				lmax = Vector3(maxf(lmax.x, vp.x), maxf(lmax.y, vp.y), maxf(lmax.z, vp.z))
			boxes.append([lmin, lmax])
			var bsr_box = _bsr_bounds.get(obj.resource_id, null)
			boxes.append(bsr_box)
			var listing := {}
			for ci in range(nvm.cells.size()):
				if nvm.cells[ci].object_indices.has(oi):
					listing[ci] = true
			for bi in range(2):
				if boxes[bi] == null:
					continue
				var bmin: Vector3 = boxes[bi][0]
				var bmax: Vector3 = boxes[bi][1]
				for i in range(n):
					var c = CANDIDATES[i]
					var basis4 := Basis(Vector3.UP, c[1] * obj.yaw + c[2])
					var lo := Vector2(INF, INF)
					var hi := Vector2(-INF, -INF)
					for corner in [Vector3(bmin.x, 0, bmin.z), Vector3(bmax.x, 0, bmin.z), Vector3(bmax.x, 0, bmax.z), Vector3(bmin.x, 0, bmax.z)]:
						var w: Vector3 = obj.local_position + basis4 * corner
						lo = Vector2(minf(lo.x, w.x), minf(lo.y, w.z))
						hi = Vector2(maxf(hi.x, w.x), maxf(hi.y, w.z))
					for ci in range(nvm.cells.size()):
						var cell: NvmReader.Cell = nvm.cells[ci]
						var over := lo.x < cell.rect_max.x and hi.x > cell.rect_min.x and lo.y < cell.rect_max.y and hi.y > cell.rect_min.y
						var k6 := bi * n + i
						if over and listing.has(ci):
							box_both[k6] += 1
						elif over:
							box_only[k6] += 1
						elif listing.has(ci):
							box_list_only[k6] += 1

		# Metric 1: every (cell, listed object) pair.
		var listers := {} # object index -> Array of cell indices listing it
		for ci in range(nvm.cells.size()):
			var cell: NvmReader.Cell = nvm.cells[ci]
			for oi in cell.object_indices:
				if oi < 0 or oi >= placed.size() or placed[oi] == null:
					continue
				listers[oi] = listers.get(oi, []) + [ci]
				listed_total += 1
				for i in range(n):
					if _overlaps_rect(placed[oi][i], cell.rect_min, cell.rect_max):
						listed_hit[i] += 1

		# Metric 2: each placed triangle's centroid, in the cell that holds it,
		# should be in a cell that lists the object. Cells are bucketed on a
		# 20-unit grid built from their own rectangles, so the lookup assumes
		# nothing about the tile map's orientation.
		var buckets := {}
		for ci in range(nvm.cells.size()):
			var cell: NvmReader.Cell = nvm.cells[ci]
			var x0 := int(floor(cell.rect_min.x / 20.0))
			var x1 := int(floor(cell.rect_max.x / 20.0))
			var z0 := int(floor(cell.rect_min.y / 20.0))
			var z1 := int(floor(cell.rect_max.y / 20.0))
			for bx in range(x0, x1 + 1):
				for bz in range(z0, z1 + 1):
					var bk := bx * 1000 + bz
					buckets[bk] = buckets.get(bk, []) + [ci]
		for oi in range(placed.size()):
			if placed[oi] == null:
				continue
			var own: Array = listers.get(oi, [])
			for i in range(n):
				var tris: PackedVector2Array = placed[oi][i]
				for t in range(0, tris.size(), 3):
					var ctr := (tris[t] + tris[t + 1] + tris[t + 2]) / 3.0
					if ctr.x < 0.0 or ctr.y < 0.0 or ctr.x >= 1920.0 or ctr.y >= 1920.0:
						continue
					var holder := -1
					var bk := int(floor(ctr.x / 20.0)) * 1000 + int(floor(ctr.y / 20.0))
					for ci in buckets.get(bk, []):
						var cell: NvmReader.Cell = nvm.cells[ci]
						if _in_rect(ctr, cell.rect_min, cell.rect_max):
							holder = ci
							break
					if holder < 0:
						continue
					fp_total[i] += 1
					if own.has(holder):
						fp_in[i] += 1
					if discriminating.has(oi):
						dfp_total[i] += 1
						if own.has(holder):
							dfp_in[i] += 1

		# Metric 3: linked edges (outline-edge index space; reported as found).
		for oi in range(nvm.objects.size()):
			var obj: NvmReader.MapObject = nvm.objects[oi]
			if placed[oi] == null:
				continue
			for le in obj.linked_edges:
				var other := le.other_object_index
				if other < 0 or other >= nvm.objects.size() or placed[other] == null:
					continue
				var ca: BmsReader.CollisionMesh = _collision_cache[obj.resource_id]
				var cb: BmsReader.CollisionMesh = _collision_cache[nvm.objects[other].resource_id]
				if le.edge_index >= ca.outline_edges.size() or le.other_edge_index >= cb.outline_edges.size():
					continue
				link_n += 1
				var ob: NvmReader.MapObject = nvm.objects[other]
				var per_link := "%s link obj%d(yaw %.1f) e%d -> obj%d(yaw %.1f) e%d:" % [spec, oi, rad_to_deg(obj.yaw), le.edge_index, other, rad_to_deg(ob.yaw), le.other_edge_index]
				for i in range(n):
					var c = CANDIDATES[i]
					var ba := Basis(Vector3.UP, c[1] * obj.yaw + c[2])
					var bb := Basis(Vector3.UP, c[1] * ob.yaw + c[2])
					var ea: BmsReader.CollisionEdge = ca.outline_edges[le.edge_index]
					var eb: BmsReader.CollisionEdge = cb.outline_edges[le.other_edge_index]
					var ma: Vector3 = obj.local_position + ba * ((ca.vertices[ea.v0].position + ca.vertices[ea.v1].position) / 2.0)
					var mb: Vector3 = ob.local_position + bb * ((cb.vertices[eb.v0].position + cb.vertices[eb.v1].position) / 2.0)
					var dl := Vector2(ma.x - mb.x, ma.z - mb.z).length()
					link_dist[i] += dl
					if i < 2:
						per_link += " %s %.2f" % [c[0], dl]
				if _arg("--links") != "":
					print(per_link)
		print("%s: nv_%04x -- %d objects, %d cells" % [spec, key, nvm.objects.size(), nvm.cells.size()])

	print("objects: %d seen, %d with a navigation mesh; yaw within 1 deg of 0/90/180/270: %d/%d/%d/%d, other %d" % [
		objects_seen, objects_placed, yaw_bins[0], yaw_bins[1], yaw_bins[2], yaw_bins[3], yaw_bins[4]])
	print("%-10s %22s %24s %22s" % ["convention", "listed hit", "footprint precision", "linked-edge mean dist"])
	for i in range(n):
		var lh := "%d/%d (%.1f%%)" % [listed_hit[i], listed_total, 100.0 * listed_hit[i] / maxf(1.0, listed_total)]
		var fp := "%d/%d (%.1f%%)" % [fp_in[i], fp_total[i], 100.0 * fp_in[i] / maxf(1.0, fp_total[i])]
		var ld := ("%.3f over %d" % [link_dist[i] / link_n, link_n]) if link_n > 0 else "-"
		print("%-10s %22s %24s %22s" % [CANDIDATES[i][0], lh, fp, ld])
	print("")
	print("objects whose yaw is not within 1 deg of 0/180 only:")
	print("%-10s %24s %34s %30s" % ["convention", "footprint precision", "bounds-overlap vs listing (both/box-only/list-only)", "vertex coincidence"])
	for i in range(n):
		var dfp := "%d/%d (%.1f%%)" % [dfp_in[i], dfp_total[i], 100.0 * dfp_in[i] / maxf(1.0, dfp_total[i])]
		var bb := "%d / %d / %d" % [bb_both[i], bb_only_box[i], bb_only_list[i]]
		print("%-10s %24s %34s %10d coincident vertices" % [CANDIDATES[i][0], dfp, bb, coincide[i]])
	for bi in range(2):
		print("")
		print(["rotated navmesh-local box vs listing (all objects): both / box-only / list-only",
			"rotated .bsr box vs listing (objects with .bsr bounds): both / box-only / list-only"][bi])
		for i in range(n):
			var k6 := bi * n + i
			print("%-10s %8d / %6d / %6d" % [CANDIDATES[i][0], box_both[k6], box_only[k6], box_list_only[k6]])
	quit(0)
