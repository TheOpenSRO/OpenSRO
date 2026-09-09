extends SceneTree

## Dev tool: dumps a `.bms` file's header words and every plausible
## length-prefixed string in it.
##
## Written to settle one question: **does a character mesh name the bones it
## is weighted to?** A skinned mesh needs a bone palette -- the indices in
## its vertices mean nothing without a list saying which skeleton bone each
## one is. If a character `.bms` carries a list of names like "Bip01 Spine",
## it is skinned and this project's "no per-vertex skinning data exists"
## conclusion is wrong. If it carries none, that conclusion stands on
## something much stronger than counting bytes in the vertex record.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_bms_strings.gd -- \
##     --pk2=/path/Data.pk2 --file="prim\\mesh\\npc\\china\\chinaquest_priest_part1.bms"

const MAX_STR := 128

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
		# Bone names carry spaces and digits ("Bip01 L Forearm"), paths
		# carry backslashes and dots.
		var ok := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
		ok = ok or c == 92 or c == 46 or c == 95 or c == 45 or c == 32
		if not ok:
			return false
	return true

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var file := _arg("--file")
	if pk2_path == "" or file == "":
		printerr("usage: --pk2=<archive> --file=<path\\inside.bms>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var entry := ObjectLoader.find_file(archive, file)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + file)
	if entry == null:
		printerr("not in archive: ", file)
		quit(1)
		return
	var data := archive.read_file(entry)

	var parsed := BmsReader.parse(data)
	print("%s -- %d bytes" % [file.get_file(), data.size()])
	if parsed != null:
		print("  parsed: %d vertices, %d indices, material %s" % [
			parsed.vertices.size(), parsed.indices.size(), parsed.material_name])

	# Header words, where a section pointer would live.
	var words := PackedStringArray()
	var i := 0
	while i < 0x60 and i + 4 <= data.size():
		words.append("%d:%d" % [i, _le_u32(data, i)])
		i += 4
	print("  header: %s" % ", ".join(words))

	# Every plausible length-prefixed string, with its offset.
	print("  strings:")
	var pos := 0
	var last_end := 0
	var shown := 0
	while pos + 4 <= data.size():
		var n := _le_u32(data, pos)
		if n > 0 and n <= MAX_STR and pos + 4 + n <= data.size() and pos >= last_end:
			var candidate := data.slice(pos + 4, pos + 4 + n)
			if _plausible(candidate):
				print("    off 0x%04x len %3d  %s" % [pos, n, candidate.get_string_from_ascii()])
				last_end = pos + 4 + n
				pos = last_end
				shown += 1
				if shown >= 80:
					print("    ... (stopping at 80)")
					break
				continue
		pos += 1
	if shown == 0:
		print("    (none)")
	quit(0)
