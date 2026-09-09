extends SceneTree

## Dev tool: searches every parsed `resinfo\` layout for controls matching a
## substring, in the control's name, type or artwork path, and prints them
## with their rects.
##
## Written because "does the client's own data do X" keeps being the
## question, and answering it by opening one layout at a time is how wrong
## answers get made -- the cell size of an item grid, the interior fill of a
## window and the close button of a panel were each settled only once every
## layout in the archive had been looked at rather than one.
##
## Usage:
##   godot4 --headless --path client --script res://tools/grep_layouts.gd -- \
##     --pk2=/path/to/Media.pk2 --match=windowclose [--field=ddj|name|type|any]

const RESINFO_DIR := "resinfo"

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var needle := _arg("--match").to_lower()
	var field := _arg("--field", "any").to_lower()
	if pk2_path == "" or needle == "":
		printerr("usage: --pk2=<Media.pk2> --match=<substring> [--field=ddj|name|type|any]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var dir_entry := ObjectLoader.find_file(archive, RESINFO_DIR)
	if dir_entry == null:
		printerr("no resinfo directory")
		quit(1)
		return

	var hits := 0
	for entry in archive.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".txt"):
			continue
		var layout := UiLayoutParser.parse(archive.read_file(entry))
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			for c in sec.controls:
				var haystack := ""
				match field:
					"ddj": haystack = c.ddj
					"name": haystack = c.name
					"type": haystack = c.type
					_: haystack = "%s %s %s %s" % [c.name, c.type, c.ddj, c.text]
				if not haystack.to_lower().contains(needle):
					continue
				hits += 1
				print("%-28s %-18s %-30s %-18s rect=%s ddj=%s" % [
					entry.name, key, c.name, c.type, str(c.rect), c.ddj])
	print("--- %d matching control(s)" % hits)
	quit(0)
