extends RefCounted
class_name CharCreateModel

## The customize screen's state and rules, without a screen (round 685): what
## each control holds, the range each slider runs, what a change does to the
## others, which tooltip it shows, what Confirm refuses, and the create
## request the choices make. CharacterCreate.gd draws it; the tests drive it
## with a synthetic CharCatalog.
##
## Everything here is READ from sro_client.exe unless it says otherwise
## (docs/protocol/charselect.md section 4 and WORLD_ISSUES round 685 have the
## addresses). Labels: READ, MEASURED, INFERRED, OURS, OPEN.
##
## **The state** (`CCustomInfoManager` at this+0x11c): the sex (+0x124, 1 man,
## 0 woman), and per slot 0..5 (model, chest, legs, feet, weapon, shield) the
## chosen id (+0x128..) and the 1-based list index (+0x140..); the scale byte
## (+0x218). A slider's value IS the list index: 0x80b440 (slot, index) takes
## list entry index-1, and index 0 is "none" (id 0).
##
## **The sliders** (the CIFSliderCtrl ids 45..49, `CPSCharacterCreateChina`
## OnCreate 0x84fbc0 and the sex setter 0x84f350; Europe 0x853990 / 0x853400):
## - Figure 1..n (n = the sex's body list), starting at its minimum 1;
## - Height and Volume 0..4 (FUN_006599e0(0, 4, 1, 1)), starting at 2
##   (FUN_006598a0(2, 1), 0x8503cb..0x8503db);
## - China Protector `min..n`, min 1 unless the per-server flag CGame+0x129 is
##   set (then 0, "none"); the user's default keeps "none" out (OURS, a user
##   decision default, charselect.md section 8 item 9), so min 1;
## - China Weapon 0..5, starting at 0;
## - Europe Weapon 0..9, starting at 0. A weapon change sets the Protector's
##   range by the weapon's TypeID4 -- 0..2 for 7, 8, 9, 15; 0..1 for 10..14;
##   0..0 with no weapon -- and puts the Protector back to 0 (0x853400), and
##   the Protector slider is drawn at alpha 100 with no weapon, 255 otherwise
##   (0x8531e0). Protector value p then selects the p-th set the weapon allows
##   (CharCatalog.armour_sets, READ 0x8531e0).
## - A slider's position is clamped into a new range (0x6599e0).
##
## **The order** of the five sliders on the panel is the layout's (their rect
## y in the `Custom` section, MEASURED): China Figure, Height, Volume,
## Protector, Weapon; Europe Figure, Height, Volume, Weapon, Protector.

const RACE_CHINA := CharCatalog.RACE_CHINA
const RACE_EUROPE := CharCatalog.RACE_EUROPE
const SEX_WOMAN := CharCatalog.SEX_WOMAN
const SEX_MAN := CharCatalog.SEX_MAN

## The five sliders, numbered as the screen's own "which control" field
## (+0x350, READ: the China handlers store 0 Figure, 1 Height, 2 Volume,
## 3 Protector, 4 Weapon before calling the tooltip 0x84d470).
enum Ctl { FIGURE, HEIGHT, VOLUME, PROTECTOR, WEAPON }

## The layout ids (READ, pscharactercreatechina.txt / _europe.txt; the same
## ids in both).
const ID_BAND_UP := 1
const ID_BAND_DOWN := 2
const ID_TITLE := 3
const ID_BACKIMAGE := 5
const ID_CHARWND := 6
const ID_CUSTOM := 7
const ID_ROTATE := 8
const ID_EXPLAIN := 9
const ID_OK := 10
const ID_CANCEL := 11
const ID_DIM := 12
const ID_BOX := 13
const ID_FADE := 14
const ID_ROTATE_LEFT := 21
const ID_ROTATE_RIGHT := 22
const ID_ZOOM := 23
const ID_BOX_NAME := 31
const ID_BOX_CREATE := 32
const ID_BOX_CANCEL := 33
const ID_NAME := 41
const ID_CHECK := 42
const ID_MALE := 43
const ID_FEMALE := 44
const ID_FIGURE := 45
const ID_HEIGHT := 46
const ID_VOLUME := 47
const ID_PROTECTOR := 48
const ID_WEAPON := 49
const ID_TIP_TITLE := 61
const ID_TIP_TEXT := 62
const ID_SLIDER_PREV := 71
const ID_SLIDER_NEXT := 72
const ID_SLIDER_THUMB := 73
const ID_MESSAGE := 500

