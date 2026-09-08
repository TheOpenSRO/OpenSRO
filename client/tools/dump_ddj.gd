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
	var compressed_format := image.get_format()
	image.decompress()
	# What the alpha actually survives as matters more than the file's own
	# fourCC: a cutout texture whose alpha is dropped in decoding renders
	# its transparent texels as solid black.
	var opaque := 0
	var transparent := 0
	var partial := 0
	if image.get_format() == Image.FORMAT_RGBA8:
		var data := image.get_data()
		var i := 3
		while i < data.size():
			if data[i] >= 250:
				opaque += 1
			elif data[i] <= 5:
				transparent += 1
			else:
				partial += 1
			i += 4
	print("%s: %dx%d  fourCC=%s  stored=%d  decompressed=%d" % [
		file_path, image.get_width(), image.get_height(),
		parsed.four_cc if parsed.four_cc != "" else "(uncompressed)",
		compressed_format, image.get_format()])
	print("  alpha: %d opaque, %d fully transparent, %d partial%s" % [
		opaque, transparent, partial,
		"  (no alpha channel survived decoding)" if image.get_format() != Image.FORMAT_RGBA8 else ""])
	if image.save_png(out_path) != OK:
		printerr("could not write ", out_path)
		quit(1)
		return
	print("wrote ", out_path)
	quit(0)
