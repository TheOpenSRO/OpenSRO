extends SceneTree

## Dev tool: reports the shape of every `*Slot` control that names no
## artwork of its own, grouped by type.
##
## The client draws a **list row** as a horizontal bar: one function sets
## `interface\ifcommon\com_bar01_` when the row is unselected and
## `com_bar01select_` when it is, and six classes do the same. That is what
## fills a list body -- ifpartymatch declares a `com_blacksquare_` border
## around its list and no fill behind it, because the rows are the fill.
##
## But not every slot is a row. `CIFSlotWithHelp` is an item square, 259 of
## them, and a horizontal bar would be wrong for all of them. The layouts
## separate the two by shape rather than by name, and this prints the
## evidence: an item slot is square, a row is wide and short.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_slot_shapes.gd -- \
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

	var by_type := {} # type -> [ [w, h], ... ]
	for entry in archive.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".txt"):
			continue
		var layout := UiLayoutParser.parse(archive.read_file(entry))
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			for c in sec.controls:
				if not c.type.contains("Slot") or c.ddj != "":
					continue
				if c.rect.size.x <= 0 or c.rect.size.y <= 0:
					continue
				if not by_type.has(c.type):
					by_type[c.type] = []
				by_type[c.type].append(Vector2i(c.rect.size))

	var types := by_type.keys()
	types.sort_custom(func(a, b): return by_type[a].size() > by_type[b].size())
	print("%-32s %6s %10s %12s  %s" % ["type", "count", "median w:h", "shape", "widths seen"])
	for t in types:
		var sizes: Array = by_type[t]
		var ratios: Array[float] = []
		var widths := {}
		for s in sizes:
			var v: Vector2i = s
			ratios.append(float(v.x) / float(v.y))
			widths[v.x] = true
		ratios.sort()
		var median: float = ratios[ratios.size() / 2]
		var shape := "row" if median >= ROW_ASPECT else "square"
		var width_list := widths.keys()
		width_list.sort()
		print("%-32s %6d %10.1f %12s  %s" % [
			t, sizes.size(), median, shape, str(width_list).substr(0, 40)])
	quit(0)

## Where a row stops being a square. Set from the printout: the two groups
## do not come close to each other.
const ROW_ASPECT := 3.0