const SLIDER_IDS := {
	Ctl.FIGURE: ID_FIGURE, Ctl.HEIGHT: ID_HEIGHT, Ctl.VOLUME: ID_VOLUME,
	Ctl.PROTECTOR: ID_PROTECTOR, Ctl.WEAPON: ID_WEAPON,
}

const LAYOUT_CHINA := "resinfo\\pscharactercreatechina.txt"
const LAYOUT_EUROPE := "resinfo\\pscharactercreate_europe.txt"
## The layout's main section per race (READ, the files' first section).
const SECTION_MAIN := {RACE_CHINA: "CreateChina", RACE_EUROPE: "CreateEurope"}

## READ: the order of the sliders down the panel, from the layouts' rects
## (y 131, 162, 193, 224, 255): China puts Protector before Weapon, Europe the
## reverse. slider_order_from_layout() measures it from the file; this is what
## the vSRO archive's two files say.
const SLIDER_ORDER := {
	RACE_CHINA: [Ctl.FIGURE, Ctl.HEIGHT, Ctl.VOLUME, Ctl.PROTECTOR, Ctl.WEAPON],
	RACE_EUROPE: [Ctl.FIGURE, Ctl.HEIGHT, Ctl.VOLUME, Ctl.WEAPON, Ctl.PROTECTOR],
}

## READ: Height and Volume run 0..4 and start at 2.
const HV_MIN := 0
const HV_MAX := 4
const HV_START := 2

## READ (0x8531e0): the Europe Protector slider's alpha with no weapon, and
## otherwise.
const PROTECTOR_ALPHA_DIMMED := 100
const PROTECTOR_ALPHA := 255

## The name rules (READ 0x84eac0: the edit's length minus 2 below 11, so
## 2..12 characters, else UIO_MSG_ERROR_CHARACTER_NAME_STRING; then the
## character test 0x8c3cb0, else UIO_MSG_ERROR_CHARACTER_WRONGSTRING).
const NAME_MIN := 2
const NAME_MAX := 12
const MSG_NAME_LENGTH := "UIO_MSG_ERROR_CHARACTER_NAME_STRING"
const MSG_NAME_CHARS := "UIO_MSG_ERROR_CHARACTER_WRONGSTRING"
const MSG_NO_WEAPON := "UIO_MSG_ERROR_CHARACTER_SELECTWEAPON"
const MSG_NO_ARMOUR := "UIO_MSG_ERROR_CHARACTER_SELECTARMOR"
## READ: what a name check's OK shows (0x84df10).
const MSG_NAME_OK := "UIO_MSG_ERROR_ADMISSON"

