extends RefCounted
class_name CharacterVisualChange

## Which of a character's attached visuals the client draws (round 789, lane
## AC): the player's own Media.pk2 `textdata\charactervisualchange.txt` and
## the client's arbitration over it. Every step is READ from sro_client.exe
## in /root/opensro-pk3av789/AVATAR_RESEARCH.md section 6 unless labelled.
##
## **The table** (6.1; parse READ CharacterVisualChangeManager::FUN_004ed530,
## FUN_004ea570): Service, ID, Name, ConditionID, AttachType, Pram1..4,
## StrPram1..4, Slot, OverlapSlot, OverlapSlotGroup, Priority, MaterialID,
## AnimationName, BsrName(M), BsrName(F). A row's ConditionID picks its class
## (c:0x4e9e50): 1 an equipped item by its TypeID word, 2 an avatar by TypeID
## word AND the item's Param7, 3 a skill or state by code name, 4 a second
## mesh by item code name (wing dresses), 5 fortress suits, 6 the default
## wear, 7 timed transforms.
##
## **The key of an item** (c:0x4ec260): an avatar (TypeID 3/1/13, the 0x680
## test) is keyed {2, the ref's full TypeID word (+0x80, cash bit included),
## ref +0x544}; anything else {1, TypeID word}. FUN_004ec170 returns the
## first row whose condition matches. ref +0x544 is Param7 (itemdata column
## 130): INFERRED -- the client parser's offset was not located -- but
## MEASURED: 1,346 of 1,354 avatar rows hit one of the 14 ConditionID-2 rows
## by (full word, Param7). **An avatar with no matching row is not drawn at
## all** (AttachAvatarVisual attaches nothing). A devil's spirit (3/1/14) takes
## the type-1 key and no ConditionID-1 row has its word (MEASURED), so it
## draws nothing.
##
## **The arbitration** (6.2, CObjCharacter::FUN_00a611e0, FUN_00a5da10,
## FUN_004e8750, FUN_004e8f90, FUN_00a5fe00, FUN_00a5d080): the attached
## visuals walked in ascending Priority (ties in attach order, the multimap's
## insert, READ FUN_005b21d0); a visual is drawn unless its Slot collides
## with what is drawn already -- see arbitrate(). Lower Priority wins: avatars
## (70/90/110) hide armour (250) wherever their Slot mask covers it, a flag
## (110) is hidden while an attachment (90) is worn, a skill row (group 2)
## hides group-1 avatars.
##
## **Default wear** (FUN_00a5e010, DefaultWear): decided from the DRAWN
## visuals' Slot masks -- a dress covering mail (0x002) and pants (0x010)
## leaves no default clothes under it.
##
## OURS / OPEN, each said where it is done: an equipped item with no
## ConditionID-1 row (none MEASURED among the armour the table names, but a
## cash or bionic word has none) is kept as a visual that covers nothing, as
## this client drew it before -- whether retail draws it is OPEN; the
## ConditionID 3/5/7 rows are not attached (their triggers are OPEN, 6.2's
## OPEN list); the animation group (6.5) is not applied.

const PATH := "server_dep\\silkroad\\textdata\\charactervisualchange.txt"

const COL_SERVICE := 0
const COL_ID := 1
const COL_CONDITION := 3
const COL_ATTACH_TYPE := 4
const COL_PRAM1 := 5
const COL_PRAM2 := 6
const COL_STR_PRAM1 := 9
const COL_SLOT := 13
const COL_OVERLAP := 14
const COL_GROUP := 15
const COL_PRIORITY := 16
const COL_MATERIAL := 17
const COL_ANIMATION := 18
const COL_BSR_MAN := 19
const COL_BSR_WOMAN := 20

const CONDITION_ITEM := 1
const CONDITION_AVATAR := 2
const CONDITION_SKILL := 3
const CONDITION_ADD_ATTACH := 4
const CONDITION_DEFAULT := 6

## The Slot mask's bits (6.1, MEASURED: the rows' names and Param7's Desc).
const MASK_HELM := 0x0001
const MASK_MAIL := 0x0002
const MASK_SHOULDER := 0x0004
const MASK_HANDS := 0x0008
const MASK_PANTS := 0x0010
const MASK_BOOTS := 0x0020
const MASK_WEAPON := 0x0040
const MASK_SHIELD := 0x0080
const MASK_HAIR := 0x0800

