extends SceneTree

## Dev probe: the ACTION TYPES a body's .bsr declares, per animation group.
##
## docs/protocol/BSR_FORMAT.md records that an entry's action type says what
## the animation is for, and that "26 and up are skills". This lists them with
## their clip names, which is what a skill -> animation mapping has to be built
## against: the client never names a .ban in code (zero references in the
## decompiled client), it looks a clip up by action type in this table.
##
## Usage:
##   godot4 --headless --path client --script res://tools/probe_anim_types.gd -- \
##     --pk2=/path/Data.pk2 --file="char\\china\\chinaman_fighter.bsr"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path: String = _arg("--pk2")
	var file_path: String = _arg("--file")
	if pk2_path == "" or file_path == "":
		printerr("need --pk2= and --file=")
		quit(2)
		return
	var archive = Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(2)
		return
	var entry = ObjectLoader.find_file(archive, file_path)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + file_path)
	if entry == null:
		printerr("not in archive: ", file_path)
		quit(2)
		return
	var obj = BsrReader.parse(archive.read_file(entry))
	if obj == null:
		printerr("could not parse ", file_path)
		quit(2)
		return
	var groups = obj.animation_groups
	print("groups: %d" % groups.size())
	for gname in groups:
		var entries = groups[gname]
		var skill_types: Array = []
		for e in entries:
			if int(e.action_type) >= 26:
				skill_types.append(int(e.action_type))
		skill_types.sort()
		print("  %-12s %3d entries, %3d with type >= 26: %s" % [
			gname, entries.size(), skill_types.size(),
			", ".join(PackedStringArray(skill_types.map(func(t): return str(t))))])
	quit(0)
