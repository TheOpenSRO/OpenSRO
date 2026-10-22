extends SceneTree

## Dev tool (round 809): the particle mods of every CHARACTER `.bsr` (object
## type 0 or 1) in an archive, by top folder (Res\mob, Res\npc, Res\COS, ...):
## how many files carry an `ambient` set, by-type sets (by action type) and
## other by-clip (named) sets, the entry modes, and with --files one line per
## file listing its sets. BsrReader.particle_mods is the reader.
##
##   godot4 --headless --path client --script res://tools/census_char_particles.gd -- \
##     --pk2=/path/Data.pk2 [--files]

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

func _bump(d: Dictionary, k, n: int = 1) -> void:
	d[k] = int(d.get(k, 0)) + n

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		quit(2)
		return
	var files: Array = []
	_collect(archive, null, "", files)
	files.sort()
	var per_file := _arg("--files") != ""
	var folders := {}
	for pair in files:
		var data: PackedByteArray = archive.read_file(pair[1])
		if data.size() < BsrReader.PREAMBLE_END:
			continue
		var t := data.decode_u16(0x40)
		if t != 0 and t != 1:
			continue
		var parts := String(pair[0]).split("\\")
		var folder := ("%s\\%s" % [parts[0], parts[1]]).to_lower() if parts.size() > 2 else String(pair[0]).to_lower()
		if not folders.has(folder):
			folders[folder] = {"files": 0, "with": 0, "ambient": 0, "types": {}, "named": {}, "modes": {},
				"amb_entries": 0, "type_entries": 0, "w4c_nonzero_type": 0, "w4c_nonzero_amb": 0, "glow": 0, "night": 0}
		var f: Dictionary = folders[folder]
		f["files"] += 1
		var mods := BsrReader.particle_mods(data)
		if mods.is_empty():
			continue
		f["with"] += 1
		var line: PackedStringArray = []
		var has_amb := false
		for pm in mods:
			var m := pm as BsrReader.ParticleMod
			for e in m.entries:
				_bump(f["modes"], e.mode)
				if e.b50 != 0:
					f["glow"] += 1
				if e.b51 & 1:
					f["night"] += 1
			if m.set_kind == BsrReader.SET_BY_TYPE:
				_bump(f["types"], m.action_type)
				f["type_entries"] += m.entries.size()
				for e in m.entries:
					if e.w4c != 0:
						f["w4c_nonzero_type"] += 1
				line.append("type%d/%s:%d" % [m.action_type, m.set_name, m.entries.size()])
			elif m.set_name == "ambient":
				has_amb = true
				f["amb_entries"] += m.entries.size()
				for e in m.entries:
					if e.w4c != 0:
						f["w4c_nonzero_amb"] += 1
				line.append("ambient:%d" % m.entries.size())
			else:
				_bump(f["named"], m.set_name)
				line.append("clip'%s':%d" % [m.set_name, m.entries.size()])
		if has_amb:
			f["ambient"] += 1
		if per_file:
			print("CHARFX\t%s\t%s" % [pair[0], " ".join(line)])
	for k in folders.keys():
		var f: Dictionary = folders[k]
		print("FOLDER %s: %d char .bsr, %d with particle mods, %d with ambient (%d entries, %d w4c!=0), by-type sets %s (%d entries, %d w4c!=0), named sets %s, modes %s, glow %d, night %d" % [
			k, f["files"], f["with"], f["ambient"], f["amb_entries"], f["w4c_nonzero_amb"], str(f["types"]),
			f["type_entries"], f["w4c_nonzero_type"], str(f["named"]), str(f["modes"]), f["glow"], f["night"]])
	quit(0)
