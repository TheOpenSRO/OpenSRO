extends RefCounted
class_name SkillBuffCatalog

## What the buff bar (HudBuffBoard, round 618) needs to know about a skill,
## by the per-level id a buff arrives with: its icon, name, level and
## description, and the four buff-bar tags of its Param block -- `cbuf`,
## `nbuf`, `bbuf`, `lnks` -- that retail's CIFMagicStateBoard reads off the
## client's skill ref (docs/protocol/magic_state_board.md).
##
## WHICH FILES (READ, 0x844cd0 Client_LoadAllRefData). Retail loads the list
## textdata\skilldataenc.txt, which names SkillData_1000ENC.txt ..
## SkillData_47000ENC.txt in that order. The ENC files are encrypted
## (0x93ef10 checks a trailing "\r\n//encrypt" and 0x4f5140 decrypts with key
## tables inside sro_client.exe -- the scheme is in the protocol doc; the
## tables are the executable's own and are not copied here). This catalog reads
## the plain twins, skilldata_<n>.txt, named by stripping "ENC" from each
## list entry, in the list's order.
##
## WHY THE PLAIN TWINS ARE ENOUGH (MEASURED on the box, round 618's review):
## the decrypted ENC set holds 33,632 ids; the plain set 33,698 ids
## (66 extra, never sent by a server built from retail's data). The shards
## OVERLAP -- the 5000-wide files 5000..30000 each repeat the five 1000-wide
## files below them, and 35000 holds 30000..46422 -- so 27,697 ids appear
## twice. Resolving a duplicate to its FIRST file in list order, every one of
## the 33,632 ids retail knows carries exactly the four tags its ENC row does
## (0 differences). The one plain duplicate that disagrees, id 35958
## (shard 35000: none; shard 36000: nbuf+bbuf), agrees with ENC under
## first-wins, which is why first-wins is used. Retail's own duplicate rule is
## moot for it (its ENC duplicates all agree) and was not read.
##
## THE INDEX is built once, at world entry (preload): the shard bytes are read
## from the archive on the main thread (~1 ms a shard) and parsed on a
## WorkerThreadPool task (~2 s for the 61k rows), so a buff's arrival never
## parses a shard inside a signal handler. Until the index is ready, info()
## says so and the board holds the buff.
##
## THE COLUMNS (0-based; skilldata's own, as SkillDataReader reads them):
## [1] the per-level id, [7] the level, [61] the icon (UI_IconFile, e.g.
## skill\china\lightning_gyeonggong_a.ddj -- stored without the `icon\`
## root, which is prepended exactly as HudPanels._load_skill_icon does),
## [62] the name code (SN_...), [64] the tooltip description code, and from
## [69] the Param block.
##
## THE PARAM BLOCK is walked the way the CLIENT's parser walks it
## (GlobalDataManager::FUN_009bbca0, READ): each run is a code word followed
## by RUN[code]-1 values, a zero word is skipped, `ssou` and `sstt` end the
## block (both return), and the cursor stops past index 49 -- it starts at
## index 1, so 49 words (real rows reach index 40 at most, MEASURED). A code
## the parser has no branch for is never advanced past (retail would spin), so
## a walk that meets one stops and says it is incomplete. `cbuf`, `nbuf` and
## `bbuf` are markers (run 1, no values); `lnks` is a run of 5. A tag is
## present iff the walk passes its code word; a code word stored as an
## integer spells the code big-endian (skillparam.CodeOf). RUN is the client
## parser's table (188 codes); it differs from the server's skillparam.Run in
## `bldr` (5, the server's 4), `fitp` (2, not 1) and 20 codes the server has
## no branch for. server/internal/skillparam/client_table_test.go guards it.
## Over the 61,395 plain rows every walk completes with this table.

