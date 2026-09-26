extends SceneTree

## Box tool: reads every `res_ui\*.2dt` in a real Media.pk2 with TwoDtReader
## and checks it the way the client's loader would take it. Nothing is written
## and no game data leaves the box. For each file it checks:
##
## - the size is exactly 4 + count * 976 (the reader refuses anything else);
## - exactly one record carries the root flag, and it is record 0;
## - every record's (parent, grandparent) pair resolves to an earlier record
##   of the same file (TwoDtReader's rule, 0x48cb00), and how many resolve to
##   nothing (left under the root) or to more than one;
## - the four string fields the reader decodes (name, base, texture, text
##   id) are plain ASCII;
## - every texture piece TwoDtBuilder derives exists in the archive. Required
##   pieces (a frame's eight, a bar's three, a tab's on / off, a check box's
##   on / off, a button's own texture, a plain texture) are counted apart from
##   the optional ones (a button's _focus / _press / _disable, a tab's
##   disable), which the client loads when present.
##
## It also measures, for the textured statics, slots and plain windows, how
## many are drawn at a rect other than their texture's own size (the builder
## stretches those; the client's own drawing of them is not read).
##
##   client/tools/remote_godot.sh script '--script res://tools/check_2dt_files.gd -- --pk2=/opt/sro-files/client/Media.pk2'
## Add `--list-off-size=1` to print each of those controls.

const RES_UI := "res_ui"
const FRAME8 := ["left_up", "mid_up", "right_up", "left_side", "right_side", "left_down", "mid_down", "right_down"]
const STRETCH6 := ["left_up", "left_side", "left_down", "right_up", "right_side", "right_down"]
const LATTICE4 := ["left_up", "right_up", "left_down", "right_down"]

var _archive: Pk2Reader
var _exists := {}
var _ui: UiBuilder

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _has(path: String) -> bool:
	var key := path.to_lower()
	if not _exists.has(key):
		_exists[key] = ObjectLoader.find_file(_archive, path) != null
	return _exists[key]

