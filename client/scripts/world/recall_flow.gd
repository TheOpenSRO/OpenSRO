extends RefCounted
class_name RecallFlow

const ErrorText = preload("res://scripts/net/error_text.gd")

## Round 869 (lane C1): the instance NPCs' talk lines on the client -- the
## exit NPC (interaction 0x29, "Exit Dungeon") and the party recall NPC
## (interaction 0x27, "Summon Party member") -- with the summon window and
## the summoned member's question. docs/protocol/game_worlds.md 5,
## forgotten_world.md 8; the bytes are InstanceTalkNet's. World3D owns one.
## READ unless a line says otherwise:
##
## - the lines (CIF_NPCTalk::FUN_007020c0): type 0x3e sends 0x751D {talk
##   NPC}, type 0x3d sends 0x7519 {talk NPC}; neither touches the talk window
##   (both cases end at c:0x703c40 returning 1). The ids map to the types in
##   the menu builder (c:0x70143b..0x7014c5: 0x27 -> 0x3d, 0x29 -> 0x3e;
##   NpcServiceReader.TAIL_LINES);
## - 0xB51D (c:0x89a760): 1 nothing (the warp follows); else the code through
##   category 1 -- which shows nothing for the exit's own refusals
##   (ErrorText.exit_line);
## - 0xB519 (c:0x89a590): the summon window's list cleared first; 1 -> the
##   rows and the window shown (SummonPartyWindow); else category 0xd;
## - the window's Summon sends 0x751A {char id}; 0xB51A: 1 nothing, else
##   category 0x23 (ErrorText.summon_line);
## - the member's push 0x751A (c:0x89f010 -> c:0x608a60): +0x7c8 = requester,
##   +0x7cc = the second u32; if no box is up (+0x7c4 == 0) a MsgBoxSimple
##   through GInterface::FUN_007884e0 (class 0xee95a0 resized to 360 x 151,
##   style 1 Yes / No, centred: the same box as GInterface 0x788270) titled
##   UIIT_STT_CONFIRM_BOX with UIIT_STT_GNGWC_PARTY_MEMBER_CALL and the name
##   (c:0x608b81..0x608bdc); a box already up keeps its text. Then timer 10
##   for 20,000 ms (c:0x608bf6) -- whose end (vslot_005, c:0x607680) closes
##   the box and zeroes the ids, sending nothing;
## - the answer (c:0x6076d0): 0x751C {+0x7c8, the own JID, Yes ? 1 : 0}, the
##   box closed; 0xB51C: 2 -> category 0xd, else nothing.
## Every refusal line goes to the system window (the dispatcher's colour
## 0xffdbc99b, HudSystemMessage.TYPE_ALWAYS -- as JobGuildFlow's).

## The member's question's life (READ c:0x608bf6: 0x4e20 ms).
const ANSWER_WAIT_SEC := 20.0

var world: Node
var hud: HudPanels
var window: SummonPartyWindow = null
## The member's question (+0x7c4), its requester (+0x7c8) and second u32.
var box: PartyMatchConfirm = null
var requester := 0
var requester_second := 0
## The box's timer generation (a later push restarts it).
var _box_gen := 0
var _dead := false
## The last lines shown, for the QA log and the tests.
var lines: PackedStringArray = []
## Sends a message: Callable(op, payload). Unset, NetClient's.
var send: Callable

func _init(w: Node, h: HudPanels) -> void:
	world = w
	hud = h
	for op in InstanceTalkNet.SERVER_OPCODES:
		NetClient.register_handler(op, _on_message.bind(op))

## The world leaves the tree: nothing it holds is touched again (round 866's
## rule). NetClient keeps the handlers until the next world's flow replaces
## them; a dead flow ignores what they bring.
func detach() -> void:
	_dead = true
	world = null
	hud = null
	window = null
	box = null

func _send(op: int, payload: PackedByteArray) -> void:
	print("RECALL send 0x%04X %s" % [op, payload.hex_encode()])
	if send.is_valid():
		send.call(op, payload)
	elif NetClient.is_connected_to_server():
		NetClient._send(op, payload)

func _table() -> UiTextTable:
	return world.get("_ui_text_table") if world != null else null

func _text(key: String, fallback: String) -> String:
	if world == null:
		return fallback
	return String(world.call("_resolve_any_text", key, fallback))

func _line(text: String) -> void:
	lines.append(text)
	if world != null and text != "":
		world.call("_log_system", text, HudSystemMessage.TYPE_ALWAYS)

## A talk line's action; false when the key is not one of these.
func handle_service(key: String) -> bool:
	if key != "party_summon" and key != "dungeon_exit":
		return false
	var npc := int(world.call("_talk_npc_uid")) if world != null else 0
	if key == "dungeon_exit":
		_send(InstanceTalkNet.OP_EXIT, InstanceTalkNet.encode_npc(npc))
	else:
		_send(InstanceTalkNet.OP_RECALL_LIST, InstanceTalkNet.encode_npc(npc))
	return true

