extends SceneTree
## Dev tool: prints a `.bsk` skeleton's bones -- name, parent, and the rest
## rotation and position SkeletonPose reads out of each record -- so an
## item skeleton's own root transform can be compared with where the item
## is drawn on the hand.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_bsk.gd -- \
##     --pk2=/path/Data.pk2 --file="prim\\skel\\item\\china\\weapon\\blade_01.bsk"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("cannot open --pk2")
		quit(1)
		return
	for path in _arg("--file").split(","):
		var entry := ObjectLoader.find_file(archive, path)
		if entry == null:
			print("%s: not in the archive" % path)
			continue
		var skel := BskReader.parse(archive.read_file(entry))
		if skel == null:
			print("%s: did not parse" % path)
			continue
		print("%s: root %s, %d bone(s)" % [path.get_file(), skel.root_name, skel.bones.size()])
		if not skel.root_transform.is_empty():
			var root := BskReader.Bone.new()
			root.bone_name = skel.root_name
			root.transform = skel.root_transform
			_print_transform("  root " + skel.root_name, root)
		for bone in skel.bones:
			_print_transform("  %s (parent %s)" % [bone.bone_name, bone.parent_name if bone.parent_name != "" else "-"], bone)
	quit(0)

func _print_transform(label: String, bone: BskReader.Bone) -> void:
	var rotation := SkeletonPose.bone_rotation(bone)
	var position := SkeletonPose.bone_local_position(bone)
	var euler := rotation.get_euler()
	print("%s: rotation (%.3f, %.3f, %.3f, %.3f) = euler deg (%.1f, %.1f, %.1f), position (%.2f, %.2f, %.2f)" % [
		label, rotation.x, rotation.y, rotation.z, rotation.w,
		rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z), position.x, position.y, position.z])
