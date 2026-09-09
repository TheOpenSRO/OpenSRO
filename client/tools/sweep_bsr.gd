extends SceneTree

## Dev tool: parses every `.bsr` in an archive both ways -- through the
## header's section table and through the legacy forward scan -- and reports
## where they disagree.
##
## This is the sweep docs/TODO.md asked for before routing building-category
## files through the header table. The character path (type 1) already goes
## that way; types 2 and 4 still scan, and the scan is known to return a
## building's first mesh piece twice, because a building carries a duplicate
## reference to that piece ahead of its header-declared mesh section.
##
## The point is to find out whether the header table is safe for every real
## building in the archive, not just the handful checked by hand -- and to
## show what it changes.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_bsr.gd -- \
##     --pk2=/path/Data.pk2 [--limit=0] [--type=2]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
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

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	if pk2_path == "":
		printerr("usage: --pk2=<archive> [--limit=N] [--type=N]")
		quit(2)
		return
	var limit := int(_arg("--limit", "0"))
	var only_type := int(_arg("--type", "-1"))

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	var files: Array = []
	_collect(archive, null, "", files)
	files.sort()
	print("found %d .bsr files" % files.size())

	var by_type := {}
	var checked := 0
	var header_ok := 0
	var header_failed := 0
	var dupes := 0
	var mesh_delta := 0
	var unresolved := 0
	var verify := _arg("--verify", "") != ""

	var examples: Array[String] = []

	for pair in files:
		if limit > 0 and checked >= limit:
			break
		var path: String = pair[0]
		var data: PackedByteArray = archive.read_file(pair[1])
		if data.size() < 0x44:
			continue
		var obj_type := BsrReader._le_u32(data, BsrReader.OFF_TYPE) & 0xFFFF
		by_type[obj_type] = by_type.get(obj_type, 0) + 1
		if only_type >= 0 and obj_type != only_type:
			continue
		checked += 1

		# What the shipping reader returns today.
		var scanned := BsrReader.parse(data)
		if scanned == null:
			continue
		var scanned_paths := scanned.all_mesh_paths()

		# A duplicate in the scanned result is the bug: the same mesh drawn
		# twice, wasting a draw call and z-fighting on any transparent
		# surface.
		var seen := {}
		var duped := false
		for m in scanned_paths:
			var key := m.to_lower()
			if seen.has(key):
				duped = true
			seen[key] = true
		if duped:
			dupes += 1

		# What the header table gives, for the same file.
		var sections = BsrReader.parse_sections(data)
		if sections == null:
			header_failed += 1
			if examples.size() < 10:
				examples.append("HEADER FAILED  %s (type %d)" % [path, obj_type])
			continue
		header_ok += 1
		var header_paths: Array = sections["meshes"]

		# The decisive check: do the header's mesh paths actually name files
		# in the archive? Chaining proves the bytes were read in the right
		# place; resolving proves they mean something. A path that does not
		# resolve would render as nothing.
		if verify:
			for m in header_paths:
				var found := ObjectLoader.find_file(archive, m)
				if found == null:
					found = ObjectLoader.find_file(archive, "res\\" + m)
				if found == null:
					unresolved += 1
					if examples.size() < 10:
						examples.append("UNRESOLVED  %s -> %s" % [path, m])
					break
		if header_paths.size() != scanned_paths.size():
			mesh_delta += 1
			if examples.size() < 10:
				examples.append("%-64s scan %d -> header %d%s" % [
					path, scanned_paths.size(), header_paths.size(), "  (scan had a duplicate)" if duped else ""])

	print("\nobject types across the archive (1 character, 2 building, 4 nature):")
	for t in by_type:
		print("  type %-3d %d files" % [t, by_type[t]])

	print("\nchecked %d file(s)" % checked)
	print("  header table parsed:      %d" % header_ok)
	print("  header table failed:      %d" % header_failed)
	print("  scan returned a duplicate: %d" % dupes)
	print("  mesh count differs:        %d" % mesh_delta)
	if verify:
		print("  header path unresolved:    %d" % unresolved)
	if not examples.is_empty():
		print("\nexamples:")
		for line in examples:
			print("  " + line)
	quit(0)
