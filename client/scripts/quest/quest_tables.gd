extends RefCounted
class_name QuestTables

## The client's own quest tables (round 785), read from the player's
## Media.pk2 the way the retail client reads them. Nothing here ships data.
##
## - questdata.txt (GlobalDataManager::FUN_0097e470, READ): 0 Service, 1 ID,
##   2 CodeName, 3 the required level (a byte), 4 the Korean name (skipped),
##   5 SN_ title, 6 SN_PAY_, 7 xxx, 8 SN_PAYCON_, 9 SN_NN_ (the NPC line),
##   10 SN_NC_ (the condition line).
## - questcontentsdata.txt (FUN_0097e890, READ): 0 CodeName, 2 the country
##   (0 China, 1 Europe, 3 both -- MEASURED 131 / 158 / 700 rows), 3 the
##   prerequisite codes, 5..12 the eight SN_CON_ ids, 13 the time flag.
## - refqusetreward.txt (RefParse 0x97f2e0; labels READ in UI_QUESTREWARD::
##   FUN_00605250): 0 QuestID, 1 CodeName, 2 IsView, 3 basic block, 4 item
##   block, 10 Gold, 11 EXP, 12 SP EXP, 13 SP, 14 AP (MEASURED against the
##   server script: QNO_CH_SMITH_1's 205 gold / 270 EXP).
## - refquestrewarditems.txt: 0 QuestID, 1 CodeName, 3 the item codename,
##   7 the count (INFERRED).
## - The quest text: textquest.txt lists the three files the
##   TextStringManager loads (READ: TextQuest_OtherString.txt,
##   TextQuest_QuestString.txt, TextQuest_Speech&Name.txt), merged keep-first.

const TEXTDATA := "server_dep\\silkroad\\textdata\\"

class Quest:
	var id := 0
	var code := ""
	var level := 0
	var title := ""
	var pay := ""
	var paycon := ""
	var npc_line := ""
	var condition := ""
	## questcontentsdata's country: 0 China, 1 Europe, 3 both; -1 unknown.
	var country := -1
	var gold := 0
	var exp := 0
	var sp_exp := 0
	var sp := 0
	## Of [code: String, count: int].
	var items: Array = []

## id -> Quest.
var by_id: Dictionary = {}
var by_code: Dictionary = {}
var text: UiTextTable = null

static var _shared: QuestTables = null

## The tables of `archive` (a Pk2Reader), read once per process.
static func shared(archive: Pk2Reader) -> QuestTables:
	if _shared != null:
		return _shared
	_shared = QuestTables.new()
	if archive != null:
		_shared.load_from(func(path: String) -> PackedByteArray:
			var e := ObjectLoader.find_file(archive, path)
			return archive.read_file(e) if e != null else PackedByteArray())
	return _shared

## Sets the shared tables (tests).
static func set_shared(t: QuestTables) -> void:
	_shared = t

static func rows(data: PackedByteArray) -> Array:
	var out: Array = []
	if data.is_empty():
		return out
	var raw := data
	var text_s := ""
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		text_s = TextDecode.utf16(raw.slice(2))
	else:
		text_s = raw.get_string_from_utf8()
	for line in text_s.replace("\r", "").split("\n"):
		if line.strip_edges() == "" or line.begins_with("//"):
			continue
		out.append(line.split("\t"))
	return out

static func _col(cols: PackedStringArray, i: int) -> String:
	if i >= cols.size():
		return ""
	var v := cols[i].strip_edges()
	return "" if v == "xxx" else v

