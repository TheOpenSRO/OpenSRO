extends SceneTree

## Round 731: the item tooltip's lines (ItemTooltipLines), its type and set
## names (ItemTypeNames) and its window (ItemTooltipBubble), against items
## built in code with the shapes real rows carry (never game data; the
## numbers are the round's measured rows, docs/protocol/item_tooltip.md).
##   godot4 --headless --path client --script res://scripts/ui/hud/item_tooltip_lines_test.gd

const L := preload("res://scripts/ui/hud/item_tooltip_lines.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_lines_tests()
	_type_name_tests()
	await process_frame
	_bubble_tests()
	await process_frame
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _item(types: Array, name: String) -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.id = 1
	it.code_name = "ITEM_TEST"
	it.item_name = name
	it.type_ids = PackedInt32Array(types)
	it.req_level_types = PackedInt32Array([1, 0, 0, 0])
	it.req_levels = PackedInt32Array([0, 0, 0, 0])
	it.req_gender = ItemTableReader.REQ_GENDER_ANY
	it.country = 0
	it.plus_incs = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	return it

## The D11 seal spear (ITEM_CH_SPEAR_11_A_RARE's columns, MEASURED).
func _spear() -> ItemTableReader.Item:
	var it := _item([3, 1, 6, 4], "Reaper Soul Spear")
	it.rarity = 2
	it.item_class = 31
	it.durability = 85
	it.durability_max = 103
	it.attack_range = 18
	it.phys_atk = Vector2i(1729, 2059)
	it.phys_atk_upper = Vector2i(1831, 2180)
	it.mag_atk = Vector2i(2964, 3623)
	it.mag_atk_upper = Vector2i(3100, 3800)
	it.attack_rate = 120
	it.attack_rate_upper = 253
	it.critical = 5
	it.critical_upper = 17
	it.phys_reinforce = Vector2i(2573, 3063)
	it.phys_reinforce_upper = Vector2i(2677, 3187)
	it.mag_reinforce = Vector2i(4411, 5391)
	it.mag_reinforce_upper = Vector2i(4600, 5600)
	it.req_levels[0] = 111
	it.max_magic_options = 9
	return it

## The D7 seal necklace (ITEM_CH_NECKLACE_07_A_RARE: absorption 17.4 ~ 18.0).
func _necklace() -> ItemTableReader.Item:
	var it := _item([3, 1, 5, 2], "Coast Pearl Necklace")
	it.rarity = 2
	it.item_class = 19
	it.durability = 40
	it.durability_max = 40
	it.phys_absorb = Vector2(17.4, 18.0)
	it.mag_absorb = Vector2(17.4, 18.0)
	it.req_levels[0] = 56
	it.max_magic_options = 9
	return it

## A D11 set helm (rarity 3, a set id) with a heavy armour's defences.
func _helm() -> ItemTableReader.Item:
	var it := _item([3, 1, 3, 1], "Set Helm")
	it.rarity = 3
	it.item_class = 31
	it.set_id = 13
	it.durability = 60
	it.durability_max = 60
	it.phys_def = Vector2(274.1, 290.4)
	it.mag_def = Vector2(358.8, 380.2)
	it.parry = Vector2(21, 63)
	it.req_levels[0] = 101
	it.req_str = 120
	it.req_int = 40
	it.req_gender = ItemTableReader.REQ_GENDER_MAN
	it.max_magic_options = 9
	it.armour_phys_reinforce = Vector2(222, 231)
	it.armour_mag_reinforce = Vector2(473, 492)
	return it

func _texts(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		out.append(String(l["text"]))
	return out

func _find(lines: Array, prefix: String) -> Dictionary:
	for l in lines:
		if String(l["text"]).begins_with(prefix):
			return l
	return {}

func _lines_tests() -> void:
	# --- the weapon, a store's reference item (variance 0, a price) ---
	var spear := L.compose(_spear(), {"type_name": "Spear", "price": 1000})
	var want := PackedStringArray([
		"Reaper Soul Spear", "", "Seal of Nova", "Sort of item: Spear", "Degree: 11 degrees", "",
		"Phy. atk. pwr. 1729 ~ 2059 (+0%)", "Mag. atk. pwr. 2964 ~ 3623 (+0%)",
		"Durability 85/85 (+0%)", "Attack distance 1.8 m", "Attack rate 120 (+0%)", "Critical 5 (+0%)",
		"Phy. reinforce 257.3 % ~ 306.3 % (+0%)", "Mag. reinforce 441.1 % ~ 539.1 % (+0%)",
		"", "Required level 111", "Chinese", "Max. no. of magic options: 9Unit",
		"Able to use Advanced elixir.", "Price : 1000Gold"])
	_check(_texts(spear) == want, "the weapon's lines in the binary's order, seal under the name (got %s)" % str(_texts(spear)))
	_check(spear[0]["color"] == L.GOLD and spear[0]["bold"] and spear[0]["icon"], "a seal item's name is gold, bold, with the icon")
	_check(spear[2]["color"] == L.GOLD and spear[2]["bold"], "the seal line is gold and bold")
	_check(spear[3]["color"] == L.BEIGE and spear[4]["color"] == L.BEIGE and spear[17]["color"] == L.BEIGE,
		"sort, degree and max magic options are beige")
	_check(spear[6]["color"] == L.WHITE and spear[15]["color"] == L.WHITE, "stats and an unknown player's requirements are white")
	_check(spear[18]["color"] == L.GREY and spear[18]["bold"], "'Able to use Advanced elixir.' is grey and bold (0xffc8c8c8)")
	var blanks := 0
	for l in spear:
		if String(l["text"]) == "":
			blanks += 1
	_check(blanks == 3, "three group breaks: after the name, after the degree, before the requirements -- none before a store's price (got %d)" % blanks)
	var flat := _spear()
	flat.mag_reinforce = Vector2i(4411, 4411)
	flat.max_magic_options = 0
	var ft := _texts(L.compose(flat, {"description": "A fortress hammer."}))
	_check(ft.has("Mag. reinforce 441.1 % ~ 441.1 % (+0%)"), "a weapon's reinforce keeps the range form with equal ends (the weapon pair decides)")
	_check(ft.has("Max. no. of magic options: 0Unit"), "max magic options shows at 0 too")
	_check(ft.slice(5, 8) == PackedStringArray(["", "A fortress hammer.", ""]), "the description (column 6) after the degree's blank, then a blank (got %s)" % str(ft.slice(5, 8)))

	# --- the empty range: 100 % (the original's "Critical 2 (+100%)") ---
	var even := _spear()
	even.critical = 2
	even.critical_upper = 2
	_check(_find(L.compose(even, {}), "Critical")["text"] == "Critical 2 (+100%)", "an empty range reads +100%")
	_check(L.quality(85, 85, 103) == 0 and L.quality(94, 85, 103) == 50 and L.quality(5, 5, 5) == 100,
		"quality: (v - L) / (U - L), 100 on an empty range")

	# --- an owned item: no instance yet -> no percentages but durability ---
	var owned := L.compose(_spear(), {"type_name": "Spear",
		"instance": {"unknown_variance": true, "durability": [92, 93]}})
	_check(_find(owned, "Phy. atk.")["text"] == "Phy. atk. pwr. 1729 ~ 2059", "an owned item without its variance shows no (+x%)")
	_check(_find(owned, "Durability")["text"] == "Durability 92/93", "its durability is the server's, with no invented percent (got %s)" % _find(owned, "Durability").get("text", ""))
	var known := L.compose(_spear(), {"instance": {"durability": [92, 93], "stats": {"dur_max": 93, "dur_q": 64}}})
	_check(_find(known, "Durability")["text"] == "Durability 92/93 (+64%)", "an instance's durability percent is lane B's q / 0.31")
	_check(L.range_quality(5, 5, 7, 7) == 100 and L.range_quality(5, 5, 7, 9) == 50 and L.range_quality(5, 6, 7, 9) == 0,
		"a min ~ max line averages its two ends (round 732)")
	_check(ItemTooltipInstance.available() or ItemTooltipInstance.fields(_spear(), RefCounted.new()).is_empty(),
		"without lane B's classes the instance adapter gives nothing")
	var broken := L.compose(_spear(), {"instance": {"durability": [0, 93]}})
	_check(_find(broken, "Durability")["color"] == L.RED, "a broken item's durability is red")

	# --- lane B's hook: plus, magic options, advanced elixir, given stats ---
	var rich := L.compose(_spear(), {"instance": {"plus": 5, "magic_options": ["Str 3 Increase"], "adv_elixir": 2,
		"stats": {"pa": [1800, 2100], "pa_q": 61}}})
	_check(rich[0]["text"] == "Reaper Soul Spear (+5)" and rich[0]["color"] == L.GOLD, "a plus shows as (+5); a seal stays gold")
	_check(_find(rich, "Phy. atk.")["text"] == "Phy. atk. pwr. 1800 ~ 2100 (+61%)", "given stats and quality win")
	_check(_find(rich, "Str 3")["color"] == L.CYAN, "magic options are cyan")
	_check(_find(rich, "2")["text"] == "2" and _find(rich, "2")["bold"], "advanced elixir used: the count, bold (no text table here)")
	var plain := _spear()
	plain.rarity = 0
	var blue := L.compose(plain, {"instance": {"magic_options": ["Str 3 Increase"]}})
	_check(blue[0]["color"] == L.CYAN and _find(blue, "Seal").is_empty(), "a non-seal item with magic options has a cyan name")
	_check(L.compose(plain, {})[0]["color"] == L.WHITE, "a plain item's name is white")

	# --- the accessory: the absorption lines the user's necklace lacked ---
	var neck := L.compose(_necklace(), {"type_name": "Necklace"})
	_check(_texts(neck).has("Phy. absorption 17.4 (+0%)") and _texts(neck).has("Mag. absorption 17.4 (+0%)"),
		"the necklace shows both absorptions (got %s)" % str(_texts(neck)))
	_check(_texts(neck).has("Seal of Star") and _texts(neck).has("Degree: 7 degrees") and _texts(neck).has("Max. no. of magic options: 9Unit"),
		"and its seal (class 19: Star), degree and magic option count")
	_check(_find(neck, "Phy. atk.").is_empty() and _find(neck, "Mounting").is_empty(), "no attack, no mounting part")

	# --- the armour: the set line (with its blank), the position, the requirements ---
	var player := {"level": 90, "str": 100, "int": 50, "gender": ItemTableReader.REQ_GENDER_WOMAN, "country": 1}
	var helm := L.compose(_helm(), {"type_name": "Heavy armor", "set_name": "Set A", "player": player,
		"text": func(k: String, f: String) -> String: return "Head" if k == "UIIT_STT_ARMOR_POSITION_HEAD" else f})
	var ht := _texts(helm)
	_check(ht.slice(0, 7) == PackedStringArray(["Set Helm", "", "", "Set A", "Sort of item: Heavy armor", "Mounting part: Head", "Degree: 11 degrees"]),
		"a set item: name, its blank, the set's own blank, the green set line, sort, mounting part, degree (got %s)" % str(ht.slice(0, 7)))
	_check(helm[3]["color"] == L.GREEN and helm[3]["bold"], "the set line is green and bold")
	_check(ht.has("Phy. reinforce 22.2 % (+0%)") and ht.has("Mag. reinforce 47.3 % (+0%)"),
		"armour shows its single-value reinforce lines from columns 82-85 (got %s)" % str(ht))
	var eu := _item([3, 1, 10, 1], "Light Hood")
	eu.country = 1
	eu.req_level_types = PackedInt32Array([0x201, 0x203, 0, 0])
	eu.req_levels = PackedInt32Array([1, 3, 0, 0])
	var eu_lines := L.compose(eu, {"player": {"masteries": {0x201: 0, 0x203: 5}}})
	_check(_texts(eu_lines).has("Mastery level: UIIT_STT_WARRIOR Mastery 1") and _texts(eu_lines).has("Mastery level: UIIT_STT_ROG Mastery 3"),
		"European gear shows its mastery requirements (got %s)" % str(_texts(eu_lines)))
	_check(_find(eu_lines, "Mastery level: UIIT_STT_WARRIOR")["color"] == L.WHITE, "one colour for the pairs: white when any is met")
	var eu_red := L.compose(eu, {"player": {"masteries": {0x201: 0}}})
	_check(_find(eu_red, "Mastery level: UIIT_STT_ROG")["color"] == L.RED and _find(eu_red, "Mastery level: UIIT_STT_WARRIOR")["color"] == L.RED,
		"and red, all of them, when none is")
	_check(ht.has("Phy. def. pwr. 274.1 (+0%)") and ht.has("Mag. def. pwr. 358.8 (+0%)") and ht.has("Parry rate 21 (+0%)"),
		"defences and parry, one value each")
	_check(_find(helm, "Required level")["color"] == L.RED, "level 101 against a level-90 player is red")
	_check(_find(helm, "Str")["color"] == L.RED, "Str 120 against 100 is red")
	_check(_find(helm, "Int")["text"] == "Int 120" and _find(helm, "Int")["color"] == L.WHITE,
		"the Int line prints the Str requirement (the binary's own slip in 0x67eec0) and is coloured by Int 40 against 50")
	_check(_find(helm, "Male")["color"] == L.RED and _find(helm, "Chinese")["color"] == L.RED,
		"a man's item and a Chinese item are red for a European woman")

	# --- the seal tiers ---
	var t := _spear()
	var tiers := []
	for cls in [1, 2, 3, 31, 32, 33]:
		t.item_class = cls
		tiers.append(L.seal_key(t))
	_check(tiers == ["PARAM_RARE_FIRST", "PARAM_RARE_SECOND", "PARAM_RARE_THIRD", "PARAM_RARE_FIRST2", "PARAM_RARE_SECOND", "PARAM_RARE_THIRD"],
		"seal tier (class - 1) mod 3, Nova from class 31 (got %s)" % str(tiers))
	t.item_class = 0
	_check(L.degree(t) == 0 and _find(L.compose(t, {}), "Degree").is_empty(), "no degree line at item class 0")

	# --- a potion: outside the four builders ---
	var pot := _item([3, 3, 1, 1], "HP Recovery Herb")
	var pl := L.compose(pot, {"type_name": "Potion", "price": 40})
	_check(_texts(pl) == PackedStringArray(["HP Recovery Herb", "", "Sort of item: Potion", "", "Price : 40Gold"]),
		"a potion: name, sort, price (got %s)" % str(_texts(pl)))
	_check(pl[0]["color"] == L.WHITE and pl[0]["icon"], "its name is white with the icon")

## A text file's bytes as the archive stores them: UTF-16LE with its BOM.
func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _type_name_tests() -> void:
	# Item names span both object-name files (ItemTableReader.load_object_names).
	var obj := UiTextTable.parse(_utf16("1\tSN_ITEM_CH_SPEAR\t?\t0\t0\t0\t0\t0\tSpear One\r\n"))
	var equip := UiTextTable.parse(_utf16("1\tSN_ITEM_EU_LIGHT_01_HA_A\t?\t0\t0\t0\t0\t0\tSagittarius Savage Sallet\r\n1\tSN_ITEM_CH_SPEAR\t?\t0\t0\t0\t0\t0\tOther\r\n"))
	obj.merge_missing(equip)
	var hood := _item([3, 1, 10, 1], "")
	hood.code_name = "ITEM_EU_W_LIGHT_01_HA_A"
	hood.name_strid = "SN_ITEM_EU_LIGHT_01_HA_A"
	_check(hood.display_name(obj) == "Sagittarius Savage Sallet" and obj.get_text("SN_ITEM_CH_SPEAR") == "Spear One",
		"an item named in textdata_equip&skill.txt resolves; a key already present is kept (got %s)" % hood.display_name(obj))
	_check(L.compose(hood, {"names": obj})[0]["text"] == "Sagittarius Savage Sallet", "and the tooltip shows it, not the code name")
	_check(ItemTableReader.OBJECT_NAME_PATHS.size() == 2, "both files the client's textdataname.txt lists")
	var groups := "﻿1\t3\t3\t1\t6\t4\r\n1\t10\t3\t1\t5\t2\r\n".to_utf16_buffer()
	var bom := PackedByteArray([0xFF, 0xFE])
	var cats := "1\tWK_CH_WEAPON\tUIIT_CTL_WK_CH_WEAPON\txxx\t0\t0\n1\tWK_CH_WEAPON_SPEAR\tUIIT_CTL_WK_CH_WEAPON_SPEAR\tWK_CH_WEAPON\t3\t11\n1\tWK_CH_ACCESSORY_NECKLACE\tUIIT_CTL_WK_CH_ACCESSORY_NECKLACE\tWK_CH_ACCESSORY\t10\t11\n".to_utf8_buffer()
	var n := ItemTypeNames.new()
	bom.append_array("1\t3\t3\t1\t6\t4\r\n1\t10\t3\t1\t5\t2\r\n".to_utf16_buffer())
	n.parse_types(bom, cats)
	_check(n.type_key(PackedInt32Array([3, 1, 6, 4])) == "UIIT_CTL_WK_CH_WEAPON_SPEAR"
		and n.type_key(PackedInt32Array([3, 1, 5, 2])) == "UIIT_CTL_WK_CH_ACCESSORY_NECKLACE",
		"TypeIDs -> group -> the category's key, UTF-16 and UTF-8 alike")
	_check(n.type_key(PackedInt32Array([3, 1, 6, 9])) == "" and groups.size() > 0, "an unmapped type has no key")
	n.parse_sets("1\t39\tITEM_11_SET_A_WEAPON\tx\tSN_ITEM_11_SET_A_WEAPON\txxx\n".to_utf8_buffer())
	_check(n.set_keys.get(39, "") == "SN_ITEM_11_SET_A_WEAPON", "refsetitemgroup: set id -> name key")
	n.parse_set_names("1\tSN_ITEM_11_SET_A_WEAPON\t??\t0\t0\t0\t0\t0\tPower\tPower\t0\n".to_utf8_buffer())
	_check(n.set_names.get(39, "") == "Power", "the set's name from the equip text table's English column")

func _bubble_tests() -> void:
	var holder := Control.new()
	holder.size = Vector2(1280, 720)
	root.add_child(holder)
	var b := ItemTooltipBubble.new(null)
	holder.add_child(b)
	var lines := L.compose(_spear(), {"type_name": "Spear", "price": 1000})
	b.show_lines(lines, Rect2(100, 50, 32, 32))
	var widest := 0.0
	for l in lines:
		widest = maxf(widest, b.text_width(l) + (b.icon_indent() if l["icon"] else 0.0))
	_check(b.size == Vector2(ceilf(widest) + 16, lines.size() * 18 + 16),
		"the window: the widest line plus the 8-px frame each side, 18 px a line (got %s, want %s)" % [b.size, Vector2(ceilf(widest) + 16, lines.size() * 18 + 16)])
	_check(b.position == ItemTooltipBubble.place(Rect2(100, 50, 32, 32), b.size, b.get_viewport_rect()),
		"placed by place() in the viewport (got %s)" % b.position)
	_check(ItemTooltipBubble.place(Rect2(100, 50, 32, 32), Vector2(200, 300), Rect2(0, 0, 1280, 720)) == Vector2(132, 50),
		"right of the slot, top aligned")
	var labels: Array = b.find_children("*", "Label", false, false)
	var shown := labels.filter(func(x): return x.visible)
	_check(shown.size() == lines.size(), "one label a line")
	var lab: Label = shown[3]
	var want_y := 8 + 3 * 18 + 12 - roundf(ThemeDB.fallback_font.get_ascent(12))
	_check(lab.position == Vector2(8, want_y) and lab.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"line 3's baseline 12 px below its top, whatever the face (got %s, want y %s), drawn crisp" % [lab.position, want_y])
	_check(lab.get_theme_constant("shadow_offset_x") == 1 and lab.get_theme_constant("shadow_offset_y") == 1
		and lab.get_theme_color("font_shadow_color") == Color(0, 0, 0), "a black drop shadow 1 px right and down")
	_check((shown[0] as Label).position.x == 8 + b.icon_indent() and b.icon_indent() > 12.0, "the name starts past the icon")
	_check(is_equal_approx(b.self_modulate.a, 200.0 / 255.0) and is_equal_approx(lab.modulate.a, 1.0),
		"the frame and fill at alpha 200/255, the text opaque")
	b.show_lines([lines[0]], Rect2(100, 50, 32, 32))
	_check(b.size.y == 14 + 16, "a one-line box is 14 px a line (got %s)" % b.size.y)
	_check(ItemTooltipBubble.place(Rect2(1250, 700, 32, 32), Vector2(200, 300), Rect2(0, 0, 1280, 720)) == Vector2(1050, 420),
		"kept on screen: left of the slot at the right edge, raised at the bottom")
	b.hide_bubble()
	_check(not b.visible and b.shown_lines().is_empty(), "hidden")
	holder.queue_free()
