extends SceneTree

## Dev tool: assembles a character body .bsr from an archive and prints the
## combined AABB of its meshes in skeleton-local space -- so "how far below the
## skeleton origin do the feet sit?" has a measured number behind it, not a
## guess. The world places the player origin at the walkable surface (the
## capsule stands on the ground), so a skeleton attached with no offset buries
## the body by exactly -min.y; this reports that value.
##
## Headless is fine -- it reads geometry, renders nothing:
##   godot4 --headless --path client --script res://tools/measure_assembled.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var media_path := _arg("--media")
	var body := _arg("--body", "CHAR_CH_MAN_FIGHTER")
	if pk2_path == "" or media_path == "":
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--body=<code>]")
		quit(2)
		return

	var data := Pk2Reader.open(pk2_path)
	var media := Pk2Reader.open(media_path)
	if data == null or media == null:
		printerr("could not open archives")
		quit(1)
		return

	# Resolve the body code to its .bsr the same way World3D does.
	var bodies := {}
	for path in NpcTableReader.model_table_paths(media):
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			bodies = NpcTableReader.parse_models_by_code(media.read_file(entry), bodies)
	var bsr_path: String = bodies.get(body, "")
	if bsr_path == "":
		printerr("no row for body code ", body)
		quit(1)
		return

	var assembled := SkinnedBsrAssembler.assemble_from_archive(data, bsr_path, false)
	if assembled == null:
		printerr("could not assemble ", bsr_path)
		quit(1)
		return
	var skeleton := assembled.skeleton

	var bounds := AABB()
	var seeded := false
	var stack: Array[Node] = [skeleton]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D and (current as MeshInstance3D).mesh != null:
			var mi := current as MeshInstance3D
			# MeshInstance transform is identity under the skeleton; the mesh's
			# own aabb is already in skeleton-local space for skinned pieces.
			var box: AABB = mi.transform * mi.mesh.get_aabb()
			bounds = box if not seeded else bounds.merge(box)
			seeded = true
		for child in current.get_children():
			stack.append(child)
	if not seeded:
		printerr("no drawable meshes")
		quit(1)
		return

	print("body %s -> %s" % [body, bsr_path])
	print("aabb min=%s max=%s" % [str(bounds.position), str(bounds.position + bounds.size)])
	print("height=%.3f  feet-below-origin(-min.y)=%.3f  center.y=%.3f" % [
		bounds.size.y, -bounds.position.y, bounds.get_center().y])
	quit(0)
