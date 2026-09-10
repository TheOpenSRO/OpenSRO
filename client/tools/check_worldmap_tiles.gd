extends SceneTree

## Dev tool: reads the real `worldmap_mapinfo.txt` and checks that every
## image it calls for is really in the archive -- world map, local maps and
## dungeon floors alike.
##
## The table says the world map is `map_world_`, region left 46, top 113,
## right 177, bottom 70, four regions to a tile, drawn at 4224x1408. That
## predicts 33 x 11 = 363 specific file names. Either they are all there or
## the reading of the table is wrong, and this is which.
##
## It also prints each map's world-space box and its units-per-pixel, which
## is the other half of the check: those come out round numbers (6.0 for
## the world map, 0.75 for a city) only if the region bounds are paired
## with the right axes.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_worldmap_tiles.gd -- \
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
	var entry := ObjectLoader.find_file(archive, WorldmapInfoReader.TABLE_PATH)
	if entry == null:
		printerr("no ", WorldmapInfoReader.TABLE_PATH)
		quit(1)
		return
	var table := WorldmapInfoReader.parse(archive.read_file(entry))
	print("parsed %d map(s), %d dungeon floor(s), skipped %d row(s) in unknown sections" % [
		table.maps.size(), table.dungeons.size(), table.skipped_other_sections])

	var failures := 0
	print("\n--- WLocalmap")
	for info in table.maps:
		var wanted: PackedStringArray = info.tiles() if info.is_tiled() \
			else PackedStringArray([info.addr])
		failures += _report(archive, "id %-4d type %d" % [info.id, info.type],
			info.addr, wanted)
		var upp := info.units_per_pixel()
		print("     world %s .. %s, %.3f x %.3f units a pixel, %s" % [
			str(info.world_min()), str(info.world_max()), upp.x, upp.y, info.name_key])
		if info.is_tiled():
			print("     grid %d x %d at %s = %dx%d, declared draw %s" % [
				info.tiles_across(), info.tiles_down(), str(info.texture_size),
				info.tiles_across() * info.texture_size.x,
				info.tiles_down() * info.texture_size.y, str(info.draw_size)])
		if info == table.world():
			# Jangan, as the worked example: region x 97, y 168, town square
			# at local (1002, 917).
			var square := Vector2((168 - 135) * 192 + 100.2, (97 - 92) * 192 + 91.7)
			print("     Jangan (region x 97, y 168) -> %s, square at map pixel %s" % [
				info.tile_for_region(97, 168).get_file(), str(info.pixel_for_world(square))])

	print("\n--- Dungeonmap")
	for info in table.dungeons:
		failures += _report(archive, "id %-4d zone %-6d" % [info.id, info.zone_code],
			info.addr, info.tiles())
		var declared := float(info.draw_size.x) / maxi(1, info.texture_count.x)
		if not is_equal_approx(declared, info.pixels_per_region()):
			print("     scale %.3f says %.1f pixels a region, draw size says %.1f" % [
				info.scale, info.pixels_per_region(), declared])

	print("\n--- %d map(s) with missing artwork" % failures)
	quit(0)

func _report(archive, label: String, addr: String, wanted: PackedStringArray) -> int:
	var present := 0
	var missing: Array[String] = []
	for path in wanted:
		if ObjectLoader.find_file(archive, path) != null:
			present += 1
		elif missing.size() < 4:
			missing.append(path.get_file())
	var line := "  %s  %-44s %d/%d present" % [label, addr.get_file(), present, wanted.size()]
	if present == wanted.size():
		print(line)
		return 0
	print(line + "   MISSING e.g. " + ", ".join(PackedStringArray(missing)))
	return 1
