extends SceneTree

## Round 834: FriendNet on the retail wire -- the same bytes as the server's
## TestFriendWireLayouts (server/internal/session/friend_test.go).
##   godot4 --headless --path client --script res://scripts/net/friend_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_check(FriendNet.encode_ask("Bo") == PackedByteArray([2, 0, 0x42, 0x6f]), "0x7302 {str name}")
	_check(FriendNet.encode_answer(7, 9, true) == PackedByteArray([7, 0, 0, 0, 9, 0, 0, 0, 1]), "0x3303 accept: {job, jid, 1}")
	_check(FriendNet.encode_answer(7, 9, false)[8] == 0, "a refusal answers 0")
	_check(FriendNet.encode_delete(5) == PackedByteArray([5, 0, 0, 0]), "0x7304 {u32 id}")
	var req := FriendNet.decode_request(PackedByteArray([7, 0, 0, 0, 9, 0, 0, 0, 2, 0, 0x41, 0x6c]))
	_check(req != null and req.job == 7 and req.asker_jid == 9 and req.asker_name == "Al", "0x7302 from the server")
	var f := FriendNet.decode_failure(PackedByteArray([2, 0x08, 0x64]))
	_check(f != null and f.code == 0x6408 and f.reason == -1, "0xB302 {2, 0x6408}")
	f = FriendNet.decode_failure(PackedByteArray([2, 0x0b, 0x64, 2, 2, 0, 0x42, 0x6f]))
	_check(f != null and f.code == FriendNet.CODE_REFUSED and f.reason == 2 and f.name == "Bo", "0xB302 {2, 0x640b, reason, name}")
	_check(FriendNet.decode_failure(PackedByteArray([1])) == null, "result 1 is nothing (c:0x885e98)")
	var list := FriendNet.decode_list(PackedByteArray([1, 5, 0, 0, 0, 2, 0, 0x41, 0x6c, 0x73, 0x07, 0, 0, 1]))
	_check(list.size() == 1 and list[0].character_id == 5 and list[0].friend_name == "Al" and list[0].ref_obj_id == 1907
		and list[0].state == 1 and not list[0].online, "0x3305: one offline friend")
	var added := FriendNet.decode_push(PackedByteArray([2, 6, 0, 0, 0, 2, 0, 0x42, 0x6f, 0x74, 0x07, 0, 0]))
	_check(added != null and added.kind == 2 and added.character_id == 6 and added.friend_name == "Bo" and added.ref_obj_id == 1908,
		"0x3B07 kind 2")
	FriendNet.apply_push(list, added)
	_check(list.size() == 2 and list[1].online, "kind 2 adds the friend online (c:0x8863da pushes 0)")
	FriendNet.apply_push(list, FriendNet.decode_push(PackedByteArray([4, 5, 0, 0, 0, 0])))
	_check(list[0].online, "kind 4 state 0: in the game")
	FriendNet.apply_push(list, FriendNet.decode_push(PackedByteArray([3, 5, 0, 0, 0])))
	_check(list.size() == 1 and list[0].friend_name == "Bo", "kind 3 removes")
	_check(FriendNet.decode_push(PackedByteArray([5, 0, 0, 0, 0])) == null, "kinds 5-7 have no client case")
	_check(FriendNet.decode_delete_result(PackedByteArray([1, 5, 0, 0, 0])) == [true, 5]
		and FriendNet.decode_delete_result(PackedByteArray([2, 3, 0])) == [false, 3], "0xB304 both ways")
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
