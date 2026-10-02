extends SceneTree

## CharCatalog's rule on synthetic textdata rows (never real game data), run
## headless:
## `godot4 --headless --path client --script res://scripts/frontend/char_catalog_test.gd`
##
## The rule is charselect.md section 6's: bodies are Service-1 characterdata
## rows of TypeID 1/1, items Service-1 itemdata rows of TypeID 3/1 whose code
## ends `_A_DEF`, the last definition of an id winning. The counts against a
## real archive (52 bodies, 5 + 9 weapons, ...) are client/tools/
## appearance_probe.gd's, run on the render box.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## One tab-separated row, 95 columns wide (the item TwoHanded column is 93).
func _row(service: int, id: int, code: String, t: Array, country: int, sex: int,
		model: String = "xxx", two_handed: int = 0) -> String:
	var cols := PackedStringArray()
	cols.resize(95)
	for i in range(95):
		cols[i] = "0"
	cols[CharCatalog.COL_SERVICE] = str(service)
	cols[CharCatalog.COL_ID] = str(id)
	cols[CharCatalog.COL_CODE] = code
	for i in range(4):
		cols[CharCatalog.COL_TYPE_ID1 + i] = str(t[i])
	cols[CharCatalog.COL_COUNTRY] = str(country)
	cols[CharCatalog.COL_MODEL] = model
	cols[CharCatalog.COL_SEX] = str(sex)
	cols[CharCatalog.COL_TWO_HANDED] = str(two_handed)
	return "\t".join(cols)

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _init() -> void:
	var chars := [
		_row(1, 101, "CHAR_CH_MAN_A", [1, 1, 0, 0], 0, 1, "char\\china\\a.bsr"),
		_row(1, 100, "CHAR_CH_MAN_B", [1, 1, 0, 0], 0, 1, "char\\china\\b.bsr"),
		_row(1, 110, "CHAR_CH_WOMAN_A", [1, 1, 0, 0], 0, 0),
		_row(1, 200, "CHAR_EU_MAN_A", [1, 1, 0, 0], 1, 1),
		_row(1, 210, "CHAR_EU_WOMAN_A", [1, 1, 0, 0], 1, 0),
		_row(0, 120, "CHAR_CH_MAN_OFF", [1, 1, 0, 0], 0, 1),  # Service 0
		_row(1, 130, "NPC_CH_SMITH", [1, 2, 2, 0], 0, 1),     # not a player character
		_row(1, 140, "CHAR_CH_MAN_LATE", [1, 2, 0, 0], 0, 1), # first: not 1/1 ...
		_row(1, 150, "CHAR_CH_MAN_GONE", [1, 1, 0, 0], 0, 1), # first: a body ...
	]
	var chars_late := [
		_row(1, 140, "CHAR_CH_MAN_LATE", [1, 1, 0, 0], 0, 1), # ... last: a body -> in
		_row(0, 150, "CHAR_CH_MAN_GONE", [1, 1, 0, 0], 0, 1), # ... last: Service 0 -> out
		_row(1, 101, "CHAR_CH_MAN_A", [1, 1, 0, 0], 0, 1, "char\\china\\a.bsr"), # a duplicate
	]
	var items := [
		# China weapons; a two-handed one gets no shield.
		_row(1, 1001, "ITEM_CH_SWORD_01_A_DEF", [3, 1, 6, 2], 0, 2, "item\\china\\weapon\\sword_01.bsr"),
		_row(1, 1002, "ITEM_CH_SPEAR_01_A_DEF", [3, 1, 6, 4], 0, 2, "xxx", 1),
		_row(1, 1003, "ITEM_CH_SHIELD_01_A_DEF", [3, 1, 4, 1], 0, 2),
		# China man armour: heavy (3), light (2), clothes (1); listed out of order.
		_row(1, 1016, "ITEM_CH_M_CLOTHES_01_BA_A_DEF", [3, 1, 1, 3], 0, 1),
		_row(1, 1017, "ITEM_CH_M_CLOTHES_01_LA_A_DEF", [3, 1, 1, 4], 0, 1),
		_row(1, 1018, "ITEM_CH_M_CLOTHES_01_FA_A_DEF", [3, 1, 1, 6], 0, 1),
		_row(1, 1010, "ITEM_CH_M_HEAVY_01_BA_A_DEF", [3, 1, 3, 3], 0, 1),
		_row(1, 1011, "ITEM_CH_M_HEAVY_01_LA_A_DEF", [3, 1, 3, 4], 0, 1),
		_row(1, 1012, "ITEM_CH_M_HEAVY_01_FA_A_DEF", [3, 1, 3, 6], 0, 1),
		_row(1, 1013, "ITEM_CH_M_LIGHT_01_BA_A_DEF", [3, 1, 2, 3], 0, 1),
		_row(1, 1014, "ITEM_CH_M_LIGHT_01_LA_A_DEF", [3, 1, 2, 4], 0, 1),
		_row(1, 1015, "ITEM_CH_M_LIGHT_01_FA_A_DEF", [3, 1, 2, 6], 0, 1),
		# A China woman's chest only.
		_row(1, 1020, "ITEM_CH_W_HEAVY_01_BA_A_DEF", [3, 1, 3, 3], 0, 0),
		# Europe weapons by TypeID4: 7 1H sword, 12 crossbow, 10 warlock rod, 15 cleric rod.
		_row(1, 2001, "ITEM_EU_SWORD_01_A_DEF", [3, 1, 6, 7], 1, 2),
		_row(1, 2002, "ITEM_EU_CROSSBOW_01_A_DEF", [3, 1, 6, 12], 1, 2, "xxx", 1),
		_row(1, 2003, "ITEM_EU_DARKSTAFF_01_A_DEF", [3, 1, 6, 10], 1, 2),
		_row(1, 2004, "ITEM_EU_STAFF_01_A_DEF", [3, 1, 6, 15], 1, 2),
		_row(1, 2005, "ITEM_EU_SHIELD_01_A_DEF", [3, 1, 4, 2], 1, 2),
		# Europe woman armour: heavy 11, light 10, robe 9.
		_row(1, 2010, "ITEM_EU_W_HEAVY_01_BA_A_DEF", [3, 1, 11, 3], 1, 0),
		_row(1, 2011, "ITEM_EU_W_HEAVY_01_LA_A_DEF", [3, 1, 11, 4], 1, 0),
		_row(1, 2012, "ITEM_EU_W_HEAVY_01_FA_A_DEF", [3, 1, 11, 6], 1, 0),
		_row(1, 2013, "ITEM_EU_W_LIGHT_01_BA_A_DEF", [3, 1, 10, 3], 1, 0),
		_row(1, 2014, "ITEM_EU_W_LIGHT_01_LA_A_DEF", [3, 1, 10, 4], 1, 0),
		_row(1, 2015, "ITEM_EU_W_LIGHT_01_FA_A_DEF", [3, 1, 10, 6], 1, 0),
		_row(1, 2016, "ITEM_EU_W_CLOTHES_01_BA_A_DEF", [3, 1, 9, 3], 1, 0),
		_row(1, 2017, "ITEM_EU_W_CLOTHES_01_LA_A_DEF", [3, 1, 9, 4], 1, 0),
		_row(1, 2018, "ITEM_EU_W_CLOTHES_01_FA_A_DEF", [3, 1, 9, 6], 1, 0),
		# Out: not _A_DEF, not equipment, Service 0, and the ammo rows.
		_row(1, 3001, "ITEM_CH_SWORD_02_A", [3, 1, 6, 2], 0, 2),
		_row(1, 3002, "ITEM_ETC_THING_A_DEF", [3, 3, 1, 1], 0, 2),
		_row(0, 3003, "ITEM_CH_BLADE_01_A_DEF", [3, 1, 6, 3], 0, 2),
		_row(1, 3004, "ITEM_ETC_AMMO_ARROW_01_DEF", [3, 3, 4, 1], 0, 2),
		# A code that does not END in _A_DEF.
		_row(1, 3005, "ITEM_CH_SWORD_01_A_DEF_X", [3, 1, 6, 2], 0, 2),
	]
	var cat := CharCatalog.from_tables(
		[_utf16("\r\n".join(PackedStringArray(chars))), "\n".join(PackedStringArray(chars_late))],
		[_utf16("\r\n".join(PackedStringArray(items)))])

	# --- bodies ---
	_check(cat.has(100) and cat.has(101) and cat.has(110) and cat.has(200) and cat.has(210), "the five player bodies are in")
	_check(not cat.has(120), "a Service-0 body is out")
	_check(not cat.has(130), "an NPC (TypeID 1/2) is out")
	_check(cat.has(140), "an id whose LAST definition is a body is in")
	_check(not cat.has(150), "an id whose last definition is Service 0 is out, though an earlier one was a body")
	var ch_men := cat.figures(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN)
	_check(ch_men.size() == 3, "China men: 3 figures (got %d)" % ch_men.size())
	_check(ch_men.size() == 3 and ch_men[0].id == 100 and ch_men[1].id == 101 and ch_men[2].id == 140, "figures are in id order")
	_check(cat.figures(CharCatalog.RACE_CHINA, CharCatalog.SEX_WOMAN).size() == 1, "China women: 1")
	_check(cat.figures(CharCatalog.RACE_EUROPE, CharCatalog.SEX_MAN).size() == 1, "Europe men: 1")
	_check(cat.get_entry(101).model_path == "char\\china\\a.bsr", "a body keeps its model path")
	_check(cat.get_entry(110).model_path == "", "an `xxx` model reads as none")

	# --- items ---
	for id in [3001, 3002, 3003, 3004, 3005]:
		_check(not cat.has(id), "item %d is out" % id)
	var cw := cat.weapons(CharCatalog.RACE_CHINA)
	_check(cw.size() == 2 and cw[0].id == 1001 and cw[1].id == 1002, "China weapons: 2, in id order")
	_check(cat.weapons(CharCatalog.RACE_EUROPE).size() == 4, "Europe weapons: 4")
	_check(cat.shield(CharCatalog.RACE_CHINA) != null and cat.shield(CharCatalog.RACE_CHINA).id == 1003, "China's shield")
	_check(cat.get_entry(1001).piece() == CharCatalog.Piece.WEAPON, "a TypeID3-6 item is the weapon")
	_check(cat.get_entry(1003).piece() == CharCatalog.Piece.SHIELD, "a TypeID3-4 item is the shield")
	_check(cat.get_entry(1010).piece() == CharCatalog.Piece.CHEST and cat.get_entry(1011).piece() == CharCatalog.Piece.LEGS \
		and cat.get_entry(1012).piece() == CharCatalog.Piece.FEET, "TypeID4 3/4/6 are chest, legs, feet")
	_check(cat.get_entry(1002).two_handed and not cat.get_entry(1001).two_handed, "TwoHanded is read from column 93")

	# --- armour sets ---
	var cm_sets := cat.armour_sets(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN)
	_check(cm_sets.size() == 3, "China man: 3 sets (got %d)" % cm_sets.size())
	if cm_sets.size() == 3:
		_check(cm_sets[0].name == "heavy" and cm_sets[1].name == "light" and cm_sets[2].name == "clothes",
			"China sets in id order: heavy, light, clothes (got %s, %s, %s)" % [cm_sets[0].name, cm_sets[1].name, cm_sets[2].name])
		_check(str(cm_sets[0].ids()) == str([1010, 1011, 1012]), "a set is its chest, legs and feet")
	_check(cat.armour_sets(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN, 1002).size() == 3, "China: no weapon restriction")
	_check(cat.armour_sets(CharCatalog.RACE_CHINA, CharCatalog.SEX_WOMAN).size() == 1, "a woman's list holds women's pieces only")
	var ew := CharCatalog.SEX_WOMAN
	var eu := CharCatalog.RACE_EUROPE
	_check(_names(cat.armour_sets(eu, ew, 2001)) == ["heavy", "light"], "Europe 1H sword: heavy, light (got %s)" % str(_names(cat.armour_sets(eu, ew, 2001))))
	_check(_names(cat.armour_sets(eu, ew, 2002)) == ["light"], "Europe crossbow: light")
	_check(_names(cat.armour_sets(eu, ew, 2003)) == ["robe"], "Europe warlock rod: robe")
	_check(_names(cat.armour_sets(eu, ew, 2004)) == ["light", "robe"], "Europe cleric rod: light, robe")
	_check(cat.armour_sets(eu, ew, 0).is_empty(), "Europe with no weapon: no set (the slider is dimmed)")
	_check(cat.armour_sets(eu, CharCatalog.SEX_MAN, 2001).is_empty(), "Europe man: no men's armour in this table")

	# --- defaults and kits ---
	var d := cat.defaults(CharCatalog.RACE_CHINA)
	_check(d["model"] == 100 and d["sex"] == CharCatalog.SEX_MAN and d["scale"] == 0x22 and d["weapon"] == 0,
		"defaults: Figure 1 of the men, scale 0x22, no weapon (got %s)" % str(d))
	_check(cat.defaults(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN, true)["chest"] == 1010, "a required Protector starts at set 1")
	var kit := cat.sample_kit(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN)
	_check(_ids(kit) == [1010, 1011, 1012, 1001, 1003], "China kit: heavy set, sword, shield (got %s)" % str(_ids(kit)))
	var kit2 := cat.sample_kit(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN, 1)
	_check(not _ids(kit2).has(1003), "no shield beside a two-handed spear")
	var kit3 := cat.sample_kit(eu, ew, 1)
	_check(_ids(kit3) == [2013, 2014, 2015, 2002], "Europe crossbow kit: light set, no shield (got %s)" % str(_ids(kit3)))
	_check(cat.size() == 6 + 2 + 1 + 9 + 1 + 4 + 1 + 9, "the catalogue holds exactly the rule's rows (got %d)" % cat.size())

	# --- an empty archive ---
	_check(CharCatalog.from_archive(null).size() == 0, "no archive: an empty catalogue")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(0)

func _names(sets: Array) -> Array:
	var out := []
	for s in sets:
		out.append((s as CharCatalog.ArmourSet).name)
	return out

func _ids(kit: Array) -> Array:
	var out := []
	for k in kit:
		out.append(int(k["id"]))
	return out
