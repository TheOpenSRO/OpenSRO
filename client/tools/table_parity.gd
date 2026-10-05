extends SceneTree

## Holds the native (Rust) text-table readers to the GDScript ones on the
## REAL archives, cell for cell and value for value (round 671;
## native/README.md, "Parity"; native/src/core/tables.rs). Run on the render
## box, never committed output:
##
##   client/tools/remote_godot.sh script res://tools/table_parity.gd -- --pk2-dir=/opt/sro-files/client
##
## Every `.txt` file in every archive (Data, Map, Media, Particles) is read
## once, and on each:
## - the decode and the splits: `_lines` + `split("\t")` (the readers' way)
##   and UiTextTable's own `split("\n")` + `split("\t")` against the native
##   `split_rows`, every cell compared as a string;
## - Godot's number semantics: every distinct stripped cell through
##   `is_valid_int`, `int()`, `is_valid_float` and `float()` against the
##   native port's, the floats by bit pattern;
## - every ported reader run both ways (NativeAssets.force_gdscript) and the
##   results compared whole -- keys, key ORDER, and every value, floats and
##   Vector2/Vector3 components by bit pattern (var_to_bytes): NpcTableReader's
##   positions, codes, models, models_by_code ("CHAR_" and ""), org_codes,
##   speeds_by_code ("CHAR_" and ""), country_by_code ("CHAR_" and ""),
##   bc_radius_by_code ("" and "MOB_"), names, name_keys and models_by_name;
##   ItemTableReader.parse (every Item field); UiTextTable.parse (language
##   columns 8, 3 and 12, keep_first true and false); SkillEffectReader.parse_all.
## Then the parts the client merges -- characterdata's and itemdata's, in the
## order World3D reads them -- are accumulated into one Dictionary both ways,
## which is where a duplicate id across parts would show.
##
## A table the port hands back (`fallback`) is counted and listed, and must be
## one whose UTF-16 holds an unpaired surrogate or decodes to "" (judged on the
## raw units, as String::parse_utf16 walks them); every native reader must hand
## it back too, so the client reads it in GDScript exactly as before. Its
## readers are then not compared: both sides are GDScript, and on such text
## Godot 4.2.2 itself is not deterministic -- parse_utf16 drops a lead
## surrogate that is followed by a plain character but still sizes the string
## for it, so the last character is uninitialised memory (MEASURED: the same
## file parsed twice gave different rows, and the log reports "Invalid unicode
## codepoint (6db3bc40)" for that character).
##
## Prints `TABLES <archive> ...` counts, the first FAIL lines, and
## `TABLE PARITY PASS` or `TABLE PARITY FAIL <n>`; exits 1 on a FAIL or when
## the library (with SrNativeTables) is not there.

const ARCHIVES := ["Data.pk2", "Map.pk2", "Media.pk2", "Particles.pk2"]
## FAIL lines printed (--max-fails=N for more).
var _max_fail_lines := 20
## The object-name table parse_names / parse_models_by_name resolve through.
const NAMES_PATH := "server_dep\\silkroad\\textdata\\textdata_object.txt"

var _fails := 0
var _names: UiTextTable = null
var _stats := {}

func _fail(msg: String) -> void:
	_fails += 1
	if _fails <= _max_fail_lines:
		print("FAIL " + msg)

func _count(key: String, n: int = 1) -> void:
	_stats[key] = int(_stats.get(key, 0)) + n

