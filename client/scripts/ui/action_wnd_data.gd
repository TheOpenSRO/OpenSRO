extends RefCounted
class_name ActionWndData

## The action window's buttons: `server_dep\silkroad\textdata\actionwnddata.txt`
## in Media.pk2 (round 781). The window's slots carry nothing of their own --
## the layout's CommandIDs are stale -- and CIFAction::Create (0x6a4870) fills
## every slot from this file.
##
## READ, sro_client.exe:
##   - GlobalDataManager::RefParse_actionwnddata (0x976e60) parses one row of
##     tab-separated columns: id, service, name (Korean, not drawn), text key,
##     icon path, section, slot.
##   - CIFAction::Create keeps four slot arrays -- 18, 8, 8 and 18 -- whose
##     controls are the layout's ids 100+i, 200+i, 300+i and 400+i (the
##     GetChild calls at 0x6a48f5, 0x6a4955, 0x6a49b8, 0x6a4a22), every one
##     made hidden (0xb9daf0(0)) with the slot type 0x4a and the section's
##     owner byte 0x64..0x67 (0x666740). Then, for each row whose service is
##     not 0, it picks the section's array by column 6 (1..4; any other
##     asserts) and the slot by column 7, sets the icon, the tooltip from the
##     text key (except id 1015, 0x3f7, which takes 0x652d60(0x80) instead),
##     the action id (0x66c3c0), and shows it.
##   - A line starting `//` is a comment (the archive's own 1013 row is one).
##
## The file is the player's own; nothing of it is in this repository.

const PATH := "server_dep\\silkroad\\textdata\\actionwnddata.txt"

## Sections (column 6) and their slot counts and layout id bases (READ, above).
const SECTION_CONTROL := 1
const SECTION_CREATED := 2
const SECTION_SUMMONED := 3
const SECTION_EMOTICON := 4
const SECTION_SLOTS := {1: 18, 2: 8, 3: 8, 4: 18}
const SECTION_ID_BASE := {1: 100, 2: 200, 3: 300, 4: 400}

class Entry:
	var id: int
	var service: int
	var name: String
	var text_key: String
	var icon: String
	var section: int
	var slot: int

	## The ifaction.txt control id this entry's slot is (SECTION_ID_BASE + slot),
	## or -1 for a section or slot outside the window.
	func control_id() -> int:
		if not ActionWndData.SECTION_SLOTS.has(section):
			return -1
		if slot < 0 or slot >= int(ActionWndData.SECTION_SLOTS[section]):
			return -1
		return int(ActionWndData.SECTION_ID_BASE[section]) + slot

## The rows of the file's text, in file order. Comment lines, blank lines and
## rows short of the seven columns are skipped; so is a row whose service is
## 0 (Create skips it, `*(rec+4) != 0`).
static func parse_text(text: String) -> Array:
	var out: Array = []
	for raw in text.split("\n"):
		var line := raw.strip_edges(false, true).trim_suffix("\r")
		if line.begins_with("﻿"):
			line = line.substr(1)
		if line.strip_edges() == "" or line.strip_edges().begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() < 7:
			continue
		if not (cols[0].strip_edges().is_valid_int() and cols[5].strip_edges().is_valid_int()
				and cols[6].strip_edges().is_valid_int()):
			continue
		var e := Entry.new()
		e.id = int(cols[0])
		e.service = int(cols[1]) if cols[1].strip_edges().is_valid_int() else 0
		e.name = cols[2]
		e.text_key = cols[3].strip_edges()
		e.icon = cols[4].strip_edges()
		e.section = int(cols[5])
		e.slot = int(cols[6])
		if e.service == 0:
			continue
		out.append(e)
	return out

## The file's bytes (UTF-16 with its BOM, as the archive's text tables are, or
## UTF-8) as text.
static func decode(data: PackedByteArray) -> String:
	if data.size() >= 2 and data[0] == 0xff and data[1] == 0xfe:
		return TextDecode.utf16(data.slice(2))
	if data.size() >= 3 and data[0] == 0xef and data[1] == 0xbb and data[2] == 0xbf:
		return data.slice(3).get_string_from_utf8()
	return data.get_string_from_utf8()

static func parse(data: PackedByteArray) -> Array:
	return parse_text(decode(data))

## The rows from the player's Media.pk2, or [] when the archive or the file is
## missing.
static func load_from(archive: Pk2Reader) -> Array:
	if archive == null:
		return []
	var entry = ObjectLoader.find_file(archive, PATH)
	if entry == null:
		return []
	return parse(archive.read_file(entry))

## The entry for an action id, or null.
static func find(entries: Array, id: int) -> Entry:
	for e in entries:
		if (e as Entry).id == id:
			return e
	return null
