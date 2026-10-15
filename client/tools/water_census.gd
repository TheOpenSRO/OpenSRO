extends SceneTree

## Dev tool (round 786): what moves a placed map object's water, over the
## whole world -- every mechanism the original has for it, which placements
## carry each, and which this client plays.
##
## Every model Map.pk2's own `object.ifo` names is read the way ObjectLoader
## reads it (a `.cpd` through its `.bsr` children), and its live mods are
## classed (BsrReader; each READ, docs/protocol/BSR_FORMAT.md):
##
##   ambient_fx    an `ambient` mod set with particle entries (the effects a
##                 placed object plays with no clip running, round 720)
##   clip_fx       particle entries in a set keyed by a clip or an action
##                 type (they play with that clip; a placed object runs only
##                 its `default` type-0 clip)
##   default_fx    of clip_fx: in the (type 0, `default`) set of a model the
##                 map animates (MapAnimation.clip_entry)
##   texani0       a live TEXANI mod of mode 0 (stage 0's coordinates)
##   texani1       a live TEXANI mod of mode 1 (stage 1's coordinates)
##   multitex      a live MULTITEX mod (a second texture on stage 1)
##   multitexrev   a live MULTITEXREV mod (its texture on stage 0)
##   texani1_mt    a mode-1 TEXANI on a material that also has a MULTITEX
##   texani1_bare  a mode-1 TEXANI on a material with no MULTITEX (stage 1
##                 holds no texture: nothing moves, READ)
##   mtrl          a live MTRL mod
##   skeletal      the map plays its `default` type-0 clip (round 645)
##   dy            a DYVERTEX / DYJOINT / DYLATTICE mod
##   motion        a mesh piece with the per-vertex motion section
##
## and `water` when any name it carries (model, material layer, texture,
## effect) looks like water (WATER_WORDS). Placements are the objects the
## world builds (World3D.region_placements: `.o2` lists 1 and 2 without the
## skip bit, one per object key), each in its owner region.
##
## Support, before round 786 and after:
##   ambient_fx    before: only the placements standing within
##                 GATE_EFFECT_RADIUS of a teleportbuilding row (World3D.
##                 _attach_gate_effects; walk-ins not counted here); after:
##                 every placement
##   texani0       both
##   texani1_mt    after only
##   multitex      after only
##
## Output:
##   MODEL <path> classes=<..> places=<n> near_list=<n> gate_places=<n> regions=<n> e.g. <x/y>..
##     <the live mods, one per line, with their material's layer name>
##     (near_list: the placements from `.o2` lists[2], the sector's +0x24
##     list, which the original draws only within 480 -- READ, round 786)
##   CLASS <c> models=<n> placed_models=<n> placements=<n> water_models=<n> water_placements=<n>
##   SUPPORT <mechanism> placements=<n> before=<n> after=<n>
##   FXTOTAL / REGIONFX <x/y> hosts=<n> entries=<n>   the ambient effect entries per region
##     (without the seasonal sets World3D leaves out by default, SeasonalObjects;
##     SUPPORT ambient_fx_unseasonal is ambient_fx without them too)
##   AT <file> <x/y> (<local x, y, z>)   (--where=<substring>)
##   IN <x/y> <path> x<n> classes=<..>   (--region=<x/y>)
##
## Usage (on the render box, via remote_godot.sh script):
##   res://tools/water_census.gd -- --pk2=Data.pk2 --map=Map.pk2 --media=Media.pk2 [--match=fount+turtle] [--where=fount] [--region=91/49] [--all] [--placed-only]
## (--match and --where take words joined by `+`: any of them matches.)

const WATER_WORDS := ["water", "fount", "fall", "splash", "spray", "_wf", "wf_", "stream", "river", "wave", "spout"]
const GATE_EFFECT_RADIUS := 30.0

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
		if a == flag:
			return "1"
	return fallback

