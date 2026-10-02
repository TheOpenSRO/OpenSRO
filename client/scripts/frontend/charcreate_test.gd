extends SceneTree

## The customize screen's rules and motion (round 685) on a synthetic
## catalogue (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/frontend/charcreate_test.gd`
##
## What it holds (READ values, docs/protocol/charselect.md section 4 and
## WORLD_ISSUES round 685): the controls -> the create request (model, the
## scale byte's nibbles, the item ids), the starting values, Europe's weapon ->
## armour rule as the sliders show it, each race's slider order (from a
## layout's own rects), the name rules and their messages, Confirm's order,
## the tooltip keys, the rotation physics (one click ~40 degrees over ~1 s),
## the zoom poses and the backdrop's turn.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _row(id: int, code: String, t: Array, country: int, sex: int, two_handed: int = 0) -> String:
	var cols := PackedStringArray()
	cols.resize(95)
	for i in range(95):
		cols[i] = "0"
	cols[CharCatalog.COL_SERVICE] = "1"
	cols[CharCatalog.COL_ID] = str(id)
	cols[CharCatalog.COL_CODE] = code
	for i in range(4):
		cols[CharCatalog.COL_TYPE_ID1 + i] = str(t[i])
	cols[CharCatalog.COL_COUNTRY] = str(country)
	cols[CharCatalog.COL_MODEL] = "xxx.bsr"
	cols[CharCatalog.COL_SEX] = str(sex)
	cols[CharCatalog.COL_TWO_HANDED] = str(two_handed)
	return "\t".join(cols)

