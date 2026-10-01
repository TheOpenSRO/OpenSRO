extends RefCounted
class_name MapmReader

## Read-only parser for the .m (JMXVMAPM) map-region terrain heightmap
## format. See docs/protocol/MAPM_FORMAT.md for the on-disk layout and the
## public-documentation citation this is verified against. Mirrors
## server/internal/mapm's Go implementation; keep the two in sync if the
## format understanding changes.
##
## The overall block/grid structure (a region is a 6x6 grid of blocks,
## each block a 17x17 vertex mesh plus a 16x16 tile-flag grid) matches
## public private-server community documentation of this format -- per
## docs/LEGAL.md, treating well-established public protocol documentation
## as a spec is standard clean-room practice, distinct from decompiling a
## binary. This reader's own byte-for-byte verification against real files
## (see the format doc) is independent confirmation, not a blind copy: two
## real per-region file-size classes exist, using two different per-vertex
## record sizes (7 and 11 bytes) the public doc doesn't distinguish by
## name -- named here by their real per-vertex byte length rather than an
## invented "shape" label, now that the exact byte layout (not just a size
## class) is confirmed for both.
##
## Parsing is fully deterministic: no resync scanning is needed, unlike
## this reader's own earlier plausibility-based implementation -- every
## real block is a fixed size once its per-vertex record length is known,
## and that per-vertex length can be read directly off the file's own
## total size (see _detect_vertex_size).

const MAGIC := "JMXVMAPM"
const MAGIC_LEN := 8
const VERSION_LEN := 4
const HEADER_LEN := MAGIC_LEN + VERSION_LEN # 12
const BLOCKS_PER_SIDE := 6
const BLOCK_COUNT := BLOCKS_PER_SIDE * BLOCKS_PER_SIDE # 36
const GRID_WIDTH := 17
const VERTEX_COUNT := GRID_WIDTH * GRID_WIDTH # 289
const BLOCK_HEADER_LEN := 4 + 2 # Flag(uint32) + EnvironmentID(uint16)
const PLANE_INFO_LEN := 1 + 1 + 4 # PlaneType(int8) + WaveID(uint8) + PlaneHeight(float32)
const TILE_FLAG_COUNT := 16 * 16
const TILE_FLAG_LEN := TILE_FLAG_COUNT * 2 # 512, uint16/tile, parsed and discarded
const HEIGHT_INFO_LEN := 4 + 4 # HeightMax + HeightMin

## The two real, confirmed per-vertex record lengths. Height is a real
## float32 at relative offset 0 in both (confirmed by decoding real files
## and checking for smoothly-varying, plausible terrain height sequences
## -- not assumed from the public doc alone).
const VERTEX_LEN_7 := 7 # real per-region file-size class ~92KB
const VERTEX_LEN_11 := 11 # real per-region file-size class ~136-137KB

## The two real, confirmed trailing "Reserved" byte counts following each
## block's tile-flag grid -- confirmed exactly by checking that every one
## of a real file's 36 blocks parses with plausible field values and the
## last block ends exactly at EOF. Content unused (unconfirmed meaning),
## only the length matters, to advance past them correctly.
const RESERVED_LEN_7 := 20 # paired with VERTEX_LEN_7
const RESERVED_LEN_11 := 70 # paired with VERTEX_LEN_11

## Generous bound on a real, confirmed all-zero trailer some real files
## have beyond the exact expected size (observed once at exactly 1,000
## bytes -- see parse()). Not a precise bound, just enough to avoid
## mistaking a genuinely malformed/truncated file for one with a real
## trailer.
const MAX_KNOWN_TRAILER := 8192

class Vertex:
	var height: float
	## Remaining raw bytes of the vertex record (a real per-tile
	## texture-info uint16 + brightness byte for the 7-byte record;
	## unconfirmed extra fields, including a real column/row-cycling
	## pattern this project independently found, for the 11-byte one) --
	## kept raw rather than mislabeled.
	var extra: PackedByteArray

class Block:
	var flag: int
	var environment_id: int
	## VERTEX_COUNT (289) Vertex objects, row-major within the block
	## (index = z*GRID_WIDTH + x), matching the public doc's own
	## nested-loop order.
	var vertices: Array[Vertex] = []
	var plane_type: int
	var wave_id: int
	var plane_height: float
	var height_max: float
	var height_min: float

class ParsedRegion:
	## The 4-byte tag after the magic, e.g. "1000".
	var version: String
	## BLOCK_COUNT (36) Block objects, in real 6x6 nested file order
	## (index = band_row * BLOCKS_PER_SIDE + band_col).
	var blocks: Array[Block] = []