## OURS: the Priority an equipped item with no ConditionID-1 row is walked
## at -- the armour rows' own (MEASURED 250) -- with a Slot of 0, so it
## collides with nothing and hides nothing.
const UNLISTED_PRIORITY := 250

class Row:
	var id: int = 0
	var condition: int = 0
	var attach_type: int = 0
	var pram1: int = 0
	var pram2: int = 0
	var str_pram1: String = ""
	var slot: int = 0
	var overlap: int = 0
	var group: int = 0
	var priority: int = 0
	var animation: String = ""
	var bsr_man: String = ""
	var bsr_woman: String = ""

	func describe() -> String:
		return "row %d cond %d pram1 %d pram2 0x%x slot 0x%04x ov 0x%04x group %d prio %d" % [
			id, condition, pram1, pram2, slot, overlap, group, priority]

## Every Service-1 row in file order.
var rows: Array[Row] = []
var _items := {}        # TypeID word -> first ConditionID-1 row
var _avatars := {}      # "word|param7" -> first ConditionID-2 row
var _add_attach := {}   # item code name (upper case) -> first ConditionID-4 row

static func from_archive(media: Pk2Reader) -> CharacterVisualChange:
	var v := CharacterVisualChange.new()
	if media == null:
		return v
	var entry := ObjectLoader.find_file(media, PATH)
	if entry != null:
		v.parse_into(media.read_file(entry))
	return v

static func from_text(text: String) -> CharacterVisualChange:
	var v := CharacterVisualChange.new()
	v.parse_into(text)
	return v

func is_empty() -> bool:
	return rows.is_empty()

func parse_into(data) -> void:
	var text := ""
	if data is String:
		text = data
	else:
		var raw: PackedByteArray = data
		if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
			text = TextDecode.utf16(raw.slice(2))
		elif raw.size() >= 3 and raw[0] == 0xEF and raw[1] == 0xBB and raw[2] == 0xBF:
			text = raw.slice(3).get_string_from_utf8()
		else:
			text = raw.get_string_from_utf8()
	for line in text.split("\n"):
		line = line.strip_edges(false, true)
		if line == "" or line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_BSR_WOMAN or _num(cols[COL_SERVICE]) != 1:
			continue
		var r := Row.new()
		r.id = _num(cols[COL_ID])
		r.condition = _num(cols[COL_CONDITION])
		r.attach_type = _num(cols[COL_ATTACH_TYPE])
		r.pram1 = _num(cols[COL_PRAM1])
		r.pram2 = _num(cols[COL_PRAM2])
		r.str_pram1 = _str(cols[COL_STR_PRAM1])
		r.slot = _num(cols[COL_SLOT])
		r.overlap = _num(cols[COL_OVERLAP])
		r.group = _num(cols[COL_GROUP])
		r.priority = _num(cols[COL_PRIORITY])
		r.animation = _str(cols[COL_ANIMATION])
		r.bsr_man = _str(cols[COL_BSR_MAN])
		r.bsr_woman = _str(cols[COL_BSR_WOMAN])
		rows.append(r)
		match r.condition:
			CONDITION_ITEM:
				if not _items.has(r.pram1):
					_items[r.pram1] = r
			CONDITION_AVATAR:
				var key := "%d|%d" % [r.pram1, r.pram2]
				if not _avatars.has(key):
					_avatars[key] = r
			CONDITION_ADD_ATTACH:
				var code := r.str_pram1.to_upper()
				if code != "" and not _add_attach.has(code):
					_add_attach[code] = r

static func _num(t: String) -> int:
	t = t.strip_edges()
	if t.begins_with("0x") or t.begins_with("0X"):
		return t.substr(2).hex_to_int()
	return int(t) if t.is_valid_int() else 0

static func _str(t: String) -> String:
	t = t.strip_edges()
	return "" if t == "" or t.to_lower() == "xxx" else t

## The TypeID word (READ s:0x48f610, c:0x6abcd0): CashItem | Bionic << 1 |
## TypeID1 << 2 | TypeID2 << 5 | TypeID3 << 7 | TypeID4 << 11.
static func type_word(type_ids: PackedInt32Array, cash: int = 0, bionic: int = 0) -> int:
	if type_ids.size() < 4:
		return 0
	return (cash & 1) | ((bionic & 1) << 1) | (type_ids[0] << 2) | (type_ids[1] << 5) | (type_ids[2] << 7) | (type_ids[3] << 11)

