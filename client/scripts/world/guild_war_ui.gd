extends Node
class_name GuildWarUi

## Round 844 (lane V): guild war's boxes, messages and panes in the world
## (docs/protocol/guild_war.md). READ in sro_client.exe unless a line says
## otherwise. World3D makes one (_wire_guild_war) and gives it itself.
##
## - The guild window's war panes (GuildWarPanes) redraw on every war change
##   (0x799510 -> 0x5b3c50 / 0x5b3c70); "Request to start the war" opens the
##   request box in state 1 (0x79bbb0(1, 1)), "Request to end the war" the
##   end proposal (0x5bcfe0: MsgBoxSimple, UIIT_STT_AGREEMENT_BOX,
##   SANCTION_ENDWAR_01 + "\n" + _02; OK sends 0x7112 {war id}).
## - A proclamation (0x3080 kind 10, 0x885920) opens the box in state 3; its
##   answer is 0x3080 {1, 1 / 0}, and a Cancel also says WARREFUSAL with the
##   player's own guild (system line and banner).
## - The war's lines and banners (HostileData): GOTOWAR, KILLNEWS and the
##   countdown's "Until the end of war (%d seconds left)" each second from 60
##   (0x781250: timer 0xd, 1000 ms) on GDR_WARNING_WND; the ending and the
##   result in MsgBoxSimple boxes titled UIIT_STT_EVENTGUIDE (0x5b25a0).
## - The guild manager's "War reward gold received" (0x1b): 0x7114 {npc};
##   B114 {1, amount} asks COMPENSATION_01 / _02 (UI_GUILDWAR 0x6f9510), whose
##   OK sends 0x7113 {npc}; B114 {2, 0x4c45} says NOTCOMPENSATION
##   (MsgBoxSimple, UIIT_STT_EVENTGUIDE).
## - Replies' refusals: category 0x10 (0x778190(0x10, code)), the system line.

var world: Node
var hostile: HostileData
var panes: GuildWarPanes
var _box: GuildWarRequestBox
var _countdown := 0
var _timer: Timer
## The values state 1 passed to state 2.
var _declared := {}
## The NPC the reward was asked at.
var _reward_npc := 0

func setup(w: Node) -> void:
	world = w
	hostile = NetClient.guild_data.hostile
	hostile.changed.connect(_on_changed)
	hostile.line.connect(func(key: String, args: Array) -> void: _line(key, args))
	hostile.banner.connect(func(key: String, args: Array) -> void: _banner(key, args))
	hostile.box.connect(_on_box)
	hostile.countdown.connect(_start_countdown)
	hostile.war_ended.connect(_on_war_ended)
	hostile.request_closed.connect(func() -> void: _close_box())
	NetClient.guild_war_proclaimed.connect(_on_proclaimed)
	NetClient.guild_war_result.connect(_on_result)
	NetClient.guild_data.changed.connect(_on_changed)
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(_tick)
	add_child(_timer)

func _hud() -> Node:
	return world.get("_hud_panels") if world != null else null

func _builder() -> UiBuilder:
	var h := _hud()
	return h.get("_builder") as UiBuilder if h != null else null

func _text(key: String, args: Array) -> String:
	return String(world.call("_guild_text", key, args)) if world != null else ""

func _line(key: String, args: Array) -> void:
	var t := _text(key, args)
	print("GUILDWAR line %s %s" % [key, args])
	if t != "":
		world.call("_log_system", t, HudSystemMessage.TYPE_ALWAYS)

func _banner(key: String, args: Array) -> void:
	var t := _text(key, args)
	print("GUILDWAR banner %s %s" % [key, args])
	if t != "":
		world.call("_show_banner", "system", t)

## The guild window's panes, made the first time the window exists.
func ensure_panes() -> GuildWarPanes:
	if panes != null:
		return panes
	var h := _hud()
	if h == null or _builder() == null:
		return null
	var gw = h.call("_guild_window")
	if gw == null:
		return null
	panes = GuildWarPanes.new(gw)
	panes.crest_for = func(n: String) -> Texture2D: return NetClient.crest_cache.texture_for(n)
	panes.declare_pressed.connect(open_declare)
	panes.end_pressed.connect(open_end_proposal)
	(gw as Control).visibility_changed.connect(func() -> void:
		if (gw as Control).visible:
			panes.refresh())
	panes.refresh()
	return panes

