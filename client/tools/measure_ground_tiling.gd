extends SceneTree

## Measures a region's ground texturing against the rules read out of the
## retail client (docs/RE_COMPLETION.md, round 610): the per-vertex
## TextureInfo at a spot, what the texture-repeat rule gives there, the region's
## `.t` lightmap term, and how our per-cell ground colour compares with the
## region's own authored minimap with and without that lightmap term.
##
## ```
## OPENSRO_PK2_PATH=Data.pk2 OPENSRO_MAP_PK2_PATH=Map.pk2 \
##   OPENSRO_MEDIA_PK2_PATH=Media.pk2 \
##   MEASURE_SPOT="97,168,955,185" MEASURE_REGIONS="97,168;96,168" \
##   godot4 --headless --path client --script res://tools/measure_ground_tiling.gd
## ```
##
## MEASURE_SPOT is `<path x>,<path y>,<local x>,<local z>`: the `.m` is
## `<path x>\<path y>.m` (the same order World3D and audit_terrain_fidelity.gd
## use) and the local position is in region units (0..1920). The minimap is
## `minimap\<path y>x<path x>.ddj` (AGENTS.md's name rule).
##
## Lines:
##   V r c id b10 top3 file      the vertex grid around the spot
##   UV ...                      the repeat the old and the read rule give there
##   STATS ...                   region-wide TextureInfo bit statistics
##   LM ...                      the lightmap term, sat(lm + TerrainShadowColor)
##   MM <area> before/after ...  mean |ours - minimap| per channel, 0..1

const SIDE := 96
const WINDOW := 8

var _tile_color_cache := {}

func _tile_color(map: Pk2Reader, table: TileIndexReader.Table, id: int) -> Color:
	if _tile_color_cache.has(id):
		return _tile_color_cache[id]
	var col := Color(0.5, 0.5, 0.5)
	var e = table.lookup(id)
	if e != null:
		var bytes := AssetSource.read_bytes("Tile2D\\%s" % String(e.filename), map)
		if not bytes.is_empty():
			var parsed := DdjReader.parse(bytes)
			if parsed != null:
				var img := DdjReader.to_image(parsed)
				if img != null:
					if img.is_compressed():
						img = img.duplicate()
						img.decompress()
					img.resize(1, 1, Image.INTERPOLATE_LANCZOS)
					col = img.get_pixel(0, 0)
	_tile_color_cache[id] = col
	return col

func _minimap(media: Pk2Reader, px: int, py: int) -> Image:
	var bytes := AssetSource.read_bytes("minimap\\%dx%d.ddj" % [py, px], media)
	if bytes.is_empty():
		return null
	var parsed := DdjReader.parse(bytes)
	if parsed == null:
		return null
	var img := DdjReader.to_image(parsed)
	if img == null:
		return null
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	img.resize(SIDE, SIDE, Image.INTERPOLATE_LANCZOS)
	return img

func _texinfo(region: MapmReader.ParsedRegion, c: int, r: int) -> int:
	var bc := mini(c / 16, 5)
	var br := mini(r / 16, 5)
	var lc := c - bc * 16
	var lr := r - br * 16
	var extra: PackedByteArray = region.blocks[br * 6 + bc].vertices[lr * 17 + lc].extra
	return extra.decode_u16(0) if extra.size() >= 2 else -1

## Our per-cell ground colour under the builder's blend (unchanged by round
## 610): the quad's dominant tile opaque, then every other tile its corners
## use in ascending ID order at the mean of its corner alphas.
func _cell_color(map: Pk2Reader, table: TileIndexReader.Table, region: MapmReader.ParsedRegion, c: int, r: int) -> Color:
	var counts := {}
	for d in [[0, 0], [1, 0], [1, 1], [0, 1]]:
		var id: int = _texinfo(region, c + int(d[0]), r + int(d[1])) & 0x3ff
		counts[id] = int(counts.get(id, 0)) + 1
	var dominant := -1
	var best := 0
	var keys := counts.keys()
	keys.sort()
	for k in keys:
		if int(counts[k]) > best:
			best = int(counts[k])
			dominant = k
	var col := _tile_color(map, table, dominant)
	for k in keys:
		if k == dominant:
			continue
		col = col.lerp(_tile_color(map, table, k), float(counts[k]) / 4.0)
	return col

func _env_shadow(data: Pk2Reader, map: Pk2Reader, region: MapmReader.ParsedRegion) -> Color:
	var bytes := AssetSource.read_bytes("environment.ifo", map)
	if bytes.is_empty():
		return Color(-1, -1, -1)
	var parsed := EnvironmentReader.parse(bytes)
	if parsed == null:
		return Color(-1, -1, -1)
	for rec in parsed.records:
		if rec.key == region.blocks[0].environment_id:
			return EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_TERRAIN_SHADOW_COLOR, 0.5)  # World3D.ENVIRONMENT_REFERENCE_TIME)
	return Color(-1, -1, -1)

