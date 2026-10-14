extends SceneTree

## Round 786 (ground flicker): where the terrain draws two or more feathered
## overlays over the same quad, and how many overlay surfaces a region has.
## MapmTerrainBuilder draws a quad's dominant tile opaque and every other tile
## its four corners use as one alpha overlay each, all of a region's overlays
## in one mesh (one surface per tile ID). A quad whose corners use three or
## more tiles is covered by two or more overlays, and alpha blending is
## order-dependent, so those quads are where the overlays' draw order shows.
##
## ```
## OPENSRO_MAP_PK2_PATH=Map.pk2 CENSUS_REGIONS="96,168;97,168" \
##   godot4 --headless --path client --script res://tools/ground_overlap_census.gd
## ```
##
## CENSUS_ALL=1 walks every region the map archive has (x and y 0..255).
##
## Lines:
##   REGION <x>,<y> quads <n> two_tiles <n> three_plus <n> max_tiles <n> overlays <n>
##       overlays: the overlay surfaces the builder makes for the region (the
##       distinct tiles some quad uses but is not dominated by; every ID
##       counted as resolved)
##   HOT <x>,<y> local <lx>,<lz> three_plus_in_window <n>   the densest
##       8x8-quad window of three-plus quads (its centre, region units)
##   CENSUS regions <n> quads <n> three_plus <n> (<pct> %) max_overlays <n> at <x>,<y>

const SIDE := 96
const WINDOW := 8

func _texinfo(region: MapmReader.ParsedRegion, c: int, r: int) -> int:
	var bc := mini(c / 16, 5)
	var br := mini(r / 16, 5)
	var lc := c - bc * 16
	var lr := r - br * 16
	var extra: PackedByteArray = region.blocks[br * 6 + bc].vertices[lr * 17 + lc].extra
	return (extra.decode_u16(0) & 0x3ff) if extra.size() >= 2 else -1

func _initialize() -> void:
	var map := Pk2Reader.open(OS.get_environment("OPENSRO_MAP_PK2_PATH"))
	var spec := OS.get_environment("CENSUS_REGIONS")
	if OS.get_environment("CENSUS_ALL") == "1":
		var all := PackedStringArray()
		for x in 256:
			for y in 256:
				all.append("%d,%d" % [x, y])
		spec = ";".join(all)
	var quiet := OS.get_environment("CENSUS_QUIET") == "1"
	var total_quads := 0
	var total_three := 0
	var regions := 0
	var max_overlays := 0
	var max_at := ""
	var overlay_hist := {}
	for item in spec.split(";", false):
		var p := item.split(",")
		if p.size() != 2:
			continue
		var px := int(p[0])
		var py := int(p[1])
		var bytes := AssetSource.read_bytes("%d\\%d.m" % [px, py], map)
		if bytes.is_empty():
			continue
		var region := MapmReader.parse(bytes)
		if region == null or region.blocks.size() != 36:
			print("REGION %d,%d unparsed" % [px, py])
			continue
		regions += 1
		var three := PackedByteArray()
		three.resize(SIDE * SIDE)
		var two := 0
		var n3 := 0
		var max_tiles := 0
		var overlay_keys := {}
		for r in SIDE:
			for c in SIDE:
				# MapmTerrainBuilder's corner order and its dominant rule: the
				# first tile with the most corners.
				var ids := {}
				for d in [[0, 0], [0, 1], [1, 1], [1, 0]]:
					var k := _texinfo(region, c + int(d[1]), r + int(d[0]))
					ids[k] = int(ids.get(k, 0)) + 1
				var dominant := -1
				var most := 0
				for k in ids:
					if int(ids[k]) > most:
						most = int(ids[k])
						dominant = k
				for k in ids:
					if k != dominant:
						overlay_keys[k] = true
				max_tiles = maxi(max_tiles, ids.size())
				if ids.size() == 2:
					two += 1
				elif ids.size() >= 3:
					n3 += 1
					three[r * SIDE + c] = 1
		var best := -1
		var best_at := Vector2i.ZERO
		for r0 in range(0, SIDE - WINDOW + 1, 2):
			for c0 in range(0, SIDE - WINDOW + 1, 2):
				var n := 0
				for r in range(r0, r0 + WINDOW):
					for c in range(c0, c0 + WINDOW):
						n += three[r * SIDE + c]
				if n > best:
					best = n
					best_at = Vector2i(c0, r0)
		total_quads += SIDE * SIDE
		total_three += n3
		var nov := overlay_keys.size()
		overlay_hist[nov] = int(overlay_hist.get(nov, 0)) + 1
		if nov > max_overlays:
			max_overlays = nov
			max_at = "%d,%d" % [px, py]
		if not quiet:
			print("REGION %d,%d quads %d two_tiles %d three_plus %d max_tiles %d overlays %d" % [px, py, SIDE * SIDE, two, n3, max_tiles, nov])
			if best > 0:
				print("HOT %d,%d local %d,%d three_plus_in_window %d" % [px, py,
					(best_at.x + WINDOW / 2) * 20, (best_at.y + WINDOW / 2) * 20, best])
	var keys := overlay_hist.keys()
	keys.sort()
	var hist := PackedStringArray()
	for k in keys:
		hist.append("%d:%d" % [k, overlay_hist[k]])
	print("CENSUS overlays-per-region histogram %s" % " ".join(hist))
	print("CENSUS regions %d quads %d three_plus %d (%.2f %%) max_overlays %d at %s" % [regions, total_quads, total_three,
		100.0 * total_three / maxf(total_quads, 1.0), max_overlays, max_at])
	quit(0)
