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

## The services' stable keys, in order.
func _keys(services: Array) -> Array:
	return services.map(func(s): return s.key)

## The service with this key, or null.
func _find(services: Array, key: String) -> Variant:
	for s in services:
		if s.key == key:
			return s
	return null

## One mouse button event at a viewport point, through the live viewport the
## way the OS delivers it (Viewport.push_input: _input, the GUI, then
## _unhandled_input). Check (o).
func _push_button(at: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	root.push_input(ev, true)

## Whether the recorder's _unhandled_input saw a button event since its list
## was last cleared: a press when `pressed`, else a release.
func _recorded_button(recorder: Node, pressed: bool) -> bool:
	for e in recorder.get("unhandled"):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed == pressed:
			return true
	return false

## A press and its release at a point; true when the press reached
## _unhandled_input, which is where World3D reads a click on the world.
func _click_reaches_world(recorder: Node, at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> bool:
	(recorder.get("unhandled") as Array).clear()
	_push_button(at, button, true)
	_push_button(at, button, false)
	return _recorded_button(recorder, true)

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
		"1\tSTORE_CH_GATE\tSTORE_CH_GATE_BS\tSTORE_CH_GATE_PS",
	])
	var greet := NpcServiceReader.parse_greetings(("\n".join(chat_rows) + "\n").to_utf16_buffer())
	_check(greet.get("NPC_CH_SMITH", [])[0] == "SN_NPC_CH_SMITH_BS", "greeting msg1 id parsed")
	_check(greet.get("STORE_CH_GATE", [""])[0] == "STORE_CH_GATE_BS", "a gate's greeting row is kept (round 725)")

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
	# a fortress system OpenSRO does not have -- deliberately not offered.
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
	# and the English at [9]. Since round 634's review the FIRST row wins, as
	# the client's loader keeps it (TextStringManager 0x8cac30 -> 0x8ca120's
	# insert returns the existing entry): the box's archive now reads
	# "Deposit items/gold into storage." where it read "Deposit into storage.".
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
	_check(ui.get_text("UIIT_STT_NPC_CHATTING_WND_STOREHOUSE") == "LAYOUT-A",
		"the first (16-column) STOREHOUSE row wins (got %s)" % ui.get_text("UIIT_STT_NPC_CHATTING_WND_STOREHOUSE"))

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
	# fallback. The HUD itself cannot be loaded here in _init: hud_panels.gd
	# compiles only once the NetClient autoload is registered, which is why
	# check (j) runs in _initialize. The composer is reached through the
	# script object, so a reader without it FAILS this check rather than
	# failing to parse, which would hang the suite.
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
	# above -- it has no "GUILD" in its name and used to be MISSED. The three
	# agents were wrongly MATCHED. No codename test in CGObjNPCNPC::Create
	# registers an interaction id on them: their strstr chain ends in
	# IGObj::SetBodyMode (slot 198, 0x4c6ddd), not AddAvailableInteraction
	# (slot 89). Round 520 corrected round 458's "specialty goods (0x0c)"; see
	# GUILD_PATTERNS.
	for agent in ["NPC_SD_GUILD_AGENT", "NPC_SD_GUILD_AGENT2", "NPC_SD_GUILD_AGENT3"]:
		var a = NpcServiceReader.services_for(agent, shops)
		_check(not a.map(func(s): return s.key).has("guild"),
			agent + " gets no interaction id by codename, so offers no Guild")

	# (k) Round 521: the guild NPC's lines follow the player's guild state, as
	# the client's FUN_00700440 id 0x0f block does: FUN_009870e0() == 0 ->
	# item 0x12 UIIT_CTL_GUILD_CREATE; else FUN_00989ce0(name) == 0 -> item
	# 0x1c UIIT_CTL_GUILD_SECESSION; else the master's items, which have no
	# server here, so a master keeps the placeholder. The new arguments and
	# guild_services are reached through the script object after checking the
	# method list, so a reader without them FAILS here rather than raising a
	# call error that stops _init and hangs the suite.
	var sf_args := -1
	var has_guild_services := false
	for m in reader_script.get_script_method_list():
		if str(m.get("name", "")) == "services_for":
			sf_args = (m.get("args", []) as Array).size()
		if str(m.get("name", "")) == "guild_services":
			has_guild_services = true
	var stateful := sf_args >= 4
	_check(stateful, "services_for takes the guild state (got %d argument(s))" % sf_args)
	_check(sf_args == 6, "services_for's signature is (code, shops, guild_id, guild_master, player_job_kind, store_lines) (got %d)" % sf_args)
	_check(has_guild_services, "NpcServiceReader has guild_services")
	# Unknown state: the 2-argument calls above already showed "guild" for all
	# seven patterns. Passing -1 explicitly is the same.
	if stateful:
		var unknown: Array = reader_script.call("services_for", "NPC_WC_GUILD", shops, -1, false)
		_check(_keys(unknown) == ["guild"], "guild_id -1 (unknown) keeps the \"guild\" placeholder (got %s)" % [_keys(unknown)])
	# NEGATIVE (fails before round 521): a guildless player at the Chinese
	# guild NPC gets the create line, with its UIIT token, and no placeholder.
	var none: Array = []
	if stateful:
		none = reader_script.call("services_for", "NPC_CH_GENARAL_SP", shops, 0, false)
	var create: Variant = _find(none, "guild_create")
	_check(create != null, "a guildless player at NPC_CH_GENARAL_SP has guild_create (got %s)" % [_keys(none)])
	_check(create != null and str(create.get("strid")) == "UIIT_CTL_GUILD_CREATE"
			and str(consts.get("GUILD_CREATE_STRID", "")) == "UIIT_CTL_GUILD_CREATE",
		"guild_create's strid is UIIT_CTL_GUILD_CREATE (FUN_006fcd60 case 0x12)")
	_check(not _keys(none).has("guild"), "and no \"guild\" placeholder (got %s)" % [_keys(none)])
	# A member who is not the master gets exactly the leave line.
	var member: Array = []
	if stateful:
		member = reader_script.call("services_for", "NPC_WC_GUILD", shops, 7, false)
	_check(_keys(member) == ["guild_leave"], "a member at NPC_WC_GUILD gets exactly [\"guild_leave\"] (got %s)" % [_keys(member)])
	var leave: Variant = _find(member, "guild_leave")
	_check(leave != null and str(leave.get("strid")) == "UIIT_CTL_GUILD_SECESSION"
			and str(consts.get("GUILD_SECESSION_STRID", "")) == "UIIT_CTL_GUILD_SECESSION",
		"guild_leave's strid is UIIT_CTL_GUILD_SECESSION (FUN_006fcd60 case 0x1c)")
	# NEGATIVE: the master is never offered secession (the 0x1c push is only
	# in FUN_00989ce0's zero branch) nor creation; it keeps the placeholder.
	var master: Array = []
	if stateful:
		master = reader_script.call("services_for", "NPC_WC_GUILD", shops, 7, true)
	_check(stateful and not _keys(master).has("guild_leave") and not _keys(master).has("guild_create"),
		"a master at NPC_WC_GUILD has neither guild_leave nor guild_create (got %s)" % [_keys(master)])
	_check(stateful and _keys(master) == ["guild"], "the master keeps the \"guild\" placeholder (got %s)" % [_keys(master)])
	# The guild agents register no id by codename (round 520), so a known
	# guild state adds nothing there either.
	for agent in ["NPC_SD_GUILD_AGENT", "NPC_SD_GUILD_AGENT2", "NPC_SD_GUILD_AGENT3"]:
		for state in [[0, false], [7, false], [7, true]]:
			var ag: Array = []
			if stateful:
				ag = reader_script.call("services_for", agent, shops, state[0], state[1])
			var guildish := _keys(ag).filter(func(k): return str(k).begins_with("guild"))
			_check(stateful and guildish.is_empty(),
				"%s with guild state %s offers no guild* line (got %s)" % [agent, state, _keys(ag)])
	# The fallback labels are the archive's own text for the two tokens.
	var gs0: Array = []
	var gs7: Array = []
	if has_guild_services:
		gs0 = reader_script.call("guild_services", 0, false)
		gs7 = reader_script.call("guild_services", 7, false)
	_check(gs0.size() == 1 and gs0[0].label == "Create a new guild",
		"guild_services(0, false)[0].label == \"Create a new guild\"")
	_check(gs7.size() == 1 and gs7[0].label == "Leave guild.",
		"guild_services(7, false)[0].label == \"Leave guild.\"")
	# The talk menu a guildless player sees, from the same composer: the
	# create line, resolved through the text table, then the end line.
	if stateful and has_composer:
		var ui3 := {"UIIT_CTL_GUILD_CREATE": "CREATE-TEXT", "UIIT_STT_NPC_CHATTING_WND_TALKEND": "END-TEXT"}
		var resolve3 := func(token: String, fallback: String) -> String:
			return str(ui3.get(token, fallback)) if token != "" else fallback
		var gmenu: PackedStringArray = reader_script.call("talk_menu_lines", "NPC_CH_GENARAL_SP", none, resolve3)
		_check(gmenu == PackedStringArray(["[url=guild_create]1. CREATE-TEXT[/url]", "[url=end]2. END-TEXT[/url]"]),
			"a guildless player's NPC_CH_GENARAL_SP menu is 1. create text / 2. end text (got %s)" % [gmenu])
	else:
		_check(false, "the guildless talk menu could not be composed (services_for stateful=%s, composer=%s)" % [stateful, has_composer])

	# (o) Round 524: a guild NPC's store line only for a player in a guild.
	# The server registers id 1 beside 0x0f on all seven GUILD_PATTERNS
	# (CGObjNPCNPC::Create 0x4c6a4f), and with 0x0f present the client's
	# FUN_00700440 emits item 1 (the store lines) only when FUN_009870e0
	# answers nonzero (0x7009fc `call 0x9870e0`, 0x700a03 `je 0x700b10`). The
	# shop set here is shaped like the player's refshopgroup.txt, which names
	# all seven as running a GROUP_STORE_*_GUILD store (col 4 is the owner;
	# the id column is not read, so it is 0), plus a potion seller. The shop
	# set in (k) leaves the guild NPCs out, which is why (k) never showed "Buy"
	# at them.
	var guild_shop_rows := PackedStringArray(["//Service\tCountry\tID\tCodeName\tOwnerNPC"])
	for pair in [["CH", "NPC_CH_GENARAL_SP"], ["WC", "NPC_WC_GUILD"], ["KT", "NPC_KT_GUILD"],
			["EU", "NPC_EU_GUILD"], ["CA", "NPC_CA_GUILD"], ["SD_M", "NPC_SD_M_AREA_GUILD"],
			["SD_T", "NPC_SD_T_AREA_GUILD2"]]:
		guild_shop_rows.append("1\t15\t0\tGROUP_STORE_%s_GUILD\t%s" % pair)
	guild_shop_rows.append("1\t15\t0\tGROUP_STORE_CH_POTION\tNPC_CH_POTION")
	var guild_shops := NpcServiceReader.parse_shop_npcs(("\n".join(guild_shop_rows) + "\n").to_utf16_buffer())
	_check(guild_shops.size() == 8, "the guild shop fixture lists 8 NPCs (got %d)" % guild_shops.size())
	var sf := func(code: String, gid: int, master: bool) -> Array:
		if not stateful:
			return []
		return reader_script.call("services_for", code, guild_shops, gid, master)
	# NEGATIVE (fails before round 524): a guildless player at each guild NPC
	# gets no shop line, only the create line.
	for guild_npc in ["NPC_CH_GENARAL_SP", "NPC_WC_GUILD", "NPC_KT_GUILD", "NPC_EU_GUILD",
			"NPC_CA_GUILD", "NPC_SD_M_AREA_GUILD", "NPC_SD_T_AREA_GUILD2"]:
		var g0: Array = sf.call(guild_npc, 0, false)
		_check(stateful and _keys(g0) == ["guild_create"],
			"a guildless player at %s gets exactly [\"guild_create\"], no shop (got %s)" % [guild_npc, _keys(g0)])
	# The talk menu that player sees: the create line is 1, as in the real
	# client, where the skipped item 1 takes no number.
	if stateful and has_composer:
		var ui_o := {"UIIT_CTL_GUILD_CREATE": "Create a new guild", "UIIT_STT_NPC_CHATTING_WND_TALKEND": "End conversation."}
		var resolve_o := func(token: String, fallback: String) -> String:
			return str(ui_o.get(token, fallback)) if token != "" else fallback
		var omenu: PackedStringArray = reader_script.call("talk_menu_lines", "NPC_CH_GENARAL_SP",
			sf.call("NPC_CH_GENARAL_SP", 0, false), resolve_o)
		_check(omenu == PackedStringArray(["[url=guild_create]1. Create a new guild[/url]", "[url=end]2. End conversation.[/url]"]),
			"a guildless player's NPC_CH_GENARAL_SP menu starts at 1. Create a new guild (got %s)" % [omenu])
	else:
		_check(false, "the guildless shop-NPC talk menu could not be composed (stateful=%s, composer=%s)" % [stateful, has_composer])
	# A member keeps the shop line, ahead of the guild line (item 1 comes
	# before the 0x0f block in FUN_00700440). So does a master.
	var g7: Array = sf.call("NPC_CH_GENARAL_SP", 7, false)
	_check(stateful and _keys(g7) == ["shop", "guild_leave"],
		"a member at NPC_CH_GENARAL_SP gets [\"shop\", \"guild_leave\"] (got %s)" % [_keys(g7)])
	var g7m: Array = sf.call("NPC_WC_GUILD", 7, true)
	_check(stateful and _keys(g7m) == ["shop", "guild"],
		"a master at NPC_WC_GUILD gets [\"shop\", \"guild\"] (got %s)" % [_keys(g7m)])
	# Guild state not known yet (-1, and the two-argument call): unchanged.
	var gu: Array = sf.call("NPC_CH_GENARAL_SP", -1, false)
	_check(stateful and _keys(gu) == ["shop", "guild"],
		"guild_id -1 at NPC_CH_GENARAL_SP keeps [\"shop\", \"guild\"] (got %s)" % [_keys(gu)])
	var g2 := NpcServiceReader.services_for("NPC_CH_GENARAL_SP", guild_shops)
	_check(_keys(g2) == ["shop", "guild"],
		"the two-argument call at NPC_CH_GENARAL_SP keeps [\"shop\", \"guild\"] (got %s)" % [_keys(g2)])
	# Any other store is untouched: its item 1 does not pass through the
	# 0x0f branch (0x7009f5 `je 0x700a0e` when 0x0f is absent).
	var potion0: Array = sf.call("NPC_CH_POTION", 0, false)
	_check(stateful and _keys(potion0) == ["shop"],
		"a guildless player at NPC_CH_POTION still gets [\"shop\"] (got %s)" % [_keys(potion0)])

	# (p) Round 526: the job guilds' join lines. The server registers id 0x14
	# (Trader) on six codename literals, 0x16 (Hunter) on six and 0x15
	# (Thief) on two (CGObjNPCNPC::Create: push 0x14 at 0x4c6c33, 0x16 at
	# 0x4c6d09, 0x15 at 0x4c6d57). The client's FUN_00700440 hands each to
	# FUN_006fdeb0(n, 1 / 3 / 2), which emits item 0x1e only when the
	# player's job byte (+0x7be) is 0. FUN_006fcd60 case 0x1e picks the
	# token by that kind. Read through get() and the constant map, so a
	# reader without job_kind or the tokens FAILS here rather than failing
	# to parse. The English is not pinned: the talk window resolves the
	# tokens through the archive's own text.
	var want_jobs := [
		["NPC_CH_DOCTOR", 1], ["NPC_WC_DOCTOR", 1], ["NPC_KT_DESIGNER", 1],
		["NPC_EU_MERCHANT", 1], ["NPC_CA_MERCHANT", 1], ["NPC_SD_M_AREA_MERCHANT", 1],
		["NPC_CH_GENARAL_SW", 3], ["NPC_WC_GENARAL_SW", 3], ["NPC_KT_MINISTER", 3],
		["NPC_EU_HUNTER", 3], ["NPC_CA_HUNTER", 3], ["NPC_SD_M_AREA_HUNTER", 3],
		["NPC_TD_THIEF_SELL", 2], ["NPC_SD_T_AREA_THIEF", 2],
	]
	var want_strid := {
		1: "UIIT_STT_NPC_CHATTING_TRADERMENU_JOIN",
		2: "UIIT_STT_NPC_CHATTING_THIEFMENU_JOIN",
		3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_JOIN",
	}
	_check(consts.get("JOB_JOIN_STRIDS", {}) == want_strid,
		"JOB_JOIN_STRIDS is exactly FUN_006fcd60 case 0x1e's three tokens (got %s)" % [consts.get("JOB_JOIN_STRIDS")])
	var job_lines := func(services: Array) -> Array:
		return services.filter(func(s): return s.key == "job_guild")
	# NEGATIVE (fails before round 526): each of the 14 has exactly one join
	# line, of its own kind and token, for a jobless player.
	for pair in want_jobs:
		var jcode: String = pair[0]
		var jkind: int = pair[1]
		var js: Array = []
		if stateful:
			js = reader_script.call("services_for", jcode, shops, -1, false, 0)
		var jl: Array = job_lines.call(js)
		var ok: bool = jl.size() == 1 and jl[0].get("job_kind") == jkind \
			and str(jl[0].get("strid")) == want_strid[jkind]
		_check(stateful and ok, "%s offers exactly one job_guild, kind %d, strid %s (got %s)"
			% [jcode, jkind, want_strid[jkind],
				jl.map(func(s): return [s.get("job_kind"), s.get("strid")])])
	# NEGATIVE: the codenames a wildcard would have caught, read as a
	# substring pattern the way the server's strstr tests match (an anchored
	# NPC_*_MERCHANT stops at _CHANGER), carry none of the three ids, and
	# neither does an ordinary store.
	for jcode in ["NPC_SD_MERCHANT_CHANGER", "NPC_TD_THIEF_BUY", "NPC_TD_THIEF_A",
			"NPC_SD_THIEF_AGENT_CHANGER", "NPC_CH_POTION"]:
		var jn: Array = []
		if stateful:
			jn = reader_script.call("services_for", jcode, shops, -1, false, 0)
		_check(stateful and (job_lines.call(jn) as Array).is_empty(),
			"%s offers no job_guild (got %s)" % [jcode, _keys(jn)])
	# The Chinese guild NPC is not the hunter NPC: NPC_CH_GENARAL_SP has id
	# 0x0f, NPC_CH_GENARAL_SW id 0x16.
	var gsp: Array = []
	if stateful:
		gsp = reader_script.call("services_for", "NPC_CH_GENARAL_SP", shops, -1, false, 0)
	_check(stateful and _keys(gsp).has("guild") and (job_lines.call(gsp) as Array).is_empty(),
		"NPC_CH_GENARAL_SP offers guild and no job_guild (got %s)" % [_keys(gsp)])
	# REGRESSION GUARDS, not negatives (round 527): these pass on the reader
	# before round 526 too, which offered no join line at all. A player who
	# has a job gets no join line, whether it is this guild's job
	# (FUN_006fdeb0's 0x1f branch) or another (its bare tail): the join line
	# needs the job byte to be 0 (0x6fdec4 `test al,al`, 0x6fdec6 `jne
	# 0x6fdee0`). Kind 1 (the trader's own) and kind 3 (another) at the
	# Jangan trader, and kind 2 (Thief, FUN_00700440 0x7012bf `push 2`) at
	# both thief NPCs.
	var held_cases := [
		["NPC_CH_DOCTOR", 1], ["NPC_CH_DOCTOR", 3],
		["NPC_TD_THIEF_SELL", 2], ["NPC_SD_T_AREA_THIEF", 2],
	]
	for hc in held_cases:
		var hcode: String = hc[0]
		var held: int = hc[1]
		var jh: Array = []
		if stateful:
			jh = reader_script.call("services_for", hcode, shops, -1, false, held)
		_check(stateful and (job_lines.call(jh) as Array).is_empty(),
			"a player with job kind %d at %s gets no job_guild (got %s)" % [held, hcode, _keys(jh)])
	# The composed menu at the Jangan trader: the join line's token resolved
	# through the text table, then the end line.
	if stateful and has_composer:
		var ui_p := {"UIIT_STT_NPC_CHATTING_TRADERMENU_JOIN": "JOIN-TEXT", "UIIT_STT_NPC_CHATTING_WND_TALKEND": "END-TEXT"}
		var resolve_p := func(token: String, fallback: String) -> String:
			return str(ui_p.get(token, fallback)) if token != "" else fallback
		var pmenu: PackedStringArray = reader_script.call("talk_menu_lines", "NPC_CH_DOCTOR",
			reader_script.call("services_for", "NPC_CH_DOCTOR", shops, -1, false, 0), resolve_p)
		_check(pmenu == PackedStringArray(["[url=job_guild]1. JOIN-TEXT[/url]", "[url=end]2. END-TEXT[/url]"]),
			"a jobless player's NPC_CH_DOCTOR menu is 1. join text / 2. end text (got %s)" % [pmenu])
	else:
		_check(false, "the job-guild talk menu could not be composed (stateful=%s, composer=%s)" % [stateful, has_composer])

	# (i) Round 514: the store window shows Repair / Repair All only at an NPC
	# with interaction id 4. The client's 0xb045 reply handler FUN_0088b200
	# hides both buttons and shows them again for id 4 (0x88b8c5-0x88b8d9,
	# then FUN_006d2840(0) and FUN_006d2840(has4)). The server registers id 4
	# by strstr on exactly these codename literals (CGObjNPCNPC::Create:
	# 0x4c677f, town smiths and armour merchants; 0x4c736f, fortress smiths).
	# This check pins the helper HudPanels._show_repair_buttons calls, and
	# check (j) below drives _show_repair_buttons itself on a store window.
	# The helper is reached through the script object, so that a reader
	# without it FAILS rather than failing to parse.
	var want_repair := [
		"NPC_CH_SMITH", "NPC_CH_ARMOR", "NPC_WC_SMITH", "NPC_WC_ARMOR",
		"NPC_KT_SMITH", "NPC_KT_ARMOR", "NPC_EU_SMITH", "NPC_EU_ARMOR",
		"NPC_CA_SMITH", "NPC_CA_ARMOR", "NPC_SD_M_AREA_SMITH", "NPC_SD_M_AREA_ARMOR",
		"NPC_SD_T_AREA_SMITH", "NPC_SD_T_AREA_ARMOR",
		"NPC_CH_FORTRESS_SMITH1", "NPC_CH_FORTRESS_SMITH2", "NPC_WC_FORTRESS_SMITH1",
		"NPC_WC_FORTRESS_SMITH2", "NPC_KT_FORTRESS_SMITH", "NPC_EU_FORTRESS_SMITH",
		"NPC_CA_FORTRESS_SMITH1", "NPC_CA_FORTRESS_SMITH2",
	]
	_check(consts.get("REPAIR_PATTERNS", []) == want_repair,
		"REPAIR_PATTERNS is exactly the server's 22 id-4 literals, in order (got %s)"
			% [consts.get("REPAIR_PATTERNS")])
	var has_offers_repair := false
	for m in reader_script.get_script_method_list():
		if str(m.get("name", "")) == "offers_repair":
			has_offers_repair = true
	_check(has_offers_repair, "NpcServiceReader has offers_repair")
	for code in want_repair:
		var yes: bool = has_offers_repair and bool(reader_script.call("offers_repair", code))
		_check(yes, "%s shows the store's repair buttons (interaction 4)" % code)
	# NEGATIVE: every other store hides them. Before this round OpenSRO showed
	# both buttons at every store. None of these carries id 4: a warehouse
	# keeper (ids 1 and 3), a potion seller, an accessory merchant, a guild NPC
	# (0x0f, 1) and a guild agent (no id by codename, round 520). An
	# empty codename hides them too. Lower case does not match, because the
	# server's strstr is case-sensitive.
	for code in ["NPC_CH_WAREHOUSE_M", "NPC_CH_POTION", "NPC_CH_ACCESSORY",
			"NPC_CH_GENARAL_SP", "NPC_SD_GUILD_AGENT", "", "npc_ch_smith"]:
		var no: bool = has_offers_repair and not bool(reader_script.call("offers_repair", code))
		_check(no, "\"%s\" hides the store's repair buttons (no interaction 4)" % code)

	# (q) Round 577: a teleport gate's lines. FUN_00700440 asks for id 7
	# (0x700c57 -> item 9), id 9 (0x700ca7 -> item 0x10) and id 8 (0x700cfb
	# -> item 0xa) in that order, and FUN_006fcd60 pushes
	# UIIT_CTL_RECALL_POSITION (0x6fcf10), UIIT_CTL_TELEPORT_TO_RESURRECT_POS
	# (0x6fcf1a) and UIIT_CTL_TELEPORT_TARGET (0x6fcf24) for them. Reached
	# through the script object, so a reader without gate_services FAILS here
	# rather than failing to parse (NEGATIVE: the pre-round tree).
	var has_gate := false
	for m in reader_script.get_script_method_list():
		if str(m.get("name", "")) == "gate_services":
			has_gate = true
	_check(has_gate, "NpcServiceReader has gate_services")
	var town_gate: Array = reader_script.call("gate_services", true, true, false) if has_gate else []
	_check(_keys(town_gate) == ["recall_designate", "teleport"],
		"a town gate (links, id 7, no id 9) offers the designate line then the teleport line (got %s)" % [_keys(town_gate)])
	var gs_designate = _find(town_gate, "recall_designate")
	var gs_teleport = _find(town_gate, "teleport")
	_check(gs_designate != null and gs_designate.strid == "UIIT_CTL_RECALL_POSITION",
		"the designate line is item 9's token, UIIT_CTL_RECALL_POSITION")
	_check(gs_teleport != null and gs_teleport.strid == "UIIT_CTL_TELEPORT_TARGET",
		"the teleport line is item 0xa's token, UIIT_CTL_TELEPORT_TARGET")
	var every_gate: Array = reader_script.call("gate_services", true, true, true) if has_gate else []
	_check(_keys(every_gate) == ["recall_designate", "recall_return", "teleport"],
		"all three come in the client's order 7, 9, 8 (got %s)" % [_keys(every_gate)])
	var gs_return = _find(every_gate, "recall_return")
	_check(gs_return != null and gs_return.strid == "UIIT_CTL_TELEPORT_TO_RESURRECT_POS",
		"the return line is item 0x10's token, UIIT_CTL_TELEPORT_TO_RESURRECT_POS")
	_check(has_gate and (reader_script.call("gate_services", false, false, false) as Array).is_empty(),
		"a gate with no link and no registration offers nothing")
	# NEGATIVE: the gate's codename alone is no shop, warehouse, guild or job
	# pattern -- its lines come only from gate_services.
	_check(NpcServiceReader.services_for("STORE_CH_GATE", {}).is_empty(),
		"services_for(\"STORE_CH_GATE\", {}) alone yields nothing")
	if has_gate and has_composer:
		var ui_q := {"UIIT_CTL_RECALL_POSITION": "DESIGNATE-TEXT", "UIIT_CTL_TELEPORT_TARGET": "SELECT-TEXT",
			"UIIT_STT_NPC_CHATTING_WND_TALKEND": "END-TEXT"}
		var resolve_q := func(token: String, fallback: String) -> String:
			return str(ui_q.get(token, fallback)) if token != "" else fallback
		var qmenu: PackedStringArray = reader_script.call("talk_menu_lines", "Dimensional Gate", town_gate, resolve_q)
		_check(qmenu == PackedStringArray(["[url=recall_designate]1. DESIGNATE-TEXT[/url]",
				"[url=teleport]2. SELECT-TEXT[/url]", "[url=end]3. END-TEXT[/url]"]),
			"the town gate's menu is 1. designate text / 2. select text / 3. end text (got %s)" % [qmenu])

	# (j) is in _initialize, below, which also reports the result.

