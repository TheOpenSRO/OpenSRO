extends SceneTree

## GameClock (round 786): the clock messages' bytes, the timer's integer
## arithmetic and the clock-hour -> sky-phase map, all READ from
## sro_client.exe (game_clock.gd's header has the addresses). Headless:
## `godot4 --headless --path client --script res://scripts/net/game_clock_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-5) -> bool:
	return absf(a - b) <= eps

func _reading(day: int, hour: int, minute: int, second: int) -> GameClock.Reading:
	var r := GameClock.Reading.new()
	r.day = day
	r.hour = hour
	r.minute = minute
	r.second = second
	return r

func _init() -> void:
	# The bytes the server sends (server/internal/session/celestial786_test.go
	# holds the other end to the same layout).
	var pos := GameClock.decode_position(PackedByteArray([0x04, 0x03, 0x02, 0x01, 0x06, 0x05, 0x07, 0x08]))
	_check(pos == [0x01020304, 0x0506, 7, 8], "0x3020: u32 uid, u16 day, u8 hour, u8 minute (got %s)" % str(pos))
	var upd := GameClock.decode_update(PackedByteArray([0x06, 0x05, 0x07, 0x08]))
	_check(upd == [0x0506, 7, 8], "0x3027: u16 day, u8 hour, u8 minute (got %s)" % str(upd))
	_check(GameClock.decode_position(PackedByteArray([1, 2, 3])).is_empty(), "a short 0x3020 is refused")
	_check(GameClock.OP_POSITION == 0x3020 and GameClock.OP_UPDATE == 0x3027, "the opcodes")

	# The timer: InitTimer at day 2, 14:30, then 20 ms a game second in whole
	# steps (30 x 1000 / 1440 truncated).
	_check(GameClock.MS_PER_GAME_SECOND == 30 * 1000 / 1440, "the divisor is the binary's integer 30000 / 1440 = 20")
	var c := GameClock.new()
	_check(not c.synced and _near(c.phase(0), GameClock.NO_CLOCK_PHASE) and c.hours(0) < 0.0,
		"before a message the phase is the no-clock 0.5 and the hour unknown")
	c.init_timer(2, 14, 30, 1000)
	_check(str(c.reading(1000)) == "day 2 14:30:00", "InitTimer starts the minute at second 0 (got %s)" % str(c.reading(1000)))
	_check(str(c.reading(1019)) == "day 2 14:30:00", "19 ms is not a game second yet (integer division)")
	_check(str(c.reading(1020)) == "day 2 14:30:01", "20 ms is one game second")
	_check(str(c.reading(1000 + 9 * 3600 * 20 + 30 * 60 * 20)) == "day 3 00:00:00", "9 h 30 game minutes later is the next day")
	_check(GameClock.MS_PER_GAME_SECOND * GameClock.SECONDS_PER_DAY == 1728000, "a game day is 1728 s of real time (28 min 48 s)")

	# The clock-hour -> sky-phase map (READ, FUN_0084ac90): 4:00 -> 6:00, 12:00
	# -> 12:00, 20:00 -> 18:00, 0:00 -> 0:00, 2:00 -> 3:00.
	_check(_near(GameClock.day_phase(4.0), 0.25), "clock 04:00 is the sky's 06:00 (0.25)")
	_check(_near(GameClock.day_phase(12.0), 0.5), "clock 12:00 is the sky's noon (0.5)")
	_check(_near(GameClock.day_phase(20.0), 0.75), "clock 20:00 is the sky's 18:00 (0.75)")
	_check(_near(GameClock.day_phase(0.0), 0.0), "clock 00:00 is the sky's midnight (0.0)")
	_check(_near(GameClock.day_phase(2.0), 0.125), "clock 02:00 is the sky's 03:00 (0.125)")
	_check(_near(GameClock.day_phase(22.0), 0.875), "clock 22:00 is the sky's 21:00 (0.875)")
	_check(_near(GameClock.day_phase(3.99999), GameClock.day_phase(4.0), 1e-4) and _near(GameClock.day_phase(20.00001), 0.75, 1e-4),
		"the map is continuous at 4:00 and at 20:00")
	_check(_near(GameClock.day_phase(8.0) - GameClock.day_phase(4.0), 4.0 * 0.75 / 24.0),
		"a day hour moves the sky three quarters of an hour")
	_check(_near(GameClock.day_phase(22.0) - GameClock.day_phase(20.0), 2.0 * 1.5 / 24.0),
		"a night hour moves the sky an hour and a half")
	_check(not _near(GameClock.day_phase(8.0), 8.0 / 24.0), "(negative) the sky's hour is not the clock's")
	_check(_near(GameClock.clock_hours(_reading(0, 18, 30, 0)), 18.5), "clock_hours: 18:30:00 is 18.5")
	_check(GameClock.is_night_hour(20.5) and GameClock.is_night_hour(3.0) and not GameClock.is_night_hour(4.0) and not GameClock.is_night_hour(20.0),
		"the sound's night: clock hour < 4 or > 20")

	# A message starts the timer; the phase follows it.
	var d := GameClock.new()
	_check(d.handle(GameClock.OP_POSITION, PackedByteArray([1, 0, 0, 0, 0, 0, 12, 0]), 5000), "0x3020 is taken")
	_check(d.synced and d.uid == 1 and _near(d.phase(5000), 0.5), "0x3020 at 12:00 -> the noon phase")
	_check(d.handle(GameClock.OP_UPDATE, PackedByteArray([0, 0, 20, 0]), 6000) and _near(d.phase(6000), 0.75),
		"0x3027 at 20:00 re-starts it -> 0.75")
	_check(_near(d.phase(6000 + 3600 * 20), GameClock.day_phase(21.0)), "an hour later the sky reads 21:00 of the clock")
	_check(not d.handle(0x3021, PackedByteArray([0, 0, 0, 0]), 0), "another opcode is not taken")

	# QA pins (OURS).
	var pins := GameClock.parse_qa("noon=12:00, sunset=19:30,night=23:00")
	_check(pins.size() == 3 and pins["sunset"] == Vector2i(19, 30), "OPENSRO_QA_CLOCK names a pin per shot (got %s)" % str(pins))
	_check(GameClock.parse_qa("13:45") == {"": Vector2i(13, 45)}, "a bare HH:MM pins the run")
	var e := GameClock.new()
	e.pin(19, 30)
	_check(e.synced and not e.running and _near(e.phase(0), e.phase(99999)), "a pinned clock holds")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
