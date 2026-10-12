extends SceneTree

## Round 783: OpNpcShopDef (NpcShopDefNet) -- the Test Items NPC's store
## lines, tabs and goods as the server sends them -- decoded from the bytes
## server/internal/testnpc's TestEncodeDecode pins, turned into the talk
## menu's store lines (through NpcServiceReader.services_from_ids, as a retail
## NPC's are) and into the store window's tabs. Synthetic ids and labels; no
## game data.
##   godot4 --headless --path client --script res://scripts/net/npc_shop_def_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _str(s: String) -> PackedByteArray:
	var b := PackedByteArray()
	var u := s.to_utf8_buffer()
	b.resize(2)
	b.encode_u16(0, u.size())
	b.append_array(u)
	return b

func _u16(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, v)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _init() -> void:
	# The Go test's golden message, byte for byte.
	var golden := PackedByteArray([
		0x23, 0x01, 0x00, 0x7f,
		2, 0, 0x48, 0x69,
		1,
		1, 0, 0x4c,
		1,
		13, 0, 0x53, 0x4e, 0x5f, 0x54, 0x41, 0x42, 0x5f, 0x57, 0x45, 0x41, 0x50, 0x4f, 0x4e,
		2, 0, 0xcc, 0x0f, 0, 0, 0x04, 0x03, 0x02, 0x01,
	])
	var g := NpcShopDefNet.decode(golden)
	_check(int(g.get("uid", 0)) == 0x7f000123, "the uid (got %s)" % str(g.get("uid")))
	_check(str(g.get("greeting", "")) == "Hi", "the greeting")
	var glines: Array = g.get("lines", [])
	_check(glines.size() == 1 and str(glines[0]["label"]) == "L", "one line, its label")
	if glines.size() == 1:
		var gtab: Dictionary = (glines[0]["tabs"] as Array)[0]
		_check(str(gtab["label"]) == "SN_TAB_WEAPON", "the tab's label is the retail tab key")
		_check(gtab["ids"] == PackedInt32Array([4044, 0x01020304]), "the tab's goods (got %s)" % str(gtab["ids"]))
	_check(NpcShopDefNet.decode(golden.slice(0, golden.size() - 1)).is_empty(), "a truncated message decodes to {}")
	var longer := golden.duplicate()
	longer.append(0)
	_check(NpcShopDefNet.decode(longer).is_empty(), "a trailing byte decodes to {}")

	# A two-line definition: the alchemy line with two tabs, a weapons line.
	var b := PackedByteArray()
	b.append_array(_u32(0x7f000150))
	b.append_array(_str("Every 11th degree item."))
	b.append(2)
	b.append_array(_str("Purchase 11th Degree Elixirs and Alchemy Stones"))
	b.append(2)
	b.append_array(_str("Elixir"))
	b.append_array(_u16(2))
	b.append_array(_u32(10))
	b.append_array(_u32(11))
	b.append_array(_str("Magic"))
	b.append_array(_u16(1))
	b.append_array(_u32(12))
	b.append_array(_str("Purchase Chinese Seal of Nova Weapons and Accessories"))
	b.append(1)
	b.append_array(_str("SN_TAB_WEAPON"))
	b.append_array(_u16(2))
	b.append_array(_u32(20))
	b.append_array(_u32(99)) # an id the client's table does not know
	var def := NpcShopDefNet.decode(b)
	_check(not def.is_empty(), "the two-line definition decodes")

	# The talk menu: one store line per definition line, in order, keyed
	# custom:<i>, worded by the label (ids {1}; the end line is the view's).
	var lines := NpcShopDefNet.store_lines(def)
	_check(lines.size() == 2 and str(lines[0]["tabgroup"]) == "custom:0" and str(lines[1]["tabgroup"]) == "custom:1",
		"store lines custom:0, custom:1 (got %s)" % str(lines))
	var services: Array = NpcServiceReader.services_from_ids(PackedByteArray([1]), lines)
	var keys: Array = []
	for s in services:
		keys.append((s as NpcServiceReader.Service).key)
	_check(keys.size() == 2 and keys[0] == "shop:custom:0" and keys[1] == "shop:custom:1",
		"the menu is the two store lines (got %s)" % str(keys))
	_check((services[0] as NpcServiceReader.Service).strid == "Purchase 11th Degree Elixirs and Alchemy Stones",
		"a store line carries its label as its text key")
	_check(NpcShopDefNet.line_of(NpcServiceReader.tabgroup_of("shop:custom:1")) == 1, "the key names line 1")
	_check(NpcShopDefNet.line_of("STORE_CH_POTION_GROUP1") == -1, "a retail tab group is not a definition line")

	# The store tabs: labels kept, ids turned into code names, unknown ids
	# skipped.
	var codes := {10: "ITEM_ETC_ARCHEMY_REINFORCE_PROB_UP_A_11", 11: "ITEM_ETC_ARCHEMY_REINFORCE_PROB_UP_B_11",
		12: "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_11", 20: "ITEM_CH_SWORD_11_A_RARE"}
	var code_of := func(id: int) -> String: return str(codes.get(id, ""))
	var tabs0 := NpcShopDefNet.tabs(def, 0, code_of)
	_check(tabs0.size() == 2, "line 0 has two tabs")
	if tabs0.size() == 2:
		var t0: ShopReader.Tab = tabs0[0]
		_check(t0.name_strid == "Elixir" and t0.item_codes == PackedStringArray(["ITEM_ETC_ARCHEMY_REINFORCE_PROB_UP_A_11",
			"ITEM_ETC_ARCHEMY_REINFORCE_PROB_UP_B_11"]), "the Elixir tab's goods, in order")
		_check((tabs0[1] as ShopReader.Tab).item_codes.size() == 1, "the Magic tab's one good")
	var tabs1 := NpcShopDefNet.tabs(def, 1, code_of)
	_check(tabs1.size() == 1 and (tabs1[0] as ShopReader.Tab).name_strid == "SN_TAB_WEAPON"
		and (tabs1[0] as ShopReader.Tab).item_codes == PackedStringArray(["ITEM_CH_SWORD_11_A_RARE"]),
		"the weapons tab keeps its key and skips the unknown id")
	_check(NpcShopDefNet.tabs(def, 2, code_of).is_empty(), "a line the definition lacks has no tabs")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % _failures)
	quit(_failures)
