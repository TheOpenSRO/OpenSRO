extends RefCounted
class_name SkillBuffCatalog

## What the buff bar (HudBuffBoard, round 618) needs to know about a skill,
## by the per-level id a buff arrives with: its icon, name, level and
## description, and the four buff-bar tags of its Param block -- `cbuf`,
## `nbuf`, `bbuf`, `lnks` -- that retail's CIFMagicStateBoard reads off the
## client's skill ref (docs/protocol/magic_state_board.md).
##
## WHERE A SKILL'S ROW IS (measured, round 618). The client's list of skill
## shards, server_dep\silkroad\textdata\skilldata.txt, names 47 files
## SkillData_1000.txt .. SkillData_47000.txt, and SkillData_<k*1000>.txt
## holds the ids [(k-1)*1000, k*1000): measured on the box's Media.pk2 for
## 1000 (ids 1..999), 2000 (1000..1999), 3000 (2000..2999), 31000
## (30000..30897) and 47000 (46000..46405). So a buff's row is read by
## loading the ONE shard its id falls in, the first time an id from it
## arrives -- about 1 MB, instead of the 60 MB the full set is.
##
## THE COLUMNS (0-based; skilldata's own, as SkillDataReader reads them):
## [1] the per-level id, [7] the level, [61] the icon (UI_IconFile, e.g.
## skill\china\lightning_gyeonggong_a.ddj -- stored without the `icon\`
## root, which is prepended exactly as HudPanels._load_skill_icon does),
## [62] the name code (SN_...), [64] the tooltip description code, and from
## [69] the Param block.
##
## THE PARAM BLOCK is walked the way the engine's parser walks it
## (server/internal/skillparam: RefSkill_ParseParams 0x587630 in
## SR_GameServer.exe, measured to walk all 33,632 real rows to completion):
## each run is a code word followed by RUN[code]-1 values, a zero word is
## padding, `ssou` ends the block, and the loop stops after 50 words. The
## four tags are MARKERS -- run 1, no values -- so a tag is present iff the
## walk passes its code word. A code word stored as an integer spells the
## code big-endian (skillparam.CodeOf). RUN is skillparam.Run copied
## verbatim; server/internal/skillparam/client_table_test.go fails if the two
## ever differ.

const SHARD_FORMAT := "server_dep\\silkroad\\textdata\\skilldata_%d.txt"
const SKILL_NAME_TABLE_PATH := "server_dep\\silkroad\\textdata\\textdata_equip&skill.txt"

const COL_ID := 1
const COL_LEVEL := 7
const COL_ICON := 61
const COL_NAME := 62
const COL_DESC := 64
const PARAM_BLOCK_COLUMN := 69
const PARAM_BLOCK_MAX_WORDS := 50
const TERMINATOR := "ssou"

## The four tags the buff bar reads (client ref fields, READ from
## GlobalDataManager::FUN_009bbca0 per docs/protocol/skill_params.md):
## cbuf +0x134, nbuf +0x138, bbuf +0x184, lnks +0x194.
const BUFF_TAGS := ["cbuf", "nbuf", "bbuf", "lnks"]

## skillparam.Run, in 32-bit words including the code word (169 codes).
const RUN := {
	"abir": 3, "abnb": 2, "alcu": 2, "ao": 1, "apau": 3, "apru": 3, "ar": 3, "atca": 3, "att": 6,
	"bbuf": 1, "bgra": 3, "bl": 6, "bldr": 4, "br": 3, "bu": 4, "ca": 4, "cbuf": 1, "chcr": 2,
	"ck": 2, "cmcr": 2, "cnsm": 4, "cr": 3, "cshp": 7, "csit": 5, "csmd": 5, "csmp": 7, "cspd": 5,
	"cssr": 5, "cura": 2, "curl": 4, "curt": 3, "da": 2, "dar": 3, "dcmp": 2, "dcri": 2,
	"defp": 4, "defr": 3, "dgmp": 2, "dmgr": 5, "dmgt": 3, "dn": 5, "dru": 3, "dru2": 3, "ds": 5,
	"dtnt": 3, "dtt": 3, "dttp": 3, "dura": 2, "efr": 7, "efta": 1, "er": 3, "es": 4, "eshp": 1,
	"esht": 3, "expi": 3, "expu": 3, "fb": 3, "fe": 4, "fitp": 1, "fz": 3, "gdr": 2, "getv": 2,
	"heal": 5, "hide": 4, "hitm": 1, "hntp": 1, "hpi": 3, "hr": 3, "hst2": 2, "hst3": 2,
	"hste": 2, "hwir": 2, "hwit": 2, "inti": 3, "irgc": 3, "kb": 3, "ko": 3, "lfst": 2, "lkag": 3,
	"lkcp": 2, "lkdd": 2, "lkdh": 4, "lkdr": 4, "lks2": 1, "lnks": 5, "luck": 2, "mc": 3,
	"mcap": 3, "mom": 5, "mpi": 3, "mscc": 2, "msch": 3, "msid": 2, "msr": 3, "mstc": 2,
	"mwdt": 2, "mwhh": 2, "mwhs": 2, "mwmh": 2, "mwtt": 2, "my": 5, "nbuf": 1, "nmf": 1, "nmh": 1,
	"odar": 3, "onff": 3, "ovl2": 2, "pao": 2, "pcdu": 3, "pchr": 2, "pdm2": 2, "pdmg": 2,
	"php1": 1, "pmdg": 5, "pmdp": 5, "pmhp": 5, "pmmp": 5, "pmp1": 1, "pola": 3, "ps": 4,
	"puls": 2, "pw": 5, "pwdt": 2, "pwtt": 2, "qest": 5, "rcur": 2, "real": 4, "reat": 3,
	"reqa": 2, "reqc": 2, "reqi": 3, "reqn": 1, "resu": 3, "rhru": 3, "rmut": 2, "rpkt": 1,
	"rt": 4, "ru": 2, "saps": 3, "scls": 2, "se": 4, "setv": 4, "skc": 4, "sl": 4, "slcc": 1,
	"spda": 3, "spi": 2, "ssou": 1, "st": 4, "stns": 4, "stri": 3, "summ": 6, "tant": 3, "tb": 5,
	"tcmd": 3, "tctc": 1, "tel2": 3, "tel3": 3, "tele": 3, "terd": 2, "thld": 2, "thrd": 2,
	"tkss": 2, "tnt2": 3, "tpad": 2, "tpdd": 2, "tran": 3, "trap": 1, "zb": 3
}

