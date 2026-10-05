extends RefCounted
class_name MagicOptionTable

## The blue options (magic params) an item can carry: Media.pk2's
## server_dep\silkroad\textdata\magicoption.txt, and how the original client
## turns one option into its tooltip line (round 732; FUN_00670dd0,
## docs/protocol/item_tooltip.md "Magic options"). Data and formats only --
## the tooltip window and line composition are lane A's.
##
## API:
##   var t := MagicOptionTable.new().load(bytes)   # the raw textdata file
##   t.row(id) -> Row or null                       # ItemInstance.option_id(i)
##   MagicOptionTable.blue_pct(row, value)           # the blue line's (+x%)
##   MagicOptionTable.line_format(code) -> {format, keys, pct} or {}
##   MagicOptionTable.format_line(code, value, pct, text) -> String
## `text` is a Callable(key: String) -> String over textuisystem.txt.

const PATH := "server_dep\\silkroad\\textdata\\magicoption.txt"

## Columns, from the file's own rows (each option has one row per item
## degree, 1..12): 1 the id an item's param names, 2 the MATTR_ code, 4 the
## degree, 8..10 the option's allowed values as u16 pairs (high, low) --
## ER degree 10 reads 5,10 / 20,30 / 40,60. That 8..10 are the words the
## client reads at row +0x4c is INFERRED from their shape and from what
## FUN_00670dd0 does with them (below), not from the row parser.
const COL_ID := 1
const COL_CODE := 2
const COL_DEGREE := 4
const COL_RANGE0 := 8

class Row:
	var id: int
	var code: String
	var degree: int
	## The three packed range words, cols 8..10.
	var ranges := PackedInt64Array()

	## The lowest value: the first word's high u16 (`movzx edx, WORD PTR
	## [edi+0x2]`, 0x670f20).
	func min_value() -> int:
		return (ranges[0] >> 16) & 0xffff if ranges.size() > 0 else 0

	## The highest: the last non-zero u16 walking high, low, high, low...
	## through at most three words (0x670ef0-0x670f1e).
	func max_value() -> int:
		var m := 0
		for w in ranges:
			var hi: int = (w >> 16) & 0xffff
			if hi == 0:
				break
			m = hi
			var lo: int = w & 0xffff
			if lo == 0:
				break
			m = lo
		return m

## The table and the textuisystem lookup the world loads once from
## Media.pk2 (World3D._try_initialize_pk2_ui); null/invalid before that or
## without the archive.
static var shared: MagicOptionTable = null
static var shared_text: Callable = Callable()

var _rows := {}

func load(data: PackedByteArray) -> MagicOptionTable:
	if data.is_empty():
		return self
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	for line in text.replace("\r", "").split("\n"):
		if line.strip_edges() == "" or line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_RANGE0 + 2 or not cols[COL_ID].strip_edges().is_valid_int():
			continue
		var r := Row.new()
		r.id = int(cols[COL_ID])
		r.code = cols[COL_CODE].strip_edges()
		r.degree = int(cols[COL_DEGREE]) if cols[COL_DEGREE].strip_edges().is_valid_int() else 0
		for k in 3:
			var s := cols[COL_RANGE0 + k].strip_edges()
			r.ranges.append(int(s) if s.is_valid_int() else 0)
		_rows[r.id] = r
	return self

func size() -> int:
	return _rows.size()

func row(id: int) -> Row:
	return _rows.get(id, null)

## The blue line's "(+x%)": trunc((value - min) / (max - min) * 100), never
## below 0 (0x670f3b-0x670f89; the value is read unsigned). -1 for an empty
## range (the client would divide by zero; it is not shown).
static func blue_pct(r: Row, value: int) -> int:
	if r == null:
		return -1
	var lo := r.min_value()
	var hi := r.max_value()
	if hi == lo:
		return -1
	return maxi(0, int((float(value) - float(lo)) / (float(hi) - float(lo)) * 100.0))