func _init() -> void:
	var pk2_path := _arg("--pk2", "/opt/sro-files/client/Media.pk2")
	var list_off_size := _arg("--list-off-size", "") != ""
	_archive = Pk2Reader.open(pk2_path)
	if _archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	_ui = UiBuilder.new(_archive, null)
	var dir := ObjectLoader.find_file(_archive, RES_UI)
	if dir == null:
		printerr("no res_ui directory")
		quit(1)
		return
	var names := PackedStringArray()
	var entries := {}
	for entry in _archive.read_dir_at(dir):
		if entry.is_dir or not entry.name.to_lower().ends_with(".2dt"):
			continue
		names.append(entry.name)
		entries[entry.name] = entry
	names.sort()

	var totals := {"files": 0, "records": 0, "bad_size": 0, "bad_root": 0, "unresolved": 0,
		"ambiguous": 0, "kept": 0, "non_ascii": 0, "req_present": 0, "req_missing": 0, "opt_present": 0,
		"opt_missing": 0, "off_size": 0, "textured": 0, "tile_first": 0, "tile_after": 0}
	var types := {}
	var missing_required := PackedStringArray()
	var unresolved_list := PackedStringArray()
	for name in names:
		var data := _archive.read_file(entries[name])
		totals["files"] += 1
		var count := data.decode_u32(0) if data.size() >= 4 else -1
		var exact := data.size() == 4 + count * TwoDtReader.RECORD_SIZE
		var file := TwoDtReader.parse(data)
		if not exact or file == null:
			totals["bad_size"] += 1
			print("FILE %s size=%d count=%d EXACT=false" % [name, data.size(), count])
			continue
		totals["records"] += file.records.size()
		var roots := 0
		var root_at := -1
		var non_ascii := 0
		var req := [0, 0]
		var opt := [0, 0]
		var off_size := 0
		for r in file.records:
			types[r.type] = int(types.get(r.type, 0)) + 1
			if r.is_root:
				roots += 1
				root_at = r.index
			for s in [r.name, r.base, r.texture, r.text_id]:
				for c in s.to_utf8_buffer():
					if c >= 0x80:
						non_ascii += 1
						break
			var pieces := _pieces(r)
			for p in pieces[0]:
				if _has(p):
					req[0] += 1
				else:
					req[1] += 1
					missing_required.append("%s #%d %s" % [name, r.index, p])
			for p in pieces[1]:
				if _has(p):
					opt[0] += 1
				else:
					opt[1] += 1
			if r.texture != "" and r.type in [TwoDtReader.TYPE_STATIC, TwoDtReader.TYPE_SLOT, TwoDtReader.TYPE_WND]:
				totals["textured"] += 1
				var t := _ui.load_texture(r.texture)
				if t != null and Vector2i(t.get_size()) != r.rect.size:
					off_size += 1
					if list_off_size:
						print("OFFSIZE %s #%d id=%d %s rect=%dx%d texture=%dx%d" % [name, r.index, r.id,
							r.texture, r.rect.size.x, r.rect.size.y, t.get_width(), t.get_height()])
		var order := _tile_order(file)
		totals["tile_first"] += order[0]
		totals["tile_after"] += order[1]
		for u in file.unresolved:
			var r := file.records[u]
			unresolved_list.append("%s #%d id=%d parent=%d gp=%d" % [name, u, r.id, r.parent_id, r.grandparent_id])
		var root_ok := roots == 1 and root_at == 0
		if not root_ok:
			totals["bad_root"] += 1
		totals["unresolved"] += file.unresolved.size()
		totals["ambiguous"] += file.ambiguous.size()
		totals["kept"] += file.kept_under_root.size()
		totals["non_ascii"] += non_ascii
		totals["req_present"] += req[0]
		totals["req_missing"] += req[1]
		totals["opt_present"] += opt[0]
		totals["opt_missing"] += opt[1]
		totals["off_size"] += off_size
		print("FILE %s bytes=%d records=%d exact=%s root0=%s unresolved=%d ambiguous=%d non_ascii=%d pieces_required=%d/%d optional=%d/%d textured_off_size=%d" % [
			name, data.size(), file.records.size(), exact, root_ok, file.unresolved.size(),
			file.ambiguous.size(), non_ascii, req[0], req[0] + req[1], opt[0], opt[0] + opt[1], off_size])
	var type_line := PackedStringArray()
	var keys := types.keys()
	keys.sort()
	for t in keys:
		type_line.append("%d:%d" % [t, types[t]])
	print("TYPES %s" % " ".join(type_line))
	for u in unresolved_list:
		print("UNRESOLVED %s" % u)
	for m in missing_required:
		print("MISSING %s" % m)
	print("LINKER-GUARD records whose parent already had a child with their id (left under the root): %d" % totals["kept"])
	print("TOTAL files=%d records=%d bad_size=%d bad_root=%d unresolved=%d ambiguous=%d non_ascii=%d required_pieces=%d/%d optional_pieces=%d/%d textured_off_size=%d/%d" % [
		totals["files"], totals["records"], totals["bad_size"], totals["bad_root"],
		totals["unresolved"], totals["ambiguous"], totals["non_ascii"], totals["req_present"],
		totals["req_present"] + totals["req_missing"], totals["opt_present"],
		totals["opt_present"] + totals["opt_missing"], totals["off_size"], totals["textured"]])
	print("ORDER overlapping sibling pairs of a tile and a content control: tile first %d, tile after %d" % [
		totals["tile_first"], totals["tile_after"]])
	quit(0)