func _init() -> void:
	var pk2_dir := "/opt/sro-files/client"
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2-dir="):
			pk2_dir = a.substr(10)
		elif a.begins_with("--only="):
			only = a.substr(7)
		elif a.begins_with("--max-fails="):
			_max_fail_lines = a.substr(12).to_int()
	if not NativeAssets.library_usable() or not ClassDB.class_exists(NativeAssets.TABLES_CLASS):
		print("TABLE PARITY FAIL: no usable native library with %s (%s) -- nothing to compare" % [
			NativeAssets.TABLES_CLASS, NativeAssets.api_verdict(NativeAssets.library_api())])
		quit(1)
		return
	NativeAssets.available()
	var t0 := Time.get_ticks_msec()
	var media := Pk2Reader.open(pk2_dir.path_join("Media.pk2"))
	if media == null:
		print("TABLE PARITY FAIL: cannot open Media.pk2")
		quit(1)
		return
	var names_entry := ObjectLoader.find_file(media, NAMES_PATH)
	NativeAssets.force_gdscript = true
	_names = UiTextTable.parse(media.read_file(names_entry)) if names_entry != null else null
	NativeAssets.force_gdscript = false
	if _names == null or _names.count() == 0:
		_fail("no %s to resolve names through" % NAMES_PATH)
	for name in ARCHIVES:
		if only != "" and name != only:
			continue
		_archive(pk2_dir.path_join(name), name)
	if only == "" or only == "Media.pk2":
		_merged(media)
	print("TABLES totals: %s" % JSON.stringify(_stats))
	print("TABLES took %d s" % ((Time.get_ticks_msec() - t0) / 1000))
	if _fails == 0:
		print("TABLE PARITY PASS")
		quit(0)
	else:
		print("TABLE PARITY FAIL %d" % _fails)
		quit(1)

func _archive(path: String, label: String) -> void:
	var pk2 := Pk2Reader.open(path)
	if pk2 == null:
		_fail("%s: cannot open" % label)
		return
	var t := Time.get_ticks_msec()
	var files: Array = []
	var queue: Array = [["", pk2.read_dir()]]
	while not queue.is_empty():
		var item: Array = queue.pop_back()
		for ev in item[1]:
			var e: Pk2Reader.Entry = ev
			if e.name == "." or e.name == "..":
				continue
			var p: String = e.name if item[0] == "" else item[0] + "\\" + e.name
			if e.is_dir:
				queue.append([p, pk2.read_dir_at(e)])
			elif e.name.to_lower().ends_with(".txt"):
				files.append([p, e])
	var bytes_total := 0
	for f in files:
		var data := pk2.read_file(f[1])
		bytes_total += data.size()
		_file(label + ":" + str(f[0]), data)
	print("TABLES %s: %d .txt files, %d bytes (%d ms)" % [label, files.size(), bytes_total, Time.get_ticks_msec() - t])
	_count("files", files.size())
	_count("bytes", bytes_total)

func _file(where: String, data: PackedByteArray) -> void:
	var nt := NativeAssets.new_tables()
	# 1. The decode and the splits, both shapes.
	var lines_ref := _rows_ref(NpcTableReader._lines(data))
	var cells: PackedStringArray = lines_ref[0]
	var handed_back := _compare_split(where + " (_lines)", data, true, lines_ref)
	handed_back = _compare_split(where + " (UiTextTable)", data, false, _rows_ref(_ui_lines(data))) or handed_back
	_count("cells", cells.size())
	_count("rows", (lines_ref[1] as PackedInt64Array).size())
	# 2. Godot's numbers, on every distinct stripped cell.
	var distinct := {}
	for c in cells:
		distinct[c.strip_edges()] = true
	var texts := PackedStringArray(distinct.keys())
	var nums: Dictionary = nt.call("numbers", texts)
	var vi: PackedByteArray = nums["valid_int"]
	var vf: PackedByteArray = nums["valid_float"]
	var ok: PackedByteArray = nums["float_ok"]
	var ints: PackedInt64Array = nums["ints"]
	var floats: PackedFloat64Array = nums["floats"]
	for i in texts.size():
		var s := texts[i]
		if (vi[i] == 1) != s.is_valid_int() or ints[i] != int(s) or (vf[i] == 1) != s.is_valid_float():
			_fail("%s: numbers of %s: native (%d, %d, %d) GDScript (%s, %d, %s)" % [where, JSON.stringify(s), vi[i], ints[i], vf[i], s.is_valid_int(), int(s), s.is_valid_float()])
		elif ok[i] == 1 and not _same_float(floats[i], float(s)):
			_fail("%s: float(%s): native %s GDScript %s" % [where, JSON.stringify(s), var_to_bytes(floats[i]).hex_encode(), var_to_bytes(float(s)).hex_encode()])
		elif ok[i] == 0:
			_count("float_overflow_fallbacks")
	_count("distinct_numbers", texts.size())
	# 3. Every ported reader, both ways -- or, for a table the port hands
	# back, a check that every native reader hands it back.
	if handed_back:
		_count("files handed back")
		for m in [["npc_positions", [data]], ["char_codes", [data]], ["char_models", [data]],
				["char_models_by_code", [data, ""]], ["char_org_codes", [data]], ["char_speeds_by_code", [data, ""]],
				["char_country_by_code", [data, ""]], ["char_bc_radius_by_code", [data, ""]], ["char_name_keys", [data]],
				["char_models_name_keys", [data]], ["items", [data]], ["ui_text_rows", [data, 8]], ["skill_effects", [data]]]:
			if not (nt.callv(m[0], m[1]) as Dictionary).has("fallback"):
				_fail("%s: split_rows handed the table back but %s did not" % [where, m[0]])
		return
	for reader in _readers():
		_compare_reader(where, reader[0], reader[1], data)

