extends SceneTree

## Round 786: the Test Items NPC's store shows each equipment good as the
## piece the buy gives -- OpNpcShopGoods (NpcShopDefNet.decode_goods) carries
## its instance, NpcShopDefNet.tabs puts it beside the good, and the store's
## tooltip (HudPanels.item_tip_lines, "store") reads it as an owned item's:
## "+12" in the name, the blue lines, every white stat at 100%. A good with
## no listed instance -- any retail store's -- stays the reference item.
## The bytes are the Go test's (session.TestShopGoodsPayloadBytes); the item
## is built in code (OURS fixture: invented columns, no game data).
##   godot4 --headless --path client --script res://scripts/ui/hud/store_listed_tip_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## server/internal/session/testshopgoods_test.go's payload, byte for byte:
## uid 0x7f000123, one entry -- item 901, +12, variance all 31, durability 0,
## options 72=7 and 90=160, the two empty binding blocks.
const GOLDEN := [
	0x23, 0x01, 0x00, 0x7f,
	1, 0,
	0x85, 0x03, 0, 0,
	0, 0, 0, 0,
	0x85, 0x03, 0, 0,
	12,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f,
	0, 0, 0, 0,
	2,
	72, 0, 0, 0, 7, 0, 0, 0,
	90, 0, 0, 0, 160, 0, 0, 0,
	1, 0, 2, 0,
]

## An unlocked Seal of Nova sword's shape (OURS fixture numbers).
func _sword(id: int) -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.id = id
	it.code_name = "ITEM_CH_SWORD_11_A_RARE_ACTIVE"
	it.item_name = "Test Sword"
	it.type_ids = PackedInt32Array([3, 1, 6, 2])
	it.req_level_types = PackedInt32Array([1, 0, 0, 0])
	it.req_levels = PackedInt32Array([101, 0, 0, 0])
	it.req_gender = ItemTableReader.REQ_GENDER_ANY
	it.country = 0
	it.plus_incs = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	it.rarity = 2
	it.item_class = 31
	it.durability = 100
	it.durability_max = 120
	it.phys_atk = Vector2i(1000, 1200)
	it.phys_atk_upper = Vector2i(1100, 1300)
	it.mag_atk = Vector2i(2000, 2400)
	it.mag_atk_upper = Vector2i(2200, 2600)
	it.attack_rate = 100
	it.attack_rate_upper = 200
	it.critical = 4
	it.critical_upper = 16
	it.max_magic_options = 9
	return it

func _stone(id: int) -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.id = id
	it.code_name = "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_11"
	it.item_name = "Test Stone"
	it.type_ids = PackedInt32Array([3, 3, 11, 1])
	it.req_level_types = PackedInt32Array([0, 0, 0, 0])
	it.req_levels = PackedInt32Array([0, 0, 0, 0])
	it.plus_incs = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	it.max_stack = 500
	return it

func _str(s: String) -> PackedByteArray:
	var b := PackedByteArray()
	var u := s.to_utf8_buffer()
	b.resize(2)
	b.encode_u16(0, u.size())
	b.append_array(u)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

## One line, one tab selling the sword (901), the stone (903) and a second
## sword (902) the goods message does not list.
func _def() -> Dictionary:
	var b := PackedByteArray()
	b.append_array(_u32(0x7f000123))
	b.append_array(_str("Hi"))
	b.append(1)
	b.append_array(_str("L"))
	b.append(1)
	b.append_array(_str("SN_TAB_WEAPON"))
	b.append_array(PackedByteArray([3, 0]))
	b.append_array(_u32(901))
	b.append_array(_u32(903))
	b.append_array(_u32(902))
	return NpcShopDefNet.decode(b)