static func is_water_name(s: String) -> bool:
	var low := s.to_lower()
	for w in WATER_WORDS:
		if low.contains(w):
			return true
	return false

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var map := Pk2Reader.open(_arg("--map"))
	if data == null or map == null:
		printerr("usage: --pk2=<Data.pk2> --map=<Map.pk2> [--media=<Media.pk2>]")
		quit(2)
		return
	var table := ObjidxReader.parse(AssetSource.read_bytes("object.ifo", map))
	if table == null:
		printerr("no object.ifo in Map.pk2")
		quit(1)
		return
	var teleports: TeleportReader = null
	var media := Pk2Reader.open(_arg("--media")) if _arg("--media") != "" else null
	if media != null:
		teleports = TeleportReader.new().load(func(archive_path: String) -> PackedByteArray:
			var e := ObjectLoader.find_file(media, archive_path)
			return media.read_file(e) if e != null else PackedByteArray())
	var match_key := _arg("--match").to_lower()
	var only_region := _arg("--region")
	var where_key := _arg("--where").to_lower()

	# Placements: type id -> {region: count}, and per type the count standing
	# by a teleport row (the pre-786 ambient effects' scope).
	var placed := {}
	var gate_placed := {}
	# Placements from `lists[2]` (the sector's +0x24 list: updated and drawn only
	# in the 9 nearest sectors, within 480 -- READ, SWorld::vslot_004).
	var near_placed := {}
	var positions := {}
	var regions_read := 0
	# One object per key (World3D.region_placements, READ round 643): the
	# `.o2` lists 1 and 2, records with the skip bit left out, each object
	# once however many sectors and regions list it, at its position in its
	# OWNER region's frame.
	var keys := {}
	var rows_of := {}
	for top in map.read_dir():
		if not top.is_dir or not top.name.is_valid_int():
			continue
		for f in map.read_dir_at(top):
			if f.is_dir or not f.name.to_lower().ends_with(".o2"):
				continue
			var y := f.name.get_basename()
			if not y.is_valid_int():
				continue
			var o2 := MapO2Reader.parse(map.read_file(f))
			if o2 == null:
				continue
			regions_read += 1
			for sector in o2.sectors:
				for li in [1, 2]:
					for e_v in (sector as MapO2Reader.Sector).lists[li]:
						var e := e_v as MapO2Reader.Entry
						if e.skipped():
							continue
						var key := e.object_key()
						if keys.has(key):
							continue
						keys[key] = true
						if li == 2:
							near_placed[e.type_id] = int(near_placed.get(e.type_id, 0)) + 1
						var ox := (e.owner_region >> 8) & 0xFF
						var oy := e.owner_region & 0xFF
						var region := "%d/%d" % [ox, oy]
						if not rows_of.has(region):
							var rows: Array = []
							if teleports != null:
								for b in teleports.buildings_in_region(ox, oy):
									rows.append(Vector2((b as TeleportReader.Building).x, (b as TeleportReader.Building).z))
							rows_of[region] = rows
						if not placed.has(e.type_id):
							placed[e.type_id] = {}
						placed[e.type_id][region] = int(placed[e.type_id].get(region, 0)) + 1
						for r in rows_of[region]:
							if Vector2(e.position.x, e.position.z).distance_to(r) <= GATE_EFFECT_RADIUS:
								gate_placed[e.type_id] = int(gate_placed.get(e.type_id, 0)) + 1
								break
						if where_key != "":
							if not positions.has(e.type_id):
								positions[e.type_id] = []
							positions[e.type_id].append("%s (%.1f, %.1f, %.1f) yaw %.2f" % [region, e.position.x, e.position.y, e.position.z, e.rotation])
	print("REGIONS %d read" % regions_read)

	var classes := {}
	var support := {}
	var region_fx := {}
	var region_hosts := {}
	var cache := {}
	var models := 0
	for e in table.entries:
		if e == null:
			continue
		var path: String = e.path
		if match_key != "" and not _any_in(path, match_key):
			continue
		models += 1
		var info := _model_info(data, path, cache)
		var where: Dictionary = placed.get(e.type_id, {})
		var places := 0
		for r in where:
			places += int(where[r])
		var gates := int(gate_placed.get(e.type_id, 0))
		var cls: Array = info["classes"]
		if where_key != "" and _any_in(path, where_key):
			for at in positions.get(e.type_id, []):
				print("AT %s %s" % [path.get_file(), at])
		if only_region != "":
			if where.has(only_region):
				print("IN %s %s x%d classes=%s%s" % [only_region, path, where[only_region], ",".join(cls),
					(" water" if info["water"] else "")])
				for line in info["lines"]:
					print("    " + line)
			continue
		if cls.is_empty() and _arg("--all") == "":
			continue
		var water: bool = info["water"]
		for r in where:
			if SeasonalObjects.classify(path) != "":
				continue
			region_fx[r] = int(region_fx.get(r, 0)) + int(where[r]) * int(info["fx"])
			if int(info["fx"]) > 0:
				region_hosts[r] = int(region_hosts.get(r, 0)) + int(where[r])
		for c in cls:
			if not classes.has(c):
				classes[c] = {"models": 0, "placed": 0, "placements": 0, "water_models": 0, "water_placements": 0}
			classes[c]["models"] += 1
			classes[c]["placements"] += places
			if places > 0:
				classes[c]["placed"] += 1
			if water:
				classes[c]["water_models"] += 1
				classes[c]["water_placements"] += places
		_support(support, "ambient_fx", cls.has("ambient_fx"), places, gates, places)
		# The seasonal sets World3D leaves out by default (SeasonalObjects,
		# round 583): the same counts without them.
		var seasonal := SeasonalObjects.classify(path) != ""
		_support(support, "ambient_fx_unseasonal", cls.has("ambient_fx") and not seasonal, places, gates, places)
		_support(support, "texani0", cls.has("texani0"), places, places, places)
		_support(support, "texani1_mt", cls.has("texani1_mt"), places, 0, places)
		_support(support, "multitex", cls.has("multitex"), places, 0, places)
		_support(support, "multitexrev", cls.has("multitexrev"), places, 0, places)
		if places == 0 and _arg("--placed-only") != "":
			continue
		var eg: Array = where.keys()
		eg.sort()
		print("MODEL %s classes=%s%s places=%d near_list=%d gate_places=%d regions=%d e.g. %s" % [path, ",".join(cls),
			" water" if water else "", places, int(near_placed.get(e.type_id, 0)), gates, where.size(), " ".join(eg.slice(0, 6))])
		for line in info["lines"]:
			print("    " + line)
	print("CENSUS %d models" % models)
	# The ambient effects each region's placements carry (every entry,
	# night-only ones too; not the seasonal sets World3D leaves out by
	# default), the busiest first.
	var rk := region_fx.keys()
	rk.sort_custom(func(a, b): return int(region_fx[a]) > int(region_fx[b]))
	var total_fx := 0
	for r in rk:
		total_fx += int(region_fx[r])
	print("FXTOTAL entries=%d regions=%d" % [total_fx, rk.size()])
	for r in rk.slice(0, 40):
		print("REGIONFX %s hosts=%d entries=%d" % [r, region_hosts.get(r, 0), region_fx[r]])
	for r in ["97/168", "98/168", "98/169", "97/169", "91/49", "90/48", "92/135", "89/138", "93/134", "105/79"]:
		print("REGIONFX_AT %s hosts=%d entries=%d" % [r, region_hosts.get(r, 0), region_fx.get(r, 0)])
	var names := classes.keys()
	names.sort()
	for c in names:
		var k: Dictionary = classes[c]
		print("CLASS %-13s models=%d placed_models=%d placements=%d water_models=%d water_placements=%d" % [c,
			k["models"], k["placed"], k["placements"], k["water_models"], k["water_placements"]])
	for m in support:
		var s: Dictionary = support[m]
		print("SUPPORT %-12s placed_models=%d placements=%d before=%d after=%d" % [m, s["models"], s["placements"], s["before"], s["after"]])
	quit(0)

