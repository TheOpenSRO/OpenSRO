extends SceneTree

## Dev tool: loads NPC models by their real `.bsr` path and reports what
## came back -- how many mesh pieces, how many vertices, and the assembled
## bounds.
##
## NPC spawn data lives server-side (a real `npcpos.txt` gives an NPC id, a
## region id and a position; a real `CharacterData` row maps that id to its
## own `.bsr`), so before any of that is wired up the question worth
## settling is whether this project can build the models at all through the
## same loader it already uses for scenery.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_npc_models.gd -- \
##     --pk2=/path/Data.pk2 --models="npc\\npc\\chinaquest_priest.bsr,..."

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _bounds(node: Node) -> AABB:
	var merged := AABB()
	var seeded := false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D:
			var mi := current as MeshInstance3D
			if mi.mesh != null:
				var box: AABB = mi.transform * mi.get_aabb()
				if seeded:
					merged = merged.merge(box)
				else:
					merged = box
					seeded = true
		for child in current.get_children():
			stack.append(child)
	return merged

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var models := _arg("--models")
	if pk2_path == "" or models == "":
		printerr("usage: --pk2=<Data.pk2> --models=<path[,path...]>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	print("%-44s %6s %9s  %s" % ["model", "pieces", "vertices", "size"])
	for raw in models.split(","):
		var path := raw.strip_edges()
		if path == "":
			continue
		# object.ifo spells these with a "res\" prefix the server tables omit.
		var candidates := [path, "res\\" + path]
		var node: Node3D = null
		for candidate in candidates:
			node = ObjectLoader.load_object(archive, candidate)
			if node != null:
				break
		if node == null:
			print("%-44s %s" % [path.get_file(), "COULD NOT LOAD"])
			continue
		var pieces := 0
		var verts := 0
		var stack: Array[Node] = [node]
		while not stack.is_empty():
			var current: Node = stack.pop_back()
			if current is MeshInstance3D and (current as MeshInstance3D).mesh != null:
				pieces += 1
				var mesh := (current as MeshInstance3D).mesh
				for s in range(mesh.get_surface_count()):
					verts += mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size()
			for child in current.get_children():
				stack.append(child)
		var box := _bounds(node)
		print("%-44s %6d %9d  %s" % [path.get_file(), pieces, verts, box.size.round()])
		node.free()

		# What the loader built is only half the answer -- the other half is
		# whether the .bsr itself gave up its skeleton and animations, which
		# is what decides if this model can be posed at all.
		var entry: Pk2Reader.Entry = null
		for candidate in candidates:
			entry = ObjectLoader.find_file(archive, candidate)
			if entry != null:
				break
		if entry == null:
			continue
		var parsed := BsrReader.parse(archive.read_file(entry))
		if parsed == null:
			print("%-44s  (bsr did not parse)" % "")
			continue
		print("%-44s  character=%s meshes=%d skeleton=%s animations=%d" % [
			"",
			parsed.is_character,
			parsed.all_mesh_paths().size(),
			"yes" if parsed.skeleton_path != "" else "no",
			parsed.animation_paths.size(),
		])
	quit(0)