## Reads every table through `read` (archive path -> bytes).
func load_from(read: Callable) -> void:
	for r in rows(read.call(TEXTDATA + "questdata.txt")):
		var cols: PackedStringArray = r
		if cols.size() < 4 or cols[0].strip_edges() != "1":
			continue
		var q := Quest.new()
		q.id = int(cols[1])
		q.code = cols[2].strip_edges()
		q.level = int(cols[3])
		q.title = _col(cols, 5)
		q.pay = _col(cols, 6)
		q.paycon = _col(cols, 8)
		q.npc_line = _col(cols, 9)
		q.condition = _col(cols, 10)
		by_id[q.id] = q
		by_code[q.code] = q
	for r in rows(read.call(TEXTDATA + "questcontentsdata.txt")):
		var cols: PackedStringArray = r
		if cols.size() < 3:
			continue
		var q := by_code.get(cols[0].strip_edges()) as Quest
		if q != null and cols[2].strip_edges().is_valid_int():
			q.country = int(cols[2])
	for r in rows(read.call(TEXTDATA + "refqusetreward.txt")):
		var cols: PackedStringArray = r
		if cols.size() < 13:
			continue
		var q := by_code.get(cols[1].strip_edges()) as Quest
		if q == null:
			continue
		q.gold = int(cols[10])
		q.exp = int(cols[11])
		q.sp_exp = int(cols[12])
		q.sp = int(cols[13]) if cols.size() > 13 else 0
	for r in rows(read.call(TEXTDATA + "refquestrewarditems.txt")):
		var cols: PackedStringArray = r
		if cols.size() < 8:
			continue
		var q := by_code.get(cols[1].strip_edges()) as Quest
		if q != null:
			q.items.append([cols[3].strip_edges(), maxi(1, int(cols[7]))])
	# The text: the files textquest.txt names, keep-first across them.
	var names := PackedStringArray()
	for r in rows(read.call(TEXTDATA + "textquest.txt")):
		var n := (r as PackedStringArray)[0].strip_edges()
		if n != "":
			names.append(n)
	if names.is_empty():
		names = PackedStringArray(["TextQuest_OtherString.txt", "TextQuest_QuestString.txt", "TextQuest_Speech&Name.txt"])
	for n in names:
		var data: PackedByteArray = read.call(TEXTDATA + n.to_lower())
		if data.is_empty():
			data = read.call(TEXTDATA + n)
		if data.is_empty():
			continue
		var t := UiTextTable.parse(data)
		if text == null:
			text = t
		else:
			text.merge_missing(t)
	print("QuestTables: %d quests, text %d rows" % [by_id.size(), text.count() if text != null else 0])

## A text id resolved, or `fallback` when it is not in the quest text.
func resolve(token: String, fallback: String = "") -> String:
	if token == "" or text == null:
		return fallback if fallback != "" else token
	var v := text.get_text(token)
	return v if v != "" and v != token else (fallback if fallback != "" else token)

func quest(id: int) -> Quest:
	return by_id.get(id) as Quest

## A quest's title for a row: its SN_ title resolved, or the code.
func title_of(id: int) -> String:
	var q := quest(id)
	if q == null:
		return "Quest %d" % id
	return resolve(q.title, q.code)

## The SN_ title id of a 0x30D4 list line resolved, and the quest it names
## (the code after "SN_"), or null.
func quest_for_title_id(token: String) -> Quest:
	if token.begins_with("SN_"):
		return by_code.get(token.substr(3)) as Quest
	return null

## The quests the level-up icon counts (FUN_00940210(newLevel, race, out,
## 40), READ): questdata level exactly `level`, not already had (`had`),
## and at or below 40 of the player's country or 3.
func unlocked_at(level: int, country: int, had: Callable) -> Array:
	var out: Array = []
	var ids := by_id.keys()
	ids.sort()
	for id in ids:
		var q := by_id[id] as Quest
		if q.level != level or bool(had.call(int(id))):
			continue
		if level <= 40 and q.country != country and q.country != 3:
			continue
		out.append(q)
	return out

## Strips the sml2 markup of an SN_PAYCON_ text to plain lines (OURS: the
## client draws it with its PML renderer, which this client does not have;
## a <br> is a line break, every other tag is dropped).
static func plain(markup: String) -> String:
	var s := markup.replace("<br>", "\n").replace("<BR>", "\n")
	var re := RegEx.new()
	re.compile("<[^>]*>")
	s = re.sub(s, "", true)
	return s.replace("&nbsp;", " ").strip_edges()
