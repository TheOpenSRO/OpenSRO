extends SceneTree

## Dev tool: for one or more `.bsr` objects, reports which of their meshes
## carry a navigation (collision) section and how big it is.
##
## The walkable graph resolves an object by reading `bsr.mesh_path` -- the
## **first** mesh only -- so an object whose first piece has no navigation
## data is reported as having none at all, and a player walks inside it.
## Jangan has eight of those: the city wall, six shops and the palace's big
## door. This says whether their other pieces carry what the first one
## lacks.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_object_collision.gd -- \
##     --pk2=/path/to/Data.pk2 --bsr=res\\bldg\\china\\jangan\\cj_luxury.bsr

func _args(flag: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

func _init() -> void:
	var pk2 := _args("--pk2")
	var bsrs := _args("--bsr")
	if pk2.is_empty() or bsrs.is_empty():
		printerr("usage: --pk2=<Data.pk2> --bsr=<path in archive>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2[0])
	if archive == null:
		printerr("could not open ", pk2[0])
		quit(1)
		return

	for bsr_path in bsrs:
		var entry := ObjectLoader.find_file(archive, bsr_path)
		if entry == null:
			print("MISSING ", bsr_path)
			continue
		var bsr := BsrReader.parse(archive.read_file(entry))
		if bsr == null:
			print("UNPARSED ", bsr_path)
			continue
		var meshes: Array[String] = [bsr.mesh_path]
		for p in bsr.sub_mesh_paths:
			meshes.append(p)
		print("=== %s -- %d mesh(es)" % [bsr_path, meshes.size()])
		var with_collision := 0
		var total_cells := 0
		for i in range(meshes.size()):
			var path := meshes[i]
			if path == "":
				continue
			var mesh_entry := ObjectLoader.find_file(archive, path)
			if mesh_entry == null:
				print("  [%2d] %-52s MISSING" % [i, path])
				continue
			var collision := BmsReader.parse_collision(archive.read_file(mesh_entry))
			if collision == null or collision.cells.is_empty():
				print("  [%2d] %-52s no navigation data" % [i, path])
				continue
			with_collision += 1
			total_cells += collision.cells.size()
			print("  [%2d] %-52s %d cell(s), %d vertex(es), grid %dx%d" % [
				i, path, collision.cells.size(), collision.vertices.size(),
				collision.grid_width, collision.grid_height])
		print("--- %d of %d mesh(es) carry navigation data, %d cell(s) in total%s" % [
			with_collision, meshes.size(), total_cells,
			"  <-- FIRST MESH HAS NONE" if with_collision > 0 and _first_lacks(archive, meshes) else ""])
	quit(0)

func _first_lacks(archive: Pk2Reader, meshes: Array[String]) -> bool:
	if meshes.is_empty() or meshes[0] == "":
		return true
	var entry := ObjectLoader.find_file(archive, meshes[0])
	if entry == null:
		return true
	var collision := BmsReader.parse_collision(archive.read_file(entry))
	return collision == null or collision.cells.is_empty()
