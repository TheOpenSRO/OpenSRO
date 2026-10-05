extends SceneTree

## Round 727: the retail NPC select/open/end codecs and state (NpcTalkNet),
## against the same golden bytes as the server's npctalk/wire_test.go, and the
## talk menu composed from an interaction-id set in the client's own order
## (NpcServiceReader.services_from_ids; FUN_00700440, READ).
##
##   godot4 --headless --path client --script res://scripts/net/npc_talk_net_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _hex(b: PackedByteArray) -> String:
	return " ".join(Array(b).map(func(x): return "%02x" % x))

func _keys(services: Array) -> Array:
	return services.map(func(s): return (s as NpcServiceReader.Service).key)

func _test_codecs() -> void:
	# The requests (npctalk TestGoldenBytes' first three rows).
	_check(_hex(NpcTalkNet.encode_entity(0x7f000123)) == "23 01 00 7f", "0x7045 / 0x704b {u32 entity}")
	_check(_hex(NpcTalkNet.encode_open(0x7f000123, 1)) == "23 01 00 7f 01", "0x7046 {u32 entity, u8 1}")
	# The herbalist's select reply for a player of level 20 or more, as the
	# original sends it: 01 | uid | 00 (the NPC's flag, s:0x4c79f0) | 03 |
	# 01 02 0a | 00 (round 727's review).
	var herb := NpcTalkNet.decode_select(PackedByteArray([0x01, 0x23, 0x01, 0x00, 0x7f, 0x00, 0x03, 0x01, 0x02, 0x0a, 0x00]))
	_check(not herb.is_empty() and int(herb["entity"]) == 0x7f000123 and int(herb["flag"]) == 0
		and Array(herb["ids"]) == [1, 2, 10] and int(herb["npc_byte"]) == 0, "0xb045 herbalist decodes (got %s)" % [herb])
	# Flag bit 0: a u32 follows (c:0x88b385).
	var fl := NpcTalkNet.decode_select(PackedByteArray([0x01, 0x01, 0, 0, 0, 0x01, 0x0d, 0x0c, 0x0b, 0x0a, 0x01, 0x01, 0x00]))
	_check(int(fl.get("flag_word", -1)) == 0x0a0b0c0d and Array(fl.get("ids", [])) == [1], "0xb045 with flag bit 0 (got %s)" % [fl])
	# 0x1f: the u16 before the NPC byte; 0x21: the u16 after it.
	var st := NpcTalkNet.decode_select(PackedByteArray([0x01, 0x01, 0, 0, 0, 0x00, 0x01, 0x1f, 0x03, 0x02, 0x07]))
	_check(int(st.get("structure_word", -1)) == 0x0203 and int(st.get("npc_byte", -1)) == 7, "0xb045 with 0x1f (got %s)" % [st])
	var ar := NpcTalkNet.decode_select(PackedByteArray([0x01, 0x01, 0, 0, 0, 0x00, 0x01, 0x21, 0x00, 0x05, 0x04]))
	_check(int(ar.get("arena_word", -1)) == 0x0405, "0xb045 with 0x21 (got %s)" % [ar])
	_check(NpcTalkNet.decode_select(PackedByteArray([0x01, 0x01, 0, 0, 0, 0x00, 0x02, 0x01])).is_empty(), "a short select reply decodes to {}")
	_check(NpcTalkNet.refusal_code(PackedByteArray([0x02, 0x0b, 0x1c])) == 0x1c0b, "a refusal's code (busy 0x1c0b)")
	_check(NpcTalkNet.refusal_code(PackedByteArray([0x01, 0x02])) == -1, "an ok is no refusal")

