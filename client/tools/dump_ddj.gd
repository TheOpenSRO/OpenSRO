extends SceneTree

## Dev tool: pulls one real .ddj texture out of a real pk2 archive and
## writes it out as a PNG, so authored art can be looked at directly
## rather than inferred from how it renders.
##
## Built to settle which of two possible spellings of the minimap
## filename is the real one -- this project had `<x>x<y>.ddj` in one place
## and `<y>x<x>.ddj` in another, and both name files that exist.
##
## Usage (no display needed):
##   godot4 --headless --path client --script res://tools/dump_ddj.gd -- \
##     --pk2=/path/to/Media.pk2 --file="minimap\\97x168.ddj" --out=/var/tmp/mm.png

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var file_path := _arg("--file")
	var out_path := _arg("--out")
	if pk2_path == "" or file_path == "" or out_path == "":
		printerr("usage: --pk2=<archive> --file=<path in archive> --out=<png>")
		quit(2)
		return

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var bytes := AssetSource.read_bytes(file_path, archive)
	if bytes.is_empty():
		printerr("not found in archive: ", file_path)
		quit(1)
		return
	var parsed := DdjReader.parse(bytes)
	if parsed == null:
		printerr("could not decode ", file_path)
		quit(1)
		return
	var texture := DdjReader.to_texture(parsed)
	if texture == null:
		printerr("could not build an image from ", file_path)
		quit(1)
		return
	var image := texture.get_image()
	image.decompress()
	print("%s: %dx%d" % [file_path, image.get_width(), image.get_height()])
	if image.save_png(out_path) != OK:
		printerr("could not write ", out_path)
		quit(1)
		return
	print("wrote ", out_path)
	quit(0)