func _texts(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		out.append(String((l as Dictionary)["text"]))
	return out

func _initialize() -> void:
	_decode_checks()
	_tip_checks()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _decode_checks() -> void:
	var golden := PackedByteArray(GOLDEN)
	var g := NpcShopDefNet.decode_goods(golden)
	_check(int(g.get("uid", 0)) == 0x7f000123, "the goods' uid (got %s)" % str(g.get("uid")))
	var insts: Dictionary = g.get("instances", {})
	_check(insts.size() == 1 and insts.has(901), "one listed instance, keyed by item id 901 (got %s)" % str(insts.keys()))
	var inst: ItemInstance = insts.get(901)
	if inst != null:
		_check(inst.ref_item_id == 901 and inst.opt_level == 12 and inst.effective_plus() == 12, "+12, item 901")
		var all31 := true
		for k in 12:
			all31 = all31 and inst.variance_group(k) == 31
		_check(all31, "every variance group at 31")
		_check(inst.option_count() == 2 and inst.option_id(0) == 72 and inst.option_value(0) == 7
			and inst.option_id(1) == 90 and inst.option_value(1) == 160, "the two blue options, 72=7 and 90=160")
	_check(NpcShopDefNet.decode_goods(golden.slice(0, golden.size() - 1)).is_empty(), "a truncated record decodes to {}")
	_check(NpcShopDefNet.decode_goods(golden.slice(0, 5)).is_empty(), "a short message decodes to {}")

	# The tabs carry the instance beside each code: the sword's, none for
	# the stone or the unlisted sword, none for an unknown id (skipped).
	var def := _def()
	_check(not def.is_empty(), "the definition decodes")
	NpcShopDefNet.merge_goods(def, g)
	var codes := {901: "ITEM_CH_SWORD_11_A_RARE_ACTIVE", 903: "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_11",
		902: "ITEM_CH_SWORD_11_A_RARE_ACTIVE_B"}
	var tabs := NpcShopDefNet.tabs(def, 0, func(id: int) -> String: return str(codes.get(id, "")))
	_check(tabs.size() == 1, "one tab")
	if tabs.size() == 1:
		var t: ShopReader.Tab = tabs[0]
		_check(t.instances.size() == t.item_codes.size() and t.item_codes.size() == 3, "instances run beside the codes")
		_check(t.instance_at(0) != null and (t.instance_at(0) as ItemInstance).opt_level == 12, "good 0 is listed +12")
		_check(t.instance_at(1) == null and t.instance_at(2) == null and t.instance_at(7) == null,
			"the stone, the unlisted sword and a slot past the end have none")
	# A retail tab (ShopReader) has none at all.
	_check(ShopReader.Tab.new().instance_at(0) == null, "a retail tab lists no instance")

func _tip_checks() -> void:
	var script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	if script == null or not script.can_instantiate():
		_check(false, "HudPanels compiles")
		return
	var p: Node = script.new()
	var def := _def()
	NpcShopDefNet.merge_goods(def, NpcShopDefNet.decode_goods(PackedByteArray(GOLDEN)))
	var codes := {901: "ITEM_CH_SWORD_11_A_RARE_ACTIVE", 903: "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_11",
		902: "ITEM_CH_SWORD_11_A_RARE_ACTIVE_B"}
	p.set("_items_loaded", true)
	p.set("_items", {901: _sword(901), 902: _sword(902), 903: _stone(903)})
	p.set("_shop_tabs", NpcShopDefNet.tabs(def, 0, func(id: int) -> String: return str(codes.get(id, ""))))
	p.set("_shop_selected", 0)

	# The listed sword, slot 0, free.
	var lines: Array = p.call("item_tip_lines", 901, "store", 0, -1, -1, 0)
	var text := _texts(lines)
	print("listed: " + " | ".join(text))
	_check(text.size() > 0 and text[0].ends_with("(+12)"), "the name reads \"(+12)\" (got %s)" % (text[0] if text.size() > 0 else ""))
	var blue := 0
	for l in lines:
		if (l as Dictionary)["color"] == ItemTooltipLines.CYAN and not bool((l as Dictionary)["bold"]):
			blue += 1
	_check(blue == 2, "two blue lines, one per option (got %d)" % blue)
	var stats := 0
	var full := 0
	for s in text:
		if s.begins_with("Phy. atk. pwr.") or s.begins_with("Mag. atk. pwr.") or s.begins_with("Attack rate") \
				or s.begins_with("Critical"):
			stats += 1
			if s.ends_with("(+100%)"):
				full += 1
	_check(stats == 4 and full == 4, "every white stat at (+100%%) (%d of %d)" % [full, stats])
	var phys := ""
	for s in text:
		if s.begins_with("Phy. atk. pwr."):
			phys = s
	_check(phys.begins_with("Phy. atk. pwr. 1100 ~ 1300"), "the attack is the variance's top, 1100 ~ 1300 (got %s)" % phys)

	# The unlisted sword, slot 2: the reference item, as any retail good.
	var ref_text := _texts(p.call("item_tip_lines", 902, "store", 2, -1, -1, 0))
	print("reference: " + " | ".join(ref_text))
	_check(ref_text.size() > 0 and not ref_text[0].contains("(+"), "an unlisted good has no plus in its name")
	var ref_phys := ""
	for s in ref_text:
		if s.begins_with("Phy. atk. pwr."):
			ref_phys = s
	_check(ref_phys == "Phy. atk. pwr. 1000 ~ 1200 (+0%)", "an unlisted good reads variance 0 (got %s)" % ref_phys)

	# A retail tab (no instances) is unchanged.
	var retail := ShopReader.Tab.new()
	retail.item_codes = PackedStringArray(["ITEM_CH_SWORD_11_A_RARE_ACTIVE"])
	p.set("_shop_tabs", [retail])
	var retail_text := _texts(p.call("item_tip_lines", 901, "store", 0, -1, -1, 1000))
	_check(retail_text.size() > 0 and not retail_text[0].contains("(+"), "a retail store's good is the reference item")
	p.free()
