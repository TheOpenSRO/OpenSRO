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
## string at 5, region at 41, x/y/z at 43..45, Scale 48, BCHeight 49 and
## BCRadius 50 (round 690; the values docs/protocol/teleport_network.md
## records for each gate).
func _building_rows() -> Array:
	return [
		_row(59, {0: 1, 1: 2094, 2: "STORE_CH_GATE", 5: "SN_NPC_CH_GATE", 41: 25000, 43: 1254, 44: -6, 45: 1374, 48: 100, 49: 25, 50: 10}),
		_row(59, {0: 1, 1: 2095, 2: "STORE_WC_GATE", 5: "SN_NPC_WC_GATE", 41: 26521, 43: 962, 44: -35, 45: 8, 48: 100, 49: 50, 50: 40}),
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
	if not here.is_empty():
		var b = here[0]
		_check(is_equal_approx(b.bc_height, 25.0) and is_equal_approx(b.bc_radius, 10.0),
			"STORE_CH_GATE: BCHeight 25 from column 49, BCRadius 10 from column 50 (round 690; got %s, %s)" % [str(b.get("bc_height")), str(b.get("bc_radius"))])
		var shed = here[1]
		_check(is_equal_approx(shed.bc_height, 0.0) and is_equal_approx(shed.bc_radius, 0.0), "a row with 0 in both keeps 0 (no box)")
	var wp: Array = reader.call("world_points") if reader.has_method("world_points") else []
	_check(_codes(wp) == ["GATE_CH", "GATE_WC", "GATE_KT", "GATE_TD"],
		"world_points: every point in a world region, in id order -- the town gates, GATE_KT and GATE_TD alike (got %s)" % [_codes(wp)])
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

		# (b) The pick box (round 690; READ: CITeleportGate::vslot_025 builds
		# (-r, -h, -r)..(r, h, r) from BCRadius / BCHeight about the gate's
		# position, axis-aligned). A region's objects, positioned
		# region-local in its RealMapObjects container under the terrain
		# group, which TerrainCollision.place_group mirrors in z as the grid
		# does: the portal is a placed COPY of a template held by an
		# ObjectTemplateCache, 3.6 units from STORE_CH_GATE's point (the
		# measured cj_portal.bsr placement); the portal stone at 7.5. The
		# gate's click is its box at the table point, not those objects.
		var has_bind := world.has_method("_bind_region_gates")
		_check(has_bind, "World3D has _bind_region_gates")
		var pick_layer: int = world_script.get_script_constant_map().get("GATE_PICK_COLLISION_LAYER", -1)
		_check(pick_layer > 0 and pick_layer & layer == 0 and pick_layer & 1 == 0,
			"the pick boxes have a layer of their own -- not the talk layer (the navmesh-wall bit the player masks), not layer 1 (got %d)" % pick_layer)
		if has_bind:
			world.set("_gate_bindings", {})
			var template := _piece_object("cj_portal")
			var cache := ObjectTemplateCache.new(func(_path: String) -> Node3D: return template)
			var group := Node3D.new()
			group.name = "RealTerrain_97_168"
			TerrainCollision.place_group(group, world_script.call("_cell_offset", 0, 0), 0.0)
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
			world.call("_bind_region_gates", 97, 168, group)
			var pick := group.get_node_or_null("GatePick_STORE_CH_GATE") as Node3D
			_check(pick != null, "Jangan's gate gets its pick node, GatePick_STORE_CH_GATE, under its region's group")
			if pick != null:
				_check(pick.get_meta("npc_name", "") == "Fixture Gate" and pick.get_meta("npc_code", "") == "STORE_CH_GATE" and pick.get_meta("gate_point_id", 0) == 1,
					"it carries the talk tags: npc_name from SN_NPC_CH_GATE, npc_code STORE_CH_GATE, gate_point_id 1")
				var at: Transform3D = world_script.call("_chain_transform", pick)
				var want: Vector3 = (world_script.call("_chain_transform", group) as Transform3D) * Vector3(1254.0, -6.0, 1374.0)
				_check(at.origin.distance_to(want) < 0.01,
					"centred on the building's table point (1254, -6, 1374) in its region's frame (got %s, want %s)" % [str(at.origin), str(want)])
				_check(at.basis.is_equal_approx(Basis.IDENTITY),
					"axis-aligned in the world: the node undoes the group's z mirror (world basis %s)" % str(at.basis))
				var bodies := pick.find_children("*", "StaticBody3D", true, false)
				var box_ok := false
				if bodies.size() == 1:
					var body := bodies[0] as StaticBody3D
					var cs := body.get_child(0) as CollisionShape3D
					box_ok = body.collision_layer == pick_layer and body.collision_mask == 0 and cs != null \
						and cs.shape is BoxShape3D and (cs.shape as BoxShape3D).size.is_equal_approx(Vector3(20.0, 50.0, 20.0))
				_check(box_ok, "one body, on the pick layer alone, mask 0, a 20 x 50 x 20 box -- 2 x BCRadius 10, 2 x BCHeight 25")
				var entry: Dictionary = (world.get("_gate_bindings") as Dictionary).get("STORE_CH_GATE", {})
				_check(entry.get("node") == pick, "_gate_bindings names the pick node")
			# NEGATIVE (the round-577 binding): the placed objects are not the
			# click any more -- untagged, their bodies on layer 1 alone.
			_check(not portal.has_meta("npc_name") and _body_layer(portal) == 1,
				"the placed portal is not a click target: untagged, its body on layer 1 alone (got layer 0b%s)" % String.num_int64(_body_layer(portal), 2))
			_check(not stone.has_meta("npc_name") and _body_layer(stone) == 1, "nor the portal stone")
			_check(_body_layer(template) == 1 and not template.has_meta("npc_name"),
				"the cache's template is untouched: layer 1, no tag")

			# (c) Alexandria North (the user's report, 2026-10-02). STORE_SD_GATE2
			# stands in 92/50 at (1719, 1586, 760), BCRadius 70 / BCHeight 70;
			# its point GATE_SD2 registers id 7. The portal is placed 15.1 units
			# from the table point (MEASURED, cmd/whatishere) -- beyond round
			# 577's 10, so it was never bound and the gate never clicked. Its
			# box does not need the portal at all.
			var sd_reader: Object = (load(READER_PATH) as GDScript).new()
			sd_reader.call("parse",
				_table(_data_rows() + [_row(14, {0: 1, 1: 176, 2: "GATE_SD2", 3: 27754, 4: "SN_ZONE_21836_16", 5: 23603,
					6: 111, 7: 1537, 8: 524, 9: 50, 10: 1, 11: 0, 12: 1})]),
				_table(_link_rows() + [_row(23, {0: 1, 1: 176, 2: 1, 3: 40000})]),
				_table(_building_rows() + [_row(59, {0: 1, 1: 27754, 2: "STORE_SD_GATE2", 5: "SN_STORE_AS_GATE_N",
					41: 23602, 43: 1719, 44: 1586, 45: 760, 48: 100, 49: 70, 50: 70})]))
			world.set("_teleport_reader", sd_reader)
			var group_sd := Node3D.new()
			group_sd.name = "RealTerrain_92_50"
			TerrainCollision.place_group(group_sd, world_script.call("_cell_offset", 0, 0), 0.0)
			var container_sd := Node3D.new()
			container_sd.name = "RealMapObjects_92_50"
			group_sd.add_child(container_sd)
			var alex := _piece_object("alex_portal")
			alex.name = "Obj_alex_portal_0"
			alex.position = Vector3(1719.15, 1549.42, 744.88)
			container_sd.add_child(alex)
			world.call("_bind_region_gates", 92, 50, group_sd)
			var pick_sd := group_sd.get_node_or_null("GatePick_STORE_SD_GATE2") as Node3D
			_check(pick_sd != null and pick_sd.get_meta("npc_code", "") == "STORE_SD_GATE2" and pick_sd.get_meta("gate_point_id", 0) == 176,
				"Alexandria North is clickable: its pick node carries STORE_SD_GATE2 and point 176")
			if pick_sd != null:
				var shape_sd := (pick_sd.find_children("*", "CollisionShape3D", true, false)[0] as CollisionShape3D).shape as BoxShape3D
				_check(shape_sd != null and shape_sd.size.is_equal_approx(Vector3(140.0, 140.0, 140.0)),
					"its box is 140 x 140 x 140 (BCRadius 70, BCHeight 70)")
				var box_sd := AABB((world_script.call("_chain_transform", pick_sd) as Transform3D).origin - Vector3(70, 70, 70), Vector3(140, 140, 140))
				var alex_at: Vector3 = (world_script.call("_chain_transform", alex) as Transform3D).origin
				_check(box_sd.has_point(alex_at), "and the portal drawn 15.1 units off its point stands inside it")
			# NEGATIVE: a row without a box (BCRadius 0) gets no pick node.
			var flat_reader: Object = (load(READER_PATH) as GDScript).new()
			flat_reader.call("parse", _table(_data_rows()), _table(_link_rows()),
				_table([_row(59, {0: 1, 1: 2094, 2: "STORE_CH_GATE", 5: "SN_NPC_CH_GATE", 41: 25000, 43: 1254, 44: -6, 45: 1374})]))
			world.set("_teleport_reader", flat_reader)
			var group_flat := Node3D.new()
			group_flat.name = "RealTerrain_97_168"
			world.call("_bind_region_gates", 97, 168, group_flat)
			_check(group_flat.get_child_count() == 0, "a gate row with no BCRadius/BCHeight gets no pick node (children %d)" % group_flat.get_child_count())

			# (d) NEGATIVE: a gate whose point does not register id 7. Retail's
			# fortress gates (STORE_CH_FORT_GATE1..3, in 92/167..169) are
			# teleportbuilding rows named by serviced teleportdata points with
			# outgoing links and column 10 = 0; one is placed here, in 97/168,
			# with a placed object exactly on its point. It gets no pick node
			# and its object no tag, while Jangan's town gate in the same
			# region still gets its box.
			var fort_reader: Object = (load(READER_PATH) as GDScript).new()
			fort_reader.call("parse",
				_table(_data_rows() + [_row(14, {0: 1, 1: 50, 2: "GATE_CH_FORT1", 3: 9001, 4: "SN_ZONE_FORT", 5: 25000,
					6: 400, 7: 0, 8: 400, 9: 50, 10: 0, 11: 0, 12: 1})]),
				_table(_link_rows() + [_row(23, {0: 1, 1: 50, 2: 1, 3: 0})]),
				_table(_building_rows() + [_row(59, {0: 1, 1: 9001, 2: "STORE_CH_FORT_GATE1", 5: "SN_NPC_CH_FORT_GATE1",
					41: 25000, 43: 400, 44: 0, 45: 400, 48: 100, 49: 30, 50: 30})]))
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
			world.call("_bind_region_gates", 97, 168, group3)
			_check(group3.get_node_or_null("GatePick_STORE_CH_FORT_GATE1") == null and not scenery.has_meta("npc_name") and _body_layer(scenery) == 1,
				"a fortress-gate row (links, no id 7) gets no pick node, and the object on its point no tag")
			_check(group3.get_node_or_null("GatePick_STORE_CH_GATE") != null,
				"while the town gate in the same region (id 7) gets its box")
			world.set("_teleport_reader", reader)
			for g in [group3, group, group_sd, group_flat]:
				g.free()
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

		# (f) Round 642's review: the talk box of a teleport NPC or gate closes
		# beyond the READ interaction range (0x4a8e10): 300 from an NPC, 800
		# from a structure, the 3-D length, the limit itself still inside.
		var near := Vector3(100, 0, 100)
		_check(not bool(world_script.call("talk_out_of_range", near, near + Vector3(300, 0, 0), false)),
			"300 from an NPC is within its range")
		_check(bool(world_script.call("talk_out_of_range", near, near + Vector3(300.5, 0, 0), false)),
			"300.5 from an NPC is beyond it")
		_check(bool(world_script.call("talk_out_of_range", near, near + Vector3(200, 250, 0), false)),
			"the height counts: 200 across and 250 up is 320 from an NPC")
		_check(not bool(world_script.call("talk_out_of_range", near, near + Vector3(0, 0, 790), true)),
			"790 from a gate structure is within its 800")
		_check(bool(world_script.call("talk_out_of_range", near, near + Vector3(0, 0, 810), true)),
			"810 from a gate structure is beyond it")

		# (g) Round 650: Donwhang's gate. STORE_WC_GATE stands in 103/153 at
		# local (962, 8), eight units from the edge with 102/153, where the
		# player arrives (GATE_WC), and its portal is held by 102/153's
		# container (a map object exists once, round 643). Round 650 searched
		# every container for it; since round 690 the box needs no placed
		# object at all: it is built in the building's own region, in that
		# region's frame. The groups stand as TerrainCollision.place_group
		# puts them (the frame region 102/153 at cell (0, 0), 103/153 one cell
		# over on region x, scale.z -1).
		var dw := _donwhang_grid(world_script)
		world.set("_object_containers", {"_102_153": dw["c102"], "_103_153": dw["c103"]})
		for g in [dw["g102"], dw["g103"]]:
			world.add_child(g)
		world.set("_gate_bindings", {})
		var dw_portal: Node3D = _piece_object("w_cd_portal")
		dw_portal.name = "Obj_w_cd_portal_0"
		dw_portal.position = Vector3(962.0 + 2.0, -35.0, 8.0 + 1920.0 + 2.5)
		(dw["c102"] as Node3D).add_child(dw_portal)
		world.call("_bind_region_gates", 103, 153, dw["g103"])
		var dw_pick := (dw["g103"] as Node3D).get_node_or_null("GatePick_STORE_WC_GATE") as Node3D
		_check(dw_pick != null and dw_pick.get_meta("npc_code", "") == "STORE_WC_GATE" and dw_pick.get_meta("gate_point_id", 0) == 2,
			"Donwhang's gate gets its pick node in its own region 103/153")
		if dw_pick != null:
			var dw_want: Vector3 = (world_script.call("_chain_transform", dw["g103"]) as Transform3D) * Vector3(962.0, -35.0, 8.0)
			var dw_at: Vector3 = (world_script.call("_chain_transform", dw_pick) as Transform3D).origin
			_check(dw_at.distance_to(dw_want) < 0.01, "at (962, -35, 8) in 103/153's frame (got %s, want %s)" % [str(dw_at), str(dw_want)])
			var portal_at: Vector3 = (world_script.call("_chain_transform", dw_portal) as Transform3D).origin
			_check(Vector2(portal_at.x - dw_at.x, portal_at.z - dw_at.z).length() < 40.0,
				"within its BCRadius 40 of the portal 102/153 holds (%.1f units in x/z)" % Vector2(portal_at.x - dw_at.x, portal_at.z - dw_at.z).length())
		_check(not dw_portal.has_meta("npc_code") and _body_layer(dw_portal) == 1, "the portal itself is not a click target")
		# The building region committing again (streamed out and back in):
		# one pick node, not two.
		world.call("_bind_region_gates", 103, 153, dw["g103"])
		var picks := (dw["g103"] as Node3D).get_children().filter(func(n): return String(n.name).begins_with("GatePick_"))
		_check(picks.size() == 1, "binding a region again replaces its pick node (got %d)" % picks.size())
		for g in [dw["g102"], dw["g103"]]:
			world.remove_child(g)
			g.free()
		world.set("_object_containers", {})
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

## Donwhang's two regions as the grid builds them for a player arriving at
## GATE_WC (round 650): RealTerrain_102_153 (the frame, cell 0,0) and
## RealTerrain_103_153 (one cell over on region x), each with its
## RealMapObjects container, placed by TerrainCollision.place_group at anchor
## height 0. The groups are returned outside any tree.
func _donwhang_grid(world_script: GDScript) -> Dictionary:
	var out := {}
	for spec in [[102, 0], [103, 1]]:
		var rx: int = spec[0]
		var dx: int = spec[1]
		var g := Node3D.new()
		g.name = "RealTerrain_%d_153" % rx
		TerrainCollision.place_group(g, world_script.call("_cell_offset", dx, 0), 0.0)
		var c := Node3D.new()
		c.name = "RealMapObjects_%d_153" % rx
		g.add_child(c)
		out["g%d" % rx] = g
		out["c%d" % rx] = c
	return out

func _body_layer(root: Node) -> int:
	var bodies := root.find_children("*", "StaticBody3D", true, false)
	return (bodies[0] as StaticBody3D).collision_layer if not bodies.is_empty() else -1
