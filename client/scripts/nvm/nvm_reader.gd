extends RefCounted
class_name NvmReader

## Read-only parser for .nvm (JMXVNVM) real navigation mesh files -- the
## real per-region walkability/pathfinding data. See
## docs/protocol/NVM_FORMAT.md for the full derivation and the public
## documentation citation this is verified against (the same source that
## solved .m/.t/tile2d.ifo).
##
## Real, confirmed location: NOT alongside .m/.o/.o2/.t in Map.pk2 -- real
## files live in Data.pk2's navmesh\ folder, named by a real packed
## regionID hex value (e.g. navmesh\nv_6464.nvm for region 100/100 --
## 100 = 0x64, packed as (Y<<8)|X = 0x6464), not the "<x>\<y>.ext" folder
## convention every other real per-region file in this project uses.
##
## Parsing is fully deterministic and was verified byte-for-byte against
## a real sample (a real nv_6464.nvm, 113,053 bytes): every real section
## below, read in order, lands exactly on the file's real end with zero
## leftover bytes. The real embedded 97x97 HeightMap was independently
## cross-checked against this project's own separately-parsed real
## 100/100.m heightmap for the same region -- an exact, zero-deviation
## match across all 9,409 real vertices, a strong independent
## confirmation of both formats at once.

const MAGIC := "JMXVNVM 1000" # note the real literal space before "1000"
const MAGIC_LEN := 12
const TILE_MAP_SIDE := 96
const TILE_COUNT := TILE_MAP_SIDE * TILE_MAP_SIDE
const HEIGHT_MAP_SIDE := 97
const HEIGHT_COUNT := HEIGHT_MAP_SIDE * HEIGHT_MAP_SIDE
const PLANE_MAP_SIDE := 6
const PLANE_COUNT := PLANE_MAP_SIDE * PLANE_MAP_SIDE

class LinkedEdge:
	var other_object_index: int
	var other_edge_index: int
	var edge_index: int

## One real placed object with navmesh-relevant data (a real subset of
## what .o/.o2 also place -- this is the navmesh's own copy, used for
## real collision/edge-linking, not rendering).
class MapObject:
	var resource_id: int
	var local_position: Vector3
	var is_static: int
	var yaw: float
	var uid: int
	var is_big: bool
	var is_struct: bool
	var region_id: int
	var linked_edges: Array[LinkedEdge] = []

## One real navigable cell (a convex rectangular region of the map).
class Cell:
	var rect_min: Vector2
	var rect_max: Vector2
	## Real indices into ParsedRegion.objects.
	var object_indices: Array[int] = []

## One real navigation edge (a line segment bounding a cell, either
## shared with a neighboring region [Global] or another cell in the same
## region [Internal]).
class Edge:
	var line_min: Vector2
	var line_max: Vector2
	var flags: int
	var assoc_direction_from: int
	var assoc_direction_to: int
	var assoc_cell_index_from: int
	var assoc_cell_index_to: int
	## Only set for global edges (-1 for internal ones): the real packed
	## region ID (see NvmReader's top comment) on each side of this edge.
	## A real cross-region link -- e.g. a real edge at a region's north
	## boundary linking its own real packed ID to its real north
	## neighbor's, confirmed directly against this project's own
	## World3D.gd region-grid convention.
	var assoc_region_id_from: int
	var assoc_region_id_to: int

## One real per-quad tile between the 97x97 height-map vertices (96x96 of
## them, matching .m's own real 16x16-per-block, 6x6-block tile-flag grid
## in total count -- these are almost certainly the same real concept,
## just carried in a different real file for this client build).
class Tile:
	## Real index into ParsedRegion.cells, or -1.
	var cell_index: int
	## Real per-tile flags (bit 0 = manually Blocked, per public
	## documentation).
	var flags: int
	## Real texture ID into tile2d.ifo -- see docs/protocol/TILE2D_FORMAT.md.
	## Documented as being used for footstep sounds, not necessarily
	## ground rendering, but it's the same real ID space MapmTerrainBuilder
	## already uses for per-vertex color.
	var texture_id: int

class ParsedRegion:
	var objects: Array[MapObject] = []
	var walkable_cell_count: int
	var cells: Array[Cell] = []
	var global_edges: Array[Edge] = []
	var internal_edges: Array[Edge] = []
	## Row-major, TILE_MAP_SIDE x TILE_MAP_SIDE (index = row*96+col).
	var tiles: Array[Tile] = []
	## Row-major, HEIGHT_MAP_SIDE x HEIGHT_MAP_SIDE (index = row*97+col) --
	## real float32 heights, the same real per-region heightmap .m's own
	## block/vertex structure produces (see this file's top comment for
	## the cross-validation).
	var heights: PackedFloat32Array
	## Row-major, PLANE_MAP_SIDE x PLANE_MAP_SIDE (index = row*6+col).
	var plane_types: PackedByteArray
	var plane_heights: PackedFloat32Array

