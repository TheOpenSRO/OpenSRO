extends SceneTree

## Exercises TeleportReader (round 577) against synthetic rows shaped like the
## real teleportdata.txt / teleportlink.txt / teleportbuilding.txt -- UTF-16LE
## with the FF FE BOM, tab-separated, CRLF, ending in a //Copyright line, as
## the archive stores them (never real game data: the values are the ones
## docs/protocol/teleport_network.md records for Jangan's gate) -- and, in
## _initialize, World3D's gate binding and talk lines over it:
##   godot4 --headless --path client --script res://scripts/npc/teleport_reader_test.gd
##
## The reader is loaded by path and reached through call()/get(), so a tree
## without it FAILS here rather than failing to parse.

const READER_PATH := "res://scripts/npc/teleport_reader.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A tab-separated row `width` fields wide from {column index: value}, every
## other field "0".
func _row(width: int, fields: Dictionary) -> String:
	var cols := PackedStringArray()
	cols.resize(width)
	cols.fill("0")
	for k in fields:
		cols[int(k)] = str(fields[k])
	return "\t".join(cols)

## The rows as the archive stores a table: optionally the UTF-16LE BOM, CRLF
## line ends, and the trailing //Copyright line.
func _table(rows: Array, bom: bool = true) -> PackedByteArray:
	var text := "\r\n".join(PackedStringArray(rows)) + "\r\n//Copyright line, as the real files end\r\n"
	var out := PackedByteArray([0xFF, 0xFE]) if bom else PackedByteArray()
	return out + text.to_utf16_buffer()

## teleportdata.txt, 14 fields: service, id, codename (space-padded in the
## real file), object, zone name, region, x, y, z, radius, the two
## interaction flags, a small integer.
func _data_rows() -> Array:
	return [
		# Row 1 of the real file is GATE_CH -- the row a BOM left on the first
		# field would lose.
		_row(14, {0: 1, 1: 1, 2: "GATE_CH                    ", 3: 2094, 4: "SN_ZONE_22001", 5: 25000,
			6: 969, 7: 0, 8: 1369, 9: 150, 10: 1, 11: 0, 12: 1}),
		_row(14, {0: 1, 1: 2, 2: "GATE_WC", 3: 2095, 4: "SN_ZONE_22002", 5: 26265,
			6: 957, 7: -80, 8: 1508, 9: 200, 10: 1, 11: 0, 12: 1}),
		_row(14, {0: 1, 1: 8, 2: "GATE_TD", 3: 2197, 4: "SN_ZONE_TD", 5: 24758,
			6: 641, 7: -3, 8: 728, 9: 70, 10: 0, 11: 1, 12: 1}),
		# A non-numeric id: skipped.
		_row(14, {0: 1, 1: "abc", 2: "GATE_BAD", 3: 7777, 4: "SN_ZONE_BAD", 5: 25000}),
		# Service 0: the client's loader never parses it.
		_row(14, {0: 0, 1: 99, 2: "GATE_OFF", 3: 8888, 4: "SN_ZONE_OFF", 5: 25000}),
		_row(14, {0: 1, 1: 5, 2: "GATE_KT", 3: 2096, 4: "SN_ZONE_22003", 5: 23687}),
	]

## teleportlink.txt, 23 fields: service, from, to, fee, then 0s and the
## restriction triples from column 7.
func _link_rows() -> Array:
	return [
		_row(23, {0: 1, 1: 1, 2: 2, 3: 5000, 7: 2}),
		_row(23, {0: 1, 1: 2, 2: 1, 3: 5000, 7: 2}),
		_row(23, {0: 1, 1: 1, 2: 175, 3: 40000, 7: 1, 9: 999, 10: 2}),
		_row(23, {0: 1, 1: 1, 2: 5, 3: 5000, 7: 1, 8: 1, 9: 110, 10: 2}),
		_row(23, {0: 0, 1: 1, 2: 99, 3: 1}),
	]

