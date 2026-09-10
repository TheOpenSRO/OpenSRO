extends SceneTree

## Dev tool: for every `.bms` whose `hdr[2]` section carries data, reports
## the record count against the mesh's own counts -- vertices, indices,
## triangles, bones, collision cells -- and dumps the first records as
## floats, as uint32 pairs and as uint16 quads.
##
## `hdr[2]` and `hdr[3]` are the last two header words this project reads
## and never uses, and the same shape -- a header word parsed and ignored --
## is what the `.bsr` offset table, the `UV_*` fields and `.bms` skinning
## each turned out to be hiding. The audit that found them
## (`audit_unused_header_words.gd`) established that 63 of 1,200 meshes
## carry data here, that they are tables, bridges and ships, and that
## `hdr[2]` holds 8-byte records. It did not establish what a record *is*.
##
## The cheapest thing that would say is what the count is a count *of*. A
## count equal to the vertex count means per-vertex data; equal to the
## triangle count means per-face; equal to neither means something with its
## own population. That is a measurement, and it does not require guessing
## from the byte pattern -- which is how the last three structures in this
## format were got wrong before they were got right.
##
## Usage:
##   godot4 --headless --path client --script res://tools/audit_bms_extra_sections.gd -- \
##     --pk2=/path/to/Data.pk2 [--limit=N] [--dump=N]

## hdr[2]'s record size, from the arithmetic on unrelated files: the bytes
## between the section's own count and hdr[3] divide by the count to
## exactly 8.00 every time.
const RECORD_SIZE := 8

