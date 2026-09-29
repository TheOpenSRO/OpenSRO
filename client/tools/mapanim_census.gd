extends SceneTree

## Dev tool (round 645): which map objects move, and where they stand.
##
## Every model Map.pk2's own `object.ifo` names is read the way ObjectLoader
## reads it (a `.cpd` through its `.bsr` children), and each is classed by
## what could animate it:
##
##   skeletal   a skeleton (`.bsk`) and at least one animation (`.ban`)
##   skel_only  a skeleton and no animation
##   texani     a TEXANI mod (0x10000) in its mod section
##   dy         a DYVERTEX / DYJOINT / DYLATTICE mod (0x60000..0x60002)
##   motion     a mesh piece with the per-vertex motion section (hdr[2])
##
## and every region's placements are counted against it: the `.o` records
## and the `.o2` list-2 records (the region's own objects, as World3D
## draws them), de-duplicated by model and position.
##
##   animates   what THIS client plays (round 645): a skeletal model whose
##              `default` group has a type-0 entry (MapAnimation.clip_entry,
##              READ from the client) and at least one skinned piece. Absent
##              on a client without MapAnimation, where nothing moves.
##
## Output lines:
##   MODEL <path> class=<c,..> type=<t> skel=<bsk> anims=<n> [<ban> <ms> cyc=<0|1>]..
##         pieces=<n> skinned=<n> rigid=<n> places=<n> regions=<n> e.g. <x/y>..
##   CLASS <c> models=<n> placements=<n> regions=<n>
##   REGION <x/y> skeletal=<n> models=<names..>   (--regions)
##   AT <file> <x/y> (<local x, y, z>)              (--where=<substring>:
##         every placement of the models whose path contains it)
##   IN <x/y> <path> x<n> class=<c,..>                (--region=<x/y>: every
##         model the region places, and nothing else)
##
## Usage (on the render box, via remote_godot.sh script):
##   res://tools/mapanim_census.gd -- --pk2=Data.pk2 --map=Map.pk2 [--regions] [--match=tak]

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
	var match_key := _arg("--match").to_lower()
	var only_region := _arg("--region")

	# Placements: type id -> {region "x/y": count}.
	var placed := {}
	var regions_read := 0
	for top in map.read_dir():
		if not top.is_dir or not top.name.is_valid_int():
			continue
		for f in map.read_dir_at(top):
			if f.is_dir or not f.name.to_lower().ends_with(".o"):
				continue
			var y := f.name.get_basename()
			if not y.is_valid_int():
				continue
			var region := "%s/%s" % [top.name, y]
			var seen := {}
			var o := MapoReader.parse(map.read_file(f))
			if o != null:
				for p in o.objects:
					_place(placed, seen, region, p.type_id, p.position)
			var o2_path := "%s\\%s.o2" % [top.name, y]
			var o2_entry := ObjectLoader.find_file(map, o2_path)
			if o2_entry != null:
				var o2 := MapO2Reader.parse(map.read_file(o2_entry))
				if o2 != null:
					for sector in o2.sectors:
						if sector.lists.size() < 3:
							continue
						for e in sector.lists[2]:
							_place(placed, seen, region, e.type_id, e.position)
			regions_read += 1
	print("REGIONS %d read" % regions_read)

	var classes := {}
	var region_models := {}
	var models := 0
	var bsr_cache := {}
	for e in table.entries:
		if e == null:
			continue
		if match_key != "" and not e.path.to_lower().contains(match_key):
			continue
		models += 1
		var info := _model_info(data, e.path, bsr_cache)
		var where: Dictionary = placed.get(e.type_id, {})
		var places := 0
		for r in where:
			places += int(where[r])
		var cls: Array = info["classes"]
		if _arg("--where") != "" and e.path.to_lower().contains(_arg("--where").to_lower()):
			for at in _positions.get(e.type_id, []):
				print("AT %s %s" % [e.path.get_file(), at])
		if only_region != "":
			if where.has(only_region):
				print("IN %s %s x%d class=%s" % [only_region, e.path, where[only_region], ",".join(cls)])
			continue
		if cls.is_empty() and _arg("--all") == "":
			continue
		for c in cls:
			if not classes.has(c):
				classes[c] = {"models": 0, "placements": 0, "regions": {}}
			classes[c]["models"] += 1
			classes[c]["placements"] += places
			for r in where:
				classes[c]["regions"][r] = true
		if cls.has("skeletal"):
			for r in where:
				if not region_models.has(r):
					region_models[r] = {}
				region_models[r][e.path.get_file().get_basename()] = int(region_models[r].get(e.path.get_file().get_basename(), 0)) + int(where[r])
		var eg: Array = where.keys()
		eg.sort()
		print("MODEL %s ifo=0x%x class=%s type=%d skel=%s anims=%d %s groups=%s pieces=%d skinned=%d rigid=%d mods=%s places=%d regions=%d e.g. %s" % [
			e.path, e.flags, ",".join(cls), info["type"], info["skel"], (info["anims"] as Array).size(),
			" ".join(info["anims"]), info["groups"], info["pieces"], info["skinned"], info["pieces"] - info["skinned"],
			info["mods"], places, where.size(), " ".join(eg.slice(0, 6))])
	print("CENSUS %d models" % models)
	var names := classes.keys()
	names.sort()
	for c in names:
		print("CLASS %-10s models=%d placements=%d regions=%d" % [c, classes[c]["models"], classes[c]["placements"], (classes[c]["regions"] as Dictionary).size()])
	if _arg("--regions") != "":
		var rs := region_models.keys()
		rs.sort()
		for r in rs:
			var total := 0
			var parts: Array = []
			for m in region_models[r]:
				total += int(region_models[r][m])
				parts.append("%s:%d" % [m, region_models[r][m]])
			print("REGION %s skeletal=%d %s" % [r, total, " ".join(parts)])
	quit(0)

