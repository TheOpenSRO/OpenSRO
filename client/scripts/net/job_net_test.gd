extends SceneTree

## Round 799: the job guild's messages as the client reads and writes them,
## from the bytes server/internal/jobs encodes (its job799_test.go checks the
## same ones); JobText's numbers and lines; LevelDataReader's job columns;
## the menu's job block (FUN_006fdeb0).
## `godot4 --headless --path client --script res://scripts/net/job_net_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# Requests.
	_check(JobNet.encode_join(0x01020304, 2) == PackedByteArray([4, 3, 2, 1, 2]), "0x70E1 {npc, kind}")
	_check(JobNet.encode_alias(1, 1, "Bob") == PackedByteArray([1, 0, 0, 0, 1, 3, 0, 66, 111, 98]), "0x70E3 {npc, op, alias}")
	_check(JobNet.encode_ranking(7, 3, 1) == PackedByteArray([7, 0, 0, 0, 3, 1]), "0x70E4 {npc, kind, type}")
	_check(JobNet.encode_reward(7, 1) == PackedByteArray([7, 0, 0, 0, 1]), "0x70E5 {npc, op}")
	# Replies (jobs.JoinOK(KindThief, 1, 0x0102) and the others).
	var j := JobNet.decode_join(PackedByteArray([1, 2, 1, 2, 1, 0, 0]))
	_check(j["ok"] and j["kind"] == 2 and j["level"] == 1 and j["exp"] == 0x0102, "0xB0E1 success")
	j = JobNet.decode_join(PackedByteArray([2, 0x19, 0x48]))
	_check(not j["ok"] and j["code"] == 0x4819, "0xB0E1 refusal")
	var a := JobNet.decode_alias(PackedByteArray([2, 0x23, 0x48, 0, 1, 0, 120]))
	_check(not a["ok"] and a["code"] == 0x4823 and a["op"] == 0 and a["alias"] == "x", "0xB0E3 refusal keeps op and alias")
	a = JobNet.decode_alias(PackedByteArray([1, 1, 2, 0, 65, 98]))
	_check(a["ok"] and a["op"] == 1 and a["alias"] == "Ab", "0xB0E3 success")
	var r := JobNet.decode_ranking(PackedByteArray([1, 1, 0, 1, 1, 1, 0, 97, 2, 3, 0, 0, 0, 1]))
	_check(r["ok"] and r["kind"] == 1 and r["type"] == 0 and (r["rows"] as Array).size() == 1
		and r["rows"][0]["alias"] == "a" and r["rows"][0]["exp"] == 3 and r["rows"][0]["country"] == 1, "0xB0E4 activity")
	r = JobNet.decode_ranking(PackedByteArray([1, 3, 1, 1, 1, 1, 0, 97, 2, 3, 0, 0, 0]))
	_check(r["rows"][0]["amount"] == 3 and not r["rows"][0].has("country"), "0xB0E4 contribution")
	var w := JobNet.decode_reward(PackedByteArray([1, 0, 9, 3, 0, 0]))
	_check(w["ok"] and w["op"] == 0 and w["gold"] == 0x309, "0xB0E5 query")
	w = JobNet.decode_reward(PackedByteArray([2, 0x2a, 0x48, 1]))
	_check(not w["ok"] and w["code"] == 0x482a and w["op"] == 1, "0xB0E5 refusal")
	var p := JobNet.decode_prev_job(PackedByteArray([1, 1, 4, 0, 0, 0, 2, 5, 0, 0, 0, 3, 6, 0, 0, 0]))
	_check(p["levels"] == [1, 2, 3] and p["exps"] == [4, 5, 6], "0xB0E6 in the wire's order")
	var x := JobNet.decode_job_exp(PackedByteArray([3, 4, 9, 0, 0, 0]))
	_check(x["kind"] == 3 and x["level"] == 4 and x["exp"] == 9, "0x30E6")
	var info := JobNet.decode_job_info(PackedByteArray([2, 0, 65, 98, 1, 2, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0]))
	_check(info["alias"] == "Ab" and info["kind"] == 1 and info["level"] == 2 and info["exp"] == 3
		and info["contribution"] == 4 and info["reward"] == 5, "OP_JOB_INFO")
	# JobText.
	_check(JobText.class_key(1, 3, false) == "UIIT_STT_CLASS_MERCHANT_3" and JobText.class_key(2, 1, true) == "UIIT_STT_CLASS_EU_THIEF_1",
		"the class title keys")
	_check(JobText.percent(35437, 70875) == 49 and JobText.percent(5, -1) == 100, "the percent: truncated; -1 is 100")
	var table := {1: [70875, 70875, 70875], 2: [2388750, 2388750, 2388750]}
	var up := JobText.exp_line(3, 1, 70000, 2, 125, table)
	_check(up["banner_key"] == "UIIT_STT_JOB_LVUP_HUNTER_CLASS" and up["key"] == "UIIT_STT_JOB_EXP_HUNTER_GET" and up["amount"] == 1000,
		"a level-up: the banner and need - old + new gained")
	var lost := JobText.exp_line(1, 2, 500, 2, 200, table)
	_check(lost["banner_key"] == "" and lost["key"] == "UIIT_STT_JOB_EXP_MERCHANT_LOST" and lost["amount"] == 300, "a loss")
	_check(JobText.exp_line(2, 1, 5, 1, 5, table)["key"] == "", "no change, no line")
	_check(JobText.grouped(1500000) == "1,500,000", "grouped")
	# LevelDataReader's job columns, -1 kept.
	var ld := "1\t118\t1\t0\t0\t24\t15000000\t15000000\t15000000\n21\t351231\t62\t0\t0\t498\t-1\t-1\t-1\n"
	var bytes := PackedByteArray([0xFF, 0xFE])
	bytes.append_array(ld.to_utf16_buffer())
	var jt := LevelDataReader.parse_job_exp(bytes)
	_check(jt.get(1, []) == [15000000, 15000000, 15000000] and jt.get(21, []) == [-1, -1, -1], "leveldata columns 6..8")
	# The alias window's local test.
	_check(not JobAliasBox.locally_ok("a") and JobAliasBox.locally_ok("ab") and not JobAliasBox.locally_ok("abcdefghijklm"),
		"2..12 bytes")
	_check(not JobAliasBox.locally_ok("ab", func(_s: String) -> bool: return false), "the name rule refuses")
	# A rank row's cells.
	var cells := JobRankBox.row_cells({"rank": 1, "alias": "h", "level": 2, "exp": 1194375, "country": 1}, false, 3, table)
	_check(cells["GDR_JOB_RANK_EXP"] == "50%" and cells["GDR_JOB_RANK_GRADENAME"] == "UIIT_STT_CLASS_EU_HUNTER_2"
		and cells["GDR_JOB_RANK_GRADE"] == "2", "an activity row")
	var prev := PrevJobInfoBox.cells_for(1, 7, 99, false, table, Callable())
	_check(prev["exp"] == "100%%" and prev["ratio"] == 1.0, "level 7's literal 100%% (0x74db48)")
	print("%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