## teleportbuilding.txt, 59 fields: service, id, codename, ..., the name
## string at 5, region at 41, x/y/z at 43..45.
func _building_rows() -> Array:
	return [
		_row(59, {0: 1, 1: 2094, 2: "STORE_CH_GATE", 5: "SN_NPC_CH_GATE", 41: 25000, 43: 1254, 44: -6, 45: 1374}),
		_row(59, {0: 1, 1: 2095, 2: "STORE_WC_GATE", 5: "SN_NPC_WC_GATE", 41: 26521, 43: 962, 44: -35, 45: 8}),
		_row(59, {0: 1, 1: 2197, 2: "STORE_TD_GATE", 5: "xxx", 41: 24758, 43: 641, 44: -3, 45: 728}),
		# A dungeon's structure (a negative region) and one with region 0.
		_row(59, {0: 1, 1: 22896, 2: "STORE_TQ_SNAKEGATE", 5: "SN_X", 41: -32764, 43: -655, 44: 7, 45: -172}),
		_row(59, {0: 1, 1: 19556, 2: "INS_QUEST_TELEPORT", 5: "SN_Y", 41: 0}),
		# A second structure in Jangan's region that no point names.
		_row(59, {0: 1, 1: 4242, 2: "STORE_CH_SHED", 5: "SN_Z", 41: 25000, 43: 100, 44: 0, 45: 100}),
	]

func _reader(bom: bool) -> Object:
	var reader_script := load(READER_PATH) as GDScript
	if reader_script == null or not reader_script.can_instantiate():
		return null
	var reader: Object = reader_script.new()
	reader.call("parse", _table(_data_rows(), bom), _table(_link_rows(), bom), _table(_building_rows(), bom))
	return reader

func _codes(items: Array) -> Array:
	return items.map(func(x): return x.code)

