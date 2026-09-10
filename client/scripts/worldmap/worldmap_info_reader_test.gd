extends SceneTree

## Exercises WorldmapInfoReader against rows shaped like the real table
## (never real game data):
##   godot4 --headless --path client --script res://scripts/worldmap/worldmap_info_reader_test.gd
##
## The numbers below are the world map's row, Jangan's row and one dungeon
## floor, because those three are what everything turns on: they are what
## makes 33 x 11 tiles come to the 4224 x 1408 the file declares, what puts
## Jangan in the tile it is actually in, and what makes both maps' scale
## come out a round number.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _close(a: float, b: float) -> bool:
	return absf(a - b) < 0.01

func _row(cols: Array) -> String:
	var out := PackedStringArray()
	out.resize(23)
	out.fill("xxx")
	for i in range(cols.size()):
		out[i] = str(cols[i])
	return "\t".join(out)

func _init() -> void:
	# WLocalmap: id, type, name, addr, texW, texH, picW, picH, drawW, drawH,
	# left, top, right, bottom, LT_x, LT_y, RB_x, RB_y, fortress, name key,
	# button, one-region-size.
	var world := _row([0, 0, "-", "interface\\worldmap\\map\\map_world_",
		128, 128, 128, 128, 4224, 1408, 46, 113, 177, 70,
		0, 192, 192, 0, "xxx", "UIIT_PAG_WORLDMAP", 0, "4x4"])
	var local := _row([1, 1, "-", "interface\\worldmap\\map\\map_jangan.ddj",
		1024, 1024, 1024, 768, 1024, 768, 166, 99, 170, 96,
		96, 96, 96, 96, "xxx", "UIIT_STT_JANGAN", 1, "xxx"])
	# Jupiter is also type 0 -- a world of its own you switch to, not an
	# overlay on the main map -- so type alone does not name the world map.
	var jupiter := _row([16, 0, "-", "interface\\worldmap\\map\\map_jupiter_a.ddj",
		1024, 1024, 768, 1280, 768, 1280, 235, 122, 238, 117,
		0, 0, 0, 0, "xxx", "UIIT_STT_JUPITER_A", 1, "xxx"])
	# Dungeonmap: id, name, layer, layers, total, code, texcount x, texcount y,
	# drawW, drawH, left, top, right, bottom, scale, addr, region id.
	var dungeon := _row([2001, "-", "F", 1, 4, 32769, 3, 3, 768, 768,
		127, 128, 129, 126, 1.0, "interface\\worldmap\\dungeon\\map_world_donf01_", 1])

	var text := "#section\tWLocalmap\n" \
		+ "//Map File Info\n" \
		+ "//Map ID\tType\tName\tAddr\n" \
		+ world + "\n" + local + "\n" + jupiter + "\n" \
		+ _row(["//", 1, "-", "commented out row"]) + "\n" \
		+ "#section\tDungeonmap\n" \
		+ "//Map ID\tName\tlayer\n" \
		+ dungeon + "\n" \
		+ "#section\tSomethingNew\n" \
		+ _row([9001, 0, "-", "a section this reader has never seen"]) + "\n"
	var table := WorldmapInfoReader.parse(text.to_utf16_buffer())

	_check(table.maps.size() == 3,
		"three WLocalmap rows parsed; the section, the comments and the commented-out row are skipped (got %d)"
			% table.maps.size())
	_check(table.dungeons.size() == 1,
		"one Dungeonmap row parsed (got %d)" % table.dungeons.size())
	# A section this reader does not know is counted rather than read with
	# the wrong columns -- reading Dungeonmap rows as WLocalmap ones is how
	# this went wrong once, and produced maps whose artwork was the string
	# "1" and whose tiles were 1 x 32,797 pixels.
	_check(table.skipped_other_sections == 1,
		"a row in an unknown section is passed over and counted (got %d)"
			% table.skipped_other_sections)

	var wm := table.world()
	_check(wm != null and wm.id == 0,
		"the world map is the type-0 row drawn from tiles, not merely the first type-0 row")
	_check(table.worlds().size() == 2,
		"and the table has more than one type-0 row (got %d)" % table.worlds().size())
	if wm == null:
		_finish()
		return

	_check(wm.is_tiled(), "an addr ending in an underscore is a grid, not one image")
	_check(not table.by_id(1).is_tiled(), "an addr ending in .ddj is one image")
	_check(wm.name_key == "UIIT_PAG_WORLDMAP",
		"the name key is read even though the client's parser drops it (got %s)" % wm.name_key)

	# --- the grid ---------------------------------------------------------
	# The step comes from column 21, which the *client* does not read: its
	# loader steps by a literal 4. So the grid the step produces has to come
	# to the declared draw size, which is the check that the two agree.
	_check(wm.regions_per_tile == Vector2i(4, 4),
		"\"4x4\" reads as four regions a tile (got %s)" % str(wm.regions_per_tile))
	_check(table.by_id(1).regions_per_tile == Vector2i.ONE,
		"\"xxx\" reads as one region a tile")

	var tiles := wm.tiles()
	_check(tiles.size() == 33 * 11, "33 x 11 tiles (got %d)" % tiles.size())
	_check(tiles.size() == wm.tiles_across() * wm.tiles_down(),
		"the step's grid is the size the draw size implies (%d against %d)"
			% [tiles.size(), wm.tiles_across() * wm.tiles_down()])

	# The client loads the first component ascending and the second
	# descending, so the first tile is (left, top).
	_check(tiles[0] == "interface\\worldmap\\map\\map_world_46x113.ddj",
		"the first tile is (left, top) (got %s)" % tiles[0])
	_check(tiles[tiles.size() - 1] == "interface\\worldmap\\map\\map_world_174x73.ddj",
		"the last tile is (right, bottom) rounded to the step (got %s)" % tiles[tiles.size() - 1])

	# Jangan is region x=97, y=168. left/right are region y and top/bottom
	# are region x, so it falls in the tile starting at y=166, x=97.
	_check(wm.tile_for_region(97, 168) == "interface\\worldmap\\map\\map_world_166x97.ddj",
		"Jangan resolves to its own tile (got %s)" % wm.tile_for_region(97, 168))
	# A region exactly on a tile's first row resolves to that tile, not the
	# one before it.
	_check(wm.tile_for_region(97, 166) == "interface\\worldmap\\map\\map_world_166x97.ddj",
		"a region on a tile boundary belongs to that tile (got %s)" % wm.tile_for_region(97, 166))
	_check(wm.tile_for_region(97, 165) == "interface\\worldmap\\map\\map_world_162x97.ddj",
		"and the region below it belongs to the previous tile (got %s)" % wm.tile_for_region(97, 165))

	# Outside the map's own bounds there is no tile, rather than a name for
	# a file that does not exist.
	_check(wm.tile_for_region(97, 45) == "", "a region left of the map has no tile")
	_check(wm.tile_for_region(97, 178) == "", "a region right of the map has no tile")
	_check(wm.tile_for_region(114, 100) == "", "a region above the map has no tile")
	_check(wm.tile_for_region(69, 100) == "", "a region below the map has no tile")

	# --- the world-space box ---------------------------------------------
	# `(region_y - 135) * 192` horizontally and `(region_x - 92) * 192`
	# vertically, plus the LT/RB offsets, straight out of NIFWorldMap.cpp.
	_check(wm.world_min() == Vector2i(-17088, -4224),
		"the world map's low corner (got %s)" % str(wm.world_min()))
	_check(wm.world_max() == Vector2i(8256, 4224),
		"the world map's high corner (got %s)" % str(wm.world_max()))
	# 25344 / 4224 and 8448 / 1408 are both exactly six. A round number on
	# both axes at once is what says the axes are paired the right way
	# round: swap them and neither comes out clean.
	var upp := wm.units_per_pixel()
	_check(_close(upp.x, 6.0) and _close(upp.y, 6.0),
		"six world units to a world-map pixel, both axes (got %s)" % str(upp))

	var jangan := table.by_id(1)
	_check(jangan.world_min() == Vector2i(6048, 864)
		and jangan.world_max() == Vector2i(6816, 1440),
		"Jangan's own map covers 6048..6816 by 864..1440 (got %s .. %s)"
			% [str(jangan.world_min()), str(jangan.world_max())])
	var jangan_upp := jangan.units_per_pixel()
	_check(_close(jangan_upp.x, 0.75) and _close(jangan_upp.y, 0.75),
		"three quarters of a unit to a Jangan pixel, both axes (got %s)" % str(jangan_upp))

	# Jangan's town square is region 97/168 at local (1002, 917), which the
	# project's readout puts at world (6436.2, 1051.7). It has to land
	# inside Jangan's own map, and near enough its middle.
	var square := Vector2(
		(168 - 135) * 192 + 1002.0 / 10.0,
		(97 - 92) * 192 + 917.0 / 10.0)
	_check(jangan.covers_region(97, 168), "Jangan's map covers Jangan's region")
	_check(table.local_for_region(97, 168) == jangan,
		"and a region look-up finds it")
	var px := jangan.pixel_for_world(square)
	_check(px.x > 0.0 and px.x < jangan.draw_size.x and px.y > 0.0 and px.y < jangan.draw_size.y,
		"the town square falls inside Jangan's 1024x768 map (got %s)" % str(px))
	_check(_close(px.x, 517.60) and _close(px.y, 517.73),
		"at pixel (517.60, 517.73) (got %s)" % str(px))
	# And on the world map, where six units to a pixel puts it much further in.
	var world_px := wm.pixel_for_world(square)
	_check(_close(world_px.x, 3920.70) and _close(world_px.y, 528.72),
		"and at (3920.70, 528.72) on the world map (got %s)" % str(world_px))

	# --- the dungeon section ---------------------------------------------
	var floor1: WorldmapInfoReader.DungeonMapInfo = table.dungeons[0]
	_check(floor1.addr == "interface\\worldmap\\dungeon\\map_world_donf01_",
		"the dungeon path is column 15, not column 3 (got %s)" % floor1.addr)
	_check(floor1.zone_code == 32769,
		"the zone code is read (got %d)" % floor1.zone_code)
	var dtiles := floor1.tiles()
	_check(dtiles.size() == 9,
		"a 3 x 3 floor is nine tiles -- the count columns, not the bounds (got %d)" % dtiles.size())
	_check(dtiles[0].ends_with("_127x128.ddj") and dtiles[dtiles.size() - 1].ends_with("_129x126.ddj"),
		"named from (left, top) to (right, bottom) like the world map (got %s .. %s)"
			% [dtiles[0], dtiles[dtiles.size() - 1]])
	_check(floor1.region_left + floor1.texture_count.x - 1 == floor1.region_right
		and floor1.region_top - floor1.texture_count.y + 1 == floor1.region_bottom,
		"the tile counts and the region bounds agree, one region a tile")
	# The header spells the scale out: "1.0 = 256". 768 drawn over three
	# tiles is 256 a tile, so a scale of 1.0 is one region to a tile.
	_check(_close(floor1.pixels_per_region(), 256.0)
		and _close(float(floor1.draw_size.x) / floor1.texture_count.x, 256.0),
		"scale 1.0 is 256 pixels a region, which is what the draw size says (got %f)"
			% floor1.pixels_per_region())

	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
