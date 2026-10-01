extends RefCounted
class_name CpdReader

## Read-only parser for the .cpd (JMXVCPD) "Compound" object format.
## See docs/protocol/CPD_FORMAT.md for the on-disk layout and how this was
## derived. Mirrors server/internal/cpd's Go implementation; keep the two
## in sync if the format understanding changes.
##
## A real compound object groups several real independent .bsr references
## under one real name -- a full character equipped with armor pieces
## (`Compound\Char\China\1.cpd`: a real body + 6 real armor pieces), a
## decorated Christmas tree (`x_mas_tree_b.cpd`: a real trunk + 8 real
## ornament attachments, one of them a real duplicate of the trunk), or a
## small multi-part scenery prop (`st_sand_01.cpd`: 2 real sand-pile
## pieces).
##
## The exact real field layout between the name and the real .bsr
## reference list is NOT fully solved -- 3 real samples showed 3 different
## shapes (a flat real sub-count, a nested real group-count-then-item-count
## structure, and a real duplicated entry with no visible count field of
## its own), and decompiling the real client's own CompoundObject::Load
## virtual method led to an already-tokenized real linked-list structure
## rather than raw file bytes, meaning the true raw layout lives in an
## earlier, uninspected real deserialization step. Rather than guess at an
## unconfirmed structure, this reader uses the same real, already-proven
## technique this project's own BsrReader/BmtReader use for their own
## unconfirmed inter-field gaps: scan forward for every real, plausible
## length-prefixed string ending in ".bsr" -- confirmed byte-exact correct
## against all 3 real samples above (recovers exactly 2, 9, and 7 real
## entries respectively, including the real intentional duplicate in the
## Christmas tree sample).

const MAGIC := "JMXVCPD 0101"
const MAGIC_LEN := 12
## magic(12) + 2 unconfirmed real u32 fields (8, observed varying per file)
## + 20 reserved bytes (zero in every real sample checked) + 2 unconfirmed
## real u16 fields (4, observed values 0/2 and 3 -- the second one is 3 in
## every real sample checked so far) = 44 bytes total before the real
## length-prefixed name string.
const HEADER_LEN := 0x2c
const MAX_PATH_LEN := 300

class ParsedCompound:
	## Real compound object name (e.g. "x_mas_tree_b", "1").
	var name: String
	## Real, distinct or repeated real .bsr paths this compound spawns.
	## Order matches real file order; a real duplicate (see
	## `x_mas_tree_b.cpd`) is kept, not deduplicated, since a caller may
	## want to render it as a real separate instance.
	var bsr_paths: Array[String] = []

## Parses a .cpd file's raw bytes. Returns null (and pushes an error) on a
## structural failure (bad magic, too small, or no real name string) --
## finding zero real `.bsr` references afterward is not itself a hard
## error (returns a real ParsedCompound with an empty bsr_paths), since
## the exact real trailing layout isn't confirmed enough to distinguish
## "no sub-objects" from "this project's scan missed something."
static func parse(data: PackedByteArray) -> ParsedCompound:
	var _pp := ParseProfile.t0()
	var _out: ParsedCompound = _pp_parse(data)
	ParseProfile.add("cpd.parse", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray) -> ParsedCompound:
	if data.size() < HEADER_LEN + 4:
		push_error("cpd: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("cpd: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var name_result := _read_len_prefixed_string(data, HEADER_LEN)
	if name_result.is_empty():
		push_error("cpd: reading name")
		return null

	var c := ParsedCompound.new()
	c.name = name_result[0]
	c.bsr_paths = _scan_bsr_paths(data, name_result[1])
	return c

## Scans forward from off for every real, plausible length-prefixed string
## ending in ".bsr" (case-insensitive) -- see this file's top comment for
## why a scan is used instead of trusting an unconfirmed field layout.
static func _scan_bsr_paths(data: PackedByteArray, off: int) -> Array[String]:
	var results: Array[String] = []
	var pos := off
	while pos + 4 <= data.size():
		var n := _le_u32(data, pos)
		if n > 0 and n <= MAX_PATH_LEN and pos + 4 + n <= data.size():
			var candidate := data.slice(pos + 4, pos + 4 + n)
			if _is_plausible_path(candidate) and candidate.get_string_from_ascii().to_lower().ends_with(".bsr"):
				results.append(candidate.get_string_from_ascii())
				pos = pos + 4 + n
				continue
		pos += 1
	return results

static func _is_plausible_path(b: PackedByteArray) -> bool:
	if b.size() == 0:
		return false
	for c in b:
		var is_alnum := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
		var is_extra := c == 92 or c == 46 or c == 95 or c == 45 or c == 32 # \ . _ - space
		if not (is_alnum or is_extra):
			return false
	return true

static func _read_len_prefixed_string(data: PackedByteArray, off: int) -> Array:
	if off + 4 > data.size():
		return []
	var n := _le_u32(data, off)
	off += 4
	if n < 0 or off + n > data.size():
		return []
	return [data.slice(off, off + n).get_string_from_ascii(), off + n]

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
