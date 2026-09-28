extends SceneTree

## Dev tool (round 625): a census of the map's foliage models, piece by
## piece, through the same readers and material decision the world uses.
##
## Every model Map.pk2's own `object.ifo` names whose path matches --match
## (default: tree, bush, leaf, pine, bamboo, willow, `tre_`, `bsh_`) is read
## the way ObjectLoader reads it, and for each mesh piece the tool prints
## what could make a tree draw without its leaves:
##
##   bsr    the object's type, skeleton and animation count
##   piece  mesh parsed or not, vertex/triangle count, skinned (bone palette
##          size), vertex-motion section, the layer it matched (by name or
##          the fallback), the layer flags, the layer's ambient/diffuse
##          alpha, the texture's fourCC and alpha fraction, and the cutout
##          decision ObjectLoader.prepare_object made
##
## then a summary: how many models and pieces fall in each failure class.
##
## --near=<region>:<x>,<z>,<r> instead lists the placements of region
## `<region>` (e.g. 97\168) within r units of local (x, z), with their
## model paths -- which trees stand at a spot.
##
## Usage (on the render box, via remote_godot.sh script):
##   res://tools/foliage_census.gd -- --pk2=Data.pk2 --map=Map.pk2 \
##     [--match=tree,bush] [--all] [--verbose] [--near=97\168:560,700,200]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
		if a == flag:
			return "1"
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var map := Pk2Reader.open(_arg("--map"))
	if data == null or map == null:
		printerr("usage: --pk2=<Data.pk2> --map=<Map.pk2>")
		quit(2)
		return
	var table := ObjidxReader.parse(AssetSource.read_bytes("object.ifo", map))
	if table == null:
		printerr("no object.ifo in Map.pk2")
		quit(1)
		return
	var near := _arg("--near")
	if near != "":
		_near(map, table, near)
		quit(0)
		return

	var keys := _arg("--match", "tree,bush,leaf,pine,bamboo,willow,tre_,bsh_").split(",")
	var every := _arg("--all") != ""
	var verbose := _arg("--verbose") != ""
	var paths := {}
	var candidates: Array = []
	var under := _arg("--under")
	if under != "":
		# Every .bsr under a Data.pk2 directory (equipment: res\item\...),
		# which object.ifo does not list.
		var dir_entry = ObjectLoader.find_file(data, under)
		if dir_entry != null:
			_collect(data, dir_entry, under, candidates)
	else:
		for e in table.entries:
			if e != null:
				candidates.append(e.path)
	for path in candidates:
		var low := String(path).to_lower()
		var hit := every
		for k in keys:
			if k != "" and low.get_file().contains(k):
				hit = true
		if hit:
			paths[low] = path

	var classes := {}
	var models := 0
	var pieces := 0
	var textures := {}
	for low in paths:
		models += 1
		var model_classes := _census_model(data, paths[low], textures, verbose)
		for c in model_classes:
			if not classes.has(c):
				classes[c] = {"models": 0, "pieces": 0, "examples": []}
			classes[c]["models"] += 1
			classes[c]["pieces"] += int(model_classes[c])
			if (classes[c]["examples"] as Array).size() < 6:
				(classes[c]["examples"] as Array).append(String(low).get_file())
		pieces += int(model_classes.get("_pieces", 0))
	print("CENSUS %d models, %d pieces" % [models, pieces])
	var names := classes.keys()
	names.sort()
	for c in names:
		if c == "_pieces":
			continue
		print("CLASS %-28s models=%d pieces=%d e.g. %s" % [c, classes[c]["models"], classes[c]["pieces"], ", ".join(classes[c]["examples"])])
	quit(0)

## Fraction of texels whose alpha byte is below `ref` -- what retail's alpha
## test (ALPHAREF 0x80, D3DCMP_GREATEREQUAL) discards at full resolution.
func _below(source: Image, ref: int) -> float:
	if source == null:
		return 0.0
	var image := source.duplicate() as Image
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var data := image.get_data()
	var below := 0
	var i := 3
	while i < data.size():
		if data[i] < ref:
			below += 1
		i += 4
	return float(below) / float(maxi(data.size() / 4, 1))

## Fraction of the MESH's own texture coverage whose alpha is below `ref`:
## each triangle sampled at 21 barycentric points weighted by its UV area --
## what the alpha test would actually cut from the drawn surface, unlike the
## whole-texture count, which includes atlas padding no triangle maps.
func _uv_below(source: Image, mesh: BmsReader.ParsedMesh, ref: int) -> float:
	if source == null or mesh.indices.size() < 3:
		return 0.0
	var image := source.duplicate() as Image
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var w := image.get_width()
	var h := image.get_height()
	var below := 0.0
	var total := 0.0
	for t in range(0, mesh.indices.size() - 2, 3):
		var a: Vector2 = mesh.vertices[mesh.indices[t]].uv
		var b: Vector2 = mesh.vertices[mesh.indices[t + 1]].uv
		var c: Vector2 = mesh.vertices[mesh.indices[t + 2]].uv
		var area := absf((b - a).cross(c - a)) * 0.5
		if area <= 0.0:
			continue
		var n := 0
		var cut := 0
		for i in range(6):
			for j in range(6 - i):
				var u := (float(i) + 1.0 / 3.0) / 6.0
				var v := (float(j) + 1.0 / 3.0) / 6.0
				var p := a + (b - a) * u + (c - a) * v
				var x := posmod(int(floor(p.x * w)), w)
				var y := posmod(int(floor(p.y * h)), h)
				n += 1
				if int(image.get_pixel(x, y).a8) < ref:
					cut += 1
		below += area * float(cut) / float(n)
		total += area
	return below / total if total > 0.0 else 0.0

