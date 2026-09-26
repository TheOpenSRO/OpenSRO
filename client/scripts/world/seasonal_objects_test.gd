extends SceneTree

## Seasonal event decorations hidden by default (round 583): the
## classifier (SeasonalObjects) over the real path shapes of Map.pk2's
## object.ifo, the SRREVAMP_SEASONAL list, and World3D's objects prepare
## leaving the hidden pieces out before the model loop -- against a
## synthetic archive (never real game data). Run headless:
##   godot4 --headless --path client --script res://scripts/world/seasonal_objects_test.gd
##
## Held to account:
## - each of the four folder rules matches its own paths, whatever the case,
##   and nothing else: `arabia_fouad` (id 3297, between two Halloween ids),
##   `alex_burner` (Alexandria, in none of the four folders), the Jangan gate
##   and wall, and the event sets the user did not choose (the new-year
##   piece, the season door) are ordinary objects;
## - SRREVAMP_SEASONAL's comma list shows again exactly the sets it names;
## - World3D._objects_prepare drops a hidden piece after the de-duplication
##   and before the model loop (its model is never read), keeps
##   arabia_fouad, and logs `hid N seasonal placement(s) (...)`; with
##   SRREVAMP_SEASONAL=christmas only the Christmas piece comes back.
##
## Everything is reached through load() and call(), so on a tree without
## round 583 the suite FAILS instead of failing to parse.

const CLASSIFIER := "res://scripts/world/seasonal_objects.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## World3D.gd needs the NetClient autoload registered before it compiles,
## which is the case in _initialize and not in _init.
func _initialize() -> void:
	var C: GDScript = load(CLASSIFIER) if ResourceLoader.exists(CLASSIFIER) else null
	_check(C != null, "the seasonal classifier exists (absent before round 583)")
	if C != null:
		_test_classifier(C)
		_test_enabled_list(C)
	_test_prepare_hides()
	_finish()

func _test_classifier(C: GDScript) -> void:
	var expect := {
		"res\\etc\\x_mas\\x_mas_tree01.bsr": "christmas",
		"res\\etc\\x_mas\\x_mas_wreath03.bsr": "christmas",
		"compound\\struct\\etc\\x_mas\\x_mas_boxset01.cpd": "christmas",
		"RES\\ETC\\X_MAS\\X_MAS_SNOWMAN.BSR": "christmas",
		"res\\etc\\halloween\\halloween_pu03.bsr": "halloween",
		"res\\etc\\halloween\\halloween_display02.bsr": "halloween",
		"res\\etc\\obt\\obt_event_pillar_one.bsr": "obt",
		"res\\etc\\obt\\obt_event_flag _01.bsr": "obt",
		"res\\etc\\summer_event\\sum_event_jang.bsr": "summer",
		"res\\etc\\summer_event\\sum_event_pillar_one.bsr": "summer",
		"res\\npc\\npc\\arabia_fouad.bsr": "",
		"res\\bldg\\north africa\\alexandria\\alex_burner.bsr": "",
		"res\\bldg\\north africa\\alexandria\\alex_burner02.bsr": "",
		"res\\bldg\\china\\jangan01\\cj_jang_gate.bsr": "",
		"res\\bldg\\china\\jangan_enter\\cj_s.bsr": "",
		"res\\etc\\newyearday\\newyearday_01.bsr": "",
		"res\\etc\\seasonevent_door.bsr": "",
		"res\\dun\\tower\\defence\\event_area_rockevent.bsr": "",
	}
	for path in expect:
		var got: String = C.call("classify", path)
		_check(got == expect[path], "%s -> '%s' (got '%s')" % [path, expect[path], got])

	# The id -> set map over an object index: by path, never by id range.
	var table := ObjidxReader.Table.new()
	var entries: Array[ObjidxReader.Entry] = []
	var paths := ["res\\bldg\\china\\jangan_enter\\cj_s.bsr", "res\\etc\\x_mas\\x_mas_tree01.bsr",
		"res\\etc\\halloween\\halloween_display04.bsr", "res\\npc\\npc\\arabia_fouad.bsr",
		"res\\etc\\halloween\\halloween_display02.bsr", "res\\etc\\obt\\obt_event_jang.bsr",
		"res\\etc\\summer_event\\sum_event_jang.bsr"]
	for id in range(paths.size()):
		var e := ObjidxReader.Entry.new()
		e.type_id = id
		e.path = paths[id]
		entries.append(e)
	table.entries = entries
	var hidden: Dictionary = C.call("hidden_ids", table, {})
	_check(hidden == {1: "christmas", 2: "halloween", 4: "halloween", 5: "obt", 6: "summer"},
		"all four sets hidden by default; the building and arabia_fouad (between two Halloween ids) are not (got %s)" % str(hidden))
	hidden = C.call("hidden_ids", table, {"halloween": true, "summer": true})
	_check(hidden == {1: "christmas", 5: "obt"}, "an enabled set is not hidden (got %s)" % str(hidden))