const TEXTDATA_DIR := "server_dep\\silkroad\\textdata\\"
const LIST_ENC_PATH := "server_dep\\silkroad\\textdata\\skilldataenc.txt"
const LIST_PLAIN_PATH := "server_dep\\silkroad\\textdata\\skilldata.txt"
## HudPanels.SKILL_NAME_TABLE_PATH's file; named here so this script does not
## pull HudPanels (and the NetClient autoload it names) into a bare --script.
const SKILL_NAME_TABLE_PATH := "server_dep\\silkroad\\textdata\\textdata_equip&skill.txt"

const COL_ID := 1
const COL_LEVEL := 7
const COL_ICON := 61
const COL_NAME := 62
const COL_DESC := 64
const PARAM_BLOCK_COLUMN := 69
## The client parser's cursor runs from index 1 while index <= 0x31.
const PARAM_BLOCK_MAX_WORDS := 49
const TERMINATORS := ["ssou", "sstt"]

## The four tags the buff bar reads (client ref fields cbuf +0x134, nbuf
## +0x138, bbuf +0x184, lnks +0x194; READ in 0x9bbca0).
static var BUFF_TAGS := ["cbuf", "nbuf", "bbuf", "lnks"]

## The client parser's run table (0x9bbca0), in 32-bit words including the
## code word.
const RUN := {
	"abir": 3, "abnb": 2, "agac": 3, "alcu": 2, "ao": 1, "apau": 3, "apru": 3, "ar": 3, "atca": 3,
	"att": 6, "bbuf": 1, "bcnt": 2, "bgra": 3, "bl": 6, "bldr": 5, "br": 3, "bu": 4, "ca": 4,
	"cabf": 2, "cbuf": 1, "chcr": 2, "chpi": 2, "chst": 2, "civi": 2, "ck": 2, "cmcr": 2,
	"cnsm": 4, "cr": 3, "cshp": 7, "csit": 5, "csmd": 5, "csmp": 7, "cspd": 5, "cssr": 5,
	"csum": 2, "cura": 2, "curl": 4, "curt": 3, "da": 2, "dac": 2, "dar": 3, "dcmp": 2, "dcri": 2,
	"defp": 4, "defr": 3, "dgmp": 2, "dmgr": 5, "dmgt": 3, "dn": 5, "dra2": 2, "dru": 3,
	"dru2": 3, "ds": 5, "dspl": 3, "dtnt": 3, "dtt": 3, "dttp": 3, "dura": 2, "efr": 7, "efta": 1,
	"er": 3, "es": 4, "eshp": 1, "esht": 3, "expi": 3, "expu": 3, "fb": 3, "fe": 4, "fitp": 2,
	"fz": 3, "gdr": 2, "getv": 2, "heal": 5, "hel2": 5, "hide": 4, "hitm": 1, "hntp": 1, "hpi": 3,
	"hr": 3, "hst2": 2, "hst3": 2, "hste": 2, "hwir": 2, "hwit": 2, "iddm": 2, "inti": 3,
	"irgc": 3, "iwky": 1, "jobs": 2, "kb": 3, "ko": 3, "lfst": 2, "lkag": 3, "lkcp": 2, "lkdd": 2,
	"lkdh": 4, "lkdr": 4, "lks2": 1, "lnks": 5, "luck": 2, "mc": 3, "mcap": 3, "mom": 5, "mpi": 3,
	"mscc": 2, "msch": 3, "msid": 2, "msr": 3, "mstc": 2, "mwdt": 2, "mwhh": 2, "mwhs": 2,
	"mwmh": 2, "mwtt": 2, "my": 5, "nbuf": 1, "nmf": 1, "nmh": 1, "odar": 3, "onff": 3, "ovl2": 2,
	"pao": 2, "pcdu": 3, "pchr": 2, "pdm2": 2, "pdmg": 2, "php1": 1, "pls2": 5, "pmdg": 5,
	"pmdp": 5, "pmhp": 5, "pmmp": 5, "pmp1": 1, "pola": 3, "ps": 4, "puls": 2, "pw": 5, "pwdt": 2,
	"pwtt": 2, "qest": 5, "rcur": 2, "real": 4, "reat": 3, "reqa": 2, "reqc": 2, "reqi": 3,
	"reqn": 1, "resu": 3, "rhru": 3, "rmut": 2, "rpkt": 1, "rsag": 1, "rt": 4, "ru": 2, "saps": 3,
	"scls": 2, "se": 4, "setv": 4, "skc": 4, "sl": 4, "slcc": 1, "smac": 3, "spda": 3, "spi": 2,
	"ssou": 1, "sstt": 1, "st": 4, "stns": 4, "stri": 3, "summ": 6, "tant": 3, "tb": 5, "tcmd": 3,
	"tctc": 1, "tel2": 3, "tel3": 3, "tel4": 3, "tele": 3, "terd": 2, "thld": 2, "thrd": 2,
	"tkss": 2, "tnt2": 3, "tpad": 2, "tpdd": 2, "tran": 3, "trap": 1, "zb": 3
}