## type id -> ["x/y local (x, y, z)", ..], kept for --where only.
var _positions := {}

func _place(placed: Dictionary, seen: Dictionary, region: String, type_id: int, pos: Vector3) -> void:
	var key := "%d@%d,%d,%d" % [type_id, roundi(pos.x * 10), roundi(pos.y * 10), roundi(pos.z * 10)]
	if seen.has(key):
		return
	seen[key] = true
	if _arg("--where") != "":
		if not _positions.has(type_id):
			_positions[type_id] = []
		_positions[type_id].append("%s (%.1f, %.1f, %.1f)" % [region, pos.x, pos.y, pos.z])
	if not placed.has(type_id):
		placed[type_id] = {}
	placed[type_id][region] = int(placed[type_id].get(region, 0)) + 1

## One object.ifo model: its classes and what backs them. A `.cpd` merges
## its children's.
func _model_info(data: Pk2Reader, path: String, cache: Dictionary) -> Dictionary:
	var low := path.to_lower()
	if cache.has(low):
		return cache[low]
	var info := {"classes": [], "type": -1, "skel": "-", "anims": [], "pieces": 0, "skinned": 0, "mods": {}, "groups": ""}
	cache[low] = info
	var entry := ObjectLoader.find_file(data, path)
	if entry == null:
		info["classes"] = ["missing"]
		return info
	if low.ends_with(".cpd"):
		var cpd := CpdReader.parse(data.read_file(entry))
		if cpd == null:
			return info
		for sub in cpd.bsr_paths:
			var s := _model_info(data, sub, cache)
			for c in s["classes"]:
				if not (info["classes"] as Array).has(c):
					(info["classes"] as Array).append(c)
			if s["groups"] != "":
				info["groups"] = s["groups"]
			if s["skel"] != "-":
				info["skel"] = s["skel"]
				info["type"] = s["type"]
			(info["anims"] as Array).append_array(s["anims"])
			info["pieces"] += s["pieces"]
			info["skinned"] += s["skinned"]
		return info
	var bytes := data.read_file(entry)
	var obj := BsrReader.parse(bytes)
	if obj == null:
		info["classes"] = ["unparsed"]
		return info
	info["type"] = obj.object_type
	var groups: Array = []
	for g in obj.animation_groups:
		var entries: Array = []
		for ae in obj.animation_groups[g]:
			entries.append("%d>%d" % [ae.action_type, ae.file_index])
		groups.append("%s[%s]" % [g, ",".join(entries)])
	info["groups"] = " ".join(groups)
	var cls: Array = info["classes"]
	if obj.skeleton_path != "":
		info["skel"] = obj.skeleton_path.get_file()
		cls.append("skeletal" if not obj.animation_paths.is_empty() else "skel_only")
	for ap in obj.animation_paths:
		var ae := ObjectLoader.find_file(data, ap)
		var desc := ap.get_file()
		if ae == null:
			desc += "(missing)"
		else:
			var ban := BanReader.parse(data.read_file(ae))
			if ban != null:
				desc += "(%dms,cyc=%d,bones=%d)" % [ban.duration_ms, 1 if ban.cyclic else 0, ban.bones.size()]
		(info["anims"] as Array).append(desc)
	var section = BsrReader.parse_sound_section(bytes, bytes.decode_u32(BsrReader.OFF_PTR_SOUND)) if bytes.size() > BsrReader.OFF_PTR_SOUND + 4 else null
	if section != null:
		var mods: Dictionary = section["mods"]
		for k in mods:
			info["mods"]["0x%x" % k] = mods[k]
		if mods.has(BsrReader.MOD_TEXANI):
			cls.append("texani")
		if mods.has(BsrReader.MOD_DYVERTEX) or mods.has(BsrReader.MOD_DYJOINT) or mods.has(BsrReader.MOD_DYLATTICE):
			cls.append("dy")
	var planned := false
	var MA = load("res://scripts/world/map_animation.gd") if ResourceLoader.exists("res://scripts/world/map_animation.gd") else null
	if MA != null and MA.clip_entry(obj) != null:
		planned = true
	var seen := {}
	for mp in ([obj.mesh_path] if obj.mesh_path != "" else []) + obj.sub_mesh_paths:
		if seen.has(mp.to_lower()):
			continue
		seen[mp.to_lower()] = true
		var me := ObjectLoader.find_file(data, mp)
		if me == null:
			continue
		var mesh := BmsReader.parse(data.read_file(me))
		if mesh == null:
			continue
		info["pieces"] += 1
		if mesh.is_skinned():
			info["skinned"] += 1
		if mesh.vertex_motion.size() > 0 and not cls.has("motion"):
			cls.append("motion")
	if planned and info["skinned"] > 0:
		cls.append("animates")
	return info