func _test_enabled_list(C: GDScript) -> void:
	_check((C.call("parse_enabled", "") as Dictionary).is_empty(), "an empty list shows nothing again")
	_check(C.call("parse_enabled", "christmas") == {"christmas": true}, "christmas alone")
	_check(C.call("parse_enabled", " Halloween , obt,,summer ") == {"halloween": true, "obt": true, "summer": true},
		"case and spaces ignored, empty items skipped")
	_check(C.call("parse_enabled", "christmas,easter,xmas") == {"christmas": true}, "an unknown name is ignored")
	_check((C.call("parse_enabled", "christmas,halloween,obt,summer") as Dictionary).size() == 4, "all four")

## World3D's prepare over a synthetic `97\168.o`: a wall, a Christmas tree,
## a Halloween display, arabia_fouad and a repeat of the Christmas tree (the
## de-duplication runs first, so it is hidden once).
func _test_prepare_hides() -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S == null or not S.can_instantiate():
		return
	var map_path := "user://srrevamp_r583_seasonal_map.pk2"
	var data_path := "user://srrevamp_r583_seasonal_data.pk2"
	_write_pk2(map_path, {"97\\168.o": _build_mapo()})
	_write_pk2(data_path, {"prim\\none.txt": "x".to_ascii_buffer()})

	var saved := OS.get_environment("SRREVAMP_SEASONAL")
	OS.set_environment("SRREVAMP_SEASONAL", "")
	var job := _prepare(S, map_path, data_path)
	var placements: Array = job.get("placements", [])
	var ids: Array = []
	for p in placements:
		ids.append(p["type_id"])
	_check(ids == [1, 4], "by default the wall and arabia_fouad are placed, the Christmas and Halloween pieces are not (got %s)" % str(ids))
	var models: Dictionary = job.get("models", {})
	_check(models.has("prim\\wall.bsr") and models.has("res\\npc\\npc\\arabia_fouad.bsr")
			and not models.has("res\\etc\\x_mas\\x_mas_tree01.bsr") and not models.has("res\\etc\\halloween\\halloween_display04.bsr"),
		"a hidden piece's model is never read (got %s)" % str(models.keys()))
	_check(job.get("seasonal_hid", {}) == {"christmas": 1, "halloween": 1},
		"the job counts what it hid, per set (got %s)" % str(job.get("seasonal_hid")))
	var text := _log_text(job)
	_check(text.contains("World3D: 97\\168.o -- hid 2 seasonal placement(s) (christmas 1, halloween 1, obt 0, summer 0)"),
		"the job logs the hidden count per set (got %s)" % text)
	_check(text.contains("dropped 1 duplicate real placements (5 -> 4)"), "the repeat was merged before the filter")

	OS.set_environment("SRREVAMP_SEASONAL", "christmas")
	job = _prepare(S, map_path, data_path)
	ids = []
	for p in job.get("placements", []):
		ids.append(p["type_id"])
	_check(ids == [1, 2, 4], "SRREVAMP_SEASONAL=christmas brings back only the Christmas piece (got %s)" % str(ids))
	_check(job.get("seasonal_hid", {}) == {"halloween": 1}, "and still hides the Halloween one (got %s)" % str(job.get("seasonal_hid")))

	OS.set_environment("SRREVAMP_SEASONAL", "christmas,halloween,obt,summer")
	job = _prepare(S, map_path, data_path)
	ids = []
	for p in job.get("placements", []):
		ids.append(p["type_id"])
	_check(ids == [1, 2, 3, 4] and not _log_text(job).contains("seasonal"),
		"all four enabled: everything is placed and nothing is logged (got %s)" % str(ids))
	OS.set_environment("SRREVAMP_SEASONAL", saved)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(map_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(data_path))

