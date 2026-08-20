extends RefCounted
class_name MapmReader

## Read-only parser for the .m (JMXVMAPM) map-region terrain heightmap
## format. See docs/protocol/MAPM_FORMAT.md for the on-disk layout, the two
## confirmed tile record shapes, and this format's lower-confidence status.
## Mirrors server/internal/mapm's Go implementation; keep the two in sync if
## the format understanding changes.

const MAGIC := "JMXVMAPM"
const MAGIC_LEN := 8
const VERSION_LEN := 4
const MIN_HEADER_LEN := 12 # magic(8) + version(4); the real header/first-tile boundary is detected, not fixed
const MAX_HEADER_SCAN := 40 # bound on how far the shape/offset detection scan looks
const MAX_RESYNC := 600 # bound on how far the resync scan looks for the next tile -- see parse()
const DETECT_RUN_LEN := 50 # how many consecutive tiles a candidate (shape, offset) must produce to be trusted
const HEIGHT_MIN_OK := -2000.0
const HEIGHT_MAX_OK := 5000.0

## SHAPE_A is the layout used by the larger (~136-137KB) region file class:
## 1 byte (plausibly a texture/terrain-type index, or a blend weight --
## real data shows 200+ distinct values, too many to be a small fixed
## catalog) + 4 unconfirmed bytes (two uint16-shaped fields that change
## tile-to-tile in a locally structured way) + height + 2 unconfirmed
## trailing bytes.
const SHAPE_A := {"length": 11, "height_off": 5}
## SHAPE_B is the layout used by the smaller (~92KB) region file class: 2
## unconfirmed leading bytes + height + 1 unconfirmed trailing byte.
const SHAPE_B := {"length": 7, "height_off": 2}

class Tile:
	var height: float
	## Every other raw byte of the record (count and meaning differ by
	## shape -- see SHAPE_A/SHAPE_B above), kept raw rather than
	## mislabeled.
	var extra: PackedByteArray

class ParsedRegion:
	## The 4-byte tag after the magic, e.g. "1000".
	var version: String
	var tiles: Array[Tile] = []

## Parses a .m file's raw bytes. Returns null (and pushes an error) on
## failure.
##
## Real files use one of two tile record shapes (SHAPE_A or SHAPE_B above),
## and don't hold to a fixed stride perfectly even once the right shape is
## known -- real data needed a byte-level resync (scanning forward for the
## next position with a plausible height value) to fully recover, the same
## technique MapoReader needed for its variable-length trailers. Since
## there's no header field declaring which shape a file uses, parse()
## detects it: it tries every (shape, starting offset) combination in a
## small window right after the version tag, and picks whichever produces
## the longest unbroken run of plausible tiles -- confirmed to correctly
## pick SHAPE_A for every real file in the larger size class and SHAPE_B
## for every real file in the smaller one.
##
## The resync bound (MAX_RESYNC, 600 bytes) is wider than MapoReader needed
## for the same mechanism: some real SHAPE_B files interleave real tile
## data with long (up to 509 bytes observed) runs of a repeating non-tile
## pattern -- plausibly a "no data here" run-length/mask section, not
## confirmed -- between bands of real tiles. An earlier, narrower bound (64
## bytes, matched to MapoReader's much shorter gaps) made those files look
## like they only had a small fraction of their real tile data, stopping
## permanently at the first such run; widening the bound recovers the real
## tile bands on the far side and gets every real file checked to ~100%
## consumption. See docs/protocol/MAPM_FORMAT.md for the full derivation.
static func parse(data: PackedByteArray) -> ParsedRegion:
	if data.size() < MIN_HEADER_LEN:
		push_error("mapm: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("mapm: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var r := ParsedRegion.new()
	r.version = data.slice(MAGIC_LEN, MAGIC_LEN + VERSION_LEN).get_string_from_ascii()

	var detected = _detect_shape(data, MAGIC_LEN + VERSION_LEN)
	if detected == null:
		push_error("mapm: no plausible tile data found")
		return null
	var shape: Dictionary = detected[0]
	var off: int = detected[1]

	while off + shape.length <= data.size():
		if not _looks_like_tile(data, off, shape):
			var resynced := _resync(data, off, shape)
			if resynced == -1:
				break
			off = resynced

		var t := Tile.new()
		t.height = data.decode_float(off + shape.height_off)
		t.extra = PackedByteArray()
		t.extra.append_array(data.slice(off, off + shape.height_off))
		t.extra.append_array(data.slice(off + shape.height_off + 4, off + shape.length))
		r.tiles.append(t)
		off += shape.length

	if r.tiles.is_empty():
		push_error("mapm: no tiles parsed")
		return null

	return r

## Tries every (shape, offset) combination in a small window starting at
## from, and returns [shape, offset] for whichever produces the longest
## unbroken run of plausible tiles at a fixed stride (no resync) -- or null
## if nothing plausible was found. Confirmed to reliably distinguish the
## two known real shapes from each other and from header padding on every
## real file checked.
static func _detect_shape(data: PackedByteArray, from: int):
	var limit: int = min(from + MAX_HEADER_SCAN, data.size())
	var best_run := -1
	var best_shape: Dictionary = {}
	var best_off := -1
	for shape in [SHAPE_A, SHAPE_B]:
		for off in range(from, limit):
			var run := _run_length(data, off, shape)
			if run > best_run:
				best_run = run
				best_shape = shape
				best_off = off
	if best_off == -1 or best_run == 0:
		return null
	return [best_shape, best_off]

static func _run_length(data: PackedByteArray, off: int, shape: Dictionary) -> int:
	var n := 0
	while n < DETECT_RUN_LEN and _looks_like_tile(data, off, shape):
		n += 1
		off += shape.length
	return n

## Returns the resynced offset, or -1 if no plausible tile was found within
## MAX_RESYNC bytes.
static func _resync(data: PackedByteArray, off: int, shape: Dictionary) -> int:
	var scanned := 0
	while off < data.size() and not _looks_like_tile(data, off, shape) and scanned < MAX_RESYNC:
		off += 1
		scanned += 1
	return off if _looks_like_tile(data, off, shape) else -1

static func _looks_like_tile(data: PackedByteArray, off: int, shape: Dictionary) -> bool:
	if off + shape.length > data.size():
		return false
	return _sane_height(data.decode_float(off + shape.height_off))

static func _sane_height(v: float) -> bool:
	if is_nan(v) or is_inf(v):
		return false
	if v == 0.0:
		return true
	var a := absf(v)
	return a > 1e-3 and v > HEIGHT_MIN_OK and v < HEIGHT_MAX_OK
