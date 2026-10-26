extends SceneTree

## Box tool (round 832): prints every record of one `res_ui\*.2dt` in a real
## Media.pk2 as TwoDtReader parses it. Nothing is written and no game data
## leaves the box.
##
##   client/tools/remote_godot.sh script '--script res://tools/dump_2dt.gd -- --file=targetmenu.2dt'

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _init() -> void:
	var archive := Pk2Reader.open(_arg("--pk2", "/opt/sro-files/client/Media.pk2"))
	if archive == null:
		printerr("could not open the archive")
		quit(1)
		return
	var path := "res_ui\\" + _arg("--file", "targetmenu.2dt")
	var entry = ObjectLoader.find_file(archive, path)
	if entry == null:
		printerr("no ", path)
		quit(1)
		return
	var file := TwoDtReader.parse(archive.read_file(entry))
	if file == null:
		printerr("did not parse")
		quit(1)
		return
	for r in file.records:
		print("%d id=%d type=%d parent=%d gp=%d root=%s rect=%s name=%s base=%s tex=%s text=%s color=%08x font=%d halign=%d valign=%d style=%s" % [
			r.index, r.id, r.type, r.parent_id, r.grandparent_id, str(r.is_root), str(r.rect), r.name, r.base,
			r.texture, r.text_id, r.color, r.font_index, r.halign, r.valign, r.style_bytes.hex_encode()])
	quit(0)
