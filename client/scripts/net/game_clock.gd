extends RefCounted
class_name GameClock

## The game clock (round 786; docs/protocol/game_clock.md): the server names
## the in-game day, hour and minute at world entry (0x3020) and when an
## operator sets the hour (0x3027); the client runs the same timer from there
## and turns its hour into the sky's day phase every frame.
##
## READ (sro_client.exe, the box's decompile and objdump):
## - 0x3020 -> FUN_008a6dc0 (registered in FUN_0086fbb0): u32 the player's
##   unique id (handed to the player object, vtable +0x48), u16 day, u8 hour,
##   u8 minute; dwRealTime := 0x1e; `m_LocalTime.InitTimer(dwRealTime, m_wDay,
##   m_byHour, m_byMin, 0)` (FUN_008b00f0: base = ((day x 24 + hour) x 60 +
##   minute) x 60 + 0, started at GetTickCount()).
## - 0x3027 -> FUN_008a6e80: u16 day, u8 hour, u8 minute, the same InitTimer
##   unless the console's TimeOff has locked the time (CGInterface +0x7cd).
## - The timer's reading (FUN_008b01b0): elapsed_ms / (30 x 1000 / 1440) +
##   base, in integers -- the divisor truncates to 20, so one game second is
##   20 real ms and a day 28 min 48 s -- split into second (% 60), minute
##   (/ 60 % 60), hour (/ 3600 % 24) and day (/ 86400).
## - CPSMission::vslot_012 calls FUN_0084ac90 every frame (unless the zone is
##   loading); it reads the timer's hour, minute and second and maps them to
##   the day phase SWorld's environment is sampled at (day_phase below), and
##   passes the day to SWorld::vslot_021 (+0x6778, the moon's picture).
## The server's clock (SR_GameServer 0x427660 / 0x427720) is the same code at
## the same rate, so the two ends agree to within the minute the server names
## (the client starts that minute at second 0).

## READ: the clock messages.
const OP_POSITION := 0x3020
const OP_UPDATE := 0x3027
## READ: dwRealTime, real minutes per game day (0x1e at 0x8a6dc0).
const REAL_MINUTES_PER_DAY := 30
## READ: the timer's integer divisor, 30 x 1000 / 1440 truncated.
const MS_PER_GAME_SECOND := 20
const SECONDS_PER_DAY := 86400

## The day phase drawn with no clock -- a server older than round 786 or one
## run with -world-clock off: the fixed 0.5 this client drew before (OURS
## fallback; retail always receives 0x3020 at entry).
const NO_CLOCK_PHASE := 0.5

## True once a 0x3020 or 0x3027 has started the timer (or a QA pin).
var synced := false
## Whether the timer runs (false: a QA pin holds the reading).
var running := true
var _base := 0
var _start_ms := 0
## The last 0x3020's uid (logged; OpSelfID already names the player).
var uid := 0
## OPENSRO_QA_CLOCK's pins by shot name, "" -> the whole run's (see qa_pins).
var qa_pins := {}

class Reading:
	var day := 0
	var hour := 0
	var minute := 0
	var second := 0
	func _to_string() -> String:
		return "day %d %02d:%02d:%02d" % [day, hour, minute, second]

## 0x3020's payload -> [uid, day, hour, minute], or [] when short.
static func decode_position(data: PackedByteArray) -> Array:
	if data.size() < 8:
		return []
	return [data.decode_u32(0), data.decode_u16(4), data[6], data[7]]

## 0x3027's payload -> [day, hour, minute], or [] when short.
static func decode_update(data: PackedByteArray) -> Array:
	if data.size() < 4:
		return []
	return [data.decode_u16(0), data[2], data[3]]

func reset() -> void:
	synced = false
	running = true
	_base = 0
	_start_ms = 0
	uid = 0
	if qa_pins.has(""):
		var at: Vector2i = qa_pins[""]
		pin(at.x, at.y)

## InitTimer (READ, FUN_008b00f0): the base in game seconds, started now.
func init_timer(day: int, hour: int, minute: int, now_ms: int) -> void:
	_base = ((day * 24 + hour) * 60 + minute) * 60
	_start_ms = now_ms
	synced = true

## The timer's game seconds at now_ms (READ: the integer division).
func seconds(now_ms: int) -> int:
	if not running:
		return _base
	var elapsed := maxi(now_ms - _start_ms, 0)
	if qa_speed != 1.0:
		elapsed = int(elapsed * qa_speed)
	return _base + elapsed / MS_PER_GAME_SECOND

static func split(s: int) -> Reading:
	var r := Reading.new()
	r.day = (s / SECONDS_PER_DAY) & 0xffff
	r.hour = (s / 3600) % 24
	r.minute = (s / 60) % 60
	r.second = s % 60
	return r

func reading(now_ms: int) -> Reading:
	return split(seconds(now_ms))

## The clock's hour as FUN_0084ac90 computes it: (second + (minute + hour x
## 60) x 60) / 86400.0 x 24.0 (READ: the doubles at 0xdd43e8 and 0xd830a0,
## stored to a float in between).
static func clock_hours(r: Reading) -> float:
	var s := r.second + (r.minute + r.hour * 60) * 60
	return f32(f32(float(s) / 86400.0) * 24.0)

