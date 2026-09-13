extends SceneTree

## Exercises NpcServiceReader against synthetic rows shaped like the real
## refshopgroup.txt / npcchat.txt (never real game data):
##   godot4 --headless --path client --script res://scripts/npc/npc_service_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	# refshopgroup: col 4 is the NPC codename that runs the shop group.
	var shop_rows := PackedStringArray([
		"//Service\tCountry\tID\tCodeName\tOwnerNPC",
		"1\t15\t978\tGROUP_STORE_CH_SMITH\tNPC_CH_SMITH",
		"1\t15\t981\tGROUP_STORE_CH_POTION\tNPC_CH_POTION",
	])
	var shops := NpcServiceReader.parse_shop_npcs(("\n".join(shop_rows) + "\n").to_utf16_buffer())
	_check(shops.has("NPC_CH_SMITH") and shops.has("NPC_CH_POTION"), "shop NPCs parsed from col 4")
	_check(not shops.has("GROUP_STORE_CH_SMITH"), "the group code is not mistaken for an NPC")

	# npcchat: codename + two greeting string ids.
	var chat_rows := PackedStringArray([
		"//Service\tOwnerCodeName\tmsg1\tmsg2",
		"1\tNPC_CH_SMITH\tSN_NPC_CH_SMITH_BS\tSN_NPC_CH_SMITH_PS",
	])
	var greet := NpcServiceReader.parse_greetings(("\n".join(chat_rows) + "\n").to_utf16_buffer())
	_check(greet.get("NPC_CH_SMITH", [])[0] == "SN_NPC_CH_SMITH_BS", "greeting msg1 id parsed")

	# services_for: shop from the set; repair from the SMITH codename; storage
	# from a WAREHOUSE codename.
	var smith := NpcServiceReader.services_for("NPC_CH_SMITH", shops)
	var keys := smith.map(func(s): return s.key)
	_check(keys.has("shop") and keys.has("repair"), "a smith offers shop + repair")
	var wh := NpcServiceReader.services_for("NPC_CH_WAREHOUSE", shops)
	_check(wh.map(func(s): return s.key).has("storage"), "a warehouse offers storage")
	var plain := NpcServiceReader.services_for("NPC_CH_FISHERMAN", shops)
	_check(plain.is_empty(), "an NPC with no shop/keyword offers no listed service")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