func _on_changed() -> void:
	if ensure_panes() != null:
		panes.refresh()
	if world != null:
		world.call("_recolour_guild_lines")
		world.call("_recolour_enemy_plates")

## A MsgBoxSimple: OK only (style 0) or Yes / No (style 1).
func _simple_box(title_key: String, message: String, yes_no: bool) -> PartyMatchConfirm:
	var b := _builder()
	var h := _hud()
	if b == null or h == null:
		return null
	var box := PartyMatchConfirm.new()
	if not box.build(b, message):
		box.free()
		return null
	box.name = "GuildWarBox"
	if box.caption != null:
		box.caption.text = box.text(title_key, title_key)
	if not yes_no:
		var ok := box._find_button(true)
		var no := box._find_button(false)
		if no != null:
			no.visible = false
		if ok != null:
			var at := Vector2(PartyMatchConfirm.SIZE.x / 2.0 - 38.0, ok.position.y)
			ok.position = at
			ok.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(at, ok.size))
			b.set_button_text(ok, box.text("UIIT_CTL_CONFIRM", "OK"))
	h.add_child(box)
	box.centre_on(box.get_viewport_rect().size)
	h.call("_qa_print_buttons", box, "GuildWarBox")
	return box

func _on_box(title_key: String, keys: Array, args: Array) -> void:
	var parts: Array[String] = []
	for k in keys:
		var t := _text(String(k), args if keys.size() == 1 else [])
		parts.append(t if t != "" else String(k))
	print("GUILDWAR box %s %s %s" % [title_key, keys, args])
	_simple_box(title_key, "\n".join(parts), false)

## 0x781250(60): the banner now and each second down to 1; the end button
## stays disabled meanwhile (+0x7c8), re-enabled at 0.
func _start_countdown(seconds: int) -> void:
	_countdown = seconds
	_banner("UIIT_MSG_GUILDWAR_END_COUNTDOWN", [_countdown])
	_timer.start()

func _tick() -> void:
	_countdown -= 1
	if _countdown <= 0:
		_timer.stop()
		hostile.ending = false
		_on_changed()
		return
	_banner("UIIT_MSG_GUILDWAR_END_COUNTDOWN", [_countdown])

## 0x1c: an action at a hostile guild's member is cancelled (0x7074 {2},
## INFERRED the cancel) before the entry goes.
func _on_war_ended(_war_id: int, other_name: String) -> void:
	if world == null:
		return
	var sel := int(world.get("_selected_character"))
	if sel < 0:
		return
	var line: Dictionary = NetClient.user_guilds.get(sel & 0xffffffff, {})
	# OURS: the server's keep-up ends at its next swing (the pair is no
	# longer hostile); the client prints the cancel it would send.
	if String(line.get("guild_name", "")) == other_name:
		print("GUILDWAR war with %s ended: the action at %d stops" % [other_name, sel])

func _close_box() -> void:
	if is_instance_valid(_box):
		_box.close()
	_box = null

func _open(which: int, values: Dictionary) -> GuildWarRequestBox:
	_close_box()
	var b := _builder()
	var h := _hud()
	if b == null or h == null:
		return null
	var box := GuildWarRequestBox.new()
	if not box.build_box(b, which, values):
		box.free()
		return null
	h.add_child(box)
	box.centre_on(box.get_viewport_rect().size)
	_box = box
	h.call("_qa_print_buttons", box, "RequestGuildWar%d" % which)
	print("GUILDWAR box state %d %s" % [which, values])
	return box

## Button 52 (0x5bd180 -> 0x79bbb0(1, 1)): state 1.
func open_declare() -> void:
	var box := _open(GuildWarRequestBox.State.INPUT, {})
	if box == null:
		return
	box.own_guild_name = NetClient.guild_data.guild_name
	box.refused.connect(func(key: String, args: Array) -> void:
		_line(key, args)
		_banner(key, args))
	box.gold_wanted.connect(func() -> void: _open_wager_box(box))
	box.proclaim.connect(func(n: String, idx: int, period: int, gold: int) -> void:
		_declared = {"guild_name": n, "point_index": idx, "period": period, "gold": gold}
		var confirm := _open(GuildWarRequestBox.State.CONFIRM, _declared)
		if confirm != null:
			confirm.proclaim.connect(func(n2: String, idx2: int, period2: int, gold2: int) -> void:
				NetClient.guild_war_declare(n2, period2, idx2, gold2)
				hostile.pending = 1
				print("GUILDWAR declare %s idx %d period 0x%x gold %d" % [n2, idx2, period2, gold2])))

