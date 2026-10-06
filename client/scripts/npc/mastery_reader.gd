extends RefCounted
class_name MasteryReader

## Reads `server_dep\silkroad\textdata\skillmasterydata.txt` from the
## player's own Media.pk2 -- the masteries the skill window is organised by.
## Measured 2026-09-11: China's three weapon masteries are ids 257 (sword
## and blade, `mastery_sword.ddj`), 258 (spear and glaive), 259 (bow), and
## its four force masteries 273-276 (cold, lightning, fire, water). The
## columns, tab separated, 0-indexed:
##
## | # | Field |
## |---|---|
## | 0 | Mastery id |
## | 2 | MasteryNameCode (a `UIIT_` token, resolved through the UI text table) |
## | 3 | GroupNum -- how many skill-group rows the mastery's board has |
## | 5 | Tab Name Code (UIIT_CTL_WEAPON_SKILL, UIIT_CTL_EU_SKILLWND_PHYSICAL, ...) |
## | 6 | Tab: China 0 Weapon, 1 Force; Europe 0 Physical, 1 Magical, 2 Assist |
## | 8, 9, 10 | the weapon TypeID4s this mastery trains (2/3 sword+blade, ...) |
## | 11 | Mastery icon (`icon\skillmastery\china\mastery_sword.ddj`) |
##
## The column map above was derived by measurement on 2026-09-11 and is now
## CONFIRMED by the table itself: skillmasterydata.txt ships a header row
## naming every column -- "Mastery ID", "MasteryNameCode", "Tab Name Code",
## "Type (TabID)", "Weapon Type 1..3", "Mastery Icon" -- and it agrees with all
## six constants below. Rare in these tables, and worth knowing before anyone
## re-derives them.
##
## EUROPE (round 691, READ from the table): 513 Warrior (tab 0, weapons 7 8 9),
## 515 Rogue (tab 0; 11 12), 514 Wizard (tab 1; 11), 516 Warlock (tab 1; 10),
## 517 Bard (tab 2; 14), 518 Cleric (tab 2; 10), icons under
## `icon\skillmastery\europe\`, tab names UIIT_CTL_EU_SKILLWND_PHYSICAL /
## _MASICAL (sic) / _ASSIST. The weapon columns are printed as the table has
## them; they are NOT the skills' cast requirements (a Rogue's crossbow skill
## asks for TypeID4 12, its dagger skills 13), and nothing here reads them for
## a rule.
##
## WHICH MASTERIES A CHARACTER SEES is not a filter on this table. The retail
## window (CIFSkill FUN_006aa3e0, READ) walks the character's own mastery map
## -- the server's list -- and files each mastery under a tab manager keyed by
## the mastery record's +0x5c byte. That byte is this table's TabID: the
## record keeps GroupNum at +0x20 (GlobalDataManager FUN_00945ee0 sizes the
## board's group vector from it) and the two icon strings at +0x64/+0x80 (the
## board loads them), and the 0x1c-byte strings between put column 5 at +0x40
## and column 6 at +0x5c (INFERRED from that layout, not from a loader read).
## The server's list is the race's: _AddNewChar seeds _CharSkillMastery from
## _RefCharDefault_SkillMastery (READ; RACE_MASTERIES below). Within a tab the
## masteries come in the map's order, ascending id.
##
## STALE CLAIM REMOVED 2026-09-15. This used to say the project had neither a
## mastery's trained level nor a skill point total, "so the skill window shows
## the masteries at level 0 and says so". The server tracks both now --
## skill.Store.MasteryLevels and SkillPoints, carried by OpSkillState and
## raised through OpRaiseMastery -- and hud_panels.gd already renders the real
## SP and the mastery total against the race's cap (rounds 483, 691).

const TABLE_PATH := "server_dep\\silkroad\\textdata\\skillmasterydata.txt"

const COL_ID := 0
const COL_NAME_CODE := 2
## Column 5 is the tab's own name code (UIIT_CTL_WEAPON_SKILL /
## UIIT_CTL_FORCE_SKILL) -- what the skill window titles each tab with.
const COL_TAB_CODE := 5
const COL_TAB := 6
const COL_WEAPON_TYPE_1 := 8
const COL_ICON := 11

const TAB_WEAPON := 0
const TAB_FORCE := 1

## The races, as the Country byte (characterdata column 14) numbers them.
const RACE_CHINA := 0
const RACE_EUROPE := 1

## The masteries each race holds, READ from the retail shard's
## _RefCharDefault_SkillMastery (13 rows; Race 0 and Race 1, none for 3), which
## _AddNewChar copies into a new character's _CharSkillMastery at level 0. The
## server's skill.DefaultMasteries holds the same rows.
static var RACE_MASTERIES := {
	RACE_CHINA: [257, 258, 259, 273, 274, 275, 276],
	RACE_EUROPE: [513, 514, 515, 516, 517, 518],
}