func _support(support: Dictionary, name: String, has: bool, places: int, before: int, after: int) -> void:
	if not has or places == 0:
		return
	if not support.has(name):
		support[name] = {"models": 0, "placements": 0, "before": 0, "after": 0}
	support[name]["models"] += 1
	support[name]["placements"] += places
	support[name]["before"] += before
	support[name]["after"] += after

## One object.ifo model: its classes, whether it names water, and a line per
## live mod. A `.cpd` merges its children's.
func _model_info(data: Pk2Reader, path: String, cache: Dictionary) -> Dictionary:
	var low := path.to_lower()
	if cache.has(low):
		return cache[low]
	var info := {"classes": [], "water": is_water_name(path), "lines": [], "fx": 0}
	cache[low] = info
	var entry := ObjectLoader.find_file(data, path)
	if entry == null:
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
			if s["water"]:
				info["water"] = true
			info["fx"] += int(s["fx"])
			for line in s["lines"]:
				(info["lines"] as Array).append("%s: %s" % [String(sub).get_file(), line])
		return info
	var bytes := data.read_file(entry)
	var obj := BsrReader.parse(bytes)
	if obj == null:
		return info
	var cls: Array = info["classes"]
	var lines: Array = info["lines"]
	var layers: Array = []
	if obj.material_path != "":
		var me := ObjectLoader.find_file(data, obj.material_path)
		if me != null:
			var mat := BmtReader.parse(data.read_file(me))
			if mat != null:
				layers = mat.layers
	var layer_name := func(i: int) -> String:
		if i == 0xFFFFFFFF:
			return "<every material>"
		if i >= 0 and i < layers.size():
			return "%s (%s, word 0x%x)" % [layers[i].layer_name, String(layers[i].texture_path).get_file(), layers[i].texture_word]
		return "?"
	for l in layers:
		if is_water_name(l.layer_name) or is_water_name(l.texture_path):
			info["water"] = true
	# Particles.
	var animates := MapAnimation.clip_entry(obj) != null
	for pm_v in obj.particle_mods:
		var pm := pm_v as BsrReader.ParticleMod
		var efps: Array = []
		for pe in pm.entries:
			efps.append("%s%s" % [(pe as BsrReader.ParticleEntry).efp, "" if (pe as BsrReader.ParticleEntry).mode != 0 else "@" + (pe as BsrReader.ParticleEntry).bone])
			if is_water_name((pe as BsrReader.ParticleEntry).efp):
				info["water"] = true
		if pm.entries.is_empty():
			continue
		if pm.set_kind == BsrReader.SET_BY_CLIP and pm.set_name == "ambient":
			if not cls.has("ambient_fx"):
				cls.append("ambient_fx")
			lines.append("ambient particles w1 %d: %s" % [pm.w1, ", ".join(efps)])
			info["fx"] += pm.entries.size()
		else:
			if not cls.has("clip_fx"):
				cls.append("clip_fx")
			var is_default := pm.set_kind == BsrReader.SET_BY_TYPE and pm.action_type == 0 and pm.set_name == "default"
			if is_default and animates and not cls.has("default_fx"):
				cls.append("default_fx")
			lines.append("particles in set %s %d '%s': %s" % ["type" if pm.set_kind == BsrReader.SET_BY_TYPE else "clip",
				pm.action_type, pm.set_name, ", ".join(efps)])
	# Texture animation and the second stage.
	var mt_materials := {}
	for m in obj.multitex_mods:
		if m["set_kind"] != 2 or not (m["w1"] == 1 or m["w1"] == 2):
			continue
		var c := "multitexrev" if m["rev"] else "multitex"
		if not cls.has(c):
			cls.append(c)
		mt_materials[int(m["material"])] = true
		if is_water_name(m["texture"]):
			info["water"] = true
		lines.append("%s w1 %d material %s op %d texture %s factor 0x%08x" % [c, m["w1"], layer_name.call(int(m["material"])),
			m["op"], m["texture"], m["factor"]])
	for t in obj.texani_mods:
		if t["set_kind"] != 2 or not (t["w1"] == 1 or t["w1"] == 2):
			continue
		var mode := int(t["mode"])
		var c := "texani1" if mode == 1 else "texani0"
		if not cls.has(c):
			cls.append(c)
		if mode == 1:
			var paired := mt_materials.has(int(t["material"])) or mt_materials.has(0xFFFFFFFF) or int(t["material"]) == 0xFFFFFFFF and not mt_materials.is_empty()
			var c2 := "texani1_mt" if paired else "texani1_bare"
			if not cls.has(c2):
				cls.append(c2)
		var r: PackedFloat32Array = t["rates"]
		lines.append("texani mode %d method %d w1 %d material %s rates u(%.3f %.3f %.3f) v(%.3f %.3f %.3f)/s frames %d..%d fps %d grid %dx%d flags %d" % [
			mode, t["method"], t["w1"], layer_name.call(int(t["material"])), r[0], r[4], r[8], r[1], r[5], r[9],
			t["start"], t["end"], t["fps"], t["cols"], t["rows"], t["flags"]])
	for m in obj.material_mods:
		if m["kind"] == BsrReader.MOD_MTRL and m["set_kind"] == 2 and (m["w1"] == 1 or m["w1"] == 2):
			if not cls.has("mtrl"):
				cls.append("mtrl")
			lines.append("mtrl w1 %d material %s %s" % [m["w1"], layer_name.call(int(m["material"])), str(m.get("state", {}))])
	if animates and not cls.has("skeletal"):
		cls.append("skeletal")
	var section = BsrReader.parse_sound_section(bytes, bytes.decode_u32(BsrReader.OFF_PTR_SOUND)) if bytes.size() > BsrReader.OFF_PTR_SOUND + 4 else null
	if section != null:
		var mods: Dictionary = section["mods"]
		if mods.has(BsrReader.MOD_DYVERTEX) or mods.has(BsrReader.MOD_DYJOINT) or mods.has(BsrReader.MOD_DYLATTICE):
			cls.append("dy")
	var seen := {}
	for mp in ([obj.mesh_path] if obj.mesh_path != "" else []) + obj.sub_mesh_paths:
		if seen.has(mp.to_lower()):
			continue
		seen[mp.to_lower()] = true
		if is_water_name(mp):
			info["water"] = true
		var me := ObjectLoader.find_file(data, mp)
		if me == null:
			continue
		var mesh := BmsReader.parse(data.read_file(me))
		if mesh != null and mesh.vertex_motion.size() > 0 and not cls.has("motion"):
			cls.append("motion")
	return info

## Whether `path` contains any of the `+`-separated words of `keys`.
static func _any_in(path: String, keys: String) -> bool:
	var low := path.to_lower()
	for k in keys.split("+", false):
		if low.contains(k):
			return true
	return false
