extends SceneTree

## Dev tool (round 644): over every object the navigation object index names,
## compares the navigation mesh the client loads with the one this project
## used to build.
##
## The client loads ONE mesh's collision section per object, READ in
## `MapLoader::FUN_0042c4a0` (the `.bsr` branch of the loader's
## last-letter switch `FUN_0042ce60`): it reads the `.bsr` header
## (`FUN_0043bfb0`), seeks to the header word at 0x28 -- the bounding-box
## block -- when it is non-zero, reads the length-prefixed path that block
## starts with (`FUN_0043c250`) and hands it to `FUN_0042cbc0`, which reads
## that `.bms`'s header and deserializes its collision section
## (`RTNavMeshObj::FUN_004489b0`). A zero word, or a path whose mesh has no
## collision section, is no navigation mesh.
##
## Until round 644 the graph merged the collision sections of EVERY mesh
## the `.bsr` lists (World3D._load_object_collision). This counts where
## that differs.
##
## Usage:
##   godot4 --headless --path client --script res://tools/navmesh_source_census.gd -- \
##     --pk2=<Data.pk2> [--map-pk2=<Map.pk2>] [--show=<n>] [--grep=<substring>]

const NAV_INDEX_PATH := "navmesh\\object.ifo"

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

static func _vmin(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))

static func _vmax(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))

func _collision_of(archive: Pk2Reader, path: String) -> BmsReader.CollisionMesh:
	if path == "":
		return null
	var e := ObjectLoader.find_file(archive, path)
	if e == null:
		return null
	var c := BmsReader.parse_collision(archive.read_file(e))
	if c == null or c.cells.is_empty():
		return null
	return c

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var show := int(_arg("--show", "40"))
	var grep := _arg("--grep", "").to_lower()
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var idx := ObjectLoader.find_file(archive, NAV_INDEX_PATH)
	if idx == null:
		printerr("no ", NAV_INDEX_PATH)
		quit(1)
		return
	var table := ObjidxReader.parse(archive.read_file(idx))
	var counts := {}
	var shown := 0
	for entry in table.entries:
		if entry == null or entry.path == "":
			continue
		var path: String = entry.path
		var lower := path.to_lower()
		if not lower.ends_with(".bsr"):
			var k := "not a .bsr (%s)" % lower.get_extension()
			counts[k] = int(counts.get(k, 0)) + 1
			continue
		var be := ObjectLoader.find_file(archive, path)
		if be == null:
			counts["bsr missing"] = int(counts.get("bsr missing", 0)) + 1
			continue
		var data := archive.read_file(be)
		var nav_path := NavObjectSource.navmesh_path_of_bsr(data)
		var bsr := BsrReader.parse(data)
		var meshes: Array[String] = []
		if bsr != null:
			meshes = bsr.all_mesh_paths()
		var carrying: Array[String] = []
		for m in meshes:
			if _collision_of(archive, m) != null:
				carrying.append(m)
		var retail := _collision_of(archive, nav_path)
		var kind := ""
		if retail == null and carrying.is_empty():
			kind = "neither has one"
		elif retail == null:
			if nav_path == "":
				kind = "ours only (no path at 0x28)"
			elif ObjectLoader.find_file(archive, nav_path) == null:
				kind = "ours only (0x28 path missing)"
			else:
				kind = "ours only (0x28 mesh has no section)"
		elif carrying.is_empty():
			kind = "client only"
		elif carrying.size() == 1 and carrying[0].to_lower() == nav_path.to_lower():
			kind = "same single mesh"
		elif carrying.has(nav_path) or carrying.map(func(s): return s.to_lower()).has(nav_path.to_lower()):
			kind = "we merged extra meshes"
		else:
			kind = "different mesh"
		counts[kind] = int(counts.get(kind, 0)) + 1
		var interesting := kind != "same single mesh" and kind != "neither has one"
		if (grep != "" and lower.contains(grep)) or (grep == "" and interesting and shown < show):
			shown += 1
			print("%05d %-26s %s  nav='%s'  ours=%s" % [entry.type_id, kind, path.get_file(), nav_path.get_file(), carrying.map(func(s): return s.get_file())])
			if grep != "":
				# Every render mesh's extent, so a navigation mesh can be set
				# against what is drawn.
				for m in meshes:
					var me := ObjectLoader.find_file(archive, m)
					var pm: BmsReader.ParsedMesh = null if me == null else BmsReader.parse(archive.read_file(me))
					if pm == null:
						print("      mesh %s: unreadable" % m.get_file())
						continue
					var lo := Vector3.INF
					var hi := -Vector3.INF
					for v in pm.vertices:
						lo = _vmin(lo, v.position)
						hi = _vmax(hi, v.position)
					print("      mesh %s: %d vertices, %s .. %s" % [m.get_file(), pm.vertices.size(), lo.round(), hi.round()])
				if retail != null:
					var lo2 := Vector3.INF
					var hi2 := -Vector3.INF
					for v in retail.vertices:
						lo2 = _vmin(lo2, v.position)
						hi2 = _vmax(hi2, v.position)
					print("      navmesh: %d cells, %s .. %s" % [retail.cells.size(), lo2.round(), hi2.round()])
	print("--- navigation object index: %d entries" % table.entries.size())
	var keys := counts.keys()
	keys.sort()
	for k in keys:
		print("   %6d  %s" % [counts[k], k])
	quit(0)
