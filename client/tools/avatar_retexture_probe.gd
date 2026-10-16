extends SceneTree

## Dev tool (round 789, lane X): looks at avatar items on the four bodies and
## checks a retextured copy of one before any pack layer exists.
##
## - `--items=<id,id,...>` builds each item through CharacterAppearance (the
##   item table, column 52's model, SkinnedBsrAssembler) on the first Figure of
##   each race of the item's sex (ReqGender 1 the two men, 0 the two women,
##   2 all four), and with `--out=<dir>` renders them front and back in one
##   frame per item, `<id>_<code>.png` (needs a GL context; no --headless).
## - `--overlay=<dir>` serves loose files before the archives, by their pk2
##   path under <dir> (`<dir>/prim/mtrl/item/etc/x.ddj` answers
##   `Prim\Mtrl\Item\etc\x.ddj`, case ignored). It is the probe's own stand-in
##   for the pack layer (OURS, docs/TODO.md "Asset packs"): a new itemdata
##   part, a new .bsr/.bmt/.ddj and an itemdata.txt naming the part are found
##   exactly as the archives' own files are, so a new item id builds end to end.
## - `--chain=<id,id,...>` prints, for each id, the row's model and icon paths,
##   the .bsr's material and meshes, the .bmt's layers and textures, and which
##   layer served each file (overlay or archive); a link that does not resolve
##   is `PARITY FAIL` (headless is enough).
## - `--dump=<dir>` with `--items` writes each item's meshes as JSON (bind-pose
##   positions, normals, UVs, triangles, material name) for the texture painter
##   (OURS tooling; the files are game data and stay on the box).
## - `--outfits=<id+id,...>` (with `--out`) renders each `+` group worn
##   together, e.g. a robe and its hat; the sex is the first id's.
##
##   remote_godot.sh script res://tools/avatar_retexture_probe.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 \
##     --chain=62956 --overlay=/var/tmp/x789/pack

var _fails := 0
var _overlay_dir := ""
var _names: UiTextTable = null

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _expect(cond: bool, msg: String) -> void:
	if cond:
		print("ok   " + msg)
	else:
		print("PARITY FAIL " + msg)
		_fails += 1

