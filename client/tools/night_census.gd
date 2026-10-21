extends SceneTree

## Dev tool (round 806): what the original turns on at night, over the whole
## archive (docs/protocol/night_lights.md has the reads).
##
## - NIGHTFX: every `.bsr` particle entry whose byte +0x51 has bit 0 -- drawn
##   only while the night flag is set (CRTModParticle::FUN_00c81450 0xc81493,
##   the glow pass FUN_00c43100 0xc431f7 / 0xc43586).
## - LAMP: every `.bsr` mesh whose `.bmt` layer has flag word bit 0x8 -- at
##   night drawn with the vertex shader's NOLIGHT (oD0 = 1), no fog and stage
##   0 MODULATE (CObjRendererVS 0xbf0fa0 and its twins, FUN_00c42a60
##   0xc42aef): the texture at its own colour.
## - With --places (server/cmd/mapobjcensus -dumpplaces): how often each such
##   model is placed in the open world, and the owner regions; a compound's
##   (`.cpd`) pieces count for it. With --dof: the `.dof` dungeons naming it.
##
## Usage (the box):
##   godot --headless --path client --script res://tools/night_census.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 [--places=/var/tmp/r806/places.tsv] [--dof]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a == flag:
			return "1"
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _collect(archive: Pk2Reader, dir_entry, prefix: String, ext: String, out: Array) -> void:
	var entries: Array = archive.read_dir() if dir_entry == null else archive.read_dir_at(dir_entry)
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var path: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_collect(archive, e, path, ext, out)
		elif e.name.to_lower().ends_with(ext):
			out.append([path, e])

var _bmt_cache := {}

## The night-lit layers of a `.bmt`: [name, flags, texture] for each layer
## with bit 0x8.
func _lamp_layers(archive: Pk2Reader, bmt_path: String) -> Array:
	var key := bmt_path.to_lower()
	if _bmt_cache.has(key):
		return _bmt_cache[key]
	var out: Array = []
	var e = ObjectLoader.find_file(archive, bmt_path)
	if e != null:
		var m := BmtReader.parse(archive.read_file(e))
		if m != null:
			for i in m.layers.size():
				var l: BmtReader.Layer = m.layers[i]
				if l.unknown & 0x8 != 0:
					out.append([l.layer_name, l.unknown, l.texture_path, i])
	_bmt_cache[key] = out
	return out

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("usage: --pk2=<Data.pk2> [--places=<places.tsv>] [--dof]")
		quit(2)
		return
	var files: Array = []
	_collect(archive, null, "", ".bsr", files)
	files.sort()
	# bsr path (lower) -> {"fx": [...], "lamp": [...]}
	var night := {}
	var fx_entries := 0
	var lamp_meshes := 0
	for f in files:
		var path: String = f[0]
		var data: PackedByteArray = archive.read_file(f[1])
		if data.size() < BsrReader.PREAMBLE_END:
			continue
		var found := {"fx": [], "lamp": []}
		for pm in BsrReader.particle_mods(data):
			for e in (pm as BsrReader.ParticleMod).entries:
				if e.b51 & 1 != 0:
					found["fx"].append("set %s '%s' efp '%s' glow %d mode %d bone '%s' offset (%.1f, %.1f, %.1f)" % [
						"by_type %d" % pm.action_type if pm.set_kind == BsrReader.SET_BY_TYPE else "by_clip", pm.set_name,
						e.efp, e.b50, e.mode, e.bone, e.offset.x, e.offset.y, e.offset.z])
		var obj := BsrReader.parse(data)
		if obj != null and obj.material_path != "":
			var layers := _lamp_layers(archive, obj.material_path)
			if not layers.is_empty():
				var names := {}
				for l in layers:
					names[l[0]] = l
				var seen := {}
				for mp in ([obj.mesh_path] if obj.mesh_path != "" else []) + Array(obj.sub_mesh_paths):
					if seen.has(String(mp).to_lower()):
						continue
					seen[String(mp).to_lower()] = true
					var me = ObjectLoader.find_file(archive, mp)
					if me == null:
						continue
					var mesh := BmsReader.parse(archive.read_file(me))
					if mesh != null and names.has(mesh.material_name):
						var l: Array = names[mesh.material_name]
						var mtrl := obj.mtrl_mod_for(int(l[3]))
						found["lamp"].append("mesh '%s' layer '%s' flags 0x%x texture '%s'%s" % [mp, l[0], l[1], l[2],
							(" MTRL %s" % str(mtrl)) if not mtrl.is_empty() else ""])
		if found["fx"].is_empty() and found["lamp"].is_empty():
			continue
		fx_entries += found["fx"].size()
		lamp_meshes += found["lamp"].size()
		night[path.to_lower()] = found
		for line in found["fx"]:
			print("NIGHTFX %s\t%s" % [path, line])
		for line in found["lamp"]:
			print("LAMP %s\t%s" % [path, line])
	print("NIGHT CENSUS: %d of %d .bsr -- %d night-only particle entr(ies), %d night-lit mesh(es)" % [
		night.size(), files.size(), fx_entries, lamp_meshes])

	var places_path := _arg("--places")
	if places_path != "":
		_placements(archive, night, places_path)
	if _arg("--dof") != "":
		_dungeons(archive, night)
	quit(0)

