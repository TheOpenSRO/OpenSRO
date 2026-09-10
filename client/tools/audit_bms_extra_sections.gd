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

## hdr[3]'s record size, read off the bytes: two uint32s and a float32.
const LINK_REC_SIZE := 12

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
	var hdr3_fits := {}
	var hdr3_indices := {}
	var link_records := 0
	var leftovers := {}
	var tail_sizes := {}
	var tail_counts := {}
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
		var probe := BmsReader.parse(data) if not no_parse else null
		var mesh_vertices := probe.vertices.size() if probe != null else -1
		var mesh_indices := probe.indices.size() if probe != null else -1
		# hdr[3]'s record size, from where its section actually ends rather
		# than from the end of the file. Every other section start in the
		# header is a candidate boundary; the nearest one above hdr[3] is
		# where it stops. This is the same chaining that cracked the .bsr
		# section table, and computing against the file end instead is what
		# made hdr[3]'s record size look like a fraction.
		var ptr3b := _le_u32(data, BmsReader.HEADER_PTRS_BASE + HDR3 * 4)
		if ptr3b > 0 and ptr3b + 4 <= data.size():
			var count3 := _le_u32(data, ptr3b)
			if count3 > 0 and count3 < data.size():
				var section_end := data.size()
				for w in range(6):
					var other := _le_u32(data, BmsReader.HEADER_PTRS_BASE + w * 4)
					if other > ptr3b and other < section_end:
						section_end = other
				var collision_ptr := _le_u32(data, BmsReader.COLLISION_PTR_OFFSET)
				if collision_ptr > ptr3b and collision_ptr < section_end:
					section_end = collision_ptr
				var span := section_end - ptr3b - 4
				hdr3_sizes["%.2f" % (float(span) / float(count3))] = int(
					hdr3_sizes.get("%.2f" % (float(span) / float(count3)), 0)) + 1
				# Does 4 + count * 12 land exactly on the next section?
				hdr3_fits[span == count3 * LINK_REC_SIZE] = int(
					hdr3_fits.get(span == count3 * LINK_REC_SIZE, 0)) + 1
				# And are both words of every record a vertex index?
				var in_range := true
				var lengths := 0
				for k in range(count3):
					var lo := ptr3b + 4 + k * LINK_REC_SIZE
					if lo + LINK_REC_SIZE > data.size():
						in_range = false
						break
					if data.decode_u32(lo) >= count or data.decode_u32(lo + 4) >= count:
						in_range = false
						break
					var d := data.decode_float(lo + 8)
					if d <= 0.0 or d > 10000.0 or is_nan(d):
						in_range = false
						break
					lengths += 1
				hdr3_indices[in_range] = int(hdr3_indices.get(in_range, 0)) + 1
				if in_range:
					link_records += lengths
					# What is left of the section after the links, and
					# whether it reads as another count-prefixed block.
					var after := ptr3b + 4 + count3 * LINK_REC_SIZE
					var leftover := section_end - after
					leftovers[leftover] = int(leftovers.get(leftover, 0)) + 1
					if after + 4 <= data.size():
						var count4 := data.decode_u32(after)
						var tail := section_end - after - 4
						if count4 > 0:
							tail_sizes["%.2f" % (float(tail) / float(count4))] = int(
								tail_sizes.get("%.2f" % (float(tail) / float(count4)), 0)) + 1
							tail_counts[count4 == count3] = int(
								tail_counts.get(count4 == count3, 0)) + 1

		if dumped < dump:
			dumped += 1
			var ptr3 := _le_u32(data, BmsReader.HEADER_PTRS_BASE + HDR3 * 4)
			print("\n=== %s" % path)
			print("   hdr[2] at 0x%04x count %d;  hdr[3] at 0x%04x;  %d bytes between = %.2f per record" % [
				ptr2, count, ptr3, ptr3 - ptr2 - 4,
				float(ptr3 - ptr2 - 4) / float(count) if count > 0 else 0.0])
			print("   mesh: %d vertices, %d indices (%d triangles), %d bone(s), %d collision cell(s) -> count matches %s" % [
				vertices, indices, triangles, bones, cells, what])
			var links := _le_u32(data, ptr3)
			var tail_at := ptr3 + 4 + links * LINK_REC_SIZE
			print("   hdr[3] at 0x%04x: %d link(s), records end at 0x%04x, file ends at 0x%04x (%d bytes of trailer)" % [
				ptr3, links, tail_at, data.size(), data.size() - tail_at])
			print("   trailer, first 16 words:")
			for j in range(16):
				var t := tail_at + j * 4
				if t + 4 > data.size():
					break
				print("     +%3d  u32 %11d   f32 %14.5f   u16 %6d %6d" % [
					j * 4, data.decode_u32(t), data.decode_float(t),
					data.decode_u16(t), data.decode_u16(t + 2)])
			print("   hdr[3] raw, first 12 words:")
			for j in range(12):
				var o := ptr3 + j * 4
				if o + 4 > data.size():
					break
				print("     +%3d  u32 %11d   f32 %14.5f   u16 %6d %6d" % [
					j * 4, data.decode_u32(o), data.decode_float(o),
					data.decode_u16(o), data.decode_u16(o + 2)])
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
	print("   4 + count * 12 lands exactly on the next section: %s" % str(hdr3_fits))
	print("   every record is (vertex index, vertex index, positive float): %s" % str(hdr3_indices))
	print("   %d link record(s) read in total" % link_records)
	print("   bytes left in the section after the links:")
	var lo_keys := leftovers.keys()
	lo_keys.sort_custom(func(a, b): return int(leftovers[a]) > int(leftovers[b]))
	for k in lo_keys.slice(0, 6):
		print("      %-8s in %d file(s)" % [str(k), int(leftovers[k])])
	print("      (%d distinct leftover size(s))" % lo_keys.size())
	print("   reading the leftover as another count + records:")
	var ts := tail_sizes.keys()
	ts.sort_custom(func(a, b): return int(tail_sizes[a]) > int(tail_sizes[b]))
	for k in ts.slice(0, 6):
		print("      %-8s bytes per record, in %d file(s)" % [k, int(tail_sizes[k])])
	print("      that second count equals the link count: %s" % str(tail_counts))
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
