extends SceneTree

## Dev tool (round 720): the particle mods of `.bsr` files, as
## BsrReader.particle_mods reads them (ModDataParticle::vslot_004,
## 0x00c643b0).
##
##   --pk2=<Data.pk2> --files=<path>|<path>...   one block per file: every
##       mod set that carries a particle mod and each entry's mode, effect
##       file, bone, offset, words and rotation
##   --pk2=<Data.pk2> --list=<file>              the same, one path per line
##   --pk2=<Data.pk2> --census                   every `.bsr` in the
##       archive: how many files carry particle mods, by set kind and name,
##       the entry modes, and the files whose entries name a bone
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_bsr_particles.gd -- \
##     --pk2=/path/to/Data.pk2 --files='res\bldg\china\jangan01\cj_portal.bsr'

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a == flag:
			return "1"
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _collect(archive: Pk2Reader, dir_entry, prefix: String, out: Array) -> void:
	var entries: Array = archive.read_dir() if dir_entry == null else archive.read_dir_at(dir_entry)
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var path: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_collect(archive, e, path, out)
		elif e.name.to_lower().ends_with(".bsr"):
			out.append([path, e])

static func describe(pm: BsrReader.ParticleMod) -> String:
	var lines: Array[String] = []
	lines.append("  set %s action %d name '%s' w1 %d, %d entr%s" % [
		"by_type" if pm.set_kind == BsrReader.SET_BY_TYPE else "by_clip", pm.action_type, pm.set_name,
		pm.w1, pm.entries.size(), "y" if pm.entries.size() == 1 else "ies"])
	for e in pm.entries:
		lines.append("    mode %d efp '%s' bone '%s' offset (%.3f, %.3f, %.3f) w4c %d bytes %d %d %d%s" % [
			e.mode, e.efp, e.bone, e.offset.x, e.offset.y, e.offset.z, e.w4c, e.b50, e.b51, e.b52,
			(" rot (%.4f, %.4f, %.4f)" % [e.angles.x, e.angles.y, e.angles.z]) if e.rotated else ""])
	return "\n".join(lines)

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	if pk2_path == "":
		printerr("usage: --pk2=<Data.pk2> (--files=a|b | --census)")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	if _arg("--census") != "":
		_census(archive)
	else:
		var paths := _arg("--files").split("|", false)
		if _arg("--list") != "":
			paths = FileAccess.get_file_as_string(_arg("--list")).split("\n", false)
		for path_v in paths:
			var path := String(path_v).strip_edges()
			if path == "":
				continue
			var entry = ObjectLoader.find_file(archive, path)
			if entry == null:
				print("PARTICLES %s: not found" % path)
				continue
			var data: PackedByteArray = archive.read_file(entry)
			var mods := BsrReader.particle_mods(data)
			var section = BsrReader.parse_sound_section(data, BsrReader._le_u32(data, BsrReader.OFF_PTR_SOUND))
			var sets := ""
			if section != null:
				var names: Array[String] = []
				for s in section["by_clip"]:
					names.append("clip '%s'" % s.name)
				for s in section["by_type"]:
					names.append("type %d '%s'" % [s.action_type, s.name])
				sets = ", ".join(names)
			print("PARTICLES %s: %d particle mod(s); mod section %s; sets [%s]" % [path, mods.size(),
				"parses" if section != null else "DOES NOT PARSE", sets])
			for pm in mods:
				print(describe(pm))
	quit(0)

func _census(archive: Pk2Reader) -> void:
	var files: Array = []
	_collect(archive, null, "", files)
	files.sort()
	var with := 0
	var unparsed := 0
	var by_set := {}
	var by_mode := {}
	var bone_files: Array[String] = []
	var entries := 0
	for pair in files:
		var data: PackedByteArray = archive.read_file(pair[1])
		if data.size() < BsrReader.PREAMBLE_END:
			continue
		var section = BsrReader.parse_sound_section(data, BsrReader._le_u32(data, BsrReader.OFF_PTR_SOUND))
		if section == null:
			unparsed += 1
			continue
		var mods: Array = section["particle_mods"]
		if mods.is_empty():
			continue
		with += 1
		for pm in mods:
			var key := "%s %d '%s'" % ["by_type" if pm.set_kind == BsrReader.SET_BY_TYPE else "by_clip",
				pm.action_type, pm.set_name]
			by_set[key] = int(by_set.get(key, 0)) + 1
			for e in pm.entries:
				entries += 1
				by_mode[e.mode] = int(by_mode.get(e.mode, 0)) + 1
				if e.mode == 0 and bone_files.size() < 30:
					bone_files.append("%s bone '%s'" % [pair[0], e.bone])
	print("PARTICLES CENSUS: %d .bsr, %d with particle mods (%d entries), %d mod sections unparsed" % [
		files.size(), with, entries, unparsed])
	var keys := by_set.keys()
	keys.sort_custom(func(a, b): return by_set[a] > by_set[b])
	for k in keys.slice(0, 40):
		print("  set %s: %d" % [k, by_set[k]])
	print("  entry modes: %s" % str(by_mode))
	for b in bone_files:
		print("  bone entry: %s" % b)