enum State { EMPTY, LOADING, READY }

var _archive: Pk2Reader = null
var _state := State.EMPTY
## id -> row info (parse_row's Dictionary).
var _rows: Dictionary = {}
var _task_id := -1
var _task_result: Dictionary = {}
var _names: UiTextTable = null
var _names_loaded := false
## Returns the shared skill-name table (World3D hands HudPanels'), so the
## tooltip does not parse textdata_equip&skill.txt a second time.
var names_provider: Callable = Callable()
## Returns the object-name table (textdata_object.txt; World3D hands its
## own). Round 638 review, READ/MEASURED: the client's TextStringManager
## loads textdataname.txt's list -- TextData_Equip&Skill.txt then
## TextData_Object.txt -- into ONE map, so a skill code found only in the
## second resolves too: SN_SKILL_MALL_PRE_APRU_4W ("Premium") is in
## textdata_object.txt and not in textdata_equip&skill.txt (MEASURED, the
## box's Media.pk2). The first file keeps a key both carry (first row wins).
var object_names_provider: Callable = Callable()

func _init(archive: Pk2Reader = null) -> void:
	_archive = archive
	# No archive: nothing to load; rows come from set_row (tests, QA).
	if archive == null:
		_state = State.READY

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
## walk passed, in order, "complete": false when a word was no code the
## client's parser knows (the walk learned nothing past it)}.
## The walk also returns "values": code -> PackedInt64Array of the run's
## values (the words after the code word), first occurrence kept.
static func walk(words: PackedInt64Array) -> Dictionary:
	var codes := PackedStringArray()
	var values := {}
	var i := 0
	while i < words.size() and i < PARAM_BLOCK_MAX_WORDS:
		if words[i] == 0:
			i += 1
			continue
		var c := code_of(words[i])
		var run: int = int(RUN.get(c, 0))
		if run < 1:
			return {"codes": codes, "values": values, "complete": false, "stopped": c}
		codes.append(c)
		if not values.has(c):
			values[c] = words.slice(i + 1, mini(i + run, words.size()))
		if c in TERMINATORS:
			return {"codes": codes, "values": values, "complete": true}
		i += run
	return {"codes": codes, "values": values, "complete": true}

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
	var info := {
		"id": int(id_text),
		"level": int(cols[COL_LEVEL]) if cols[COL_LEVEL].strip_edges().is_valid_int() else 0,
		"icon": cols[COL_ICON].strip_edges().replace("/", "\\"),
		"name_code": cols[COL_NAME].strip_edges(),
		"desc_code": cols[COL_DESC].strip_edges(),
		"walk_complete": bool(w["complete"]),
	}
	for tag in BUFF_TAGS:
		info[tag] = codes.has(tag)
	# Round 640: whether the row is an 'onff' toggle (client +0x58), and its
	# Basic_Code (col 3) for the skilleffect rows the walls' DefenseEfp is on.
	info["onff"] = codes.has("onff")
	# A protection wall ('pw', client +0x90): its caster is rooted while it
	# stands (round 640, OURS -- World3D._wall_root).
	info["pw"] = codes.has("pw")
	info["basic_code"] = cols[3].strip_edges() if cols.size() > 3 else ""
	# 'tele' value[0] and value[1] (round 616-618 integration): value[1] is
	# the ground-cast move's reach, D in the server's FUN_005862e0 (READ);
	# value[0] is not read there (OPEN). [] when the row has no 'tele'.
	var tele: PackedInt64Array = w["values"].get("tele", PackedInt64Array())
	info["tele"] = [int(tele[0]), int(tele[1])] if tele.size() >= 2 else []
	# Round 785: 'tel2' (the Europe Teleport rows) -- READ, the client's
	# parser FUN_009bbca0 files 'tele' at ref +0xc8 and 'tel2' at +0xcc, and
	# the skill use FUN_0081ba10 (0x81bf26..0x81bf38) takes the cursor's
	# point for a row with either (SkillCursorCast).
	var tel2: PackedInt64Array = w["values"].get("tel2", PackedInt64Array())
	info["tel2"] = [int(tel2[0]), int(tel2[1])] if tel2.size() >= 2 else []
	# Round 785: the timing and re-use columns (skilldata's own, 0-based):
	# 11 Action_PreparingTime, 12 Action_CastingTime, 14 Action_ReuseDelay
	# and 18 Action_Overlap, whose high byte is the cooldown group
	# (SkillCooldowns' header).
	info["prep"] = _int_col(cols, 11)
	info["cast"] = _int_col(cols, 12)
	info["reuse"] = _int_col(cols, 14)
	info["cooldown_group"] = (_int_col(cols, 18) >> 24) & 0xff
	return info

