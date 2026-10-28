extends SceneTree

## Round 838 (lane 5): Magic POP's codec (GachaNet) against the server's
## bytes (session/gacha.go: EncodeGachaPlay, gachaFail, EncodeGachaExchanged)
## and the client's tables (GachaTables) on the archive's own layout.
##
## NEGATIVE: before round 838 GachaNet and GachaTables do not exist and this
## suite does not parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _init() -> void:
	# 0x7118: npc 0x7f000007, GachaID 3916 (0x0f4c), the card in bag slot 2 -> 15.
	var play := GachaNet.encode_play(0x7f000007, 3916, 2)
	_check(play == PackedByteArray([0x07, 0, 0, 0x7f, 0x4c, 0x0f, 0, 0, 15]), "0x7118's bytes: %s" % play.hex_encode())
	_check(GachaNet.encode_exchange(0x7f000008) == PackedByteArray([0x08, 0, 0, 0x7f]), "0x7119's bytes")
	var win := GachaNet.decode_play_result(PackedByteArray([1, 1]))
	_check(bool(win["ok"]) and bool(win["win"]), "0xB118 {1, 1} is a win")
	var lose := GachaNet.decode_play_result(PackedByteArray([1, 0]))
	_check(bool(lose["ok"]) and not bool(lose["win"]), "0xB118 {1, 0} is a loss")
	var refused := GachaNet.decode_play_result(PackedByteArray([2, 0x0f, 0x1c]))
	_check(not bool(refused["ok"]) and int(refused["code"]) == 0x1c0f, "0xB118 {2, 0x1c0f} is a refusal")
	var an := GachaNet.decode_announce(PackedByteArray([0x79, 0x0e, 0, 0, 1, 0]))
	_check(int(an.get("ref", 0)) == 3705 and int(an.get("count", 0)) == 1, "0x3120")

	# The tables, as the archive lays them out (MEASURED rows).
	var t := GachaTables.new()
	t.parse_items(_utf16("1\t1\t3705\t120\t1\t3916\t0\t-1\txxx\n0\t1\t3706\t120\t1\t3999\t0\n1\t2\t3680\t2400\t1\t3881\t0\n//Copyright\n"))
	t.parse_map(_utf16("1\t9251\t1\t2\n"))
	t.parse_tree(_utf16("1\t3\t1\t13\t4\t700\tUIIT_CTL_WK_ETC_ETC\t701\tUIIT_CTL_WK_AVATAR_FLAG\t0\n1\t3\t3\t10\t2\t700\tUIIT_CTL_WK_ETC_ETC\t702\tUIIT_CTL_WK_LMP\t0\n"))
	_check(t.prizes.size() == 2, "Service 0 rows are skipped: %d prizes" % t.prizes.size())
	_check(t.prize_set(9251) == 1 and t.prize_set(9252) == -1, "the machine's prize set")
	_check(t.kinds.size() == 2 and (t.kinds[1] as GachaTables.Kind).type_key == "UIIT_CTL_WK_LMP"
		and (t.kinds[1] as GachaTables.Kind).types == PackedInt32Array([3, 3, 10, 2]), "the kinds")
	var types := func(ref: int) -> PackedInt32Array:
		return PackedInt32Array([3, 3, 10, 2]) if ref == 3705 else PackedInt32Array([3, 3, 11, 1])
	_check(t.prizes_for(1, null, types).size() == 1, "set 1 unfiltered")
	_check(t.prizes_for(1, t.kinds[1], types).size() == 1, "set 1 by LMP (3/3/10/2)")
	_check(t.prizes_for(1, t.kinds[0], types).is_empty(), "set 1 by Avatar Flag: none")
	if _failures == 0:
		print("ALL PASS")
	quit(1 if _failures > 0 else 0)
