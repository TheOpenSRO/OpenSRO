extends SceneTree

## Dev tool: for every window layout that declares a frame at the origin,
## compares the frame's rect against how far the rest of the section
## reaches -- counted two ways, over controls that carry artwork and over
## every control.
##
## The question is what a window's size actually is. The frame alone is too
## small: ifinventory's gold row (`GDR_INVENTORY_STA_MONEY`, `0,305,176,28`,
## carrying `int_window_downbox.ddj`) hangs below the frame's bottom edge
## and belongs to the window. But the bounding box of everything is too
## large: ifplayerinfo's `GDR_PI_TEXT_HP_DAT` is a 228-wide text field
## starting at x=153 in a 364-wide window, so it overruns the right edge by
## 17 pixels and would widen the window for nothing.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_window_size.gd -- \
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

	var framed_windows := 0
	var art_fits := 0
	var all_fits := 0

	for entry in archive.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".txt"):
			continue
		var layout := UiLayoutParser.parse(archive.read_file(entry))
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			var frame := Vector2.ZERO
			for c in sec.controls:
				if c.rect.position == Vector2i.ZERO and c.rect.size.x > frame.x:
					frame = Vector2(c.rect.size)
			if frame == Vector2.ZERO:
				continue
			framed_windows += 1
			var art := Vector2.ZERO
			var all := Vector2.ZERO
			for c in sec.controls:
				var far := Vector2(c.rect.position + c.rect.size)
				all = Vector2(maxf(all.x, far.x), maxf(all.y, far.y))
				if c.ddj != "":
					art = Vector2(maxf(art.x, far.x), maxf(art.y, far.y))
			if art.x <= frame.x and art.y <= frame.y:
				art_fits += 1
			if all.x <= frame.x and all.y <= frame.y:
				all_fits += 1
			if art.x > frame.x or art.y > frame.y or all.x > frame.x or all.y > frame.y:
				print("%-28s %-18s frame=%s art=%s all=%s" % [
					entry.name, key, str(frame), str(art), str(all)])

	print("--- %d framed sections; artwork fits inside the frame in %d, everything fits in %d" % [
		framed_windows, art_fits, all_fits])
	quit(0)
