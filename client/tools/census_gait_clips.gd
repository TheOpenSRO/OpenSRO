extends SceneTree

## Dev tool (round 853): which bodies have no stand, walk or run clip.
##
## The client's MOVE state (READ c:0xa59680) plays type 1 (walk) or 7 (run)
## through the body's play call with no fallback and no check of the result:
## the lookup (CCObjCharacter slot 3 c:0xa5faf0 -> CCObjAnimation::
## FUN_00a5b550 c:0xa5b550) tries the body's group, then `default`, and plays
## nothing when both miss. This lists, per `.bsr` in a list, the entries the
## same lookup finds for types 0, 1 and 7 in `default` (BsrReader.
## animation_entry_for, the client's rule) and whether each clip's `.ban` is in
## the archive, one tab-separated line a file:
##
##   GAIT<TAB>path<TAB>label<TAB>groups=<n><TAB>stand=<clip|->
##       <TAB>walk=<clip|-><TAB>run=<clip|-><TAB>missing_ban=<types>
##
## or `GAIT<TAB>path<TAB>label<TAB>MISSING|NOPARSE`. The list is
## `path<TAB>label...` lines (the label is passed through).
##
##   godot4 --headless --path client --script res://tools/census_gait_clips.gd -- \
##     --pk2=/path/Data.pk2 --list=<file>

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	var f := FileAccess.open(_arg("--list"), FileAccess.READ)
	if archive == null or f == null:
		printerr("usage: --pk2=<Data.pk2> --list=<file>")
		quit(2)
		return
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		var parts := line.split("\t")
		var path := parts[0]
		var label := "\t".join(parts.slice(1)) if parts.size() > 1 else ""
		var data := SkinnedBsrAssembler._read(archive, path)
		if data.is_empty():
			print("GAIT\t%s\t%s\tMISSING" % [path, label])
			continue
		var parsed := BsrReader.parse(data)
		if parsed == null:
			print("GAIT\t%s\t%s\tNOPARSE" % [path, label])
			continue
		var cols: PackedStringArray = []
		var missing_ban: PackedStringArray = []
		for t in [BsrReader.AnimationEntry.TYPE_STAND, BsrReader.AnimationEntry.TYPE_WALK, BsrReader.AnimationEntry.TYPE_RUN]:
			var entry := parsed.animation_entry_for(t, "default")
			var clip := "-"
			if entry != null:
				clip = entry.path.get_file()
				if SkinnedBsrAssembler._read(archive, entry.path).is_empty():
					missing_ban.append(str(t))
			cols.append(clip)
		print("GAIT\t%s\t%s\tgroups=%d\tstand=%s\twalk=%s\trun=%s\tmissing_ban=%s" % [path, label,
			parsed.animation_groups.size(), cols[0], cols[1], cols[2], ",".join(missing_ban)])
	quit(0)