## Each option's line, READ from FUN_00670dd0: the format string and the
## textuisystem keys it fetches, in the sprintf argument order. The argument
## order is the REVERSE of the fetch order (the strings are pushed last
## first); that rule is checked on two lines whose real text is known --
## "HP/MP recovery %d%% Increase" and "Steady(%dTime/times)". `pct` says
## whether the format carries the "(+x%)". The value is the option's own
## value (ItemInstance.option_value). Codes not listed (the reinforce
## timer, the 3rd-job, avatar and Nasrun options) are OPEN.
const FORMATS := {
	"MATTR_STR": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_STR", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_STR_SET": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_STR", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_INT": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_INT", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_INT_SET": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_INT", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_HP": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_HP", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_HP_SET": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_HP", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_MP": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_MP", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_MP_SET": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_MP", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_CRITICAL": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_CRITICAL", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_BLOCKRATE": {"format": "%s %d %s (+%d%%)", "keys": ["PARAM_BLOCKING", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_HR": {"format": "%s %d%% %s (+%d%%)", "keys": ["PARAM_HR", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_ER": {"format": "%s %d%% %s (+%d%%)", "keys": ["PARAM_ER", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_ER_SET": {"format": "%s %d%% %s (+%d%%)", "keys": ["PARAM_ER", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_DUR": {"format": "%s %d%% %s (+%d%%)", "keys": ["PARAM_DUR", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_DUR_SET": {"format": "%s %d%% %s (+%d%%)", "keys": ["PARAM_DUR", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_REGENHPMP": {"format": "%s/%s %d%% %s (+%d%%)", "keys": ["PARAM_HEAL_HP", "PARAM_HEAL_MP", "#", "PARAM_INCREASE"], "pct": true},
	"MATTR_LUCK": {"format": "%s(%d%s)", "keys": ["PARAM_LUCK", "#", "UIIT_STT_COUNT"], "pct": false},
	"MATTR_LUCK_SET": {"format": "%s(%d%s)", "keys": ["PARAM_LUCK", "#", "UIIT_STT_COUNT"], "pct": false},
	"MATTR_SOLID": {"format": "%s(%d%s)", "keys": ["PARAM_SOLID", "#", "UIIT_STT_COUNT"], "pct": false},
	"MATTR_ATHANASIA": {"format": "%s(%d%s)", "keys": ["PARAM_ATHANASIA", "#", "UIIT_STT_COUNT"], "pct": false},
	"MATTR_ASTRAL": {"format": "%s %d %s", "keys": ["PARAM_ASTRAL", "#", "UIIT_STT_COUNT"], "pct": false},
	"MATTR_APE": {"format": "%s: %d %s", "keys": ["PARAM_ATTR_ASSIMILATION", "#", "UIIT_STT_COUNT"], "pct": false},
	"MATTR_REPAIR": {"format": "%s (%d%s)", "keys": ["PARAM_REPAIR", "#", "UIIT_STT_COUNT"], "pct": false},
	"MATTR_EVADE_BLOCK": {"format": "%s %d (+%d%%)", "keys": ["PARAM_IGNORE_BLOCKING", "#"], "pct": true},
	"MATTR_EVADE_CRITICAL": {"format": "%s %d (+%d%%)", "keys": ["PARAM_EVADE_CRITICAL", "#"], "pct": true},
	"MATTR_RESIST_FROSTBITE": {"format": "%s,%s%s %d%% %s (+%d%%)", "keys": ["PARAM_FZ", "PARAM_FB", "PARAM_HOUR", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_ESHOCK": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_ES", "PARAM_HOUR", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_BURN": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_BU", "PARAM_HOUR", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_POISON": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_PS", "PARAM_HOUR", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_ZOMBIE": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_ZB", "PARAM_HOUR", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_STUN": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_STUN", "UIIT_STT_PROBABILITY", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_CSMP": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_CURSIE_MP", "UIIT_STT_PROBABILITY", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_DISEASE": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_DISEASE", "UIIT_STT_PROBABILITY", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_SLEEP": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_SLEEP", "UIIT_STT_PROBABILITY", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_RESIST_FEAR": {"format": "%s%s %d%% %s (+%d%%)", "keys": ["PARAM_FEAR", "UIIT_STT_PROBABILITY", "#", "PARAM_DECREASE"], "pct": true},
	"MATTR_DEC_MAXDUR": {"format": "%s %d%% %s", "keys": ["PARAM_MAX_DURABILITY", "#", "PARAM_DECREASE"], "pct": false},
	"MATTR_NOT_REPARABLE": {"format": "%s (%s %d%% %s)", "keys": ["PARAM_NOT_REPAIRABLE", "PARAM_MAX_DURABILITY", "#", "PARAM_INCREASE"], "pct": false},
}

static func line_format(code: String) -> Dictionary:
	return FORMATS.get(code, {})

## The option's line: the format filled with the keys' text, the value at
## "#", and the percent when the format carries it. "" for an unlisted code.
static func format_line(code: String, value: int, pct: int, text: Callable) -> String:
	var f: Dictionary = line_format(code)
	if f.is_empty():
		return ""
	var args: Array = []
	for k in f["keys"]:
		args.append(value if k == "#" else String(text.call(k)))
	if f["pct"]:
		args.append(maxi(pct, 0))
	return String(f["format"]) % args
