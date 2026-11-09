extends SceneTree

## Round 869 (lane C1): the game worlds' client codecs against the READ and
## MEASURED bytes (StructureSpawnNet, GameWorldNet; docs/protocol/
## game_worlds.md 14 CLIENT, forgotten_world.md 11 CLIENT): the gate's spawn
## record (the measured layout, with a synthetic uid and name), a door's,
## both in a group, the type-6 / type-7 visibility rule, 0x351E, the gate's
## select reply and its talk lines, 0x705A, 0xB05A's refusals, the 0x300C
## words and 0x320C. The archive part (the texts, the group record) reads
## Media.pk2 on the render box and SKIPs without it; nothing from it is
## committed.
##   godot4 --headless --path client --script res://scripts/net/game_world_net_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_records()
	_group()
	_visibility()
	_event_zone()
	_gate_select()
	_teleport()
	_notices()
	_timed_job()
	_archive()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## The measured gate record: {19556, uid, region 0xA861, x, y, z, angle, 1, 0,
## 1, 6, str name, u32 35883} + the 0x3015 trailer 1.
func _gate_bytes(uid: int, owner: String) -> PackedByteArray:
	var rec := StructureSpawnNet.Record.new()
	rec.kind = StructureSpawnNet.KIND_GATE
	rec.ref_id = 19556
	rec.uid = uid
	rec.region = 0xA861
	rec.local_position = Vector3(1002.5, 0.0, 1100.25)
	rec.angle = 0x4000
	rec.b260 = 1
	rec.state = 0
	rec.owned = 1
	rec.access = 6
	rec.owner_name = owner
	rec.hole_ref = 35883
	return StructureSpawnNet.encode_record(rec)

func _door_bytes(uid: int, zone: int, state: int) -> PackedByteArray:
	var rec := StructureSpawnNet.Record.new()
	rec.kind = StructureSpawnNet.KIND_EVENT
	rec.ref_id = 36513
	rec.uid = uid
	rec.region = 0x7EE4
	rec.local_position = Vector3(900.0, 693.0, 1200.0)
	rec.angle = 0
	rec.b260 = 1
	rec.state = state
	rec.owned = 0
	rec.access = 0
	rec.owner_id = 0
	rec.hole_ref = 0
	rec.zone_id = zone
	rec.b284 = 0
	return StructureSpawnNet.encode_record(rec)

func _records() -> void:
	var b := _gate_bytes(0x00ABCDEF, "Tester01")
	# The field order, byte for byte (READ c:0x9c3a70 + c:0x56dfa0).
	_check(b.slice(0, 4).hex_encode() == "644c0000", "the RefObjID 19556 first")
	_check(b.slice(24, 28).hex_encode() == "01000106", "+0x260 1, +0x261 0, +0x254 1, +0x255 6")
	_check(b.slice(28, 30).hex_encode() == "0800" and b.slice(30, 38).get_string_from_ascii() == "Tester01", "type 6: the owner's name, u16 length + ANSI")
	_check(b.slice(38, 42).hex_encode() == "2b8c0000", "then the hole's RefObjID 35883")
	var single := b.duplicate()
	single.append(1)
	var rec := StructureSpawnNet.decode_single_spawn(single, StructureSpawnNet.KIND_GATE)
	_check(rec != null, "0x3015 reads as a CITeleportGate's record")
	if rec != null:
		_check(rec.uid == 0x00ABCDEF and rec.region_x == 0xA8 and rec.region_y == 0x61 and rec.local_position.is_equal_approx(Vector3(1002.5, 0, 1100.25)),
			"uid, region (high byte first, as the NPCs' key) and position")
		_check(rec.access == 6 and rec.owner_name == "Tester01" and rec.hole_ref == 35883 and rec.spawn_type == 1, "access 6, owner, hole, trailer")
	_check(StructureSpawnNet.decode_single_spawn(b, StructureSpawnNet.KIND_GATE) == null, "no trailer: refused")
	# Type 7: a u32 party id in place of the name.
	var r7 := StructureSpawnNet.Record.new()
	r7.kind = StructureSpawnNet.KIND_GATE
	r7.ref_id = 19556
	r7.uid = 7
	r7.owned = 1
	r7.access = 7
	r7.owner_id = 0x1234
	r7.hole_ref = 35883
	var b7 := StructureSpawnNet.encode_record(r7)
	_check(b7.size() == 36 and b7.slice(28, 32).hex_encode() == "34120000", "type 7: u32 +0x258")
	var d := _door_bytes(0x501, 251, 0)
	d.append(0)
	var door := StructureSpawnNet.decode_single_spawn(d, StructureSpawnNet.KIND_EVENT)
	_check(door != null and door.zone_id == 251 and door.state == 0 and d.size() == 26 + 2 + 4 + 4 + 5 + 1,
		"CIEventRuntimeObj: + u32 event zone, u8 (c:0x535980)")
	_check(StructureSpawnNet.kind_of_type(4, 1) == StructureSpawnNet.KIND_GATE and StructureSpawnNet.kind_of_type(4, 2) == StructureSpawnNet.KIND_EVENT \
		and StructureSpawnNet.kind_of_type(1, 2) == StructureSpawnNet.KIND_NONE, "classes by TypeID (c:0x9c1ca0, c:0x9c1cc0)")

