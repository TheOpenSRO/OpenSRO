extends SceneTree

## Dev tool: settles which way a region's minimap art is oriented, by
## correlating it against that region's own water.
##
## The minimap is a painted top-down image; nothing in it says which way up
## it goes, and the world carries a global `z -> -z` mirror (see World3D's
## terrain_group comment), so "obvious" is not good enough -- a minimap
## flipped in either axis still looks like a map. Water is the measurement:
## the navmesh's per-tile water flags give exact region-local positions, and
## water paints blue on the art. Correlating the two under all eight
## orientations (four rotations, each mirrored or not) tells you which one
## the art actually uses, rather than which one looks right.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_minimap_orientation.gd -- \
##     --map-pk2=/path/Map.pk2 --media-pk2=/path/Media.pk2 --regions=98/168,97/167

const GRID := 24 # cells a side to compare on

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

## Region-local water, as a GRID x GRID occupancy mask. Index [row][col]
## where col runs along region-local X and row along region-local Z -- the
## same space NvmCollision and NvmWater use.
func _water_mask(region: NvmReader.ParsedRegion, table: TileIndexReader.Table) -> Array:
	var mask := []
	for r in range(GRID):
		mask.append(PackedFloat32Array())
		mask[r].resize(GRID)
	if region == null or region.tiles.size() < NvmReader.TILE_COUNT:
		return mask
	var tside := NvmReader.TILE_MAP_SIDE
	for row in range(tside):
		for col in range(tside):
			var tile: NvmReader.Tile = region.tiles[row * tside + col]
			var entry = table.lookup(tile.texture_id)
			if entry == null:
				continue
			if entry.type != TileIndexReader.TileType.WATER and entry.type != TileIndexReader.TileType.DEEP_WATER:
				continue
			var gr := int(float(row) / float(tside) * GRID)
			var gc := int(float(col) / float(tside) * GRID)
			mask[gr][gc] = 1.0
	return mask

## Minimap blueness, as a GRID x GRID mask in image space (row 0 is the top
## of the image, col 0 the left).
func _blue_mask(image: Image) -> Array:
	var mask := []
	for r in range(GRID):
		mask.append(PackedFloat32Array())
		mask[r].resize(GRID)
	var w := image.get_width()
	var h := image.get_height()
	var counts := []
	for r in range(GRID):
		counts.append(PackedFloat32Array())
		counts[r].resize(GRID)
	for y in range(h):
		var gr := int(float(y) / float(h) * GRID)
		for x in range(w):
			var gc := int(float(x) / float(w) * GRID)
			var c := image.get_pixel(x, y)
			# "Noticeably bluer than it is red or green" -- the same test
			# check_water_vs_minimap.gd uses.
			if c.b > c.r + 0.06 and c.b > c.g + 0.03:
				mask[gr][gc] += 1.0
			counts[gr][gc] += 1.0
	for r in range(GRID):
		for c in range(GRID):
			if counts[r][c] > 0:
				mask[r][c] = 1.0 if mask[r][c] / counts[r][c] > 0.15 else 0.0
	return mask

## One of eight orientations of a GRID x GRID mask.
func _orient(mask: Array, which: int) -> Array:
	var out := []
	for r in range(GRID):
		out.append(PackedFloat32Array())
		out[r].resize(GRID)
	for r in range(GRID):
		for c in range(GRID):
			var sr := r
			var sc := c
			if which & 4:
				sc = GRID - 1 - sc # mirror in X
			match which & 3:
				0: pass
				1: # rotate 90
					var t := sr
					sr = sc
					sc = GRID - 1 - t
				2: # rotate 180
					sr = GRID - 1 - sr
					sc = GRID - 1 - sc
				3: # rotate 270
					var t2 := sr
					sr = GRID - 1 - sc
					sc = t2
			out[r][c] = mask[sr][sc]
	return out

## Intersection over union -- the honest score for two sparse masks, where
## plain agreement would be dominated by the empty majority.
func _iou(a: Array, b: Array) -> float:
	var inter := 0.0
	var union := 0.0
	for r in range(GRID):
		for c in range(GRID):
			var x: float = a[r][c]
			var y: float = b[r][c]
			if x > 0.0 or y > 0.0:
				union += 1.0
			if x > 0.0 and y > 0.0:
				inter += 1.0
	return 0.0 if union == 0.0 else inter / union

