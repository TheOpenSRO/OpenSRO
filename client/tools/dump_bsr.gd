extends SceneTree

## Dev tool: dumps a `.bsr` file's real structure -- every plausible
## length-prefixed string with its offset, and the raw 32-bit words in the
## gaps between them.
##
## The gaps are the point. `BsrReader` was written against scenery `.bsr`
## files, where scanning for the first ".bms"/".bmt" string is enough. A
## character `.bsr` (NPCs, monsters and the player's own body all use the
## same format) carries several meshes plus `.bsk`/`.ban` references, and
## the only way to read those correctly rather than by pattern-matching
## file extensions is to know which word is the count in front of each
## list. Printing the gap words next to the strings is what makes those
## counts readable.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_bsr.gd -- \
##     --pk2=/path/Data.pk2 --file="npc\\npc\\chinaquest_priest.bsr"

const MAX_PATH_LEN := 512

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

func _plausible(b: PackedByteArray) -> bool:
	if b.size() == 0:
		return false
	for c in b:
		var alnum := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
		var extra := c == 92 or c == 46 or c == 95 or c == 45 or c == 32
		if not (alnum or extra):
			return false
	return true

## Prints every 32-bit word in [from, to), so a list count sitting just
## before a run of strings is visible instead of inferred.
func _dump_gap(data: PackedByteArray, from: int, to: int) -> void:
	if to <= from:
		return
	var words: Array[String] = []
	var pos := from
	while pos + 4 <= to:
		words.append("%d" % _le_u32(data, pos))
		pos += 4
	var tail := to - pos
	var note := ""
	if tail > 0:
		note = " (+%d loose byte(s))" % tail
	print("    gap 0x%04x..0x%04x  words: %s%s" % [from, to, ", ".join(words), note])

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var file := _arg("--file")
	if pk2_path == "" or file == "":
		printerr("usage: --pk2=<Data.pk2> --file=<path\\inside.bsr>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	# object.ifo spells these with a "res\" prefix the server tables omit,
	# so accept either spelling rather than making the caller guess.
	var entry := ObjectLoader.find_file(archive, file)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + file)
	if entry == null:
		printerr("not in archive: ", file)
		quit(1)
		return
	var data := archive.read_file(entry)
	if data.is_empty():
		printerr("empty: ", file)
		quit(1)
		return

	print("%s -- %d bytes" % [file, data.size()])
	# Strings are found by scanning every byte offset rather than by
	# walking the format, because walking it is exactly what isn't known
	# yet. Overlapping false positives are filtered by only accepting a
	# match that starts at or after the end of the last one.
	var pos := 0
	var last_end := 0
	while pos + 4 <= data.size():
		var n := _le_u32(data, pos)
		if n > 0 and n <= MAX_PATH_LEN and pos + 4 + n <= data.size():
			var candidate := data.slice(pos + 4, pos + 4 + n)
			if _plausible(candidate) and pos >= last_end:
				_dump_gap(data, last_end, pos)
				print("  off 0x%04x len %3d  %s" % [pos, n, candidate.get_string_from_ascii()])
				last_end = pos + 4 + n
				pos = last_end
				continue
		pos += 1
	_dump_gap(data, last_end, data.size())
	quit(0)
