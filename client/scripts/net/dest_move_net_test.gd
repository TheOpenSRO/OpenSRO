extends SceneTree

## DestMoveNet (round 749): retail's 0x7021 / 0xB021 / 0xB023 against the
## bytes the server pins (server/internal/session destmove749_test.go
## TestRound749TheEchoAndTheStopAreRetailsBytes; pcspawn TestClientMovingFixture
## for the records of players spawned moving), and NetClient's handling.
## `godot4 --headless --path client --script res://scripts/net/dest_move_net_test.gd`

## 0xB021: uid 0x01020304, a destination of region 0x61a8 local (1000, -3,
## 900), flag 1, source region 0x61a8, x * 10 = 9602, y 5.5, z * 10 = 9599.
const ECHO := "0403020101a861e803fdff840301a8618225 0000b0407f25"
## 0xB023: uid 0x0a0b0c0d, region 0x61a8, (960, 5, 960), wire angle 0.
const STOP := "0d0c0b0aa86100007044 0000a04000007044 0000"
## pcspawn's fixtureWalker / fixtureRunner: Cara walking to 0x61a8 local
## (1500, -2, 300), Dane on a heading run (command 1, angle 0x1234).
const WALKER := "73070000220000006d0005000003000000a86100807a440000604000007f4400400101a861dc05feff2c010100030000008041000048420000c8420004004361726100000000000000000000000000000000000000000000000000000000000000ff04"
const RUNNER := "73070000220000006d0005000004000000a86100807a440000604000007f44004000010134120100030000008041000048420000c84200040044616e6500000000000000000000000000000000000000000000000000000000000000ff04"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _hex(s: String) -> PackedByteArray:
	return s.replace(" ", "").hex_decode()

func _test_request() -> void:
	var d := DestMoveNet.encode_destination(0x61a8, 1000.0, -3.0, 900.0)
	_check(d == _hex("01a861e803fdff8403"), "the destination form is 01 | region | i16 x y z (%s)" % d.hex_encode())
	# ftol truncates toward zero (0x9ec080): 1000.9 -> 1000, -3.7 -> -3.
	_check(DestMoveNet.encode_destination(0x61a8, 1000.9, -3.7, 900.99) == d, "the coordinates are truncated, not rounded")
	_check(DestMoveNet.encode_heading(1, 0xbeef) == PackedByteArray([0, 1, 0xef, 0xbe]), "the heading form is 00 | command | u16 angle")
	# Round 808: the arrow keys' stop and turn, and the server's turn (destmove808_test.go).
	_check(DestMoveNet.encode_angle(0xbeef) == PackedByteArray([0xef, 0xbe]), "0x7023 / 0x7024 carry the u16 angle")
	_check(DestMoveNet.encode_cos_angle(0x01020304, DestMoveNet.COS_COMMAND_TURN, 0xbeef) == PackedByteArray([4, 3, 2, 1, 4, 0xef, 0xbe]),
		"ridden, 0x70C5 {uid, 4, angle}")
	var turn := DestMoveNet.decode_turn(PackedByteArray([4, 3, 2, 1, 0xef, 0xbe]))
	_check(int(turn["uid"]) == 0x01020304 and int(turn["angle"]) == 0xbeef, "0xB024 reads uid and angle")
	_check(int(DestMoveNet.decode_turn(PackedByteArray([1, 2]))["uid"]) == -1, "a short 0xB024 is refused")

func _test_echo() -> void:
	var e := DestMoveNet.decode_echo(_hex(ECHO))
	_check(e.error == "", "the server's 0xB021 reads (%s)" % e.error)
	_check(e.uid == 0x01020304 and e.kind == 1 and e.region == 0x61a8, "uid, kind, region")
	_check(e.local == Vector3i(1000, -3, 900), "the destination's i16s are sign-extended (%s)" % str(e.local))
	_check(e.has_source and e.source_region == 0x61a8, "flag 1 carries the source")
	_check(is_equal_approx(e.source_local.x, 960.2) and is_equal_approx(e.source_local.z, 959.9) and e.source_local.y == 5.5,
		"the source's x and z are tenths (%s)" % str(e.source_local))
	load("res://scripts/net/net_client.gd").resolve_echo(e, Vector2i(97, 168))
	_check(e.dest_world.is_equal_approx(Vector3(40, -3, 60)), "the destination in the 97/168 frame is world (40, -3, 60) (%s)" % str(e.dest_world))
	var h := DestMoveNet.decode_echo(_hex("0100000000012a1000"))
	_check(h.error == "" and h.kind == 0 and h.command == 1 and h.angle == 0x102a and not h.has_source, "a heading echo, flag 0")
	_check(DestMoveNet.decode_echo(_hex("0100000000012a1001")).error != "", "flag 1 with no source is an error")
	_check(DestMoveNet.decode_echo(_hex("01000000")).error != "", "a short echo is an error")