## Parses a .nvm file's raw bytes. Returns null (and pushes an error) on
## failure. Every count in this format is real and self-describing (no
## resync/plausibility scanning needed, like .m's own deterministic
## parse) -- a truncated or malformed file fails with a specific error
## rather than a silent partial result.
static func parse(data: PackedByteArray) -> ParsedRegion:
	if data.size() < MAGIC_LEN + 2:
		push_error("nvm: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("nvm: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var r := ParsedRegion.new()
	var off := MAGIC_LEN

	var object_count := data.decode_u16(off)
	off += 2
	for _i in range(object_count):
		if off + 30 > data.size():
			push_error("nvm: truncated reading object header")
			return null
		var obj := MapObject.new()
		obj.resource_id = data.decode_u32(off)
		obj.local_position = Vector3(data.decode_float(off + 4), data.decode_float(off + 8), data.decode_float(off + 12))
		obj.is_static = data.decode_s16(off + 16)
		obj.yaw = data.decode_float(off + 18)
		obj.uid = data.decode_u16(off + 22)
		# offset 24: unkShort01 (2 bytes), skipped
		obj.is_big = data[off + 26] != 0
		obj.is_struct = data[off + 27] != 0
		obj.region_id = data.decode_u16(off + 28)
		off += 30
		if off + 2 > data.size():
			push_error("nvm: truncated reading object's LinkedEdgeCount")
			return null
		var link_count := data.decode_u16(off)
		off += 2
		for _j in range(link_count):
			if off + 6 > data.size():
				push_error("nvm: truncated reading a LinkedEdge")
				return null
			var link := LinkedEdge.new()
			link.other_object_index = data.decode_s16(off)
			link.other_edge_index = data.decode_s16(off + 2)
			link.edge_index = data.decode_s16(off + 4)
			off += 6
			obj.linked_edges.append(link)
		r.objects.append(obj)

	if off + 8 > data.size():
		push_error("nvm: truncated reading CellCount/WalkableCellCount")
		return null
	var cell_count := data.decode_u32(off)
	r.walkable_cell_count = data.decode_u32(off + 4)
	off += 8
	for _i in range(cell_count):
		if off + 17 > data.size():
			push_error("nvm: truncated reading a Cell")
			return null
		var cell := Cell.new()
		cell.rect_min = Vector2(data.decode_float(off), data.decode_float(off + 4))
		cell.rect_max = Vector2(data.decode_float(off + 8), data.decode_float(off + 12))
		var idx_count := data[off + 16]
		off += 17
		if off + 2 * idx_count > data.size():
			push_error("nvm: truncated reading a Cell's ObjectIndices")
			return null
		for _j in range(idx_count):
			cell.object_indices.append(data.decode_u16(off))
			off += 2
		r.cells.append(cell)

	var parsed_edges = _parse_edges(data, off, true)
	if parsed_edges == null:
		return null
	r.global_edges = parsed_edges[0]
	off = parsed_edges[1]

	parsed_edges = _parse_edges(data, off, false)
	if parsed_edges == null:
		return null
	r.internal_edges = parsed_edges[0]
	off = parsed_edges[1]

	if off + TILE_COUNT * 8 > data.size():
		push_error("nvm: truncated reading the real TileMap")
		return null
	for _i in range(TILE_COUNT):
		var tile := Tile.new()
		tile.cell_index = data.decode_s32(off)
		tile.flags = data.decode_u16(off + 4)
		tile.texture_id = data.decode_u16(off + 6)
		off += 8
		r.tiles.append(tile)

	if off + HEIGHT_COUNT * 4 > data.size():
		push_error("nvm: truncated reading the real HeightMap")
		return null
	r.heights.resize(HEIGHT_COUNT)
	for i in range(HEIGHT_COUNT):
		r.heights[i] = data.decode_float(off)
		off += 4

	if off + PLANE_COUNT + PLANE_COUNT * 4 > data.size():
		push_error("nvm: truncated reading the real PlaneTypeMap/PlaneHeightMap")
		return null
	r.plane_types = data.slice(off, off + PLANE_COUNT)
	off += PLANE_COUNT
	r.plane_heights.resize(PLANE_COUNT)
	for i in range(PLANE_COUNT):
		r.plane_heights[i] = data.decode_float(off)
		off += 4

	if off != data.size():
		push_error("nvm: parsed %d bytes but file is %d" % [off, data.size()])
		return null

	return r

## Shared parser for GlobalEdges (is_global=true, carries real
## AssocRegionIdFrom/To) and InternalEdges (is_global=false, no region
## fields) -- identical shape otherwise. Returns [edges, new_offset] or
## null on failure.
static func _parse_edges(data: PackedByteArray, off: int, is_global: bool):
	if off + 4 > data.size():
		push_error("nvm: truncated reading an edge count")
		return null
	var count := data.decode_u32(off)
	off += 4
	var edges: Array[Edge] = []
	# 16 (line: 4 floats) + 1 (flags) + 1 + 1 (dirs) + 2 + 2 (cell indices)
	# + [2 + 2 (region ids), global only] -- 23 bytes internal, 27 global.
	var fixed_len := 27 if is_global else 23
	for _i in range(count):
		if off + fixed_len > data.size():
			push_error("nvm: truncated reading an edge")
			return null
		var edge := Edge.new()
		edge.line_min = Vector2(data.decode_float(off), data.decode_float(off + 4))
		edge.line_max = Vector2(data.decode_float(off + 8), data.decode_float(off + 12))
		edge.flags = data[off + 16]
		edge.assoc_direction_from = data.decode_s8(off + 17)
		edge.assoc_direction_to = data.decode_s8(off + 18)
		edge.assoc_cell_index_from = data.decode_s16(off + 19)
		edge.assoc_cell_index_to = data.decode_s16(off + 21)
		if is_global:
			edge.assoc_region_id_from = data.decode_u16(off + 23)
			edge.assoc_region_id_to = data.decode_u16(off + 25)
		else:
			edge.assoc_region_id_from = -1
			edge.assoc_region_id_to = -1
		off += fixed_len
		edges.append(edge)
	return [edges, off]
