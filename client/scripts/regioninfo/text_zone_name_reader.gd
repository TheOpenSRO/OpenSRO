class_name TextZoneNameReader

## Reads the client's own per-region zone-name table,
## `server_dep\silkroad\textdata\textzonename.txt` in Media.pk2 -- the real
## text resource behind the area name a real client shows over its minimap.
##
## Why this exists (2026-09-19, docs/rounds/map.md): the zone label used to
## be resolved only through `Shader\regioninfo.txt`, a 15-zone table (Jangan
## to Central Asia, Korean names) that predates every later expansion. A
## region it does not claim -- all of Alexandria, for one -- left the label
## and the minimap showing whatever zone the player came from. This table
## covers the whole world by REGION ID (4,176 rows in a retail archive) with
## real localized names, so it is the primary source now and the Shader
## table's transliterations are the fallback.
##
## Row shape, UTF-16LE tab-separated like every other textdata table:
##
##   <service> <regionId> <korean> 0 0 0 0 0 <english> <...more languages>
##
## `regionId` packs the region the same way this project already does
## everywhere else: `(x << 8) | y` -- Jangan's town region 97/168 is 25000.
## The display name is picked by UiTextTable's own language-column rule
## (column 8 when it holds Latin text, its documented fallbacks otherwise),
## so a multi-language or a stripped archive resolves the same way UI text
## does. Rows whose service column is not "1" are skipped, as the game does.

const COL_SERVICE := 0
const COL_REGION_ID := 1

## The packed region id the table keys on.
static func region_id(region_x: int, region_y: int) -> int:
	return (region_x << 8) | region_y

## Parses the table into {region_id: int -> display name: String}. An empty
## buffer, or one with no usable rows, gives an empty Dictionary rather than
## an error: a caller without the file simply keeps its other source.
static func parse(data: PackedByteArray) -> Dictionary:
	var names := {}
	if data.is_empty():
		return names
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var full_text := ""
	if raw.size() >= 2:
		full_text = raw.get_string_from_utf16()
	if full_text.is_empty() and raw.size() > 0:
		full_text = raw.get_string_from_utf8()
	for line in full_text.split("\n"):
		var clean := line.strip_edges()
		if clean.is_empty() or clean.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= UiTextTable.COL_ENGLISH:
			continue
		if cols[COL_SERVICE].strip_edges() != "1":
			continue
		var id_text := cols[COL_REGION_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var name := UiTextTable._pick_language_column(cols, UiTextTable.COL_ENGLISH)
		if name == "":
			continue
		names[id_text.to_int()] = name
	return names

## The display name for a region, or "" when the table has no row for it.
static func name_for(names: Dictionary, region_x: int, region_y: int) -> String:
	return String(names.get(region_id(region_x, region_y), ""))