## Parses a .m file's raw bytes. Returns null (and pushes an error) on
## failure.
static func parse(data: PackedByteArray) -> ParsedRegion:
	var _pp := ParseProfile.t0()
	var _out: ParsedRegion = _pp_parse(data)
	ParseProfile.add("mapm.parse", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray) -> ParsedRegion:
	if data.size() < HEADER_LEN:
		push_error("mapm: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("mapm: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var sizes = _detect_vertex_size(data)
	if sizes == null:
		push_error("mapm: file size %d doesn't match either known real layout" % data.size())
		return null
	var vertex_len: int = sizes[0]
	var reserved_len: int = sizes[1]

	var r := ParsedRegion.new()
	r.version = data.slice(MAGIC_LEN, HEADER_LEN).get_string_from_ascii()

	var off := HEADER_LEN
	for _b in range(BLOCK_COUNT):
		var block := Block.new()
		block.flag = data.decode_u32(off)
		block.environment_id = data.decode_u16(off + 4)
		off += BLOCK_HEADER_LEN

		block.vertices.resize(VERTEX_COUNT)
		for v in range(VERTEX_COUNT):
			var v_off := off + v * vertex_len
			var vertex := Vertex.new()
			vertex.height = data.decode_float(v_off)
			vertex.extra = data.slice(v_off + 4, v_off + vertex_len)
			block.vertices[v] = vertex
		off += VERTEX_COUNT * vertex_len

		block.plane_type = data.decode_s8(off)
		block.wave_id = data[off + 1]
		block.plane_height = data.decode_float(off + 2)
		off += PLANE_INFO_LEN

		off += TILE_FLAG_LEN # real per-tile flag grid, parsed and discarded -- not used

		block.height_max = data.decode_float(off)
		block.height_min = data.decode_float(off + 4)
		off += HEIGHT_INFO_LEN

		off += reserved_len # real trailing bytes, unconfirmed meaning, parsed and discarded

		r.blocks.append(block)

	if off != data.size():
		# A real, confirmed anomaly on a small minority of real files
		# (e.g. a real 0/0.m): the block data ends exactly as expected,
		# but a real all-zero trailer of unconfirmed purpose follows
		# (observed once at exactly 1,000 bytes). Only ever accepted as
		# all-zero padding, never guessed at as real trailing data.
		var trailer := data.slice(off, data.size())
		for b in trailer:
			if b != 0:
				push_error("mapm: parsed %d bytes but file is %d, and the %d leftover bytes aren't all zero" % [off, data.size(), trailer.size()])
				return null

	return r

## The same parse through the native decode (round 670): the bytes decoded in
## Rust (native/src/core/terrain.rs, a one-to-one port of _pp_parse, held to
## it on every real `.m` by tools/native_parity_terrain.gd) and this reader's
## ParsedRegion built from the columns. Null without the native readers.
##
## NOT on the load path. Round 670 measured it: the decode takes about 0.1
## ms a file, but building this reader's objects from the columns costs as
## much as the whole GDScript parse (WORLD_ISSUES, round 670), so parse()
## stays in GDScript. It is the decode a later round needs once the
## region's readers move onto the columns (docs/TODO.md).
static func parse_native(data: PackedByteArray) -> ParsedRegion:
	var native := NativeAssets.terrain()
	if native == null:
		return null
	return _from_native(native.call("mapm_parse", data))

## The ParsedRegion of a native decode (SrNativeTerrain.mapm_parse): the
## same objects the GDScript parse builds, field for field; null, with the
## GDScript parse's own error, on {error}.
static func _from_native(d: Dictionary) -> ParsedRegion:
	if d.has("error"):
		push_error(d["error"])
		return null
	var r := ParsedRegion.new()
	r.version = d["version"]
	var flags: PackedInt64Array = d["flags"]
	var env_ids: PackedInt32Array = d["environment_ids"]
	var plane_types: PackedInt32Array = d["plane_types"]
	var wave_ids: PackedInt32Array = d["wave_ids"]
	var plane_heights: PackedFloat32Array = d["plane_heights"]
	var height_max: PackedFloat32Array = d["height_max"]
	var height_min: PackedFloat32Array = d["height_min"]
	var heights: PackedFloat32Array = d["heights"]
	var extras: PackedByteArray = d["extras"]
	var extra_len: int = int(d["vertex_len"]) - 4
	var i := 0
	for b in range(BLOCK_COUNT):
		var block := Block.new()
		block.flag = flags[b]
		block.environment_id = env_ids[b]
		block.vertices.resize(VERTEX_COUNT)
		for v in range(VERTEX_COUNT):
			var vertex := Vertex.new()
			vertex.height = heights[i]
			vertex.extra = extras.slice(i * extra_len, i * extra_len + extra_len)
			block.vertices[v] = vertex
			i += 1
		block.plane_type = plane_types[b]
		block.wave_id = wave_ids[b]
		block.plane_height = plane_heights[b]
		block.height_max = height_max[b]
		block.height_min = height_min[b]
		r.blocks.append(block)
	return r

## Reports [vertex_len, reserved_len] implied by data's own total size, or
## null if it matches neither known real layout. Real files fit exactly
## one of the two candidate exact totals, or that total plus a real,
## confirmed-zero-only trailer (see parse()) -- picks the larger candidate
## whenever the file is big enough to hold it (within MAX_KNOWN_TRAILER),
## since the two real totals are far enough apart (92,712 vs 136,116
## bytes) that a genuine 11-byte-vertex file is never mistakable for a
## padded 7-byte-vertex one at that bound.
static func _detect_vertex_size(data: PackedByteArray):
	var fixed_overhead := BLOCK_HEADER_LEN + PLANE_INFO_LEN + TILE_FLAG_LEN + HEIGHT_INFO_LEN
	var block7 := fixed_overhead + VERTEX_COUNT * VERTEX_LEN_7 + RESERVED_LEN_7
	var block11 := fixed_overhead + VERTEX_COUNT * VERTEX_LEN_11 + RESERVED_LEN_11
	var total7 := HEADER_LEN + BLOCK_COUNT * block7
	var total11 := HEADER_LEN + BLOCK_COUNT * block11

	if data.size() >= total11 and data.size() <= total11 + MAX_KNOWN_TRAILER:
		return [VERTEX_LEN_11, RESERVED_LEN_11]
	if data.size() >= total7 and data.size() <= total7 + MAX_KNOWN_TRAILER:
		return [VERTEX_LEN_7, RESERVED_LEN_7]
	return null