## A Pk2Reader that answers from a loose folder first (see the file comment).
## Every lookup the client makes goes through ObjectLoader.find_file and
## read_file, so answering find_native (is_native true) and read_file here is
## the whole hook.
class OverlayArchive extends Pk2Reader:
	var base: Pk2Reader
	## lower-cased pk2 path with `\` -> absolute loose file
	var files := {}
	var served := {}

	static func wrap(archive: Pk2Reader, dir: String) -> OverlayArchive:
		var o := OverlayArchive.new()
		o.base = archive
		o.source_path = "overlay:%s:%s" % [dir, archive.source_path]
		if dir != "":
			o._scan(dir, "")
		return o

	func _scan(root: String, rel: String) -> void:
		var d := DirAccess.open(root.path_join(rel))
		if d == null:
			return
		for f in d.get_files():
			var r := f if rel == "" else rel + "/" + f
			files[r.replace("/", "\\").to_lower()] = root.path_join(r)
		for sub in d.get_directories():
			_scan(root, sub if rel == "" else rel + "/" + sub)

	func is_native() -> bool:
		return true

	func find_native(path: String) -> Pk2Reader.Entry:
		var key := path.replace("/", "\\").to_lower()
		if files.has(key):
			var e := Pk2Reader.Entry.new()
			e.name = key.replace("\\", "/").get_file()
			e.is_dir = false
			e._offset = -1
			e.set_meta("overlay", files[key])
			e.size = FileAccess.get_file_as_bytes(files[key]).size()
			served[key] = "overlay"
			return e
		var found := ObjectLoader.find_file(base, path)
		if found != null:
			served[key] = "archive"
		return found

	func read_dir() -> Array[Pk2Reader.Entry]:
		return base.read_dir()

	func read_dir_at(dir: Pk2Reader.Entry) -> Array[Pk2Reader.Entry]:
		return base.read_dir_at(dir)

	func read_file(file: Pk2Reader.Entry) -> PackedByteArray:
		if file.has_meta("overlay"):
			return FileAccess.get_file_as_bytes(String(file.get_meta("overlay")))
		return base.read_file(file)

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--items=..] [--chain=..] [--overlay=<dir>] [--out=<dir>] [--dump=<dir>]")
		quit(2)
		return
	_overlay_dir = _arg("--overlay")
	var odata := OverlayArchive.wrap(data, _overlay_dir)
	var omedia := OverlayArchive.wrap(media, _overlay_dir)
	if _overlay_dir != "":
		print("overlay %s: %d files" % [_overlay_dir, odata.files.size()])
	var app := CharacterAppearance.from_archives(odata, omedia)
	var rows := ItemTableReader.load_all(omedia)
	print("item rows: %d (%d parts)" % [rows.size(), ItemTableReader.last_load_parts])

	_names = ItemTableReader.load_object_names(omedia)
	for id in _ids("--chain"):
		_check_chain(odata, omedia, rows, id)
	var items := _ids("--items")
	if _arg("--dump") != "":
		for id in items:
			_dump(odata, rows, id, _arg("--dump"))
	var groups := []
	for id in items:
		groups.append([id])
	for g in _arg("--outfits").split(",", false):
		var ids := []
		for s in g.split("+", false):
			ids.append(int(s))
		groups.append(ids)
	if _arg("--out") != "" and not groups.is_empty():
		await _render(app, rows, groups, _arg("--out"))
	app.free_templates()
	print("RESULT: %s (%d failing)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(1 if _fails > 0 else 0)

func _ids(flag: String) -> Array:
	var out := []
	for s in _arg(flag).split(",", false):
		out.append(int(s))
	return out

# --- the chain: row -> .bsr -> .bms + .bmt -> .ddj, and the icon -----------------

func _layer_of(archive: Pk2Reader, path: String) -> String:
	var e := ObjectLoader.find_file(archive, path)
	if e == null:
		e = ObjectLoader.find_file(archive, "res\\" + path)
	if e == null:
		return "MISSING"
	return "overlay" if e.has_meta("overlay") else "archive"

func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	var e := ObjectLoader.find_file(archive, path)
	if e == null:
		e = ObjectLoader.find_file(archive, "res\\" + path)
	return archive.read_file(e) if e != null else PackedByteArray()

func _check_chain(data: Pk2Reader, media: Pk2Reader, rows: Dictionary, id: int) -> void:
	var item: ItemTableReader.Item = rows.get(id)
	_expect(item != null, "item %d is in the item table" % id)
	if item == null:
		return
	print("item %d %s type %s model %s icon %s" % [id, item.code_name, str(item.type_ids), item.model_path, item.icon_path])
	var shown := _names.get_text(item.name_strid, "") if _names != null else ""
	_expect(shown != "", "  name %s -> \"%s\" (the tables textdataname.txt lists)" % [item.name_strid, shown])
	# Item.icon_path already carries the `icon\` prefix (ItemTableReader).
	var icon := item.icon_path
	var icon_layer := _layer_of(media, icon)
	_expect(icon_layer != "MISSING", "  icon %s (%s)" % [icon, icon_layer])
	if icon_layer != "MISSING":
		var tex := DdjReader.parse(_read(media, icon))
		_expect(tex != null, "  icon decodes")
		if tex != null:
			print("  icon %dx%d %s mips %d" % [tex.width, tex.height, tex.four_cc, tex.mip_map_count])
	for model in item.model_paths:
		var layer := _layer_of(data, model)
		_expect(layer != "MISSING", "  model %s (%s)" % [model, layer])
		var parsed := BsrReader.parse(_read(data, model))
		_expect(parsed != null and parsed.is_item(), "  model parses as an item .bsr")
		if parsed == null:
			continue
		var ml := _layer_of(data, parsed.material_path)
		_expect(ml != "MISSING", "    material %s (%s)" % [parsed.material_path, ml])
		for mp in parsed.all_mesh_paths():
			var l := _layer_of(data, mp)
			_expect(l != "MISSING", "    mesh %s (%s)" % [mp, l])
		var bmt := BmtReader.parse(_read(data, parsed.material_path))
		_expect(bmt != null and bmt.layers.size() > 0, "    material parses")
		if bmt == null:
			continue
		var dir := parsed.material_path.replace("\\", "/").get_base_dir()
		for li in range(bmt.layers.size()):
			var layer_rec: BmtReader.Layer = bmt.layers[li]
			# How the layer's alpha is used: the flag word, the object's env-map
			# and MTRL mods (ObjectLoader.layer_draw_rule, READ round 625).
			var rule := ObjectLoader.layer_draw_rule(layer_rec.unknown, parsed.env_map_flags, parsed.mtrl_mod_for(li), parsed.two_pass())
			print("    layer %s flags 0x%x env-map %d mtrl %s -> alpha test ref %d func %d, blend \"%s\", two-sided %s" % [
				layer_rec.layer_name, layer_rec.unknown, parsed.env_map_flags, "yes" if rule["mtrl"] else "no",
				int(rule["alpha_ref"]), int(rule["alpha_func"]), rule["blend"], str(rule["two_sided"])])
			var tp: String = layer_rec.texture_path
			if tp == "":
				print("    layer %s: no texture" % layer_rec.layer_name)
				continue
			var full := tp if (tp.contains("\\") or tp.contains("/")) else dir + "/" + tp
			var tl := _layer_of(data, full)
			_expect(tl != "MISSING", "    layer %s -> %s (%s)" % [layer_rec.layer_name, full, tl])
			if tl != "MISSING":
				var t := DdjReader.parse(_read(data, full))
				_expect(t != null, "      texture decodes")
				if t != null:
					print("      %dx%d %s mips %d" % [t.width, t.height, t.four_cc, t.mip_map_count])

# --- mesh dumps --------------------------------------------------------------------

func _dump(data: Pk2Reader, rows: Dictionary, id: int, dir: String) -> void:
	var item: ItemTableReader.Item = rows.get(id)
	if item == null:
		_expect(false, "dump: item %d is in the item table" % id)
		return
	DirAccess.make_dir_recursive_absolute(dir)
	for model in item.model_paths:
		var parsed := BsrReader.parse(_read(data, model))
		if parsed == null:
			continue
		var meshes := []
		for mp in parsed.all_mesh_paths():
			var m := BmsReader.parse(_read(data, mp))
			if m == null:
				continue
			var pos := []
			var nrm := []
			var uv := []
			var bones := []
			for v in m.vertices:
				pos.append([v.position.x, v.position.y, v.position.z])
				nrm.append([v.normal.x, v.normal.y, v.normal.z])
				uv.append([v.uv.x, v.uv.y])
				bones.append([v.bone0, v.weight0, v.bone1, v.weight1])
			meshes.append({"path": mp, "name": m.mesh_name, "material": m.material_name,
				"bone_names": Array(m.bone_names), "positions": pos, "normals": nrm, "uvs": uv,
				"bones": bones, "indices": Array(m.indices)})
		var out := dir.path_join("%d_%s.json" % [id, model.replace("\\", "/").get_file().get_basename()])
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify({"id": id, "model": model, "material": parsed.material_path, "meshes": meshes}))
		f.close()
		print("dumped %s (%d meshes)" % [out, meshes.size()])

