extends SceneTree

## Dev tool: the parse-all check of the .bsr sound section
## (docs/protocol/BSR_FORMAT.md, "Sound tracks"). Reads every character
## `.bsr` (object type 0 or 1) in an archive through
## BsrReader.parse_sound_section -- the reader the client runs -- and
## reports whether each section is consumed exactly: it must end at the end
## of the file, or where the attachment block the client reads next
## (BsrReader.attachable_tail_end) begins and itself ends at the end of the
## file. Everything else is listed.
##
## With --durations it also parses each type-keyed set's animation and
## counts the tracks whose key time lies past the clip's own length -- the
## check on the millisecond reading of the key times.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_bsr_sound.gd -- \
##     --pk2=/path/Data.pk2 [--durations]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a == flag:
			return "1"
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _collect(archive: Pk2Reader, dir_entry, prefix: String, out: Array, index: Dictionary) -> void:
	var entries: Array = archive.read_dir() if dir_entry == null else archive.read_dir_at(dir_entry)
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var path: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_collect(archive, e, path, out, index)
		else:
			index[path.to_lower()] = e
			if e.name.to_lower().ends_with(".bsr"):
				out.append([path, e])

func _bump(d: Dictionary, k, n: int = 1) -> void:
	d[k] = int(d.get(k, 0)) + n

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	if pk2_path == "":
		printerr("usage: --pk2=<Data.pk2> [--durations]")
		quit(2)
		return
	var durations := _arg("--durations") != ""
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var files: Array = []
	var index := {}
	_collect(archive, null, "", files, index)
	files.sort()

	var counts := {}
	var mods := {}
	var names := {}
	var tails := {}
	var failures: Array[String] = []
	var odd_tails: Array[String] = []
	var ban_cache := {}
	var past_end := 0
	var within := 0
	var past_examples: Array[String] = []
	for pair in files:
		var path: String = pair[0]
		var data: PackedByteArray = archive.read_file(pair[1])
		if data.size() < BsrReader.PREAMBLE_END:
			continue
		var obj_type := BsrReader._le_u32(data, BsrReader.OFF_TYPE) & 0xFFFF
		if obj_type != BsrReader.TYPE_PLAYER_CHARACTER and obj_type != BsrReader.TYPE_CHARACTER:
			continue
		_bump(counts, "character files")
		var section = BsrReader.parse_sound_section(data, BsrReader._le_u32(data, BsrReader.OFF_PTR_SOUND))
		if section == null:
			_bump(counts, "section does not parse")
			failures.append("%s (%d bytes)" % [path, data.size()])
			continue
		_bump(counts, "section parses")
		var end: int = section["end"]
		if end == data.size():
			_bump(tails, "ends at EOF")
		else:
			var tail_end := BsrReader.attachable_tail_end(data, end)
			if tail_end == data.size():
				_bump(tails, "attachment block, then EOF")
			else:
				_bump(tails, "other trailing bytes")
				odd_tails.append("%s: %d byte(s) after the section: %s" % [path, data.size() - end, data.slice(end, mini(end + 24, data.size())).hex_encode()])
		for k in section["mods"]:
			_bump(mods, "0x%05x" % int(k), int(section["mods"][k]))
		_bump(counts, "sets by clip", (section["by_clip"] as Array).size())
		_bump(counts, "sets by type", (section["by_type"] as Array).size())
		for list_name in ["by_clip", "by_type"]:
			for s in section[list_name]:
				var sset := s as BsrReader.SoundSet
				_bump(counts, "flag-0 tracks", sset.empty_tracks)
				for t in sset.tracks:
					var tr := t as BsrReader.SoundTrack
					_bump(counts, "tracks (%s)" % list_name)
					var handled := AnimSounds.HANDLERS.has(tr.name)
					_bump(names, "%s %s%s" % [list_name, tr.name, "" if handled else " [no handler]"])
		if durations:
			var parsed := BsrReader.parse(data)
			if parsed == null:
				continue
			for s in section["by_type"]:
				var sset := s as BsrReader.SoundSet
				if sset.tracks.is_empty():
					continue
				var entry := parsed.animation_entry_for(sset.action_type, sset.name)
				if entry == null or parsed.animation_group_for(sset.action_type, sset.name) != sset.name:
					continue
				var key := entry.path.to_lower()
				if not ban_cache.has(key):
					var e = index.get(key, index.get("res\\" + key))
					var anim: BanReader.ParsedAnimation = null
					if e != null:
						anim = BanReader.parse(archive.read_file(e))
					ban_cache[key] = anim.duration_ms if anim != null else -1
				var dur: int = ban_cache[key]
				if dur < 0:
					continue
				for t in sset.tracks:
					if (t as BsrReader.SoundTrack).key_ms > dur:
						past_end += 1
						if past_examples.size() < 12:
							past_examples.append("%s %d:%s %s at %d > clip %d" % [path.get_file(), sset.action_type, sset.name, t.name, t.key_ms, dur])
					else:
						within += 1

	print("SOUNDSWEEP counts: ", counts)
	print("SOUNDSWEEP after the section: ", tails)
	print("SOUNDSWEEP mod kinds: ", mods)
	var sorted_names := names.keys()
	sorted_names.sort_custom(func(a, b): return int(names[a]) > int(names[b]))
	for n in sorted_names:
		print("SOUNDSWEEP name %6d  %s" % [names[n], n])
	for f in failures:
		print("SOUNDSWEEP does not parse: ", f)
	for t in odd_tails:
		print("SOUNDSWEEP odd tail: ", t)
	if durations:
		print("SOUNDSWEEP key times within their clip: %d, past its end: %d" % [within, past_end])
		for e in past_examples:
			print("SOUNDSWEEP past end: ", e)
	quit(0)
