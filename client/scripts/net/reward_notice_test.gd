extends SceneTree

## Round 716: the reward notices against the shared golden fixtures
## (client/scripts/net/fixtures/party/, written by gen_fixtures.py from
## docs/protocol/party_protocol.md "Rewards"): 0x3056 (the EXP/skill-EXP
## gain), 0x304E kind 1 (the gold total) and 0x3068 (the Item Auto Share
## notice), decoded field by field and encoded back; the system lines the
## original client writes for each; and PartyState naming the 0x3068
## recipient from its own member list.
##
##   godot4 --headless --path client --script res://scripts/net/reward_notice_test.gd

const FIX := "res://scripts/net/fixtures/party/"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _fx(name: String) -> PackedByteArray:
	var f := FileAccess.open(FIX + name + ".hex", FileAccess.READ)
	if f == null:
		_check(false, "fixture %s is readable" % name)
		return PackedByteArray()
	var out := PackedByteArray()
	for tok in f.get_as_text().split(" ", false):
		var t := tok.strip_edges()
		if t != "":
			out.append(t.hex_to_int())
	return out

func _test_exp_gain() -> void:
	var g := RewardNoticeNet.decode_exp_gain(_fx("3056_kill"))
	_check(g != null and g.source == 4321 and g.exp == 1170 and g.skill_exp == 249 and g.flags == 0 and not g.level_up,
		"3056_kill: source 4321, 1170 EXP, 249 skill EXP, no level-up")
	_check(g != null and RewardNoticeNet.encode_exp_gain(g) == _fx("3056_kill"), "3056_kill encodes back byte for byte")
	var up := RewardNoticeNet.decode_exp_gain(_fx("3056_levelup"))
	_check(up != null and up.exp == 5000 and up.skill_exp == 10 and up.level_up and up.stat_points == 3,
		"3056_levelup: the u16 after the flags is the unspent stat points")
	_check(up != null and RewardNoticeNet.encode_exp_gain(up) == _fx("3056_levelup"), "3056_levelup encodes back byte for byte")
	var lose := RewardNoticeNet.decode_exp_gain(_fx("3056_lose"))
	_check(lose != null and lose.exp == -2000 and lose.source == 0, "3056_lose: a signed 64-bit loss")
	_check(RewardNoticeNet.decode_exp_gain(_fx("3056_kill").slice(0, 20)) == null, "a 20-byte 0x3056 is dropped")
	# The lines (c:0x8a97c0), with the archive's English standing in.
	var l := RewardNoticeNet.exp_lines(g, "", "", "")
	_check(l.size() == 2 and l[0] == "[1170]Experience Points gained." and l[1] == "[249]skill experience point gained.",
		"a gain writes GAIN_EXP and GET_SKILL_EXP (%s)" % str(l))
	var ll := RewardNoticeNet.exp_lines(lose, "", "", "")
	_check(ll.size() == 1 and ll[0] == "[2000]Experience Points lost.", "a loss writes LOSE_EXP with the amount (%s)" % str(ll))
	var t := RewardNoticeNet.exp_lines(g, "got [%I64d] exp", "", "sp [%u]")
	_check(t[0] == "got [1170] exp" and t[1] == "sp [249]", "the archive's templates are filled")

func _test_gold() -> void:
	var gold := RewardNoticeNet.decode_gold(_fx("304e_gold"))
	_check(gold.size() == 2 and gold[0] == 1234567 and gold[1] == true, "304e_gold: kind 1, total 1234567, shown")
	_check(RewardNoticeNet.decode_gold(PackedByteArray([2, 0, 0, 0, 0, 1])).is_empty(), "another 0x304E kind is not read as gold")
	_check(RewardNoticeNet.gold_line(1000, 1250, true, "") == "[250]gold gained.", "a shown rise prints GAIN_GOLD with the rise")
	_check(RewardNoticeNet.gold_line(1000, 1250, false, "") == "", "an unshown update prints nothing")
	_check(RewardNoticeNet.gold_line(1250, 1000, true, "") == "", "a fall prints nothing (c:0x8a70d0 only reports a rise)")
	_check(RewardNoticeNet.gold_line(0, 0x7fffffff + 50, true, "[%d]") == "[2147483647]", "the rise is clamped to 0x7fffffff")

func _test_item_notice() -> void:
	var e := PartyNet.decode_item_notice(_fx("3068_expendable"))
	_check(e != null and e.recipient_jid == 201 and e.item_id == 62 and e.amount == 5 and not e.is_gold, "3068_expendable: u16 count")
	var o := PartyNet.decode_item_notice(_fx("3068_other"))
	_check(o != null and o.recipient_jid == 101 and o.item_id == 3617 and o.amount == 1, "3068_other: u8 count")
	var gd := PartyNet.decode_item_notice(_fx("3068_gold"))
	_check(gd != null and gd.is_gold and gd.amount == 1234, "3068_gold: u64 amount")
	_check(PartyNet.decode_item_notice(PackedByteArray([1, 2, 3])) == null, "a short 0x3068 is dropped")
	var line := RewardNoticeNet.item_notice_line(false, false, "HP Recovery Potion (Small)", 5, "Bram", "", "", "")
	_check(line[0] == "Item [HP Recovery Potion (Small) 5 pieces]is distributed to [Bram]." and line[1] == 4,
		"another member's item: PARTYGET_ITEM_EXPENDABLE, type 4 (%s)" % str(line))
	var mine := RewardNoticeNet.item_notice_line(true, false, "Arrow", 20, "Aria", "", "", "")
	_check(mine[0] == "item [Arrow 20 pieces]gained." and mine[1] == 1, "the player's own: STATE_GET_ITEM_EXPENDABLE, type 1")
	var g := RewardNoticeNet.item_notice_line(false, true, "", 1234, "Bram", "", "", "")
	_check(g[0] == "[1234]gold is distributed to [Bram]." and g[1] == 4, "gold: PARTYGET_GOLD, type 4")
	# PartyState names the recipient from its own list.
	var st := PartyState.new()
	st.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	var seen := []
	st.item_notice.connect(func(jid: int, member: String, item: int, amount: int, is_gold: bool) -> void:
		seen.append([jid, member, item, amount, is_gold]))
	_check(st.handle(PartyNet.OP_ITEM_NOTICE, _fx("3068_expendable")), "PartyState takes 0x3068")
	_check(seen.size() == 1 and seen[0][1] == "Bram" and seen[0][3] == 5,
		"the notice names the recipient from the party (%s)" % str(seen))

func _initialize() -> void:
	_test_exp_gain()
	_test_gold()
	_test_item_notice()
	if _failures == 0:
		print("reward_notice_test: all checks passed")
		quit(0)
	else:
		print("reward_notice_test: %d check(s) FAILED" % _failures)
		quit(1)
