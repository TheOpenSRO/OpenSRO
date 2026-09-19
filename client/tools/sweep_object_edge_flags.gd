extends SceneTree

## Dev tool: the flag histogram of every object navigation mesh's edges, over
## the whole object index, split by list (outline / internal).
##
## Why it exists: the client's own object-navmesh walk (see
## docs/protocol/BMS_FORMAT.md's "Edge semantics" and NAVMESH_MOVEMENT.md)
## reads an edge's flag byte *directionally* -- value 1 blocks a mover on the
## edge's `cell_to` side, value 2 one on its `cell_from` side, 4 marks an
## internal edge, 8 a link to another object -- so the question "which edges
## let a character walk into a building" is answered by counting outline
## edges whose bit 0 is clear, per object, and that is what this prints.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_object_edge_flags.gd -- \
##     --pk2=/path/to/Data.pk2 [--map-pk2=/path/to/Map.pk2] [--limit=n] [--name=substring]

const OBJECT_INDEX_PATH := "navmesh\\object.ifo"

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _bump(histogram: Dictionary, key, by: int = 1) -> void:
	histogram[key] = int(histogram.get(key, 0)) + by

func _print_histogram(title: String, histogram: Dictionary) -> void:
	var keys := histogram.keys()
	keys.sort()
	var total := 0
	for k in keys:
		total += int(histogram[k])
	print("    %s (%d):" % [title, total])
	for k in keys:
		var n: int = histogram[k]
		print("      flag %3d (0x%02x)  %7d  %5.1f%%" % [k, k, n, 100.0 * n / maxf(total, 1)])

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var map_path := _arg("--map-pk2")
	var limit := int(_arg("--limit", "0"))
	var name_filter := _arg("--name").to_lower()
	if pk2_path == "":
		printerr("usage: --pk2=<Data.pk2> [--map-pk2=<Map.pk2>] [--limit=n] [--name=substring]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
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
		if entry == null:
			printerr("no object index in either archive")
			quit(1)
			return
		table = ObjidxReader.parse(archive.read_file(entry))
	if table == null:
		printerr("could not parse the object index")
		quit(1)
		return

	var outline := {}
	var internal := {}
	var objects := 0
	var with_navmesh := 0
	var enterable := 0
	var sealed := 0
	var sealed_examples: Array[String] = []
	var enterable_examples: Array[String] = []
	var per_object_lines: Array[String] = []
	## Objects whose collision section names an event. The client's own loader
	## sets a per-mesh byte when that name is "event"/"EVENT" (sro_client.exe
	## 0x449395/0x4495d9), and its terrain walk reads that byte to decide
	## whether the terrain and other objects still block a mover standing on
	## this one (CRTNavMeshTerrain::vslot_002, 0x404c71).
	var with_events := 0
	var event_names := {}
	var event_examples: Array[String] = []
	var seen := {}
	for entry in table.entries:
		var path: String = entry.path
		if path == "" or not path.to_lower().ends_with(".bsr") or seen.has(path):
			continue
		seen[path] = true
		if name_filter != "" and not path.to_lower().contains(name_filter):
			continue
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
		var found := false
		var open_edges := 0
		var wall_edges := 0
		var object_outline := {}
		var object_events: Array[String] = []
		for i in range(meshes.size()):
			var mesh_entry := ObjectLoader.find_file(archive, meshes[i])
			if mesh_entry == null:
				continue
			var collision := BmsReader.parse_collision(archive.read_file(mesh_entry))
			if collision == null or collision.cells.is_empty():
				continue
			found = true
			for ev in collision.events:
				object_events.append(ev)
				_bump(event_names, ev)
			for edge in collision.outline_edges:
				_bump(outline, edge.flags)
				_bump(object_outline, edge.flags)
				if (edge.flags & 1) == 0:
					open_edges += 1
				else:
					wall_edges += 1
			for edge in collision.internal_edges:
				_bump(internal, edge.flags)
		if not found:
			continue
		with_navmesh += 1
		if not object_events.is_empty():
			with_events += 1
			if event_examples.size() < 16:
				event_examples.append(path.get_file())
		if open_edges > 0:
			enterable += 1
			if enterable_examples.size() < 12:
				enterable_examples.append("%s (%d open / %d wall)" % [path.get_file(), open_edges, wall_edges])
		else:
			sealed += 1
			if sealed_examples.size() < 12:
				sealed_examples.append("%s (%d wall)" % [path.get_file(), wall_edges])
		if name_filter != "":
			var flags_text := ""
			var fkeys := object_outline.keys()
			fkeys.sort()
			for k in fkeys:
				flags_text += " %d:%d" % [k, object_outline[k]]
			per_object_lines.append("      %-40s outline%s%s" % [path.get_file(), flags_text,
				"" if object_events.is_empty() else "  events=" + ",".join(PackedStringArray(object_events))])
		if limit > 0 and objects >= limit:
			break

	print("--- %d distinct objects examined, %d carry a navigation mesh" % [objects, with_navmesh])
	_print_histogram("outline edges", outline)
	_print_histogram("internal edges", internal)
	print("    objects with at least one outline edge a mover outside may cross (bit 0 clear): %d" % enterable)
	print("    objects sealed on every outline edge (bit 0 set on all): %d" % sealed)
	if not enterable_examples.is_empty():
		print("      enterable e.g. %s" % ", ".join(PackedStringArray(enterable_examples)))
	if not sealed_examples.is_empty():
		print("      sealed e.g. %s" % ", ".join(PackedStringArray(sealed_examples)))
	print("    objects whose collision section names an event: %d  (names: %s)" % [with_events, str(event_names)])
	if not event_examples.is_empty():
		print("      e.g. %s" % ", ".join(PackedStringArray(event_examples)))
	for line in per_object_lines:
		print(line)
	quit(0)