## The weapon TypeID4 -> a short name, so a mastery with no resolvable name
## in the archive still labels by what it trains. (Items name their sort from
## the archive since round 731, ItemTypeNames.)
## The Europe codes (7-15) are labelled after itemdata's own families
## (EU_SWORD, EU_TSWORD, EU_AXE, EU_DARKSTAFF, EU_TSTAFF, EU_CROSSBOW, EU_DAGGER,
## EU_HARP, EU_STAFF -- the skilldata-columns note); the English words are OURS.
const WEAPON_LABEL := {
	2: "Sword", 3: "Blade", 4: "Spear", 5: "Glaive", 6: "Bow",
	7: "One-handed Sword", 8: "Two-handed Sword", 9: "Dual Axe", 10: "Dark Staff",
	11: "Two-handed Staff", 12: "Crossbow", 13: "Dagger", 14: "Harp", 15: "Light Staff",
}

class Mastery:
	var id: int
	var name_code: String
	var tab: int
	## The UIIT_ token titling this mastery's tab (Weapon / Force skill).
	var tab_name_code: String
	var icon_path: String
	## The weapon TypeID4s this mastery trains (empty for a force mastery).
	var weapon_types: PackedInt32Array = PackedInt32Array()

	## The name to show: the archive's own (resolved through `names`, then
	## `more_names`) when it has one, else the weapons it trains ("Sword /
	## Blade"), else the id. China's name codes (UIIT_STT_MASTERY_VI ...) live
	## in textuisystem.txt; Europe's (UIIT_STT_WARRIOR ...) only in
	## textdata_equip&skill.txt (MEASURED, round 691), hence the second table.
	func display_name(names: UiTextTable, more_names: UiTextTable = null) -> String:
		for table in [names, more_names]:
			if table != null and name_code != "" and name_code != "xxx":
				var resolved: String = (table as UiTextTable).get_text(name_code)
				if resolved != "" and resolved != name_code:
					return resolved
		var parts := PackedStringArray()
		for t in weapon_types:
			if WEAPON_LABEL.has(t):
				parts.append(WEAPON_LABEL[t])
		if not parts.is_empty():
			return " / ".join(parts) + " Mastery"
		return "Mastery %d" % id

## Parses the table into an ordered Array[Mastery] -- China's weapon
## masteries first, then its force masteries, the order the skill window's
## tabs use. Kept for its callers; parse_race(data, RACE_CHINA) is the same.
static func parse_china(data: PackedByteArray) -> Array:
	return parse_race(data, RACE_CHINA)

## The masteries a character of `race` holds (RACE_MASTERIES), ordered as the
## retail window files them: by tab (TabID ascending), then by id within a tab
## (the server's mastery map is keyed by id). A partial archive yields what it
## has.
static func parse_race(data: PackedByteArray, race: int) -> Array:
	return for_race(parse_all(data), race)

## Every mastery of the table a race holds (either race's), unordered beyond
## file order.
static func parse_all(data: PackedByteArray) -> Array:
	var held: Dictionary = {}
	for r in RACE_MASTERIES:
		for id in RACE_MASTERIES[r]:
			held[int(id)] = true
	var out: Array = []
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_ICON:
			continue
		var id_text := cols[COL_ID].strip_edges()
		if not id_text.is_valid_int() or not held.has(int(id_text)):
			continue
		var m := Mastery.new()
		m.id = int(id_text)
		m.name_code = cols[COL_NAME_CODE].strip_edges()
		m.tab = _int_at(cols, COL_TAB)
		if COL_TAB_CODE < cols.size():
			m.tab_name_code = cols[COL_TAB_CODE].strip_edges()
		# Column 11 already carries the full `icon\...` archive path, unlike
		# the item table's bare filenames -- so it is used as-is.
		m.icon_path = cols[COL_ICON].strip_edges().replace("/", "\\")
		for c in range(COL_WEAPON_TYPE_1, COL_WEAPON_TYPE_1 + 3):
			var t := _int_at(cols, c)
			if t > 0:
				m.weapon_types.append(t)
		out.append(m)
	return out

## `masteries` narrowed to those `race` holds, ordered by (tab, id).
static func for_race(masteries: Array, race: int) -> Array:
	var ids: Array = RACE_MASTERIES.get(race, [])
	var out: Array = []
	for entry in masteries:
		if ids.has((entry as Mastery).id):
			out.append(entry)
	out.sort_custom(func(a, b):
		var ma: Mastery = a
		var mb: Mastery = b
		return ma.id < mb.id if ma.tab == mb.tab else ma.tab < mb.tab)
	return out

## The race whose masteries `ids` names (the server's held list), or -1 when
## it names none of either race's.
static func race_of_masteries(ids: Array) -> int:
	for r in RACE_MASTERIES:
		for id in ids:
			if (RACE_MASTERIES[r] as Array).has(int(id)):
				return int(r)
	return -1

static func _int_at(cols: PackedStringArray, col: int) -> int:
	if col >= cols.size():
		return 0
	var text := cols[col].strip_edges()
	return int(text) if text.is_valid_int() else 0

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
