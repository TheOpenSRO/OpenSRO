extends SceneTree

## Dev tool (round 809): what a character `.bsr` is made of -- the material
## list with each entry's leading word, the mesh groups, and per mesh piece
## its material name, vertex count, skinning, bones and bounding box.
##
##   godot4 --headless --path client --script res://tools/probe_monster_parts.gd -- \
##     --pk2=/path/Data.pk2 --list=<file of .bsr paths, one a line>

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _u32(d: PackedByteArray, o: int) -> int:
	return d.decode_u32(o)

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("no archive")
		quit(1)
		return
	var f := FileAccess.open(_arg("--list"), FileAccess.READ)
	while f != null and not f.eof_reached():
		var path := f.get_line().strip_edges()
		if path != "":
			_probe(archive, path)
	quit(0)

func _probe(archive: Pk2Reader, path: String) -> void:
	var data := SkinnedBsrAssembler._read(archive, path)
	if data.is_empty():
		print("PARTS %s: not found" % path)
		return
	print("PARTS %s (%d bytes, type %d)" % [path, data.size(), _u32(data, 0x40) & 0xffff])
	var off := _u32(data, 0x0C)
	var n := _u32(data, off)
	off += 4
	for i in n:
		var word := _u32(data, off)
		var ln := _u32(data, off + 4)
		var s := data.slice(off + 8, off + 8 + ln).get_string_from_ascii()
		print("  material %d word %d %s" % [i, word, s])
		off += 8 + ln
	var parsed := BsrReader.parse(data)
	if parsed == null:
		print("  does not parse")
		return
	print("  mesh groups %s" % str(parsed.mesh_groups))
	print("  header flags 0x%x word30 %d" % [parsed.header_flags, _u32(data, 0x30)])
	var paths := parsed.all_mesh_paths()
	for i in paths.size():
		var bms := SkinnedBsrAssembler._read(archive, paths[i])
		var m := BmsReader.parse(bms) if not bms.is_empty() else null
		if m == null:
			print("  mesh %d %s: missing" % [i, paths[i]])
			continue
		var lo := Vector3.INF
		var hi := -Vector3.INF
		for v in m.vertices:
			lo = lo.min(v.position)
			hi = hi.max(v.position)
		print("  mesh %d %s: name '%s' material '%s' %d verts skinned %s bones %s box %s..%s" % [
			i, paths[i].get_file(), m.mesh_name, m.material_name, m.vertices.size(), m.is_skinned(),
			str(m.bone_names), str(lo), str(hi)])

	if _arg("--anims") != "":
		for g in parsed.animation_groups:
			for e in parsed.animation_groups[g]:
				var ent := e as BsrReader.AnimationEntry
				if ent == null or ent.path == "":
					continue
				var ban := SkinnedBsrAssembler._read(archive, ent.path)
				var a := BanReader.parse(ban) if not ban.is_empty() else null
				print("  anim group '%s' type %d %s: %s ms, cyclic %s, events %s" % [g, ent.action_type,
					ent.path.get_file(), str(a.duration_ms) if a != null else "?", str(a.cyclic) if a != null else "?",
					str(ent.events)])

	# Round 809: --saddle=1 prints the `saddle` bone's rest height (the
	# rider's seat, World3D._cos_seat_height).
	if _arg("--saddle") != "":
		var bsk := SkinnedBsrAssembler._read(archive, parsed.skeleton_path)
		var ps := BskReader.parse(bsk) if not bsk.is_empty() else null
		var skel := Skeleton3DBuilder.build_skeleton3d(ps) if ps != null else null
		if skel == null:
			print("  saddle: no skeleton")
			return
		var b := skel.find_bone("saddle")
		print("  saddle: %s" % (str(skel.get_bone_global_rest(b).origin) if b >= 0 else "none"))
		skel.free()
