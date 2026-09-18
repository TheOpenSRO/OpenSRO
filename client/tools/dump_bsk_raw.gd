extends SceneTree
## Dev tool: prints EVERY float of a `.bsk` bone record (22 floats after the
## Type-A leading dword), not just the rest rotation/position SkeletonPose
## reads -- so the record's other fields (the conjugate quaternion, the two
## further positions, the trailing scalar) can be identified against the
## client's own loader rather than guessed. Also prints a `.bsr`'s skeleton
## path and attach bone so an item's records can be pulled by name.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_bsk_raw.gd -- \
##     --pk2=/path/Data.pk2 --file="prim\skel\item\china\weapon\blade_01.bsk" \
##     [--bones="Bip01 R HandMid,Bip01 Neck1"] [--bsr="item\china\weapon\sword_01.bsr"]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

## An archive path argument: backslashes are eaten by nested ssh/su quoting,
## so forward slashes are accepted and normalised to the archive's own.
func _apath(flag: String) -> String:
	return _arg(flag).replace("/", "\\")

## Reads an archive file by its table path, with the same `res\` fallback
## SkinnedBsrAssembler uses (item tables name `item\...`, the archive holds
## `res\item\...`).
func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	var entry := ObjectLoader.find_file(archive, path)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + path)
	if entry == null:
		return PackedByteArray()
	return archive.read_file(entry)

func _floats(bytes: PackedByteArray) -> String:
	var out := ""
	var lead := 0
	if bytes.size() == BskReader.ROOT_TRANSFORM_LEN:
		out += "lead dword 0x%08x (%.4f as float)\n" % [bytes.decode_u32(0), bytes.decode_float(0)]
		lead = 4
	var n := int((bytes.size() - lead) / 4)
	var row := ""
	for i in range(n):
		row += "[%2d]%9.4f " % [i, bytes.decode_float(lead + i * 4)]
		if (i + 1) % 4 == 0 or i == n - 1:
			out += "      " + row + "\n"
			row = ""
	return out

func _init() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("cannot open --pk2")
		quit(1)
		return
	var bsr := _apath("--bsr")
	if bsr != "":
		for p in bsr.split(","):
			var bytes := _read(archive, p)
			if bytes.is_empty():
				print("%s: not in the archive" % p)
				continue
			var parsed := BsrReader.parse(bytes)
			if parsed == null:
				print("%s: did not parse" % p)
				continue
			print("%s: type %d, skeleton '%s', attach bone '%s', meshes %s" % [
				p.get_file(), parsed.object_type, parsed.skeleton_path, parsed.attach_bone,
				str(parsed.all_mesh_paths())])
	var wanted: Array = []
	if _arg("--bones") != "":
		for b in _arg("--bones").split(","):
			# Bone names carry spaces, which nested ssh quoting splits; accept
			# underscores in their place.
			wanted.append(b.strip_edges().replace("_", " "))
	for path in _apath("--file").split(",", false):
		var bytes := _read(archive, path)
		if bytes.is_empty():
			print("%s: not in the archive" % path)
			continue
		var skel := BskReader.parse(bytes)
		if skel == null:
			print("%s: did not parse" % path)
			continue
		print("== %s: root '%s', %d bone(s)" % [path.get_file(), skel.root_name, skel.bones.size()])
		print("   ROOT %s (%d bytes)" % [skel.root_name, skel.root_transform.size()])
		print(_floats(skel.root_transform))
		for bone in skel.bones:
			if not wanted.is_empty() and not (bone.bone_name in wanted):
				continue
			print("   %s (parent '%s', %d bytes)" % [bone.bone_name, bone.parent_name, bone.transform.size()])
			print(_floats(bone.transform))
	quit(0)