## [label, func(data) -> canonical Variant] for every ported reader.
func _readers() -> Array:
	return [
		["positions", func(d): return _canon_spawns(NpcTableReader.parse_positions(d))],
		["codes", func(d): return NpcTableReader.parse_codes(d, {})],
		["models", func(d): return NpcTableReader.parse_models(d, {})],
		["models_by_code CHAR_", func(d): return NpcTableReader.parse_models_by_code(d, {})],
		["models_by_code ''", func(d): return NpcTableReader.parse_models_by_code(d, {}, "")],
		["org_codes", func(d): return NpcTableReader.parse_org_codes(d, {})],
		["speeds CHAR_", func(d): return NpcTableReader.parse_speeds_by_code(d, {})],
		["speeds ''", func(d): return NpcTableReader.parse_speeds_by_code(d, {}, "")],
		["country CHAR_", func(d): return NpcTableReader.parse_country_by_code(d, {})],
		["country ''", func(d): return NpcTableReader.parse_country_by_code(d, {}, "")],
		["bc_radius ''", func(d): return NpcTableReader.parse_bc_radius_by_code(d, {})],
		["bc_radius MOB_", func(d): return NpcTableReader.parse_bc_radius_by_code(d, {}, "MOB_")],
		["names", func(d): return NpcTableReader.parse_names(d, _names, {})],
		["name_keys", func(d): return NpcTableReader.parse_name_keys(d, {})],
		["models_by_name", func(d): return NpcTableReader.parse_models_by_name(d, _names, {})],
		["items", func(d): return _canon_items(ItemTableReader.parse(d, {}))],
		["ui 8", func(d): return UiTextTable.parse(d)._strings],
		["ui 8 last", func(d): return UiTextTable.parse(d, 8, false)._strings],
		["ui 3", func(d): return UiTextTable.parse(d, 3)._strings],
		["ui 12", func(d): return UiTextTable.parse(d, 12)._strings],
		["skill_effects", func(d): return SkillEffectReader.parse_all(d)],
	]

func _compare_reader(where: String, label: String, run: Callable, data: PackedByteArray) -> void:
	NativeAssets.force_gdscript = true
	var g = run.call(data)
	NativeAssets.force_gdscript = false
	var n = run.call(data)
	_count("reader runs")
	_count("entries " + label, (g as Dictionary).size() if g is Dictionary else (g as Array).size())
	if var_to_bytes(g) != var_to_bytes(n):
		_fail("%s: %s differs: %s" % [where, label, _first_difference(g, n)])

