extends SceneTree

## Dev tool: over every object in the object index, counts how many of its
## meshes carry navigation (collision) data, and how often the first mesh --
## the only one the walkable graph reads -- is not one of them.
##
## The graph resolves an object with `BsrReader.parse(...).mesh_path`, a
## single mesh. A building's walkable surface is one piece among many
## (`cj_luxu_floor.bms` of twelve, `cj_armo_floor.bms` of seven), and the
## pieces are in alphabetical order, so whether the graph finds it is
## chance. Where it does not, the object is reported as having no navigation
## mesh at all and a player walks inside it -- Jangan's six shops, its city
## wall and the palace door.
##
## The number that decides the fix is how many objects carry navigation data
## in **more than one** mesh: if none do, taking the first mesh that has any
## is complete, and merging several is unnecessary machinery.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_object_collision.gd -- \
##     --pk2=/path/to/Data.pk2 [--map-pk2=/path/to/Map.pk2] [--limit=n]

const OBJECT_INDEX_PATH := "navmesh\\object.ifo"
const MAP_OBJECT_INDEX_PATH := "navmesh\\object.ifo"

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var map_path := _arg("--map-pk2")
	var limit := int(_arg("--limit", "0"))
	if pk2_path == "":
		printerr("usage: --pk2=<Data.pk2> [--map-pk2=<Map.pk2>] [--limit=n]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	# The map's own table is the authoritative one where it exists; see
	# AGENTS.md's established facts.
	var table: ObjidxReader.Table = null
	if map_path != "":
		var map_archive := Pk2Reader.open(map_path)
		if map_archive != null:
			var e := ObjectLoader.find_file(map_archive, MAP_OBJECT_INDEX_PATH)
			if e != null:
				table = ObjidxReader.parse(map_archive.read_file(e))
	if table == null:
		var entry := ObjectLoader.find_file(archive, OBJECT_INDEX_PATH)
		if entry == null:
			printerr("no object index in either archive")
			quit(1)
			return
		table = ObjidxReader.parse(archive.read_file(entry))
	if table == null:
		printerr("could not parse the object index")
		quit(1)
		return

	var seen := {}
	var objects := 0
	var none := 0
	var one := 0
	var several := 0
	var first_has_it := 0
	var first_lacks_it := 0
	var examples: Array[String] = []
	var multi_examples: Array[String] = []
	## Where the objects that carry no navigation data at all come from.
	## A shrub having none is expected; a building having none is a hole a
	## player can walk into.
	var none_by_area := {}
	var none_buildings: Array[String] = []

	for entry in table.entries:
		var path: String = entry.path
		if path == "" or not path.to_lower().ends_with(".bsr") or seen.has(path):
			continue
		seen[path] = true
		var bsr_entry := ObjectLoader.find_file(archive, path)
		if bsr_entry == null:
			continue
		var bsr := BsrReader.parse(archive.read_file(bsr_entry))
		if bsr == null or bsr.mesh_path == "":
			continue
		objects += 1
		var meshes: Array[String] = [bsr.mesh_path]
		for p in bsr.sub_mesh_paths:
			meshes.append(p)

		var carrying := 0
		var first := false
		for i in range(meshes.size()):
			var mesh_entry := ObjectLoader.find_file(archive, meshes[i])
			if mesh_entry == null:
				continue
			var collision := BmsReader.parse_collision(archive.read_file(mesh_entry))
			if collision == null or collision.cells.is_empty():
				continue
			carrying += 1
			if i == 0:
				first = true
		if carrying == 0:
			none += 1
			var area := path.get_base_dir().to_lower()
			var head := area.split("\\")
			var bucket: String = "%s\\%s" % [head[0], head[1]] if head.size() > 1 else area
			none_by_area[bucket] = int(none_by_area.get(bucket, 0)) + 1
			if area.contains("bldg") and none_buildings.size() < 20:
				none_buildings.append(path.get_file())
		elif carrying == 1:
			one += 1
		else:
			several += 1
			if multi_examples.size() < 8:
				multi_examples.append("%s (%d of %d)" % [path.get_file(), carrying, meshes.size()])
		if carrying > 0:
			if first:
				first_has_it += 1
			else:
				first_lacks_it += 1
				if examples.size() < 8:
					examples.append("%s (%d mesh(es))" % [path.get_file(), meshes.size()])
		if limit > 0 and objects >= limit:
			break

	print("--- %d distinct objects examined" % objects)
	print("    %d carry navigation data in no mesh at all" % none)
	print("    %d carry it in exactly one mesh" % one)
	print("    %d carry it in more than one" % several)
	if not multi_examples.is_empty():
		print("      e.g. %s" % ", ".join(PackedStringArray(multi_examples)))
	print("    of the %d that carry it anywhere:" % (first_has_it + first_lacks_it))
	print("      %d have it in the first mesh (the graph finds these)" % first_has_it)
	print("      %d do not (the graph reports these as having none)" % first_lacks_it)
	if not examples.is_empty():
		print("      e.g. %s" % ", ".join(PackedStringArray(examples)))
	print("")
	print("    where the %d with no navigation data at all come from:" % none)
	var areas := none_by_area.keys()
	areas.sort_custom(func(a, b): return int(none_by_area[a]) > int(none_by_area[b]))
	for a in areas:
		print("      %-40s %d" % [a, int(none_by_area[a])])
	if not none_buildings.is_empty():
		print("    buildings among them: %s" % ", ".join(PackedStringArray(none_buildings)))
	quit(0)
