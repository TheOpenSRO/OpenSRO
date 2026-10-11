extends SceneTree

## Round 775: the world map's dungeon data -- the Dungeonmap row's name and
## layer columns and its box, scale and tile names as NIFWorldMap 0x6217e0
## computes them, the player's pixel as 0x60f660 does, the floor walks of
## 0x614280 / 0x6143b0, worldmap_localinfo.txt's signs (0x96f280, 0x6210b0)
## and worldmap_instanceinfo.txt's field points (0x9536a0, 0x60fa90).
## Synthetic rows shaped like the real tables (no game data):
##   godot4 --headless --path client --script res://scripts/worldmap/worldmap_dungeon_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _close(a: float, b: float) -> bool:
	return absf(a - b) < 0.01

func _row(cols: Array, width: int = 23) -> String:
	var out := PackedStringArray()
	out.resize(width)
	out.fill("0")
	for i in range(cols.size()):
		out[i] = str(cols[i])
	return "\t".join(out)

## Dungeonmap: id, name, layer, layers, total, code, count x, count y, draw w,
## draw h, left, top, right, bottom, scale, path, region id, floor key.
func _dungeon(id: int, name: String, layer: String, n: int, total: int, code: int,
		count: Vector2i, draw: Vector2i, bounds: Array, scale: float, path: String) -> String:
	return _row([id, name, layer, n, total, code, count.x, count.y, draw.x, draw.y,
		bounds[0], bounds[1], bounds[2], bounds[3], scale, path, code & 0x7fff, "KEY", 1])

