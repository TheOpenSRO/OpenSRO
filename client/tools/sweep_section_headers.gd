extends SceneTree

## Dev tool: prints the trailing field of every section header across
## `resinfo\`, with how many sections carry each value.
##
## `Section = Create,"0,0,0,0","0"` has one field after the rect that
## nothing has ever read. `resinfo\base.txt` holds five window recipes
## named Type1..Type5 -- a frame plus a background tile inset inside it,
## optionally with black-square panels -- and a window has to select one
## somehow. This is the only candidate in the file.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_section_headers.gd -- \
##     --pk2=/path/to/Media.pk2

const RESINFO_DIR := "resinfo"

func _init() -> void:
	var pk2_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2="):
			pk2_path = a.substr(6)
	if pk2_path == "":
		printerr("usage: --pk2=<Media.pk2>")
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

	var counts := {}
	var examples := {}
	for entry in archive.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".txt"):
			continue
		var layout := UiLayoutParser.parse(archive.read_file(entry))
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			counts[sec.base_type] = int(counts.get(sec.base_type, 0)) + 1
			if not examples.has(sec.base_type):
				examples[sec.base_type] = "%s %s" % [entry.name, key]
	var keys := counts.keys()
	keys.sort()
	for k in keys:
		print("trailing field %3d : %4d section(s)   e.g. %s" % [k, int(counts[k]), str(examples[k])])
	quit(0)
