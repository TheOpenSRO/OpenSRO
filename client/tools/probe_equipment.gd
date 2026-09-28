extends SceneTree

## Dev tool: measures what dressing a body in real items actually draws --
## item by item, mesh by mesh -- so "the chest armour doesn't render" is a
## number rather than a picture (round 626).
##
## For every item row matched (by --ids, or --grep on the code name) it walks
## the same chain World3D does -- item table model column -> .bsr -> meshes
## (.bms) -> material (.bmt layer by the mesh's material_name) -> texture
## (.ddj) -- and prints what each link resolved to, then attaches the item to a
## freshly assembled body through SkinnedBsrAssembler.attach_item_from_archive
## (the exact call the world makes) and counts the MeshInstance3Ds and vertices
## it added, and whether their material is a cutout.
##
## Headless is fine -- it reads and assembles, renders nothing:
##   godot4 --headless --path client --script res://tools/probe_equipment.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 \
##     [--ids=25541,25542] [--grep=_ch_m_heavy_11_] [--body=CHAR_CH_MAN_FIGHTER]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--ids=a,b] [--grep=<code substr>] [--body=<code>]")
		quit(2)
		return
	var ids := {}
	for s in _arg("--ids").split(",", false):
		ids[int(s)] = true
	var needle := _arg("--grep").to_lower()
	var body := _arg("--body", "CHAR_CH_MAN_FIGHTER")

	var bodies := {}
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			bodies = NpcTableReader.parse_models_by_code(media.read_file(entry), bodies)
	var body_bsr: String = bodies.get(body, "")
	var items := {}
	for path in ItemTableReader.TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			ItemTableReader.parse(media.read_file(entry), items)

	var ordered := items.keys()
	ordered.sort()
	for id in ordered:
		var item = items[id]
		if item.model_path == "":
			continue
		if not ids.is_empty() and not ids.has(id):
			continue
		if ids.is_empty() and (needle == "" or not String(item.code_name).to_lower().contains(needle)):
			continue
		print("== item %d %s tids=%s models=%s" % [id, item.code_name, str(item.type_ids), str(item.model_paths)])
		# Every model the row lists: the first is the one worn, a second the
		# full-set model (ItemTableReader.Item.model_paths).
		for model in item.model_paths:
			_probe_model(data, body_bsr, model)
	quit(0)

func _probe_model(data: Pk2Reader, body_bsr: String, model: String) -> void:
	var bytes := SkinnedBsrAssembler._read(data, model)
	if bytes.is_empty():
		print("  bsr %s: NOT FOUND in archive" % model)
		return
	var sections = BsrReader.parse_sections(bytes)
	var parsed := BsrReader.parse(bytes)
	if parsed == null:
		print("  bsr %s: does not parse" % model)
		return
	print("  bsr %s: type %d item=%s skeleton='%s' attach='%s' envmap=%d" % [
		model, parsed.object_type, str(parsed.is_item()), parsed.skeleton_path, parsed.attach_bone, parsed.env_map_flags])
	if sections != null:
		print("    materials %s" % str(sections["materials"]))
		print("    mesh groups %s" % str(sections["mesh_groups"]))
	var material := ObjectLoader.load_material(data, parsed.material_path) if parsed.material_path != "" else null
	if material != null:
		for li in range(material.layers.size()):
			var l: BmtReader.Layer = material.layers[li]
			print("    layer %d '%s' flags 0x%04x tex '%s' amb %s dif %s%s" % [
				li, l.layer_name, l.unknown, l.texture_path, str(l.ambient), str(l.diffuse),
				_alpha_histogram(data, parsed.material_path, l.texture_path)])
	var paths := parsed.all_mesh_paths()
	for i in range(paths.size()):
		var mb := SkinnedBsrAssembler._read(data, paths[i])
		if mb.is_empty():
			print("    mesh %d %s: NOT FOUND" % [i, paths[i]])
			continue
		var mesh := BmsReader.parse(mb)
		if mesh == null:
			print("    mesh %d %s: DOES NOT PARSE" % [i, paths[i]])
			continue
		var layer_idx := -2
		if material != null and material.layers.size() > 0:
			layer_idx = ObjectLoader._find_layer_by_name(material.layers, mesh.material_name)
		print("    mesh %d %s: %d verts %d tris skinned=%s bones=%s mat='%s' -> layer %d bounds %s..%s" % [
			i, paths[i].get_file(), mesh.vertices.size(), mesh.indices.size() / 3, str(mesh.is_skinned()),
			str(mesh.bone_names), mesh.material_name, layer_idx, str(mesh.bounds_min), str(mesh.bounds_max)])
		if layer_idx >= 0:
			print("      surface alpha: %s" % _surface_alpha(data, parsed.material_path, material.layers[layer_idx].texture_path, mesh))
	if body_bsr == "":
		return
	var assembled := SkinnedBsrAssembler.assemble_from_archive(data, body_bsr, false)
	if assembled == null:
		print("    (body did not assemble)")
		return
	var att := SkinnedBsrAssembler.attach_item_from_archive(data, assembled.skeleton, model)
	if att == null:
		print("    ATTACH: null -- nothing drawn")
	else:
		var n := 0
		var verts := 0
		var stack: Array[Node] = [att.node]
		while not stack.is_empty():
			var cur: Node = stack.pop_back()
			if cur is MeshInstance3D:
				var mi := cur as MeshInstance3D
				n += 1
				var v := 0
				for s in range(mi.mesh.get_surface_count()):
					v += mi.mesh.surface_get_array_len(s)
				verts += v
				var mat := mi.material_override
				var kind := "none"
				if mat is ShaderMaterial:
					kind = "shader %s scissor %.4f" % [(mat as ShaderMaterial).shader.resource_path.get_file(),
						float((mat as ShaderMaterial).get_shader_parameter("alpha_scissor"))]
				elif mat is StandardMaterial3D:
					kind = "standard transparency=%d cull=%d tex=%s" % [
						(mat as StandardMaterial3D).transparency, (mat as StandardMaterial3D).cull_mode,
						str((mat as StandardMaterial3D).albedo_texture != null)]
				print("    DRAWN %s: %d verts skin=%s material %s" % [mi.name, v, str(mi.skin != null), kind])
			for c in cur.get_children():
				stack.append(c)
		print("    ATTACH: %d mesh instance(s), %d verts, skinned=%s bone='%s'" % [n, verts, str(att.skinned), att.attach_bone])
	assembled.skeleton.free()

