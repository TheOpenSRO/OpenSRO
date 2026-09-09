extends SceneTree

## Dev tool: counts every control type across every `resinfo\` layout, and
## says for each how many of its instances name artwork -- and how many of
## those name an **8-slice base**, a path ending in an underscore that
## expands into corner and edge pieces rather than being a texture in its
## own right.
##
## That last column is the one that matters. A control whose `ddj` ends in
## `_` draws a framed panel whatever its type is called, and `UiBuilder`
## used to build anything it did not recognise as an empty Control -- so a
## window whose body is one big compound control came out see-through.
## ifskill's `GDR_SKILL_BOARD` is a `CIFSkillBoard` carrying
## `interface\\inventory\\int_window_` over 351x270 of a 364x333 window.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_control_types.gd -- \
##     --pk2=/path/to/Media.pk2 [--min=1]

const RESINFO_DIR := "resinfo"

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var minimum := int(_arg("--min", "1"))
	if pk2_path == "":
		printerr("usage: --pk2=<Media.pk2> [--min=n]")
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

	var total := {}      # type -> instances
	var with_art := {}   # type -> instances naming a ddj
	var sliced := {}     # type -> instances naming an 8-slice base
	var example := {}    # type -> "file GDR_NAME ddj"

	for entry in archive.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".txt"):
			continue
		var layout := UiLayoutParser.parse(archive.read_file(entry))
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			for c in sec.controls:
				total[c.type] = int(total.get(c.type, 0)) + 1
				if c.ddj == "":
					continue
				with_art[c.type] = int(with_art.get(c.type, 0)) + 1
				if c.ddj.ends_with("_"):
					sliced[c.type] = int(sliced.get(c.type, 0)) + 1
					if not example.has(c.type):
						example[c.type] = "%s %s %s" % [entry.name, c.name, c.ddj]

	var types := total.keys()
	types.sort_custom(func(a, b): return int(total[a]) > int(total[b]))
	print("%-32s %8s %8s %8s  %s" % ["type", "total", "with art", "8-slice", "first 8-slice instance"])
	for t in types:
		if int(total[t]) < minimum:
			continue
		print("%-32s %8d %8d %8d  %s" % [
			t, int(total[t]), int(with_art.get(t, 0)), int(sliced.get(t, 0)),
			str(example.get(t, ""))])

	var sliced_total := 0
	for t in sliced:
		sliced_total += int(sliced[t])
	print("--- %d control types; %d instances name an 8-slice base" % [types.size(), sliced_total])
	quit(0)