## Whether a TypeID word is an avatar's (the 0x680 test on TypeID 3/1/13,
## not bionic: c:0x4ec260's own predicate is `!(w&2) && 3/1 && TypeID3 13`).
static func is_avatar_word(word: int) -> bool:
	return (word & 2) == 0 and ((word >> 2) & 7) == 3 and ((word >> 5) & 3) == 1 and ((word >> 7) & 0xf) == 13

## The row an item is drawn by (FUN_004ec260 -> FUN_004ec170): an avatar's
## ConditionID-2 row by (word, Param7), anything else's ConditionID-1 row by
## its word; null when none matches.
func row_for(word: int, param7: int) -> Row:
	if is_avatar_word(word):
		return _avatars.get("%d|%d" % [word, param7], null)
	return _items.get(word, null)

## The ConditionID-4 row of an item code name (FUN_004ec300, key +0x90): a
## wing dress's second mesh, or null.
func add_attach_row(code: String) -> Row:
	return _add_attach.get(code.to_upper(), null)

## The second mesh an AddAttach row names (READ c:0xa5f4f0: the first
## non-empty of BsrName(M), BsrName(F)), or "".
static func add_attach_path(r: Row) -> String:
	if r == null:
		return ""
	return r.bsr_man if r.bsr_man != "" else r.bsr_woman

## The arbitration (READ c:0xa611e0 and its callees, AVATAR_RESEARCH.md 6.2)
## over `visuals`, each a Dictionary with "priority", "slot", "overlap",
## "group" (ints), in attach order. Returns {"drawn": [index], "hidden":
## [index], "occupied": the +0x174 mask} -- drawn in the walk's order.
##
##   occ = 0; lastPrio = 0; groupOverlap = {}
##   for v in attached, ascending Priority (ties in attach order):
##       S = occ | OR(groupOverlap[g] for g != v.group)          # FUN_00a5da10
##       conflict = (S & v.Slot) and (v.group == 0 or
##                  (S & ~v.OverlapSlot & v.Slot) or v.group not in groupOverlap)   # FUN_004e8750
##       if conflict and lastPrio <= v.Priority: hidden          # FUN_004e8f90
##       else: drawn; occ |= v.Slot & ~v.OverlapSlot; lastPrio = v.Priority;
##             groupOverlap.setdefault(v.group, v.OverlapSlot)   # FUN_00a5fe00
static func arbitrate(visuals: Array) -> Dictionary:
	var order: Array = []
	for i in visuals.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var pa := int(visuals[a]["priority"])
		var pb := int(visuals[b]["priority"])
		return pa < pb or (pa == pb and a < b))
	var occ := 0
	var last_prio := 0
	var group_overlap := {}
	var drawn: Array = []
	var hidden: Array = []
	for i in order:
		var v: Dictionary = visuals[i]
		var slot := int(v["slot"])
		var ov := int(v["overlap"])
		var group := int(v["group"])
		var prio := int(v["priority"])
		var s := occ
		for g in group_overlap:
			if int(g) != group:
				s |= int(group_overlap[g])
		var conflict := (s & slot) != 0 and (group == 0 or (s & ~ov & slot) != 0 or not group_overlap.has(group))
		if conflict and last_prio <= prio:
			hidden.append(i)
			continue
		drawn.append(i)
		occ |= slot & ~ov
		last_prio = prio
		if not group_overlap.has(group):
			group_overlap[group] = ov
	return {"drawn": drawn, "hidden": hidden, "occupied": occ}

## The visual an item is walked as: {"priority", "slot", "overlap", "group",
## "row": Row or null, "drawn_by_row": bool}. An avatar with no row is not
## attached at all (READ): null. An equipped item with no row is a visual
## that covers nothing (OURS, see the header).
func visual_for(word: int, param7: int) -> Dictionary:
	var r := row_for(word, param7)
	if r == null:
		if is_avatar_word(word):
			return {}
		return {"priority": UNLISTED_PRIORITY, "slot": 0, "overlap": 0, "group": 0, "row": null}
	return {"priority": r.priority, "slot": r.slot, "overlap": r.overlap, "group": r.group, "row": r}
