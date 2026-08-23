extends SceneTree

## Exercises NvmReader against a synthetic .nvm-shaped buffer (never real
## game data), run headless:
## `godot4 --headless --path client --script res://scripts/nvm/nvm_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _u16(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, v)
	return b

func _s16(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_s16(0, v)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _s32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	return b

func _f32(v: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b

func _u8(v: int) -> PackedByteArray:
	return PackedByteArray([v])

func _s8(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(1)
	b.encode_s8(0, v)
	return b

## Builds a minimal but real-shaped .nvm buffer: 1 object with 1 linked
## edge, 2 cells (one referencing the object), 1 global edge (with real
## region-ID fields), 1 internal edge (without), a full real TileMap
## (96x96, all zero except one flagged/textured tile), a full real
## HeightMap (97x97, one distinguishable value), and a full real
## PlaneTypeMap/PlaneHeightMap (6x6 each).
func _build_region() -> PackedByteArray:
	var buf := NvmReader.MAGIC.to_ascii_buffer()

	buf.append_array(_u16(1)) # ObjectCount
	buf.append_array(_u32(4242)) # ResourceId
	buf.append_array(_f32(10.0)); buf.append_array(_f32(20.0)); buf.append_array(_f32(30.0)) # LocalPosition
	buf.append_array(_s16(-1)) # IsStatic
	buf.append_array(_f32(1.57)) # Yaw
	buf.append_array(_u16(7)) # UID
	buf.append_array(_u16(0)) # unkShort01
	buf.append_array(_u8(1)) # IsBig
	buf.append_array(_u8(0)) # IsStruct
	buf.append_array(_u16(0x6464)) # RegionId
	buf.append_array(_u16(1)) # LinkedEdgeCount
	buf.append_array(_s16(2)); buf.append_array(_s16(3)); buf.append_array(_s16(4)) # one LinkedEdge

	buf.append_array(_u32(2)) # CellCount
	buf.append_array(_u32(1)) # WalkableCellCount
	buf.append_array(_f32(0.0)); buf.append_array(_f32(0.0)); buf.append_array(_f32(960.0)); buf.append_array(_f32(960.0)) # cell 0 rect
	buf.append_array(_u8(1)) # cell 0 ObjectIndexCount
	buf.append_array(_u16(0)) # cell 0 -> object 0
	buf.append_array(_f32(960.0)); buf.append_array(_f32(960.0)); buf.append_array(_f32(1920.0)); buf.append_array(_f32(1920.0)) # cell 1 rect
	buf.append_array(_u8(0)) # cell 1 ObjectIndexCount

	buf.append_array(_u32(1)) # GlobalEdgeCount
	buf.append_array(_f32(0.0)); buf.append_array(_f32(1920.0)); buf.append_array(_f32(960.0)); buf.append_array(_f32(1920.0)) # line
	buf.append_array(_u8(8)) # flags
	buf.append_array(_s8(0)); buf.append_array(_s8(2)) # dir from/to
	buf.append_array(_s16(0)); buf.append_array(_s16(1)) # cell from/to
	buf.append_array(_u16(0x6464)); buf.append_array(_u16(0x6564)) # real region from/to

	buf.append_array(_u32(1)) # InternalEdgeCount
	buf.append_array(_f32(960.0)); buf.append_array(_f32(0.0)); buf.append_array(_f32(960.0)); buf.append_array(_f32(960.0)) # line
	buf.append_array(_u8(4)) # flags
	buf.append_array(_s8(1)); buf.append_array(_s8(3)) # dir from/to
	buf.append_array(_s16(0)); buf.append_array(_s16(-1)) # cell from/to

	for i in range(NvmReader.TILE_COUNT):
		if i == 100:
			buf.append_array(_s32(5)) # CellIndex
			buf.append_array(_u16(1)) # Flags: Blocked
			buf.append_array(_u16(408)) # TextureID
		else:
			buf.append_array(_s32(-1))
			buf.append_array(_u16(0))
			buf.append_array(_u16(0))

	for i in range(NvmReader.HEIGHT_COUNT):
		if i == 50:
			buf.append_array(_f32(123.45))
		else:
			buf.append_array(_f32(0.0))

	for i in range(NvmReader.PLANE_COUNT):
		buf.append_array(_u8(0 if i != 3 else 1)) # Water at index 3
	for i in range(NvmReader.PLANE_COUNT):
		buf.append_array(_f32(0.0 if i != 3 else -5.0))

	return buf

func _init() -> void:
	var data := _build_region()
	var r := NvmReader.parse(data)
	_check(r != null, "parses a full synthetic real-shaped region")
	if r != null:
		_check(r.objects.size() == 1, "1 object (got %d)" % r.objects.size())
		if r.objects.size() == 1:
			var obj: NvmReader.MapObject = r.objects[0]
			_check(obj.resource_id == 4242, "object resource_id matches (got %d)" % obj.resource_id)
			_check(obj.local_position.is_equal_approx(Vector3(10, 20, 30)), "object position matches (got %s)" % obj.local_position)
			_check(obj.is_static == -1, "object is_static matches (got %d)" % obj.is_static)
			_check(obj.region_id == 0x6464, "object region_id matches (got %s)" % String.num_int64(obj.region_id, 16))
			_check(obj.linked_edges.size() == 1, "1 linked edge (got %d)" % obj.linked_edges.size())
			if obj.linked_edges.size() == 1:
				var link: NvmReader.LinkedEdge = obj.linked_edges[0]
				_check(link.other_object_index == 2 and link.other_edge_index == 3 and link.edge_index == 4, "linked edge fields match")

		_check(r.cells.size() == 2, "2 cells (got %d)" % r.cells.size())
		_check(r.walkable_cell_count == 1, "walkable_cell_count matches (got %d)" % r.walkable_cell_count)
		if r.cells.size() == 2:
			_check(r.cells[0].rect_min.is_equal_approx(Vector2(0, 0)) and r.cells[0].rect_max.is_equal_approx(Vector2(960, 960)), "cell 0 rect matches")
			_check(r.cells[0].object_indices == [0], "cell 0 references object 0 (got %s)" % [r.cells[0].object_indices])
			_check(r.cells[1].object_indices.is_empty(), "cell 1 has no real objects")

		_check(r.global_edges.size() == 1, "1 global edge (got %d)" % r.global_edges.size())
		if r.global_edges.size() == 1:
			var ge: NvmReader.Edge = r.global_edges[0]
			_check(ge.assoc_region_id_from == 0x6464 and ge.assoc_region_id_to == 0x6564, "global edge real region IDs match (got %s/%s)" % [String.num_int64(ge.assoc_region_id_from, 16), String.num_int64(ge.assoc_region_id_to, 16)])
			_check(ge.flags == 8, "global edge flags match (got %d)" % ge.flags)

		_check(r.internal_edges.size() == 1, "1 internal edge (got %d)" % r.internal_edges.size())
		if r.internal_edges.size() == 1:
			var ie: NvmReader.Edge = r.internal_edges[0]
			_check(ie.assoc_region_id_from == -1 and ie.assoc_region_id_to == -1, "internal edge has no real region IDs (got %d/%d)" % [ie.assoc_region_id_from, ie.assoc_region_id_to])
			_check(ie.assoc_cell_index_to == -1, "internal edge's real -1 cell index round-trips (got %d)" % ie.assoc_cell_index_to)

		_check(r.tiles.size() == NvmReader.TILE_COUNT, "real full 96x96 TileMap (got %d)" % r.tiles.size())
		_check(r.tiles[100].flags == 1 and r.tiles[100].texture_id == 408 and r.tiles[100].cell_index == 5, "the one flagged/textured tile matches")
		_check(r.tiles[0].cell_index == -1 and r.tiles[0].flags == 0, "an untouched tile stays at its real defaults")

		_check(r.heights.size() == NvmReader.HEIGHT_COUNT, "real full 97x97 HeightMap (got %d)" % r.heights.size())
		_check(absf(r.heights[50] - 123.45) < 0.01, "the one distinguishable height matches (got %s)" % r.heights[50])
		_check(r.heights[0] == 0.0, "an untouched height stays at its real default")

		_check(r.plane_types.size() == NvmReader.PLANE_COUNT and r.plane_heights.size() == NvmReader.PLANE_COUNT, "real full 6x6 PlaneTypeMap/PlaneHeightMap")
		_check(r.plane_types[3] == 1, "the one Water plane type matches (got %d)" % r.plane_types[3])
		_check(absf(r.plane_heights[3] - (-5.0)) < 0.01, "the one distinguishable plane height matches (got %s)" % r.plane_heights[3])

	var bad_magic := PackedByteArray()
	bad_magic.resize(20)
	_check(NvmReader.parse(bad_magic) == null, "rejects bad magic")

	var too_small := PackedByteArray()
	too_small.resize(NvmReader.MAGIC_LEN)
	_check(NvmReader.parse(too_small) == null, "rejects a buffer too small for a header")

	var truncated := data.slice(0, data.size() - 100)
	_check(NvmReader.parse(truncated) == null, "rejects a region truncated mid-HeightMap")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