## Every placement of a night model (a `.bsr`, or a `.cpd` holding one).
func _placements(archive: Pk2Reader, night: Dictionary, places_path: String) -> void:
	var text := FileAccess.get_file_as_string(places_path)
	var cpd_cache := {}
	var by_model := {}
	for line in text.split("\n", false):
		var cols := line.split("\t")
		if cols.size() < 5:
			continue
		var model := cols[4].strip_edges()
		var key := model.to_lower()
		var pieces: Array = []
		if key.ends_with(".cpd"):
			if not cpd_cache.has(key):
				var hits: Array = []
				var e = ObjectLoader.find_file(archive, model)
				if e != null:
					var c := CpdReader.parse(archive.read_file(e))
					if c != null:
						for p in c.bsr_paths:
							if night.has(String(p).to_lower()) and not hits.has(String(p).to_lower()):
								hits.append(String(p).to_lower())
				cpd_cache[key] = hits
			pieces = cpd_cache[key]
		elif night.has(key):
			pieces = [key]
		for p in pieces:
			var row: Dictionary = by_model.get(p, {"n": 0, "regions": {}, "via": {}})
			row["n"] += 1
			row["regions"][cols[0]] = int(row["regions"].get(cols[0], 0)) + 1
			if key != p:
				row["via"][model] = true
			by_model[p] = row
	var names := by_model.keys()
	names.sort()
	var total := 0
	for p in names:
		var row: Dictionary = by_model[p]
		total += int(row["n"])
		var regions: Array = []
		for r in row["regions"]:
			regions.append("%s x%d" % [r, row["regions"][r]])
		regions.sort()
		var kinds: Array = []
		if not (night[p]["fx"] as Array).is_empty():
			kinds.append("fx %d" % (night[p]["fx"] as Array).size())
		if not (night[p]["lamp"] as Array).is_empty():
			kinds.append("lamp %d" % (night[p]["lamp"] as Array).size())
		print("PLACED %s\t%d\t%s\t%s%s" % [p, row["n"], ", ".join(kinds), " ".join(regions),
			("\tvia " + ", ".join(row["via"].keys())) if not row["via"].is_empty() else ""])
	var unplaced: Array = []
	for p in night:
		if not by_model.has(p):
			unplaced.append(p)
	unplaced.sort()
	for p in unplaced:
		print("UNPLACED %s" % p)
	print("PLACED TOTAL: %d model(s), %d placement(s); %d night model(s) not placed in the open world" % [
		by_model.size(), total, unplaced.size()])

## The `.dof` dungeons whose rooms or objects are night models (DofReader).
func _dungeons(archive: Pk2Reader, night: Dictionary) -> void:
	var dofs: Array = []
	_collect(archive, null, "", ".dof", dofs)
	for d in dofs:
		var dof := DofReader.parse(archive.read_file(d[1]))
		if dof == null:
			print("DOF %s\tDOES NOT PARSE" % d[0])
			continue
		var hits := {}
		for b in dof.blocks:
			for p in [b.path] + b.objects.map(func(o): return o.path):
				var key := String(p).to_lower()
				if night.has(key):
					hits[key] = int(hits.get(key, 0)) + 1
		if not hits.is_empty():
			var names: Array = []
			for k in hits:
				names.append("%s x%d" % [k, hits[k]])
			names.sort()
			print("DOF %s\t%s" % [d[0], ", ".join(names)])