var _archive: Pk2Reader = null
var _names: UiTextTable = null
var _names_loaded := false
## id -> row info (parse_row's Dictionary).
var _rows: Dictionary = {}
## shard number -> true once read (found or not).
var _shards_read: Dictionary = {}

func _init(archive: Pk2Reader = null) -> void:
	_archive = archive

## The code a stored Param word spells: its four bytes big-endian with the
## leading zero bytes dropped ("att" is 0x00617474).
static func code_of(word: int) -> String:
	var w := word & 0xFFFFFFFF
	var bytes := PackedByteArray([(w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF])
	var i := 0
	while i < 4 and bytes[i] == 0:
		i += 1
	return bytes.slice(i).get_string_from_ascii()

## Walks a Param block. Returns {"codes": PackedStringArray of the codes the
## walk passed, in order, "complete": false when a word was no code at all
## (the walk learned nothing past it)}.
static func walk(words: PackedInt64Array) -> Dictionary:
	var codes := PackedStringArray()
	var i := 0
	while i < words.size() and i < PARAM_BLOCK_MAX_WORDS:
		if words[i] == 0:
			i += 1
			continue
		var c := code_of(words[i])
		var run: int = int(RUN.get(c, 0))
		if run < 1:
			return {"codes": codes, "complete": false, "stopped": c}
		codes.append(c)
		if c == TERMINATOR:
			return {"codes": codes, "complete": true}
		i += run
	return {"codes": codes, "complete": true}

## One skilldata row, split on tabs, as the buff bar uses it; {} when the row
## carries no id.
static func parse_row(cols: PackedStringArray) -> Dictionary:
	if cols.size() <= COL_DESC:
		return {}
	var id_text := cols[COL_ID].strip_edges()
	if not id_text.is_valid_int():
		return {}
	var words := PackedInt64Array()
	for c in range(PARAM_BLOCK_COLUMN, mini(cols.size(), PARAM_BLOCK_COLUMN + PARAM_BLOCK_MAX_WORDS)):
		var t := cols[c].strip_edges()
		words.append(int(t) if t.is_valid_int() else 0)
	var w := walk(words)
	var codes: PackedStringArray = w["codes"]
	var icon := cols[COL_ICON].strip_edges().replace("/", "\\")
	var info := {
		"id": int(id_text),
		"level": int(cols[COL_LEVEL]) if cols[COL_LEVEL].strip_edges().is_valid_int() else 0,
		"icon": icon,
		"name_code": cols[COL_NAME].strip_edges(),
		"desc_code": cols[COL_DESC].strip_edges(),
		"walk_complete": bool(w["complete"]),
	}
	for tag in BUFF_TAGS:
		info[tag] = codes.has(tag)
	return info

## The shard a skill id's row is in (see the header).
static func shard_path(skill_id: int) -> String:
	return SHARD_FORMAT % ((skill_id / 1000 + 1) * 1000)

## Test seam and QA seam: a row without an archive.
func set_row(info: Dictionary) -> void:
	_rows[int(info["id"])] = info

## The row for a per-level skill id, loading its shard on first use; {} when
## the archive has no such row.
func info(skill_id: int) -> Dictionary:
	if _rows.has(skill_id):
		return _rows[skill_id]
	var shard := skill_id / 1000 + 1
	if not _shards_read.has(shard) and _archive != null:
		_shards_read[shard] = true
		_read_shard(shard_path(skill_id))
	return _rows.get(skill_id, {})

func _read_shard(path: String) -> void:
	var entry := ObjectLoader.find_file(_archive, path)
	if entry == null:
		print("SkillBuffCatalog: no %s in the archive" % path.get_file())
		return
	var n := 0
	for line in SkillDataReader._lines(_archive.read_file(entry)):
		var row := parse_row(line.split("\t"))
		if not row.is_empty():
			_rows[int(row["id"])] = row
			n += 1
	print("SkillBuffCatalog: %d skill rows read from %s" % [n, path.get_file()])

## The skill-name table (textdata_equip&skill.txt), the one HudPanels resolves
## skill names and descriptions through; null without an archive.
func names() -> UiTextTable:
	if not _names_loaded:
		_names_loaded = true
		if _archive != null:
			var entry := ObjectLoader.find_file(_archive, SKILL_NAME_TABLE_PATH)
			if entry != null:
				_names = UiTextTable.parse(_archive.read_file(entry))
	return _names

## Test seam: resolve names through this table.
func set_names(table: UiTextTable) -> void:
	_names = table
	_names_loaded = true

## A code's text through the skill-name table, or "" when it has none.
func text_of(code: String) -> String:
	var t := names()
	if t == null or code == "" or code == "xxx":
		return ""
	var s := t.get_text(code)
	return s if s != code else ""
