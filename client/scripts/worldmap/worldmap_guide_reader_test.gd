extends SceneTree

## Exercises WorldmapGuideReader against rows shaped like the real table
## (never real game data), run headless:
##   godot4 --headless --path client --script res://scripts/worldmap/worldmap_guide_reader_test.gd
##
## The four sections have four different column layouts, and two of them
## carry the same six geometry columns at different indices -- MONSTER's x
## is column 8 and QUEST's is column 5. Reading one with the other's
## columns is the mistake to catch, and it is the mistake this file's
## sibling reader made once already on a different table.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _row(cols: Array) -> String:
	var out := PackedStringArray()
	out.resize(16)
	out.fill("xxx")
	for i in range(cols.size()):
		out[i] = str(cols[i])
	return "\t".join(out)

func _init() -> void:
	# MAP_MANAGER: service, name, start region, end region, texture size,
	# one region size, map id.
	var world_map := _row([1, "field", "46x113", "17x26", "128x128", "4x4", 0])
	var dungeon_map := _row([1, "dunhuang1", "127x128", "17x26", "256x256", "1x1", 2001])
	# MONSTER: service, name, code, area, kind, three orders, x, y,
	# region A, region B, pos x, pos y, colour.
	var mangnyang := _row([1, "망량", "MOB_CH_MANGNYANG", "field", "sub",
		10101, 10801, 10101, 3212, 559, 166, 97, 12, 47, "0x80000005"])
	# QUEST: service, name, code, kind, area, x, y, region A, region B,
	# pos x, pos y, monster code -- the geometry three columns earlier.
	var quest := _row([1, "장안 사냥", "QNO_CH_JANGAN_01", "main", "field",
		3852, 559, 166, 97, 12, 47, "MOB_CH_MANGNYANG"])
	var area := _row([1, "장안", "TOWN_JANGAN", "SN_ZONE_22001", "field", "sub"])

	var text := "#section\tMAP_MANAGER\t\t0\n" \
		+ "//서비스\t항목\t시작 리전\n" \
		+ world_map + "\n" + dungeon_map + "\n" \
		+ "#section\tAREA\n" + "//서비스\t이름\n" + area + "\n" \
		+ "#section\tMONSTER\n" + "//서비스\t이름\n" + mangnyang + "\n" \
		+ "//실제 데이터 영역\n" \
		+ "#section\tQUEST\n" + "//서비스\t퀘스트 이름\n" + quest + "\n" \
		+ "#section\tSOMETHING_NEW\n" + _row([1, "unknown"]) + "\n"
	var guide := WorldmapGuideReader.parse(text.to_utf16_buffer())

	_check(guide.maps.size() == 2, "two MAP_MANAGER rows (got %d)" % guide.maps.size())
	_check(guide.areas.size() == 1, "one AREA row (got %d)" % guide.areas.size())
	_check(guide.monsters.size() == 1, "one MONSTER row (got %d)" % guide.monsters.size())
	_check(guide.quests.size() == 1, "one QUEST row (got %d)" % guide.quests.size())
	_check(guide.skipped_other_sections == 1,
		"a section this reader does not know is counted, not read with the wrong columns (got %d)"
			% guide.skipped_other_sections)

	var field := guide.map_named("field")
	_check(field != null and field.map_id == 0,
		"the world map joins to worldmap_mapinfo.txt by its map id")
	if field == null:
		_finish()
		return
	# The same three facts worldmap_mapinfo.txt states about the world map,
	# in a separately authored table.
	_check(field.start_region == Vector2i(46, 113),
		"start region 46x113, which is left x top (got %s)" % str(field.start_region))
	_check(field.texture_size == Vector2i(128, 128) and field.regions_per_tile == Vector2i(4, 4),
		"128x128 tiles, four regions to a tile")
	_check(guide.map_named("dunhuang1").regions_per_tile == Vector2i(1, 1),
		"and a dungeon floor is one region to a tile")

	# The geometry, derived rather than read. Jangan's tile is 166x97,
	# which is column 30 and row 4 of the world map's grid.
	var mangnyang_point: WorldmapGuideReader.GuidePoint = guide.monsters[0]
	_check(mangnyang_point.region == Vector2i(166, 97) and mangnyang_point.pos == Vector2i(12, 47),
		"MONSTER's region is columns 10 and 11 and its offset 12 and 13 (got %s, %s)"
			% [str(mangnyang_point.region), str(mangnyang_point.pos)])
	var px := mangnyang_point.pixel_in(field)
	_check(px == Vector2i(30 * 128 + 12, 4 * 128 + 47),
		"a monster's pixel is tile index times 128 plus its offset (got %s)" % str(px))
	# Which is the *row* the stale x column disagrees with, and the y it
	# agrees with -- 559 is 4 * 128 + 47 exactly.
	_check(px.y == 559, "and the y matches the table's own stale column (got %d)" % px.y)
	_check(px.x == 3852 and px.x != 3212,
		"while the x does not: the table's is five tiles out for MOB_CH_ rows (got %d)" % px.x)

	var q: WorldmapGuideReader.GuidePoint = guide.quests[0]
	_check(q.region == Vector2i(166, 97) and q.pos == Vector2i(12, 47),
		"QUEST's geometry is three columns earlier and reads the same (got %s, %s)"
			% [str(q.region), str(q.pos)])
	_check(q.monster_code == "MOB_CH_MANGNYANG",
		"and a quest names the monster it is about (got %s)" % q.monster_code)
	_check(q.pixel_in(field) == px, "so both land on the same pixel")

	_check(guide.areas[0].code == "TOWN_JANGAN" and guide.areas[0].monster_code == "SN_ZONE_22001",
		"an area carries its code name and its string key")
	_check(guide.monsters_in("field", Vector2i(166, 97)).size() == 1,
		"and a tile can be asked what lives in it")
	_check(guide.monsters_in("field", Vector2i(46, 113)).is_empty(),
		"a tile with nothing in it comes back empty")

	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