func _collect(archive: Pk2Reader, dir_entry, prefix: String, out: Array) -> void:
	for e in archive.read_dir_at(dir_entry):
		if e.name == "." or e.name == "..":
			continue
		var path: String = prefix + "\\" + e.name
		if e.is_dir:
			_collect(archive, e, path, out)
		elif e.name.to_lower().ends_with(".bsr"):
			out.append(path)

## One model: returns class -> piece count.
func _census_model(data: Pk2Reader, path: String, texture_cache: Dictionary, verbose: bool) -> Dictionary:
	var out := {}
	if path.to_lower().ends_with(".cpd"):
		var entry := ObjectLoader.find_file(data, path)
		if entry == null:
			out["cpd_missing"] = 1
			return out
		var cpd := CpdReader.parse(data.read_file(entry))
		if cpd == null:
			out["cpd_unparsed"] = 1
			return out
		for sub in cpd.bsr_paths:
			var sub_out := _census_model(data, sub, texture_cache, verbose)
			for c in sub_out:
				out[c] = int(out.get(c, 0)) + int(sub_out[c])
		return out
	var bsr_entry := ObjectLoader.find_file(data, path)
	if bsr_entry == null:
		out["bsr_missing"] = 1
		return out
	var obj := BsrReader.parse(data.read_file(bsr_entry))
	if obj == null:
		out["bsr_unparsed"] = 1
		return out
	var prepared := ObjectLoader.prepare_object(data, path, {}, {})
	var plans := {}
	if prepared["root"] != null:
		for piece in prepared["root"]["pieces"]:
			plans[String(piece["name"])] = piece
	var material: BmtReader.ParsedMaterial = null
	if obj.material_path != "":
		var me := ObjectLoader.find_file(data, obj.material_path)
		if me != null:
			material = BmtReader.parse(data.read_file(me))
	if material == null:
		out["bmt_missing"] = 1
	print("BSR %s type=%d skel=%s anims=%d meshes=%d layers=%s" % [path, obj.object_type,
		obj.skeleton_path if obj.skeleton_path != "" else "-", obj.animation_paths.size(),
		obj.sub_mesh_paths.size(), str(material.layers.size()) if material != null else "none"])
	var seen := {}
	for mp in ([obj.mesh_path] if obj.mesh_path != "" else []) + obj.sub_mesh_paths:
		if seen.has(mp.to_lower()):
			continue
		seen[mp.to_lower()] = true
		out["_pieces"] = int(out.get("_pieces", 0)) + 1
		var me := ObjectLoader.find_file(data, mp)
		if me == null:
			out["mesh_missing"] = int(out.get("mesh_missing", 0)) + 1
			print("  PIECE %s MISSING" % mp)
			continue
		var mesh := BmsReader.parse(data.read_file(me))
		if mesh == null:
			out["mesh_unparsed"] = int(out.get("mesh_unparsed", 0)) + 1
			print("  PIECE %s UNPARSED" % mp)
			continue
		var line := "  PIECE %s mat=%s v=%d t=%d bones=%d motion=%d" % [mp.get_file(), mesh.material_name,
			mesh.vertices.size(), mesh.indices.size() / 3, mesh.bone_names.size(), mesh.vertex_motion.size()]
		if mesh.is_skinned():
			out["skinned"] = int(out.get("skinned", 0)) + 1
		if mesh.vertex_motion.size() > 0:
			out["vertex_motion"] = int(out.get("vertex_motion", 0)) + 1
		if material != null and material.layers.size() > 0:
			var li := ObjectLoader._find_layer_by_name(material.layers, mesh.material_name)
			if li == -1:
				out["layer_by_fallback"] = int(out.get("layer_by_fallback", 0)) + 1
				li = 0
			var layer := material.layers[li]
			line += " layer=%s flags=0x%04x amb.a=%.2f dif.a=%.2f tex=%s" % [layer.layer_name, layer.unknown,
				layer.ambient.a, layer.diffuse.a, layer.texture_path]
			# READ (round 625): CObjRendererVS FUN_00c42a60 -- 0x200 alpha
			# test (ref 0x80, GREATEREQUAL), 0x1 cull none.
			line += " [test=%s two=%s]" % [layer.unknown & 0x200 != 0, layer.unknown & 0x1 != 0]
			if layer.unknown & 0x200 != 0:
				out["flag_alpha_test"] = int(out.get("flag_alpha_test", 0)) + 1
			if layer.unknown & 0x1 != 0:
				out["flag_two_sided"] = int(out.get("flag_two_sided", 0)) + 1
			if (layer.unknown & 0x200 != 0) and (layer.unknown & 0x1 == 0):
				out["flag_alpha_test_one_sided"] = int(out.get("flag_alpha_test_one_sided", 0)) + 1
			if (layer.unknown & 0x200 == 0) and (layer.unknown & 0x1 != 0):
				out["flag_two_sided_no_test"] = int(out.get("flag_two_sided_no_test", 0)) + 1
			if layer.ambient.a < 0.5:
				out["ambient_alpha_low"] = int(out.get("ambient_alpha_low", 0)) + 1
			if layer.unknown & 0x40 == 0:
				out["flags_unrecognised"] = int(out.get("flags_unrecognised", 0)) + 1
			if obj.env_map_flags >= 0:
				line += " ENVMAP(flags=0x%x)" % obj.env_map_flags
				out["env_map"] = int(out.get("env_map", 0)) + 1
			var mtrl := obj.mtrl_mod_for(li)
			if not mtrl.is_empty():
				var rule := ObjectLoader.layer_draw_rule(layer.unknown, obj.env_map_flags, mtrl, obj.two_pass())
				line += " MTRL(test=%s ref=%d blend=%s zwrite=%s cull_none=%s)" % [mtrl["alpha_test"], mtrl["alpha_ref"],
					rule["blend"] if rule["blend"] != "" else "none", rule["zwrite"], mtrl["cull_none"]]
				out["mtrl_mod"] = int(out.get("mtrl_mod", 0)) + 1
				if rule["blend"] != "":
					out["mtrl_blend_" + String(rule["blend"])] = int(out.get("mtrl_blend_" + String(rule["blend"]), 0)) + 1
			if obj.two_pass():
				line += " TWO-PASS"
				out["two_pass"] = int(out.get("two_pass", 0)) + 1
			var piece = plans.get(mesh.mesh_name)
			if piece != null and piece["material"] != null:
				var plan: Dictionary = piece["material"]
				var key: String = plan["texture_key"]
				line += " cutout=%s" % plan["cutout"]
				if key == "":
					out["texture_unresolved"] = int(out.get("texture_unresolved", 0)) + 1
					line += " TEXTURE-UNRESOLVED"
				else:
					var dec: Dictionary = prepared["textures"][key]
					var fr := float(ObjectLoader._real_alpha_fraction(dec["image"]))
					line += " fourcc=%s alpha<250=%.3f alpha<128=%.3f uv_alpha<128=%.3f" % [dec["four_cc"] if dec["four_cc"] != "" else "raw", fr, _below(dec["image"], 128), _uv_below(dec["image"], mesh, 128)]
					if fr >= 0.05 and not plan["cutout"]:
						out["alpha_tex_drawn_solid"] = int(out.get("alpha_tex_drawn_solid", 0)) + 1
					if bool(plan["cutout"]) != (layer.unknown & 0x200 != 0):
						out["plan_disagrees_with_0x200"] = int(out.get("plan_disagrees_with_0x200", 0)) + 1
					if plan["cutout"]:
						out["cutout"] = int(out.get("cutout", 0)) + 1
						if mesh.is_skinned():
							out["cutout_and_skinned"] = int(out.get("cutout_and_skinned", 0)) + 1
		print(line)
	return out

