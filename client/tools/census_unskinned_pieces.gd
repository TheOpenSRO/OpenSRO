extends SceneTree

## Dev tool (round 816): lists every mesh piece of a skeletal `.bsr` that
## carries no bone palette -- the pieces the original draws on palette entry
## 0, the identity (ResObject::FUN_00be2f80 with an empty skin array;
## CObjRendererVS 0xbeeaa0 uploads the identity to c26), so they stand still
## in the model's own space whatever the skeleton does.
##
## Before round 816 SkinnedBsrAssembler hung such a piece rigidly off the bone
## nearest its centroid, which is how the storage keepers' chests came to bob
## with a clavicle and swing with a calf. This prints the whole set, so the
## change's reach is known.
##
## Usage:
##   godot4 --headless --path client --script res://tools/census_unskinned_pieces.gd -- \
##     --pk2=/path/Data.pk2 [--animated-only=1]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _collect(archive: Pk2Reader, dir_entry, prefix: String, out: Array) -> void:
	var entries: Array = archive.read_dir() if dir_entry == null else archive.read_dir_at(dir_entry)
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var path: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_collect(archive, e, path, out)
		elif e.name.to_lower().ends_with(".bsr"):
			out.append([path, e])

func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	var entry := ObjectLoader.find_file(archive, path)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + path)
	if entry == null:
		return PackedByteArray()
	return archive.read_file(entry)

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	if pk2_path == "":
		printerr("usage: --pk2=<Data.pk2> [--animated-only=1]")
		quit(2)
		return
	var animated_only := _arg("--animated-only", "1") == "1"
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var files: Array = []
	_collect(archive, null, "", files)
	files.sort()

	var models := 0
	var with_unskinned := 0
	var pieces := 0
	var by_folder := {}
	var mesh_cache := {}
	for pair in files:
		var path: String = pair[0]
		var data: PackedByteArray = archive.read_file(pair[1])
		if data.size() < 0x44:
			continue
		var parsed := BsrReader.parse(data)
		if parsed == null or parsed.skeleton_path == "":
			continue
		if animated_only and parsed.animation_paths.is_empty():
			continue
		models += 1
		var skinned := 0
		var bare: Array[String] = []
		for mesh_path in parsed.all_mesh_paths():
			var key := mesh_path.to_lower()
			if not mesh_cache.has(key):
				var bms := _read(archive, mesh_path)
				var mesh: BmsReader.ParsedMesh = BmsReader.parse(bms) if not bms.is_empty() else null
				mesh_cache[key] = -1 if mesh == null else (1 if mesh.is_skinned() else 0)
			match mesh_cache[key]:
				1:
					skinned += 1
				0:
					bare.append(mesh_path.get_file())
		if bare.is_empty():
			continue
		with_unskinned += 1
		pieces += bare.size()
		var folder := path.get_base_dir().to_lower()
		by_folder[folder] = by_folder.get(folder, 0) + 1
		print("%s  skinned %d  bare %d: %s" % [path, skinned, bare.size(), ", ".join(bare)])
	print("---")
	print("%d skeletal model(s)%s; %d with %d bare piece(s)" % [
		models, " with animations" if animated_only else "", with_unskinned, pieces])
	var folders := by_folder.keys()
	folders.sort()
	for f in folders:
		print("  %-40s %d" % [f, by_folder[f]])
	quit(0)