## The tooltip keys (READ: the strings 0x84d470 / 0x850f50 pass to the text
## table, by the list index of the control's current choice). The Figure keys
## are "UIO_NEWCHAR_<prefix>_<name>" and "..._EXPLANATION".
const FIGURE_TIP_PREFIX := {
	RACE_CHINA: {SEX_MAN: "UIO_NEWCHAR_MAN_", SEX_WOMAN: "UIO_NEWCHAR_FEMALE_"},
	RACE_EUROPE: {SEX_MAN: "UIO_NEWCHAR_EU_MAN_", SEX_WOMAN: "UIO_NEWCHAR_EU_FEMALE_"},
}
const FIGURE_TIP_NAMES := {
	RACE_CHINA: {
		SEX_MAN: ["ADVENTURER", "BOGY", "FIGHTER", "MERCHANT", "MONK", "MONKEY", "NECROMANCER",
			"NOBLEBOY", "PERFORMER", "PRIEST", "SCHOLAR", "TATTOO", "WARRIOR"],
		SEX_WOMAN: ["ADVENTURER", "ASSASSIN", "BOGY", "FIGHTER", "FOX", "KANGSI", "KISAENG",
			"MERCHANT", "NECROMANCERB", "NECROMANCERW", "NOBLEGIRL", "SCHOLAR", "WARRIOR"],
	},
	RACE_EUROPE: {
		SEX_MAN: ["NOBLE", "EXORCIST", "NECROMANCER", "MERCHANT", "PRIEST", "KNIGHT", "WARRIOR",
			"GLADIATOR", "BARBARIAN", "ADVENTURER", "ANGEL", "DEVIL", "WEREWOLF"],
		SEX_WOMAN: ["NOBLE", "WITCH", "SUMMONER", "MERCHANT", "ORACLE", "CRUSADER", "AMAZONESS",
			"KNIGHT", "ADVENTURER", "GLADIATOR", "ANGEL", "SUCCUBUS", "DEVIL"],
	},
}
## Weapon index 1..n -> "UIO_NEWCHAR_STT_<x>" / "UIO_NEWCHAR_EXPLANATION_<y>".
const WEAPON_TIPS := {
	RACE_CHINA: [["SWORD", "SWORD"], ["BLADE", "BLADE"], ["SPEAR", "SPEAR"], ["TBLADE", "TBLADE"], ["BOW", "BOW"]],
	RACE_EUROPE: [["EU_DAGGER", "DAGGER"], ["EU_ONEHANDSWORD", "ONEHANDSWORD"], ["EU_TWOHANDSWORD", "TWOHANDSWORD"],
		["EU_DUELAXE", "DUELAXE"], ["EU_CROSSBOW", "CROSSBOW"], ["EU_DARKSTAFF", "DARKSTAFF"],
		["EU_TWOHANDSTAFF", "TWOHANDSTAFF"], ["EU_HARP", "HARP"], ["EU_ONEHANDSTAFF", "ONEHANDSTAFF"]],
}
## Armour list position 1..3 -> the same pair.
const ARMOUR_TIPS := {
	RACE_CHINA: [["HEAVY_ARMOR", "HEAVY_ARMOR"], ["LIGHT_ARMOR", "LIGHT_ARMOR"], ["CLOTHES", "CLOTHES"]],
	RACE_EUROPE: [["EU_HEAVY_ARMOR", "EU_HEAVY_ARMOR"], ["EU_LIGHT_ARMOR", "EU_LIGHT_ARMOR"], ["EU_ROBE", "EU_ROBE"]],
}

var catalog: CharCatalog
var race: int = RACE_CHINA
var sex: int = SEX_MAN
## Slider values (list indices; 0 is "none" where the range allows it).
var figure: int = 1
var height: int = HV_START
var volume: int = HV_START
var weapon: int = 0
var protector: int = 0
## Whether China's Protector starts at 1 (no "none"). OURS default true, see
## the header.
var protector_required: bool = true

## The model with the READ starting values: man, Figure 1, Height and Volume
## 2, Weapon 0, Protector at its minimum.
static func create(cat: CharCatalog, for_race: int, require_protector: bool = true) -> CharCreateModel:
	var m := CharCreateModel.new()
	m.catalog = cat
	m.race = RACE_EUROPE if for_race == RACE_EUROPE else RACE_CHINA
	m.protector_required = require_protector
	m.sex = SEX_MAN
	m.figure = 1
	m.height = HV_START
	m.volume = HV_START
	m.weapon = 0
	m.protector = 0
	m._clamp_all()
	return m

# --- ranges -------------------------------------------------------------------

