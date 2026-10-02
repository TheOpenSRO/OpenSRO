extends SceneTree

## Dev tool (round 683 review): how a worn piece's vertices sit against the
## body's own, at bind. For each body piece and each armour mesh: how many
## armour vertices coincide with a body vertex (within --eps), and how far the
## rest are. Run headless:
##   remote_godot.sh script res://tools/probe_body_armour.gd -- --pk2=$PK2/Data.pk2 \
##     --body='res\char\china\chinawoman_adventurer.bsr' --items='item\china\woman_item\heavy_01_ba.bsr,...'

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	return SkinnedBsrAssembler._read(archive, path.replace("/", "\\"))

func _meshes(archive: Pk2Reader, bsr_path: String) -> Dictionary:
	var out := {}
	var parsed := BsrReader.parse(_read(archive, bsr_path))
	if parsed == null:
		return out
	for p in parsed.all_mesh_paths():
		var m := BmsReader.parse(_read(archive, p))
		if m != null:
			out[p.get_file()] = m
	return out

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var eps := float(_arg("--eps", "0.01"))
	var body := _meshes(data, _arg("--body"))
	for item in _arg("--items").split(",", false):
		var worn := _meshes(data, item)
		for wn in worn:
			var w: BmsReader.ParsedMesh = worn[wn]
			var wp := w.positions()
			print("%s: %d vertices, palette %s" % [wn, wp.size(), str(w.bone_names)])
			for bn in body:
				var b: BmsReader.ParsedMesh = body[bn]
				var bp := b.positions()
				var same := 0
				for p in wp:
					for q in bp:
						if p.distance_to(q) <= eps:
							same += 1
							break
				var bsame := 0
				for q in bp:
					for p in wp:
						if p.distance_to(q) <= eps:
							bsame += 1
							break
				if same > 0:
					print("   vs %-34s %4d/%d of its vertices on the body's, %4d/%d of the body's on its" % [bn, same, wp.size(), bsame, bp.size()])
	quit(0)
