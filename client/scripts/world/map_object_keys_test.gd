extends SceneTree

## Round 643: the map's objects are the ones the retail loader builds -- a
## region's `.o2` lists 1 and 2, skip bit clear, one object per key, each in
## its OWNER region's frame -- and each exists once in the world however many
## regions list it. Against synthetic `.o2` bytes (never real game data).
## Run headless:
##   godot4 --headless --path client --script res://scripts/world/map_object_keys_test.gd
##
## Held to account:
## - MapO2Reader reads the owner region (bytes 28-29) and byte 27, and names
##   the loader's skip test and key (FUN_00a361b0 / Map::FUN_00a1a1d0);
## - World3D.region_placements takes list 1 as well as list 2 (the Hotan
##   stable and bridges and the Taklamakan temple sit in list 1 alone),
##   drops the skip bit, merges a key listed twice, and moves a neighbour's
##   object into the owner's frame;
## - that frame is the owner's: an object placed through a neighbour's
##   terrain group lands where the owner's group puts it (the groups placed
##   by TerrainCollision.place_group over World3D._cell_offset, as the world
##   places them);
## - _objects_commit places a key once across regions, and a region
##   streaming out hands what it holds to a region still listing it
##   (_release_region_objects), in the same place in the world.
##
## World3D.gd is reached through load() and call(), so on a tree without the
## change the suite FAILS instead of failing to parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

const JANGAN := (97 << 8) | 168
const EAST := (97 << 8) | 169 # 97/169: region_y + 1, one span along local x

