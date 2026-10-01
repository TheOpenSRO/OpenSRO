extends SceneTree

## The native terrain parsers (round 670; native/src/core/terrain.rs) against
## the GDScript ones, on synthetic input only (never real game data), run
## headless:
## `godot4 --headless --path client --script res://scripts/mapm/terrain_native_test.gd`
##
## With the library: synthetic `.m` (both vertex sizes, a zero trailer, a
## non-zero one, a signalling NaN, every truncation) and `.nvm` files go
## through parse() and parse_native() (the native decode, not on the load
## path -- MapmReader.parse_native says why), RGB8 lightmaps through
## lightmap_term both ways, and every pair must agree field for field (the
## real archives are tools/native_parity_terrain.gd's); 8 WorkerThreadPool
## tasks then parse at once, the first call making the shared parser object.
## Without it (CI, a player without the DLL): NativeAssets.terrain() is null
## and the GDScript readers still parse the same files.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _f32(buf: PackedByteArray, v: float) -> void:
	var at := buf.size()
	buf.resize(at + 4)
	buf.encode_float(at, v)

func _u16(buf: PackedByteArray, v: int) -> void:
	buf.append(v & 0xff)
	buf.append((v >> 8) & 0xff)

func _u32(buf: PackedByteArray, v: int) -> void:
	for k in range(4):
		buf.append((v >> (8 * k)) & 0xff)

