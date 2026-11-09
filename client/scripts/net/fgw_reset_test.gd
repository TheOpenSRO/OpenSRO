extends SceneTree

## Round 872 (OURS): the Forgotten World timer reset on the client -- the
## Test Items NPC's action line (NpcShopDefNet.OP_ACTION_DEF, the bytes
## server/internal/testnpc's TestResetActionAndTicketTab pins) after its store
## lines, the request OP_ACTION, the confirm box with the ticket's text
## (MsgBoxInif.Kind.DUNGEON_TICKET), and the answer OP_TIMERS_RESET (the bytes
## server/internal/session's TestTimersResetBytes pins) clearing the holes'
## cool time group 0x71 and the re-entry icon of group 1 at once, and
## nothing else. Synthetic data; no game data.
##   godot4 --headless --path client --script res://scripts/net/fgw_reset_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_action_lines()
	_answer()
	_cooldowns()
	_icon()
	_box()
	_ticket()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _action_lines() -> void:
	# testnpc: EncodeActions(0x7f000123) of {1, "R", "K"}.
	var b := PackedByteArray([0x23, 0x01, 0x00, 0x7f, 0x01, 0x01, 0x01, 0x00, 0x52, 0x01, 0x00, 0x4b])
	var d := NpcShopDefNet.decode_actions(b)
	_check(int(d.get("uid", 0)) == 0x7f000123 and (d["actions"] as Array).size() == 1, "OP_ACTION_DEF decodes (got %s)" % str(d))
	var a: Dictionary = (d["actions"] as Array)[0]
	_check(int(a["id"]) == 1 and String(a["label"]) == "R" and String(a["confirm"]) == "K", "the action's id, label and confirm key")
	_check(NpcShopDefNet.decode_actions(b.slice(0, b.size() - 1)).is_empty(), "a truncated message is refused")
	_check(NpcShopDefNet.decode_actions(b + PackedByteArray([0])).is_empty(), "a trailing byte is refused")
	# The talk window: the store lines first, the action after them.
	var def := {"uid": 0x7f000123, "greeting": "", "lines": [{"label": "Purchase Dimension Holes", "tabs": []}]}
	NpcShopDefNet.merge_actions(def, d)
	var services := NpcServiceReader.services_from_ids(PackedByteArray([1]), NpcShopDefNet.store_lines(def))
	var keys: Array = []
	for s in services:
		keys.append((s as NpcServiceReader.Service).key)
	for l in NpcShopDefNet.action_lines(def):
		keys.append(String(l["key"]))
	_check(keys == ["shop:custom:0", "npcaction:1"], "the store line, then the action line (got %s)" % str(keys))
	_check(int(NpcShopDefNet.action_of(def, "npcaction:1").get("id", 0)) == 1, "the key names the action")
	_check(NpcShopDefNet.action_of(def, "npcaction:2").is_empty() and NpcShopDefNet.action_of(def, "shop:custom:0").is_empty(),
		"another id or a store key names none")
	_check(NpcShopDefNet.encode_action(0x7f000123, 1) == PackedByteArray([0x23, 0x01, 0x00, 0x7f, 0x01]),
		"OP_ACTION {u32 npc, u8 id} (testnpc.EncodeAction)")
	_check(NpcShopDefNet.OP_ACTION_DEF == 0x00bd and NpcShopDefNet.OP_ACTION == 0x00be and GameWorldNet.OP_TIMERS_RESET == 0x00bf,
		"the opcodes are the server's")

func _answer() -> void:
	# session: TimersReset{1, "ok", [0x71], [1]}.Encode().
	var b := PackedByteArray([1, 2, 0, 0x6f, 0x6b, 1, 0x71, 0, 0, 0, 1, 1, 0, 0, 0])
	var r := GameWorldNet.decode_timers_reset(b)
	_check(int(r.get("status", 0)) == GameWorldNet.TIMERS_RESET_DONE and String(r["text"]) == "ok", "OP_TIMERS_RESET's status and line")
	_check(r["cool_groups"] == PackedInt32Array([0x71]) and r["world_groups"] == PackedInt32Array([1]), "its groups (got %s)" % str(r))
	_check(GameWorldNet.decode_timers_reset(b.slice(0, b.size() - 1)).is_empty(), "a truncated answer is refused")
	var nothing := GameWorldNet.decode_timers_reset(PackedByteArray([2, 0, 0, 0, 0]))
	_check(int(nothing.get("status", 0)) == GameWorldNet.TIMERS_RESET_NOTHING and (nothing["cool_groups"] as PackedInt32Array).is_empty(),
		"nothing to reset: no group")

