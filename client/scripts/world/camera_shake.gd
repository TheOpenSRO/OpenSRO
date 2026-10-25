extends RefCounted
class_name CameraShake

## Round 826: the original's camera shake. READ from sro_client.exe unless
## a line says otherwise; docs/protocol/camera_shake.md has the addresses.
##
## ONE SHAKE AT A TIME. `start` is UI_SILKMALL::FUN_0078db50 on the game
## process (ds:0x110f80c): it stores the mode (+0x408), the strength in both
## +0x414 (the one in force) and +0x420 (the start), the length (+0x40c) and
## the tick (+0x410), kills and re-arms timer 4 (the length) and timer 5 (the
## tick), zeroes the two offsets (+0x418, +0x41c) and marks it running
## (+0x424). A shake started while one runs replaces it.
##
## THE TIMERS (FUN_00b93320 / FUN_00b933d0, polled once a frame): a timer
## fires on the first frame its period has passed since it last fired (or
## was set), and its last-fired time becomes that frame's time. Timer 4 was
## set first and is polled first, so a frame that is due for both ends the
## shake and the tick does not run.
## - Timer 4 (case 3 of the process's timer switch, 0x789870): both timers
##   killed, the offsets and the strength zeroed, the shake over.
## - Timer 5 (case 4): the strength falls by round(start x since / length),
##   `since` the ms since timer 5 last fired (DAT_0110f800 - the entry's
##   +0x10), the x87's round to nearest-even; a 0 becomes 1. Then mode 0 draws
##   both offsets, mode 1 the height only, mode 2 the side only, each
##   (rand() % (2 x strength) - strength) / 100.0 (0xe1b7d8 = 100.0) -- the
##   modulus unsigned, as the client's is.
##
## THE CAMERA (UI_SILKMALL::FUN_0078dc50): the look-at point is the player's
## position plus +0x418 on x and +0x41c on the height; the eye goes round it,
## so the whole view moves. The original's x is the world's x here
## (UserSpawnNet.world_xz).
##
## OURS: the clock is the caller's (World3D's scene time, so a movie render
## shakes as it plays; the original reads timeGetTime), and rand() is
## Godot's, 0..0x7fff as MSVC's.

## The original's shakes by script flag (READ, the SCT_ name table at
## 0x00ec7378 and the strengths each caller passes): [strength, tick ms].
## Every one lasts LENGTH_MS.
const SCT_SHAKECAM0 := 0x8
const SCT_SHAKECAM1 := 0x10
const SCT_SHAKECAM_MOV0 := 0x20
const SCT_SHAKECAM_MOV1 := 0x40
const SCT_SHAKECAM2 := 0x80
const SCT_SHAKECAM3 := 0x100
const SCT_SHAKECAM_MOV2 := 0x200
const SCT_SHAKECAM_MOV3 := 0x400
## When the row plays (IDecoSkill::FUN_00a51bc0, 0xa52e74..).
const START_FLAGS := [SCT_SHAKECAM0, SCT_SHAKECAM1, SCT_SHAKECAM2, SCT_SHAKECAM3]
## When the row's mover arrives (IDecoSkill::FUN_00a4bf00, 0xa4bf62..).
const MOV_FLAGS := [SCT_SHAKECAM_MOV0, SCT_SHAKECAM_MOV1, SCT_SHAKECAM_MOV2, SCT_SHAKECAM_MOV3]
const STRENGTH := {
	SCT_SHAKECAM0: [50, 20], SCT_SHAKECAM_MOV0: [50, 20],
	SCT_SHAKECAM1: [200, 25], SCT_SHAKECAM_MOV1: [200, 25],
	SCT_SHAKECAM2: [300, 25], SCT_SHAKECAM_MOV2: [300, 25],
	SCT_SHAKECAM3: [400, 25], SCT_SHAKECAM_MOV3: [400, 25],
}
const LENGTH_MS := 500
## The own blow's shakes (FUN_00a49290, 0xa495c5): [strength, tick ms].
const HIT_LIGHT := [50, 20]
const HIT_HEAVY := [200, 25]
## The divisor of an offset (0xe1b7d8).
const UNIT := 100.0

const MODE_BOTH := 0
const MODE_HEIGHT := 1
const MODE_SIDE := 2

var mode := MODE_BOTH
var strength := 0
var strength0 := 0
var length_ms := 0
var tick_ms := 0
var side := 0.0
var height := 0.0
var active := false
var _end_last := 0
var _tick_last := 0
## Test seam: Callable() -> int in 0..0x7fff.
var rand: Callable = Callable()

## The script flags (any of a row's) -> the shakes they start, as
## [strength, tick] pairs, in the order the client tests them.
static func shakes_of(flags: int, which: Array) -> Array:
	var out: Array = []
	for f in which:
		if flags & int(f):
			out.append(STRENGTH[f])
	return out

## The own blow's shake (FUN_00a49290): a critical (the hit's flag 0x02) or a
## blow while berserk shakes; [] for none.
static func hit_shake(critical: bool, berserk: bool) -> Array:
	if critical:
		return HIT_HEAVY if berserk else HIT_LIGHT
	return HIT_LIGHT if berserk else []

func start(p_mode: int, p_strength: int, p_length_ms: int, p_tick_ms: int, now_ms: int) -> void:
	mode = p_mode
	strength = p_strength
	strength0 = p_strength
	length_ms = p_length_ms
	tick_ms = p_tick_ms
	side = 0.0
	height = 0.0
	# FUN_00b93320 turns a period of 0 into 1.
	length_ms = maxi(length_ms, 1)
	tick_ms = maxi(tick_ms, 1)
	_end_last = now_ms
	_tick_last = now_ms
	active = true

## One frame at `now_ms`: the timers polled in the order they were set.
func step(now_ms: int) -> void:
	if not active:
		return
	if now_ms - _end_last >= length_ms:
		_end_last = now_ms
		stop()
		return
	if now_ms - _tick_last >= tick_ms:
		var since := now_ms - _tick_last
		_tick_last = now_ms
		_tick(since)

func stop() -> void:
	active = false
	side = 0.0
	height = 0.0
	strength0 = 0

func _tick(since_ms: int) -> void:
	var fall := _round_even(float(strength0) * (float(since_ms) / float(length_ms)))
	strength -= fall
	if strength == 0:
		strength = 1
	match mode:
		MODE_BOTH:
			side = _draw()
			height = _draw()
		MODE_HEIGHT:
			height = _draw()
		MODE_SIDE:
			side = _draw()

## (rand() % (uint)(2 x strength) - strength) / 100.0, in the client's
## unsigned arithmetic (a strength below 0 makes the modulus huge, so the
## draw is rand() + |strength|).
func _draw() -> float:
	var r := int(rand.call()) if rand.is_valid() else randi() % 0x8000
	var m := (strength * 2) & 0xffffffff
	var v := (r % m) if m != 0 else 0
	var d := (v - strength) & 0xffffffff
	if d >= 0x80000000:
		d -= 0x100000000
	return float(d) / UNIT

static func _round_even(x: float) -> int:
	var f := floorf(x)
	var frac := x - f
	if frac > 0.5:
		return int(f) + 1
	if frac < 0.5:
		return int(f)
	return int(f) if int(f) % 2 == 0 else int(f) + 1

## The look-at point's offset in world axes.
func offset() -> Vector3:
	return Vector3(side, height, 0.0) if active else Vector3.ZERO
