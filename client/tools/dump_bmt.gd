extends SceneTree

## Dev tool: prints a real .bmt material's layers -- name, texture, colours,
## and the still-unconfirmed per-layer `unknown` word -- so the meaning of
## that word can be worked out by comparing it across real materials whose
## behaviour is known from the outside.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_bmt.gd -- \
##     --pk2=/path/to/Data.pk2 --file="prim\\mtrl\\...\\thing.bmt"
##
## --file may be repeated by passing a comma-separated list.

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var files := _arg("--file")
	if pk2_path == "" or files == "":
		printerr("usage: --pk2=<archive> --file=<path[,path...]>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	for path in files.split(","):
		var bytes := AssetSource.read_bytes(path.strip_edges(), archive)
		if bytes.is_empty():
			print("%s: NOT FOUND" % path)
			continue
		var material := BmtReader.parse(bytes)
		if material == null:
			print("%s: could not parse" % path)
			continue
		print("%s: %d layer(s)" % [path.get_file(), material.layers.size()])
		for layer in material.layers:
			print("   unknown=0x%04x (%6d)  power=%.2f  %-28s %s" % [
				layer.unknown, layer.unknown, layer.power,
				layer.layer_name, layer.texture_path])
			# The colours matter as much as the texture: the loader multiplies
			# the texture by the diffuse, so a dark diffuse is a dark wall.
			print("      ambient %s  diffuse %s  specular %s  emissive %s" % [
				_rgba(layer.ambient), _rgba(layer.diffuse), _rgba(layer.specular), _rgba(layer.emissive)])
	quit(0)

func _rgba(c: Color) -> String:
	return "(%.2f, %.2f, %.2f, %.2f)" % [c.r, c.g, c.b, c.a]
