extends SceneTree

## Dev probe for the player-block portrait (round 635): measures, from the
## player's own archives, the facts PlayerPortrait depends on --
##   * each body's ANI_POSE (action type 60) entry per animation group, the
##     clip retail's portrait poses the avatar with (FUN_007b7740 plays 0x3c);
##   * the `Bip01 Head` bone's rest position (the camera's anchor);
##   * the body material's layer colours (ambient / diffuse), which the
##     lighting multiplies;
##   * interface\playerminiinfo\pmi_face.ddj's size, format and alpha -- the
##     mask CIFStaticWithPictureClip draws the render through.
##
## Usage:
##   godot4 --headless --path client --script res://tools/probe_portrait.gd -- \
##     --data=/path/Data.pk2 --media=/path/Media.pk2 [--codes=CHAR_CH_MAN_FIGHTER,...]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var data := Pk2Reader.open(_arg("--data"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("need --data= and --media=")
		quit(2)
		return
	var codes := _arg("--codes")
	if codes == "":
		codes = "CHAR_CH_MAN_FIGHTER,CHAR_CH_WOMAN_FIGHTER,CHAR_EU_MAN_WARRIOR,CHAR_EU_WOMAN_WARRIOR"
	var bodies := {}
	for path in NpcTableReader.model_table_paths(media):
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			bodies = NpcTableReader.parse_models_by_code(media.read_file(entry), bodies)
	for code in codes.split(","):
		var bsr_path: String = bodies.get(code, "")
		print("== %s -> %s" % [code, bsr_path])
		if bsr_path == "":
			print("  known EU/CH player codes: %s" % str(bodies.keys().filter(func(k): return String(k).begins_with("CHAR_EU") or String(k).begins_with("CHAR_CH"))))
			continue
		var bytes := AssetSource.read_bytes(bsr_path, data)
		if bytes.is_empty():
			bytes = AssetSource.read_bytes("res\\" + bsr_path, data)
		var parsed := BsrReader.parse(bytes)
		if parsed == null:
			print("  unparsed")
			continue
		for g in parsed.animation_groups:
			for e in parsed.animation_groups[g]:
				if int((e as BsrReader.AnimationEntry).action_type) == 60:
					print("  ANI_POSE group=%s path=%s" % [g, (e as BsrReader.AnimationEntry).path])
		var sk_bytes := AssetSource.read_bytes(parsed.skeleton_path, data)
		var sk := BskReader.parse(sk_bytes) if not sk_bytes.is_empty() else null
		if sk != null:
			var skel := Skeleton3DBuilder.build_skeleton3d(sk)
			var head := skel.find_bone("Bip01 Head")
			if head >= 0:
				print("  Bip01 Head rest origin %s" % str(skel.get_bone_global_rest(head).origin))
			var foot := Vector3.INF
			var top := -Vector3.INF
			for i in range(skel.get_bone_count()):
				var o := skel.get_bone_global_rest(i).origin
				foot = Vector3(minf(foot.x, o.x), minf(foot.y, o.y), minf(foot.z, o.z))
				top = Vector3(maxf(top.x, o.x), maxf(top.y, o.y), maxf(top.z, o.z))
			print("  bone bounds %s .. %s" % [str(foot), str(top)])
			skel.free()
		if parsed.material_path != "":
			var mat := ObjectLoader.load_material(data, parsed.material_path)
			if mat != null:
				for l in mat.layers:
					print("  layer %s amb=%s dif=%s spec=%s emi=%s flags=0x%x tex=%s" % [
						l.layer_name, str(l.ambient), str(l.diffuse), str(l.specular), str(l.emissive), l.unknown, l.texture_path])
	var face_bytes := AssetSource.read_bytes("interface\\playerminiinfo\\pmi_face.ddj", media)
	if face_bytes.is_empty():
		face_bytes = AssetSource.read_bytes("interface\\playerminiinfo\\pmi_face.ddj", data)
	var face := DdjReader.parse(face_bytes) if not face_bytes.is_empty() else null
	if face == null:
		print("pmi_face.ddj: not found")
	else:
		var img := DdjReader.to_image(face)
		print("pmi_face.ddj: %dx%d four_cc=%s bits=%d a_mask=0x%x" % [face.width, face.height, face.four_cc, face.rgb_bit_count, face.a_mask])
		var hist := {}
		var rows: Array = []
		for y in range(img.get_height()):
			var row := ""
			for x in range(img.get_width()):
				var c := img.get_pixel(x, y)
				var a := int(round(c.a * 255.0))
				hist[a] = int(hist.get(a, 0)) + 1
				row += "#" if a >= 128 else ("+" if a > 0 else ".")
			rows.append(row)
		print("  alpha histogram %s" % str(hist))
		var cols := {}
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var c := img.get_pixel(x, y)
				var key := "%d,%d,%d" % [int(round(c.r * 255)), int(round(c.g * 255)), int(round(c.b * 255))]
				cols[key] = int(cols.get(key, 0)) + 1
		print("  colours %s" % str(cols))
		for r in rows:
			print("  " + r)
	quit(0)
