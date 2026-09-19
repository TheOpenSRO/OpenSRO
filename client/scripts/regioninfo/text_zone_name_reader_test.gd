extends SceneTree

## Exercises TextZoneNameReader against a synthetic textzonename-shaped
## buffer (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/regioninfo/text_zone_name_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A UTF-16LE table with BOM, tab-separated, CRLF-terminated, the shape the
## real file has: service, region id, a non-Latin original, five zero
## columns, then the language columns.
func _table(rows: Array) -> PackedByteArray:
	var text := ""
	for r in rows:
		text += "\t".join(r) + "\r\n"
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _initialize() -> void:
	var data := _table([
		["1", "25000", "장안", "0", "0", "0", "0", "0", "Jangan", "Jangan", "0"],
		["1", "23088", "알렉산드리아", "0", "0", "0", "0", "0", "Alexandria", "Alejandría", "0"],
		# A stripped archive: column 8 is the "0" filler, the name sits after it.
		["1", "23089", "?", "0", "0", "0", "0", "0", "0", "Alexandria Delta", "0"],
		# Service 0: not loaded by the game, not by this reader.
		["0", "23090", "x", "0", "0", "0", "0", "0", "Nowhere", "0", "0"],
		# Too short to carry a language column.
		["1", "23091", "x"],
	])
	var names := TextZoneNameReader.parse(data)
	_check(names.size() == 3, "three usable rows parsed (got %d)" % names.size())
	_check(TextZoneNameReader.region_id(97, 168) == 25000, "region 97/168 packs to 25000")
	_check(TextZoneNameReader.region_id(90, 48) == 23088, "region 90/48 packs to 23088")
	_check(TextZoneNameReader.name_for(names, 97, 168) == "Jangan", "97/168 resolves to Jangan")
	_check(TextZoneNameReader.name_for(names, 90, 48) == "Alexandria", "90/48 resolves to Alexandria (column 8)")
	_check(TextZoneNameReader.name_for(names, 90, 49) == "Alexandria Delta", "a filler column 8 falls through to the next Latin column")
	_check(TextZoneNameReader.name_for(names, 90, 50) == "", "a service-0 row is skipped")
	_check(TextZoneNameReader.name_for(names, 90, 51) == "", "a short row is skipped")
	_check(TextZoneNameReader.name_for(names, 1, 1) == "", "an unknown region resolves to nothing, never a guess")
	_check(TextZoneNameReader.parse(PackedByteArray()).is_empty(), "an empty buffer gives an empty table")

	if _failures > 0:
		print("%d FAILURE(S)" % _failures)
		quit(1)
	else:
		print("ALL PASS")
		quit(0)
