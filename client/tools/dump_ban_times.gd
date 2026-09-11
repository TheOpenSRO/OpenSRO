extends SceneTree
## Dev tool: prints the timing a `.ban` file carries -- the three header
## words, the per-keyframe table BanReader used to skip, and each bone's
## keyframe count -- for every animation a character `.bsr` names, so the
## playback rate can be read off the files instead of guessed.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_ban_times.gd -- \
##     --pk2=/path/Data.pk2 --file="char\\china\\chinaman_fighter.bsr" [--limit=N]
##   godot4 --headless --path client --script res://tools/dump_ban_times.gd -- \
##     --pk2=/path/Data.pk2 --ban="prim\\anim\\...\\x.ban"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

## Walks the header by hand, so nothing the reader assumes is assumed here.
func _describe(path: String, data: PackedByteArray) -> String:
	if data.size() < 24 or data.slice(0, 12).get_string_from_ascii() != "JMXVBAN 0102":
		return "%s: not a JMXVBAN 0102 file (%d bytes)" % [path, data.size()]
	var off := 12
	var w0 := _le_u32(data, off)
	var w1 := _le_u32(data, off + 4)
	off += 8
	var name_len := _le_u32(data, off)
	off += 4
	var name := data.slice(off, off + name_len).get_string_from_ascii()
	off += name_len
	var h1 := _le_u32(data, off)
	var h2 := _le_u32(data, off + 4)
	var h3 := _le_u32(data, off + 8)
	off += 12
	var count := _le_u32(data, off)
	off += 4
	var times := PackedInt32Array()
	for i in range(count):
		times.append(_le_u32(data, off + i * 4))
	off += count * 4
	var bone_count := _le_u32(data, off)
	off += 4
	var kf_counts := {}
	for i in range(bone_count):
		var bl := _le_u32(data, off)
		off += 4 + bl
		var kf := _le_u32(data, off)
		off += 4 + kf * 28
		kf_counts[kf] = kf_counts.get(kf, 0) + 1
	var ascending := true
	for i in range(1, times.size()):
		if times[i] <= times[i - 1]:
			ascending = false
	var shown := times.slice(0, mini(6, times.size()))
	var tail := "" if times.size() <= 6 else " .. %d" % times[times.size() - 1]
	return "%s | %s | pre-name words %d %d | header %d %d %d | table %d entries%s: %s%s | bones %d, keyframes per bone %s | ends at %d of %d bytes" % [
		path.get_file(), name, w0, w1, h1, h2, h3, count, "" if ascending else " NOT ascending",
		str(shown), tail, bone_count, str(kf_counts), off, data.size()]

func _init() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("cannot open --pk2")
		quit(1)
		return
	var single := _arg("--ban")
	var paths: Array[String] = []
	if single != "":
		paths.append(single)
	else:
		var bsr_entry := ObjectLoader.find_file(archive, _arg("--file"))
		if bsr_entry == null:
			bsr_entry = ObjectLoader.find_file(archive, "res\\" + _arg("--file"))
		if bsr_entry == null:
			printerr("--file not found in the archive")
			quit(1)
			return
		var parsed := BsrReader.parse(archive.read_file(bsr_entry))
		if parsed == null:
			printerr("--file did not parse as a .bsr")
			quit(1)
			return
		paths.assign(parsed.animation_paths)
	var limit := int(_arg("--limit")) if _arg("--limit") != "" else paths.size()
	var shown := 0
	for path in paths:
		if shown >= limit:
			break
		var entry := ObjectLoader.find_file(archive, path)
		if entry == null:
			entry = ObjectLoader.find_file(archive, "res\\" + path)
		if entry == null:
			print("%s: not in the archive" % path)
			continue
		print(_describe(path, archive.read_file(entry)))
		shown += 1
	quit(0)
