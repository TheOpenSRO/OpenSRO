extends RefCounted
class_name ItemTableReader

## Reads the item tables in the player's own Media.pk2, so the client can
## show an item's real name and inventory icon from the id the server sends.
##
## `server_dep\silkroad\textdata\itemdata*.txt` is UTF-16LE, tab separated,
## ~160 columns wide and split across numbered parts. Three fields matter:
## the id, the display name, and the icon path. As with the character
## tables, the icon is found **by content** rather than by column index --
## the parts are not guaranteed to agree on layout, and a row carries three
## resource paths of which only one is a `.ddj`.
##
## The icon path is stored relative to `icon\`: a row reads
## `item\china\man_item\clothes_01_ba.ddj` and the file lives at
## `icon\item\china\man_item\clothes_01_ba.ddj`. A real archive holds 5,370
## of them.

const TABLE_PATHS := [
	"server_dep\\silkroad\\textdata\\itemdata.txt",
	"server_dep\\silkroad\\textdata\\itemdata_5000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_10000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_15000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_20000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_25000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_30000.txt",
]

## Icon paths in the table are relative to this directory in Media.pk2.
const ICON_PREFIX := "icon\\"

## Column 1 is the id, column 3 the display name, in every part checked.
const COL_ID := 1
const COL_NAME := 3

class Item:
	var id: int
	var item_name: String
	## Archive path of the inventory icon, ICON_PREFIX already applied.
	var icon_path: String

## Parses one itemdata part into {id -> Item}, merging into `into` so the
## parts can be accumulated.
static func parse(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_NAME:
			continue
		var id_text := cols[COL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var item := Item.new()
		item.id = int(id_text)
		item.item_name = cols[COL_NAME].strip_edges()
		var icon := _find_icon_path(cols)
		if icon != "":
			item.icon_path = ICON_PREFIX + icon
		# A row with neither a name nor an icon tells the player nothing.
		if item.item_name == "" and item.icon_path == "":
			continue
		into[item.id] = item
	return into

## The `.ddj` field in an item row. A row also carries two `.bsr` model
## paths, so matching on the extension is what picks the icon out.
static func _find_icon_path(cols: PackedStringArray) -> String:
	for col in cols:
		var trimmed := col.strip_edges()
		if trimmed.to_lower().ends_with(".ddj"):
			return trimmed
	return ""

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text.replace("\r", "").split("\n")
