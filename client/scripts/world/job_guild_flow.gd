extends RefCounted
class_name JobGuildFlow

const ErrorText = preload("res://scripts/net/error_text.gd")

## Round 799: the job guild on the client -- the talk lines' actions, the
## replies' windows and lines, and the job exp notice -- as sro_client.exe
## does them (docs/protocol/jobs.md "The client's job UI"; the reading of
## each step is beside it). World3D owns one; it holds the HUD and calls back
## into the world for the talk box, the text tables and the system window.
##
## READ (sro_client.exe):
## - the talk lines (CIF_NPCTalk::FUN_007020c0's switch at 0x70214a): join
##   and leave ask first (confirm kinds 4 / 5, UIIT_STT_JOBGUILD_JOIN_WINDOW /
##   _WITHD_WINDOW) and their OK sends 0x70e1 / 0x70e2; the alias lines open
##   the alias window (FUN_0079c850); the outcome line sends 0x70e5 op 0 and
##   the reply's collect line op 1; the ranking lines send 0x70e4 only when
##   the kind's table is not held, else show it (0x703130 / 0x703192); the
##   old-job line sends 0x70e6;
## - 0xB0E1 / 0xB0E2 (JobGuild_OnJoinResult 0x8890b0, _OnWithdrawResult
##   0x889210): the talk menu rebuilt, UIIT_MSG_JOBGUILD_JOIN_COMPELET /
##   _WITHD_COMPELET in the system window (type 5);
## - 0xB0E3 (UI_ALIAS::FUN_00889370): op 0 marks the window's name checked,
##   op 1 says UIIT_MSG_ALIAS_CREATE_COMPLETE (the alias was empty) or
##   _MODIFY_COMPLETE (type 5) and rebuilds the menu;
## - 0xB0E5 (0x8830f0): op 0 rewrites the talk box (FUN_006fdd40) with
##   UIIT_STT_OUTCOME_WINDOW (the name, the amount grouped) and the collect
##   line when the amount is not 0; op 1 closes it and says
##   UIIT_MSG_OUTCOM_COMPLETE with the amount (type 5);
## - every refusal: FUN_00778190(0x18, code, ...), the error dispatcher
##   (ErrorText.job_line);
## - 0x30E6 (0x884dd0): JobText.exp_line -- type 1 lines, the level-up as the
##   warning banner (0x77b580).

var world: Node
var hud: HudPanels
## {"kind:type": rows} -- the client caches each table until it is shown
## again (GInterface +0x458.., READ); when it drops them is OPEN, so a table
## is kept for the session (OURS).
var rank_cache := {}
## {level: [trader, thief, hunter]} (LevelDataReader.parse_job_exp).
var job_table: Dictionary = {}
var alias_box: JobAliasBox
## The ranking asked for, shown on its reply.
var _rank_pending := {}

func _init(w: Node, h: HudPanels) -> void:
	world = w
	hud = h

func _text(key: String, fallback: String) -> String:
	return String(world.call("_resolve_any_text", key, fallback))

func _npc() -> int:
	return int(world.call("_talk_npc_uid"))

func _syslog(text: String, type: int) -> void:
	world.call("_log_system", text, type)

## A talk line's action; false when the key is not a job line.
func handle_service(key: String) -> bool:
	if not key.begins_with("job_"):
		return false
	var parts := key.split(":")
	var line := parts[0].trim_prefix("job_")
	var sub := int(parts[1]) if parts.size() > 1 else 0
	var npc := _npc()
	if not NetClient.is_connected_to_server():
		_syslog("The job guild needs the server.", HudSystemMessage.TYPE_ALWAYS)
		return true
	match line:
		"join":
			_confirm("UIIT_STT_JOBGUILD_JOIN_WINDOW", "<sml2><center>Join job league?</center></sml2>",
				func() -> void: NetClient.send_job_join(npc, sub))
		"withdraw":
			_confirm("UIIT_STT_JOBGUILD_WITHD_WINDOW", "<sml2><center>Leave job league?</center></sml2>",
				func() -> void: NetClient.send_job_withdraw(npc))
		"alias_create", "alias_modify":
			open_alias(line == "alias_modify", npc)
		"outcome":
			NetClient.send_job_reward(npc, 0)
		"collect":
			NetClient.send_job_reward(npc, 1)
		"rank_activity", "rank_contribution":
			var t := JobNet.RANK_ACTIVITY if line == "rank_activity" else JobNet.RANK_CONTRIBUTION
			var ck := "%d:%d" % [sub, t]
			if rank_cache.has(ck):
				show_rank(sub, t, rank_cache[ck])
			else:
				_rank_pending[ck] = true
				NetClient.send_job_ranking(npc, sub, t)
		"prev":
			NetClient.send_job_prev(npc)
		_:
			return false
	return true

func _confirm(key: String, fallback: String, yes: Callable) -> void:
	var box := JobConfirmBox.new()
	if not box.build_sml(hud.job_builder(), _text(key, fallback)):
		box.queue_free()
		return
	box.confirmed.connect(yes)
	hud.open_job_box(box)