func _init() -> void:
	var reader := _reader(true)
	_check(reader != null, "TeleportReader loads and instantiates")
	if reader == null:
		return

	# NEGATIVE: the BOM. Every table's first row survives it -- GATE_CH, whose
	# service field the BOM would otherwise prefix.
	var ch = reader.call("point_for_building", "STORE_CH_GATE")
	_check(ch != null and ch.id == 1 and ch.code == "GATE_CH",
		"with the FF FE BOM, teleportdata row 1 (GATE_CH) is read and joins STORE_CH_GATE (got %s)" % [str(ch.code) if ch != null else "null"])
	if ch != null:
		_check(ch.object_id == 2094 and ch.zone_strid == "SN_ZONE_22001" and ch.region == 25000,
			"its object 2094, zone SN_ZONE_22001 and region 25000 (got %d %s %d)" % [ch.object_id, ch.zone_strid, ch.region])
		_check(is_equal_approx(ch.x, 969.0) and is_equal_approx(ch.y, 0.0) and is_equal_approx(ch.z, 1369.0) and is_equal_approx(ch.radius, 150.0),
			"its local point (969, 0, 1369) and radius 150")
		_check(ch.interaction7 and not ch.interaction9, "a town gate registers id 7 and not id 9 (columns 10/11 = 1, 0)")
	var td = reader.call("point_for_building", "STORE_TD_GATE")
	_check(td != null and not td.interaction7 and td.interaction9, "GATE_TD registers id 9 only (0, 1)")
	var from_ch: Array = reader.call("links_from", 1)
	var to_ids: Array = from_ch.map(func(l): return l.to_id)
	_check(to_ids == [2, 175, 5],
		"with the BOM, teleportlink row 1 (1 -> 2) is read, and the links leave in file order, the service-0 row dropped (got %s)" % [to_ids])
	var fees: Array = from_ch.map(func(l): return l.fee)
	_check(fees == [5000, 40000, 5000], "each link's fee is column 3 (got %s)" % [fees])
	_check((reader.call("links_from", 2) as Array).size() == 1, "GATE_WC has its own link")
	_check((reader.call("links_from", 8) as Array).is_empty(), "GATE_TD has no outgoing link")
	var here: Array = reader.call("buildings_in_region", 97, 168)
	_check(_codes(here) == ["STORE_CH_GATE", "STORE_CH_SHED"],
		"with the BOM, teleportbuilding row 1 is read: region 25000 is 97/168, in file order (got %s)" % [_codes(here)])
	if not here.is_empty():
		var b = here[0]
		_check(b.id == 2094 and b.name_strid == "SN_NPC_CH_GATE" and is_equal_approx(b.x, 1254.0) and is_equal_approx(b.y, -6.0) and is_equal_approx(b.z, 1374.0),
			"STORE_CH_GATE: id 2094, SN_NPC_CH_GATE, local (1254, -6, 1374) from columns 43-45")
	_check(_codes(reader.call("buildings_in_region", 103, 153)) == ["STORE_WC_GATE"],
		"region 26521 is 103/153 ((x << 8) | y)")
	_check((reader.call("buildings_in_region", 128, 4) as Array).is_empty() and (reader.call("buildings_in_region", 0, 0) as Array).is_empty(),
		"a dungeon's structure (region -32764) and a region-0 row are in no region")

	# A row with a non-numeric id is skipped; so is a service-0 row.
	_check(reader.call("place_token", 99) == "", "a service-0 teleportdata row is not read")
	_check(reader.call("summary") == "4 teleport point(s), 4 link(s), 6 gate building(s)",
		"4 points (the non-numeric id and the service-0 row skipped), 4 links, 6 buildings (got %s)" % reader.call("summary"))
	_check(reader.call("place_token", 1) == "SN_ZONE_22001" and reader.call("place_token", 2) == "SN_ZONE_22002",
		"place_token is the point's zone-name string id")
	_check(reader.call("place_token", 12345) == "", "an unknown point has no place token")
	_check(reader.call("point_for_building", "STORE_CH_SHED") == null, "a structure no point names is not a teleport point")
	_check(reader.call("point_for_building", "NPC_CH_SMITH") == null and reader.call("point_for_building", "") == null,
		"an NPC codename or an empty one is not a gate")
	_check(reader.call("point_for_building", "store_ch_gate") != null, "the codename is matched without case")

	# The same tables without the BOM read the same.
	var plain := _reader(false)
	_check(plain != null and plain.call("summary") == reader.call("summary") and plain.call("point_for_building", "STORE_CH_GATE") != null,
		"without the BOM the same rows are read")

	# load() reads the three archive paths through the callback.
	var tables := {
		"server_dep\\silkroad\\textdata\\teleportdata.txt": _table(_data_rows()),
		"server_dep\\silkroad\\textdata\\teleportlink.txt": _table(_link_rows()),
		"server_dep\\silkroad\\textdata\\teleportbuilding.txt": _table(_building_rows()),
	}
	var reader_script := load(READER_PATH) as GDScript
	var loaded: Object = reader_script.new().call("load", func(path: String) -> PackedByteArray:
		return tables.get(path, PackedByteArray()))
	_check(loaded != null and loaded.call("summary") == reader.call("summary"), "load() reads the three textdata paths")
	var empty: Object = reader_script.new().call("load", func(_path: String) -> PackedByteArray: return PackedByteArray())
	_check(empty.call("summary") == "0 teleport point(s), 0 link(s), 0 gate building(s)" and empty.call("point_for_building", "STORE_CH_GATE") == null,
		"an archive without the tables gives an empty network, not an error")