## For every pair of siblings where one is a NormalTile and the other is a
## content control (not a frame or stretch border), and their rects overlap:
## how often the tile comes first in the file. The
## builder's back-to-front order rests on this measurement.
func _tile_order(file: TwoDtReader.TwoDtFile) -> Array:
	var first := 0
	var after := 0
	for r in file.records:
		var kids := r.children
		for a in kids.size():
			for b in range(a + 1, kids.size()):
				var ra := file.records[kids[a]]
				var rb := file.records[kids[b]]
				var a_tile := ra.type == TwoDtReader.TYPE_NORMAL_TILE
				var b_tile := rb.type == TwoDtReader.TYPE_NORMAL_TILE
				if a_tile == b_tile:
					continue
				# Content only: a frame or stretch border beside a tile is a
				# border around a body, which says nothing about which of the
				# two is drawn over the other.
				var other := rb if a_tile else ra
				if other.type in [TwoDtReader.TYPE_MAINFRAME, TwoDtReader.TYPE_FRAME, TwoDtReader.TYPE_STRETCH]:
					continue
				if not file.rect_in_root(kids[a]).intersects(file.rect_in_root(kids[b])):
					continue
				if a_tile:
					first += 1
				else:
					after += 1
					if OS.get_cmdline_user_args().has("--list-order=1"):
						print("TILEAFTER %s #%d %s id=%d before tile #%d id=%d" % [file.records[0].name, ra.index, ra.type_name(), ra.id, rb.index, rb.id])
	return [first, after]

## [required pieces, optional pieces] for one record, by TwoDtBuilder's rules.
func _pieces(r: TwoDtReader.Record) -> Array:
	var req := PackedStringArray()
	var opt := PackedStringArray()
	match r.type:
		TwoDtReader.TYPE_MAINFRAME, TwoDtReader.TYPE_FRAME:
			var base := r.base if r.base != "" else (TwoDtBuilder.DEFAULT_MAINFRAME if r.type == 0 else TwoDtBuilder.DEFAULT_FRAME)
			for s in FRAME8:
				req.append(base + s + ".ddj")
		TwoDtReader.TYPE_STRETCH:
			var base := r.base if r.base != "" else TwoDtBuilder.DEFAULT_STRETCH
			for s in STRETCH6:
				req.append(base + s + ".ddj")
		TwoDtReader.TYPE_NORMAL_TILE:
			req.append(r.base if r.base != "" else TwoDtBuilder.DEFAULT_TILE)
		TwoDtReader.TYPE_LATTICE:
			var base := r.base if r.base != "" else TwoDtBuilder.DEFAULT_LATTICE
			for s in LATTICE4:
				req.append(base + s + ".ddj")
		TwoDtReader.TYPE_BUTTON:
			var tex := r.texture if r.texture != "" else TwoDtBuilder.DEFAULT_BUTTON
			req.append(tex)
			for s in ["_focus", "_press", "_disable"]:
				opt.append(_ui._insert_suffix(tex, s))
		TwoDtReader.TYPE_BAR:
			if r.texture != "":
				var base := TwoDtBuilder.slice_base(r.texture)
				for s in ["left", "mid", "right"]:
					req.append(base + s + ".ddj")
		TwoDtReader.TYPE_TAB:
			if r.texture != "":
				var base := TwoDtBuilder.slice_base(r.texture)
				req.append(base + "on.ddj")
				req.append(base + "off.ddj")
				opt.append(base + "disable.ddj")
		TwoDtReader.TYPE_CHECKBOX:
			var base := TwoDtBuilder.slice_base(r.texture if r.texture != "" else TwoDtBuilder.DEFAULT_CHECKBOX)
			req.append(base + "on.ddj")
			req.append(base + "off.ddj")
		TwoDtReader.TYPE_GAUGE:
			req.append(r.texture if r.texture != "" else TwoDtBuilder.DEFAULT_GAUGE)
		TwoDtReader.TYPE_SLIDER:
			req.append(r.texture if r.texture != "" else TwoDtBuilder.DEFAULT_SLIDER)
		TwoDtReader.TYPE_STATIC, TwoDtReader.TYPE_SLOT, TwoDtReader.TYPE_WND:
			if r.texture != "":
				req.append(r.texture)
	return [req, opt]