func _merged(media: Pk2Reader) -> void:
	# The parts, accumulated in World3D's order: duplicates across parts.
	var parts: Array = []
	for p in NpcTableReader.MODEL_TABLE_PATHS:
		var e := ObjectLoader.find_file(media, p)
		if e != null:
			parts.append(media.read_file(e))
	var item_parts: Array = []
	for p in ItemTableReader.TABLE_PATHS:
		var e := ObjectLoader.find_file(media, p)
		if e != null:
			item_parts.append(media.read_file(e))
	var merges := [
		["merged models_by_code ''", parts, func(d, into): return NpcTableReader.parse_models_by_code(d, into, "")],
		["merged models", parts, func(d, into): return NpcTableReader.parse_models(d, into)],
		["merged codes", parts, func(d, into): return NpcTableReader.parse_codes(d, into)],
		["merged names", parts, func(d, into): return NpcTableReader.parse_names(d, _names, into)],
		["merged name_keys", parts, func(d, into): return NpcTableReader.parse_name_keys(d, into)],
		["merged org_codes", parts, func(d, into): return NpcTableReader.parse_org_codes(d, into)],
		["merged bc_radius", parts, func(d, into): return NpcTableReader.parse_bc_radius_by_code(d, into)],
		["merged models_by_name", parts, func(d, into): return NpcTableReader.parse_models_by_name(d, _names, into)],
		["merged items", item_parts, func(d, into): return ItemTableReader.parse(d, into)],
	]
	for m in merges:
		var both := []
		for native in [false, true]:
			NativeAssets.force_gdscript = not native
			var into := {}
			for d in m[1]:
				into = m[2].call(d, into)
			both.append(into)
		NativeAssets.force_gdscript = false
		var g = both[0]
		var n = both[1]
		if m[0] == "merged items":
			g = _canon_items(g)
			n = _canon_items(n)
		print("TABLES %s: %d parts, %d entries" % [m[0], (m[1] as Array).size(), (g as Dictionary).size()])
		_count("merged entries", (g as Dictionary).size())
		if var_to_bytes(g) != var_to_bytes(n):
			_fail("%s differs: %s" % [m[0], _first_difference(g, n)])

## [cells, row_ends] of rows split on tabs, the GDScript way.
func _rows_ref(lines: PackedStringArray) -> Array:
	var cells := PackedStringArray()
	var ends := PackedInt64Array()
	for line in lines:
		cells.append_array(line.split("\t"))
		ends.append(cells.size())
	return [cells, ends]

## UiTextTable's own decode and line split (its _pp_parse, up to `lines`).
func _ui_lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var full_text: String
	if raw.size() >= 2:
		full_text = raw.get_string_from_utf16()
	if full_text.is_empty() and raw.size() > 0:
		full_text = raw.get_string_from_utf8()
	return full_text.split("\n")

## Why String::parse_utf16 would not give plain text for these bytes (after
## the readers' FF FE strip), walking the units as it does -- a second BOM,
## FFFE byte-swapping, the stop at the first NUL: "empty" when it decodes to
## nothing, "unpaired" when it meets an unpaired surrogate, else "".
func _utf16_trouble(data: PackedByteArray) -> String:
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var n := raw.size() / 2
	var i := 0
	var swap := false
	if n >= 1:
		var first := raw.decode_u16(0)
		if first == 0xFEFF:
			i = 1
		elif first == 0xFFFE:
			i = 1
			swap = true
	var decoded := 0
	while i < n:
		var c := _unit(raw, i, swap)
		if c == 0:
			break
		decoded += 1
		if c >= 0xD800 and c < 0xDC00:
			var d := _unit(raw, i + 1, swap) if i + 1 < n else 0
			if d < 0xDC00 or d >= 0xE000:
				return "unpaired"
			i += 2
			continue
		if c >= 0xDC00 and c < 0xE000:
			return "unpaired"
		i += 1
	return "empty" if decoded == 0 else ""

func _unit(raw: PackedByteArray, i: int, swap: bool) -> int:
	var u := raw.decode_u16(i * 2)
	return ((u & 0xFF) << 8) | (u >> 8) if swap else u

## Compares the native split with the GDScript one; true when the port handed
## the table back (and rightly).
func _compare_split(where: String, data: PackedByteArray, drop_cr: bool, ref: Array) -> bool:
	var nt := NativeAssets.new_tables()
	var r: Dictionary = nt.call("split_rows", data, drop_cr)
	if r.has("fallback"):
		_count("fallbacks")
		var why := _utf16_trouble(data)
		if why == "":
			_fail("%s: native fell back (%s) on UTF-16 that decodes plainly" % [where, r["fallback"]])
		else:
			print("TABLES handed back %s: %s (%s)" % [where, r["fallback"], why])
		return true
	var cells: PackedStringArray = r["cells"]
	var ends: PackedInt64Array = r["row_ends"]
	if ends != ref[1]:
		_fail("%s: rows split differently: %d rows native, %d GDScript" % [where, ends.size(), (ref[1] as PackedInt64Array).size()])
	elif cells != ref[0]:
		var ref_cells: PackedStringArray = ref[0]
		for i in cells.size():
			if cells[i] != ref_cells[i]:
				_fail("%s: cell %d: native %s GDScript %s" % [where, i, JSON.stringify(cells[i]), JSON.stringify(ref_cells[i])])
				break
	if _utf16_trouble_cheap(data):
		_fail("%s: read natively, but its UTF-16 is not plain" % where)
	return false