func figures() -> Array[CharCatalog.Entry]:
	if catalog == null:
		var none: Array[CharCatalog.Entry] = []
		return none
	return catalog.figures(race, sex)

func weapons() -> Array[CharCatalog.Entry]:
	if catalog == null:
		var none: Array[CharCatalog.Entry] = []
		return none
	return catalog.weapons(race, sex)

## The sets the Protector slider walks: China every set of the sex (READ: no
## restriction); Europe the sets the weapon allows (CharCatalog's READ table).
func armour_sets() -> Array[CharCatalog.ArmourSet]:
	if catalog == null:
		var none: Array[CharCatalog.ArmourSet] = []
		return none
	return catalog.armour_sets(race, sex, weapon_id())

## The slider's [min, max] (READ, header).
func slider_range(c: int) -> Vector2i:
	match c:
		Ctl.FIGURE:
			var n := figures().size()
			return Vector2i(1, maxi(n, 1))
		Ctl.HEIGHT, Ctl.VOLUME:
			return Vector2i(HV_MIN, HV_MAX)
		Ctl.WEAPON:
			return Vector2i(0, weapons().size())
		Ctl.PROTECTOR:
			var n := armour_sets().size()
			if race == RACE_EUROPE:
				return Vector2i(0, n)
			var lo := 1 if protector_required else 0
			return Vector2i(mini(lo, n), n)
	return Vector2i.ZERO

func value(c: int) -> int:
	match c:
		Ctl.FIGURE: return figure
		Ctl.HEIGHT: return height
		Ctl.VOLUME: return volume
		Ctl.WEAPON: return weapon
		Ctl.PROTECTOR: return protector
	return 0

## Sets a slider (clamped into its range) and applies what the client's
## handler does after it. Returns true when anything changed.
func set_value(c: int, v: int) -> bool:
	var r := slider_range(c)
	v = clampi(v, r.x, r.y)
	if v == value(c):
		return false
	match c:
		Ctl.FIGURE: figure = v
		Ctl.HEIGHT: height = v
		Ctl.VOLUME: volume = v
		Ctl.PROTECTOR: protector = v
		Ctl.WEAPON:
			weapon = v
			if race == RACE_EUROPE:
				# READ 0x853400: the Protector's range follows the weapon and
				# its position goes back to 0 (FUN_006598a0(0, 1)).
				protector = 0
			else:
				_clamp(Ctl.PROTECTOR)
	return true

## Sex: the lists change, the indices stay where they are (READ 0x84f350:
## the ranges are re-set and each position clamped into its own).
func set_sex(s: int) -> bool:
	s = SEX_WOMAN if s == SEX_WOMAN else SEX_MAN
	if s == sex:
		return false
	sex = s
	_clamp_all()
	return true

func _clamp(c: int) -> void:
	var r := slider_range(c)
	match c:
		Ctl.FIGURE: figure = clampi(figure, r.x, r.y)
		Ctl.HEIGHT: height = clampi(height, r.x, r.y)
		Ctl.VOLUME: volume = clampi(volume, r.x, r.y)
		Ctl.WEAPON: weapon = clampi(weapon, r.x, r.y)
		Ctl.PROTECTOR: protector = clampi(protector, r.x, r.y)

func _clamp_all() -> void:
	for c in [Ctl.FIGURE, Ctl.HEIGHT, Ctl.VOLUME, Ctl.WEAPON, Ctl.PROTECTOR]:
		_clamp(c)

## The Protector slider's alpha (READ 0x8531e0): Europe dims it with no
## weapon; China never does.
func protector_alpha() -> int:
	if race == RACE_EUROPE and weapon == 0:
		return PROTECTOR_ALPHA_DIMMED
	return PROTECTOR_ALPHA

# --- the choices as ids -------------------------------------------------------

func figure_entry() -> CharCatalog.Entry:
	var f := figures()
	return f[figure - 1] if figure >= 1 and figure <= f.size() else null

