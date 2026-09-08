extends SceneTree

## Dev tool: reports what a region's navmesh says about water -- how many
## plane cells are marked as water, and which real tile types actually sit
## under them.
##
## Exists because a region can be marked as having water and still render
## none: the water surface is built where a real *water tile* falls inside a
## real *water plane cell*, so a region whose plane map says water while its
## tiles classify as something else produces nothing at all, silently.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_nvm_water.gd -- \
##     --pk2=/path/Data.pk2 --map=/path/Map.pk2 --regions=96/168,98/167
##
## With --map it also reports, per water plane cell, what share of the
## terrain under it lies below that cell's own water level -- which is the
## share a water surface would actually be visible over.

const NAVMESH_PATH_FORMAT := "navmesh\\nv_%04x.nvm"
const TILE_INDEX_PATH := "navmesh\\tile2d.ifo"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _initialize() -> void:
	var data_path := _arg("--pk2")
	var map_path := _arg("--map")
	var regions := _arg("--regions")
	if data_path == "" or regions == "":
		printerr("usage: --pk2=<Data.pk2> --regions=96/168,...")
		quit(2)
		return
	var data := Pk2Reader.open(data_path)
	if data == null:
		printerr("could not open ", data_path)
		quit(1)
		return
	var table := TileIndexReader.parse(AssetSource.read_bytes(TILE_INDEX_PATH, data))
	if table == null:
		printerr("could not read the tile index")
		quit(1)
		return

	var map_archive: Pk2Reader = Pk2Reader.open(map_path) if map_path != "" else null

	for spec in regions.split(","):
		var parts := spec.strip_edges().split("/")
		if parts.size() != 2:
			continue
		var heightmap: MapmReader.ParsedRegion = null
		if map_archive != null:
			var mbytes := AssetSource.read_bytes("%s\\%s.m" % [parts[0], parts[1]], map_archive)
			if not mbytes.is_empty():
				heightmap = MapmReader.parse(mbytes)
		var key := (int(parts[0]) << 8) | int(parts[1])
		var bytes := AssetSource.read_bytes(NAVMESH_PATH_FORMAT % key, data)
		if bytes.is_empty():
			print("%s: no navmesh" % spec)
			continue
		var region := NvmReader.parse(bytes)
		if region == null:
			print("%s: navmesh did not parse" % spec)
			continue

		var side := NvmReader.PLANE_MAP_SIDE
		var tside := NvmReader.TILE_MAP_SIDE
		var water_cells := 0
		var counts := {}
		var water_tiles := 0
		for prow in range(side):
			for pcol in range(side):
				if region.plane_types[prow * side + pcol] != NvmWater.PLANE_TYPE_WATER:
					continue
				water_cells += 1
				var per := tside / side
				for r in range(prow * per, (prow + 1) * per):
					for c in range(pcol * per, (pcol + 1) * per):
						var tile: NvmReader.Tile = region.tiles[r * tside + c]
						var entry = table.lookup(tile.texture_id)
						var name := "id %d (not in tile2d.ifo)" % tile.texture_id
						if entry != null:
							name = "id %d type %d" % [entry.id, entry.type]
							if entry.type == TileIndexReader.TileType.WATER \
								or entry.type == TileIndexReader.TileType.DEEP_WATER:
								water_tiles += 1
						counts[name] = counts.get(name, 0) + 1
		# How much of each water cell would actually show water, if the
		# surface were drawn wherever the ground lies below the cell's own
		# level rather than only where a tile is classified as water.
		var submerged := 0
		var sampled := 0
		var real_submerged := 0
		var real_sampled := 0
		var levels := {}
		if heightmap != null:
			var cell := 1920.0 / float(side)
			for prow in range(side):
				for pcol in range(side):
					if region.plane_types[prow * side + pcol] != NvmWater.PLANE_TYPE_WATER:
						continue
					var level := region.plane_heights[prow * side + pcol]
					levels[level] = levels.get(level, 0) + 1
					for i in range(16):
						for j in range(16):
							var x := (float(pcol) + (float(i) + 0.5) / 16.0) * cell
							var z := (float(prow) + (float(j) + 0.5) / 16.0) * cell
							var h := MapmTerrainBuilder.height_at(heightmap, x, z)
							if is_nan(h):
								continue
							sampled += 1
							if h < level:
								submerged += 1
							# The same figure, ignoring cells whose level is
							# exactly 100 -- a suspiciously round value that
							# sits far above its own ground.
							if level != 100.0:
								real_sampled += 1
								if h < level:
									real_submerged += 1
		# Where the water cells actually are, and at what level, so a render
		# can be aimed at one.
		if heightmap != null:
			var cell := 1920.0 / float(side)
			print("    water cells (local x, z of centre -> level, mean ground):")
			var shown := 0
			for prow in range(side):
				for pcol in range(side):
					if region.plane_types[prow * side + pcol] != NvmWater.PLANE_TYPE_WATER:
						continue
					if shown >= 8:
						continue
					shown += 1
					var cx := (float(pcol) + 0.5) * cell
					var cz := (float(prow) + 0.5) * cell
					var g := MapmTerrainBuilder.height_at(heightmap, cx, cz)
					print("      (%6.0f, %6.0f) -> level %8.2f, ground %8.2f" % [
						cx, cz, region.plane_heights[prow * side + pcol], g])
		var keys := counts.keys()
		keys.sort_custom(func(a, b): return counts[a] > counts[b])
		var real_share := (100.0 * float(real_submerged) / float(real_sampled)) if real_sampled > 0 else NAN
		print("    distinct plane levels: %s" % [levels])
		print("    ignoring level==100 cells: %.1f%% of the rest is below its own level" % real_share)
		var share := (100.0 * float(submerged) / float(sampled)) if sampled > 0 else NAN
		print("%s: %d water plane cell(s), %d water tile(s) under them, %.1f%% of their ground is below water level" % [
			spec, water_cells, water_tiles, share])
		for i in range(mini(keys.size(), 6)):
			print("    %6d x %s" % [counts[keys[i]], keys[i]])
	quit(0)
