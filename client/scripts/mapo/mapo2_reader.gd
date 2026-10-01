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
## each holding FIELDS_PER_SECTOR separate uint16-counted fields of
## ENTRY_LEN-byte records.
##
## FIELDS_PER_SECTOR is 4, not 3 -- an initial reading of the decompiled
## function found only 3 (see MAPO2_FORMAT.md's own account of that
## mistake), and a first empirical check even seemed to confirm it (no
## parse errors), but left a real 552-byte gap before EOF that turned out
## to be more real, valid entries -- a real 4th counted field, read right
## before what this project first labeled "list 1", whose value the real
## client reads but never stores anywhere. That 4th field's entries are
## parsed and discarded here (field index 0 below) rather than exposed,
## matching the real client's own behavior -- callers only see the 3
## fields that are actually stored (index 1-3 in the file, exposed here as
## Sector.lists[0..2]).
##
## .o2 only exists for newer-generation ("Shape B") regions -- see
## docs/protocol/MAPM_FORMAT.md's Shape A/B split. Older regions have only
## .o (MapoReader).

const MAGIC := "JMXVMAPO"
const MAGIC_LEN := 8
const VERSION_LEN := 4
const HEADER_LEN := MAGIC_LEN + VERSION_LEN
const SECTORS_PER_SIDE := 6
const FIELDS_PER_SECTOR := 4
const LISTS_PER_SECTOR := FIELDS_PER_SECTOR - 1 # field 0's entries are discarded, not stored
const ENTRY_LEN := 30

class Entry:
	var type_id: int
	var position: Vector3
	## Real Y-axis (yaw) rotation in radians -- raw[18:22] as a
	## little-endian float32. Confirmed the same way MapoReader's own
	## rotation field was (see its doc comment): a real, densely-populated
	## Jangan region's .o2 file (98/168.o2, 506 real entries) has 100% of
	## its values at this offset landing in the real [0, 2*PI] range,
	## several rounding to whole real degrees. An earlier pass of
	## MAPO2_FORMAT.md reported this same byte range as "reads zero" --
	## true for the one small sample checked at the time (most real
	## objects do have rotation 0, i.e. face the default direction), not a
	## real contradiction, just an incomplete sample corrected here.
	## HOW IT TURNS (round 506): as MapoReader.ObjectPlacement.rotation --
	## the game's matrix is the NEGATED yaw in Godot; use NavGraph.godot_yaw.
	var rotation: float
	## Real, confirmed 1-based sequential index (relative offset 22-23 in
	## the raw record). Round 583 read it in the loader: it is the object's
	## uid, the low half of the key the loader files the object under, and
	## raw[28:30] is the high half, the owner region `(Y<<8)|X`. raw[27]
	## bit 0 is the loader's skip bit (MAPO2_FORMAT.md, "Corrected (round
	## 583)"); World3D.region_placements acts on both since round 643.
	var index: int
	## The owner region, raw[28:30] as a little-endian uint16: the packed
	## `(first << 8) | second` of the owner's `<first>\<second>` folder name
	## (round 583: `86\90.o2`'s own records carry 0x565a). The record's
	## position is local to this region, not necessarily the file's.
	var owner_region: int
	## raw[27], whose bit 0 is the loader's skip bit (skipped()).
	var build_flags: int
	## The full 30 raw bytes, including the fields already decoded above --
	## kept so nothing is lost while the trailing bytes' full meaning is
	## still being worked out.
	var raw: PackedByteArray

	## The loader's skip test (FUN_00a361b0, READ in round 583): a record of
	## the second or third stored list with raw[27] & 1 is not built.
	func skipped() -> bool:
		return build_flags & 1 != 0

	## The key the loader files the object under: CONCAT22(raw[28:30],
	## raw[22:24]) -- the owner region and the uid (round 583, READ). Two
	## records with one key are one object (Map::FUN_00a1a1d0's refcounted
	## cache), however many sectors or regions list it.
	func object_key() -> int:
		return (owner_region << 16) | index

## The offset from region (region_x, region_y) -- World3D's
## _parse_region_coords of `<x>\<y>` -- to the frame of the packed owner
## region, in the region's local space: the owner's `<y>` steps local x and
## its `<x>` steps local z, one REGION_SPAN (1920) each, as
## World3D._cell_offset steps the terrain groups (region_x -> world Z,
## region_y -> world X). Zero for the region's own records.
static func owner_offset(owner_region: int, region_x: int, region_y: int) -> Vector3:
	var owner_x := (owner_region >> 8) & 0xFF
	var owner_y := owner_region & 0xFF
	return Vector3((owner_y - region_y) * 1920.0, 0.0, (owner_x - region_x) * 1920.0)

class Sector:
	## Exactly LISTS_PER_SECTOR (3) arrays of Entry, in real file order --
	## the real file's 4th, leading per-sector field is parsed and
	## discarded (see this file's top comment), matching the real client.
	## Which of these 3 stored lists is which is not confirmed -- see
	## MAPO2_FORMAT.md (only one of them held any real data in the one
	## sample checked so far).
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
	var _pp := ParseProfile.t0()
	var _out: ParsedRegion = _pp_parse(data)
	ParseProfile.add("o2.parse", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray) -> ParsedRegion:
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
			for field_idx in range(FIELDS_PER_SECTOR):
				if off + 2 > data.size():
					push_error("mapo2: truncated before sector (%d,%d) field %d count" % [band_row, band_col, field_idx])
					return null
				var count := data.decode_u16(off)
				off += 2
				var entries: Array = []
				for _e in range(count):
					if off + ENTRY_LEN > data.size():
						push_error("mapo2: truncated mid-entry in sector (%d,%d) field %d" % [band_row, band_col, field_idx])
						return null
					var entry := Entry.new()
					entry.type_id = data.decode_u32(off)
					entry.position = Vector3(
						data.decode_float(off + 4),
						data.decode_float(off + 8),
						data.decode_float(off + 12))
					entry.rotation = data.decode_float(off + 18)
					entry.index = data.decode_u16(off + 22)
					entry.build_flags = data[off + 27]
					entry.owner_region = data.decode_u16(off + 28)
					entry.raw = data.slice(off, off + ENTRY_LEN)
					off += ENTRY_LEN
					entries.append(entry)
				if field_idx > 0:
					sector.lists[field_idx - 1] = entries
			r.sectors.append(sector)

	return r