func model_id() -> int:
	var e := figure_entry()
	return e.id if e != null else 0

func weapon_entry() -> CharCatalog.Entry:
	var w := weapons()
	return w[weapon - 1] if weapon >= 1 and weapon <= w.size() else null

func weapon_id() -> int:
	var e := weapon_entry()
	return e.id if e != null else 0

func armour_set() -> CharCatalog.ArmourSet:
	var s := armour_sets()
	return s[protector - 1] if protector >= 1 and protector <= s.size() else null

## [chest, legs, feet], zeros for none.
func armour_ids() -> Array[int]:
	var s := armour_set()
	if s == null:
		var none: Array[int] = [0, 0, 0]
		return none
	return s.ids()

## The scale byte: Volume in the high nibble, Height in the low (READ:
## Height writes the low nibble, 0x84d040; Volume the high, 0x84d070).
static func scale_of(h: int, v: int) -> int:
	return ((v & 0x0f) << 4) | (h & 0x0f)

func scale_byte() -> int:
	return scale_of(height, volume)

## What 0x7007 action 1 carries (READ writer 0x84e2e0: the name, u32 model,
## u8 scale, u32 chest, legs, feet, weapon -- from +0x128, +0x218, +0x12c,
## +0x130, +0x134, +0x138).
func request() -> Dictionary:
	var a := armour_ids()
	return {"model": model_id(), "scale": scale_byte(), "chest": a[0], "legs": a[1], "feet": a[2], "weapon": weapon_id()}

## What the preview wears: the armour, the weapon, and the race's shield
## beside a weapon whose refitem +0x250 is 0 (READ 0x80b440 case 4, which
## installs the shield into slot 7 then; INFERRED +0x250 is the TwoHanded
## column 93, which CharCatalog reads -- MEASURED 0 on the one-handed
## weapons and 1 on the rest, bows and crossbows included).
func preview_items() -> Array:
	var out: Array = []
	for id in armour_ids():
		if id != 0:
			out.append({"id": id, "plus": 0})
	var w := weapon_entry()
	if w != null:
		out.append({"id": w.id, "plus": 0})
		if not w.two_handed and catalog != null:
			var sh := catalog.shield(race)
			if sh != null:
				out.append({"id": sh.id, "plus": 0})
	return out

func is_woman() -> bool:
	return sex == SEX_WOMAN

# --- Confirm and the name -----------------------------------------------------

## What Confirm refuses before the name, as a text key, or "" (READ: China
## 0x84ed50 tests the weapon only; Europe 0x8527e0 tests the chest first, then
## the weapon; both play snd_error).
func confirm_error() -> String:
	var a := armour_ids()
	if race == RACE_EUROPE and a[0] == 0:
		return MSG_NO_ARMOUR
	if weapon_id() == 0:
		return MSG_NO_WEAPON
	return ""

## The name's refusal as a text key, or "" (READ 0x84eac0: the length first,
## 2..12 characters, then the character test).
##
## The character test: READ, 0x8c3cb0 lower-cases A-Z (0x8c1660) and refuses
## a name with any character whose bit is set in a 65,536-bit table
## (0x8c0760), then two word lists. The table is built by 0x8c4a10 from
## Media.pk2 `server_dep\silkroad\textdata\abusefilter.txt`: its
## `#ALLOW_ID_TABLE <from> <to>` rows mark the allowed ranges of one of six
## language columns, and the rest of the table is the refused set. Which
## column the English client reads (the filter object's +0x14, passed to its
## constructor 0x8c46a0 from GlobalDataManager +0x858) is OPEN. So the test
## here is OURS: the server's own rule (session.LobbyNameCode -- printable
## ASCII, no space, `'` or `"`), so the client never passes a name the
## server refuses for its characters, nor refuses one it would take.
static func name_error(name: String) -> String:
	var n := name.length()
	if n < NAME_MIN or n > NAME_MAX:
		return MSG_NAME_LENGTH
	for i in range(n):
		var c := name.unicode_at(i)
		if c < 0x21 or c > 0x7e or c == 0x27 or c == 0x22:
			return MSG_NAME_CHARS
	return ""

