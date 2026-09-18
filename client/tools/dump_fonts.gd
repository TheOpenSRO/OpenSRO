extends SceneTree

## Dev tool: what the client's UI font actually is, read from the player's own
## Media.pk2 -- so the face the interface renders with is the archive's word,
## not a guess.
##
## The client picks its UI typeface by NAME: `Game.cpp` extracts every file
## under `fonts\` and registers it with AddFontResourceA, then the font table
## builder (FUN_00469350) creates each FontIndex with the face named by the UI
## text key `UIC_STT_FONTNAME` (falling back to "굴림체"/GulimChe when that is
## empty). So the face is a text-table entry and the candidates are the .ttf
## files' own family names. This prints both, plus vplus\vfont.ttf.
##
##   godot4 --headless --path client --script res://tools/dump_fonts.gd -- \
##     --media=/opt/sro-files/client/Media.pk2

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _describe(label: String, data: PackedByteArray) -> void:
	var font := FontFile.new()
	font.data = data
	if font.get_face_count() == 0:
		print("  %-28s %8d bytes  (not a usable font)" % [label, data.size()])
		return
	print("  %-28s %8d bytes  family='%s' style='%s' faces=%d weight=%d" % [
		label, data.size(), font.get_font_name(), font.get_font_style_name(),
		font.get_face_count(), font.get_font_weight()])

func _initialize() -> void:
	var media_path := _arg("--media")
	if media_path == "":
		printerr("usage: --media=<Media.pk2>")
		quit(2)
		return
	var media := Pk2Reader.open(media_path)
	if media == null:
		printerr("could not open ", media_path)
		quit(1)
		return

	var text_entry := ObjectLoader.find_file(media, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	if text_entry != null:
		var table := UiTextTable.parse(media.read_file(text_entry))
		print("UIC_STT_FONTNAME (English column pick) = '%s'" % table.get_text("UIC_STT_FONTNAME", "<missing>"))
		# Every language column of that row, raw, so the per-locale faces show.
		var raw := media.read_file(text_entry).get_string_from_utf16()
		for line in raw.split("\n"):
			if line.contains("UIC_STT_FONTNAME"):
				var cols := line.strip_edges().split("\t")
				print("  row has %d columns: %s" % [cols.size(), str(cols)])
	else:
		print("textuisystem.txt not found")

	var dir_entry := ObjectLoader.find_file(media, "fonts")
	if dir_entry == null or not dir_entry.is_dir:
		print("no fonts\\ directory")
	else:
		print("fonts\\ directory:")
		for entry in media.read_dir_at(dir_entry):
			if entry.is_dir:
				continue
			var name_hex := entry.name.to_utf8_buffer().hex_encode()
			var lower: String = entry.name.to_lower()
			if lower.ends_with(".ttf") or lower.ends_with(".ttc") or lower.ends_with(".otf"):
				_describe(entry.name, media.read_file(entry))
			else:
				print("  %-28s (not a font file)" % entry.name)
			print("      name bytes: %s" % name_hex)

	var vfont := ObjectLoader.find_file(media, "vplus\\vfont.ttf")
	if vfont != null:
		print("vplus\\vfont.ttf:")
		_describe("vplus\\vfont.ttf", media.read_file(vfont))
	else:
		print("vplus\\vfont.ttf not found")
	quit(0)