static func _int_col(cols: PackedStringArray, i: int) -> int:
	if i >= cols.size():
		return 0
	var t := cols[i].strip_edges()
	return int(t) if t.is_valid_int() else 0

## The shard file names a list names, in its order: "SkillData_1000ENC.txt"
## -> "skilldata_1000.txt" (the plain twin).
static func shard_names(list_bytes: PackedByteArray) -> PackedStringArray:
	var out := PackedStringArray()
	for line in SkillDataReader._lines(list_bytes):
		var n := line.strip_edges().to_lower()
		if n == "" or n.begins_with("//"):
			continue
		n = n.replace("enc.txt", ".txt")
		if not out.has(n):
			out.append(n)
	return out

## The index: every row of `shards` ([[name, bytes], ...] in list order), a
## duplicate id resolved to its FIRST file (see the header). Pure data -- runs
## on a worker thread.
static func build_index(shards: Array) -> Dictionary:
	var rows := {}
	for s in shards:
		var bytes: PackedByteArray = s[1]
		for line in SkillDataReader._lines(bytes):
			var row := parse_row(line.split("\t"))
			if not row.is_empty() and not rows.has(row["id"]):
				rows[row["id"]] = row
	return rows

## Starts building the index (World3D calls it when the world is built). The
## reads are here, on the calling thread; the parse is a WorkerThreadPool task.
func preload_index() -> void:
	if _archive == null or _state != State.EMPTY:
		return
	var list_entry := ObjectLoader.find_file(_archive, LIST_ENC_PATH)
	if list_entry == null:
		list_entry = ObjectLoader.find_file(_archive, LIST_PLAIN_PATH)
	if list_entry == null:
		print("SkillBuffCatalog: no skilldata list in the archive -- buff icons carry no skill data")
		_state = State.READY
		return
	var shards: Array = []
	var t0 := Time.get_ticks_msec()
	for n in shard_names(_archive.read_file(list_entry)):
		var e := ObjectLoader.find_file(_archive, TEXTDATA_DIR + n)
		if e != null:
			shards.append([n, _archive.read_file(e)])
		else:
			print("SkillBuffCatalog: the list names %s, which the archive lacks" % n)
	print("SkillBuffCatalog: %d skilldata shards read in %d ms; parsing off the main thread" % [shards.size(), Time.get_ticks_msec() - t0])
	start_index(shards)

