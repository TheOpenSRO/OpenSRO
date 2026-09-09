extends SceneTree

## Dev tool: lists every frame control in the archive that carries a `Text`,
## which is the window's own caption.
##
## `HudWindow` takes its title from the caller -- "Inventory", "Quest list"
## -- because most layouts do not carry one. Some do: ifquest's
## `GDR_QUEST_FRAME` is a `CIFSubFrame` with `Text=UIIT_STT_QUEST_LIST`, and
## a string the client itself would show beats a string this project chose.
## This says how many there are and which windows they cover, so the caption
## can come from the layout wherever the layout has one.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_frame_captions.gd -- \
##     --pk2=/path/to/Media.pk2

const RESINFO_DIR := "resinfo"
const FRAME_TYPES := ["CIFFrame", "CIFSubFrame", "CIFStretchWnd"]

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

	var with_text := 0
	var without := 0
	for entry in archive.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".txt"):
			continue
		var layout := UiLayoutParser.parse(archive.read_file(entry))
		for key in layout.sections:
			var sec: UiLayoutParser.SectionDef = layout.sections[key]
			for c in sec.controls:
				if not (c.type in FRAME_TYPES):
					continue
				# The window's own frame is the one at the origin.
				if c.rect.position != Vector2i.ZERO:
					continue
				if c.text == "":
					without += 1
					continue
				with_text += 1
				print("%-30s %-30s %-18s %s" % [entry.name, c.name, c.type, c.text])
	print("--- %d frames at the origin carry a caption; %d do not" % [with_text, without])
	quit(0)
