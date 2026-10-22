extends SceneTree

## Dev tool (round 809): the material section of each `.bsr` in a list --
## per entry its leading word (the material slot, READ: ResObject::
## FUN_00be41d0 files the path at slot `word`) and its `.bmt` path, one line a
## file, tab-separated: `path<TAB>count<TAB>word=bmt|word=bmt...`, or
## `path<TAB>MISSING`.
##
##   godot4 --headless --path client --script res://tools/census_bsr_materials.gd -- \
##     --pk2=/path/Data.pk2 --list=<file of .bsr paths, one a line>

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	var f := FileAccess.open(_arg("--list"), FileAccess.READ)
	if archive == null or f == null:
		printerr("usage: --pk2=<Data.pk2> --list=<file>")
		quit(2)
		return
	while not f.eof_reached():
		var path := f.get_line().strip_edges()
		if path == "":
			continue
		var data := SkinnedBsrAssembler._read(archive, path)
		if data.size() < 0x48:
			print("MTRL\t%s\tMISSING" % path)
			continue
		var off := data.decode_u32(0x0C)
		if off + 4 > data.size():
			print("MTRL\t%s\tBADPTR" % path)
			continue
		var n := data.decode_u32(off)
		off += 4
		var parts: PackedStringArray = []
		for i in mini(n, 64):
			if off + 8 > data.size():
				break
			var word := data.decode_u32(off)
			var ln := data.decode_u32(off + 4)
			if ln > 512 or off + 8 + ln > data.size():
				break
			parts.append("%d=%s" % [word, data.slice(off + 8, off + 8 + ln).get_string_from_ascii()])
			off += 8 + ln
		print("MTRL\t%s\t%d\t%s" % [path, n, "|".join(parts)])
	quit(0)
