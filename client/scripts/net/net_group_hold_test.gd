extends SceneTree

## Round 762's review, F5: while a group spawn or despawn is read a frame's
## share at a time, the packets behind it that cannot concern a body of the
## group are dispatched at once -- this player's own results, the monsters,
## chat, a known player's moves -- and the rest wait, in order, and go first
## once the group is done. A move of a player still unknown waits, and so do
## that player's later moves (their order kept); after a barrier (a zone
## change's result) everything waits.
##   godot4 --headless --path client --script res://scripts/net/net_group_hold_test.gd
## NEGATIVE (by hand): _passes_group returning false always fails "an unstuck
## result is dispatched while the group is read"; dropping the _held_uids test
## fails "a known player's later move waits behind its held one".

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_hold()
	_test_held_groups()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

static func _stop(uid: int, x: float) -> Packet:
	var d := PackedByteArray()
	d.resize(20)
	d.encode_u32(0, uid)
	d.encode_u16(4, 0x61a8)
	d.encode_float(6, x)
	d.encode_float(10, 0.0)
	d.encode_float(14, 0.0)
	d.encode_u16(18, 0)
	return Packet.new(DestMoveNet.OP_MOVEMENT_STOP, d)

static func _unstuck(wait: int) -> Packet:
	var d := PackedByteArray([1, 0, 0])
	d.encode_u16(1, wait)
	return Packet.new(0x00b9, d)

func _test_hold() -> void:
	var nc = load("res://scripts/net/net_client.gd").new()
	var seen: Array = []
	nc.entity_move_stop.connect(func(s): seen.append("stop %d %.0f" % [s.uid, s.local.x]))
	nc.unstuck_result.connect(func(_ok, w): seen.append("unstuck %d" % w))
	nc.user_roster[7] = true
	# A despawn group that does not finish in one frame: many ids, none in view.
	var uids: Array = []
	for i in range(400000):
		uids.append(1000000 + i)
	nc._group_job = {"uids": uids, "count": uids.size(), "i": 0, "users": 0, "npcs": 0, "bytes": 0, "t0": Time.get_ticks_usec(), "frames": 0}
	var queue: Array = [_stop(9, 1.0), _unstuck(1), _stop(7, 2.0), _stop(9, 3.0), _unstuck(2)]
	var poll := func():
		return queue.pop_front() if not queue.is_empty() else null
	nc._net_frame(poll)
	_check(nc._group_job != null, "the group is still being read after a frame")
	_check(seen == ["unstuck 1", "stop 7 2", "unstuck 2"], "an unstuck result is dispatched while the group is read, a known player's move too; an unknown player's moves wait (%s)" % str(seen))
	_check(nc.held_count() == 2, "two moves wait (%d)" % nc.held_count())
	# 9 becomes known (its record read); its next move still waits behind its first.
	nc.user_roster[9] = true
	queue.append(_stop(9, 4.0))
	nc._net_frame(poll)
	_check(nc.held_count() == 3 and seen.size() == 3, "a known player's later move waits behind its held one (%d held)" % nc.held_count())
	# A barrier: everything after it waits.
	queue.append(Packet.new(WorldNet.OP_CHANGE_ZONE_RESULT, PackedByteArray()))
	queue.append(_unstuck(3))
	nc._net_frame(poll)
	_check(nc._held_barrier and nc.held_count() == 5 and seen.size() == 3, "after a zone change's result everything waits (%d held)" % nc.held_count())
	# The barrier taken out by hand (its empty result is not a real one), the
	# group done: what waited goes first, in order.
	nc._held_packets.remove_at(3)
	nc._group_job = null
	queue.append(_unstuck(4))
	nc._net_frame(poll)
	_check(seen == ["unstuck 1", "stop 7 2", "unstuck 2", "stop 9 1", "stop 9 3", "stop 9 4", "unstuck 3", "unstuck 4"],
		"once the group is read the held packets go first, in their order (%s)" % str(seen))
	_check(nc.held_count() == 0 and not nc._held_barrier and nc._held_uids.is_empty(), "nothing is held after")
	nc.free()

## Round 764: a group end (0x3018) waiting behind the group being read keeps
## group_reading() true until it is dispatched -- a frame that falls between
## two groups of one window must not reveal their page -- and a dispatched
## 0x3018 sets group_rx_msec from its packet's receive time.
func _test_held_groups() -> void:
	var nc = load("res://scripts/net/net_client.gd").new()
	var uids: Array = []
	for i in range(400000):
		uids.append(2000000 + i)
	nc._group_job = {"uids": uids, "count": uids.size(), "i": 0, "users": 0, "npcs": 0, "bytes": 0, "t0": Time.get_ticks_usec(), "frames": 0}
	var begin := Packet.new(NpcSpawnNet.OP_GROUP_BEGIN, PackedByteArray([2, 1, 0]))
	var data := PackedByteArray()
	data.resize(4)
	data.encode_u32(0, 3000001)
	var body := Packet.new(NpcSpawnNet.OP_GROUP_DATA, data)
	var end := Packet.new(NpcSpawnNet.OP_GROUP_END, PackedByteArray())
	end.rx_msec = 12345
	var queue: Array = [begin, body, end]
	var poll := func():
		return queue.pop_front() if not queue.is_empty() else null
	nc._net_frame(poll)
	_check(nc._group_job != null and nc._held_groups == 1, "a group's 0x3018 behind the one being read is counted (%d)" % nc._held_groups)
	nc._group_job = null
	_check(nc.group_reading(), "group_reading() is true while a held group waits")
	nc._net_frame(poll)
	_check(nc._held_groups == 0, "the count drops when it is dispatched")
	_check(nc.group_rx_msec == 12345, "group_rx_msec is the 0x3018's receive time (%d)" % nc.group_rx_msec)
	nc.free()