func _group() -> void:
	var types := UserSpawnNet.Types.new({}, Callable(), {19556: StructureSpawnNet.KIND_GATE, 36513: StructureSpawnNet.KIND_EVENT})
	var buf := PackedByteArray([1, 2, 0])
	buf.append_array(_gate_bytes(11, "Tester01"))
	buf.append_array(_door_bytes(12, 252, 1))
	var g := UserSpawnNet.read_group(buf, types)
	_check(g.error == "" and (g.structures as Array).size() == 2 and (g.npcs as Array).is_empty(),
		"a group with a gate and a door reads both as structures (no trailer in a group)")
	if (g.structures as Array).size() == 2:
		_check((g.structures[1] as StructureSpawnNet.Record).zone_id == 252 and (g.structures[1] as StructureSpawnNet.Record).state == 1, "the door's zone and state")

func _visibility() -> void:
	var rec := StructureSpawnNet.decode_single_spawn(_gate_bytes(1, "Tester01") + PackedByteArray([1]), StructureSpawnNet.KIND_GATE)
	_check(StructureSpawnNet.gate_visible(rec, "Tester01", 0), "type 6: the creator draws it")
	_check(not StructureSpawnNet.gate_visible(rec, "Tester02", 55), "type 6: anyone else draws nothing (MEASURED: a party member)")
	rec.access = 7
	rec.owner_id = 55
	_check(StructureSpawnNet.gate_visible(rec, "Tester02", 55) and not StructureSpawnNet.gate_visible(rec, "Tester02", 56) \
		and not StructureSpawnNet.gate_visible(rec, "Tester02", 0), "type 7: only the party whose id it carries")
	rec.owned = 0
	_check(StructureSpawnNet.gate_visible(rec, "x", 0), "+0x254 0: no rule")

func _event_zone() -> void:
	var ez := StructureSpawnNet.decode_event_zone_state("01050000".hex_decode() + PackedByteArray([0x10, 1]))
	_check(ez.get("uid") == 0x501 and ez.get("field") == 0x10 and ez.get("state") == 1, "0x351E {u32 object, u8 0x10, u8 state}")
	_check(StructureSpawnNet.decode_event_zone_state(PackedByteArray([1, 2, 3])).is_empty(), "short: nothing")

func _text(k: String) -> String:
	var t := {
		"UIIT_STT_GOD_TELTOPRT_GATE_1": "G1", "UIIT_STT_GOD_TELTOPRT_GATE_2": "G2",
		"UIIT_STT_GOD_LV_EXTENT": "Level : %s", "UIIT_STT_GOD_CLASS": "Grade : %s", "UIIT_STT_GOD_CLASS_1": "*",
		"UIIT_STT_GOD_CLASS_2": "**", "UIIT_STT_GOD_PARTY_MASTER": "Party master : %s",
		"UIIT_CTL_TELEPORT_FREE_RESULT": "Teleport to [%s]area.", "32484": "Togui Village",
		"UIIT_MSG_EGYPT_DUNGEON_DESTROY_ALARM": "After %d minute, gone.", "KEY_A": "Text A",
		"UIIT_STT_REMAIN_TIME": "Remaining time", "PARAM_HOUR": "Hour", "PARAM_MINUTE": "Minute", "PARAM_SECOND": "Second",
		"SUBJ": "Subject", "EXPL": "Explanation",
	}
	return String(t.get(k, k))

