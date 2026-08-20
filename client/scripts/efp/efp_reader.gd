extends RefCounted
class_name EfpReader

## Read-only parser for the .efp (JMXVEFF) particle-effect format. See
## docs/protocol/EFP_FORMAT.md for the on-disk layout and why this reader
## only recovers a *flat* sequence of (name, raw value bytes) pairs rather
## than the format's true nested tree structure. Mirrors
## server/internal/efp's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVEFF"
const MAGIC_LEN := 7
const VERSION_LEN := 4
const MAX_NAME_LEN := 40
const MAX_SCAN_SKIP := 100000 # bound on how far the "find the next name" scan looks

class Entry:
	var entry_name: String
	## Raw, unparsed bytes -- see EfpReader's top comment.
	var value: PackedByteArray

class ParsedEffect:
	## "0011" or "0013" -- both confirmed real, with different fixed
	## header shapes before the effect name.
	var version: String
	var effect_name: String
	## Read right after effect_name, plausibly a top-level section count
	## -- not expected to match entries.size() (entries is a flat walk of
	## every nesting level, not just top-level sections).
	var count: int
	var entries: Array[Entry] = []

## Parses a .efp file's raw bytes. Returns null (and pushes an error) on
## failure.
static func parse(data: PackedByteArray) -> ParsedEffect:
	if data.size() < MAGIC_LEN + 1 + VERSION_LEN:
		push_error("efp: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("efp: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var e := ParsedEffect.new()
	e.version = data.slice(MAGIC_LEN + 1, MAGIC_LEN + 1 + VERSION_LEN).get_string_from_ascii()

	var off := MAGIC_LEN + 1 + VERSION_LEN
	if e.version == "0011":
		off += 4 # unconfirmed u32
	elif e.version == "0013":
		off += 4 + 12 + 4 # unconfirmed float32, 12 reserved bytes, unconfirmed u32
	else:
		push_error("efp: unrecognized version %s" % e.version)
		return null

	var name_result = _read_name(data, off)
	if name_result == null:
		push_error("efp: reading effect name")
		return null
	e.effect_name = name_result[0]
	off = name_result[1]

	if off + 4 > data.size():
		push_error("efp: truncated before top-level count")
		return null
	e.count = _le_u32(data, off)
	off += 4

	while off < data.size():
		var entry_result = _read_name(data, off)
		if entry_result == null:
			break # the file's small trailer, or truncation
		var entry_name: String = entry_result[0]
		var value_start: int = entry_result[1]

		var value_end := _find_next_name(data, value_start)
		if value_end == -1:
			var entry := Entry.new()
			entry.entry_name = entry_name
			entry.value = data.slice(value_start, data.size())
			e.entries.append(entry)
			off = data.size()
			break

		var entry := Entry.new()
		entry.entry_name = entry_name
		entry.value = data.slice(value_start, value_end)
		e.entries.append(entry)
		off = value_end

	if e.entries.is_empty():
		push_error("efp: no entries parsed")
		return null

	return e

static func _find_next_name(data: PackedByteArray, off: int) -> int:
	var limit := data.size()
	if off + MAX_SCAN_SKIP < limit:
		limit = off + MAX_SCAN_SKIP
	var scan := off
	while scan < limit:
		if _read_name(data, scan) != null:
			return scan
		scan += 1
	return -1

## Reads a uint32-length-prefixed name at off: 1-40 ASCII
## letters/digits/underscores, starting with a letter -- the same rule used
## to discover this format's structure in the first place.
static func _read_name(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n <= 0 or n > MAX_NAME_LEN or off + n > data.size():
		return null
	var s := data.slice(off, off + n)
	if not _is_alpha(s[0]):
		return null
	for c in s:
		if not (_is_alpha(c) or _is_digit(c) or c == 95):
			return null
	return [s.get_string_from_ascii(), off + n]

static func _is_alpha(c: int) -> bool:
	return (c >= 97 and c <= 122) or (c >= 65 and c <= 90)

static func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