func _init() -> void:
	var cave := [127, 128, 129, 126]
	var text := "#section\tWLocalmap\n#section\tDungeonmap\n//Map ID\tName\tlayer\n" \
		+ _dungeon(2001, "Cave", "F", 1, 4, 0x8001, Vector2i(3, 3), Vector2i(768, 768), cave, 1.0, "d\\cave_f1_") + "\n" \
		+ _dungeon(2002, "Cave", "F", 2, 4, 0x8001, Vector2i(3, 3), Vector2i(768, 768), cave, 1.0, "d\\cave_f2_") + "\n" \
		+ _dungeon(2004, "Cave", "F", 4, 4, 0x8001, Vector2i(3, 3), Vector2i(768, 768), cave, 1.0, "d\\cave_f4_") + "\n" \
		+ _dungeon(2010, "Tomb", "B", 2, 6, 0x8006, Vector2i(6, 8), Vector2i(768, 1024), [125, 132, 130, 125], 0.5, "d\\tomb_b2_") + "\n"
	var table := WorldmapInfoReader.parse(text.to_utf16_buffer())
	_check(table.dungeons.size() == 4, "four Dungeonmap rows (got %d)" % table.dungeons.size())
	var f1 := table.dungeon_by_id(2001)
	_check(f1 != null and f1.name == "Cave" and f1.layer == "F" and f1.layers == 1 and f1.total_layers == 4,
		"column 1 is the name and column 2 the layer (0x62c1eb / 0x62c20b; got %s %s)"
			% [f1.name if f1 else "?", f1.layer if f1 else "?"])

	# --- labels: 0x612920 / 0x60edd0 ----------------------------------------
	_check(f1.floor_label() == "1F" and f1.floor_label(3) == "3F" and f1.spinner_mode() == 2,
		"an F floor is spelled number-first, 1F (got %s)" % f1.floor_label())
	var tomb := table.dungeon_by_id(2010)
	_check(tomb.floor_label() == "B2" and tomb.spinner_mode() == 1,
		"any other letter goes first, B2 (got %s)" % tomb.floor_label())

	# --- the box and scale: 0x6217e0 ----------------------------------------
	var box := f1.box()
	_check(box == Vector4i(-1536, 6528, -960, 7104),
		"the box is (left-135)*192 .. ((right-135)*3+3)*64 by (bottom-92)*192 .. ((top-92)*3+3)*64 (got %s)" % box)
	var upp := f1.units_per_pixel()
	_check(_close(upp.x, 0.75) and _close(upp.y, 0.75), "576 units over 768 pixels, 0.75 a pixel (got %s)" % upp)
	_check(_close(f1.tile_side(), 256.0) and _close(tomb.tile_side(), 128.0),
		"a tile's side is the scale times 256 (0x6196d0; got %f, %f)" % [f1.tile_side(), tomb.tile_side()])
	_check(f1.tile_path(0, 0) == "d\\cave_f1_127x128.ddj" and f1.tile_path(2, 2) == "d\\cave_f1_129x126.ddj",
		"tile (a, b) is <path><left+a>x<top-b> (got %s, %s)" % [f1.tile_path(0, 0), f1.tile_path(2, 2)])

	# --- the player's pixel: 0x60f660 ---------------------------------------
	var p0 := f1.pixel_for_dungeon(Vector3(0, 50, 0))
	var p1 := f1.pixel_for_dungeon(Vector3(1920, 0, 1920))
	var p2 := f1.pixel_for_dungeon(Vector3(-1920, 0, -1920))
	_check(_close(p0.x, 256) and _close(p0.y, 256), "dungeon (0, 0) is at (256, 256): the middle column's left, the top row's bottom (got %s)" % p0)
	_check(_close(p1.x, 512) and _close(p1.y, 0), "(1920, 1920) at (512, 0) (got %s)" % p1)
	_check(_close(p2.x, 0) and _close(p2.y, 512), "(-1920, -1920) at (0, 512) (got %s)" % p2)
	# count_x / 2 is an integer halving: 6 / 2 = 3 = 128 - 125.
	var t0 := tomb.pixel_for_dungeon(Vector3(0, 0, 0))
	_check(_close(t0.x, 384) and _close(t0.y, 640),
		"on a half-scale floor (0, 0) is three columns of 128 in, at the bottom of row 4 (region 128; got %s)" % t0)

	# --- the walks: 0x614280 / 0x6143b0 -------------------------------------
	var walk := table.dungeon_walk()
	_check(walk.size() == 2 and walk[1].id == 2002, "the walk runs 2001, 2002 and stops at the first missing id (got %d)" % walk.size())
	_check(table.dungeon_for(0x8001, "2F") == 2002, "the player's floor is the row of its region id whose label is the floor's text")
	_check(table.dungeon_for(0x8001, "") == 0 and table.dungeon_for(0x8002, "1F") == 0,
		"no floor text, or another region id, finds nothing")
	_check(table.dungeon_for(0x8001, "4F") == 0, "a row past the walk's gap is not found")
	_check(table.dungeon_floor(2001, 2) == 2002 and table.dungeon_floor(2002, 1) == 2001,
		"the spinner's floor change finds the same name's row with that number")
	_check(table.dungeon_floor(2001, 3) == 0 and table.dungeon_floor(9999, 1) == 0, "a floor with no row is 0")

	# --- worldmap_localinfo.txt ---------------------------------------------
	var signs_text := "\n".join([
		"//service\t\tstring",
		_row([1, 92033, 2, "interface\\worldmap\\map\\icon.ddj", "a", "b", "c", 2001, 0, 147, 106, 20, 19, 32, 32, 0, 0, 0, 0, 0, 1, "xxx"], 22),
		_row([0, 92034, 2, "interface\\worldmap\\map\\off.ddj", "a", "b", "c", 2005, 0, 172, 102, 7, 0, 32, 32, 0, 0, 0, 0, 0, 1, "xxx"], 22),
		_row([1, 15000, 1, "STORE_GATE", "a", "b", "c", 0, 2001, -1, -1, 405, 394, 2, 0, 255, 244, 166, 0, 1, 1, "xxx"], 22),
		"// | //12006\t1",
	])
	var signs := WorldmapLocalInfoReader.parse(signs_text.to_utf16_buffer())
	_check(signs.signs.size() == 2, "service 0 and comment rows are skipped (0x9534c4; got %d)" % signs.signs.size())
	var icon: WorldmapLocalInfoReader.Sign = signs.signs[0]
	_check(icon.id == 92033 and icon.type == 2 and icon.link == 2001 and icon.parent == 0
		and icon.region_a == 147 and icon.region_b == 106 and icon.pos == Vector2i(20, 19) and icon.size == Vector2i(32, 32),
		"a picture sign's columns in the parser's order (0x96f280)")
	# The world map's own bounds: left 46, top 113 (WORLDMAP_FORMAT.md).
	_check(icon.anchor(46, 113) == Vector2i(20 + (147 - 46) * 32, 19 + (113 - 106) * 32),
		"a world-map sign sits 32 pixels a region from the world map's left and top (0x6210b0; got %s)" % icon.anchor(46, 113))
	var r := icon.rect(46, 113)
	_check(icon.hit(46, 113, r.get_center()) and not icon.hit(46, 113, r.position),
		"the hit test is strictly inside (0x623220)")
	var gate: WorldmapLocalInfoReader.Sign = signs.signs[1]
	_check(gate.type == 1 and gate.text == "STORE_GATE" and gate.anchor(46, 113) == Vector2i(405, 394)
		and gate.color == Color8(255, 244, 166) and gate.bold == 1,
		"a sign on another map is placed as written, with its colour and style bytes")
	_check(signs.for_map(2001).size() == 1 and signs.for_map(0).size() == 1, "signs are listed by the map they are drawn on")

	# --- worldmap_instanceinfo.txt ------------------------------------------
	var inst_text := "\n".join([
		"//CodeName\tName(Skip)\tRegionLeft\tRegionTop\tRegionRight\tRegionBottom\tMapRegionX\tMapRegionZ\tMapPosX\tMapPosY\tMapPosZ",
		"Worldmap_CAVE\tx\t1\t128\t1\t128\t147\t106\t1620\t474\t48",
		"Worldmap_TOMB\tx\t2\t128\t7\t128\t172\t102\t963\t107\t1480",
		"Worldmap_BACK\tx\t5\t100\t3\t90\t131\t105\t1751\t2\t982",
	])
	var inst := WorldmapInstanceInfoReader.parse(inst_text.to_utf16_buffer())
	_check(inst.by_region.size() == 7, "a box is expanded one region at a time, and a box whose start is past its end gives none (got %d)" % inst.by_region.size())
	var cave_e := inst.find(0x8001)
	var cave_pt: Vector2 = cave_e.world_point() if cave_e != null else Vector2.ZERO
	_check(cave_e != null and _close(cave_pt.x, (147 - 135) * 192 + 162.0) and _close(cave_pt.y, (106 - 92) * 192 + 4.8),
		"the field point is (x - 135) * 192 + MapPosX / 10, (z - 92) * 192 + MapPosZ / 10 (0x60fa90; got %s)" % cave_pt)
	_check(inst.find(0x8005) != null and inst.find(0x8005).code == "Worldmap_TOMB", "every region of a box finds its row")
	var fb: Variant = WorldmapInstanceInfoReader.field_point(null, 0x8003)
	_check(fb is Vector2 and fb == Vector2(7200, 2102) and WorldmapInstanceInfoReader.field_point(null, 0x8001) == Vector2(2465, 2693)
		and WorldmapInstanceInfoReader.field_point(null, 0x8010) == null,
		"without the table, the two constants of 0x610c5e")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
