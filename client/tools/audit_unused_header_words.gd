extends SceneTree

## Dev tool: for every `.bms` in an archive, reports what the header words
## the reader parses but never uses actually point at.
##
## Why this exists. Three settled conclusions in this project have been
## overturned by re-reading data rather than by new evidence -- the `.bsr`
## offset table was called untrustworthy (it was read one field off), the
## `UV_*` layout fields were called always-identity (three files were
## sampled), and `.bms` was said to carry no per-vertex skinning (the audit
## looked at the vertex record, and the weights are in their own section).
##
## The tell in all three was the same: **a header word parsed into a
## variable and never used.** That is cheap to check, so this checks it.
##
## `BmsReader` reads `hdr[0..5]` and uses 0 (skin), 1 (indices) and 4
## (bounding box). This reports, for 2, 3 and 5, whether they point
## anywhere, how much room there is before the next thing, and what the
## first word there is -- so "an empty section" and "a section full of data
## nobody reads" can be told apart.
##
## Usage:
##   godot4 --headless --path client --script res://tools/audit_unused_header_words.gd -- \
##     --pk2=/path/Data.pk2 [--limit=400]

const UNUSED_WORDS := [2, 3, 5]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

func _collect(archive: Pk2Reader, dir_entry, prefix: String, out: Array) -> void:
	var entries: Array = archive.read_dir() if dir_entry == null else archive.read_dir_at(dir_entry)
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var path: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_collect(archive, e, path, out)
		elif e.name.to_lower().ends_with(".bms"):
			out.append([path, e])

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	if pk2_path == "":
		printerr("usage: --pk2=<archive> [--limit=N]")
		quit(2)
		return
	var limit := int(_arg("--limit", "0"))
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	var files: Array = []
	_collect(archive, null, "", files)
	files.sort()
	print("found %d .bms file(s)" % files.size())

	# Per unused header word: how often it is zero, how often it points
	# somewhere, and the distribution of the first uint32 there.
	var zero := {}
	var pointing := {}
	var first_word_counts := {}
	var examples := {}
	for w in UNUSED_WORDS:
		zero[w] = 0
		pointing[w] = 0
		first_word_counts[w] = {}
		examples[w] = []

	var checked := 0
	for pair in files:
		if limit > 0 and checked >= limit:
			break
		var data: PackedByteArray = archive.read_file(pair[1])
		if data.size() < BmsReader.PREAMBLE_END:
			continue
		checked += 1
		for w in UNUSED_WORDS:
			var ptr := _le_u32(data, BmsReader.HEADER_PTRS_BASE + w * 4)
			if ptr == 0:
				zero[w] += 1
				continue
			if ptr + 4 > data.size():
				continue
			pointing[w] += 1
			var value := _le_u32(data, ptr)
			var counts: Dictionary = first_word_counts[w]
			counts[value] = counts.get(value, 0) + 1
			if value != 0 and (examples[w] as Array).size() < 5:
				(examples[w] as Array).append("%s -> 0x%04x holds %d" % [pair[0], ptr, value])

	print("\nchecked %d file(s)" % checked)
	for w in UNUSED_WORDS:
		print("\nhdr[%d] (header offset 0x%02x):" % [w, BmsReader.HEADER_PTRS_BASE + w * 4])
		print("   zero: %d,  points into the file: %d" % [zero[w], pointing[w]])
		var counts: Dictionary = first_word_counts[w]
		var keys := counts.keys()
		keys.sort()
		var shown := 0
		for k in keys:
			print("      first word %-10d in %d file(s)" % [k, counts[k]])
			shown += 1
			if shown >= 6:
				print("      ... %d more distinct value(s)" % (keys.size() - shown))
				break
		for line in examples[w]:
			print("      e.g. " + line)
	quit(0)
