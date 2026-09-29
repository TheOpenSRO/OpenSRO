extends SceneTree

## Round 643's review: force_addobject.txt's rows are map objects too. READ
## chain (ForceAddObjectReader's doc): Client_LoadRefDataFile type 0x3d ->
## FUN_00927620 -> SWorld::vslot_045 -> the tail of FUN_00a361b0, which
## builds each loaded row as an object of its region, at its position as
## given (FUN_00a33530 copies the record), by the key (region, sector bits |
## a per-sector counter from 0x3ff down), when that region's `.o2` loads.
## Synthetic bytes only (no game data). Run headless:
##   godot4 --headless --path client --script res://scripts/world/force_addobject_test.gd
##
## The reader and World3D are reached through load() and call(), so on a
## tree without them the suite FAILS instead of failing to parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

const BRIDGE_REGION := (124 << 8) | 247

func _initialize() -> void:
	var R := load("res://scripts/mapo/force_addobject_reader.gd") as GDScript
	_check(R != null, "force_addobject_reader.gd exists (absent before round 643's review)")
	if R != null:
		_test_reader(R)
	_test_world()
	print("ALL PASS" if _failures == 0 else "FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

## Two comment lines, a service-0 row, a structure row in 124/247 (the
## retail bridge's columns, synthetic path), a second in the same sector,
## and a flag in 96/168. UTF-16LE with a BOM and CRLF, as the file is.
func _table_bytes() -> PackedByteArray:
	var text := "//header\t\r\n//service\tBSR\tregionX\tregionY\r\n" \
		+ "0\tres\\flag\\new.bsr\t168\t96\t893\t0\t1575\t0\t0\t2\tFORTRESS_A\t// off\r\n" \
		+ "1\tRES\\Bldg\\Synth\\Bridge.bsr\t247\t124\t1789.318\t848\t199.588\t3.111\t1\t2\tFORTRESS_B\t// Bridge 1\r\n" \
		+ "1\tres\\bldg\\synth\\bridge.bsr\t247\t124\t1800\t848\t250\t0\t1\t2\tFORTRESS_B\r\n" \
		+ "1\tres\\flag\\flag.bsr\t168\t96\t800\t218\t1620\t0\t0\t0\tFORTRESS_A\r\n"
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _test_reader(R: GDScript) -> void:
	var rows: Array = R.call("parse", _table_bytes())
	_check(rows.size() == 3, "the three service-1 rows load; comments and the service-0 row do not (got %d)" % rows.size())
	if rows.size() != 3:
		return
	var bridge = rows[0]
	_check(bridge.region == BRIDGE_REGION, "region X 247 and region Y 124 pack as (124 << 8) | 247 (got %x)" % bridge.region)
	_check(bridge.position == Vector3(1789.318, 848, 199.588) and is_equal_approx(bridge.yaw, 3.111),
		"the position is kept as given, Y 848 included (got %s)" % str(bridge.position))
	_check(bridge.kind == 1 and bridge.guild == 2 and bridge.fortress == "FORTRESS_B", "type, guild and fortress columns read")
	_check((R.call("rows_for", rows, 124, 247) as Array).size() == 2 and (R.call("rows_for", rows, 96, 168) as Array).size() == 1,
		"rows_for files the rows under <regionY>\\<regionX>")
	var counters := {}
	var uid1: int = R.call("uid_for", Vector3(1789.318, 848, 199.588), counters)
	var uid2: int = R.call("uid_for", Vector3(1800, 848, 250), counters)
	_check(uid1 == (5 << 10) | 0x3FF and uid2 == (5 << 10) | 0x3FE,
		"uid: row int(z)/320 = 0, col int(x)/320 = 5 in bits 10-15, the sector's counter 0x3ff then 0x3fe (got %d, %d)" % [uid1, uid2])
	var table := ObjidxReader.Table.new()
	var entries: Array[ObjidxReader.Entry] = []
	for id in range(3):
		var e := ObjidxReader.Entry.new()
		e.type_id = id
		e.path = ["", "res\\wall.bsr", "res\\bldg\\synth\\bridge.bsr"][id]
		entries.append(e)
	table.entries = entries
	var placed: Array = R.call("placements", R.call("rows_for", rows, 124, 247), table)
	_check(placed.size() == 2 and placed[0]["type_id"] == 2 and placed[0]["key"] == (BRIDGE_REGION << 16) | ((5 << 10) | 0x3FF),
		"the path is found in the object index case-insensitively, and the key is (region << 16) | uid (got %s)" % str(placed))
	var flags: Array = R.call("placements", R.call("rows_for", rows, 96, 168), table)
	_check(flags.size() == 1 and flags[0]["type_id"] == -1 and flags[0]["path"] == "res\\flag\\flag.bsr",
		"a path the index lacks keeps its own path (vslot_045 appends it as a new type)")

## World3D builds a region's rows with its `.o2` and places them at their
## own Y; a region without an `.o2` gets none.
func _test_world() -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S == null or not S.can_instantiate():
		return
	var names := {}
	for m in S.get_script_method_list():
		names[m["name"]] = true
	_check(names.has("_force_rows_for") and names.has("placement_model_path"),
		"World3D.gd has _force_rows_for and placement_model_path (absent before round 643's review)")
	if not names.has("_force_rows_for"):
		return
	var map_path := "user://srrevamp_r643_force_map.pk2"
	var data_path := "user://srrevamp_r643_force_data.pk2"
	var media_path := "user://srrevamp_r643_force_media.pk2"
	_write_pk2(map_path, {"124\\247.o2": _empty_o2()})
	_write_pk2(data_path, {"prim\\none.txt": "x".to_ascii_buffer()})
	_write_pk2(media_path, {"server_dep\\silkroad\\textdata\\force_addobject.txt": _table_bytes()})
	var w: Node = S.new()
	w._map_pk2 = Pk2Reader.open(map_path)
	w._data_pk2 = Pk2Reader.open(data_path)
	w._media_pk2 = Pk2Reader.open(media_path)
	var table := ObjidxReader.Table.new()
	var entries: Array[ObjidxReader.Entry] = []
	for id in range(2):
		var e := ObjidxReader.Entry.new()
		e.type_id = id
		e.path = ["", "res\\wall.bsr"][id]
		entries.append(e)
	table.entries = entries
	w._object_index_cache = table
	w._object_index_load_attempted = true
	w.set("_object_templates", ObjectTemplateCache.new(func(_path: String) -> Node3D: return Node3D.new()))
	var job: Dictionary = w.call("_objects_job", "124\\247.o", Vector3.ZERO, "_124_247")
	w.call("_objects_prepare", job)
	var placements: Array = job.get("placements", [])
	_check(not job.has("error") and placements.size() == 2,
		"124/247's empty .o2 plus its two force rows: 2 placements (error %s, got %d)" % [str(job.get("error", "none")), placements.size()])
	if placements.size() == 2:
		_check(placements[0]["position"] == Vector3(1789.318, 848, 199.588) and placements[0]["key"] == (BRIDGE_REGION << 16) | 6143,
			"the bridge row at Y 848 with its key (got %s)" % str(placements[0]))
	w.call("_objects_commit", job)
	var container: Node = w.get_node_or_null("RealMapObjects_124_247")
	_check(container != null and container.get_child_count() == 2
			and String(container.get_child(0).name).begins_with("Obj_Bridge_")
			and (container.get_child(0) as Node3D).position.y == 848.0,
		"the commit places both, named after the row's path, at Y 848 (got %s)" % (str(container.get_child_count()) if container != null else "null"))
	# A region without an .o2 builds none (the rows are built by its .o2's loader).
	var job2: Dictionary = w.call("_objects_job", "96\\168.o", Vector3.ZERO, "_96_168")
	w.call("_objects_prepare", job2)
	_check(job2.has("error") and (job2.get("placements", []) as Array).is_empty(),
		"96/168 has no .o2 here, so its flag row is not built")
	w.free()
	for p in [map_path, data_path, media_path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

## A `.o2` with 36 empty sectors.
func _empty_o2() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array((MapO2Reader.MAGIC + "1001").to_ascii_buffer())
	buf.resize(buf.size() + MapO2Reader.SECTORS_PER_SIDE * MapO2Reader.SECTORS_PER_SIDE * MapO2Reader.FIELDS_PER_SECTOR * 2)
	return buf

## A synthetic pk2 holding `files` ({"folder\\name": bytes}), one directory
## block per folder, unencrypted (terrain_prepare_test.gd's writer).
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

