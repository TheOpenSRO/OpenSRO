extends SceneTree

## Holds the native (Rust) terrain parsers to the GDScript ones on the REAL
## archives, value for value and float bit pattern for bit pattern (round
## 670; native/README.md, "Parity"). The sibling of native_parity.gd. Run on
## the render box, never committed output:
##
##   client/tools/remote_godot.sh script res://tools/native_parity_terrain.gd -- --pk2-dir=/opt/sro-files/client
##
## Every `.m` and `.t` in Map.pk2 and every `.nvm` in Data.pk2:
## - `.m`: MapmReader.parse against MapmReader.parse_native (the native
##   decode, not on the load path -- see its doc comment) -- the version, and every block's flag,
##   environment id, plane type, wave id, plane height, height max/min, and
##   every vertex's height and extra bytes;
## - `.nvm`: NvmReader.parse against NvmReader.parse_native -- every object (and its linked
##   edges), cell (and its object indices), global and internal edge, tile,
##   height and plane;
## - `.t`: MapmTerrainBuilder.lightmap_term both ways over the decoded
##   lightmap, under SHADOWS (the environment's TerrainShadowColor), RGB8
##   bytes compared.
## Floats are compared by their bits (a 64-bit float as GDScript holds it,
## a float32 as a packed array or a vector holds it), so a NaN or a -0.0
## counts. Every TRUNCATE_STRIDE-th `.m` and `.nvm` is also cut at
## TRUNCATE_CUTS points and must be refused both ways.
##
## `--only=mapm|nvm|lightmap` runs one of the three; `--limit=N` compares only
## the first N files of each type.
##
## Prints `PARITY <type> ...` counts with each path's parse time, the first
## FAIL lines of any mismatch, and `PARITY PASS` or `PARITY FAIL <n>`. Exits
## 1 on a FAIL or when the library did not load.

const MAX_FAIL_LINES := 12
const TRUNCATE_STRIDE := 50
const TRUNCATE_CUTS := [0, 11, 13, 100, 0.5, -1]
const SHADOWS := [Color(0, 0, 0), Color(0.2, 0.4, 0.6), Color(1, 1, 1), Color(0.5, 0.999, 0.003)]

var _fails := 0
## --limit=N: only the first N files of each type (the negative's quick run).
var _limit := 0

func _fail(msg: String) -> void:
	_fails += 1
	if _fails <= MAX_FAIL_LINES:
		print("FAIL " + msg)

func _init() -> void:
	var pk2_dir := "/opt/sro-files/client"
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2-dir="):
			pk2_dir = a.substr(10)
		elif a.begins_with("--only="):
			only = a.substr(7)
		elif a.begins_with("--limit="):
			_limit = int(a.substr(8))
	if not NativeAssets.library_usable():
		print("PARITY FAIL: no usable native library (%s) -- nothing to compare (is a current client/native_bin shipped?)" % NativeAssets.api_verdict(NativeAssets.library_api()))
		quit(1)
		return
	NativeAssets.available()
	if NativeAssets.terrain() == null:
		print("PARITY FAIL: the library has no SrNativeTerrain")
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var map := Pk2Reader.open(pk2_dir.path_join("Map.pk2"))
	var data := Pk2Reader.open(pk2_dir.path_join("Data.pk2"))
	if map == null or data == null:
		print("PARITY FAIL: could not open Map.pk2 / Data.pk2 under %s" % pk2_dir)
		quit(1)
		return
	var map_files := _files(map)
	var data_files := _files(data)
	if only == "" or only == "mapm":
		_compare_mapm(map, map_files)
	if only == "" or only == "nvm":
		_compare_nvm(data, data_files)
	if only == "" or only == "lightmap":
		_compare_lightmaps(map, map_files)
	print("PARITY took %d s" % ((Time.get_ticks_msec() - t0) / 1000))
	if _fails == 0:
		print("PARITY PASS")
		quit(0)
	else:
		print("PARITY FAIL %d" % _fails)
		quit(1)