func _test_stop() -> void:
	var s := DestMoveNet.decode_stop(_hex(STOP))
	_check(s.error == "" and s.uid == 0x0a0b0c0d and s.region == 0x61a8 and s.local == Vector3(960, 5, 960) and s.angle == 0,
		"the server's 0xB023 reads")
	_check(DestMoveNet.decode_stop(_hex(STOP).slice(0, 19)).error != "", "a short stop is an error")

func _test_frames() -> void:
	# server/internal/worldmap's measured point: 97/168 local (1002, 1020) is
	# world (42, -60) in Jangan's frame.
	var l := DestMoveNet.local_of_world(42.0, -60.0, Vector2i(97, 168))
	_check(int(l["region"]) == 0x61a8 and is_equal_approx(float(l["lx"]), 1002.0) and is_equal_approx(float(l["lz"]), 1020.0),
		"world (42, -60) is 97/168 local (1002, 1020): %s" % str(l))
	for w in [Vector2(-1500, 2500), Vector2(3000, -100), Vector2(0, 0), Vector2(-959.5, 959.5)]:
		var r := DestMoveNet.local_of_world(w.x, w.y, Vector2i(97, 168))
		var back := DestMoveNet.world_of_local(int(r["region"]), float(r["lx"]), float(r["lz"]), Vector2i(97, 168))
		_check(back.is_equal_approx(w) and float(r["lx"]) >= 0.0 and float(r["lx"]) < 1920.0 and float(r["lz"]) >= 0.0 and float(r["lz"]) < 1920.0,
			"world %s round-trips through region %x" % [str(w), int(r["region"])])

func _test_moving_records() -> void:
	var walker := UserSpawnNet.decode_single_spawn(_hex(WALKER), null)
	_check(walker != null and walker.has_dest and walker.dest_region == 0x61a8 and walker.dest_local == Vector3i(1500, -2, 300),
		"a record spawned walking carries its destination")
	if walker != null:
		var s := UserSpawnNet.to_snapshot(walker, null, Vector2i(97, 168))
		_check(s.has_dest and s.dest.is_equal_approx(Vector3(540, -2, 660)) and s.run_wire == -1 and s.run_speed == 50.0,
			"its snapshot walks to world (540, -2, 660) at 50 (%s)" % str(s.dest))
	var runner := UserSpawnNet.decode_single_spawn(_hex(RUNNER), null)
	_check(runner != null and not runner.has_dest and runner.move_command == 1 and runner.move_angle == 0x1234,
		"a record spawned on a heading run carries its command and angle")
	if runner != null:
		var s := UserSpawnNet.to_snapshot(runner, null, Vector2i(97, 168))
		_check(not s.has_dest and s.run_wire == 0x1234, "its snapshot runs on wire angle 0x1234")

## NetClient: 0xB021 / 0xB023 reach World3D resolved in the result's frame,
## in order behind a player spawn still waiting for the item table.
func _test_net_client() -> void:
	var nc = load("res://scripts/net/net_client.gd").new()
	var res := WorldNet.EnterWorldResult.new()
	res.ok = true
	res.frame = "97/168"
	nc.last_enter_world_result = res
	nc._start_user_view(res.frame)
	var echoes: Array = []
	var stops: Array = []
	nc.entity_move_echo.connect(func(e): echoes.append(e))
	nc.entity_move_stop.connect(func(s): stops.append(s))
	nc._user_spawn_message(DestMoveNet.OP_MOVEMENT_ECHO, _hex(ECHO))
	nc._user_spawn_message(DestMoveNet.OP_MOVEMENT_STOP, _hex(STOP))
	_check(echoes.size() == 1 and (echoes[0] as DestMoveNet.Echo).dest_world.is_equal_approx(Vector3(40, -3, 60)), "the echo is emitted, resolved")
	_check(stops.size() == 1 and (stops[0] as DestMoveNet.Stop).world.is_equal_approx(Vector3(0, 5, 0)), "the stop is emitted at world (0, 5, 0)")
	# Behind a waiting spawn: held until the item table comes.
	nc._pending_spawns.append({"op": NpcSpawnNet.OP_SINGLE_SPAWN, "data": _hex(WALKER)})
	nc._user_spawn_message(DestMoveNet.OP_MOVEMENT_ECHO, _hex(ECHO))
	_check(echoes.size() == 1, "an echo behind a waiting spawn waits")
	nc.set_spawn_item_rows({})
	_check(echoes.size() == 2, "and follows it once the table comes")
	nc.free()

func _init() -> void:
	_test_request()
	_test_echo()
	_test_stop()
	_test_frames()
	_test_moving_records()
	_test_net_client()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