# --- the tooltip --------------------------------------------------------------

## [title key, text key] for a control at its current value (READ 0x84d470,
## 0x850f50); [] when the client shows nothing new.
func tooltip_keys(c: int) -> Array:
	match c:
		Ctl.FIGURE:
			var name := _figure_tip_name()
			if name == "":
				return []
			var prefix: String = FIGURE_TIP_PREFIX[race][sex]
			return [prefix + name, prefix + name + "_EXPLANATION"]
		Ctl.HEIGHT:
			return ["UIO_NEWCHAR_STT_HEIGHT", "UIO_NEWCHAR_EXPLANATION_HEIGHT"]
		Ctl.VOLUME:
			return ["UIO_NEWCHAR_STT_VOLUME", "UIO_NEWCHAR_EXPLANATION_VOLUME"]
		Ctl.WEAPON:
			if weapon == 0:
				return ["UIO_NEWCHAR_STT_WEAPON", "UIO_NEWCHAR_EXPLANATION_ARMY_SELECT"]
			var tips: Array = WEAPON_TIPS[race]
			if weapon > tips.size():
				return []
			return ["UIO_NEWCHAR_STT_" + tips[weapon - 1][0], "UIO_NEWCHAR_EXPLANATION_" + tips[weapon - 1][1]]
		Ctl.PROTECTOR:
			var pos := armour_list_position()
			if pos == 0:
				return ["UIO_NEWCHAR_STT_PROTECTOR", "UIO_NEWCHAR_EXPLANATION_ARMOR_SELECT"]
			var tips: Array = ARMOUR_TIPS[race]
			if pos > tips.size():
				return []
			return ["UIO_NEWCHAR_STT_" + tips[pos - 1][0], "UIO_NEWCHAR_EXPLANATION_" + tips[pos - 1][1]]
	return []

## The chosen set's 1-based place in the sex's whole armour list (the chest
## slot's index, +0x144, which the Protector tooltip reads), 0 for none.
func armour_list_position() -> int:
	var s := armour_set()
	if s == null or catalog == null:
		return 0
	var all := catalog.all_armour_sets(race, sex)
	for i in range(all.size()):
		if all[i].armour_class == s.armour_class:
			return i + 1
	return 0

## The Figure tooltip's name. READ: by list index. OURS (charselect.md
## section 4): taken by the body's code name where one of the READ names
## matches it -- the Europe women's 12 and 13 are named SUCCUBUS then DEVIL
## while the ids run DEVIL then SUCCUBUS, and which is out of order in retail
## is OPEN -- with the codes' MENCER spelling read as the keys' MANCER.
func _figure_tip_name() -> String:
	var names: Array = FIGURE_TIP_NAMES[race][sex]
	var e := figure_entry()
	if e != null:
		var parts := e.code.split("_")
		if parts.size() >= 4:
			var suffix := "_".join(parts.slice(3)).replace("MENCER", "MANCER")
			if suffix in names:
				return suffix
	if figure >= 1 and figure <= names.size():
		return names[figure - 1]
	return ""

# --- the layout ---------------------------------------------------------------

## The sliders top to bottom as a layout's `Custom` section places them (its
## rect y), as Control values; empty when the section lacks any of the five.
static func slider_order_from_layout(section: UiLayoutParser.SectionDef) -> Array:
	if section == null:
		return []
	var found: Array = []
	for c in SLIDER_IDS:
		var d := FrontEndFrame.by_id(section, SLIDER_IDS[c])
		if d == null:
			return []
		found.append([d.rect.position.y, c])
	found.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for f in found:
		out.append(f[1])
	return out
