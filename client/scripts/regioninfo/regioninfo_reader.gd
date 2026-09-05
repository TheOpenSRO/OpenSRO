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
	## Index into ParsedTable.zones of the zone making this claim.
	var zone_index: int
	## True for a real `ALL` row (the region's default zone). False for a
	## real `RECT` row, which claims only the box in `rect` and overrides
	## that default for positions inside it.
	var whole_region: bool
	## For a `RECT` claim: `[x_min, z_min, x_max, z_max]`, real
	## region-local and inclusive on all four sides. Recovered from the
	## client's own test, not guessed -- see the format doc.
	var rect: PackedInt32Array

	## The real client's own containment test, reproduced exactly:
	## `rect[0] <= x <= rect[2] && rect[1] <= z <= rect[3]`.
	##
	## Note this is inclusive, so the real degenerate rows in the real
	## table (zero-thickness boxes, and one inverted one) match only an
	## exact coordinate or nothing at all. That is faithfully what the
	## real client does with them, and deliberately not "corrected" here.
	func contains(local_x: float, local_z: float) -> bool:
		if whole_region or rect.size() < 4:
			return false
		return (float(rect[0]) <= local_x and local_x <= float(rect[2])
			and float(rect[1]) <= local_z and local_z <= float(rect[3]))

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
	## Real packed region id -> the Claims against it, in file order.
	var _by_region: Dictionary = {}

	## Every real claim against this region, in file order.
	func claims_for(region_x: int, region_y: int) -> Array:
		var key := (region_x << 8) | region_y
		if not _by_region.has(key):
			return []
		return _by_region[key]

	## Every zone index claiming this real region, in file order.
	func zone_indices_for(region_x: int, region_y: int) -> Array:
		var out: Array = []
		for claim in claims_for(region_x, region_y):
			if not out.has(claim.zone_index):
				out.append(claim.zone_index)
		return out

	## The zone whose real `ALL` row makes it this region's default, or -1.
	##
	## **The last `ALL` row wins, not the first.** Nine real regions are
	## claimed `ALL` by two sections (one pair is even the same zone listed
	## twice), and the client's own loader overwrites the region's existing
	## record when it meets a later `ALL` rather than keeping the first, so
	## this matches it. See the format doc.
	func default_zone_for(region_x: int, region_y: int) -> int:
		var found := -1
		for claim in claims_for(region_x, region_y):
			if claim.whole_region:
				found = claim.zone_index
		return found

	## The real zone a position falls in, or -1 -- the client's own
	## resolution order, reproduced exactly: the first real `RECT` claim
	## containing the point wins, and otherwise the region's real `ALL`
	## default applies.
	##
	## `local_x`/`local_z` are real region-local coordinates (the same
	## 0-1920 space `.nvm` uses), not world coordinates.
	func zone_for_position(region_x: int, region_y: int, local_x: float, local_z: float) -> int:
		for claim in claims_for(region_x, region_y):
			if claim.contains(local_x, local_z):
				return claim.zone_index
		return default_zone_for(region_x, region_y)

	## The single zone that owns this whole real region, or -1.
	##
	## Answers only when the region has a real `ALL` default and no real
	## `RECT` exception carved out of it, so the answer cannot depend on
	## where in the region you are standing. A region with any `RECT`
	## returns -1 and the caller should ask zone_for_position instead.
	## In the one real file checked this alone resolves 1,516 of the 1,563
	## real regions; the other 47 all carry a real `RECT`.
	func sole_zone_for(region_x: int, region_y: int) -> int:
		var claims := claims_for(region_x, region_y)
		if claims.is_empty():
			return -1
		for claim in claims:
			if not claim.whole_region:
				return -1
		return default_zone_for(region_x, region_y)

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
		claim.zone_index = current
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
		table._by_region[key].append(claim)
	if table.zones.is_empty():
		push_error("regioninfo: no real #TOWN/#FIELD section found")
		return null
	return table