func _cooldowns() -> void:
	var cd := ItemCooldowns.new()
	cd.arm(ItemCooldowns.data_key(35883, 0x71), 18000000)
	cd.arm(ItemCooldowns.data_key(22936, 0xA7), 60000)
	cd.arm(ItemCooldowns.data_key(9, 0), 5000)
	cd.arm("k1", 1000)
	_check(cd.clear_group(0x71), "the holes' group 0x71 was running and is cleared")
	_check(cd.left_ms("g113") == 0 and cd.ratio("g113") == 0.0, "nothing left of it: the slot's sweep and time go")
	_check(cd.left_ms("g167") == 60000 and cd.left_ms("r9") == 5000 and cd.left_ms("k1") == 1000 and cd.count() == 3,
		"another group, an item's own and a potion kind stay")
	_check(not cd.clear_group(0x71), "a second clear finds nothing")
	var hole := ItemTableReader.Item.new()
	hole.id = 35884
	hole.type_ids = PackedInt32Array([3, 3, 12, 7])
	hole.cool_group = 0x71
	hole.cool_ms = 18000000
	_check(DimensionHole.reuse_left_ms(hole, func(k: String) -> int: return cd.left_ms(k)) == 0,
		"so a hole's own re-use check (c:0x7972aa) lets the next one go at once")

func _icon() -> void:
	var board := HudBuffBoard.new(null, SkillBuffCatalog.new(null))
	root.add_child(board)
	board.add_world_group(1, "icon\\etc\\x.ddj", 18000000, 17000000)
	board.add_world_group(2, "icon\\etc\\y.ddj", 18000000, 17000000)
	_check(board.world_group_entry(1) != null, "group 1's re-entry icon is up")
	_check(board.remove_world_group(1), "the reset takes it down")
	_check(board.world_group_entry(1) == null and board.world_group_entry(2) != null, "group 1 gone, group 2 kept")
	_check(not board.remove_world_group(1) and not board.remove_world_group(7), "no icon: nothing to take down")
	board.queue_free()

func _box() -> void:
	var builder := MsgBoxFixture.builder()
	var box := MsgBoxInif.new()
	_check(box.build_kind(builder, MsgBoxInif.Kind.DUNGEON_TICKET, "FgwResetConfirm"), "the reset's box builds")
	_check(box.size == Vector2(500, 144), "box 0x2e's size (got %s)" % str(box.size))
	var l0 := box.line(0)
	_check(box.caption.text == "<UIIT_STT_CONFIRM_BOX>" and l0 in ["<UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN>", "UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN"],
		"title UIIT_STT_CONFIRM_BOX, the ticket's text key (got %s / %s)" % [box.caption.text, l0])
	var said: Array = []
	box.accepted.connect(func(_t: String) -> void: said.append("yes"))
	box.button("GDR_MBIN_BTN_OK").pressed.emit()
	_check(said == ["yes"], "Yes accepts")
	box.free()
	var two := MsgBoxInif.split_sentence("If you use the Dungeon entrance ticket, dungeon cooltime will  disappear. Do you want to use the entrance ticket?")
	_check(two == ["If you use the Dungeon entrance ticket, dungeon cooltime will  disappear.", "Do you want to use the entrance ticket?"],
		"the archive's English text on two lines (got %s)" % str(two))
	_check(MsgBoxInif.split_sentence("One line") == ["One line"], "one sentence stays one line")

func _ticket() -> void:
	_check(HudPanels.is_fgw_ticket(PackedInt32Array([3, 3, 13, 23])), "3/3/13/23 is the Forgotten World ticket")
	_check(not HudPanels.is_fgw_ticket(PackedInt32Array([3, 3, 13, 22])), "the Egypt ticket 3/3/13/22 is not")
