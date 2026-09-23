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

	# services_for: shop from the set; storage from a WAREHOUSE codename.
	# A town smith lists the shop and nothing else (round 512): the client's
	# talk-menu builder FUN_00700440 adds no item for the smith's interaction 4
	# (LAB_00700b10 has no membership branch), and FUN_006fcd60 has no repair
	# label. Repair is the store window's GDR_STORE_BTN_REPAIR/REPAIRALL.
	var smith := NpcServiceReader.services_for("NPC_CH_SMITH", shops)
	var keys := smith.map(func(s): return s.key)
	_check(keys == ["shop"], "NPC_CH_SMITH offers exactly [\"shop\"] (got %s)" % [keys])
	for town_smith in ["NPC_WC_SMITH", "NPC_KT_SMITH", "NPC_EU_SMITH",
			"NPC_CA_SMITH", "NPC_SD_M_AREA_SMITH"]:
		var ts = NpcServiceReader.services_for(town_smith, shops)
		_check(not ts.map(func(s): return s.key).has("repair"),
			town_smith + " lists no repair talk line (interaction 4 adds no item in FUN_00700440)")
	# The fortress smith's real SN_FORTRESS_SMITH_REPAIR line comes from
	# interaction 0x1a (FUN_00700200 -> IF_NPCTalk::FUN_006fe030 case 0x36),
	# a fortress system srrevamp does not have -- deliberately not offered.
	var fs := NpcServiceReader.services_for("NPC_KT_FORTRESS_SMITH", shops)
	_check(not fs.map(func(s): return s.key).has("repair"),
		"NPC_KT_FORTRESS_SMITH offers no repair (its real line is interaction 0x1a, fortress only)")
	# Armour merchants get no repair talk line either; no NPC does. Id 4 has no
	# reader on the server (round 458). The client reader found in review,
	# 0x88b8c5 in FUN_0088b200, shows the store window's repair buttons, not a
	# talk line.
	var armor := NpcServiceReader.services_for("NPC_CH_ARMOR", shops)
	_check(not armor.map(func(s): return s.key).has("repair"),
		"NPC_CH_ARMOR offers no repair talk line (id 4 reads only as the store's buttons)")
	var wh := NpcServiceReader.services_for("NPC_CH_WAREHOUSE", shops)
	_check(wh.map(func(s): return s.key).has("storage"), "a warehouse offers storage")
	var plain := NpcServiceReader.services_for("NPC_CH_FISHERMAN", shops)
	_check(plain.is_empty(), "an NPC with no shop/keyword offers no listed service")

	# Guild: the server's own seven patterns, not a bare "GUILD" token
	# (CGObjNPCNPC::Create registers interaction 0x0f on exactly these).
	for guild_npc in ["NPC_CH_GENARAL_SP", "NPC_WC_GUILD", "NPC_KT_GUILD",
			"NPC_EU_GUILD", "NPC_CA_GUILD", "NPC_SD_M_AREA_GUILD",
			"NPC_SD_T_AREA_GUILD2"]:
		var g = NpcServiceReader.services_for(guild_npc, shops)
		_check(g.map(func(s): return s.key).has("guild"), guild_npc + " offers guild")

	# The two defects a bare "GUILD" token had. NPC_CH_GENARAL_SP is covered
	# above -- it has no "GUILD" in its name and used to be MISSED.
	for agent in ["NPC_SD_GUILD_AGENT", "NPC_SD_GUILD_AGENT2", "NPC_SD_GUILD_AGENT3"]:
		var a = NpcServiceReader.services_for(agent, shops)
		_check(not a.map(func(s): return s.key).has("guild"),
			agent + " is specialty goods (0x0c), not a guild NPC")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