## The same judgement, only where it is cheap to make here: a table of at
## most 64 KB (the full scan is a GDScript loop over every unit).
func _utf16_trouble_cheap(data: PackedByteArray) -> bool:
	return data.size() <= 65536 and _utf16_trouble(data) != ""

## Floats equal bit for bit (-0.0 against 0.0 and NaN payloads included).
func _same_float(a: float, b: float) -> bool:
	if is_nan(a) or is_nan(b) or (a == 0.0 and b == 0.0):
		return var_to_bytes(a) == var_to_bytes(b)
	return a == b

func _canon_spawns(spawns: Array) -> Array:
	var out := []
	for sv in spawns:
		var s: NpcTableReader.Spawn = sv
		out.append([s.npc_id, s.region_x, s.region_y, s.local_position])
	return out

## Every Item field, in a fixed order, per id (in the dictionary's order).
func _canon_items(items: Dictionary) -> Dictionary:
	var out := {}
	for id in items:
		var it: ItemTableReader.Item = items[id]
		out[id] = [it.id, it.code_name, it.item_name, it.name_strid, it.max_stack, it.sell_price, it.keeping_fee,
			it.icon_path, it.model_path, it.model_paths, it.drop_model_path, it.type_ids, it.country,
			it.req_gender, it.req_level_types, it.req_levels, it.durability, it.phys_atk, it.mag_atk,
			it.phys_reinforce, it.mag_reinforce, it.attack_rate, it.critical, it.attack_range,
			it.param1, it.phys_def, it.mag_def, it.block, it.cash_item, it.bionic,
			# Round 731: the tooltip's columns.
			it.rarity, it.item_class, it.set_id, it.durability_max, it.req_str, it.req_int,
			it.max_magic_options, it.parry, it.phys_absorb, it.mag_absorb, it.plus_incs]
	return out

## The first place two results differ, for the FAIL line.
func _first_difference(g, n) -> String:
	if typeof(g) != typeof(n):
		return "types %d / %d" % [typeof(g), typeof(n)]
	if g is Dictionary:
		var gk: Array = (g as Dictionary).keys()
		var nk: Array = (n as Dictionary).keys()
		if gk.size() != nk.size():
			for k in gk:
				if not (n as Dictionary).has(k):
					return "%d keys GDScript, %d native; first missing natively: %s" % [gk.size(), nk.size(), str(k)]
			for k in nk:
				if not (g as Dictionary).has(k):
					return "%d keys GDScript, %d native; first extra natively: %s" % [gk.size(), nk.size(), str(k)]
		for i in mini(gk.size(), nk.size()):
			if var_to_bytes(gk[i]) != var_to_bytes(nk[i]):
				return "key %d: GDScript %s, native %s" % [i, str(gk[i]), str(nk[i])]
			if var_to_bytes(g[gk[i]]) != var_to_bytes(n[nk[i]]):
				return "at %s: GDScript %s, native %s" % [str(gk[i]), str(g[gk[i]]), str(n[nk[i]])]
	elif g is Array:
		if (g as Array).size() != (n as Array).size():
			return "%d entries GDScript, %d native" % [(g as Array).size(), (n as Array).size()]
		for i in (g as Array).size():
			if var_to_bytes(g[i]) != var_to_bytes(n[i]):
				return "entry %d: GDScript %s, native %s" % [i, str(g[i]), str(n[i])]
	return "bytes differ (%s / %s)" % [str(g).left(200), str(n).left(200)]
