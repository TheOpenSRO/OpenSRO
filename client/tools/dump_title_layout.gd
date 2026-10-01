extends SceneTree

## Prints Media.pk2 resinfo\pstitle.txt's Title and Login sections as the
## front-end frame reads them (round 678): each control's ID, rect, art,
## text key and font index. Reads the player's own archive; writes nothing.
##
##   remote_godot.sh script res://tools/dump_title_layout.gd -- --media=/path/Media.pk2

func _initialize() -> void:
	var media_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--media="):
			media_path = a.substr(8)
	var media := Pk2Reader.open(media_path)
	if media == null:
		print("cannot open %s" % media_path)
		quit(1)
		return
	var layout := FrontEndFrame.load_layout(media)
	for sec in ["Title", "Login"]:
		var s: UiLayoutParser.SectionDef = layout.sections.get(sec)
		if s == null:
			print("no section %s" % sec)
			continue
		for c in s.controls:
			print("%s id %d %s rect %s ddj '%s' text '%s' font %d color %s" % [sec, c.id, c.name, str(c.rect), c.ddj, c.text, c.font_index, str(c.font_color)])
	quit()
