extends SceneTree

## Dev tool: prints one `resinfo\if*.txt` window layout as the client parses
## it -- every control in declaration order with its rect, artwork and atlas
## sub-rect -- so a window's structure can be read out of the authored data
## instead of inferred from how it renders.
##
## Declaration order is the point: a section lists its controls **front to
## back**, so the last entry is the backmost. Printing them in order is what
## shows which control is meant to be the window's own frame.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_layout.gd -- \
##     --pk2=/path/to/Media.pk2 --file=ifplayerinfo [--file=ifinventory]

func _args(flag: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

func _init() -> void:
	var pk2 := _args("--pk2")
	var files := _args("--file")
	if pk2.is_empty() or files.is_empty():
		printerr("usage: --pk2=<Media.pk2> --file=<resinfo name, no path or extension>")
		quit(2)
		return

	var archive := Pk2Reader.open(pk2[0])
	if archive == null:
		printerr("could not open ", pk2[0])
		quit(1)
		return

	for name in files:
		var path := "resinfo\\" + name + ".txt"
		var bytes := AssetSource.read_bytes(path, archive)
		if bytes.is_empty():
			print("MISSING ", path)
			continue
		var layout := UiLayoutParser.parse(bytes)
		print("=== %s  sections=%d" % [path, layout.sections.size()])
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			print("--- section %s rect=%s controls=%d" % [key, str(sec.rect), sec.controls.size()])
			var i := 0
			for c in sec.controls:
				print("  [%2d] %-30s %-18s rect=%-26s h=%d v=%d f=%d ddj=%s uv=%s..%s text=%s" % [
					i, c.name, c.type, str(c.rect), c.halign, c.valign, c.font_index, c.ddj,
					str(c.uv_lt), str(c.uv_rb), c.text])
				i += 1
	quit(0)