const NAMES := [
	"as-is", "rot90", "rot180", "rot270",
	"mirrorX", "mirrorX+rot90", "mirrorX+rot180", "mirrorX+rot270",
]

func _initialize() -> void:
	var map_pk2 := _arg("--map-pk2")
	var media_pk2 := _arg("--media-pk2")
	# Both the navmesh files and the tile-type table they index into live in
	# Data.pk2, under navmesh\\ -- not in Map.pk2, which holds the terrain
	# .m files and object placements. Map.pk2 is not needed here at all, but
	# is accepted so the tool reads like the others.
	var data_pk2 := _arg("--data-pk2")
	var regions := _arg("--regions", "98/168")
	if map_pk2 == "" or media_pk2 == "" or data_pk2 == "":
		printerr("usage: --map-pk2=<Map.pk2> --media-pk2=<Media.pk2> --data-pk2=<Data.pk2> [--regions=x/y,...]")
		quit(2)
		return
	var map_archive := Pk2Reader.open(map_pk2)
	var media_archive := Pk2Reader.open(media_pk2)
	if map_archive == null or media_archive == null:
		printerr("could not open the archives")
		quit(1)
		return

	var data_archive := Pk2Reader.open(data_pk2)
	if data_archive == null:
		printerr("could not open ", data_pk2)
		quit(1)
		return
	var tile_bytes := AssetSource.read_bytes("navmesh\\tile2d.ifo", data_archive)
	var table := TileIndexReader.parse(tile_bytes)
	if table == null:
		printerr("could not read navmesh\\tile2d.ifo")
		quit(1)
		return

	var totals := PackedFloat32Array()
	totals.resize(8)
	var counted := 0

	for spec in regions.split(","):
		var parts := spec.strip_edges().split("/")
		if parts.size() != 2:
			continue
		var rx := int(parts[0])
		var ry := int(parts[1])

		var nvm_bytes := AssetSource.read_bytes("navmesh\\nv_%04x.nvm" % ((rx << 8) | ry), data_archive)
		if nvm_bytes.is_empty():
			print("%d/%d: no navmesh" % [rx, ry])
			continue
		var region := NvmReader.parse(nvm_bytes)
		var water := _water_mask(region, table)
		var water_cells := 0
		for r in range(GRID):
			for c in range(GRID):
				if water[r][c] > 0.0:
					water_cells += 1
		if water_cells == 0:
			print("%d/%d: no water tiles -- nothing to correlate against" % [rx, ry])
			continue

		# The real minimap filename is minimap\<y>x<x>.ddj.
		var mm_bytes := AssetSource.read_bytes("minimap\\%dx%d.ddj" % [ry, rx], media_archive)
		if mm_bytes.is_empty():
			print("%d/%d: no minimap art" % [rx, ry])
			continue
		var parsed := DdjReader.parse(mm_bytes)
		if parsed == null:
			continue
		var tex := DdjReader.to_texture(parsed)
		if tex == null:
			continue
		# Region minimaps are DXT1, and get_pixel() refuses to read a
		# compressed image, so decompress before sampling.
		var mm_image := tex.get_image()
		if mm_image.is_compressed():
			mm_image.decompress()
		var blue := _blue_mask(mm_image)

		var blue_cells := 0
		for r in range(GRID):
			for c in range(GRID):
				if blue[r][c] > 0.0:
					blue_cells += 1
		print("\n%d/%d -- %d water cells, %d blue cells, of %d" % [
			rx, ry, water_cells, blue_cells, GRID * GRID])
		if blue_cells == 0:
			# Check the probe before believing the result: with no blue
			# cells every orientation scores zero and "best" is meaningless.
			print("   no blue cells found -- this region cannot settle orientation")
			continue
		for which in range(8):
			var score := _iou(_orient(blue, which), water)
			totals[which] += score
			print("   %-16s IoU %.3f" % [NAMES[which], score])
		counted += 1

	if counted > 1:
		print("\nmean over %d region(s):" % counted)
		var best := 0
		for which in range(8):
			if totals[which] > totals[best]:
				best = which
			print("   %-16s %.3f" % [NAMES[which], totals[which] / counted])
		print("\nbest: %s" % NAMES[best])
	quit(0)