static func _pearson(xs: PackedFloat32Array, ys: PackedFloat32Array) -> float:
	var n := float(xs.size())
	var mx := 0.0
	var my := 0.0
	for i in range(xs.size()):
		mx += xs[i]
		my += ys[i]
	mx /= n
	my /= n
	var sxy := 0.0
	var sxx := 0.0
	var syy := 0.0
	for i in range(xs.size()):
		sxy += (xs[i] - mx) * (ys[i] - my)
		sxx += (xs[i] - mx) * (xs[i] - mx)
		syy += (ys[i] - my) * (ys[i] - my)
	return sxy / sqrt(sxx * syy) if sxx > 0.0 and syy > 0.0 else 0.0

func _initialize() -> void:
	var data := Pk2Reader.open(OS.get_environment("OPENSRO_PK2_PATH"))
	var map := Pk2Reader.open(OS.get_environment("OPENSRO_MAP_PK2_PATH"))
	var media := Pk2Reader.open(OS.get_environment("OPENSRO_MEDIA_PK2_PATH"))
	var table := TileIndexReader.parse(AssetSource.read_bytes("navmesh\\tile2d.ifo", data))
	var spot := OS.get_environment("MEASURE_SPOT").split(",")
	var regions := OS.get_environment("MEASURE_REGIONS").split(";", false)
	for spec in regions:
		var p := spec.split(",")
		var px := int(p[0])
		var py := int(p[1])
		var region := MapmReader.parse(AssetSource.read_bytes("%d\\%d.m" % [px, py], map))
		if region == null:
			print("R %d %d PARSE_FAIL" % [px, py])
			continue
		var at_spot := spot.size() == 4 and int(spot[0]) == px and int(spot[1]) == py
		var sc := int(float(spot[2]) / 20.0) if at_spot else SIDE / 2
		var sr := int(float(spot[3]) / 20.0) if at_spot else SIDE / 2
		print("R %d %d spot cell c=%d r=%d (%s)" % [px, py, sc, sr, "reported" if at_spot else "centre"])

		# The vertex grid around the spot.
		if at_spot:
			for r in range(maxi(sr - 3, 0), mini(sr + 5, SIDE + 1)):
				for c in range(maxi(sc - 3, 0), mini(sc + 5, SIDE + 1)):
					var t := _texinfo(region, c, r)
					var e = table.lookup(t & 0x3ff)
					print("V r=%d c=%d id=%d b10=%d top3=%d %s" % [r, c, t & 0x3ff, (t >> 10) & 7, (t >> 13) & 7, String(e.filename) if e != null else "?"])
			# tile2d.ifo's own line for each ID at the spot: its trailing {a,b}
			# is the grass scatter FUN_00a27880 reads (object, percent).
			var ifo := AssetSource.read_bytes("navmesh\\tile2d.ifo", data).get_string_from_ascii().split("\n")
			var ids_here := {}
			for r in range(maxi(sr - 3, 0), mini(sr + 5, SIDE + 1)):
				for c in range(maxi(sc - 3, 0), mini(sc + 5, SIDE + 1)):
					ids_here[_texinfo(region, c, r) & 0x3ff] = true
			for id in ids_here:
				for l in ifo:
					if l.begins_with("%05d " % id):
						print("TILE2D " + l.strip_edges())
			var t0 := _texinfo(region, sc, sr)
			var s: float = MapmTerrainBuilder.TEXTURE_MATRIX_SCALES[(t0 >> 13) & 7]
			print("UV spot top3=%d: old rule one repeat per %.1f units, read rule u = c * 0.25 * %.2f -> one repeat per %.1f units" % [
				(t0 >> 13) & 7, MapmTerrainBuilder.TILE_SIZE, s, MapmTerrainBuilder.TILE_SIZE / (0.25 * s) if s > 0.0 else INF])

		# Region-wide TextureInfo bits.
		var top3 := {}
		var b10 := 0
		var mixed := 0
		for r in range(SIDE + 1):
			for c in range(SIDE + 1):
				var t := _texinfo(region, c, r)
				top3[(t >> 13) & 7] = int(top3.get((t >> 13) & 7, 0)) + 1
				if (t >> 10) & 7 != 0:
					b10 += 1
		for r in range(SIDE):
			for c in range(SIDE):
				var seen := {}
				for d in [[0, 0], [1, 0], [1, 1], [0, 1]]:
					var t := _texinfo(region, c + int(d[0]), r + int(d[1]))
					var id := t & 0x3ff
					if seen.has(id) and int(seen[id]) != (t >> 13) & 7:
						mixed += 1
						break
					seen[id] = (t >> 13) & 7
		print("STATS top3 histogram %s; vertices with bits 10-12 set %d of %d; quads with one ID at two scales %d" % [str(top3), b10, (SIDE + 1) * (SIDE + 1), mixed])

		# The lightmap term.
		var tbytes := AssetSource.read_bytes("%d\\%d.t" % [px, py], map)
		var lm: Image = null
		if not tbytes.is_empty():
			var parsed_t := MapTReader.parse(tbytes, false)
			if parsed_t != null:
				lm = parsed_t.image
		var shadow := _env_shadow(data, map, region)
		print("LM %s env=%d TerrainShadowColor=%s" % ["present %dx%d" % [lm.get_width(), lm.get_height()] if lm != null else "absent", region.blocks[0].environment_id, str(shadow)])
		var lterm: Image = null
		if lm != null and shadow.r >= 0.0:
			lterm = MapmTerrainBuilder.lightmap_term(lm, shadow)
			var dark := 0
			var total := 0
			var sum := 0.0
			for y in range(0, lterm.get_height(), 4):
				for x in range(0, lterm.get_width(), 4):
					var v := lterm.get_pixel(x, y)
					sum += (v.r + v.g + v.b) / 3.0
					total += 1
					if v.r < 0.999 or v.g < 0.999 or v.b < 0.999:
						dark += 1
			print("LM term mean %.3f; %.1f%% of sampled texels darkened" % [sum / float(total), 100.0 * float(dark) / float(total)])

		# Our per-cell colour against the authored minimap, before (no lightmap
		# term) and after (times the lightmap term at the cell's centre).
		var mm := _minimap(media, px, py)
		if mm == null:
			print("MM none")
			continue
		# Which way the lightmap lies on the region, measured: the Pearson
		# correlation of its luminance with the minimap's over the 96 x 96
		# cells, read as the builder reads it (row r -> lightmap row r) and
		# with its rows or columns reversed or its axes swapped.
		if lterm != null:
			var small := lterm.duplicate() as Image
			small.resize(SIDE, SIDE, Image.INTERPOLATE_BILINEAR)
			var orient := PackedStringArray()
			for mode in ["as_read", "rows_flipped", "cols_flipped", "transposed"]:
				var xs := PackedFloat32Array()
				var ys := PackedFloat32Array()
				for r in range(SIDE):
					for c in range(SIDE):
						var lx := c
						var ly := r
						if mode == "rows_flipped":
							ly = SIDE - 1 - r
						elif mode == "cols_flipped":
							lx = SIDE - 1 - c
						elif mode == "transposed":
							lx = r
							ly = c
						xs.append(small.get_pixel(lx, ly).get_luminance())
						ys.append(mm.get_pixel(c, SIDE - 1 - r).get_luminance())
				orient.append("%s %.3f" % [mode, _pearson(xs, ys)])
			print("LM orientation vs minimap: " + ", ".join(orient))
			# MEASURE_DUMP=<dir> writes the lightmap term and the minimap (row-
			# flipped into the builder's row order) for a human to look at.
			if OS.get_environment("MEASURE_DUMP") != "":
				var mmr := mm.duplicate() as Image
				mmr.flip_y()
				small.resize(192, 192)
				mmr.resize(192, 192)
				small.save_png("%s/lm_%d_%d.png" % [OS.get_environment("MEASURE_DUMP"), px, py])
				mmr.save_png("%s/mm_%d_%d.png" % [OS.get_environment("MEASURE_DUMP"), px, py])
		var areas := {"region": [0, 0, SIDE, SIDE]}
		areas["spot"] = [maxi(sc - WINDOW, 0), maxi(sr - WINDOW, 0), mini(sc + WINDOW, SIDE), mini(sr + WINDOW, SIDE)]
		for name in ["spot", "region"]:
			var a: Array = areas[name]
			var before := 0.0
			var after := 0.0
			var bright_ours_b := 0.0
			var bright_ours_a := 0.0
			var bright_mm := 0.0
			var n := 0
			for r in range(int(a[1]), int(a[3])):
				for c in range(int(a[0]), int(a[2])):
					var ours := _cell_color(map, table, region, c, r)
					var lit := ours
					if lterm != null:
						var u := (float(c) + 0.5) / 96.0 * 0.998046875 + 0.0009765625
						var v := (float(r) + 0.5) / 96.0 * 0.998046875 + 0.0009765625
						var l := lterm.get_pixel(int(u * lterm.get_width()), int(v * lterm.get_height()))
						lit = Color(ours.r * l.r, ours.g * l.g, ours.b * l.b)
					# minimap +Y runs toward -Z: its row 0 is our last row
					var m := mm.get_pixel(c, SIDE - 1 - r)
					before += (absf(ours.r - m.r) + absf(ours.g - m.g) + absf(ours.b - m.b)) / 3.0
					after += (absf(lit.r - m.r) + absf(lit.g - m.g) + absf(lit.b - m.b)) / 3.0
					bright_ours_b += (ours.r + ours.g + ours.b) / 3.0
					bright_ours_a += (lit.r + lit.g + lit.b) / 3.0
					bright_mm += (m.r + m.g + m.b) / 3.0
					n += 1
			print("MM %s cells=%d before %.4f after %.4f | mean brightness ours %.3f -> %.3f, minimap %.3f" % [
				name, n, before / n, after / n, bright_ours_b / n, bright_ours_a / n, bright_mm / n])
	quit(0)