## (j) Added after review: the rule reaches the store window's buttons.
##
## This runs here and not in _init. A --script suite's _init runs before the
## NetClient autoload's global is registered, so hud_panels.gd cannot compile
## there. Measured on the render box: loading it from _init printed
## "Compile Error: Identifier not found: NetClient" (hud_panels.gd:389, in
## open_shop), and can_instantiate() was false. By _initialize the autoload
## is in the tree (root.has_node("NetClient") was true), and the same load
## compiles and instantiates. hud_window_test.gd reads HudPanels' constants
## from _init and never instantiates it. The script is loaded by path, not by
## its class_name, so that nothing compiles it before the autoload exists.
##
## _show_repair_buttons uses only offers_repair, HudWindow.node() and
## `visible`. So a HudWindow whose panel_root holds the two authored buttons,
## both visible, is driven the way open_shop drives it. A freshly built
## ifstore leaves them visible, and so did every store before round 514.
## First comes a potion seller's store, then a smith's in the same reused
## window. The helper is reached through has_method/call, so a HudPanels
## without it FAILS here rather than failing to parse.
func _initialize() -> void:
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var compiled := panels_script != null and panels_script.can_instantiate()
	_check(compiled, "HudPanels compiles in _initialize, once the NetClient autoload is registered")
	if compiled:
		var panels: Node = panels_script.new()
		var store := HudWindow.new()
		store.panel_root = Control.new()
		store.add_child(store.panel_root)
		var repair_btns: Array[Button] = []
		for control_name in ["GDR_STORE_BTN_REPAIR", "GDR_STORE_BTN_REPAIRALL"]:
			var btn := Button.new()
			btn.name = control_name
			btn.visible = true
			store.panel_root.add_child(btn)
			repair_btns.append(btn)
		var has_show := panels.has_method("_show_repair_buttons")
		_check(has_show, "HudPanels has _show_repair_buttons")
		# NEGATIVE: a potion seller has no interaction 4, so its store hides
		# both. Before round 514 nothing hid them.
		if has_show:
			panels.call("_show_repair_buttons", store, "NPC_CH_POTION")
		for btn in repair_btns:
			_check(not btn.visible, "the store opened at NPC_CH_POTION hides %s" % btn.name)
		# The smith has interaction 4, so the same window shows both again.
		if has_show:
			panels.call("_show_repair_buttons", store, "NPC_CH_SMITH")
		for btn in repair_btns:
			_check(btn.visible, "the store opened at NPC_CH_SMITH shows %s" % btn.name)
		store.free()

		# (l) Round 521: the guild create line's name prompt, on a bare talk
		# window. It caps the name at the server's 12 (guild.MaxNameLength),
		# ignores an empty name, and emits guild_create_requested with the
		# trimmed name. Reached through has_method/has_signal, so a HudPanels
		# without them FAILS here rather than failing to parse.
		var has_prompt := panels.has_method("open_guild_name_prompt") and panels.has_signal("guild_create_requested")
		_check(has_prompt, "HudPanels has open_guild_name_prompt and guild_create_requested")
		var talk := HudWindow.new()
		(panels.get("_windows") as Dictionary)["npctalk"] = talk
		var requested: Array = []
		if has_prompt:
			panels.connect("guild_create_requested", func(n: String) -> void: requested.append(n))
			panels.call("open_guild_name_prompt", "NPC_CH_GENARAL_SP")
		var name_edit := talk.get_node_or_null("GuildNamePrompt/VB/GuildName") as LineEdit
		_check(name_edit != null, "the prompt opens on the talk window with a name line")
		if name_edit != null:
			_check(name_edit.max_length == 12, "the name line takes at most 12 (got %d)" % name_edit.max_length)
			name_edit.text = "   "
			name_edit.text_submitted.emit(name_edit.text)
			_check(requested.is_empty(), "an empty name sends nothing (got %s)" % [requested])
			name_edit.text = "  Lions  "
			name_edit.text_submitted.emit(name_edit.text)
		_check(requested == ["Lions"], "Enter sends the trimmed name once (got %s)" % [requested])
		talk.free()
		panels.free()

	# (m) Review of round 521: the guild prompts in the running tree. The name
	# prompt's line takes the keyboard, and World3D reads movement from the
	# raw key state (Input.get_axis), which a focused LineEdit does not
	# consume. Its gate asked only the chat line, so typing "Swords" into the
	# prompt walked the character on S, W and D. Here the panels are in the
	# tree, so the focus is real, and World3D's own gate (_is_typing) is asked
	# with them wired in. The same live window checks three more things. A new
	# conversation drops the prompt. A guild reply's refresh keeps it and does
	# not raise the talk box. The leave line asks before it sends. Methods
	# are reached through has_method/call, so a build without them FAILS here
	# rather than failing to parse.
	#
	# It needs the running tree, which the root of a --script suite enters
	# only after _initialize returns. Measured on the render box: here,
	# root.is_inside_tree() was false, nothing added under it was inside the
	# tree, and grab_focus() failed with `!is_inside_tree()`. So (m) waits a
	# frame first. A watchdog fails the suite, rather than hanging it, if a
	# script error stops (m) before it reports.
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL check (m) never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_check(root.is_inside_tree(), "after one frame the root is in the tree")
	if compiled:
		var live: Node = panels_script.new()
		root.add_child(live)
		var live_talk := HudWindow.new()
		live_talk.name = "Window_npctalk"
		live.add_child(live_talk)
		var store_win := HudWindow.new()
		store_win.name = "Window_store"
		live.add_child(store_win)
		(live.get("_windows") as Dictionary)["npctalk"] = live_talk
		(live.get("_windows") as Dictionary)["store"] = store_win
		var world_script := load("res://scripts/World3D.gd") as GDScript
		var world_ok := world_script != null and world_script.can_instantiate()
		_check(world_ok, "World3D compiles in _initialize")
		var world: Node = world_script.new() if world_ok else null
		var has_gate := world != null and world.has_method("_is_typing")
		_check(has_gate, "World3D has _is_typing, the gate _physics_process reads the move keys behind")
		if world != null:
			world.set("_hud_panels", live)
		_check(world != null and world.get("_hud_panels") == live, "World3D holds the live panels")
		var typing := func() -> bool:
			return has_gate and bool(world.call("_is_typing"))
		_check(has_gate and not typing.call(), "with nothing focused World3D's gate reads no typing")
		if live.has_method("open_guild_name_prompt"):
			live.call("open_guild_name_prompt", "NPC_CH_GENARAL_SP")
		var live_edit := live_talk.get_node_or_null("GuildNamePrompt/VB/GuildName") as LineEdit
		# The probe first: the name line really holds the viewport's focus.
		_check(live_edit != null and root.gui_get_focus_owner() == live_edit,
			"the open name prompt's line has the keyboard (focus owner %s)" % [root.gui_get_focus_owner()])
		# NEGATIVE (fails before the review fix): the gate read the chat alone.
		_check(typing.call(), "World3D's movement gate counts the focused guild name line as typing")
		# A guild reply rebuilds the lines in place: the prompt stays, and the
		# store opened from the talk box stays in front of it.
		store_win.move_to_front()
		var has_refresh := live.has_method("refresh_npc_talk")
		_check(has_refresh, "HudPanels has refresh_npc_talk")
		if has_refresh:
			live.call("refresh_npc_talk", "NPC_CH_GENARAL_SP", "", [])
		_check(has_refresh and live_talk.get_node_or_null("GuildNamePrompt") != null,
			"a guild reply's refresh keeps the name prompt")
		_check(has_refresh and live_talk.get_index() < store_win.get_index(),
			"a guild reply's refresh leaves the store in front of the talk box")
		# The order probe works: a new conversation does raise the talk box.
		live.call("open_npc_talk", "NPC_CH_POTION", "", [])
		_check(live_talk.get_index() > store_win.get_index(), "a new conversation raises the talk box")
		# NEGATIVE: a new conversation (a potion merchant clicked while the
		# prompt was up) drops the prompt, and the keyboard with it.
		_check(live_talk.get_node_or_null("GuildNamePrompt") == null, "a new conversation drops the name prompt")
		_check(has_gate and not typing.call(), "with the prompt gone the player is not typing")
		# The leave line asks first. Opening its prompt replaces the name
		# prompt; Cancel sends nothing; Leave sends once.
		var has_leave := live.has_method("open_guild_leave_prompt") and live.has_signal("guild_leave_requested")
		_check(has_leave, "HudPanels has open_guild_leave_prompt and guild_leave_requested")
		var leaves: Array = []
		if has_leave:
			live.connect("guild_leave_requested", func() -> void: leaves.append(1))
			live.call("open_guild_name_prompt", "NPC_WC_GUILD")
			live.call("open_guild_leave_prompt", "NPC_WC_GUILD")
		var leave_prompt := live_talk.get_node_or_null("GuildLeavePrompt")
		_check(leave_prompt != null, "the leave line opens a prompt on the talk window")
		_check(has_leave and live_talk.get_node_or_null("GuildNamePrompt") == null,
			"one prompt at a time: the leave prompt replaced the name prompt")
		# NEGATIVE: opening the prompt sends nothing by itself.
		_check(has_leave and leaves.is_empty(), "opening the leave prompt sends no leave (got %d)" % leaves.size())
		var cancel_btn: Button = null
		if leave_prompt != null:
			cancel_btn = leave_prompt.find_child("Cancel", true, false) as Button
		_check(cancel_btn != null, "the leave prompt has a Cancel button")
		if cancel_btn != null:
			cancel_btn.pressed.emit()
		_check(has_leave and leaves.is_empty(), "Cancel sends no leave (got %d)" % leaves.size())
		var confirm_btn: Button = null
		if has_leave:
			live.call("open_guild_leave_prompt", "NPC_WC_GUILD")
			var again := live_talk.get_node_or_null("GuildLeavePrompt")
			if again != null:
				confirm_btn = again.find_child("Leave", true, false) as Button
		_check(confirm_btn != null, "the leave prompt has a Leave button")
		if confirm_btn != null:
			confirm_btn.pressed.emit()
		_check(leaves.size() == 1, "Leave sends the leave request once (got %d)" % leaves.size())

		# (n) Review of round 521, the other way: a line left focused must not
		# keep movement dead once the player clicks away. A click on a
		# SpinBox's arrows grabs its inner LineEdit's focus, and the options
		# panel's chat-font spinner then stopped WASD, click-to-move and the
		# attack walk while it stayed open. Round 522 takes the focus back on
		# a LEFT click on the world (World3D.take_focus_back) -- not on a
		# right drag, the wheel or a key -- and the spinner hands it back once
		# its value is set (debug_panel.gd; not driven here, it needs a world).
		var spin := SpinBox.new()
		live.add_child(spin)
		spin.get_line_edit().grab_focus()
		_check(root.gui_get_focus_owner() == spin.get_line_edit(),
			"the probe: the spinner's inner line holds the focus (owner %s)" % [root.gui_get_focus_owner()])
		# The keys typed there go into the spinner, so it counts as typing:
		# letting W also walk would split one key press two ways.
		_check(has_gate and typing.call(), "a focused SpinBox line counts as typing")
		var field := LineEdit.new()
		live.add_child(field)
		field.grab_focus()
		_check(has_gate and typing.call(), "a focused, visible LineEdit is typing")
		var key := InputEventKey.new()
		key.pressed = true
		key.keycode = KEY_W
		var took_key := world_ok and bool(world_script.call("take_focus_back", root, key))
		_check(world_ok and not took_key and root.gui_get_focus_owner() == field,
			"a key press does not take the focus back")
		for button in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			var other := InputEventMouseButton.new()
			other.pressed = true
			other.button_index = button
			var took_other := world_ok and bool(world_script.call("take_focus_back", root, other))
			_check(world_ok and not took_other and root.gui_get_focus_owner() == field,
				"mouse button %d (zoom, orbit, quickslot) does not take the focus back" % button)
		var lift := InputEventMouseButton.new()
		lift.pressed = false
		lift.button_index = MOUSE_BUTTON_LEFT
		var took_lift := world_ok and bool(world_script.call("take_focus_back", root, lift))
		_check(world_ok and not took_lift and root.gui_get_focus_owner() == field,
			"a left release does not take the focus back")
		var click := InputEventMouseButton.new()
		click.pressed = true
		click.button_index = MOUSE_BUTTON_LEFT
		var took := world_ok and bool(world_script.call("take_focus_back", root, click))
		# NEGATIVE (fails before round 522: there was no take_focus_back).
		_check(took and root.gui_get_focus_owner() == null,
			"a left click on the world takes the focus back (owner %s)" % [root.gui_get_focus_owner()])
		_check(has_gate and not typing.call(), "after the click the player is not typing")
		# The chat window consumes its own clicks. It was PASS, so a click on
		# its scrollback reached World3D._unhandled_input: it walked the
		# character and, with take_focus_back, ended the message being typed.
		# NEGATIVE (fails before the review fix: PASS).
		var chat_script := load("res://scripts/ui/hud/hud_chat.gd") as GDScript
		var chat: Control = chat_script.new() if chat_script != null and chat_script.can_instantiate() else null
		if chat != null:
			chat.call("setup")
		_check(chat != null and chat.mouse_filter == Control.MOUSE_FILTER_STOP,
			"the chat window stops its clicks reaching the world (filter %s)" % [chat.mouse_filter if chat != null else -1])
		if chat != null:
			chat.free()
		spin.free()
		field.free()
		if world != null:
			world.free()
		# (o) clicks through the live viewport; the panels' windows must not
		# sit under its points.
		live.free()

	# (o) Round 529: the four HUD surfaces round 522's re-review measured
	# passing clicks to the world -- the player-info block, the minimap, the
	# target window and the hotbar's body -- consume them now, and a camera
	# orbit keeps turning over a STOP control. Real events go through the live
	# viewport, and a recorder node stands in for World3D's two handlers, so
	# "reaches the world" is measured here, not read off a filter value. Each
	# surface is built without an archive; the hotbar from a synthetic
	# nifundermenubar.2dt (never real game data). Not driven:
	# a real click in a running client, and the surfaces built from Media.pk2.
	var recorder_script := GDScript.new()
	recorder_script.source_code = "\n".join([
		"extends Node",
		"var inputs: Array = []",
		"var unhandled: Array = []",
		"func _input(event: InputEvent) -> void:",
		"\tinputs.append(event)",
		"func _unhandled_input(event: InputEvent) -> void:",
		"\tunhandled.append(event)",
		""])
	_check(recorder_script.reload() == OK, "the recorder script compiles")
	var recorder := Node.new()
	recorder.set_script(recorder_script)
	root.add_child(recorder)
	# A motion finds the control under the cursor only while the mouse is in
	# the viewport (Godot 4.2.2 Viewport::_gui_input_event, gui.mouse_in_viewport),
	# which only the OS's enter event sets; headless, it is sent here.
	root.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var hud := Control.new()
	hud.name = "Round529Hud"
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE  # as World3D.tscn's UI/Control
	root.add_child(hud)
	var empty := Vector2(600, 300)
	# The probe first: a click on no control does reach _unhandled_input.
	_check(_click_reaches_world(recorder, empty), "the probe: a click on no control reaches _unhandled_input")

	# The player-info block. NEGATIVE (fails before round 529: IGNORE).
	var pmi := HudPlayerInfo.new(null)
	pmi.setup()
	hud.add_child(pmi)
	pmi.position = Vector2(4, 7)
	_check(pmi.mouse_filter == Control.MOUSE_FILTER_STOP,
		"the player-info block is STOP (filter %d)" % pmi.mouse_filter)
	_check(not _click_reaches_world(recorder, pmi.position + pmi.size / 2.0),
		"a click on the player-info block does not reach the world")

	# The minimap. NEGATIVE (fails before round 529: IGNORE on every node).
	var minimap := HudMinimap.new()
	minimap.setup()
	hud.add_child(minimap)
	minimap.position = Vector2(900, 10)
	_check(minimap.mouse_filter == Control.MOUSE_FILTER_STOP,
		"the minimap is STOP (filter %d)" % minimap.mouse_filter)
	var aperture_centre: Vector2 = minimap.position + HudMinimap.APERTURE_RECT.get_center()
	_check(not _click_reaches_world(recorder, aperture_centre),
		"a click on the minimap's map does not reach the world")

	# The target window: STOP, and catches nothing while hidden. Without an
	# archive there is no piece to show, so it is given a rect and shown, as
	# _select and show_target do with one. NEGATIVE (fails before round 529).
	var target := HudTarget.new(null)
	_check(target.setup() == false, "the target window builds no piece without an archive")
	hud.add_child(target)
	_check(target.mouse_filter == Control.MOUSE_FILTER_STOP,
		"the target window is STOP (filter %d)" % target.mouse_filter)
	target.position = Vector2(400, 10)
	target.size = Vector2(100, 40)
	var target_centre := target.position + target.size / 2.0
	_check(_click_reaches_world(recorder, target_centre), "a hidden target window catches nothing")
	target.visible = true
	_check(not _click_reaches_world(recorder, target_centre),
		"a click on the shown target window does not reach the world")

	# The hotbar: CNIFUnderMenuBar from the synthetic nifundermenubar.2dt in
	# underbar_fixture.gd (round 598). Its rect is the 800x68 body; quick slot
	# 1 (40) and the menu button (4) sit inside it, the left decoration (2)
	# hangs off its left end, and the menu (59) opens above it.
	var Fixture = load("res://scripts/ui/hud/underbar_fixture.gd")
	var bar := HudUnderbar.new(Fixture.builder(), null, null)
	bar.setup()
	hud.add_child(bar)
	var bar_at := Vector2(100, 400)
	bar.position = bar_at
	var fired: Array = []
	bar.quickslot_activated.connect(func(idx: int) -> void: fired.append(idx))
	_check(bar.size == Vector2(HudUnderbar.BODY_WIDTH, HudUnderbar.BODY_HEIGHT) and bar.size == Vector2(800, 68),
		"the probe: the hotbar's rect is its 800x68 body (%s)" % [bar.size])
	# NEGATIVE (fails before round 529: IGNORE).
	_check(bar.mouse_filter == Control.MOUSE_FILTER_STOP, "the hotbar's body is STOP (filter %d)" % bar.mouse_filter)
	_check(not _click_reaches_world(recorder, bar_at + Vector2(100, 30)),
		"a click on the hotbar's body away from its slots does not reach the world")
	_check(not _click_reaches_world(recorder, bar_at + Vector2(600, 50)),
		"a click on the bar's own art (a PASS control) stops at the body")
	_check(fired.is_empty(), "a left click on the body fires no quickslot (got %s)" % [fired])
	# The children keep their clicks.
	_check(not _click_reaches_world(recorder, bar_at + Vector2(277, 34), MOUSE_BUTTON_RIGHT) and fired == [1],
		"a right click on quick slot 1 fires it (round 652) and does not reach the world (fired %s)" % [fired])
	fired.clear()
	_check(not _click_reaches_world(recorder, bar_at + Vector2(277, 34)) and fired.is_empty(),
		"a left click on quick slot 1 fires nothing and does not reach the world (fired %s)" % [fired])
	_check(not _click_reaches_world(recorder, bar_at + Vector2(720, 13)) and bar.is_menu_open(),
		"the menu button takes its click and opens the menu")
	var menu := bar.control([59])
	_check(menu != null and not _click_reaches_world(recorder, menu.get_global_rect().position + Vector2(20, 100)),
		"a click on the open menu does not reach the world")
	bar.toggle_menu()
	# Nothing is swallowed outside the body: the space above it (the menu
	# closed) and the decoration beside it still pass a click to the world.
	_check(_click_reaches_world(recorder, bar_at + Vector2(100, -20)),
		"a click in the empty space above the bar reaches the world")
	_check(_click_reaches_world(recorder, bar_at + Vector2(-30, 30)),
		"a click on the decoration beside the bar reaches the world")
	# The middle button fires the "m" slot, quick slot 0, over the body (it
	# reached World3D before) and over a slot, once each.
	fired.clear()
	_check(not _click_reaches_world(recorder, bar_at + Vector2(100, 30), MOUSE_BUTTON_MIDDLE) and fired == [0],
		"a middle press on the body fires the \"m\" slot (fired %s)" % [fired])
	fired.clear()
	_check(not _click_reaches_world(recorder, bar_at + Vector2(277, 34), MOUSE_BUTTON_MIDDLE) and fired == [0],
		"a middle press on a slot fires the \"m\" slot once (fired %s)" % [fired])

	# The orbit. First the routing it rests on, measured with a plain STOP
	# control (every HudWindow is one): a right press on no control leaves no
	# mouse focus, so Godot sends the drag's motion to the control under the
	# cursor, which consumes it; _input still sees it.
	var pane := Control.new()
	pane.mouse_filter = Control.MOUSE_FILTER_STOP
	pane.position = Vector2(600, 100)
	pane.size = Vector2(120, 120)
	hud.add_child(pane)
	var over_pane := pane.position + pane.size / 2.0
	(recorder.get("unhandled") as Array).clear()
	_push_button(empty, MOUSE_BUTTON_RIGHT, true)
	_check(_recorded_button(recorder, true), "the probe: a right press on no control reaches _unhandled_input")
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(10, 4)
	drag.button_mask = MOUSE_BUTTON_MASK_RIGHT
	var drag_world := drag.duplicate() as InputEventMouseMotion
	drag_world.position = empty + Vector2(10, 4)
	drag_world.global_position = drag_world.position
	var drag_pane := drag.duplicate() as InputEventMouseMotion
	drag_pane.position = over_pane
	drag_pane.global_position = over_pane
	(recorder.get("inputs") as Array).clear()
	(recorder.get("unhandled") as Array).clear()
	root.push_input(drag_world, true)
	_check((recorder.get("inputs") as Array).size() == 1 and (recorder.get("unhandled") as Array).size() == 1,
		"over the world a drag's motion reaches both _input and _unhandled_input, so only one may turn the camera")
	(recorder.get("inputs") as Array).clear()
	(recorder.get("unhandled") as Array).clear()
	root.push_input(drag_pane, true)
	_check((recorder.get("inputs") as Array).size() == 1, "_input sees the drag's motion over a STOP control")
	_check((recorder.get("unhandled") as Array).is_empty(),
		"the STOP control consumes it: _unhandled_input never sees it (why the orbit reads _input)")
	(recorder.get("unhandled") as Array).clear()
	_push_button(over_pane, MOUSE_BUTTON_RIGHT, false)
	_check(_recorded_button(recorder, false), "the right release still reaches _unhandled_input (no mouse focus)")
	# The case orbit_motion_applies' mask check covers: a left press on the
	# STOP control while the right button is held takes the mouse focus, and
	# the right release then goes there, never to _unhandled_input.
	_push_button(empty, MOUSE_BUTTON_RIGHT, true)
	_push_button(over_pane, MOUSE_BUTTON_LEFT, true)
	(recorder.get("unhandled") as Array).clear()
	_push_button(empty, MOUSE_BUTTON_RIGHT, false)
	_check(not _recorded_button(recorder, false),
		"a right release while a left press holds a control's focus misses _unhandled_input")
	_push_button(over_pane, MOUSE_BUTTON_LEFT, false)

	# World3D's own handlers, called directly (it cannot run without a world).
	var w3d_script := load("res://scripts/World3D.gd") as GDScript
	var w3d: Node = w3d_script.new() if w3d_script != null and w3d_script.can_instantiate() else null
	var has_orbit := w3d != null and w3d.has_method("orbit_motion_applies")
	# NEGATIVE (fails before round 529: the orbit was read in _unhandled_input).
	_check(has_orbit, "World3D has orbit_motion_applies")
	var consts: Dictionary = w3d_script.get_script_constant_map() if w3d_script != null else {}
	var view_free: String = consts.get("CAMERA_VIEW_FREE", "")
	var view_third: String = consts.get("CAMERA_VIEW_THIRD_PERSON", "")
	var orbits := func(ev: InputEvent, orbiting: bool, view: String) -> bool:
		return has_orbit and bool(w3d.call("orbit_motion_applies", ev, orbiting, view))
	_check(orbits.call(drag_pane, true, view_free), "an orbit's motion over a control turns the camera")
	_check(has_orbit and not orbits.call(drag_pane, false, view_free), "the same motion turns nothing when not orbiting")
	var no_right := drag_pane.duplicate() as InputEventMouseMotion
	no_right.button_mask = 0
	_check(has_orbit and not orbits.call(no_right, true, view_free),
		"an orbiting flag left set with no right button down turns nothing")
	_check(has_orbit and not orbits.call(drag_pane, true, view_third),
		"the third-person view does not orbit (the camera follows the player)")
	_check(has_orbit and not orbits.call(InputEventMouseButton.new(), true, view_free), "a button event is not orbit motion")
	if w3d != null:
		var arm := SpringArm3D.new()
		w3d.set("camera_arm", arm)
		w3d.set("_camera_orbiting", true)
		w3d.set("_right_button_held", true)
		var sensitivity: float = consts.get("CAMERA_ORBIT_SENSITIVITY", 0.0)
		var yaw_before := arm.rotation_degrees.y
		w3d.call("_input", drag_pane)
		var yaw_after_input := arm.rotation_degrees.y
		# NEGATIVE (fails before round 529: _input did not orbit).
		_check(sensitivity > 0.0 and is_equal_approx(yaw_after_input, yaw_before - drag_pane.relative.x * sensitivity),
			"World3D._input turns the camera by the drag (yaw %.2f -> %.2f)" % [yaw_before, yaw_after_input])
		w3d.call("_unhandled_input", drag_world)
		# NEGATIVE (fails before round 529: _unhandled_input turned it).
		_check(is_equal_approx(arm.rotation_degrees.y, yaw_after_input),
			"World3D._unhandled_input no longer turns it, so motion over the world turns it once (yaw %.2f)" % arm.rotation_degrees.y)
		# A left drag turns no camera (round 701: and steers nothing either --
		# world/click_hold_test.gd holds the walk's side).
		w3d.set("_camera_orbiting", false)
		w3d.set("_right_button_held", false)
		w3d.set("_left_button_held", true)
		var steer := InputEventMouseMotion.new()
		steer.position = Vector2(20, 0)
		steer.relative = Vector2(20, 0)
		steer.button_mask = MOUSE_BUTTON_MASK_LEFT
		var rotation_before := arm.rotation_degrees
		w3d.call("_input", steer)
		w3d.call("_unhandled_input", steer)
		_check(not bool(w3d.get("_has_move_target")) and arm.rotation_degrees.is_equal_approx(rotation_before),
			"a left drag turns no camera and sets no destination")
		arm.free()
		w3d.free()
	hud.free()
	recorder.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
