extends SceneTree

## Dev tool: computes the piece-to-bone mapping for a skinned `.bsr` from
## geometry alone, and prints it next to the distance it was decided by.
##
## MonsterAssembler currently carries two of these mappings as hardcoded
## dictionaries (golem, scorpion), each derived by hand from exactly this
## computation. That doesn't scale to the hundreds of NPCs and monsters the
## game has. Before replacing the dictionaries with a computation at
## runtime, the computation has to be shown to reproduce them -- so this
## tool prints its result for any model, and, for those two, whether it
## agrees with what was written down by hand.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_piece_bones.gd -- \
##     --pk2=/path/Data.pk2 --models="Res\\mob\\casia\\golem.bsr,..."

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	var entry := ObjectLoader.find_file(archive, path)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + path)
	if entry == null:
		return PackedByteArray()
	return archive.read_file(entry)

## The centroid of a piece's own vertices, in the absolute character-space
## coordinates .bms bakes in (see docs/protocol/BMS_FORMAT.md).
func _centroid(mesh: BmsReader.ParsedMesh) -> Vector3:
	if mesh.vertices.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for v in mesh.vertices:
		sum += v.position
	return sum / float(mesh.vertices.size())

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

	# The two mappings MonsterAssembler holds by hand, to check against.
	var known := {
		"golem": MonsterAssembler.GOLEM_PIECE_BONES,
		"scorpion": MonsterAssembler.SCORPION_PIECE_BONES,
	}

	for raw in models.split(","):
		var path := raw.strip_edges()
		if path == "":
			continue
		var data := _read(archive, path)
		if data.is_empty():
			print("%s: not in archive" % path)
			continue
		var parsed := BsrReader.parse(data)
		if parsed == null or parsed.skeleton_path == "":
			print("%s: no skeleton (is_character=%s)" % [path, parsed != null and parsed.is_character])
			continue

		var bsk_data := _read(archive, parsed.skeleton_path)
		if bsk_data.is_empty():
			print("%s: skeleton %s not in archive" % [path, parsed.skeleton_path])
			continue
		var skeleton := Skeleton3DBuilder.build_skeleton3d(BskReader.parse(bsk_data))
		if skeleton == null:
			print("%s: skeleton did not build" % path)
			continue

		# Every bone's bind-pose position, in the same absolute space the
		# mesh vertices are baked in.
		var bone_positions := {}
		for i in range(skeleton.get_bone_count()):
			bone_positions[skeleton.get_bone_name(i)] = skeleton.get_bone_global_rest(i).origin

		var model_key := path.get_file().get_basename().to_lower()
		var expected: Dictionary = known.get(model_key, {})
		print("%s -- %d bones, %d mesh pieces%s" % [
			path.get_file(),
			skeleton.get_bone_count(),
			parsed.all_mesh_paths().size(),
			"  (checking against the hand-derived map)" if not expected.is_empty() else "",
		])

		var agreed := 0
		var compared := 0
		for mesh_path in parsed.all_mesh_paths():
			var bms_data := _read(archive, mesh_path)
			if bms_data.is_empty():
				print("    %-28s mesh not in archive" % mesh_path.get_file())
				continue
			var mesh := BmsReader.parse(bms_data)
			if mesh == null:
				print("    %-28s mesh did not parse" % mesh_path.get_file())
				continue
			var centre := _centroid(mesh)
			var best_bone := ""
			var best_distance := INF
			for bone_name in bone_positions:
				var d: float = centre.distance_to(bone_positions[bone_name])
				if d < best_distance:
					best_distance = d
					best_bone = bone_name
			var piece := mesh_path.get_file().get_basename().to_lower()
			var verdict := ""
			if expected.has(piece):
				compared += 1
				if expected[piece] == best_bone:
					agreed += 1
					verdict = "  == hand-derived"
				else:
					verdict = "  != hand-derived (%s)" % expected[piece]
			print("    %-28s %5d verts -> %-18s  d=%.2f%s" % [
				piece, mesh.vertices.size(), best_bone, best_distance, verdict
			])
		if compared > 0:
			print("    %d/%d pieces agree with the hand-derived map" % [agreed, compared])
	quit(0)