func _test_state() -> void:
	var sent: Array = []
	var net := NpcTalkNet.new()
	net.send = func(op: int, payload: PackedByteArray) -> void: sent.append([op, _hex(payload)])
	var got := {}
	net.selected.connect(func(e: int, ids: PackedByteArray) -> void: got["selected"] = [e, Array(ids)])
	net.opened.connect(func(id: int) -> void: got["opened"] = id)
	net.select_refused.connect(func(code: int) -> void: got["select_refused"] = code)
	net.ended.connect(func() -> void: got["ended"] = true)
	net.open(1)
	_check(sent.is_empty(), "no open before a select named the NPC")
	net.select(0x7f000123)
	net.handle(PackedByteArray([0x02, 0x04, 0x00]), NpcTalkNet.OP_SELECT_RESULT)
	_check(got.get("select_refused", -1) == 4 and net.entity == 0, "a refused select (4, out of reach) names nothing")
	net.handle(PackedByteArray([0x01, 0x23, 0x01, 0x00, 0x7f, 0x00, 0x02, 0x01, 0x02, 0x00]), NpcTalkNet.OP_SELECT_RESULT)
	_check(got.get("selected", []) == [0x7f000123, [1, 2]] and net.entity == 0x7f000123, "the select reply names the NPC and its set")
	# The store line: the close's end goes first, then the open.
	_check(net.end(), "the talk window's close sends 0x704b")
	net.open(1)
	_check(sent.slice(-2) == [[NpcTalkNet.OP_END, "23 01 00 7f"], [NpcTalkNet.OP_OPEN, "23 01 00 7f 01"]],
		"store line: 0x704b then 0x7046 {1} (got %s)" % [sent.slice(-2)])
	# The storage line: the open first; the hide's end is held while it is out.
	var before := sent.size()
	net.open(3)
	_check(not net.end() and sent.size() == before + 1, "no 0x704b while a 0x7046 is in flight (0x841780)")
	net.handle(PackedByteArray([0x01, 0x03]), NpcTalkNet.OP_OPEN_RESULT)
	_check(got.get("opened", -1) == 3 and not net.open_in_flight, "0xb046 {1, 3} opens the storage")
	_check(net.end() and sent[-1] == [NpcTalkNet.OP_END, "23 01 00 7f"], "the storage's close sends 0x704b")
	net.handle(PackedByteArray([0x01]), NpcTalkNet.OP_END_RESULT)
	_check(got.get("ended", false), "0xb04b {1} ends")

