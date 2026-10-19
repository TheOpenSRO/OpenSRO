extends SceneTree

## Round 794 (QA): a .bms's cloth sections as BmsReader reads them, GDScript
## and native. `remote_godot.sh script res://tools/cloth_probe.gd -- --pk2=<Data.pk2> --mesh=<path>`.

func _arg(k: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(k + "="):
			return a.substr(k.length() + 1)
	return ""

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	if data == null:
		print("CLOTH PROBE: no archive")
		quit(1)
		return
	for path in _arg("--mesh").split(",", false):
		var e = ObjectLoader.find_file(data, path)
		if e == null:
			print("CLOTH PROBE %s: not found" % path)
			continue
		var bytes := data.read_file(e)
		var m := BmsReader.parse(bytes)
		print("CLOTH PROBE %s: verts %d motion %d links %d order %d params %s cloth %s native %s skinned %s" % [path,
			m.vertices.size(), m.vertex_motion.size(), m.vertex_links.size() / 2, m.vertex_link_order.size(), m.cloth_params, m.is_cloth(),
			not m._native.is_empty(), m.is_skinned()])
		var am := BmsReader.to_array_mesh(m, true)
		print("CLOTH PROBE   tagged %s" % am.has_meta(BmsReader.CLOTH_META))
	quit(0)
