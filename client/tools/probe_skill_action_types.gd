extends SceneTree

## Dev probe: join a skill's cast CLIP back to the ACTION TYPE that plays it.
##
## Round 316 established the mechanism: the client never names a .ban in code
## (zero references in the decompiled client); it looks an entry up in the body
## .bsr's animation table by action type. What is not settled is which skilldata
## column carries that type, and a range test cannot settle it -- 99 permitted
## values over 26..220 means any numeric column scores.
##
## This is the join instead. For every animation entry, print its action type
## beside the clip file it indexes. The skills whose derived filename exists
## (59 of 338) then give their action type directly, and the column is whichever
## one carries that number on those rows.
##
## Usage:
##   godot4 --headless --path client --script res://tools/probe_skill_action_types.gd -- \
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
	for gname in obj.animation_groups:
		for e in obj.animation_groups[gname]:
			var clip: String = String(e.path).to_lower()
			if clip.ends_with(".ban"):
				clip = clip.substr(0, clip.length() - 4)
			print("%s\t%d\t%s" % [gname, int(e.action_type), clip])
	quit(0)
