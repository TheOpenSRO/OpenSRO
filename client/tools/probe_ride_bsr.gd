extends SceneTree

## Dev tool (round 809): a character `.bsr`'s animation groups -- per group
## each entry's action type, clip and key events, and the clip's length --
## plus its skeleton's bone count and root bones, for the ride and die
## bodies skilleffect.txt's characterInfo names.
##
##   godot4 --headless --path client --script res://tools/probe_ride_bsr.gd -- \
##     --pk2=/path/Data.pk2 --list=<file of .bsr paths, one a line>

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("no archive")
		quit(1)
		return
	var f := FileAccess.open(_arg("--list"), FileAccess.READ)
	while f != null and not f.eof_reached():
		var path := f.get_line().strip_edges()
		if path != "":
			_probe(archive, path)
	quit(0)

func _probe(archive: Pk2Reader, path: String) -> void:
	var data := SkinnedBsrAssembler._read(archive, path)
	if data.is_empty():
		print("RIDE %s: not found" % path)
		return
	var parsed := BsrReader.parse(data)
	if parsed == null:
		print("RIDE %s: does not parse" % path)
		return
	print("RIDE %s: type %d character %s skeleton '%s' meshes %d material '%s'" % [path, parsed.object_type,
		parsed.is_character, parsed.skeleton_path, parsed.all_mesh_paths().size(), parsed.material_path])
	if parsed.skeleton_path != "":
		var bsk := SkinnedBsrAssembler._read(archive, parsed.skeleton_path)
		var sk := BskReader.parse(bsk) if not bsk.is_empty() else null
		if sk != null:
			var s := Skeleton3DBuilder.build_skeleton3d(sk)
			if s != null:
				var names: Array = []
				for i in s.get_bone_count():
					names.append(s.get_bone_name(i))
				print("  bones %d: %s" % [s.get_bone_count(), ", ".join(names)])
				s.free()
	for g in parsed.animation_groups:
		print("  group '%s'" % g)
		for e in parsed.animation_groups[g]:
			var en := e as BsrReader.AnimationEntry
			var ms := -1
			if en.path != "":
				var ban := SkinnedBsrAssembler._read(archive, en.path)
				var a := BanReader.parse(ban) if not ban.is_empty() else null
				if a != null:
					ms = a.duration_ms
			var evs: Array = []
			for ev in en.events:
				evs.append("%d@%d(%d,%d)" % [(ev as PackedInt32Array)[1], (ev as PackedInt32Array)[0],
					(ev as PackedInt32Array)[2], (ev as PackedInt32Array)[3]])
			print("    type %d %s %d ms events %s" % [en.action_type, en.path.get_file(), ms, " ".join(evs)])