func _test_menus() -> void:
	var lines := [{"tabgroup": "STORE_CH_POTION_GROUP1", "name_strid": "SN_STORE_POTION_GROUP1"}]
	# The herbalist in tcHCl0v.png: Talk / Purchase-Sell / Withdrawing Skill.
	var herb := NpcServiceReader.services_from_ids(PackedByteArray([1, 2, 10]), lines)
	_check(_keys(herb) == ["talk", "shop:STORE_CH_POTION_GROUP1", "withdraw_skill"],
		"{1, 2, 10}: talk, the store line, withdraw skill (got %s)" % [_keys(herb)])
	_check((herb[0] as NpcServiceReader.Service).strid == "UIIT_STT_NPC_CHATTING_WND_TALKSTART"
		and (herb[2] as NpcServiceReader.Service).strid == "UIIT_MSG_CIRCULATION_WITHDRAW_SKILL",
		"the talk and withdraw tokens (FUN_006fcd60 cases 4 and 0x16)")
	var drawn := NpcServiceReader.talk_menu_lines("Herbalist", herb, func(t: String, f: String) -> String:
		return {"UIIT_STT_NPC_CHATTING_WND_TALKSTART": "Talk to this person.",
			"SN_STORE_POTION_GROUP1": "Purchase/ Sell recovery liquid medicine",
			"UIIT_MSG_CIRCULATION_WITHDRAW_SKILL": "Withdrawing Skill",
			"UIIT_STT_NPC_CHATTING_WND_TALKEND": "End conversation."}.get(t, f))
	_check(drawn == PackedStringArray(["[url=talk]1. Talk to this person.[/url]",
			"[url=shop:STORE_CH_POTION_GROUP1]2. Purchase/ Sell recovery liquid medicine[/url]",
			"[url=withdraw_skill]3. Withdrawing Skill[/url]", "[url=end]4. End conversation.[/url]"]),
		"the herbalist's four lines, as the original's (got %s)" % [drawn])
	# What OpenSRO's server sends the herbalist ({1, 2}; id 10 OPEN).
	_check(_keys(NpcServiceReader.services_from_ids(PackedByteArray([1, 2]), lines)) == ["talk", "shop:STORE_CH_POTION_GROUP1"],
		"{1, 2}: talk, the store line")
	# The Dimensional Gate in 1llywhJ.png: {7, 8}.
	_check(_keys(NpcServiceReader.services_from_ids(PackedByteArray([7, 8]))) == ["recall_designate", "teleport"],
		"{7, 8}: designate, then select teleport area")
	_check(Array(NpcServiceReader.gate_ids(true, true, false)) == [7, 8], "a town gate's client-side set is {7, 8}")
	# The whole order, every id the builder asks for at once (the set is
	# sorted on the wire, the menu is not).
	var all := NpcServiceReader.services_from_ids(PackedByteArray([1, 2, 3, 7, 8, 9, 10, 0x0c, 0x0f, 0x11, 0x12, 0x13,
		0x14, 0x15, 0x16, 0x20, 0x23, 0x27, 0x29]), lines, 7, false, 0, 60)
	_check(_keys(all) == ["talk", "shop:STORE_CH_POTION_GROUP1", "storage", "academy_open", "honor_rank",
			"avatar_magic_option", "recall_designate", "recall_return", "teleport", "guild_leave", "xmas_change",
			"withdraw_skill", "job_guild", "job_guild", "job_guild", "gacha_machine", "gacha_operator", "open_market",
			"special_price", "party_summon", "dungeon_exit"],
		"FUN_00700440's order (got %s)" % [_keys(all)])
	var jobs: Array = all.filter(func(s): return s.key == "job_guild").map(func(s): return s.job_kind)
	_check(jobs == [1, 3, 2], "the job lines go 0x14, 0x16, 0x15 -> kinds 1, 3, 2 (got %s)" % [jobs])
	# Ids that add no line: 4 (the store's repair buttons), 0x0b, 0x0d, 0x0e,
	# 0x17-0x19, 0x1b, 0x1f, 0x21, 0x22, 0x28; 6 (item 0xb, no text).
	_check(NpcServiceReader.services_from_ids(PackedByteArray([4, 6, 0x0b, 0x0d, 0x0e, 0x17, 0x18, 0x19, 0x1b, 0x1f,
		0x21, 0x22, 0x28])).is_empty(), "ids with no line in the builder add none")
	# The gates on id 1 and 3.
	var guild := PackedByteArray([1, 0x0f])
	_check(_keys(NpcServiceReader.services_from_ids(guild, lines, 0)) == ["guild_create"],
		"a guild NPC, no guild: no store line (FUN_009870e0 == 0), the create line")
	_check(_keys(NpcServiceReader.services_from_ids(guild, lines, -1)) == ["shop:STORE_CH_POTION_GROUP1", "guild"],
		"a guild NPC, guild not known yet: the store line and the placeholder")
	_check(_keys(NpcServiceReader.services_from_ids(PackedByteArray([1, 3]), lines, -1, false, 0, 59)) == ["shop:STORE_CH_POTION_GROUP1", "storage", "honor_rank"],
		"a keeper at level 59: no academy line (0x700b96 cmp 0x3c, jb)")
	_check(_keys(NpcServiceReader.services_from_ids(PackedByteArray([0x14]), [], -1, false, 1)).is_empty(),
		"a player with a job gets no join line")
	_check(_keys(NpcServiceReader.services_from_ids(PackedByteArray([1, 3]))) == ["storage", "honor_rank"],
		"a keeper with no tab group (NPC_WC_WAREHOUSE_M): no store line")

func _initialize() -> void:
	_test_codecs()
	_test_state()
	_test_menus()
	if _failures == 0:
		print("npc_talk_net_test: all checks passed")
		quit(0)
	else:
		print("npc_talk_net_test: %d check(s) FAILED" % _failures)
		quit(1)