func open_alias(modify: bool, npc: int) -> void:
	if alias_box != null and is_instance_valid(alias_box):
		alias_box.close()
	alias_box = JobAliasBox.new()
	alias_box.name_rule = func(s: String) -> bool:
		var f := NameFilter.shared(world.get("_media_pk2"))
		return f == null or f.name_ok(s)
	if not alias_box.build_alias(hud.job_builder(), modify, npc, NetClient.job_alias, NetClient.current_character_name,
			int(world.get("_player_level"))):
		alias_box.queue_free()
		alias_box = null
		return
	alias_box.check_requested.connect(func(n: int, a: String) -> void: NetClient.send_job_alias(n, 0, a))
	alias_box.set_requested.connect(func(n: int, a: String) -> void: NetClient.send_job_alias(n, 1, a))
	alias_box.refused.connect(func(code: int) -> void: _refusal(code))
	alias_box.confirm_opened.connect(func(b: JobConfirmBox) -> void: hud.open_job_box(b))
	hud.open_job_box(alias_box)

func show_rank(kind: int, t: int, rows: Array) -> void:
	var box := JobRankBox.new()
	var me := {"kind": NetClient.job_kind, "alias": NetClient.job_alias, "level": NetClient.job_level,
		"exp": NetClient.job_exp, "contribution": NetClient.job_contribution}
	if not box.build_rank(hud.job_builder(), t == JobNet.RANK_CONTRIBUTION, kind, rows, job_table, me):
		box.queue_free()
		return
	hud.open_job_box(box)

## A refusal through the error dispatcher (category 0x18): nothing shown for
## a code it has no message for, as the client.
func _refusal(code: int) -> void:
	var line := ErrorText.job_line(code, world.get("_ui_text_table"))
	print("JOB: refused, code 0x%x (%s)" % [code, line if line != "" else "no message in the client"])
	if line != "":
		_syslog(line, HudSystemMessage.TYPE_ALWAYS)

func on_reply(op: int, d: Dictionary) -> void:
	if not bool(d.get("ok", false)):
		_refusal(int(d.get("code", 0)))
		return
	match op:
		JobNet.OP_JOIN_RESULT:
			_syslog(_text("UIIT_MSG_JOBGUILD_JOIN_COMPELET", "Joined the job league."), HudSystemMessage.TYPE_GAME)
			world.call("_refresh_open_talk_menu")
		JobNet.OP_WITHDRAW_RESULT:
			_syslog(_text("UIIT_MSG_JOBGUILD_WITHD_COMPELET", "Left the job league."), HudSystemMessage.TYPE_GAME)
			world.call("_refresh_open_talk_menu")
		JobNet.OP_ALIAS_RESULT:
			if int(d["op"]) == 0:
				if alias_box != null and is_instance_valid(alias_box):
					alias_box.on_checked(String(d["alias"]))
			else:
				var created := bool(d.get("was_empty", true))
				_syslog(_text("UIIT_MSG_ALIAS_CREATE_COMPLETE" if created else "UIIT_MSG_ALIAS_MODIFY_COMPLETE",
					"Alias has been created." if created else "Alias has been changed."), HudSystemMessage.TYPE_GAME)
				world.call("_refresh_open_talk_menu")
		JobNet.OP_RANKING_RESULT:
			var ck := "%d:%d" % [int(d["kind"]), int(d["type"])]
			rank_cache[ck] = d["rows"]
			if _rank_pending.has(ck):
				_rank_pending.erase(ck)
				show_rank(int(d["kind"]), int(d["type"]), d["rows"])
		JobNet.OP_REWARD_RESULT:
			var gold := int(d["gold"])
			if int(d["op"]) == 0:
				var fmt := _text("UIIT_STT_OUTCOME_WINDOW", "You have worked hard for a week.\n[%s]will receive following reward.\nReward : [%s]gold")
				var body := JobAliasBox._format3(fmt.replace("\\n", "\n"), NetClient.current_character_name, JobText.grouped(gold), "")
				var services: Array = []
				if gold != 0:
					services.append(NpcServiceReader.Service.new("job_collect:%d" % NetClient.job_kind, "Collect this week's outcome",
						NpcServiceReader.JOB_COLLECT_STRID, NetClient.job_kind))
				world.call("_replace_talk", body, services)
			else:
				hud.close("npctalk")
				var line := JobAliasBox._format3(_text("UIIT_MSG_OUTCOM_COMPLETE", "A reward of [%s]gold has been received."),
					JobText.grouped(gold), "", "")
				_syslog(line, HudSystemMessage.TYPE_GAME)
		JobNet.OP_PREV_JOB_RESULT:
			var box := PrevJobInfoBox.new()
			if box.build_prev(hud.job_builder(), d["levels"], d["exps"], hud.own_race_europe(), job_table):
				hud.open_job_box(box)
			else:
				box.queue_free()

## 0x30E6's lines (JobText.exp_line).
func on_exp(d: Dictionary, old_level: int, old_exp: int) -> void:
	var kind := int(d["kind"])
	var l := JobText.exp_line(kind, old_level, old_exp, int(d["level"]), int(d["exp"]), job_table)
	if String(l["banner_key"]) != "":
		var cls := _text(JobText.class_key(kind, int(d["level"]), hud.own_race_europe()), "")
		var banner := JobAliasBox._format3(_text(String(l["banner_key"]), "Job level increased to [%s]"), cls, "", "")
		world.call("_show_banner", "job_level_up", banner)
	if String(l["key"]) != "":
		var fmt := _text(String(l["key"]), "Job experience [%d]")
		_syslog(fmt.replace("%d", str(int(l["amount"]))), HudSystemMessage.TYPE_GAIN)
