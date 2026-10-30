extends SceneTree

## Round 844 lane G (part 2): the master-release vote's messages and window,
## the GP history's reply and window, the recall's question and answer, the
## guild goods' GP price (tooltip line and buy box row). Against the real
## Media.pk2 (READ notes in GuildPart2Net and each window).
##   godot4 --headless --path client --script res://scripts/ui/hud/guild844b_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _run() -> void:
	# 1. The vote's messages (no archive needed).
	var v := GuildPart2Net.new()
	var shown: Array = []
	v.shown.connect(func(w: String, k: String, a: Array) -> void: shown.append([w, k, a]))
	var k1 := PackedByteArray([1])
	k1.append_array(_u32(7))
	k1.append(0)
	k1.append_array(_u32(600000))
	v.handle(GuildPart2Net.OP_VOTE_UPDATE, k1)
	_check(v.vote_id == 7 and not v.vote_loaded and v.vote_ms == 600000, "kind 1 records the vote, not loaded")
	var b106 := PackedByteArray([1])
	b106.append_array(_u32(7))
	b106.append_array(_u32(540000))
	b106.append(2)
	b106.append_array(_u32(11))
	b106.append(0)
	b106.append_array(_u32(12))
	b106.append(1)
	var loaded := [false]
	v.vote_state_loaded.connect(func() -> void: loaded[0] = true)
	v.handle(GuildPart2Net.OP_VOTE_STATE_RESULT, b106)
	_check(loaded[0] and v.vote_list == [11, 12] and v.vote_counts == [0, 1], "B106 loads the list and counts")
	var k4 := PackedByteArray([4])
	k4.append_array(_u32(7))
	k4.append_array(PackedByteArray([1, 0, 1]))
	v.handle(GuildPart2Net.OP_VOTE_UPDATE, k4)
	_check(v.vote_counts == [1, 0], "kind 4 moves a ballot (old -1, new count)")
	var k3 := PackedByteArray([3])
	k3.append_array(_u32(7))
	k3.append(1)
	k3.append_array(_u32(11))
	v.handle(GuildPart2Net.OP_VOTE_UPDATE, k3)
	_check(v.vote_id == 0 and shown.back()[1] == "UIIT_MSG_MRELEASE_BEELETED" and shown.back()[2] == [11], "kind 3 ends it with the winner")
	v.handle(GuildPart2Net.OP_VOTE_START_RESULT, PackedByteArray([2, 0x33, 0x4c]))
	_check(shown.back()[1] == "UIIT_MSG_MRELEASEERR_NOTVOTETIME", "B105 0x4c33's box")
	v.set_from_block([[9, 0, 300000]])
	_check(v.vote_id == 9 and v.vote_ms == 300000, "the block's tail brings a running vote")
	v.set_from_block([])
	_check(v.vote_id == 0, "and a block without one clears it")
	# The GP history's reply.
	var b501 := PackedByteArray([1, 1])
	b501.append_array(_u32(1761786000))
	b501.append_array(PackedByteArray([3, 0]))
	b501.append_array("Pai".to_utf8_buffer())
	b501.append_array(_u32(5400))
	b501.append(5)
	var hist: Array = []
	v.gp_history.connect(func(e: Array) -> void: hist.append_array(e))
	v.handle(GuildPart2Net.OP_GP_HISTORY_RESULT, b501)
	_check(hist.size() == 1 and hist[0]["name"] == "Pai" and hist[0]["gp"] == 5400 and hist[0]["kind"] == 5, "B501's entry")
	# The recall: a question, a yes, B031 {1} -> the gauge.
	var asked: Array = []
	var gauge: Array = []
	v.recall_asked.connect(func(j: int, c: int, s: int) -> void: asked.append([j, c, s]))
	v.recall_accepted.connect(func(s: int) -> void: gauge.append(s))
	var ask := _u32(3)
	ask.append_array(_u32(44))
	ask.append_array(_u32(30))
	v.handle(GuildPart2Net.OP_RECALL_ASK, ask)
	var ans := v.encode_recall_answer(3, 44, true)
	v.handle(GuildPart2Net.OP_RECALL_ANSWER_RESULT, PackedByteArray([1]))
	_check(asked == [[3, 44, 30]] and ans.size() == 9 and ans[8] == 1 and gauge == [30], "0x7030, 0x7031 yes, B031 {1}: the 30 s gauge")
	v.encode_recall_answer(3, 44, false)
	v.handle(GuildPart2Net.OP_RECALL_ANSWER_RESULT, PackedByteArray([1]))
	_check(gauge.size() == 1, "after a no, B031 {1} starts no gauge")

	if not FileAccess.file_exists(MEDIA):
		print("SKIP the windows (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)

	# 2. The election window.
	v.set_from_block([[7, 0, 600000]])
	v.handle(GuildPart2Net.OP_VOTE_STATE_RESULT, b106)
	var ew := GuildElectionWindow.new()
	root.add_child(ew)
	_check(ew.build_election(builder, 77, v, func(id: int) -> String: return {11: "Ann", 12: "Bob"}.get(id, "")),
		"ifguildmasterelection builds")
	_check(ew.size == Vector2(274, 315), "274 x 315 (ginterface GDR_GUILDMASTER_ELECTION)")
	var cbs := ew.find_children("CheckBox", "TextureButton", true, false)
	_check(cbs.size() == 7, "seven rows with a check (got %d)" % cbs.size())
	var ok := ew.button(GuildElectionWindow.BTN_OK)
	_check(ok != null and ok.disabled, "OK off until a check is ticked")
	(cbs[1] as TextureButton).button_pressed = true
	_check(ew.chosen == 1 and not ok.disabled, "a tick chooses the row, OK on")
	var cast: Array = []
	ew.voted.connect(func(n: int, id: int, i: int) -> void: cast.append([n, id, i]))
	ew.press_ok()
	_check(cast == [[77, 7, 1]], "OK sends {NPC, vote, index} (got %s)" % [cast])

	# 3. The GP history window (res_ui\guild_gp.2dt).
	var hw := GuildGPHistoryWindow.new()
	root.add_child(hw)
	_check(hw.build_history(builder), "guild_gp.2dt builds")
	hw.fill(hist)
	_check(hw.lines.size() == 1 and hw.lines[0].begins_with("[Pai] has spent [5400] GP for [")
		and hw.lines[0].contains(builder.resolve_text("UIIT_STT_FORTRESS_GP_HISTORY_GROWTH")), "the line (got %s)" % [hw.lines])

	# 4. The guild goods: the archive's GP price, the tooltip line, the box row.
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	var crest_id := int(panels.call("item_id_for_code", "ITEM_ETC_GUILD_CREST_USER")) if panels.has_method("item_id_for_code") else 9268
	var gp := int(panels.call("guild_gp_price", crest_id))
	_check(gp == 20000, "the guild crest's GP price from refpricepolicyofitem (got %d)" % gp)
	var lines: Array = panels.call("item_tip_lines", crest_id, "store", 0, -1, -1, 1000000)
	var gp_line := false
	for l in lines:
		if String(l["text"]).contains("20000" + builder.resolve_text("UIIT_STT_GUILD_POINT_GP")):
			gp_line = true
	_check(gp_line, "the tooltip carries the GP line")
	var box := StoreMessageBox.new()
	root.add_child(box)
	box.build(builder, StoreMessageBox.Kind.BUY, {"name": "Crest", "count": 1, "max": 1, "unit_price": 1000000, "gp_unit_price": 20000})
	var gp_row := box.get_node_or_null("GPRow")
	_check(gp_row != null and box.gp_unit_price == 20000, "the buy box has the GP row")