## A fresh world per run: the hidden set is built once per world.
func _prepare(S: GDScript, map_path: String, data_path: String) -> Dictionary:
	var w: Node = S.new()
	w._map_pk2 = Pk2Reader.open(map_path)
	w._data_pk2 = Pk2Reader.open(data_path)
	w._object_index_cache = _object_index()
	w._object_index_load_attempted = true
	var job: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168")
	w.call("_objects_prepare", job)
	w.free()
	return job

func _log_text(job: Dictionary) -> String:
	var lines := PackedStringArray()
	for line in job.get("log", []):
		lines.append(str(line[1]))
	return "\n".join(lines)

func _object_index() -> ObjidxReader.Table:
	var table := ObjidxReader.Table.new()
	var entries: Array[ObjidxReader.Entry] = []
	var paths := ["", "prim\\wall.bsr", "res\\etc\\x_mas\\x_mas_tree01.bsr",
		"res\\etc\\halloween\\halloween_display04.bsr", "res\\npc\\npc\\arabia_fouad.bsr"]
	for id in range(paths.size()):
		var e := ObjidxReader.Entry.new()
		e.type_id = id
		e.path = paths[id]
		entries.append(e)
	table.entries = entries
	return table

## A real-shaped `.o` (objects_prepare_test.gd's layout).
func _build_mapo() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array((MapoReader.MAGIC + "1001").to_ascii_buffer())
	buf.resize(buf.size() + 8)
	for rec in [[1, Vector3(100, 0, 100)], [2, Vector3(200, 0, 100)], [3, Vector3(300, 0, 300)],
			[4, Vector3(400, 0, 400)], [2, Vector3(200, 0, 100)]]:
		var r := PackedByteArray()
		r.resize(MapoReader.FIXED_RECORD_LEN)
		r.encode_u32(0, rec[0])
		r.encode_float(4, rec[1].x)
		r.encode_float(8, rec[1].y)
		r.encode_float(12, rec[1].z)
		buf.append_array(r)
	return buf

## A synthetic pk2 holding `files` ({"folder\\name": bytes}), one directory
## block per folder, unencrypted (objects_prepare_test.gd's writer).
func _write_pk2(path: String, files: Dictionary) -> void:
	var children := {"": []}
	var order: Array[String] = [""]
	for fp in files:
		var parts := (fp as String).split("\\")
		var parent := ""
		for i in range(parts.size() - 1):
			var here: String = parts[i] if parent == "" else parent + "\\" + parts[i]
			if not children.has(here):
				children[here] = []
				order.append(here)
				(children[parent] as Array).append([parts[i], true, here])
			parent = here
		(children[parent] as Array).append([parts[-1], false, fp])
	var block_at := {}
	for n in range(order.size()):
		block_at[order[n]] = Pk2Reader.HEADER_SIZE + n * Pk2Reader.BLOCK_SIZE
	var data_start := Pk2Reader.HEADER_SIZE + order.size() * Pk2Reader.BLOCK_SIZE
	var data := PackedByteArray()
	var file_at := {}
	for fp in files:
		file_at[fp] = data_start + data.size()
		data.append_array(files[fp])
	var out := PackedByteArray()
	out.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		out[i] = magic[i]
	for folder in order:
		var block := PackedByteArray()
		block.resize(Pk2Reader.BLOCK_SIZE)
		_write_entry(block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", block_at[folder], 0)
		var slot := 1
		for child in children[folder]:
			if child[1]:
				_write_entry(block, slot, Pk2Reader.ENTRY_TYPE_FOLDER, child[0], block_at[child[2]], 0)
			else:
				_write_entry(block, slot, Pk2Reader.ENTRY_TYPE_FILE, child[0], file_at[child[2]], (files[child[2]] as PackedByteArray).size())
			slot += 1
		out.append_array(block)
	out.append_array(data)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(out)
	f.close()

func _write_entry(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE
	block[base] = entry_type
	var name_bytes := name.to_ascii_buffer()
	for j in range(name_bytes.size()):
		block[base + Pk2Reader.ENTRY_OFF_NAME + j] = name_bytes[j]
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_POSITION, offset)
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_SIZE, size)

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
