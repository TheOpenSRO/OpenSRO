extends SceneTree

## Dev tool (round 706 review): what a .bsr's mod section asks of its
## materials -- the env-map flags that govern the whole object (BsrReader.
## env_map_flags), the per-material env-map / bump-env flag words, and every
## material-state mod with its kind, set, header words and state.
##
##   godot4 --headless --path client --script res://tools/probe_bsr_mods.gd -- \
##     --pk2=/path/Data.pk2 --file="res\\bldg\\china\\jangan01\\cj_jang_gate_dragon.bsr"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("could not open the archive")
		quit(1)
		return
	for path in _arg("--file").split(",", false):
		var entry := ObjectLoader.find_file(archive, path)
		if entry == null:
			print("%s: NOT FOUND" % path)
			continue
		var data := archive.read_file(entry)
		var obj := BsrReader.parse(data)
		if obj == null:
			print("%s: does not parse" % path)
			continue
		print("%s: %d bytes, env_map_flags %d, env_map_materials %s, %d material mod(s)" % [
			path, data.size(), obj.env_map_flags, str(obj.env_map_materials), obj.material_mods.size()])
		for m in obj.material_mods:
			print("  mod %s" % str(m))
		var sections = BsrReader.parse_sections(data)
		print("  sections: %s" % str(sections))
	quit(0)
