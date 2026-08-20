extends RefCounted
class_name MapoReader

## Read-only parser for the .o (JMXVMAPO) map-region object-placement
## format. See docs/protocol/MAPO_FORMAT.md for the on-disk layout. Mirrors
## server/internal/mapo's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVMAPO"
const MAGIC_LEN := 8
const VERSION_LEN := 4
const MIN_HEADER_LEN := 0x14 # magic(8) + version(4) + 2 unconfirmed u32 fields (8) -- most files
const MAX_HEADER_SCAN := 64 # bound on how far the header-length scan looks for the first record
const POS_FIELD_LEN := 16 # type ID (4) + position (3x float32)
const FIXED_RECORD_LEN := 28 # POS_FIELD_LEN + 12 more raw bytes, unconfirmed, present on every record
const MAX_TRAILER_SCAN := 128 # bound on how far the resync scan looks for the next record

class ObjectPlacement:
	var type_id: int
	var position: Vector3
	## The 12 raw bytes every record has right after the position --
	## unconfirmed meaning.
	var fixed12: PackedByteArray
	## 0 or more further raw trailing bytes before the next record (or
	## EOF) -- real files show these as zero padding plus a small
	## trailing value, but the exact meaning isn't confirmed. See
	## docs/protocol/MAPO_FORMAT.md.
	var extra: PackedByteArray

class ParsedRegion:
	## The 4-byte tag after the magic, e.g. "1000" (an effectively-empty
	## region, no objects) or "1001" (populated).
	var version: String
	var objects: Array[ObjectPlacement] = []

## Parses a .o file's raw bytes. Returns null (and pushes an error) on
## failure.
##
## The header between the version tag and the first object record isn't a
## fixed size: it's usually 20 bytes (magic + version + 2 unconfirmed u32
## fields), but real files were also seen with an 18-byte header -- 2 bytes
## narrower, cause unconfirmed. Rather than trust either fixed length, this
## scans forward (bounded) from right after the version tag for the first
## byte offset that looks like a plausible record, the same
## verify-plausibility approach the rest of this format needed.
static func parse(data: PackedByteArray) -> ParsedRegion:
	if data.size() < MIN_HEADER_LEN:
		push_error("mapo: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("mapo: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var r := ParsedRegion.new()
	r.version = data.slice(MAGIC_LEN, MAGIC_LEN + VERSION_LEN).get_string_from_ascii()

	var off := _find_first_record(data, MAGIC_LEN + VERSION_LEN)
	while off != -1 and _looks_like_record(data, off):
		var type_id := _le_u32(data, off)
		var pos := Vector3(
			_read_float32(data, off + 4),
			_read_float32(data, off + 8),
			_read_float32(data, off + 12))

		var trailer_start := off + FIXED_RECORD_LEN
		var next := trailer_start
		var scanned := 0
		while next < data.size() and not _looks_like_record(data, next) and scanned < MAX_TRAILER_SCAN:
			next += 1
			scanned += 1

		var o := ObjectPlacement.new()
		o.type_id = type_id
		o.position = pos
		o.fixed12 = data.slice(off + POS_FIELD_LEN, trailer_start)
		o.extra = data.slice(trailer_start, next)
		r.objects.append(o)
		off = next

	return r

## Scans forward from off (bounded by MAX_HEADER_SCAN) for the first byte
## offset that looks like a plausible record start. Returns -1 if none is
## found -- the normal, expected outcome for an effectively-empty region
## (version "1000", or occasionally "1001" with no real objects -- the
## version tag alone isn't a reliable populated/empty signal, see
## docs/protocol/MAPO_FORMAT.md).
static func _find_first_record(data: PackedByteArray, off: int) -> int:
	var limit := off + MAX_HEADER_SCAN
	if limit > data.size():
		limit = data.size()
	var scan := off
	while scan < limit:
		if _looks_like_record(data, scan):
			return scan
		scan += 1
	return -1

## Reports whether off is a plausible object-record start: a small-ish type
## ID followed by 3 position floats that aren't NaN/Inf, and aren't a
## suspicious near-zero value that only shows up from misaligned binary
## data (every real position component checked was either exactly 0.0 or
## had a magnitude well above float32 subnormal-noise range).
static func _looks_like_record(data: PackedByteArray, off: int) -> bool:
	if off + FIXED_RECORD_LEN > data.size():
		return false
	var type_id := _le_u32(data, off)
	if type_id == 0 or type_id >= 10000:
		return false
	for i in range(3):
		if not _sane_float(_read_float32(data, off + 4 + 4 * i)):
			return false
	return true

static func _sane_float(v: float) -> bool:
	if is_nan(v) or is_inf(v):
		return false
	if v == 0.0:
		return true
	var a := absf(v)
	return a > 1e-3 and a < 20000.0

static func _read_float32(data: PackedByteArray, off: int) -> float:
	return data.decode_float(off)

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
