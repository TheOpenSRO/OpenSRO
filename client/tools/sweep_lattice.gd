extends SceneTree

## Dev tool: finds every `CIFLattice` declared anywhere in `resinfo\` and
## reports its authored rect against the size of the artwork it names.
##
## The question this settles is the cell pitch of an item grid. The layout
## gives a lattice a pixel rect and nothing else -- no row or column count --
## so the grid has to come from the art. `com_lattice_` is four 36x36 pieces
## (`left_up`, `right_up`, `left_down`, `right_down`, loaded together by one
## function in the client), and a cell is one piece. If that is right, every
## authored lattice rect divides by the piece size exactly, in both axes,
## across every window in the archive.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_lattice.gd -- \
##     --pk2=/path/to/Media.pk2

const RESINFO_DIR := "resinfo"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
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

	# Piece size, read from the art rather than assumed.
	var piece_sizes := {}
	var found := 0
	var exact_36 := 0
	var exact_32 := 0

	for entry in archive.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".txt"):
			continue
		var layout := UiLayoutParser.parse(archive.read_file(entry))
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			for c in sec.controls:
				if c.type != "CIFLattice":
					continue
				found += 1
				var piece := Vector2.ZERO
				if c.ddj != "":
					if not piece_sizes.has(c.ddj):
						piece_sizes[c.ddj] = _piece(archive, c.ddj + "left_up.ddj")
					piece = piece_sizes[c.ddj]
				var note := ""
				if piece.x > 0 and piece.y > 0:
					var fits_x: bool = int(c.rect.size.x) % int(piece.x) == 0
					var fits_y: bool = int(c.rect.size.y) % int(piece.y) == 0
					if fits_x and fits_y:
						exact_36 += 1
						note = "= %dx%d cells" % [c.rect.size.x / int(piece.x), c.rect.size.y / int(piece.y)]
					else:
						note = "REMAINDER %dx%d" % [
							int(c.rect.size.x) % int(piece.x), int(c.rect.size.y) % int(piece.y)]
				if int(c.rect.size.x) % 32 == 0 and int(c.rect.size.y) % 32 == 0:
					exact_32 += 1
				print("%-24s %-28s rect=%dx%d piece=%s  %s" % [
					entry.name, c.name, c.rect.size.x, c.rect.size.y, str(piece), note])

	print("--- %d lattices; %d divide exactly by their own piece size; %d divide by 32" % [
		found, exact_36, exact_32])
	quit(0)

func _piece(archive: Pk2Reader, path: String) -> Vector2:
	var e := ObjectLoader.find_file(archive, path)
	if e == null:
		return Vector2.ZERO
	var parsed := DdjReader.parse(archive.read_file(e))
	if parsed == null:
		return Vector2.ZERO
	var tex := DdjReader.to_texture(parsed)
	return tex.get_size() if tex != null else Vector2.ZERO