func _initialize() -> void:
	_test_reader()
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S != null and S.can_instantiate():
		var names := {}
		for m in S.get_script_method_list():
			names[m["name"]] = true
		_check(names.has("region_placements"), "World3D.gd has region_placements (absent before round 643)")
		_check(names.has("_release_region_objects"), "World3D.gd has _release_region_objects (absent before round 643)")
		if names.has("region_placements"):
			_test_region_placements(S)
			_test_owner_frame(S)
		if names.has("_release_region_objects"):
			_test_one_object_per_key(S)
	print("ALL PASS" if _failures == 0 else "FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

## MapO2Reader.owner_offset, reached through call() so that a reader without
## it FAILS here rather than failing to parse (Vector3.INF when absent).
func _offset(owner: int, x: int, y: int) -> Vector3:
	var R := load("res://scripts/mapo/mapo2_reader.gd") as GDScript
	for m in R.get_script_method_list():
		if m["name"] == "owner_offset":
			return R.call("owner_offset", owner, x, y)
	return Vector3.INF

## Owner, skip byte, key and frame offset, read off raw records.
func _test_reader() -> void:
	var region := MapO2Reader.parse(_o2({2: [[7, Vector3(1, 2, 3), 5, EAST, 1], [8, Vector3(4, 5, 6), 9, JANGAN, 0]]}))
	_check(region != null, "the synthetic .o2 parses")
	if region == null:
		return
	var list: Array = region.sectors[0].lists[1]
	_check(list.size() == 2, "sector 0's list 1 holds the two records")
	if list.size() != 2:
		return
	var a = list[0]
	_check("owner_region" in a and "build_flags" in a, "MapO2Reader.Entry has owner_region and build_flags (absent before round 643)")
	if not ("owner_region" in a and a.has_method("object_key") and a.has_method("skipped")):
		_check(false, "MapO2Reader.Entry has object_key() and skipped() (absent before round 643)")
		return
	_check(a.owner_region == EAST and a.build_flags == 1 and a.skipped(), "bytes 28-29 are the owner 97/169, byte 27 bit 0 the skip bit")
	_check(a.object_key() == (EAST << 16) | 5, "the key is CONCAT22(owner, uid) (got %x)" % a.object_key())
	_check(not list[1].skipped() and list[1].object_key() == (JANGAN << 16) | 9, "a clear byte 27 is built; its key is its own")
	_check(_offset(EAST, 97, 168) == Vector3(1920, 0, 0), "97/169's frame is one span along local x from 97/168's (MapO2Reader.owner_offset, absent before round 643)")
	_check(_offset((98 << 8) | 168, 97, 168) == Vector3(0, 0, 1920), "98/168's is one span along local z")
	_check(_offset(JANGAN, 97, 168) == Vector3.ZERO, "the region's own records move nowhere")

## The retail set from one file: both lists, the skip bit, repeats, owners.
func _test_region_placements(S: GDScript) -> void:
	var region := MapO2Reader.parse(_o2({
		2: [[1, Vector3(100, 0, 100), 1, JANGAN, 0], [2, Vector3(300, 0, 300), 2, JANGAN, 0],
			[3, Vector3(50, 7, 60), 7, EAST, 0]],
		3: [[1, Vector3(100, 0, 100), 1, JANGAN, 0], [2, Vector3(500, 0, 500), 3, JANGAN, 0],
			[2, Vector3(600, 0, 600), 4, JANGAN, 1]],
	}))
	var got: Dictionary = S.call("region_placements", region, {"x": 97, "y": 168})
	var placements: Array = got.get("placements", [])
	var keys: Array = []
	for p in placements:
		keys.append(p["key"])
	_check(keys == [(JANGAN << 16) | 1, (JANGAN << 16) | 2, (EAST << 16) | 7, (JANGAN << 16) | 3],
		"list 1's three objects, then list 2's new one; the repeat and the skipped record left out (got %s)" % str(keys))
	_check(int(got.get("records", -1)) == 6 and int(got.get("repeats", -1)) == 1 and int(got.get("skipped", -1)) == 1
			and int(got.get("foreign", -1)) == 1,
		"6 records, 1 key listed again, 1 skip bit, 1 owned by a neighbour (got %s %s %s %s)" % [
			got.get("records"), got.get("repeats"), got.get("skipped"), got.get("foreign")])
	if placements.size() == 4:
		_check(placements[2]["position"] == Vector3(1970, 7, 60) and placements[2]["type_id"] == 3,
			"the neighbour's object moves one span along local x, into its owner's frame (got %s)" % str(placements[2]["position"]))
		_check(placements[1]["position"] == Vector3(300, 0, 300), "an own record keeps its position")

## An object placed through its neighbour's group lands where its owner's
## group would put it: the frame is the owner's.
func _test_owner_frame(S: GDScript) -> void:
	var here := Node3D.new()
	var east := Node3D.new()
	TerrainCollision.place_group(here, S.call("_cell_offset", 0, 0), 12.5)
	TerrainCollision.place_group(east, S.call("_cell_offset", 0, 1), 12.5)
	var local := Vector3(50, 7, 60)
	var through_here: Vector3 = here.transform * (local + _offset(EAST, 97, 168))
	var through_owner: Vector3 = east.transform * local
	_check(through_here.distance_to(through_owner) < 0.001,
		"97/169's object placed via 97/168 stands where 97/169 places it (%s vs %s)" % [str(through_here), str(through_owner)])
	here.free()
	east.free()

## Two regions listing one key: one object, handed over when its holder goes.
func _test_one_object_per_key(S: GDScript) -> void:
	var w: Node = S.new()
	w.set("_object_templates", ObjectTemplateCache.new(func(_path: String) -> Node3D: return Node3D.new()))
	var table := ObjidxReader.Table.new()
	var entries: Array[ObjidxReader.Entry] = []
	for id in range(4):
		var e := ObjidxReader.Entry.new()
		e.type_id = id
		e.path = ["", "prim\\wall.bsr", "prim\\tree.bsr", "prim\\post.bsr"][id]
		entries.append(e)
	table.entries = entries
	var groups := {}
	for pair in [["_97_168", 0], ["_97_169", 1]]:
		var g := Node3D.new()
		g.name = "RealTerrain" + pair[0]
		TerrainCollision.place_group(g, S.call("_cell_offset", 0, pair[1]), 0.0)
		w.add_child(g)
		groups[pair[0]] = g
	# 97/168 lists its wall and 97/169's tree; 97/169 lists the tree and a post.
	var here := MapO2Reader.parse(_o2({2: [[1, Vector3(100, 0, 100), 1, JANGAN, 0], [2, Vector3(50, 0, 60), 7, EAST, 0]]}))
	var east := MapO2Reader.parse(_o2({3: [[2, Vector3(50, 0, 60), 7, EAST, 0], [3, Vector3(900, 0, 900), 8, EAST, 0]]}))
	w.call("_objects_commit", _job(S, here, 97, 168, "_97_168", table))
	w.call("_objects_commit", _job(S, east, 97, 169, "_97_169", table))
	var c_here: Node = groups["_97_168"].get_node_or_null("RealMapObjects_97_168")
	var c_east: Node = groups["_97_169"].get_node_or_null("RealMapObjects_97_169")
	_check(c_here != null and c_east != null, "both regions' containers stand under their terrain groups")
	if c_here == null or c_east == null:
		w.free()
		return
	_check(c_here.get_child_count() == 2 and c_east.get_child_count() == 1,
		"97/168 places its wall and the tree; 97/169 only its post -- the tree is one object (got %d, %d)" % [
			c_here.get_child_count(), c_east.get_child_count()])
	var placed: Dictionary = w.get("_placed_objects")
	var tree_key := (EAST << 16) | 7
	_check(placed.size() == 3 and placed.has(tree_key) and (placed[tree_key]["listers"] as Dictionary).size() == 2,
		"three keys placed; the tree listed by both regions")
	if not placed.has(tree_key):
		w.free()
		return
	var tree: Node3D = placed[tree_key]["node"]
	var want: Vector3 = _in_world(groups["_97_169"]) * Vector3(50, 0, 60)
	_check(_in_world(tree).origin.distance_to(want) < 0.001,
		"the tree stands where its owner's frame puts it (%s vs %s)" % [str(_in_world(tree).origin), str(want)])
	var handed: Dictionary = w.call("_release_region_objects", "_97_168")
	_check(int(handed.get("moved", -1)) == 1 and int(handed.get("dropped", -1)) == 1,
		"97/168 streaming out hands the tree on and drops its own wall (got %s)" % str(handed))
	_check(tree.get_parent() == c_east and _in_world(tree).origin.distance_to(want) < 0.001
			and String(tree.name).begins_with("Obj_tree_"),
		"the tree now under 97/169's container, in the same place, still named Obj_tree_* (%s)" % tree.name)
	_check(placed.size() == 2 and placed[tree_key]["holder"] == "_97_169", "the registry follows it")
	w.call("_release_region_objects", "_97_169")
	_check(placed.is_empty(), "no lister left: every key forgotten")
	w.free()

## A node's transform in the world node's space, composed by hand (the
## world is not in a tree here, so global_transform is not available).
func _in_world(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var at: Node = n
	while at is Node3D:
		xf = (at as Node3D).transform * xf
		at = at.get_parent()
	return xf

## A committable job over one parsed `.o2` (the prepare's output shape).
func _job(S: GDScript, region: MapO2Reader.ParsedRegion, x: int, y: int, suffix: String, table: ObjidxReader.Table) -> Dictionary:
	var taken: Dictionary = S.call("region_placements", region, {"x": x, "y": y})
	return {"prepared": true, "placements": taken["placements"], "models": {}, "textures": {}, "log": [], "laps": [],
		"new_heightmaps": {}, "object_index": table, "node_suffix": suffix, "mapo_path": "%d\\%d.o" % [x, y],
		"world_offset": Vector3.ZERO, "threaded": false, "objects_o2": taken["records"], "objects_foreign": taken["foreign"]}

## A real-shaped `.o2` whose sector 0 holds `fields` ({field index: records});
## a record is [type, position, uid, owner region, byte 27].
func _o2(fields: Dictionary) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array((MapO2Reader.MAGIC + "1001").to_ascii_buffer())
	for sector in range(MapO2Reader.SECTORS_PER_SIDE * MapO2Reader.SECTORS_PER_SIDE):
		for field in range(MapO2Reader.FIELDS_PER_SECTOR):
			var records: Array = fields.get(field, []) if sector == 0 else []
			var c := PackedByteArray()
			c.resize(2)
			c.encode_u16(0, records.size())
			buf.append_array(c)
			for rec in records:
				var e := PackedByteArray()
				e.resize(MapO2Reader.ENTRY_LEN)
				e.encode_u32(0, rec[0])
				e.encode_float(4, rec[1].x)
				e.encode_float(8, rec[1].y)
				e.encode_float(12, rec[1].z)
				e.encode_u16(16, 0xffff)
				e.encode_u16(22, rec[2])
				e[27] = rec[4]
				e.encode_u16(28, rec[3])
				buf.append_array(e)
	return buf
