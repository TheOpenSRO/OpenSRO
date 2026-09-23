extends SceneTree

## Exercises NpcServiceReader against synthetic rows shaped like the real
## refshopgroup.txt / npcchat.txt / textuisystem.txt (never real game data):
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

	# Round 513: the talk lines carry the client's own UIIT string ids. The
	# constants are read through the script's constant map, and `strid`
	# through get(), so that a reader without them FAILS here rather than
	# failing to parse.
	var consts := (load("res://scripts/npc/npc_service_reader.gd") as Script).get_script_constant_map()
	# (a) The warehouse's storage line is the client's item 3: FUN_006fcd60
	# case 3, emitted by FUN_00700440 for interaction id 3 (0x700b73
	# `push 0; push 3; ... call 0x6fcd60`).
	var wh_storage: Variant = null
	for s in NpcServiceReader.services_for("NPC_CH_WAREHOUSE_M", shops):
		if s.key == "storage":
			wh_storage = s
	_check(wh_storage != null and str(wh_storage.get("strid")) == "UIIT_STT_NPC_CHATTING_WND_STOREHOUSE"
			and str(consts.get("STOREHOUSE_STRID", "")) == "UIIT_STT_NPC_CHATTING_WND_STOREHOUSE",
		"the warehouse storage line's strid is UIIT_STT_NPC_CHATTING_WND_STOREHOUSE (got %s)"
			% [wh_storage.get("strid") if wh_storage != null else "no storage service"])
	_check(wh_storage != null and wh_storage.label == "Storage",
		"the storage line keeps \"Storage\" as its fallback label")
	# (e) The shop line has no single token in the client (item 1 is
	# FUN_006fb630's per-store lines, not built), so it stays "Buy".
	var smith_shop: Variant = smith[0] if smith.size() > 0 else null
	_check(smith_shop != null and str(smith_shop.get("strid")) == "" and smith_shop.label == "Buy",
		"the smith's shop line has an empty strid and the label \"Buy\" (got strid %s)"
			% [smith_shop.get("strid") if smith_shop != null else "no shop service"])
	# (f) The end line is the client's item 0: FUN_006fcd60 case 0, .rdata
	# 0xdadd28. TALKEND2 (0xdadd70) is chosen only for an NPC holding id
	# 0x1f, the siege pulley, so it is not carried.
	_check(str(consts.get("TALKEND_STRID", "")) == "UIIT_STT_NPC_CHATTING_WND_TALKEND",
		"TALKEND_STRID is exactly UIIT_STT_NPC_CHATTING_WND_TALKEND (got %s)" % [consts.get("TALKEND_STRID")])
	_check(not consts.has("TALKEND2_STRID"), "no TALKEND2 constant (pulley-only, id 0x1f)")
	# (g) textuisystem.txt holds STOREHOUSE twice, in two layouts: a 16-column
	# row with the English at [8], and later a 19-column row with "0" at [8]
	# and the English at [9]. The later row wins, which is why the player's
	# archive shows "Deposit into storage." rather than the earlier row's text.
	var a16 := PackedStringArray()
	a16.resize(16)
	a16.fill("0")
	a16[0] = "1"
	a16[1] = "UIIT_STT_NPC_CHATTING_WND_STOREHOUSE"
	a16[8] = "LAYOUT-A"
	var b19 := PackedStringArray()
	b19.resize(19)
	b19.fill("0")
	b19[0] = "1"
	b19[1] = "UIIT_STT_NPC_CHATTING_WND_STOREHOUSE"
	b19[9] = "LAYOUT-B"
	var ui_rows := "\t".join(a16) + "\n" + "\t".join(b19) + "\n"
	var ui := UiTextTable.parse(ui_rows.to_utf16_buffer())
	_check(ui.get_text("UIIT_STT_NPC_CHATTING_WND_STOREHOUSE") == "LAYOUT-B",
		"the later 19-column STOREHOUSE row wins (got %s)" % ui.get_text("UIIT_STT_NPC_CHATTING_WND_STOREHOUSE"))

	# (h) The composition a warehouse keeper really gets. The player's
	# refshopgroup.txt lists 8 of the 9 keepers npcpos spawns as running a
	# store: col 3 GROUP_STORE_*_HONOR, col 4 NPC_*_WAREHOUSE* (measured round
	# 513 with client/tools/dump_text_table.gd on the render box's Media.pk2,
	# --grep=WAREHOUSE: 9 rows, CH _M/_W, WC _W twice, KT, EU, CA and both SD
	# keepers; NPC_WC_WAREHOUSE_M, which npcpos also spawns, is in no row and
	# gets storage only). So a listed
	# keeper has the shop service AND storage, shop first, and the talk box
	# numbers the end line 3, not 2. The shop set above leaves the warehouse
	# out, which is why (a) alone never showed this. The id column is not read,
	# so it is 0 here.
	var wh_shops := NpcServiceReader.parse_shop_npcs(("\n".join(PackedStringArray([
		"//Service\tCountry\tID\tCodeName\tOwnerNPC",
		"1\t15\t0\tGROUP_STORE_CH_HONOR\tNPC_CH_WAREHOUSE_M",
	])) + "\n").to_utf16_buffer())
	var wh_m := NpcServiceReader.services_for("NPC_CH_WAREHOUSE_M", wh_shops)
	var wh_m_keys: Array = wh_m.map(func(s): return s.key)
	_check(wh_m_keys == ["shop", "storage"],
		"a warehouse keeper in refshopgroup offers [shop, storage] in that order (got %s)" % [wh_m_keys])
	# The talk box's own lines for that composition, from the same composer
	# the talk window calls (talk_menu_lines), against a synthetic text table
	# (19-column rows, text at [9]). The resolver passed in has the same rules
	# as HudPanels._resolve_ui: an empty token, or no text for it, gives the
	# fallback. The HUD itself cannot be loaded here: it needs the NetClient
	# autoload. The composer is reached through the script object, so a reader
	# without it FAILS this check rather than failing to parse, which would
	# hang the suite.
	var ui_tokens := {
		"UIIT_STT_NPC_CHATTING_WND_STOREHOUSE": "STORE-TEXT",
		"UIIT_STT_NPC_CHATTING_WND_TALKEND": "END-TEXT",
	}
	var ui2_rows := ""
	for token in ui_tokens:
		var row := PackedStringArray()
		row.resize(19)
		row.fill("0")
		row[0] = "1"
		row[1] = token
		row[9] = ui_tokens[token]
		ui2_rows += "\t".join(row) + "\n"
	var ui2 := UiTextTable.parse(ui2_rows.to_utf16_buffer())
	var resolve := func(token: String, fallback: String) -> String:
		var t := ui2.get_text(token) if token != "" else ""
		return t if t != "" and t != token else fallback
	var reader_script := load("res://scripts/npc/npc_service_reader.gd") as Script
	var has_composer := false
	for m in reader_script.get_script_method_list():
		if str(m.get("name", "")) == "talk_menu_lines":
			has_composer = true
	var menu := PackedStringArray()
	if has_composer:
		menu = reader_script.call("talk_menu_lines", "NPC_CH_WAREHOUSE_M", wh_m, resolve)
	var want_menu := PackedStringArray([
		"[url=shop]1. Buy[/url]",
		"[url=storage]2. STORE-TEXT[/url]",
		"[url=end]3. END-TEXT[/url]",
	])
	_check(menu == want_menu,
		"the warehouse keeper's talk menu is 1. Buy / 2. storage text / 3. end text (got %s)" % [menu])
	# The exception: a keeper refshopgroup does NOT list -- NPC_WC_WAREHOUSE_M,
	# whose town's second HONOR row names NPC_WC_WAREHOUSE_W again -- runs no
	# store, so its menu is storage and the end line only, numbered 1 and 2.
	var wc_shops := NpcServiceReader.parse_shop_npcs(("\n".join(PackedStringArray([
		"//Service\tCountry\tID\tCodeName\tOwnerNPC",
		"1\t15\t0\tGROUP_STORE_WC_HONOR\tNPC_WC_WAREHOUSE_W",
		"1\t15\t0\tGROUP_STORE_WC_HONOR2\tNPC_WC_WAREHOUSE_W",
	])) + "\n").to_utf16_buffer())
	var wc_m := NpcServiceReader.services_for("NPC_WC_WAREHOUSE_M", wc_shops)
	var wc_m_keys: Array = wc_m.map(func(s): return s.key)
	_check(wc_m_keys == ["storage"],
		"a keeper refshopgroup does not list (NPC_WC_WAREHOUSE_M) offers storage only (got %s)" % [wc_m_keys])
	var wc_menu := PackedStringArray()
	if has_composer:
		wc_menu = reader_script.call("talk_menu_lines", "NPC_WC_WAREHOUSE_M", wc_m, resolve)
	_check(wc_menu == PackedStringArray(["[url=storage]1. STORE-TEXT[/url]", "[url=end]2. END-TEXT[/url]"]),
		"and its talk menu is 1. storage text / 2. end text (got %s)" % [wc_menu])
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