func _on_message(data: PackedByteArray, op: int) -> void:
	if _dead:
		return
	handle(op, data)

func handle(op: int, data: PackedByteArray) -> void:
	print("RECALL recv 0x%04X %s" % [op, data.hex_encode()])
	match op:
		InstanceTalkNet.OP_EXIT_ACK:
			var code := InstanceTalkNet.refusal_code(data)
			if code >= 0:
				_refusal(1, code)
		InstanceTalkNet.OP_RECALL_LIST_ACK:
			var r := InstanceTalkNet.decode_list(data)
			if r.is_empty():
				return
			var w := summon_window()
			if not bool(r["ok"]):
				if w != null:
					w.clear_entries()
				_refusal(0xd, int(r["code"]))
				return
			if w != null:
				w.fill(r["entries"])
				print("RECALL window rows %s" % [w.report()])
		InstanceTalkNet.OP_SUMMON_ACK:
			var code := InstanceTalkNet.refusal_code(data)
			if code >= 0:
				_refusal(0x23, code)
		InstanceTalkNet.OP_ANSWER_ACK:
			var code := InstanceTalkNet.refusal_code(data, true)
			if code >= 0:
				_refusal(0xd, code)
		InstanceTalkNet.OP_SUMMON:
			var p := InstanceTalkNet.decode_push(data)
			if not p.is_empty():
				on_push(int(p["requester"]), int(p["second"]), String(p["name"]))

## A refusal through the error dispatcher; nothing for a code with no row.
func _refusal(category: int, code: int) -> void:
	var t := _table()
	var line := ""
	match category:
		1:
			line = ErrorText.exit_line(code, t)
		0x23:
			line = ErrorText.summon_line(code, t)
		_:
			line = ErrorText.interaction_line(code, t)
	print("RECALL refused, category 0x%x code 0x%x (%s)" % [category, code, line if line != "" else "no message in the client"])
	if line != "":
		_line(line)

## The summon window, built on first use (the client loads it at game start;
## OURS: here on the first 0xB519, which shows the same thing).
func summon_window() -> SummonPartyWindow:
	if window != null and is_instance_valid(window):
		return window
	if hud == null:
		return null
	var w := SummonPartyWindow.new()
	if not w.build_window(hud.job_builder()):
		w.free()
		return null
	w.name_of = func(id: int) -> String:
		var m: PartyNet.Member = NetClient.party.member(id)
		return m.member_name if m != null else ""
	w.summon_requested.connect(func(id: int) -> void:
		_send(InstanceTalkNet.OP_SUMMON, InstanceTalkNet.encode_summon(id)))
	hud.add_child(w)
	window = w
	return w

## The push (c:0x608a60).
func on_push(req: int, second: int, who: String) -> void:
	requester = req
	requester_second = second
	if box == null or not is_instance_valid(box) or box.is_queued_for_deletion():
		var fmt := _text("UIIT_STT_GNGWC_PARTY_MEMBER_CALL", "%s is summoning you. Do you wish to accept the summon?")
		var msg := fmt.replace("%s", who) if fmt.count("%s") == 1 else fmt
		box = PartyMatchConfirm.new()
		if hud == null or not box.build(hud.job_builder(), msg):
			box.free()
			box = null
		else:
			box.name = "SummonPartyQuestion"
			box.confirmed.connect(func() -> void: answer(true))
			box.declined.connect(func() -> void: answer(false))
			hud.open_job_box(box)
			print("RECALL question: '%s'" % msg)
	_box_gen += 1
	var gen := _box_gen
	if hud != null and hud.is_inside_tree():
		hud.get_tree().create_timer(ANSWER_WAIT_SEC).timeout.connect(func() -> void:
			if gen == _box_gen and not _dead:
				expire_box())

## Timer 10's end (vslot_005): the box closed, the ids zeroed, nothing sent.
func expire_box() -> void:
	print("RECALL question expired (20 s): closed, nothing sent")
	_close_box()
	requester = 0
	requester_second = 0

func _close_box() -> void:
	if box != null and is_instance_valid(box):
		box.close()
	box = null

## The box's answer (c:0x6076d0).
func answer(accept: bool) -> void:
	_send(InstanceTalkNet.OP_ANSWER, InstanceTalkNet.encode_answer(requester, NetClient.party.own_jid, accept))
	# The box's own button closes it (PartyMatchConfirm); the client destroys
	# it here too (c:0x607707..0x60771a).
	box = null

## The window's state for the QA log.
func report() -> String:
	var w := window if window != null and is_instance_valid(window) else null
	return JSON.stringify({"window": w != null and w.visible, "rows": w.report() if w != null else [],
		"selected": w.selected if w != null else -1,
		"button_enabled": w != null and w.summon_button() != null and not w.summon_button().disabled,
		"question": box != null and is_instance_valid(box) and box.visible, "requester": requester, "lines": lines})