func _gate_select() -> void:
	# MEASURED: {01, uid, 01 1c, 01, 02, u16 0x7EE4, i32 1063, 693, 1125}.
	var hex := "01" + "efcdab00" + "011c" + "01" + "02" + "e47e" + "27040000" + "b5020000" + "65040000"
	var s := GameWorldNet.decode_gate_select(hex.hex_decode())
	_check(not s.is_empty() and int(s["entity"]) == 0x00ABCDEF and Array(s["ids"]) == [0x1c], "the measured 0xB045: entity and the id 0x1c")
	if not s.is_empty():
		var d: Dictionary = (s["dests"] as Array)[0]
		_check((s["dests"] as Array).size() == 1 and int(d["kind"]) == 2 and int(d["region"]) == 0x7EE4 and d["pos"] == Vector3i(1063, 693, 1125),
			"one destination of kind 2: region 0x7EE4 (1063, 693, 1125)")
		var t := func(k: String) -> String: return _text(k)
		_check(GameWorldNet.dest_line(1, GameWorldNet.dest_place(d, t, -1), t) == "1. Teleport to [Togui Village]area.",
			"the line: '%d. ' + FREE_RESULT with the region's own name (c:0x6fac20)")
	_check(GameWorldNet.decode_gate_select("01efcdab00011c01".hex_decode()).is_empty(), "cut short: nothing")
	var t2 := func(k: String) -> String: return _text(k)
	var lines := GameWorldNet.gate_lines(t2, "", Vector2i(35, 50), 1)
	var texts := lines.map(func(l) -> String: return String(l["text"]))
	_check(texts == ["G1", "", "Level : 35 - 50", "Grade : *", "", "G2"], "type 6: GATE_1, blank, level, grade, blank, GATE_2 (c:0x9ea880)")
	_check(bool(lines[-1]["bold"]) and lines[-1]["colour"] == Color8(0xd6, 0xff, 0x7e) and not bool(lines[0]["bold"]),
		"GATE_2 in 0xffd6ff7e, bold; the rest white")
	var party_lines := GameWorldNet.gate_lines(t2, "Leader1", Vector2i(91, 100), 2)
	_check(String(party_lines[2]["text"]) == "Party master : Leader1" and String(party_lines[4]["text"]) == "Grade : **",
		"type 7: the party master's line before the level")

func _teleport() -> void:
	_check(GameWorldNet.encode_portal_use(0x00ABCDEF, 0).hex_encode() == "efcdab000300", "0x705A {gate, 3, 0} (c:0x7035f8..0x703690)")
	_check(GameWorldNet.decode_teleport_ack(PackedByteArray([1])) == {"result": 1, "code": -1}, "0xB05A {1}")
	var acc := GameWorldNet.decode_teleport_ack("020100".hex_decode())
	_check(acc["code"] == 1 and GameWorldNet.refusal_key(1) == "", "{2, 1}: the accept, no text (category 0xd's default)")
	_check(GameWorldNet.refusal_key(3) == "" and GameWorldNet.refusal_key(2) == "", "2 and 3: no text")
	_check(GameWorldNet.refusal_key(0x1c32) == "UIIT_MGS_ERR_GOD_LIMIT_TIME" and GameWorldNet.refusal_key(0x1c25) == "UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_NUMBER_FOR_TELEPORT" \
		and GameWorldNet.refusal_key(0x1c2c) == "UIIT_MSG_EGYPT_SHRINE_ENTRANCE_CONDITION_ERROR_01", "the table at 0x7bbaac")