## World3D's side (round 577), in _initialize: World3D names the NetClient
## autoload, which a --script suite registers only after _init (see
## error_text_test.gd). Reached through has_method/call, so a World3D without
## the binding FAILS here rather than failing to parse.
func _initialize() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles in _initialize")
	var reader := _reader(true)
	if world_ok and reader != null:
		var world: Node = world_script.new()
		world.set("_teleport_reader", reader)
		# textdata_object, as _object_names reads it: the gate's name string.
		var names_row := PackedStringArray()
		names_row.resize(10)
		names_row.fill("0")
		names_row[0] = "1"
		names_row[1] = "SN_NPC_CH_GATE"
		names_row[8] = "Fixture Gate"
		world.set("_object_name_table", UiTextTable.parse(("\t".join(names_row) + "\n").to_utf16_buffer()))
		var layer: int = world_script.get_script_constant_map().get("NPC_COLLISION_LAYER", -1)

		# (a) The talk lines: the gate code alone is no shop, warehouse or
		# guild pattern; World3D adds its gate lines from the point.
		_check(NpcServiceReader.services_for("STORE_CH_GATE", {}).is_empty(),
			"services_for(\"STORE_CH_GATE\") alone offers nothing")
		var services: Array = world.call("_npc_services", "STORE_CH_GATE")
		var keys: Array = services.map(func(s): return s.key)
		_check(keys == ["recall_designate", "teleport"],
			"Jangan's gate offers the designate line then the teleport line, the client's order (got %s)" % [keys])
		var td_keys: Array = (world.call("_npc_services", "STORE_TD_GATE") as Array).map(func(s): return s.key)
		_check(td_keys == ["recall_return"], "GATE_TD (id 9, no links) offers the return line alone (got %s)" % [td_keys])
		var smith: Array = world.call("_npc_services", "NPC_CH_SMITH")
		_check(smith.map(func(s): return s.key).filter(func(k): return k in ["teleport", "recall_designate", "recall_return"]).is_empty(),
			"an NPC gets no gate line")

		# (b) The binding. A region's objects, positioned region-local in its
		# RealMapObjects container under the terrain group: the portal is a
		# placed COPY of a template held by an ObjectTemplateCache, 3.6 units
		# from STORE_CH_GATE's point (the measured cj_portal.bsr placement);
		# the portal stone at 7.5; something else 40 away.
		var has_bind := world.has_method("_bind_region_gates")
		_check(has_bind, "World3D has _bind_region_gates")
		if has_bind:
			var template := _piece_object("cj_portal")
			var cache := ObjectTemplateCache.new(func(_path: String) -> Node3D: return template)
			var group := Node3D.new()
			group.name = "RealTerrain_97_168"
			var container := Node3D.new()
			container.name = "RealMapObjects_97_168"
			group.add_child(container)
			var portal := cache.instance("res\\bldg\\china\\jangan01\\cj_portal.bsr", "97\\168.o")
			portal.name = "Obj_cj_portal_0"
			portal.position = Vector3(1257.14, -33.0, 1375.71)
			container.add_child(portal)
			var stone := _piece_object("cj_portal_stone")
			stone.name = "Obj_cj_portal_stone_1"
			stone.position = Vector3(1254.0 + 7.5, 0.0, 1374.0)
			container.add_child(stone)
			var far := _piece_object("cj_house")
			far.name = "Obj_cj_house_2"
			far.position = Vector3(1294.0, 0.0, 1374.0)
			container.add_child(far)
			world.call("_bind_region_gates", 97, 168, group)
			_check(portal.get_meta("npc_name", "") == "Fixture Gate" and portal.get_meta("npc_code", "") == "STORE_CH_GATE" and portal.get_meta("gate_point_id", 0) == 1,
				"the nearest placed object within 10 units is the gate: npc_name from SN_NPC_CH_GATE, npc_code STORE_CH_GATE, gate_point_id 1")
			_check(_body_layer(portal) == (1 | layer),
				"its piece body keeps layer 1 and gains the talk layer (got 0b%s)" % String.num_int64(_body_layer(portal), 2))
			_check(_body_layer(template) == 1 and not template.has_meta("npc_name"),
				"the cache's template is untouched: layer 1, no tag")
			_check(not stone.has_meta("npc_name") and _body_layer(stone) == 1 and not far.has_meta("npc_name"),
				"the farther objects are not tagged")
			# The talk ray's walk: from the piece body up to the tag.
			var node: Node = portal.find_children("*", "StaticBody3D", true, false)[0]
			while node != null and not node.has_meta("npc_name"):
				node = node.get_parent()
			_check(node == portal, "a hit on the portal's piece body walks up to the tagged copy")

			# (c) NEGATIVE of the rule: nothing within 10 units -> the gate is
			# left unbound: no placed object tagged, and no stand-in body added
			# (the talk layer is the navmesh-wall bit the player's body masks,
			# so a stand-in would be an invisible wall).
			var group2 := Node3D.new()
			group2.name = "RealTerrain_97_168"
			var container2 := Node3D.new()
			container2.name = "RealMapObjects_97_168"
			group2.add_child(container2)
			var lone := _piece_object("cj_house")
			lone.position = Vector3(1254.0 + 12.0, 0.0, 1374.0)
			container2.add_child(lone)
			world.call("_bind_region_gates", 97, 168, group2)
			_check(not lone.has_meta("npc_name") and _body_layer(lone) == 1,
				"an object 12 units off is not taken: untagged, its body still on layer 1 alone")
			_check(group2.get_child_count() == 1 and container2.get_child_count() == 1,
				"and no stand-in collider is added anywhere (group children %d, container children %d)" % [group2.get_child_count(), container2.get_child_count()])

			# (d) NEGATIVE: a gate whose point does not register id 7. Retail's
			# fortress gates (STORE_CH_FORT_GATE1..3, in 92/167..169) are
			# teleportbuilding rows named by serviced teleportdata points with
			# outgoing links and column 10 = 0; one is placed here, in 97/168,
			# with a placed object exactly on its point. It must be neither
			# tagged nor given a stand-in, while Jangan's town gate in the same
			# region still binds.
			var fort_reader: Object = (load(READER_PATH) as GDScript).new()
			fort_reader.call("parse",
				_table(_data_rows() + [_row(14, {0: 1, 1: 50, 2: "GATE_CH_FORT1", 3: 9001, 4: "SN_ZONE_FORT", 5: 25000,
					6: 400, 7: 0, 8: 400, 9: 50, 10: 0, 11: 0, 12: 1})]),
				_table(_link_rows() + [_row(23, {0: 1, 1: 50, 2: 1, 3: 0})]),
				_table(_building_rows() + [_row(59, {0: 1, 1: 9001, 2: "STORE_CH_FORT_GATE1", 5: "SN_NPC_CH_FORT_GATE1",
					41: 25000, 43: 400, 44: 0, 45: 400})]))
			var fort_point = fort_reader.call("point_for_building", "STORE_CH_FORT_GATE1")
			_check(fort_point != null and not fort_point.interaction7 and not (fort_reader.call("links_from", 50) as Array).is_empty(),
				"the fixture's fortress gate is a teleport point with a link and no id-7 registration")
			world.set("_teleport_reader", fort_reader)
			var group3 := Node3D.new()
			group3.name = "RealTerrain_97_168"
			var container3 := Node3D.new()
			container3.name = "RealMapObjects_97_168"
			group3.add_child(container3)
			var scenery := _piece_object("cj_wall")
			scenery.name = "Obj_cj_wall_0"
			scenery.position = Vector3(400.0, 0.0, 400.0)
			container3.add_child(scenery)
			var portal3 := _piece_object("cj_portal")
			portal3.name = "Obj_cj_portal_1"
			portal3.position = Vector3(1257.14, -33.0, 1375.71)
			container3.add_child(portal3)
			world.call("_bind_region_gates", 97, 168, group3)
			_check(not scenery.has_meta("npc_name") and not scenery.has_meta("npc_code") and _body_layer(scenery) == 1,
				"a fortress-gate row (links, no id 7) does not tag the object on its point: no npc_name/npc_code, body on layer 1 alone")
			_check(group3.get_child_count() == 1 and container3.get_child_count() == 2,
				"and gets no stand-in collider (group children %d, container children %d)" % [group3.get_child_count(), container3.get_child_count()])
			_check(portal3.get_meta("npc_code", "") == "STORE_CH_GATE",
				"while the town gate in the same region (id 7) still binds")
			world.set("_teleport_reader", reader)
			group3.free()
			group.free()
			group2.free()
			template.free()

		# (e) Round 642: a teleport NPC. GATE_NPC_CH_FERRY's associated object
		# is 2011, NPC_CH_FERRY's characterdata id (teleportdata column 3), and
		# its link leaves for the far bank (3 -> 4, 500 gold). The ferry
		# seller's talk box offers the teleport line and nothing else -- its
		# point registers neither id 7 nor id 9 -- and the destination list is
		# its point's. A smith, whose id no point names, still gets no gate
		# line, and a ferry the NPC tables do not know gets none either.
		var ferry_reader: Object = (load(READER_PATH) as GDScript).new()
		ferry_reader.call("parse",
			_table(_data_rows() + [
				_row(14, {0: 1, 1: 3, 2: "GATE_NPC_CH_FERRY", 3: 2011, 4: "SN_ZONE_21002", 5: 24993,
					6: 560, 7: 140, 8: 1460, 9: 200, 10: 0, 11: 0, 12: 1}),
				_row(14, {0: 1, 1: 4, 2: "GATE_NPC_WC_FERRY", 3: 2056, 4: "SN_ZONE_21004", 5: 25761,
					6: 636, 7: 160, 8: 1482, 9: 200, 10: 0, 11: 0, 12: 1})]),
			_table(_link_rows() + [_row(23, {0: 1, 1: 3, 2: 4, 3: 500}), _row(23, {0: 1, 1: 4, 2: 3, 3: 500})]),
			_table(_building_rows()))
		var by_object = ferry_reader.call("point_for_object", 2011)
		_check(by_object != null and by_object.code == "GATE_NPC_CH_FERRY",
			"point_for_object(2011) is the ferry's point (got %s)" % [by_object.code if by_object != null else "null"])
		_check(ferry_reader.call("point_for_object", 0) == null and ferry_reader.call("point_for_object", 4242) == null,
			"point_for_object(0) and an object no point names give null")
		_check(ferry_reader.call("point_for_building", "NPC_CH_FERRY") == null,
			"the ferry is not a building (point_for_building does not find it)")
		world.set("_teleport_reader", ferry_reader)
		world.set("_npc_codes", {2011: "NPC_CH_FERRY", 2056: "NPC_WC_FERRY", 2000: "NPC_CH_SMITH"})
		var ferry_keys: Array = (world.call("_npc_services", "NPC_CH_FERRY") as Array).map(func(s): return s.key)
		_check(ferry_keys == ["teleport"], "the ferry seller offers the teleport line alone (got %s)" % [ferry_keys])
		var smith_keys: Array = (world.call("_npc_services", "NPC_CH_SMITH") as Array).map(func(s): return s.key)
		_check(not ("teleport" in smith_keys), "the smith still offers no teleport line (got %s)" % [smith_keys])
		var ferry_point = world.call("_teleport_point_for_code", "npc_ch_ferry")
		_check(ferry_point != null and ferry_point.id == 3, "the codename is matched without case")
		var dests: Array = (ferry_reader.call("links_from", 3) as Array).map(func(l): return [l.to_id, l.fee])
		_check(dests == [[4, 500]], "the ferry lists the far bank for 500 (got %s)" % [dests])
		world.set("_npc_codes", {2056: "NPC_WC_FERRY"})
		_check((world.call("_npc_services", "NPC_CH_FERRY") as Array).is_empty(),
			"a ferry the NPC tables do not know gets no line")
		world.set("_teleport_reader", reader)
		world.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A placed object shaped as ObjectLoader builds one: a root, a MeshInstance3D
## per piece, and under it a StaticBody3D on the default layer 1.
func _piece_object(root_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = root_name
	var piece := MeshInstance3D.new()
	piece.name = "piece"
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	piece.add_child(body)
	root.add_child(piece)
	return root

func _body_layer(root: Node) -> int:
	var bodies := root.find_children("*", "StaticBody3D", true, false)
	return (bodies[0] as StaticBody3D).collision_layer if not bodies.is_empty() else -1