## The wager's gold box (INFERRED the store's money box, 0x71abf0 /
## 0x71a880): at most min(the gold carried, 500,000,000).
func _open_wager_box(box: GuildWarRequestBox) -> void:
	var h := _hud()
	var b := _builder()
	if h == null or b == null:
		return
	var carried := _own_gold()
	var gb := StoreMessageBox.new()
	gb.name = "GuildWarGold"
	if not gb.build(b, StoreMessageBox.Kind.EXCHANGE_GOLD, {"count": box.gold, "min": 0,
			"max": mini(maxi(0, carried), GuildWarNet.MAX_WAGER)}):
		gb.free()
		return
	h.add_child(gb)
	gb.global_position = gb.screen_position(gb.get_viewport_rect().size)
	gb.confirmed.connect(func(n: int) -> void:
		if is_instance_valid(box):
			box.set_gold(n))

## The gold carried (the inventory's readout, HudPanels' stats).
func _own_gold() -> int:
	var h := _hud()
	if h == null:
		return 0
	var st = h.get("_stats")
	if st != null:
		return int(st.gold)
	var c = h.get("_storage_carried")
	return int(c) if c != null else 0

## 0x3080 kind 10: state 3, the master's own gold beside the wager.
func _on_proclaimed(info: Dictionary) -> void:
	var gold_now := _own_gold()
	var values := {"guild_name": String(info["guild_name"]), "point_index": int(info["victory_index"]),
		"period": int(info["period"]), "gold": int(info["gold"]), "own_gold": gold_now}
	hostile.pending = 2
	var box := _open(GuildWarRequestBox.State.AGREE, values)
	if box == null:
		return
	box.answered.connect(func(accept: bool) -> void:
		NetClient.guild_war_answer(accept)
		hostile.pending = 0
		if not accept:
			_line("UIIT_MSG_GUILDWAR_WARREFUSAL", [NetClient.guild_data.guild_name])
			_banner("UIIT_MSG_GUILDWAR_WARREFUSAL", [NetClient.guild_data.guild_name]))

## Button 53 with a war selected (0x5bcfe0).
func open_end_proposal(war_id: int) -> void:
	var war := hostile.war(war_id)
	if war == null:
		return
	var a := _text("UIIT_MSG_GUILDWAR_SANCTION_ENDWAR_01", [war.name])
	var b := _text("UIIT_MSG_GUILDWAR_SANCTION_ENDWAR_02", [])
	var box := _simple_box("UIIT_STT_AGREEMENT_BOX", a + "\n" + b, true)
	if box != null:
		box.confirmed.connect(func() -> void:
			print("GUILDWAR end proposal war %d" % war_id)
			NetClient.guild_war_end(war_id))

## The guild manager's line 0x1b (CIF_NPCTalk 0x7020c0 case 0x1b).
func ask_reward(npc_uid: int) -> void:
	_reward_npc = npc_uid
	NetClient.guild_war_ask_reward(npc_uid)

func _on_result(op: int, r: Dictionary) -> void:
	print("GUILDWAR result 0x%04x %s" % [op, r])
	if r.is_empty():
		return
	if op == GuildWarNet.OP_DECLARE_RESULT:
		hostile.pending = 0
	if op == GuildWarNet.OP_ASK_REWARD_RESULT:
		if bool(r["ok"]):
			var a := _text("UIIT_CTL_GUILDWAR_COMPENSATION_01", [int(r["amount"])])
			var b := _text("UIIT_CTL_GUILDWAR_COMPENSATION_02", [])
			var box := _simple_box("UIIT_STT_EVENTGUIDE", a + "\n" + b, true)
			if box != null:
				var npc := _reward_npc
				box.confirmed.connect(func() -> void: NetClient.guild_war_claim(npc))
			return
		if int(r["code"]) == GuildWarNet.CODE_NO_REWARD:
			_simple_box("UIIT_STT_EVENTGUIDE", _text("UIIT_CTL_GUILDWAR_NOTCOMPENSATION", []), false)
			return
	if not bool(r["ok"]):
		var key := GuildOpsNet.error_key(int(r["code"]))
		if key == "":
			print("GUILDWAR refusal code 0x%x -- the client has no message for it" % int(r["code"]))
			return
		_line(key, [])
