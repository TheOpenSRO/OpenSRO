extends RefCounted
class_name MapO2Reader

## Read-only parser for the .o2 (JMXVMAPO, version "1001"-family) map-region
## object/event index format. See docs/protocol/MAPO2_FORMAT.md for the
## on-disk layout -- unlike .o (MapoReader, entirely empirical), this
## structure comes from a real decompiled loader function
## (sro_client.exe's FUN_00a361b0, MapCallBack.cpp) and was then verified
## byte-for-byte against a real 100/100.o2 sample, so parsing here is
## deterministic (no resync scanning needed): a fixed 12-byte header, then
## SECTORS_PER_SIDE x SECTORS_PER_SIDE real sectors in nested file order,
## each holding LISTS_PER_SECTOR separate uint16-counted lists of
## ENTRY_LEN-byte records.
##
## .o2 only exists for newer-generation ("Shape B") regions -- see
## docs/protocol/MAPM_FORMAT.md's Shape A/B split. Older regions have only
## .o (MapoReader).

const MAGIC := "JMXVMAPO"
const MAGIC_LEN := 8
const VERSION_LEN := 4
const HEADER_LEN := MAGIC_LEN + VERSION_LEN
const SECTORS_PER_SIDE := 6
const LISTS_PER_SECTOR := 3
const ENTRY_LEN := 30

class Entry:
	var type_id: int
	var position: Vector3
	## Real, confirmed 1-based sequential index (relative offset 22-23 in
	## the raw record) -- scope (per-list? per-sector? per-file?) not yet
	## confirmed, see MAPO2_FORMAT.md.
	var index: int
	## The full 30 raw bytes, including the fields already decoded above --
	## kept so nothing is lost while the trailing bytes' full meaning is
	## still being worked out.
	var raw: PackedByteArray

class Sector:
	## Exactly LISTS_PER_SECTOR arrays of Entry, in real file order. Which
	## list is which is not confirmed -- see MAPO2_FORMAT.md's "3 counted
	## lists" section (type IDs are shared across all 3 lists, ruling out a
	## simple per-list category split).
	var lists: Array = [[], [], []]

class ParsedRegion:
	## The 4-byte tag after the magic, e.g. "1001".
	var version: String
	## SECTORS_PER_SIDE * SECTORS_PER_SIDE Sector objects, row-major
	## (index = band_row * SECTORS_PER_SIDE + band_col), in the real nested
	## file order the decompiled loader reads them in.
	var sectors: Array = []

## Parses a .o2 file's raw bytes. Returns null (and pushes an error) on
## failure -- including a truncated file mid-sector, which is treated as a
## real error (not a graceful partial result) since this format's layout is
## fully deterministic, unlike .m's still-partially-understood Shape A.
static func parse(data: PackedByteArray) -> ParsedRegion:
	if data.size() < HEADER_LEN:
		push_error("mapo2: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("mapo2: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var r := ParsedRegion.new()
	r.version = data.slice(MAGIC_LEN, HEADER_LEN).get_string_from_ascii()

	var off := HEADER_LEN
	for band_row in range(SECTORS_PER_SIDE):
		for band_col in range(SECTORS_PER_SIDE):
			var sector := Sector.new()
			for list_idx in range(LISTS_PER_SECTOR):
				if off + 2 > data.size():
					push_error("mapo2: truncated before sector (%d,%d) list %d count" % [band_row, band_col, list_idx])
					return null
				var count := data.decode_u16(off)
				off += 2
				var entries: Array = []
				for _e in range(count):
					if off + ENTRY_LEN > data.size():
						push_error("mapo2: truncated mid-entry in sector (%d,%d) list %d" % [band_row, band_col, list_idx])
						return null
					var entry := Entry.new()
					entry.type_id = data.decode_u32(off)
					entry.position = Vector3(
						data.decode_float(off + 4),
						data.decode_float(off + 8),
						data.decode_float(off + 12))
					entry.index = data.decode_u16(off + 22)
					entry.raw = data.slice(off, off + ENTRY_LEN)
					off += ENTRY_LEN
					entries.append(entry)
				sector.lists[list_idx] = entries
			r.sectors.append(sector)

	return r