## Parses `shards` ([[name, bytes], ...] in list order) on a WorkerThreadPool
## task; poll() collects it. preload_index's second half, and the test seam
## for the threaded path.
func start_index(shards: Array) -> void:
	_state = State.LOADING
	var result := _task_result
	_task_id = WorkerThreadPool.add_task(func() -> void:
		var t := Time.get_ticks_msec()
		# Named through the class: a bare static call from this lambda,
		# on a worker thread, resolved against a null base (measured).
		result["rows"] = SkillBuffCatalog.build_index(shards)
		result["ms"] = Time.get_ticks_msec() - t)

## A catalog freed with its parse still out waits for it (round 754: Godot
## 4.7 aborts at quit over a task nobody waited for; MusicDirector._exit_tree).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _task_id >= 0:
		PoolWait.task(_task_id)
		_task_id = -1

## Collects a finished index; true once the catalog can answer.
func poll() -> bool:
	if _state == State.LOADING and _task_id >= 0 and WorkerThreadPool.is_task_completed(_task_id):
		PoolWait.task(_task_id)
		_task_id = -1
		var rows: Dictionary = _task_result.get("rows", {})
		var ms := int(_task_result.get("ms", 0))
		for id in rows:
			if not _rows.has(id):
				_rows[id] = rows[id]
		_task_result.clear()
		_state = State.READY
		print("SkillBuffCatalog: %d skill rows indexed in %d ms" % [rows.size(), ms])
	return _state == State.READY

func is_ready() -> bool:
	return _state == State.READY

## Test seam: a catalog that is still loading until finish_loading().
func mark_loading() -> void:
	_state = State.LOADING

func finish_loading() -> void:
	_state = State.READY

## Test and QA seam: a row without an archive.
func set_row(info: Dictionary) -> void:
	_rows[int(info["id"])] = info

## The row for a per-level skill id; {} when the data has none (or the index
## is not ready -- ask is_ready() first).
func info(skill_id: int) -> Dictionary:
	return _rows.get(skill_id, {})

## A ground-cast move's reach, 'tele' value[1], in world units; 0 when the
## row has none or the index does not know the id (yet).
func tele_reach(skill_id: int) -> float:
	var tele: Array = info(skill_id).get("tele", [])
	if tele.size() < 2:
		tele = info(skill_id).get("tel2", [])
	return float(tele[1]) if tele.size() >= 2 else 0.0

## Round 785: whether the row casts at the cursor's point -- it carries
## 'tele' or 'tel2' (READ, FUN_0081ba10's ref +0xc8 / +0xcc test). False
## while the index is not ready.
func casts_at_cursor(skill_id: int) -> bool:
	var row := info(skill_id)
	return not (row.get("tele", []) as Array).is_empty() or not (row.get("tel2", []) as Array).is_empty()

## The skill-name table: the provider's (HudPanels'), else read here.
func names() -> UiTextTable:
	if _names_loaded:
		return _names
	if names_provider.is_valid():
		var t = names_provider.call()
		if t != null:
			_names = t
			_names_loaded = true
			return _names
		return null
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
	if code == "" or code == "xxx":
		return ""
	var t := names()
	if t != null and t.has(code):
		var s := t.get_text(code)
		return s if s != code else ""
	if object_names_provider.is_valid():
		var o = object_names_provider.call()
		if o != null and (o as UiTextTable).has(code):
			var s2 := (o as UiTextTable).get_text(code)
			return s2 if s2 != code else ""
	return ""
