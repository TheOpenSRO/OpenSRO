extends SceneTree

## Dev tool: reads the per-vertex block that sits between a character
## `.bms`'s bone-name list and the section after it, and tests whether it is
## skinning data.
##
## The question this answers. This project recorded that "no per-vertex
## skinning data exists -- real characters are rigid multi-part assemblies
## instead", and everything built on that: pieces are attached rigidly to
## one bone each, which is why animating a humanoid NPC tears it apart. But
## a character `.bms` carries a **bone name list** ("Bip01 L Hand",
## "Bip01 Spine", ...), and a bone palette is only meaningful if something
## indexes into it.
##
## What it checks. `chinaquest_priest_part1.bms` has 280 vertices, a bone
## list ending at 0x3201, and the next header-declared section at 0x3891 --
## a gap of 1,680 bytes, which is exactly **6 bytes per vertex**. Six bytes
## is the size of a two-bone weight: two `uint8` indices into the palette
## plus one `float32` weight. This decodes the block that way and reports
## whether every index lands inside the palette and every weight inside
## [0, 1], which is what would make it skinning rather than coincidence.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_bms_skin.gd -- \
##     --pk2=/path/Data.pk2 --file="prim\\mesh\\npc\\china\\chinaquest_priest_part1.bms"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var file := _arg("--file")
	if pk2_path == "" or file == "":
		printerr("usage: --pk2=<archive> --file=<path.bms>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	var entry := ObjectLoader.find_file(archive, file)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + file)
	if entry == null:
		printerr("not in archive: ", file)
		quit(1)
		return
	var data := archive.read_file(entry)
	var parsed := BmsReader.parse(data)
	if parsed == null:
		printerr("did not parse")
		quit(1)
		return
	var vertex_count := parsed.vertices.size()

	# The bone palette: a count at the offset header word 0x10 names, then
	# that many length-prefixed names.
	var bone_section := _le_u32(data, 0x10)
	var bone_count := _le_u32(data, bone_section)
	var off := bone_section + 4
	var bones := PackedStringArray()
	for i in range(bone_count):
		if off + 4 > data.size():
			break
		var n := _le_u32(data, off)
		off += 4
		if off + n > data.size():
			break
		bones.append(data.slice(off, off + n).get_string_from_ascii())
		off += n
	print("%s: %d vertices, palette of %d bone(s), names end at 0x%04x" % [
		file.get_file(), vertex_count, bones.size(), off])

	var next_section := _le_u32(data, 0x14)
	var span := next_section - off
	print("  next section (header 0x14) at 0x%04x -- %d bytes for %d vertices = %.2f per vertex" % [
		next_section, span, vertex_count, float(span) / float(maxi(vertex_count, 1))])
	if vertex_count == 0 or span <= 0:
		quit(0)
		return

	# Raw bytes first. The decode below is a hypothesis; this is the data.
	print("  first 96 bytes of the block, as u8:")
	var line := PackedStringArray()
	for i in range(mini(96, data.size() - off)):
		line.append("%3d" % data[off + i])
		if line.size() == 12:
			print("    " + " ".join(line))
			line = PackedStringArray()
	if not line.is_empty():
		print("    " + " ".join(line))

	# The layout, and the test that settles it.
	#
	#   u8  bone0        index into the palette
	#   u16 weight0      65535 == 1.0
	#   u8  bone1        0xFF == no second influence
	#   u16 weight1
	#
	# Six bytes, two influences. The decisive property is that the weights
	# sum to full scale: a vertex split 50/50 reads 32765 + 32765, and one
	# bound to a single bone reads 65535 + 0. Nothing but real weights does
	# that.
	var stride := 6
	const FULL_WEIGHT := 65535.0
	const NO_BONE := 255
	var bad_bone := 0
	var bad_sum := 0
	var two_bone := 0
	var worst_sum_error := 0.0
	for v in range(vertex_count):
		var rec := off + v * stride
		if rec + stride > data.size():
			break
		var b0 := data[rec]
		var w0 := data[rec + 1] | (data[rec + 2] << 8)
		var b1 := data[rec + 3]
		var w1 := data[rec + 4] | (data[rec + 5] << 8)
		if b0 >= bones.size():
			bad_bone += 1
		if b1 != NO_BONE:
			two_bone += 1
			if b1 >= bones.size():
				bad_bone += 1
		var total := float(w0 + w1)
		var err: float = absf(total - FULL_WEIGHT) / FULL_WEIGHT
		worst_sum_error = maxf(worst_sum_error, err)
		if err > 0.01:
			bad_sum += 1
		if v < 6:
			var n0: String = bones[b0] if b0 < bones.size() else "?"
			var n1: String = bones[b1] if b1 < bones.size() else "(none)"
			print("    v%-4d %-16s %.3f  +  %-16s %.3f" % [
				v, n0, float(w0) / FULL_WEIGHT, n1, float(w1) / FULL_WEIGHT])
	print("  %d/%d vertices have an out-of-palette bone index" % [bad_bone, vertex_count])
	print("  %d/%d vertices have weights that do not sum to 1" % [bad_sum, vertex_count])
	print("  %d/%d vertices are influenced by two bones" % [two_bone, vertex_count])
	print("  worst weight-sum error %.5f" % worst_sum_error)
	quit(0)