const HDR2 := 2
const HDR3 := 3

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _le_u32(b: PackedByteArray, off: int) -> int:
	return b.decode_u32(off) if off >= 0 and off + 4 <= b.size() else 0

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
	var limit := int(_arg("--limit", "0"))
	var dump := int(_arg("--dump", "4"))
	var no_parse := "--no-parse" in OS.get_cmdline_user_args()
	if pk2_path == "":
		printerr("usage: --pk2=<archive> [--limit=N] [--dump=N]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var files: Array = []
	_collect(archive, null, "", files)
	print("found %d .bms file(s)" % files.size())

	var checked := 0
	var carrying := 0
	var matches := {"vertices": 0, "indices": 0, "triangles": 0, "bones": 0, "cells": 0, "none": 0}
	var dumped := 0
	var varied := 0
	var varied_examples: Array[String] = []
	var uniform_values := {}
	var carrying_names: Array[String] = []
	var hdr3_sizes := {}
	var hdr3_counts := {}
	var oversized := 0
	var first_floats := {}
	var second_words := {}

	for pair in files:
		if limit > 0 and checked >= limit:
			break
		var path: String = pair[0]
		var data := archive.read_file(pair[1])
		if data.size() < BmsReader.PREAMBLE_END:
			continue
		checked += 1
		var ptr2 := _le_u32(data, BmsReader.HEADER_PTRS_BASE + HDR2 * 4)
		if ptr2 == 0 or ptr2 + 4 > data.size():
			continue
		var count := _le_u32(data, ptr2)
		if count == 0:
			continue
		# A section that does not fit inside the file is not a section: at
		# least one .bms in a real Data.pk2 has a header word pointing
		# somewhere that reads as a count of four billion, and taking that
		# at face value exhausts memory before anything is learned.
		if ptr2 + 4 + count * RECORD_SIZE > data.size():
			oversized += 1
			continue
		carrying += 1

		# Parsing the geometry is only needed for the count comparison, and
		# it is what makes a full sweep unsafe: at least one .bms in a real
		# Data.pk2 declares an index array of 4,279,369,728 triangles, and
		# BmsReader allocates before it validates. --no-parse collects the
		# names without touching the geometry.
		var mesh: BmsReader.ParsedMesh = null if no_parse else BmsReader.parse(data)
		var vertices := 0
		var indices := 0
		var bones := 0
		if mesh != null:
			vertices = mesh.vertices.size()
			indices = mesh.indices.size()
			bones = mesh.bone_names.size() if mesh.get("bone_names") != null else 0
		var collision: BmsReader.CollisionMesh = null if no_parse else BmsReader.parse_collision(data)
		var cells := collision.cells.size() if collision != null else 0
		var triangles: int = indices / 3

		var what := "none"
		if count == vertices:
			what = "vertices"
		elif count == indices:
			what = "indices"
		elif count == triangles:
			what = "triangles"
		elif bones > 0 and count == bones:
			what = "bones"
		elif cells > 0 and count == cells:
			what = "cells"
		matches[what] = int(matches[what]) + 1

		# How much variety a file's records carry. All-identical records say
		# something different from records that differ per vertex.
		var distinct := {}
		for i in range(count):
			var off := ptr2 + 4 + i * RECORD_SIZE
			if off + RECORD_SIZE > data.size():
				break
			distinct["%d:%d" % [data.decode_u32(off), data.decode_u32(off + 4)]] = true
			# The global distribution of both words, read the way the values
			# themselves suggest: the first as a float (1036831949 is
			# 0x3DCCCCCD, which is 0.1f), the second as an integer.
			first_floats["%.4f" % data.decode_float(off)] = int(
				first_floats.get("%.4f" % data.decode_float(off), 0)) + 1
			second_words[data.decode_u32(off + 4)] = int(
				second_words.get(data.decode_u32(off + 4), 0)) + 1
		if distinct.size() > 1:
			varied += 1
			if varied_examples.size() < 6:
				var keys := distinct.keys()
				keys.sort()
				varied_examples.append("%s: %d record(s), %d distinct %s" % [
					path.get_file(), count, distinct.size(),
					str(keys.slice(0, 6))])
		else:
			var only := distinct.keys()
			var key: String = str(only[0]) if not only.is_empty() else "-"
			uniform_values[key] = int(uniform_values.get(key, 0)) + 1

		carrying_names.append(path)
		# hdr[3]'s own record size, from the bytes between it and whatever
		# follows -- the end of the file, in every sample seen.
		var ptr3b := _le_u32(data, BmsReader.HEADER_PTRS_BASE + HDR3 * 4)
		if ptr3b > 0 and ptr3b + 4 <= data.size():
			var count3 := _le_u32(data, ptr3b)
			if count3 > 0:
				var span := data.size() - ptr3b - 4
				hdr3_sizes["%.2f" % (float(span) / float(count3))] = int(
					hdr3_sizes.get("%.2f" % (float(span) / float(count3)), 0)) + 1
				hdr3_counts[count3 == count] = int(hdr3_counts.get(count3 == count, 0)) + 1

		if dumped < dump:
			dumped += 1
			var ptr3 := _le_u32(data, BmsReader.HEADER_PTRS_BASE + HDR3 * 4)
			print("\n=== %s" % path)
			print("   hdr[2] at 0x%04x count %d;  hdr[3] at 0x%04x;  %d bytes between = %.2f per record" % [
				ptr2, count, ptr3, ptr3 - ptr2 - 4,
				float(ptr3 - ptr2 - 4) / float(count) if count > 0 else 0.0])
			print("   mesh: %d vertices, %d indices (%d triangles), %d bone(s), %d collision cell(s) -> count matches %s" % [
				vertices, indices, triangles, bones, cells, what])
			for i in range(mini(6, count)):
				var off := ptr2 + 4 + i * 8
				if off + 8 > data.size():
					break
				print("     [%2d] f32 %12.4f %12.4f | u32 %10d %10d | u16 %6d %6d %6d %6d" % [
					i, data.decode_float(off), data.decode_float(off + 4),
					data.decode_u32(off), data.decode_u32(off + 4),
					data.decode_u16(off), data.decode_u16(off + 2),
					data.decode_u16(off + 4), data.decode_u16(off + 6)])

	print("\nchecked %d file(s); %d carry an hdr[2] section (%d skipped: the section does not fit the file)" % [
		checked, carrying, oversized])
	print("what the record count equals:")
	for key in matches:
		print("   %-10s %d" % [key, int(matches[key])])
	print("")
	print("%d file(s) carry more than one distinct record; %d are uniform" % [
		varied, carrying - varied])
	for line in varied_examples:
		print("   varied: %s" % line)
	var uniform_keys := uniform_values.keys()
	uniform_keys.sort_custom(func(a, b): return int(uniform_values[a]) > int(uniform_values[b]))
	for k in uniform_keys.slice(0, 8):
		print("   uniform value %-16s in %d file(s)" % [k, int(uniform_values[k])])
	print("")
	print("every hdr[2] record's first word, read as a float:")
	var ff := first_floats.keys()
	ff.sort_custom(func(a, b): return int(first_floats[a]) > int(first_floats[b]))
	for k in ff.slice(0, 12):
		print("   %-10s in %d record(s)" % [k, int(first_floats[k])])
	print("   (%d distinct value(s) in total)" % ff.size())
	print("every hdr[2] record's second word, read as an integer:")
	var sw := second_words.keys()
	sw.sort_custom(func(a, b): return int(second_words[a]) > int(second_words[b]))
	for k in sw.slice(0, 12):
		print("   %-10s in %d record(s)" % [str(k), int(second_words[k])])
	print("   (%d distinct value(s) in total)" % sw.size())
	print("")
	print("hdr[3]: bytes per record, taken as (file end - section start - 4) / count:")
	var size_keys := hdr3_sizes.keys()
	size_keys.sort_custom(func(a, b): return int(hdr3_sizes[a]) > int(hdr3_sizes[b]))
	for k in size_keys.slice(0, 6):
		print("   %-8s in %d file(s)" % [k, int(hdr3_sizes[k])])
	print("   hdr[3] count equals hdr[2] count: %s" % str(hdr3_counts))
	print("")
	print("what the %d carrying files are, by leading name fragment:" % carrying_names.size())
	var kinds := {}
	for n in carrying_names:
		var base := n.get_file().get_basename().to_lower()
		var head := base.split("_")
		var key: String = head[0] if head.size() > 0 else base
		kinds[key] = int(kinds.get(key, 0)) + 1
	var kind_keys := kinds.keys()
	kind_keys.sort_custom(func(a, b): return int(kinds[a]) > int(kinds[b]))
	for k in kind_keys.slice(0, 14):
		print("   %-16s %d" % [k, int(kinds[k])])
	quit(0)