## A small catalogue shaped like the archive's (ids are synthetic).
func _catalog() -> CharCatalog:
	var chars := [
		_row(100, "CHAR_CH_MAN_ADVENTURER", [1, 1, 0, 0], 0, 1),
		_row(101, "CHAR_CH_MAN_BOGY", [1, 1, 0, 0], 0, 1),
		_row(102, "CHAR_CH_MAN_FIGHTER", [1, 1, 0, 0], 0, 1),
		_row(110, "CHAR_CH_WOMAN_ADVENTURER", [1, 1, 0, 0], 0, 0),
		_row(111, "CHAR_CH_WOMAN_NECROMENCERB", [1, 1, 0, 0], 0, 0),
		_row(200, "CHAR_EU_MAN_NOBLE", [1, 1, 0, 0], 1, 1),
		_row(201, "CHAR_EU_MAN_NECROMENCER", [1, 1, 0, 0], 1, 1),
		_row(210, "CHAR_EU_WOMAN_ANGEL", [1, 1, 0, 0], 1, 0),
		_row(211, "CHAR_EU_WOMAN_DEVIL", [1, 1, 0, 0], 1, 0),
		_row(212, "CHAR_EU_WOMAN_SUCCUBUS", [1, 1, 0, 0], 1, 0),
	]
	var items := [
		# China weapons: sword, blade one-handed; spear, glaive, bow not.
		_row(1001, "ITEM_CH_SWORD_01_A_DEF", [3, 1, 6, 2], 0, 2),
		_row(1002, "ITEM_CH_BLADE_01_A_DEF", [3, 1, 6, 3], 0, 2),
		_row(1003, "ITEM_CH_SPEAR_01_A_DEF", [3, 1, 6, 4], 0, 2, 1),
		_row(1004, "ITEM_CH_TBLADE_01_A_DEF", [3, 1, 6, 5], 0, 2, 1),
		_row(1005, "ITEM_CH_BOW_01_A_DEF", [3, 1, 6, 6], 0, 2, 1),
		_row(1009, "ITEM_CH_SHIELD_01_A_DEF", [3, 1, 4, 1], 0, 2),
		# China man: heavy (3), light (2), clothes (1) -- in id order.
		_row(1010, "ITEM_CH_M_HEAVY_01_BA_A_DEF", [3, 1, 3, 3], 0, 1),
		_row(1011, "ITEM_CH_M_HEAVY_01_LA_A_DEF", [3, 1, 3, 4], 0, 1),
		_row(1012, "ITEM_CH_M_HEAVY_01_FA_A_DEF", [3, 1, 3, 6], 0, 1),
		_row(1013, "ITEM_CH_M_LIGHT_01_BA_A_DEF", [3, 1, 2, 3], 0, 1),
		_row(1014, "ITEM_CH_M_LIGHT_01_LA_A_DEF", [3, 1, 2, 4], 0, 1),
		_row(1015, "ITEM_CH_M_LIGHT_01_FA_A_DEF", [3, 1, 2, 6], 0, 1),
		_row(1016, "ITEM_CH_M_CLOTHES_01_BA_A_DEF", [3, 1, 1, 3], 0, 1),
		_row(1017, "ITEM_CH_M_CLOTHES_01_LA_A_DEF", [3, 1, 1, 4], 0, 1),
		_row(1018, "ITEM_CH_M_CLOTHES_01_FA_A_DEF", [3, 1, 1, 6], 0, 1),
		# China woman: the same three sets.
		_row(1020, "ITEM_CH_W_HEAVY_01_BA_A_DEF", [3, 1, 3, 3], 0, 0),
		_row(1021, "ITEM_CH_W_HEAVY_01_LA_A_DEF", [3, 1, 3, 4], 0, 0),
		_row(1022, "ITEM_CH_W_HEAVY_01_FA_A_DEF", [3, 1, 3, 6], 0, 0),
		_row(1023, "ITEM_CH_W_LIGHT_01_BA_A_DEF", [3, 1, 2, 3], 0, 0),
		_row(1024, "ITEM_CH_W_LIGHT_01_LA_A_DEF", [3, 1, 2, 4], 0, 0),
		_row(1025, "ITEM_CH_W_LIGHT_01_FA_A_DEF", [3, 1, 2, 6], 0, 0),
		_row(1026, "ITEM_CH_W_CLOTHES_01_BA_A_DEF", [3, 1, 1, 3], 0, 0),
		_row(1027, "ITEM_CH_W_CLOTHES_01_LA_A_DEF", [3, 1, 1, 4], 0, 0),
		_row(1028, "ITEM_CH_W_CLOTHES_01_FA_A_DEF", [3, 1, 1, 6], 0, 0),
		# Europe weapons in the archive's id order: dagger, 1H sword, 2H
		# sword, dual axe, crossbow, warlock rod, staff, harp, cleric rod.
		_row(2001, "ITEM_EU_DAGGER_01_A_DEF", [3, 1, 6, 13], 1, 2, 1),
		_row(2002, "ITEM_EU_SWORD_01_A_DEF", [3, 1, 6, 7], 1, 2),
		_row(2003, "ITEM_EU_TSWORD_01_A_DEF", [3, 1, 6, 8], 1, 2, 1),
		_row(2004, "ITEM_EU_AXE_01_A_DEF", [3, 1, 6, 9], 1, 2, 1),
		_row(2005, "ITEM_EU_CROSSBOW_01_A_DEF", [3, 1, 6, 12], 1, 2, 1),
		_row(2006, "ITEM_EU_DARKSTAFF_01_A_DEF", [3, 1, 6, 10], 1, 2),
		_row(2007, "ITEM_EU_STAFF_01_A_DEF", [3, 1, 6, 11], 1, 2, 1),
		_row(2008, "ITEM_EU_HARP_01_A_DEF", [3, 1, 6, 14], 1, 2, 1),
		_row(2009, "ITEM_EU_STAFF_02_A_DEF", [3, 1, 6, 15], 1, 2),
		_row(2010, "ITEM_EU_SHIELD_01_A_DEF", [3, 1, 4, 1], 1, 2),
		# Europe man: heavy (11), light (10), robe (9) -- in id order.
		_row(2011, "ITEM_EU_M_HEAVY_01_BA_A_DEF", [3, 1, 11, 3], 1, 1),
		_row(2012, "ITEM_EU_M_HEAVY_01_LA_A_DEF", [3, 1, 11, 4], 1, 1),
		_row(2013, "ITEM_EU_M_HEAVY_01_FA_A_DEF", [3, 1, 11, 6], 1, 1),
		_row(2014, "ITEM_EU_M_LIGHT_01_BA_A_DEF", [3, 1, 10, 3], 1, 1),
		_row(2015, "ITEM_EU_M_LIGHT_01_LA_A_DEF", [3, 1, 10, 4], 1, 1),
		_row(2016, "ITEM_EU_M_LIGHT_01_FA_A_DEF", [3, 1, 10, 6], 1, 1),
		_row(2017, "ITEM_EU_M_CLOTHES_01_BA_A_DEF", [3, 1, 9, 3], 1, 1),
		_row(2018, "ITEM_EU_M_CLOTHES_01_LA_A_DEF", [3, 1, 9, 4], 1, 1),
		_row(2019, "ITEM_EU_M_CLOTHES_01_FA_A_DEF", [3, 1, 9, 6], 1, 1),
	]
	return CharCatalog.from_tables(["\n".join(chars)], ["\n".join(items)])

