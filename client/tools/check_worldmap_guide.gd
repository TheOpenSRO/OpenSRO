extends SceneTree

## Dev tool: cross-checks `worldmapguidedata.txt` against
## `worldmap_mapinfo.txt`, and measures how far the guide's own pixel
## columns can be trusted.
##
## The two tables were authored separately and say overlapping things, so
## each is a check on the other: MAP_MANAGER's `시작 리전` should be the
## `left x top` of the map with the same id, its picture size the same
## texture size, and its `한 리전크기` the same regions per tile.
##
## It also reproduces the reason `WorldmapGuideReader` refuses to read the
## `x`/`y` columns. For every MONSTER and QUEST row on the world map's own
## grid it compares the table's pixel against the pixel the region and the
## `pos_` columns imply, and prints the distribution of the difference in
## whole tiles. The answer is not noise: it is exactly two populations.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_worldmap_guide.gd -- \
##     --pk2=/path/to/Media.pk2

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
	if pk2_path == "":
		printerr("usage: --pk2=<Media.pk2>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	var guide := WorldmapGuideReader.parse(_read(archive, WorldmapGuideReader.TABLE_PATH))
	var table := WorldmapInfoReader.parse(_read(archive, WorldmapInfoReader.TABLE_PATH))
	if guide == null or table == null:
		printerr("one of the tables is missing")
		quit(1)
		return
	print("guide: %d map(s), %d area(s), %d monster(s), %d quest(s), %d row(s) in unknown sections" % [
		guide.maps.size(), guide.areas.size(), guide.monsters.size(), guide.quests.size(),
		guide.skipped_other_sections])

	print("\n--- MAP_MANAGER against worldmap_mapinfo.txt")
	var disagreements := 0
	for m in guide.maps:
		var info: WorldmapInfoReader.MapInfo = table.by_id(m.map_id)
		var line := "  %-16s id %-5d start %-9s tile %-9s per-region %s" % [
			m.name, m.map_id, str(m.start_region), str(m.texture_size), str(m.regions_per_tile)]
		if info == null:
			# Dungeon floors live in the other section, so most of these
			# are expected: say which rather than counting them as wrong.
			print(line + "   (no WLocalmap row -- a dungeon floor)")
			continue
		var want_start := Vector2i(info.region_left, info.region_top)
		if m.start_region != want_start or m.texture_size != info.texture_size:
			disagreements += 1
			print(line + "   DISAGREES: mapinfo says start %s tile %s" % [
				str(want_start), str(info.texture_size)])
			continue
		if not info.is_tiled():
			# `한 리젼 크기` is only meaningful on a tiled row -- a single
			# image writes "xxx" -- so there is nothing to compare it
			# against, and saying so is more useful than a false agreement.
			# `jupiter_field` is the case that matters: worldmap_mapinfo
			# gives it as one image and the guide as a 4-region grid at the
			# same origin, which is what the archive's spare tile lattice
			# at 199x103 turns out to be.
			print(line + "   agrees; mapinfo has it as one image, the guide as a grid")
			continue
		if m.regions_per_tile != info.regions_per_tile:
			disagreements += 1
			print(line + "   DISAGREES: mapinfo says per-region %s" % str(info.regions_per_tile))
			continue
		print(line + "   agrees")

	var world := table.world()
	if world == null:
		print("\nno world map row, so nothing to measure the points against")
		quit(0)
		return
	var field := guide.map_named("field")
	if field == null:
		print("\nthe guide has no `field` map")
		quit(0)
		return

	print("\n--- the guide's own pixel columns, against the pixel its regions imply")
	_measure("MONSTER", guide.monsters, field, world)
	_measure("QUEST", guide.quests, field, world)
	print("\n--- %d MAP_MANAGER row(s) disagreeing with worldmap_mapinfo.txt" % disagreements)
	quit(0)

## Reports, for one section, how the table's `x`/`y` compare with the pixel
## its region and `pos_` columns imply -- in whole tiles, so a clean offset
## shows up as a single number rather than a spread.
func _measure(label: String, points: Array, field: WorldmapGuideReader.GuideMap,
		world: WorldmapInfoReader.MapInfo) -> void:
	var on_grid := 0
	var by_offset := {}
	var ragged := 0
	for p in points:
		if p.area != field.name or not world.covers_region(p.region.y, p.region.x):
			continue
		# Only tiles the world map really has: the table names a few
		# regions off its grid entirely.
		if world.tile_for_region(p.region.y, p.region.x) == "":
			continue
		on_grid += 1
		var derived := field.pixel(p.region, p.pos)
		var delta: Vector2i = p.stated_pixel - derived
		if delta.x % field.texture_size.x != 0 or delta.y % field.texture_size.y != 0:
			ragged += 1
			continue
		var key := Vector2i(delta.x / field.texture_size.x, delta.y / field.texture_size.y)
		by_offset[key] = int(by_offset.get(key, 0)) + 1
	print("  %s: %d row(s) on the world map's grid" % [label, on_grid])
	for key in by_offset:
		print("     stated minus derived = %s tile(s): %d row(s)%s" % [
			str(key), by_offset[key], "   <- exact" if key == Vector2i.ZERO else ""])
	if ragged > 0:
		print("     %d row(s) whose stated pixel is not a whole number of tiles off" % ragged)

static func _read(archive, path: String) -> PackedByteArray:
	var entry := ObjectLoader.find_file(archive, path)
	return archive.read_file(entry) if entry != null else PackedByteArray()
