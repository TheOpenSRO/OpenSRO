extends SceneTree

## Dev tool: copies one file out of a real pk2 archive to disk, so a
## format can be picked apart offline -- in a scripting language with a
## `struct` module, against several files at once -- rather than one
## Godot run per hypothesis.
##
## That is how the `.bsr` animation-group layout was settled: seven files
## pulled with this, one Python parse, and every one landing exactly on
## its sound-effect pointer. What comes out is game data and stays in a
## scratch directory; nothing extracted is ever committed (docs/LEGAL.md).
##
## Usage:
##   godot4 --headless --path client --script res://tools/extract_pk2_file.gd -- \
##     --pk2=/path/to/Data.pk2 --file=res/char/china/chinaman_fighter.bsr --out=/var/tmp/fighter.bsr
##
## Forward slashes are accepted in the archive path; backslashes do not
## survive ssh and su to the render box.

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""
func _init() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	var path := _arg("--file").replace("/", "\\")
	var e := ObjectLoader.find_file(archive, path)
	if e == null:
		printerr("not found: ", path); quit(1); return
	var f := FileAccess.open(_arg("--out"), FileAccess.WRITE)
	f.store_buffer(archive.read_file(e))
	f.close()
	print("wrote ", _arg("--out"))
	quit(0)
