extends SceneTree

## Round 802: job PvP's and the safe trade's client rules and messages, from
## the bytes server/internal/session/jobpvp.go and safetrade.go write (its
## job802_test.go checks the same ones).
## `godot4 --headless --path client --script res://scripts/net/job_pvp_net_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var tr := JobPvpNet.STATE_TRADER
	var th := JobPvpNet.STATE_THIEF
	var hu := JobPvpNet.STATE_HUNTER
	var no := JobPvpNet.STATE_NONE
	_check(JobPvpNet.opposed(tr, th) and JobPvpNet.opposed(th, tr) and JobPvpNet.opposed(hu, th) and JobPvpNet.opposed(th, hu),
		"c:0x9d02c0: a trader or hunter against a thief, either way")
	_check(not JobPvpNet.opposed(tr, hu) and not JobPvpNet.opposed(th, th) and not JobPvpNet.opposed(tr, no) and not JobPvpNet.opposed(no, th),
		"trader-hunter, thief-thief and a player out of a job are not opposed")
	# c:0x9de780: opposition first; Alt only when the two do not both wear a suit.
	_check(JobPvpNet.is_enemy(th, tr, false, true), "an opposed pair is an enemy without Alt")
	_check(not JobPvpNet.is_enemy(tr, hu, true, true), "two suits not opposed: no enemy even with Alt")
	_check(JobPvpNet.is_enemy(no, tr, true, false) and not JobPvpNet.is_enemy(no, tr, false, false),
		"out of a job: Alt makes an enemy")
	# c:0x792f00's player branch.
	_check(JobPvpNet.player_click(false, false, true, false, 50) == "select", "the first click selects")
	_check(JobPvpNet.player_click(true, false, true, false, 50) == "attack", "a click on the selected enemy attacks")
	_check(JobPvpNet.player_click(false, true, true, false, 50) == "attack", "Alt attacks at once")
	_check(JobPvpNet.player_click(true, false, false, false, 50) == "select", "a selected non-enemy stays selected")
	_check(JobPvpNet.player_click(true, false, true, true, 50) == "party", "a party member is not attacked")
	_check(JobPvpNet.player_click(true, false, true, false, 19) == "level", "below level 20: 0x3016, nothing sent")
	_check(JobPvpNet.enemy_name(th, tr) and not JobPvpNet.enemy_name(no, tr) and not JobPvpNet.enemy_name(tr, hu),
		"the hostile name: the worn suit against the spawned job")
	_check(JobPvpNet.ENEMY_NAME_COLOUR.to_argb32() == 0xffff6262, "c:0x9cfd50's 0xffff6262")
	# OpAttack with the kind byte.
	var a := JobPvpNet.encode_attack("Robin", 7, JobPvpNet.TARGET_CHARACTER)
	_check(a == PackedByteArray([5, 0, 82, 111, 98, 105, 110, 7, 0, 0, 0, 0, 0, 0, 0, 3]), "OpAttack + kind 3")
	_check(JobPvpNet.is_cos_uid(0x7e000001) and not JobPvpNet.is_cos_uid(0x7f000001) and not JobPvpNet.is_cos_uid(5),
		"the COS uid range")
	# OpPlayerStruck: attacker 1, character 2, 30 damage, died, HP 0 of 500;
	# the struck player's copy adds the 2400 exp its death cost.
	var st := PackedByteArray([1, 0, 0, 0, 0, 2, 0, 0, 0, 30, 0, 0, 0, 4, 0, 0, 0, 0, 0xf4, 1, 0, 0])
	var d := JobPvpNet.decode_struck(st)
	_check(d["attacker"] == 1 and not d["cos"] and d["target"] == 2 and d["damage"] == 30 and d["died"]
		and not d["critical"] and d["hp"] == 0 and d["max_hp"] == 500 and not d["own"], "OpPlayerStruck")
	var own := st.duplicate()
	own.append_array(PackedByteArray([0x60, 0x09, 0, 0, 0, 0, 0, 0]))
	var od := JobPvpNet.decode_struck(own)
	_check(od["own"] and od["exp_lost"] == 2400, "the struck player's copy: the exp lost")
	_check(JobPvpNet.decode_struck(PackedByteArray([1, 2, 3])).is_empty(), "a short OpPlayerStruck")
	# 0x34D5.
	var g := JobPvpNet.decode_safe_trade(PackedByteArray([1, 0x50, 3, 8]))
	_check(g["status"] and g["code"] == JobPvpNet.SAFE_GRANTED and g["count"] == 3 and g["num"] == 8, "0x34D5 granted")
	var l := JobPvpNet.decode_safe_trade(PackedByteArray([0, 0x41]))
	_check(not l["status"] and l["code"] == JobPvpNet.SAFE_LIMIT, "0x34D5 the day's limit")
	_check(JobPvpNet.safe_trade_banner(g, "Safe trade will begin.[%d]/[%d] ") == "Safe trade will begin.[3]/[8]",
		"the banner's count / num")
	_check(JobPvpNet.safe_trade_banner(JobPvpNet.decode_safe_trade(PackedByteArray([1, 0x51, 3, 8])), "x %d") == "",
		"the login's report shows no banner")
	_check(JobPvpNet.safe_trade_banner(l, "x %d") == "", "the limit shows no banner")
	print("%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
