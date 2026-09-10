extends SceneTree

## Dev tool: prints the pixel size and compression of named `.ddj` textures.
##
## Cheap, and it settles questions that otherwise get guessed. The world
## map window's frame insets come from here -- `mframe_wnd_left_up` is
## 40x68 and `mframe_wnd_left_down` is 40x48, so the frame is 40 down the
## sides, 68 across the top and 48 across the bottom, and the interior
## follows without a single number being chosen by eye.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_ddj_sizes.gd -- \
##     --pk2=/path/to/Media.pk2 --files=interface/frame/mframe_wnd_left_up.ddj,...
##
## Paths may use forward slashes: backslashes do not survive being passed
## through ssh and su to the render box.

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var files := _arg("--files")
	if pk2_path == "" or files == "":
		printerr("usage: --pk2=<archive> --files=<comma separated paths>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	for name in files.split(","):
		var path := name.strip_edges().replace("/", "\\")
		if path == "":
			continue
		var entry := ObjectLoader.find_file(archive, path)
		if entry == null:
			print("%-56s MISSING" % path)
			continue
		var tex := DdjReader.parse(archive.read_file(entry))
		if tex == null:
			print("%-56s unreadable" % path)
			continue
		print("%-56s %4d x %4d  %s" % [path, tex.width, tex.height,
			tex.four_cc if tex.four_cc != "" else "%d-bit" % tex.rgb_bit_count])
	quit(0)
