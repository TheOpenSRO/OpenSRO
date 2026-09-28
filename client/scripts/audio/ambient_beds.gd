extends RefCounted
class_name AmbientBeds

## A zone's ambient list at run time: looping beds and timed one-shots
## (round 612). No nodes, so a headless test can drive it; MusicDirector
## plays what it returns.
##
## READ from sro_client.exe (audio_spec 6, sec_A A.5), SetArea and
## CGEffSoundBody::vslot_005:
## - An entry with a == 0 (`0~0`, 119 of the 569 live rows, MEASURED) is a
##   bed: it starts looping when the zone is entered.
## - Any other entry is a one-shot with a countdown, first set to `a`. Every
##   2 s tick: a countdown below 3 plays the sound once and becomes
##   rand() % (b - a) + a; otherwise it loses 2. So `a~b` is seconds and the
##   first play comes about `a` seconds after entering.
## - The list is chosen when the area changes, day or night, and not again
##   until the next change.
## - Everything is 2-D, at the one Env volume, with no per-entry volume.
## INFERRED: that the timer registered as id 1 / 2000 ms drives vslot_005(1).
## OURS: the tick's phase (it restarts on each zone entry; retail's timer runs
## on regardless) and the random source (Godot's randi, not MSVC rand()). No
## row has a == b != 0 (MEASURED); if one did, its countdown resets to a.

const TICK_SECONDS := 2.0

class Shot:
	var file: String = ""
	var a: int = 0
	var b: int = 0
	var countdown: int = 0
	## Whether it has played since the zone was entered (for the log).
	var played := false

## Files of the looping beds of the current list.
var beds: PackedStringArray = PackedStringArray()
var shots: Array = []
var _clock := 0.0

## Takes a zone's day or night list (EnvSoundTable.Entry). Returns the beds
## to start looping.
func start(entries: Array) -> PackedStringArray:
	stop()
	for e in entries:
		if e.a == 0:
			beds.append(e.file)
		else:
			var s := Shot.new()
			s.file = e.file
			s.a = e.a
			s.b = e.b
			s.countdown = e.a
			shots.append(s)
	return beds

func stop() -> void:
	beds = PackedStringArray()
	shots = []
	_clock = 0.0

## Advances the 2 s tick by `delta`; returns the one-shots due now (Shot).
## `roll` is a Callable returning a non-negative random int.
func advance(delta: float, roll: Callable) -> Array:
	_clock += delta
	var due: Array = []
	while _clock >= TICK_SECONDS:
		_clock -= TICK_SECONDS
		due.append_array(tick(roll))
	return due

## One 2 s tick (READ rule above).
func tick(roll: Callable) -> Array:
	var due: Array = []
	for s in shots:
		var shot: Shot = s
		if shot.countdown < 3:
			due.append(shot)
			var span := shot.b - shot.a
			shot.countdown = (int(roll.call()) % span + shot.a) if span > 0 else shot.a
		else:
			shot.countdown -= 2
	return due

## Retail's night test on the game clock's hour (FUN_0084ac90, READ; floats
## 4.0 at 0xd8ada8 and 20.0 at 0xd88108): night is h < 4 or h > 20.
## A negative hour means "no clock": day.
static func is_night(hour: float) -> bool:
	if hour < 0.0:
		return false
	return hour < 4.0 or hour > 20.0