## A synthetic `.m`: every value derived from its position.
func _mapm(vertex_len: int, trailer: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var reserved := 70 if vertex_len == 11 else 20
	var d := "JMXVMAPM1000".to_ascii_buffer()
	for b in range(36):
		_u32(d, 0x1000 + b)
		_u16(d, b * 3)
		for v in range(289):
			_f32(d, (b * 289 + v) * 0.5 - 100.0)
			for k in range(vertex_len - 4):
				d.append((v * 7 + k) & 0xff)
		d.append(0xff if b % 2 == 0 else 2)
		d.append(b)
		_f32(d, b + 0.25)
		for _i in range(512):
			d.append(0xab)
		_f32(d, b * 10.0)
		_f32(d, -b)
		for _i in range(reserved):
			d.append(0xcd)
	d.append_array(trailer)
	return d

## A synthetic `.nvm`: two objects (one linked edge), two cells, two edges of
## each kind, every tile, height and plane.
func _nvm() -> PackedByteArray:
	var d := "JMXVNVM 1000".to_ascii_buffer()
	_u16(d, 2)
	for o in range(2):
		_u32(d, 100 + o)
		for f in [1.5, 2.5, 3.5]:
			_f32(d, f + o)
		_u16(d, 0xffff)
		_f32(d, 0.75)
		_u16(d, 7 + o)
		d.append_array(PackedByteArray([0, 0, o, 1]))
		_u16(d, 0x61a8)
		_u16(d, o)
		for l in range(o):
			_u16(d, l)
			_u16(d, 0xfffe)
			_u16(d, 3)
	_u32(d, 2)
	_u32(d, 1)
	for c in range(2):
		for f in [0.0, 1.0, 20.0, 21.0]:
			_f32(d, f + c)
		d.append(c)
		for i in range(c):
			_u16(d, i + 1)
	for global in [true, false]:
		_u32(d, 2)
		for e in range(2):
			for f in [0.0, 0.0, 1920.0, 0.0]:
				_f32(d, f + e)
			d.append_array(PackedByteArray([e | 4, 0xff, 2]))
			_u16(d, 0xffff)
			_u16(d, e)
			if global:
				_u16(d, 0x61a8)
				_u16(d, 0x61a9)
	for t in range(NvmReader.TILE_COUNT):
		_u32(d, (t % 3 - 1) & 0xffffffff)
		_u16(d, t % 2)
		_u16(d, t % 300)
	for h in range(NvmReader.HEIGHT_COUNT):
		_f32(d, h * 0.125)
	for p in range(36):
		d.append(p % 3)
	for p in range(36):
		_f32(d, p - 5.0)
	return d

## Everything a parsed `.m` holds, as bytes (floats by their bits).
func _mapm_print(r: MapmReader.ParsedRegion) -> PackedByteArray:
	if r == null:
		return PackedByteArray()
	var out := [r.version]
	for b in r.blocks:
		var blk := b as MapmReader.Block
		out.append([blk.flag, blk.environment_id, blk.plane_type, blk.wave_id])
		var f := PackedFloat64Array([blk.plane_height, blk.height_max, blk.height_min])
		var extras := PackedByteArray()
		for v in blk.vertices:
			f.append((v as MapmReader.Vertex).height)
			extras.append_array((v as MapmReader.Vertex).extra)
		out.append(f.to_byte_array())
		out.append(extras)
	return var_to_bytes(out)

## Everything a parsed `.nvm` holds, as bytes (floats by their bits).
func _nvm_print(r: NvmReader.ParsedRegion) -> PackedByteArray:
	if r == null:
		return PackedByteArray()
	var out := [r.walkable_cell_count, r.heights.to_byte_array(), r.plane_types, r.plane_heights.to_byte_array()]
	for o in r.objects:
		var obj := o as NvmReader.MapObject
		var links := []
		for l in obj.linked_edges:
			links.append([l.other_object_index, l.other_edge_index, l.edge_index])
		out.append([obj.resource_id, PackedVector3Array([obj.local_position]).to_byte_array(), obj.is_static,
			PackedFloat64Array([obj.yaw]).to_byte_array(), obj.uid, obj.is_big, obj.is_struct, obj.region_id, links])
	for c in r.cells:
		out.append([PackedVector2Array([c.rect_min, c.rect_max]).to_byte_array(), c.object_indices])
	for e in r.global_edges + r.internal_edges:
		out.append([PackedVector2Array([e.line_min, e.line_max]).to_byte_array(), e.flags, e.assoc_direction_from,
			e.assoc_direction_to, e.assoc_cell_index_from, e.assoc_cell_index_to, e.assoc_region_id_from, e.assoc_region_id_to])
	for t in r.tiles:
		out.append([t.cell_index, t.flags, t.texture_id])
	return var_to_bytes(out)

## [GDScript, native] prints of parsing `bytes` with `parse` and
## `parse_native` / `printer`.
func _both(parse: Callable, parse_native: Callable, printer: Callable, bytes: PackedByteArray) -> Array:
	NativeAssets.force_gdscript = true
	var g: PackedByteArray = printer.call(parse.call(bytes))
	NativeAssets.force_gdscript = false
	var n: PackedByteArray = printer.call(parse_native.call(bytes))
	return [g, n]

func _init() -> void:
	var usable := NativeAssets.library_usable()
	NativeAssets.available()
	if not usable:
		_check(NativeAssets.terrain() == null and MapmReader.parse_native(_mapm(7)) == null,
			"without a usable library there is no native terrain parser")
		_check(MapmReader.parse(_mapm(7)) != null and NvmReader.parse(_nvm()) != null,
			"without it the GDScript readers parse the synthetic .m and .nvm")
		_finish()
		return
	_check(NativeAssets.terrain() != null, "the library's SrNativeTerrain is there")

	var snan := _mapm(11)
	snan.encode_u32(18, 0x7f800001) # block 0's first height: a signalling NaN
	var trailer_bad := PackedByteArray()
	trailer_bad.resize(1000)
	trailer_bad[999] = 1
	var zero_trailer := PackedByteArray()
	zero_trailer.resize(1000)
	var cases := {"7-byte vertices": _mapm(7), "11-byte vertices": _mapm(11), "a zero trailer": _mapm(7, zero_trailer),
		"a non-zero trailer": _mapm(7, trailer_bad), "a signalling NaN": snan,
		"a bad magic": "JMXVMAPX1000".to_ascii_buffer(), "a short header": "JMXV".to_ascii_buffer()}
	for name in cases:
		var r := _both(MapmReader.parse, MapmReader.parse_native, _mapm_print, cases[name])
		_check(r[0] == r[1], ".m with %s: both paths agree (%d bytes of fields)" % [name, r[0].size()])
	var agree := 0
	var base := _mapm(7)
	for cut in range(0, base.size(), 997):
		var r := _both(MapmReader.parse, MapmReader.parse_native, _mapm_print, base.slice(0, cut))
		if r[0] == r[1] and r[0].is_empty():
			agree += 1
	_check(agree == ceili(base.size() / 997.0), ".m: every truncation refused both ways (%d)" % agree)

	var nvm := _nvm()
	var rn := _both(NvmReader.parse, NvmReader.parse_native, _nvm_print, nvm)
	_check(rn[0] == rn[1] and not rn[0].is_empty(), ".nvm: both paths agree (%d bytes of fields)" % rn[0].size())
	agree = 0
	var cuts := 0
	for cut in range(0, nvm.size(), 331):
		cuts += 1
		var r := _both(NvmReader.parse, NvmReader.parse_native, _nvm_print, nvm.slice(0, cut))
		if r[0] == r[1] and r[0].is_empty():
			agree += 1
	var extra := nvm.duplicate()
	extra.append(0)
	var r2 := _both(NvmReader.parse, NvmReader.parse_native, _nvm_print, extra)
	_check(agree == cuts and r2[0].is_empty() and r2[1].is_empty(), ".nvm: every truncation and a trailing byte refused both ways (%d)" % agree)

	var img := Image.create(64, 32, false, Image.FORMAT_RGB8)
	for y in range(32):
		for x in range(64):
			img.set_pixel(x, y, Color8((x * 4) & 0xff, (y * 8 + x) & 0xff, 255 - x))
	for shadow in [Color(0, 0, 0), Color(0.3, 0.6, 0.9), Color(1, 1, 1)]:
		NativeAssets.force_gdscript = true
		var a := MapmTerrainBuilder.lightmap_term(img, shadow)
		NativeAssets.force_gdscript = false
		var b := MapmTerrainBuilder.lightmap_term(img, shadow)
		_check(a.get_data() == b.get_data() and a.get_format() == b.get_format(), "lightmap_term under %s agrees both ways" % shadow)

	# Many tasks at once (World3D's terrain prepare runs on WorkerThreadPool),
	# the first of them making the shared parser object again.
	NativeAssets._terrain = null
	var want_m := _mapm_print(MapmReader.parse(_mapm(11)))
	var want_n := _nvm_print(NvmReader.parse(nvm))
	var results := []
	results.resize(16)
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void:
		results[i] = _mapm_print(MapmReader.parse_native(_mapm(11))) == want_m and _nvm_print(NvmReader.parse_native(nvm)) == want_n, 16, 8)
	WorkerThreadPool.wait_for_group_task_completion(task)
	_check(results.count(true) == 16, "16 parses on 8 worker threads agree with the main thread's (%d)" % results.count(true))
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
