extends RefCounted
class_name TitleNet

## Round 838: a character's title (server/internal/session/titlescroll.go).
## The title is retail's hwan level, READ from sro_client.exe:
##   - S->C 0x30DF {u32 uid, u8 level} (FUN_008a7630) finds the object and
##     calls FUN_009ca930(level); the spawn record's HwanLevel (pc_spawn row
##     3, read by slot 22 into DAT_00ef1bb8) reaches the same call from slot
##     27 (0x9dbcc0), and 0x3013 carries the own one.
##   - FUN_009ca930 keeps the level (+0x764) and builds the title through
##     FUN_00941000: hwanleveldata.txt's row for the level, its Title_CH70
##     key for a Chinese body or Title_EU70 for a European one (the body's
##     ref +0x9d), the text table's line for the key -- "" when the level has
##     no row or the key no line (0x8c9b20) -- handed to the title slot
##     (vslot 30, c:0x9c28a0): drawn left of the name in #FFE65B, emptied
##     while a job suit is worn (World3D._job_plate_decor).
## OURS: the archive's ITEM_TITLE_255 "Custom Title Scroll" -- level 255 with
## the player's own text, which the server sends as
##   - S->C 0x01A8 {u32 uid, str text}
## and the scroll's use request carries (UseItemNet.encode_use_custom_title).
## OpenSRO has no 0x3013: the own title comes as a 0x30DF after the entry,
## so the own one is forgotten at every entry (NetClient.enter_world).
##
## Strings are u16 length + UTF-8 bytes, as everywhere on the wire.

const OP_HWAN_LEVEL := 0x30DF
const OP_CUSTOM_TITLE := 0x01A8
## The custom title's level and scroll (OURS).
const CUSTOM_LEVEL := 255
const CUSTOM_ITEM_CODE := "ITEM_TITLE_255"
## The custom title's longest text (the server's customTitleMax).
const CUSTOM_MAX := 20
## The client's hwan level table.
const LEVEL_TABLE := "server_dep\\silkroad\\textdata\\hwanleveldata.txt"

## uid's title changed (its level or its custom text).
signal changed(uid: int)

## uid -> hwan level (absent = 0).
var levels: Dictionary = {}
## uid -> custom title text.
var customs: Dictionary = {}

func register_with(client: Node) -> void:
	client.register_handler(OP_HWAN_LEVEL, func(data: PackedByteArray) -> void:
		var d := decode_hwan_level(data)
		if not d.is_empty():
			note_level(int(d["uid"]), int(d["level"]), true))
	client.register_handler(OP_CUSTOM_TITLE, func(data: PackedByteArray) -> void:
		var d := decode_custom_title(data)
		if d.is_empty():
			return
		var uid := int(d["uid"])
		if String(d["text"]) == "":
			customs.erase(uid)
		else:
			customs[uid] = String(d["text"])
		changed.emit(uid))

## Notes uid's level (a 0x30DF, or a spawn record's with `emit` false: the
## plate is built after it).
func note_level(uid: int, level: int, emit: bool) -> void:
	uid &= 0xffffffff
	if level <= 0:
		levels.erase(uid)
	else:
		levels[uid] = level
	if emit:
		changed.emit(uid)

func level_of(uid: int) -> int:
	return int(levels.get(uid & 0xffffffff, 0))

func custom_of(uid: int) -> String:
	return String(customs.get(uid & 0xffffffff, ""))

## A body left view: its title goes with it (a new spawn brings it again).
func forget(uid: int) -> void:
	levels.erase(uid & 0xffffffff)
	customs.erase(uid & 0xffffffff)

func clear() -> void:
	levels.clear()
	customs.clear()

## uid's title text: "" for none. `table` is parse_levels' result, `lookup`
## the text table's Callable(key) -> String ("" on a miss).
func title_text(uid: int, europe: bool, table: Dictionary, lookup: Callable) -> String:
	return text_for(level_of(uid), custom_of(uid), europe, table, lookup)

## The text for a level (READ FUN_00941000, see the top). OURS: level 255
## shows its custom text, and nothing until that text has come.
static func text_for(level: int, custom: String, europe: bool, table: Dictionary, lookup: Callable) -> String:
	if level <= 0:
		return ""
	if level == CUSTOM_LEVEL:
		return custom
	var row: Array = table.get(level, [])
	if row.size() < 2:
		return ""
	var key := String(row[1 if europe else 0])
	if key == "" or key == "xxx" or not lookup.is_valid():
		return ""
	return String(lookup.call(key))

## hwanleveldata.txt -> {level: [Title_CH70 key, Title_EU70 key]}: tab
## columns HwanLevel, Title_CH70, Title_EU70 (MEASURED: 256 rows, 0..255).
static func parse_levels(text: String) -> Dictionary:
	var out := {}
	for line in text.replace("\r", "").split("\n"):
		var cols := line.split("\t")
		if cols.size() < 3 or not cols[0].strip_edges().is_valid_int():
			continue
		out[int(cols[0])] = [cols[1].strip_edges(), cols[2].strip_edges()]
	return out

static func decode_hwan_level(d: PackedByteArray) -> Dictionary:
	if d.size() < 5:
		return {}
	return {"uid": d.decode_u32(0), "level": d[4]}

static func decode_custom_title(d: PackedByteArray) -> Dictionary:
	if d.size() < 6:
		return {}
	var n := d.decode_u16(4)
	if 6 + n > d.size():
		return {}
	return {"uid": d.decode_u32(0), "text": d.slice(6, 6 + n).get_string_from_utf8()}