## A layout's Custom section with the five sliders at the given y's.
func _custom_layout(ys: Dictionary) -> UiLayoutParser.SectionDef:
	var lines := PackedStringArray(["Section = Custom,\"0,0,0,0\",\"0\"", "{"])
	for id in ys:
		lines.append("\tGDR_SLI_%d:CIFSliderCtrl" % id)
		lines.append("\t{")
		lines.append("\t\tID=INTEGER,\"%d\"" % id)
		lines.append("\t\tRect=RECT,\"88,%d,120,24\"" % ys[id])
		lines.append("\t}")
	lines.append("}")
	var layout := UiLayoutParser.parse("\n".join(lines).to_utf8_buffer(), true, PackedStringArray())
	return layout.sections.get("Custom")

func _init() -> void:
	var cat := _catalog()
	var C := CharCreateModel.Ctl

	# --- the starting values (READ) ---
	var m := CharCreateModel.create(cat, CharCatalog.RACE_CHINA)
	_check(m.sex == CharCatalog.SEX_MAN and m.figure == 1 and m.height == 2 and m.volume == 2 and m.weapon == 0,
		"China starts man, Figure 1, Height 2, Volume 2, Weapon 0")
	_check(m.protector == 1 and m.slider_range(C.PROTECTOR) == Vector2i(1, 3),
		"China's Protector runs 1..3 and starts at 1 ('none' kept out, OURS) (got %d, %s)" % [m.protector, m.slider_range(C.PROTECTOR)])
	_check(m.slider_range(C.FIGURE) == Vector2i(1, 3) and m.slider_range(C.HEIGHT) == Vector2i(0, 4)
		and m.slider_range(C.VOLUME) == Vector2i(0, 4) and m.slider_range(C.WEAPON) == Vector2i(0, 5),
		"China's ranges: Figure 1..n, Height and Volume 0..4, Weapon 0..5")
	var mn := CharCreateModel.create(cat, CharCatalog.RACE_CHINA, false)
	_check(mn.protector == 0 and mn.slider_range(C.PROTECTOR).x == 0, "with the per-server flag set, China's Protector starts at 0 (READ 0x84f350)")
	_check(m.scale_byte() == 0x22, "the starting scale byte is 0x22")

	# --- controls -> the create request ---
	m.set_value(C.FIGURE, 3)
	m.set_value(C.HEIGHT, 4)
	m.set_value(C.VOLUME, 1)
	m.set_value(C.WEAPON, 2)
	m.set_value(C.PROTECTOR, 2)
	var req := m.request()
	_check(req["model"] == 102, "Figure 3 is the third man's body (got %d)" % req["model"])
	_check(req["scale"] == 0x14, "Height 4, Volume 1 -> scale 0x14: Volume high nibble, Height low (got 0x%x)" % req["scale"])
	_check([req["chest"], req["legs"], req["feet"]] == [1013, 1014, 1015], "Protector 2 is the light set (got %s)" % str([req["chest"], req["legs"], req["feet"]]))
	_check(req["weapon"] == 1002, "Weapon 2 is the blade (got %d)" % req["weapon"])
	_check(CharCreateModel.scale_of(0, 4) == 0x40 and CharCreateModel.scale_of(3, 0) == 0x03 and CharCreateModel.scale_of(4, 4) == 0x44,
		"scale_of: (h 0, v 4) 0x40, (3, 0) 0x03, (4, 4) 0x44")
	_check(_ids(m.preview_items()) == [1013, 1014, 1015, 1002, 1009], "a one-handed blade wears the shield in the preview (got %s)" % str(_ids(m.preview_items())))
	m.set_value(C.WEAPON, 5)
	_check(_ids(m.preview_items()) == [1013, 1014, 1015, 1005], "a bow wears none (got %s)" % str(_ids(m.preview_items())))
	_check(m.protector == 2, "China: a weapon change leaves the Protector alone")
	_check(not m.set_value(C.HEIGHT, 9) or m.height == 4, "a value past the range is clamped")
	_check(m.height == 4, "Height stays 4 after asking for 9")

	# --- sex: the lists change, the indices stay ---
	m.set_value(C.FIGURE, 3)
	m.set_sex(CharCatalog.SEX_WOMAN)
	_check(m.figure == 2, "a woman has two Figures here, so Figure 3 clamps to 2 (got %d)" % m.figure)
	req = m.request()
	_check(req["model"] == 111 and [req["chest"], req["legs"], req["feet"]] == [1023, 1024, 1025],
		"after the switch: the woman's body and her light set (got %s)" % str(req))
	_check(req["weapon"] == 1005 and req["scale"] == 0x14, "the weapon and the scale carry over")

	# --- Europe's weapon -> armour rule, as the sliders show it ---
	var e := CharCreateModel.create(cat, CharCatalog.RACE_EUROPE)
	_check(e.weapon == 0 and e.protector == 0 and e.slider_range(C.PROTECTOR) == Vector2i(0, 0),
		"Europe starts with no weapon and the Protector at 0..0")
	_check(e.protector_alpha() == 100, "with no weapon the Protector slider is dimmed to alpha 100 (READ 0x8531e0)")
	_check(e.slider_range(C.WEAPON) == Vector2i(0, 9), "Europe's Weapon runs 0..9")
	var expect := {1: [[2014, 2015, 2016]], 2: [[2011, 2012, 2013], [2014, 2015, 2016]], 3: [[2011, 2012, 2013], [2014, 2015, 2016]],
		4: [[2011, 2012, 2013], [2014, 2015, 2016]], 5: [[2014, 2015, 2016]], 6: [[2017, 2018, 2019]], 7: [[2017, 2018, 2019]],
		8: [[2017, 2018, 2019]], 9: [[2014, 2015, 2016], [2017, 2018, 2019]]}
	for w in range(1, 10):
		e.set_value(C.PROTECTOR, 1)
		e.set_value(C.WEAPON, w)
		var allowed: Array = expect[w]
		_check(e.protector == 0, "Europe weapon %d puts the Protector back to 0" % w)
		_check(e.slider_range(C.PROTECTOR) == Vector2i(0, allowed.size()), "Europe weapon %d: Protector 0..%d (got %s)" % [w, allowed.size(), e.slider_range(C.PROTECTOR)])
		_check(e.protector_alpha() == 255, "Europe weapon %d: the Protector is lit" % w)
		var got := []
		for p in range(1, allowed.size() + 1):
			e.set_value(C.PROTECTOR, p)
			got.append(Array(e.armour_ids()))
		_check(got == allowed, "Europe weapon %d offers %s (got %s)" % [w, str(allowed), str(got)])
	e.set_value(C.WEAPON, 2)
	e.set_value(C.PROTECTOR, 2)
	_check(Array(e.armour_ids()) == [2014, 2015, 2016] and e.weapon_id() == 2002, "1H sword with Protector 2 is the light set")
	_check(_ids(e.preview_items()) == [2014, 2015, 2016, 2002, 2010], "the 1H sword wears the Europe shield")
	e.set_value(C.WEAPON, 1)
	_check(_ids(e.preview_items()) == [2001], "a dagger (TwoHanded 1) carries no shield and no armour yet (got %s)" % str(_ids(e.preview_items())))

	# --- Confirm's checks, in order (READ 0x84ed50 / 0x8527e0) ---
	var cc := CharCreateModel.create(cat, CharCatalog.RACE_CHINA)
	_check(cc.confirm_error() == CharCreateModel.MSG_NO_WEAPON, "China with no weapon: SELECTWEAPON")
	cc.set_value(C.WEAPON, 1)
	_check(cc.confirm_error() == "", "China with a weapon: no refusal")
	var ec := CharCreateModel.create(cat, CharCatalog.RACE_EUROPE)
	_check(ec.confirm_error() == CharCreateModel.MSG_NO_ARMOUR, "Europe checks the armour first: SELECTARMOR")
	ec.set_value(C.WEAPON, 2)
	_check(ec.confirm_error() == CharCreateModel.MSG_NO_ARMOUR, "Europe with a weapon but Protector 0: SELECTARMOR")
	ec.set_value(C.PROTECTOR, 1)
	_check(ec.confirm_error() == "", "Europe with a weapon and a set: no refusal")

	# --- the name (READ length; OURS characters, the server's rule) ---
	_check(CharCreateModel.name_error("a") == CharCreateModel.MSG_NAME_LENGTH, "1 character: NAME_STRING")
	_check(CharCreateModel.name_error("abcdefghijklm") == CharCreateModel.MSG_NAME_LENGTH, "13 characters: NAME_STRING")
	_check(CharCreateModel.name_error("ab") == "" and CharCreateModel.name_error("abcdefghijkl") == "", "2 and 12 characters pass")
	_check(CharCreateModel.name_error("a b") == CharCreateModel.MSG_NAME_CHARS, "a space: WRONGSTRING")
	_check(CharCreateModel.name_error("it's") == CharCreateModel.MSG_NAME_CHARS, "a quote: WRONGSTRING")
	_check(CharCreateModel.name_error("Krämer") == CharCreateModel.MSG_NAME_CHARS, "a non-ASCII letter: WRONGSTRING")
	_check(CharCreateModel.name_error("Hero_77") == "", "letters, digits and _ pass")
	_check(CharCreateModel.name_error("") == CharCreateModel.MSG_NAME_LENGTH, "empty: the length message first")

	# --- the tooltip keys (READ) ---
	var t := CharCreateModel.create(cat, CharCatalog.RACE_CHINA)
	_check(t.tooltip_keys(C.FIGURE) == ["UIO_NEWCHAR_MAN_ADVENTURER", "UIO_NEWCHAR_MAN_ADVENTURER_EXPLANATION"], "China man Figure 1's tooltip")
	_check(t.tooltip_keys(C.WEAPON) == ["UIO_NEWCHAR_STT_WEAPON", "UIO_NEWCHAR_EXPLANATION_ARMY_SELECT"], "Weapon 0's tooltip is the slider's own")
	t.set_value(C.WEAPON, 4)
	_check(t.tooltip_keys(C.WEAPON) == ["UIO_NEWCHAR_STT_TBLADE", "UIO_NEWCHAR_EXPLANATION_TBLADE"], "China Weapon 4 is the glaive (TBLADE)")
	_check(t.tooltip_keys(C.PROTECTOR) == ["UIO_NEWCHAR_STT_HEAVY_ARMOR", "UIO_NEWCHAR_EXPLANATION_HEAVY_ARMOR"], "China Protector 1 is heavy")
	_check(t.tooltip_keys(C.HEIGHT)[1] == "UIO_NEWCHAR_EXPLANATION_HEIGHT" and t.tooltip_keys(C.VOLUME)[1] == "UIO_NEWCHAR_EXPLANATION_VOLUME", "Height's and Volume's tooltips")
	t.set_sex(CharCatalog.SEX_WOMAN)
	t.set_value(C.FIGURE, 2)
	_check(t.tooltip_keys(C.FIGURE)[0] == "UIO_NEWCHAR_FEMALE_NECROMANCERB", "a NECROMENCERB body is named by the key's NECROMANCERB (got %s)" % str(t.tooltip_keys(C.FIGURE)))
	var te := CharCreateModel.create(cat, CharCatalog.RACE_EUROPE)
	te.set_sex(CharCatalog.SEX_WOMAN)
	te.set_value(C.FIGURE, 2)
	_check(te.tooltip_keys(C.FIGURE)[0] == "UIO_NEWCHAR_EU_FEMALE_DEVIL", "the DEVIL body gets the DEVIL tooltip by its code (OURS) (got %s)" % str(te.tooltip_keys(C.FIGURE)))
	te.set_value(C.FIGURE, 3)
	_check(te.tooltip_keys(C.FIGURE)[0] == "UIO_NEWCHAR_EU_FEMALE_SUCCUBUS", "and the SUCCUBUS body the SUCCUBUS tooltip")
	te.set_sex(CharCatalog.SEX_MAN)
	te.set_value(C.WEAPON, 9)
	_check(te.tooltip_keys(C.WEAPON) == ["UIO_NEWCHAR_STT_EU_ONEHANDSTAFF", "UIO_NEWCHAR_EXPLANATION_ONEHANDSTAFF"], "Europe Weapon 9 is the cleric rod (ONEHANDSTAFF)")
	te.set_value(C.PROTECTOR, 2)
	_check(te.tooltip_keys(C.PROTECTOR) == ["UIO_NEWCHAR_STT_EU_ROBE", "UIO_NEWCHAR_EXPLANATION_EU_ROBE"],
		"Europe: the cleric rod's Protector 2 is the robe -- the tooltip follows the set's list place, not the slider (got %s)" % str(te.tooltip_keys(C.PROTECTOR)))

	# --- the slider order per race ---
	_check(CharCreateModel.SLIDER_ORDER[CharCatalog.RACE_CHINA] == [C.FIGURE, C.HEIGHT, C.VOLUME, C.PROTECTOR, C.WEAPON], "China: Protector before Weapon")
	_check(CharCreateModel.SLIDER_ORDER[CharCatalog.RACE_EUROPE] == [C.FIGURE, C.HEIGHT, C.VOLUME, C.WEAPON, C.PROTECTOR], "Europe: Weapon before Protector")
	# The archive's own rects (MEASURED): China 49 at 255, 48 at 224; Europe the reverse.
	var china := _custom_layout({49: 255, 48: 224, 47: 193, 46: 162, 45: 131})
	var europe := _custom_layout({48: 255, 49: 224, 47: 193, 46: 162, 45: 131})
	_check(CharCreateModel.slider_order_from_layout(china) == CharCreateModel.SLIDER_ORDER[CharCatalog.RACE_CHINA], "the China layout's rects give China's order (got %s)" % str(CharCreateModel.slider_order_from_layout(china)))
	_check(CharCreateModel.slider_order_from_layout(europe) == CharCreateModel.SLIDER_ORDER[CharCatalog.RACE_EUROPE], "the Europe layout's rects give Europe's order")
	_check(CharCreateModel.slider_order_from_layout(_custom_layout({45: 1})).is_empty(), "a section missing a slider gives no order")

	# --- the slider's thumb (INFERRED geometry) ---
	_check(CharCreateSlider.thumb_x(0, 0, 4) == 20.0 and CharCreateSlider.thumb_x(4, 0, 4) == 104.0 and CharCreateSlider.thumb_x(2, 0, 4) == 62.0, "the thumb runs 20..104")
	_check(CharCreateSlider.thumb_x(0, 0, 0) == 20.0, "an empty range keeps the thumb at the start")
	_check(CharCreateSlider.value_at(104.0, 1, 13) == 13 and CharCreateSlider.value_at(0.0, 1, 13) == 1 and CharCreateSlider.value_at(62.0, 0, 4) == 2, "a drag picks the nearest value")

	# --- the rotation physics (READ 0x850804..0x8508a4) ---
	var v := CharCreateView.new()
	v.click(1)
	_check(v.velocity == 50.0, "a right click adds 50 to the spin")
	var steps := 0
	while v.velocity != 0.0 and steps < 600:
		v.step_spin(1.0 / 60.0)
		steps += 1
	_check(absf(v.angle - 40.0) < 0.5, "one click turns ~40 degrees (got %.3f)" % v.angle)
	_check(absf(steps / 60.0 - 1.02) < 0.05, "and stops after ~1.02 s (got %.3f s)" % (steps / 60.0))
	_check(absf(v.yaw() - v.angle * 3.14 / 180.0) < 1e-6, "yaw is angle / 180 x 3.14 (not pi)")
	var v2 := CharCreateView.new()
	v2.click(-1)
	v2.click(-1)
	steps = 0
	while v2.velocity != 0.0 and steps < 600:
		v2.step_spin(1.0 / 60.0)
		steps += 1
	_check(absf(v2.angle + 140.0) < 1.0, "two left clicks stack: (100 - 30) / 0.5 = 140 degrees the other way (got %.3f)" % v2.angle)
	var v3 := CharCreateView.new()
	v3.click(1)
	v3.step_spin(1.0 / 60.0)
	var first := v3.angle
	_check(absf(first - (100.0 - 50.0 / 120.0) / 120.0) < 1e-4, "the first frame's step is (2v - d) dt / 2 (got %.5f)" % first)
	var v4 := CharCreateView.new()
	v4.velocity = 29.0
	v4.step_spin(0.0)
	_check(v4.velocity == 0.0, "a spin below 30 stops at once")

	# --- the zoom (READ) ---
	var out := CharCreateView.pose_for(false, 1.0, false)
	_check(out.target == Vector3(0.5, 9.8, 0.0) and out.distance == 28.5 and is_equal_approx(out.pitch, 0.2), "zoomed out: (0.5, 9.8, 0) at 28.5, pitch 0.2")
	var inm := CharCreateView.pose_for(true, 1.06, false)
	var inw := CharCreateView.pose_for(true, 1.0, true)
	_check(is_equal_approx(inm.target.y, 15.9) and inm.target.x == 2.0 and inm.distance == 11.0, "zoomed in on a man at Height 4: y 1.06 x 15, distance 11")
	_check(is_equal_approx(inw.target.y, 14.0), "zoomed in on a woman: y x 14")
	var zv := CharCreateView.new()
	zv.toggle_zoom(1.0, false)
	var mid := zv.step_zoom(0.5)
	_check(mid.distance < 28.5 and mid.distance > 11.0, "half way through the 1.0 s zoom the distance is between (got %.2f)" % mid.distance)
	var end := zv.step_zoom(0.6)
	_check(is_equal_approx(end.distance, 11.0) and not zv.zoom_moving(), "after 1.0 s it rests zoomed in")
	zv.toggle_zoom(1.0, false)
	zv.step_zoom(2.0)
	_check(is_equal_approx(zv.pose().distance, 28.5) and not zv.zoomed, "the button again zooms back out (a toggle, not a reset)")

	# --- the backdrop's turn (READ) ---
	var b0 := CharCreateView.backdrop_pose(CharCatalog.RACE_CHINA, 0)
	_check(is_equal_approx(b0.yaw, 0.390955) and b0.distance == 0.1 and b0.pitch == 0.0, "the backdrop starts at yaw 0.390955, distance 0.1, level")
	var b1 := CharCreateView.backdrop_pose(CharCatalog.RACE_EUROPE, 30000)
	_check(is_equal_approx(b1.yaw, 1.390955) and b1.target == Vector3(335, 140, 1460), "30 s later it has turned 1 radian; Europe looks from (335, 140, 1460)")
	_check(CharCreateView.BACKDROP[CharCatalog.RACE_CHINA]["region"] == Vector2i(98, 168) and CharCreateView.BACKDROP[CharCatalog.RACE_EUROPE]["region"] == Vector2i(105, 79), "China 98/168, Europe 105/79")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(0)

func _ids(items: Array) -> Array:
	var out := []
	for i in items:
		out.append(int(i["id"]))
	return out