# --- renders -----------------------------------------------------------------------

func _render(app: CharacterAppearance, rows: Dictionary, groups: Array, out: String) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var cat := app.catalog()
	var world := Node3D.new()
	get_root().add_child(world)
	_lights(world)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.current = true
	world.add_child(cam)
	for group in groups:
		var id: int = group[0]
		var item: ItemTableReader.Item = rows.get(id)
		if item == null:
			_expect(false, "render: item %d is in the item table" % id)
			continue
		var kit := []
		for gid in group:
			kit.append({"id": int(gid), "plus": 0})
		var sexes := [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]
		if item.req_gender == 1:
			sexes = [CharCatalog.SEX_MAN]
		elif item.req_gender == 0:
			sexes = [CharCatalog.SEX_WOMAN]
		var holder := Node3D.new()
		world.add_child(holder)
		var col := 0
		for s in sexes:
			for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
				var f: CharCatalog.Entry = cat.figures(r, s)[0]
				for yaw in [PI, 0.0]:
					var b := app.build(f.id, 0x22, kit)
					if b == null:
						continue
					var drawn := 0
					for w in b.worn:
						drawn += (w["nodes"] as Array).size()
					if yaw == PI:
						_expect(drawn >= group.size(), "%s drawn on %s (%d): %d piece(s)" % [str(group), f.code, f.id, drawn])
					_stand(app, b)
					b.rotation.y = yaw
					b.position = Vector3(col * 9.0, 0, 0)
					holder.add_child(b)
					col += 1
		_frame(cam, Vector3((col - 1) * 4.5, 10.0, 0), 22.0, col * 9.0)
		var stem := "_".join(PackedStringArray(group.map(func(x): return str(x))))
		await _shoot(out.path_join("%s_%s.png" % [stem, item.code_name.to_lower()]))
		holder.free()
	world.free()

func _stand(app: CharacterAppearance, b: CharacterAppearance.Body) -> void:
	var idle := app.animation_for(b, BsrReader.AnimationEntry.TYPE_STAND)
	b.pose(idle, 0.0)

func _frame(cam: Camera3D, centre: Vector3, height: float, width: float) -> void:
	var vp := get_root().get_visible_rect().size
	cam.size = maxf(height, width * vp.y / maxf(vp.x, 1.0))
	cam.look_at_from_position(centre + Vector3(0, 0, 200), centre, Vector3.UP)
	cam.far = 1000.0

func _lights(world: Node3D) -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 25, 0)
	world.add_child(key)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.21)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.62, 0.66)
	env_node.environment = env
	world.add_child(env_node)

func _shoot(path: String) -> void:
	for _i in range(4):
		await process_frame
	get_root().get_texture().get_image().save_png(path)
	print("saved " + path)