## The day phase SWorld's environment is read at, from the clock's hour
## (READ, FUN_0084ac90 0x84ad55..0x84ae74): between 4:00 and 20:00 of the
## clock (inclusive) the sky's hour is 6 + (h - 4) x 12 x 0.0625 -- 16 clock
## hours become the sky's 6:00..18:00; otherwise (h + 24 below 4) it is
## 18 + (h - 20) x 12 x 0.125, less 24 at or past 24 -- 8 clock hours become
## 18:00..6:00. The phase is that hour / 24. Constants: 4.0 (0xd8ada8,
## 0xe1b860), 20.0 (0xd88108, 0xe1b830), 12.0 (0xd89248), 0.0625 (0xdd43e0),
## 6.0 (0xd99a68), 0.125 (0xdd43d8), 18.0 (0xdd43d0), 24.0 (0xd880e0,
## 0xd830a0). So a clock day of 28 min 48 s is 19 min 12 s of sky daytime and
## 9 min 36 s of night.
static func day_phase(h: float) -> float:
	var sky_hour: float
	if h >= 4.0 and h <= 20.0:
		sky_hour = f32(f32(f32(h - 4.0) * 12.0) * 0.0625 + 6.0)
	else:
		if h < 4.0:
			h = f32(h + 24.0)
		sky_hour = f32(f32(f32(h - 20.0) * 12.0) * 0.125 + 18.0)
		if sky_hour >= 24.0:
			sky_hour = f32(sky_hour - 24.0)
	return f32(sky_hour / 24.0)

## Whether the clock's hour is night for the sound (READ, FUN_0084ac90: the
## flag it hands the sound manager, vtable +0x6c, is the else branch above;
## AmbientBeds.is_night is the same test).
static func is_night_hour(h: float) -> bool:
	return h < 4.0 or h > 20.0

## The world's night flag at a day phase (round 806, READ:
## docs/protocol/night_lights.md). SWorld::vslot_004 (0xa2cf60), every world
## frame with no dungeon or zone test before it, shifts the phase +0x26a3 by
## a quarter -- phase + 0.75 below 0.25 (the float 0.25 at 0xd9a2b8, the
## double 0.75 at 0xda34b0), else phase - 0.25 (the double at 0xd83070) --
## stores it as a float (+0x26a7) and sets the effect manager's +0x1a8
## (0x1112fb0, through the thunk 0xbbdbf0 at 0xa2d1c6) to 0.5 (0xe1b7e0) <
## that. So night is a phase below 0.25 or above 0.75: with day_phase, clock
## 20:00:01 to 03:59:59 (04:00:00 and 20:00:00 are day; MEASURED in
## game_clock_test.gd over every second of a day).
static func is_night_phase(p: float) -> bool:
	var shifted := f32(p + 0.75) if p < 0.25 else f32(p - 0.25)
	return shifted > 0.5

## The phase to draw now: the clock's, or NO_CLOCK_PHASE before any.
func phase(now_ms: int) -> float:
	if not synced:
		return NO_CLOCK_PHASE
	return day_phase(clock_hours(reading(now_ms)))

## The clock's hour now, or -1.0 before any (MusicDirector's "no clock").
func hours(now_ms: int) -> float:
	if not synced:
		return -1.0
	return clock_hours(reading(now_ms))

## A message: 0x3020 or 0x3027 (true when it was one and was taken).
func handle(opcode: int, data: PackedByteArray, now_ms: int) -> bool:
	var fields: Array
	match opcode:
		OP_POSITION:
			fields = decode_position(data)
			if fields.is_empty():
				return false
			uid = fields[0]
			fields = fields.slice(1)
		OP_UPDATE:
			fields = decode_update(data)
			if fields.is_empty():
				return false
		_:
			return false
	if not qa_pins.is_empty():
		# A QA pin holds the clock against the server's (OURS, QA only).
		print("GameClock: 0x%04x day %d %02d:%02d from the server -- held by OPENSRO_QA_CLOCK" % [opcode, fields[0], fields[1], fields[2]])
		return true
	init_timer(fields[0], fields[1], fields[2], now_ms)
	print("GameClock: 0x%04x day %d %02d:%02d -> sky phase %.4f%s" % [opcode, fields[0], fields[1], fields[2],
		phase(now_ms), (" (uid %d)" % uid) if opcode == OP_POSITION else ""])
	return true

## OPENSRO_QA_CLOCK (OURS, QA only): "HH:MM" pins the clock there for the
## run; "name=HH:MM,name=HH:MM" pins it per QA shot (World3D applies the pin
## named like the shot when the shot begins). A pinned clock does not run.
static func parse_qa(spec: String) -> Dictionary:
	var out := {}
	for part in spec.split(",", false):
		var name := ""
		var at := part.strip_edges()
		if at.contains("="):
			name = at.get_slice("=", 0).strip_edges()
			at = at.get_slice("=", 1).strip_edges()
		var hm := at.split(":")
		if hm.size() != 2 or not hm[0].is_valid_int() or not hm[1].is_valid_int():
			continue
		out[name] = Vector2i(clampi(hm[0].to_int(), 0, 23), clampi(hm[1].to_int(), 0, 59))
	return out

## Pins the clock at hour:minute (QA): synced, not running -- or, with
## qa_speed > 0 (OPENSRO_QA_CLOCK_RUN, OURS), running from there that many
## times faster than the game's own rate (the perf gate's moving day).
func pin(hour: int, minute: int) -> void:
	_base = (hour * 60 + minute) * 60
	synced = true
	running = qa_run
	_start_ms = Time.get_ticks_msec()

## QA (OURS): a pinned clock runs (OPENSRO_QA_CLOCK_RUN=<speed>), at this
## multiple of the game's rate.
var qa_run := false
var qa_speed := 1.0

static func f32(v: float) -> float:
	return PackedFloat32Array([v])[0]
