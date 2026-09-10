extends SceneTree

## Dev tool: lists one directory inside a real pk2 archive, with each
## entry's size.
##
## Answers "what pieces does this actually ship?", which several findings
## have turned on: `interface\ifcommon\lattice_window\` holds four
## `com_lattice_*` cell pieces and six `com_lattice_outline_*` border pieces
## and nothing else, which is what showed an item grid's cell is one piece
## of art rather than a corner of a frame. The same listing showed
## `com_blacksquare_` is six pieces, not eight, and that
## `interface\ifcommon\` carries a real close button.
##
## Usage:
##   godot4 --headless --path client --script res://tools/list_archive_dir.gd -- \
##     --pk2=/path/to/Media.pk2 --dir="interface\\ifcommon\\bg_tile"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var dir_path := _arg("--dir")
	if pk2_path == "" or dir_path == "":
		printerr("usage: --pk2=<archive> --dir=<path in archive>")
		quit(2)
		return

	# Archive paths use backslashes, which do not survive being passed
	# through ssh and su to the render box -- each layer eats one. Forward
	# slashes are accepted so the caller need not count them.
	dir_path = dir_path.replace("/", "\\")

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var entry := ObjectLoader.find_file(archive, dir_path)
	if entry == null:
		print("MISSING ", dir_path)
		quit(1)
		return

	var files := 0
	var dirs := 0
	for child in archive.read_dir_at(entry):
		if child.is_dir:
			dirs += 1
			print("%s/" % child.name)
			continue
		files += 1
		print("%-48s %d" % [child.name, archive.read_file(child).size()])
	print("--- %d file(s), %d subdirector(ies)" % [files, dirs])
	quit(0)
