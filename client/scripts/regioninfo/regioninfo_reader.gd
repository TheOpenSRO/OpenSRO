class_name RegioninfoReader

## Parses the real region-to-zone name table, `Data.pk2`'s
## `Shader\regioninfo.txt` -- see docs/protocol/REGIONINFO_FORMAT.md for
## where it really lives, how its real structure was established, and what
## about it is deliberately left unresolved.
##
## Works on raw bytes rather than a decoded String on purpose: the file is
## real **EUC-KR**, so decoding it as UTF-8 would mangle every real zone
## name. The structural fields (digits, `ALL`/`RECT`, `TOWN`/`FIELD`) are
## plain ASCII and are decoded as such; each real name is kept as its own
## raw bytes plus a stable lowercase-hex `name_key`, and turning that key
## into something displayable is RegioninfoNames' job, not this reader's.

const KIND_TOWN := "TOWN"
const KIND_FIELD := "FIELD"

## One real region claimed by a zone.
class Claim:
	var region_x: int
	var region_y: int
	## True for a real `ALL` row (the whole region is this zone's). False
	## for a real `RECT` row, which claims only part of the region -- see
	## the format doc: `RECT`'s four numbers are real but their exact
	## meaning is not established, so they are carried through unread.
	var whole_region: bool
	var rect: PackedInt32Array

## One real `#TOWN`/`#FIELD` section.
class Zone:
	var kind: String
	## The real name exactly as stored, still EUC-KR encoded.
	var name_bytes: PackedByteArray
	## Lowercase hex of name_bytes -- a stable key that survives having no
	## EUC-KR decoder, and what RegioninfoNames maps to a display name.
	var name_key: String
	var claims: Array[Claim] = []

class ParsedTable:
	var zones: Array[Zone] = []
	## Real packed region id -> the indices into `zones` that claim it.
	var _by_region: Dictionary = {}

	## Every zone index claiming this real region, in file order.
	func zone_indices_for(region_x: int, region_y: int) -> Array:
		var key := (region_x << 8) | region_y
		if not _by_region.has(key):
			return []
		return _by_region[key]

	## The single zone that unambiguously owns this real region, or -1.
	##
	## Deliberately strict: it answers only when exactly one real zone
	## claims the region *and* claims the whole of it. A region split
	## between two zones by real `RECT` rows returns -1 rather than a
	## guess, because which side a given point falls on cannot be decided
	## until `RECT`'s coordinates are understood (see the format doc).
	## In the one real file checked this still resolves 1,572 of 1,619
	## real regions.
	func sole_zone_for(region_x: int, region_y: int) -> int:
		var indices := zone_indices_for(region_x, region_y)
		if indices.size() != 1:
			return -1
		var zone: Zone = zones[indices[0]]
		for claim in zone.claims:
			if claim.region_x == region_x and claim.region_y == region_y:
				return indices[0] if claim.whole_region else -1
		return -1

static func _split_on(data: PackedByteArray, sep: int) -> Array:
	var parts: Array = []
	var start := 0
	for i in range(data.size()):
		if data[i] == sep:
			parts.append(data.slice(start, i))
			start = i + 1
	parts.append(data.slice(start, data.size()))
	return parts

static func _to_hex(data: PackedByteArray) -> String:
	var out := ""
	for b in data:
		out += "%02x" % b
	return out

## Parses the real file's bytes. Returns null (and pushes an error) if the
## buffer contains no real section at all, which is the only shape that
## cannot be a real table; anything else is parsed as far as it goes.
static func parse(data: PackedByteArray) -> ParsedTable:
	var table := ParsedTable.new()
	var current := -1
	for raw_line in _split_on(data, 0x0A):
		var line: PackedByteArray = raw_line
		if line.size() > 0 and line[line.size() - 1] == 0x0D:
			line = line.slice(0, line.size() - 1)
		if line.is_empty():
			continue
		var fields := _split_on(line, 0x09)
		if line[0] == 0x23: # '#'
			var kind: String = fields[0].slice(1, fields[0].size()).get_string_from_ascii()
			if kind != KIND_TOWN and kind != KIND_FIELD:
				continue
			var zone := Zone.new()
			zone.kind = kind
			zone.name_bytes = fields[1] if fields.size() > 1 else PackedByteArray()
			zone.name_key = _to_hex(zone.name_bytes)
			table.zones.append(zone)
			current = table.zones.size() - 1
			continue
		if current < 0 or fields.size() < 3:
			continue
		var y_text: String = fields[0].get_string_from_ascii()
		var x_text: String = fields[1].get_string_from_ascii()
		if not y_text.is_valid_int() or not x_text.is_valid_int():
			continue
		var token: String = fields[2].get_string_from_ascii()
		var claim := Claim.new()
		# Column order really is <y> then <x> here -- the opposite of the
		# <x>\<y>.m region naming used everywhere else. See the format doc.
		claim.region_y = int(y_text)
		claim.region_x = int(x_text)
		if token == "ALL":
			claim.whole_region = true
		elif token == "RECT":
			claim.whole_region = false
			for i in range(3, mini(7, fields.size())):
				var value: String = fields[i].get_string_from_ascii()
				if value.is_valid_int():
					claim.rect.append(int(value))
		else:
			continue
		table.zones[current].claims.append(claim)
		var key := (claim.region_x << 8) | claim.region_y
		if not table._by_region.has(key):
			table._by_region[key] = []
		table._by_region[key].append(current)
	if table.zones.is_empty():
		push_error("regioninfo: no real #TOWN/#FIELD section found")
		return null
	return table