## The texture's alpha, counted: its fourCC and the share of texels fully
## transparent (<= 5), graded (6..249) and opaque (>= 250) -- the same bands
## ObjectLoader's cutout tests use.
func _alpha_histogram(data: Pk2Reader, bmt_path: String, tex: String) -> String:
	if tex == "":
		return ""
	var path := tex
	if not (tex.contains("\\") or tex.contains("/")):
		path = bmt_path.replace("\\", "/").get_base_dir() + "/" + tex
	var entry := ObjectLoader.find_file(data, path)
	if entry == null:
		return " [texture not found]"
	var parsed_tex := DdjReader.parse(data.read_file(entry))
	if parsed_tex == null:
		return " [texture does not parse]"
	var image := DdjReader.to_image(parsed_tex)
	if image == null or image.is_empty():
		return " [texture does not decode]"
	image = image.duplicate() as Image
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	var bytes := image.get_data()
	var t := 0
	var g := 0
	var o := 0
	var below_ref := 0
	var i := 3
	while i < bytes.size():
		var a := bytes[i]
		if a < ObjectLoader.ALPHA_TEST_REF:
			below_ref += 1
		if a <= 5:
			t += 1
		elif a < 250:
			g += 1
		else:
			o += 1
		i += 4
	var n := float(maxi(t + g + o, 1))
	return " [%s %dx%d alpha: %.1f%% transparent, %.1f%% graded, %.1f%% opaque; %.1f%% below ALPHAREF 0x80]" % [
		parsed_tex.four_cc if parsed_tex.four_cc != "" else "uncompressed", image.get_width(), image.get_height(),
		100.0 * t / n, 100.0 * g / n, 100.0 * o / n, 100.0 * below_ref / n]

## The texture's alpha where the MESH samples it: at every triangle's UV
## centroid (wrapped, nearest texel), the share below ALPHAREF 0x80 and fully
## transparent -- how much of the drawn surface an alpha test at the client's
## reference would remove, rather than how much of the atlas is below it.
func _surface_alpha(data: Pk2Reader, bmt_path: String, tex: String, mesh: BmsReader.ParsedMesh) -> String:
	if tex == "":
		return "no texture"
	var path := tex
	if not (tex.contains("\\") or tex.contains("/")):
		path = bmt_path.replace("\\", "/").get_base_dir() + "/" + tex
	var entry := ObjectLoader.find_file(data, path)
	if entry == null:
		return "texture not found"
	var image := DdjReader.to_image(DdjReader.parse(data.read_file(entry)))
	if image == null:
		return "texture does not decode"
	image = image.duplicate() as Image
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	var w := image.get_width()
	var h := image.get_height()
	var below := 0
	var zero := 0
	var n := 0
	for t in range(0, mesh.indices.size(), 3):
		var uv: Vector2 = (mesh.vertices[mesh.indices[t]].uv + mesh.vertices[mesh.indices[t + 1]].uv + mesh.vertices[mesh.indices[t + 2]].uv) / 3.0
		var x := posmod(int(floor(uv.x * w)), w)
		var y := posmod(int(floor(uv.y * h)), h)
		var a := int(round(image.get_pixel(x, y).a * 255.0))
		if a < ObjectLoader.ALPHA_TEST_REF:
			below += 1
		if a <= 5:
			zero += 1
		n += 1
	return "%d triangles: %.1f%% sample alpha below 0x80, %.1f%% sample alpha <= 5" % [
		n, 100.0 * below / maxf(n, 1), 100.0 * zero / maxf(n, 1)]