func _notices() -> void:
	var t := func(k: String) -> String: return _text(k)
	var c := GameWorldNet.encode_notice_closes(10)
	_check(c.hex_encode() == "1a0c0a", "0x300C {0x0C1A, 10}")
	var n := GameWorldNet.decode_notice(c)
	var tx := GameWorldNet.notice_texts(n, t)
	_check(tx["banner"] == "After 10 minute, gone." and tx["line"] == tx["banner"], "0x0C1A: the alarm with the minutes, banner and line")
	var b := GameWorldNet.encode_notice_trigger(1, "KEY_A")
	_check(b.hex_encode() == "1c0c010500" + "KEY_A".to_ascii_buffer().hex_encode(), "0x300C {0x0C1C, 1, str key}")
	var tb := GameWorldNet.notice_texts(GameWorldNet.decode_notice(b), t)
	_check(tb["banner"] == "Text A" and tb["line"] == "", "kind 1: the banner only")
	var tl := GameWorldNet.notice_texts(GameWorldNet.decode_notice(GameWorldNet.encode_notice_trigger(2, "KEY_A")), t)
	_check(tl["banner"] == "" and tl["line"] == "Text A", "kind 2: the system line only")
	_check(GameWorldNet.decode_notice("050c".hex_decode() + PackedByteArray([1, 2, 3, 4])).is_empty() and not GameWorldNet.is_world_notice("050c00".hex_decode()),
		"another word is not the game worlds'")

func _timed_job() -> void:
	var d := GameWorldNet.decode_timed_job(GameWorldNet.encode_timed_job_group(1, 18000))
	_check(d == {"kind": 0x0C, "group": 1, "remaining_s": 18000}, "0x320C {0x0C, u32 group, u32 remaining s}")
	var g := GameWorldNet.group_gauge(480 * 60, 18000)
	_check(g["total_ms"] == 28800000 and g["remaining_ms"] == 18000000, "the gauge: total 480 min (the archive's), 5 h left (c:0x805a40 case 0xe)")
	var tip := GameWorldNet.group_tooltip({"subject": "SUBJ", "explanation": "EXPL"}, 4 * 3600000 + 59 * 60000 + 30000, func(k: String) -> String: return _text(k))
	_check(Array(tip) == ["Subject", "Explanation", "Remaining time: 4Hour 59Minute 30Second"], "the tooltip (c:0x803a3d..)")

func _archive() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP the archive part: no Media.pk2")
		return
	var pk := Pk2Reader.open(MEDIA)
	if pk == null:
		print("SKIP the archive part: Media.pk2 does not open")
		return
	var read := func(path: String) -> PackedByteArray:
		var e := ObjectLoader.find_file(pk, path)
		return pk.read_file(e) if e != null else PackedByteArray()
	var cfg := GameWorldNet.parse_group_config(read.call("server_dep\\silkroad\\textdata\\groupworld_config_forclient.txt"))
	_check(cfg.has(1) and int(cfg[1]["cool_s"]) == 480 * 60 and String(cfg[1]["icon"]) == "icon\\item\\etc\\teleprot_hole.ddj" \
		and String(cfg[1]["subject"]) == "UIIT_STT_PARTY_LOST_WOLRD_SUBJECT", "MEASURED: group 1's record (480 min, the hole's icon)")
	var ui := UiTextTable.parse(read.call("server_dep\\silkroad\\textdata\\textuisystem.txt"))
	var t := func(k: String) -> String: return ui.get_text(k)
	_check(ui.get_text("UIIT_STT_GOD_TELTOPRT_GATE_1") == "The currently generated dimension is the Forgotten World.", "GATE_1's English text")
	var lines := GameWorldNet.gate_lines(t, "", Vector2i(35, 50), 1)
	_check(String(lines[2]["text"]) == "Level : 35 - 50" and String(lines[3]["text"]) == "Grade : " + ui.get_text("UIIT_STT_GOD_CLASS_1"),
		"'Level : 35 - 50' and the grade from this archive's own first row (%s / %s; MEASURED: the window showed '★' with another archive)" % [lines[2]["text"], lines[3]["text"]])
	var n := GameWorldNet.notice_texts(GameWorldNet.decode_notice(GameWorldNet.encode_notice_closes(5)), t)
	_check(String(n["line"]) == "After 5 minute, instance dungeon will vanish. When it vanish, user will move to saved return place.", "the alarm's text")
	var tip := GameWorldNet.group_tooltip(cfg[1], 3600000, t)
	_check(tip[0] == "Forgotten World - Re-entry Time Limit" and tip[1].begins_with("Once the instance dungeon re-entry time limit expires"), "the icon's subject and explanation")
	pk.close()