func _near(map: Pk2Reader, table: ObjidxReader.Table, spec: String) -> void:
	var region := spec.get_slice(":", 0).replace("/", "\\")
	var nums := spec.get_slice(":", 1).split(",")
	var at := Vector2(float(nums[0]), float(nums[1]))
	var r := float(nums[2])
	var placements: Array = []
	var o := MapoReader.parse(AssetSource.read_bytes(region + ".o", map))
	if o != null:
		for p in o.objects:
			placements.append([p.type_id, p.position, p.rotation, ".o"])
	var o2bytes := AssetSource.read_bytes(region + ".o2", map)
	if not o2bytes.is_empty():
		var o2 := MapO2Reader.parse(o2bytes)
		if o2 != null:
			for s in o2.sectors:
				if s.lists.size() >= 3:
					for e in s.lists[2]:
						placements.append([e.type_id, e.position, e.rotation, ".o2"])
	var seen := {}
	for p in placements:
		var pos: Vector3 = p[1]
		var d := Vector2(pos.x, pos.z).distance_to(at)
		if d > r:
			continue
		var k := "%d@%.2f,%.2f" % [p[0], pos.x, pos.z]
		if seen.has(k):
			continue
		seen[k] = true
		var e := table.lookup(p[0])
		print("NEAR %s id=%d at (%.1f, %.1f, %.1f) yaw=%.2f d=%.0f %s" % [p[3], p[0], pos.x, pos.y, pos.z, p[2], d,
			e.path if e != null else "?"])
