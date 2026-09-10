extends SceneTree

## Dev tool: prints a `server_dep\silkroad\textdata\*.txt` table with each
## column numbered, so a column index can be read off rather than counted
## by hand.
##
## These tables are UTF-16LE, tab separated, and several of them carry their
## own header row naming every column -- which is the whole reason this is
## worth a tool. `worldmap_mapinfo.txt` names its 22 columns in a mixture of
## Korean and English, and lining those names up against the column indices
## the client's parser reads in order is what decodes the file.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_text_table.gd -- \
##     --pk2=/path/to/Media.pk2 \
##     --file=server_dep/silkroad/textdata/worldmap_mapinfo.txt \
##     [--rows=8] [--grep=Dungeon]
##
## `--rows` limits how many data rows follow each header (default 4);
## `--grep` keeps only lines containing the text.

func _arg(flag: String, fallback := "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var file_path := _arg("--file")
	if pk2_path == "" or file_path == "":
		printerr("usage: --pk2=<archive> --file=<path in archive> [--rows=N] [--grep=TEXT]")
		quit(2)
		return
	var rows_per_section := int(_arg("--rows", "4"))
	var needle := _arg("--grep")
	# Archive paths use backslashes, which do not survive ssh and su to the
	# render box -- each layer eats one. Forward slashes are accepted too.
	file_path = file_path.replace("/", "\\")

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var entry := ObjectLoader.find_file(archive, file_path)
	if entry == null:
		printerr("no ", file_path)
		quit(1)
		return

	var text := _decode(archive.read_file(entry))
	var shown := 0
	for line in text.replace("\r", "").split("\n"):
		if line.strip_edges() == "":
			continue
		if needle != "" and not line.contains(needle):
			continue
		# A header row is one whose first column is not a number: the
		# `#section` lines and the column-name rows both qualify, and both
		# reset the per-section row budget.
		var cols := line.split("\t")
		var is_header := not cols[0].strip_edges().is_valid_int()
		if is_header:
			shown = 0
			print("")
		elif shown >= rows_per_section:
			continue
		else:
			shown += 1
		for i in cols.size():
			var value := cols[i].strip_edges()
			if value != "":
				print("  [%2d] %s" % [i, value])
		print("  --- %d columns" % cols.size())
	quit(0)

static func _decode(data: PackedByteArray) -> String:
	if data.is_empty():
		return ""
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text
