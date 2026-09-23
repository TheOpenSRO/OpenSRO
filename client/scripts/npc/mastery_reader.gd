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
## | 6 | Tab: 0 Weapon, 1 Force |
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
## STALE CLAIM REMOVED 2026-09-15. This used to say the project had neither a
## mastery's trained level nor a skill point total, "so the skill window shows
## the masteries at level 0 and says so". The server tracks both now --
## skill.Store.MasteryLevels and SkillPoints, carried by OpSkillState and
## raised through OpRaiseMastery -- and hud_panels.gd already renders the real
## SP and the mastery total against the flat 330 cap (round 483).

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

## The weapon TypeID4 -> a short name, so a mastery with no resolvable name
## in the archive still labels by what it trains. Same numbers as
## ItemTableReader.WEAPON_SORT; kept here so this reader stands alone.
const WEAPON_LABEL := {
	2: "Sword", 3: "Blade", 4: "Spear", 5: "Glaive", 6: "Bow",
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

	## The name to show: the archive's own (resolved through `names`) when it
	## has one, else the weapons it trains ("Sword / Blade"), else the id.
	func display_name(names: UiTextTable) -> String:
		if names != null and name_code != "" and name_code != "xxx":
			var resolved := names.get_text(name_code)
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
## tabs use. Only masteries with a real icon under `china\` are kept, so a
## partial or Europe-only archive still yields what it has.
static func parse_china(data: PackedByteArray) -> Array:
	var weapon: Array = []
	var force: Array = []
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_ICON:
			continue
		var id_text := cols[COL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var icon := cols[COL_ICON].strip_edges()
		if not icon.to_lower().contains("skillmastery\\china\\") and not icon.to_lower().contains("skillmastery/china/"):
			continue
		var m := Mastery.new()
		m.id = int(id_text)
		m.name_code = cols[COL_NAME_CODE].strip_edges()
		m.tab = _int_at(cols, COL_TAB)
		if COL_TAB_CODE < cols.size():
			m.tab_name_code = cols[COL_TAB_CODE].strip_edges()
		# Column 11 already carries the full `icon\...` archive path, unlike
		# the item table's bare filenames -- so it is used as-is.
		m.icon_path = icon.replace("/", "\\")
		for c in range(COL_WEAPON_TYPE_1, COL_WEAPON_TYPE_1 + 3):
			var t := _int_at(cols, c)
			if t > 0:
				m.weapon_types.append(t)
		if m.tab == TAB_WEAPON:
			weapon.append(m)
		elif m.tab == TAB_FORCE:
			force.append(m)
	return weapon + force

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