## Every file of an archive, as [path, Entry], walking its whole tree.
func _files(archive: Pk2Reader) -> Array:
	var out: Array = []
	var queue: Array = [["", archive._root_offset]]
	var seen := {}
	while not queue.is_empty():
		var item: Array = queue.pop_back()
		var off: int = item[1]
		if seen.has(off):
			continue
		seen[off] = true
		for e in archive._read_block_chain(off):
			if e.name == "." or e.name == "..":
				continue
			var p: String = e.name if item[0] == "" else item[0] + "\\" + e.name
			if e.is_dir:
				queue.append([p, e._offset])
			else:
				out.append([p, e])
	return out

## [GDScript result, native result, GDScript usec, native usec] of `parse`
## (the reader's GDScript parse) and `parse_native` on `bytes`.
func _both(parse: Callable, parse_native: Callable, bytes: PackedByteArray) -> Array:
	NativeAssets.force_gdscript = true
	var t := Time.get_ticks_usec()
	var g = parse.call(bytes)
	var tg := Time.get_ticks_usec() - t
	NativeAssets.force_gdscript = false
	t = Time.get_ticks_usec()
	var n = parse_native.call(bytes)
	var tn := Time.get_ticks_usec() - t
	return [g, n, tg, tn]

## The cut points of a file of `size` bytes TRUNCATE_CUTS names (a float is a
## fraction of it, -1 one byte short).
func _cuts(size: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	for c in TRUNCATE_CUTS:
		var at: int = int(size * c) if c is float else (size - 1 if c == -1 else c)
		if at >= 0 and at < size:
			out.append(at)
	return out

func _compare_mapm(map: Pk2Reader, files: Array) -> void:
	var fails0 := _fails
	var count := 0
	var refused := 0
	var vertices := 0
	var truncated := 0
	var tg := 0
	var tn := 0
	for f in files:
		var p: String = f[0]
		if not p.to_lower().ends_with(".m"):
			continue
		if _limit > 0 and count >= _limit:
			break
		var bytes := map.read_file(f[1])
		var r := _both(MapmReader.parse, MapmReader.parse_native, bytes)
		count += 1
		tg += r[2]
		tn += r[3]
		var g: MapmReader.ParsedRegion = r[0]
		var n: MapmReader.ParsedRegion = r[1]
		if (g == null) != (n == null):
			_fail("mapm '%s': GDScript %s, native %s" % [p, g != null, n != null])
			continue
		if g == null:
			refused += 1
			continue
		vertices += _diff_mapm(p, g, n)
		if count % TRUNCATE_STRIDE == 0:
			for at in _cuts(bytes.size()):
				truncated += 1
				var c := _both(MapmReader.parse, MapmReader.parse_native, bytes.slice(0, at))
				if c[0] != null or c[1] != null:
					_fail("mapm '%s' cut at %d: GDScript %s, native %s (both must refuse)" % [p, at, c[0] != null, c[1] != null])
	print("PARITY mapm: %d mismatches; %d .m files compared (%d refused both ways), %d vertices; %d truncations refused both ways; parse GDScript %.1f ms/file, native %.1f ms/file" % [
		_fails - fails0, count, refused, vertices, truncated, tg / 1000.0 / maxi(count, 1), tn / 1000.0 / maxi(count, 1)])

func _diff_mapm(p: String, g: MapmReader.ParsedRegion, n: MapmReader.ParsedRegion) -> int:
	if g.version != n.version or g.blocks.size() != n.blocks.size():
		_fail("mapm '%s': version %s/%s, %d/%d blocks" % [p, g.version, n.version, g.blocks.size(), n.blocks.size()])
		return 0
	var fg := PackedFloat64Array()
	var fn := PackedFloat64Array()
	var vertices := 0
	for b in range(g.blocks.size()):
		var a: MapmReader.Block = g.blocks[b]
		var c: MapmReader.Block = n.blocks[b]
		if a.flag != c.flag or a.environment_id != c.environment_id or a.plane_type != c.plane_type \
				or a.wave_id != c.wave_id or a.vertices.size() != c.vertices.size():
			_fail("mapm '%s' block %d: flag %d/%d env %d/%d plane type %d/%d wave %d/%d vertices %d/%d" % [
				p, b, a.flag, c.flag, a.environment_id, c.environment_id, a.plane_type, c.plane_type,
				a.wave_id, c.wave_id, a.vertices.size(), c.vertices.size()])
			continue
		fg.append_array([a.plane_height, a.height_max, a.height_min])
		fn.append_array([c.plane_height, c.height_max, c.height_min])
		for v in range(a.vertices.size()):
			var va: MapmReader.Vertex = a.vertices[v]
			var vc: MapmReader.Vertex = c.vertices[v]
			fg.append(va.height)
			fn.append(vc.height)
			if va.extra != vc.extra:
				_fail("mapm '%s' block %d vertex %d: extra %s / %s" % [p, b, v, va.extra, vc.extra])
			vertices += 1
	_same_floats("mapm '%s'" % p, fg, fn)
	return vertices

## Fails unless the two float lists hold the same bit patterns, naming the first difference.
func _same_floats(what: String, a: PackedFloat64Array, b: PackedFloat64Array) -> void:
	if a.to_byte_array() == b.to_byte_array():
		return
	for i in range(mini(a.size(), b.size())):
		if PackedFloat64Array([a[i]]).to_byte_array() != PackedFloat64Array([b[i]]).to_byte_array():
			_fail("%s: float %d is %s in GDScript, %s native (bits differ)" % [what, i, a[i], b[i]])
			return
	_fail("%s: %d floats in GDScript, %d native" % [what, a.size(), b.size()])

func _compare_nvm(data: Pk2Reader, files: Array) -> void:
	var fails0 := _fails
	var count := 0
	var refused := 0
	var truncated := 0
	var totals := {"objects": 0, "links": 0, "cells": 0, "edges": 0, "tiles": 0}
	var tg := 0
	var tn := 0
	for f in files:
		var p: String = f[0]
		if not p.to_lower().ends_with(".nvm"):
			continue
		if _limit > 0 and count >= _limit:
			break
		var bytes := data.read_file(f[1])
		var r := _both(NvmReader.parse, NvmReader.parse_native, bytes)
		count += 1
		tg += r[2]
		tn += r[3]
		var g: NvmReader.ParsedRegion = r[0]
		var n: NvmReader.ParsedRegion = r[1]
		if (g == null) != (n == null):
			_fail("nvm '%s': GDScript %s, native %s" % [p, g != null, n != null])
			continue
		if g == null:
			refused += 1
			continue
		_diff_nvm(p, g, n, totals)
		if count % TRUNCATE_STRIDE == 0:
			for at in _cuts(bytes.size()):
				truncated += 1
				var c := _both(NvmReader.parse, NvmReader.parse_native, bytes.slice(0, at))
				if c[0] != null or c[1] != null:
					_fail("nvm '%s' cut at %d: GDScript %s, native %s (both must refuse)" % [p, at, c[0] != null, c[1] != null])
	print("PARITY nvm: %d mismatches; %d .nvm files compared (%d refused both ways): %d objects, %d linked edges, %d cells, %d edges, %d tiles; %d truncations refused both ways; parse GDScript %.1f ms/file, native %.1f ms/file" % [
		_fails - fails0, count, refused, totals["objects"], totals["links"], totals["cells"], totals["edges"], totals["tiles"], truncated,
		tg / 1000.0 / maxi(count, 1), tn / 1000.0 / maxi(count, 1)])

func _diff_nvm(p: String, g: NvmReader.ParsedRegion, n: NvmReader.ParsedRegion, totals: Dictionary) -> void:
	if g.objects.size() != n.objects.size() or g.cells.size() != n.cells.size() or g.tiles.size() != n.tiles.size() \
			or g.global_edges.size() != n.global_edges.size() or g.internal_edges.size() != n.internal_edges.size() \
			or g.walkable_cell_count != n.walkable_cell_count:
		_fail("nvm '%s': counts differ (objects %d/%d cells %d/%d tiles %d/%d global %d/%d internal %d/%d walkable %d/%d)" % [
			p, g.objects.size(), n.objects.size(), g.cells.size(), n.cells.size(), g.tiles.size(), n.tiles.size(),
			g.global_edges.size(), n.global_edges.size(), g.internal_edges.size(), n.internal_edges.size(),
			g.walkable_cell_count, n.walkable_cell_count])
		return
	var fg := PackedFloat64Array()
	var fn := PackedFloat64Array()
	var vg := PackedVector3Array()
	var vn := PackedVector3Array()
	var v2g := PackedVector2Array()
	var v2n := PackedVector2Array()
	for i in range(g.objects.size()):
		var a: NvmReader.MapObject = g.objects[i]
		var c: NvmReader.MapObject = n.objects[i]
		vg.append(a.local_position)
		vn.append(c.local_position)
		fg.append(a.yaw)
		fn.append(c.yaw)
		if a.resource_id != c.resource_id or a.is_static != c.is_static or a.uid != c.uid or a.is_big != c.is_big \
				or a.is_struct != c.is_struct or a.region_id != c.region_id or a.linked_edges.size() != c.linked_edges.size():
			_fail("nvm '%s' object %d: (%d %d %d %s %s %d, %d links) / (%d %d %d %s %s %d, %d links)" % [p, i,
				a.resource_id, a.is_static, a.uid, a.is_big, a.is_struct, a.region_id, a.linked_edges.size(),
				c.resource_id, c.is_static, c.uid, c.is_big, c.is_struct, c.region_id, c.linked_edges.size()])
			continue
		for k in range(a.linked_edges.size()):
			var la: NvmReader.LinkedEdge = a.linked_edges[k]
			var lc: NvmReader.LinkedEdge = c.linked_edges[k]
			if la.other_object_index != lc.other_object_index or la.other_edge_index != lc.other_edge_index or la.edge_index != lc.edge_index:
				_fail("nvm '%s' object %d link %d differs" % [p, i, k])
		totals["links"] += a.linked_edges.size()
	for i in range(g.cells.size()):
		var a: NvmReader.Cell = g.cells[i]
		var c: NvmReader.Cell = n.cells[i]
		v2g.append_array([a.rect_min, a.rect_max])
		v2n.append_array([c.rect_min, c.rect_max])
		if a.object_indices != c.object_indices:
			_fail("nvm '%s' cell %d: object indices %s / %s" % [p, i, a.object_indices, c.object_indices])
	for lists in [[g.global_edges, n.global_edges, "global"], [g.internal_edges, n.internal_edges, "internal"]]:
		var ga: Array = lists[0]
		var na: Array = lists[1]
		for i in range(ga.size()):
			var a: NvmReader.Edge = ga[i]
			var c: NvmReader.Edge = na[i]
			v2g.append_array([a.line_min, a.line_max])
			v2n.append_array([c.line_min, c.line_max])
			if a.flags != c.flags or a.assoc_direction_from != c.assoc_direction_from or a.assoc_direction_to != c.assoc_direction_to \
					or a.assoc_cell_index_from != c.assoc_cell_index_from or a.assoc_cell_index_to != c.assoc_cell_index_to \
					or a.assoc_region_id_from != c.assoc_region_id_from or a.assoc_region_id_to != c.assoc_region_id_to:
				_fail("nvm '%s' %s edge %d: (%d %d %d %d %d %d %d) / (%d %d %d %d %d %d %d)" % [p, lists[2], i,
					a.flags, a.assoc_direction_from, a.assoc_direction_to, a.assoc_cell_index_from, a.assoc_cell_index_to, a.assoc_region_id_from, a.assoc_region_id_to,
					c.flags, c.assoc_direction_from, c.assoc_direction_to, c.assoc_cell_index_from, c.assoc_cell_index_to, c.assoc_region_id_from, c.assoc_region_id_to])
	for i in range(g.tiles.size()):
		var a: NvmReader.Tile = g.tiles[i]
		var c: NvmReader.Tile = n.tiles[i]
		if a.cell_index != c.cell_index or a.flags != c.flags or a.texture_id != c.texture_id:
			_fail("nvm '%s' tile %d: (%d %d %d) / (%d %d %d)" % [p, i, a.cell_index, a.flags, a.texture_id, c.cell_index, c.flags, c.texture_id])
			break
	_same_floats("nvm '%s' yaws" % p, fg, fn)
	if vg.to_byte_array() != vn.to_byte_array():
		_fail("nvm '%s': object positions differ (bits)" % p)
	if v2g.to_byte_array() != v2n.to_byte_array():
		_fail("nvm '%s': cell rects or edge lines differ (bits)" % p)
	if g.heights.to_byte_array() != n.heights.to_byte_array():
		_fail("nvm '%s': heights differ (bits)" % p)
	if g.plane_types != n.plane_types or g.plane_heights.to_byte_array() != n.plane_heights.to_byte_array():
		_fail("nvm '%s': planes differ" % p)
	totals["objects"] += g.objects.size()
	totals["cells"] += g.cells.size()
	totals["edges"] += g.global_edges.size() + g.internal_edges.size()
	totals["tiles"] += g.tiles.size()

func _compare_lightmaps(map: Pk2Reader, files: Array) -> void:
	var fails0 := _fails
	var count := 0
	var images := 0
	var terms := 0
	var pixels := 0
	var tg := 0
	var tn := 0
	var native_answers := 0
	var native_empty := 0
	for f in files:
		var p: String = f[0]
		if not p.to_lower().ends_with(".t"):
			continue
		if _limit > 0 and count >= _limit:
			break
		count += 1
		var parsed := MapTReader.parse(map.read_file(f[1]), false)
		if parsed == null or parsed.image == null:
			continue
		images += 1
		for shadow in SHADOWS:
			NativeAssets.force_gdscript = true
			var t := Time.get_ticks_usec()
			var a := MapmTerrainBuilder.lightmap_term(parsed.image, shadow)
			tg += Time.get_ticks_usec() - t
			NativeAssets.force_gdscript = false
			t = Time.get_ticks_usec()
			var b := MapmTerrainBuilder.lightmap_term(parsed.image, shadow)
			tn += Time.get_ticks_usec() - t
			terms += 1
			if (a == null) != (b == null):
				_fail("lightmap '%s' %s: GDScript %s, native %s" % [p, shadow, a != null, b != null])
				continue
			if a == null:
				continue
			pixels += a.get_width() * a.get_height()
			if a.get_width() != b.get_width() or a.get_height() != b.get_height() or a.get_format() != b.get_format() \
					or a.get_data() != b.get_data():
				_fail("lightmap '%s' under %s: the terms differ" % [p, shadow])
				continue
			# lightmap_term falls back to its GDScript loop when the native one
			# answers empty, which would make both sides above GDScript. So the
			# native loop is also asked directly, on the same RGB8 bytes, and
			# must answer with the term's own bytes (round 670's review).
			var rgb := parsed.image.duplicate() as Image
			if rgb.is_compressed():
				rgb.decompress()
			rgb.convert(Image.FORMAT_RGB8)
			var direct: PackedByteArray = NativeAssets.terrain().call("lightmap_add", rgb.get_data(),
				clampi(roundi(shadow.r * 255.0), 0, 255), clampi(roundi(shadow.g * 255.0), 0, 255), clampi(roundi(shadow.b * 255.0), 0, 255))
			if direct.is_empty():
				native_empty += 1
			else:
				native_answers += 1
				if direct != a.get_data():
					_fail("lightmap '%s' under %s: the native loop's own answer differs from the term" % [p, shadow])
	if terms > 0 and native_answers == 0:
		_fail("lightmap: the native loop answered 0 of %d terms (%d empty) -- every term above was GDScript's fallback" % [terms, native_empty])
	print("PARITY lightmap: %d mismatches; %d .t files, %d lightmaps decoded, %d terms compared (%d pixels); the native loop answered %d, fell back %d; lightmap_term GDScript %.1f ms, native %.1f ms a term" % [
		_fails - fails0, count, images, terms, pixels, native_answers, native_empty, tg / 1000.0 / maxi(terms, 1), tn / 1000.0 / maxi(terms, 1)])
