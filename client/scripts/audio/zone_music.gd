extends RefCounted
class_name ZoneMusic

## The background-music state machine, with no nodes in it so a headless
## test can hold it to account (round 612). MusicDirector drives an
## AudioStreamPlayer from it: it reads `commands` (start/stop) and
## fade_offset_db() every frame.
##
## READ from sro_client.exe (audio_spec 2.2-2.6, sec_A A.2-A.3):
## - SetArea (vslot_026, 0xa732d0) does nothing when the area is unchanged.
##   On a change: an unknown zone, or none, LEAVES THE MUSIC PLAYING; a known
##   zone calls PlayBGM with its track unless an override playlist is active
##   or BGM is muted.
## - PlayBGM (FUN_00a67d70) does nothing when the name equals the current
##   track, so zones sharing a file (Jangan and Bandit_Fortress share
##   Jangan_Town.ogg) never restart it.
## - A change while something plays FADES OUT in 10 steps, linear in
##   hundredths of a dB from the music volume V down to -3000 (-30 dB)
##   (FUN_00bb6640: f -= 0.1, vol = (V + 3000) * f - 3000), then the new
##   track HARD-STARTS at V: no crossfade, no fade-in. From idle it starts at
##   once (FUN_00bb6290).
## - Four override levels, 0..3 (PushBGM +0x54, PopBGM +0x5c): 0 the title's
##   IntroBGM, 1 fortress war, 2 a record's BGM (source table not read), 3 a
##   script's S_SetBGM. The first push stops the zone music and plays its
##   name; a later push joins its level and switches only if its level is at
##   least the active one. Pop-all returns to the zone music; popping one
##   level falls back to the highest non-empty level, or the zone music.
## - BGM muted (-10000) STOPS the track; un-muting restarts the zone track,
##   or the active playlist entry, from the start.
## - The loading screen (FUN_0084ab20) stops the music and the ambient,
##   clears the area and pops every level: loading is silent and the first
##   world frame starts the zone's music from the top.
## INFERRED: each fade step is one quarter-buffer notify of the 1 s stream
## buffer, so the fade takes about 2.5 s (FADE_STEP_SECONDS).
## OURS: a track loops seamlessly (retail replays it on its end-of-track
## message after a zero tail, a gap INFERRED at 0.25-0.5 s); a level keeps
## one entry per name and plays its first on a fall-back (retail rotates a
## level's list on track end; nothing here pushes two names to one level).

const FADE_STEPS := 10
const FADE_STEP_SECONDS := 0.25
const FADE_FLOOR_DB := -30.0

const LEVEL_TITLE := 0
const LEVEL_SIEGE := 1
const LEVEL_RECORD := 2
const LEVEL_SCRIPT := 3
const LEVELS := 4

enum State { IDLE, PLAYING, FADING }

var state: int = State.IDLE
## The name PlayBGM last took (retail this+0xd0); "" after a stop.
var track := ""
## What the stream is playing now; "" when idle. Differs from `track` only
## while a fade runs towards `track`.
var sounding := ""
## The current area's music ("" when the area has no record).
var zone_bgm := ""
var muted := false
## Override playlist: LEVELS arrays of names, and the level playing, or -1.
var levels: Array = [[], [], [], []]
var active_level := -1
## Start/stop orders for the player: ["start", name] or ["stop"], oldest
## first. MusicDirector drains it every frame.
var commands: Array = []

var _step := 0
var _clock := 0.0

## PlayBGM. Returns true when `name` becomes the new track.
func play(name: String) -> bool:
	if name == "" or name == track:
		return false
	track = name
	match state:
		State.IDLE:
			_start()
		State.PLAYING:
			state = State.FADING
			_step = 0
			_clock = 0.0
		State.FADING:
			pass # the running fade ends in the new track
	return true

## Stops the music at once (retail +0x4c; also clears the name).
func stop() -> void:
	track = ""
	if state != State.IDLE:
		commands.append(["stop"])
	state = State.IDLE
	sounding = ""
	_step = 0
	_clock = 0.0

## SetArea's music half: `known` is whether the zone has a record. Returns
## what happened, for the log: "start", "fade", "same", "unknown", "held"
## (a playlist or the mute holds the zone music back).
func enter_area(known: bool, bgm: String) -> String:
	if not known:
		return "unknown"
	zone_bgm = bgm
	if active_level >= 0 or muted:
		return "held"
	if bgm == track:
		return "same"
	var was_idle := state == State.IDLE
	play(bgm)
	return "start" if was_idle else "fade"

## Advances a running fade by `delta` seconds.
func advance(delta: float) -> void:
	if state != State.FADING:
		return
	_clock += delta
	while state == State.FADING and _clock >= FADE_STEP_SECONDS:
		_clock -= FADE_STEP_SECONDS
		_step += 1
		if _step >= FADE_STEPS:
			_start()

## The player's volume relative to the BGM bus: 0 dB except while fading,
## when it walks linearly in dB from the bus's `option_db` to -30 dB.
func fade_offset_db(option_db: float) -> float:
	if state != State.FADING:
		return 0.0
	return -(option_db - FADE_FLOOR_DB) * float(_step) / float(FADE_STEPS)

## PushBGM(name, level).
func push(name: String, level: int) -> void:
	level = clampi(level, 0, LEVELS - 1)
	if active_level < 0:
		stop()
		levels[level] = [name]
		active_level = level
		if not muted:
			play(name)
		return
	if not (levels[level] as Array).has(name):
		(levels[level] as Array).append(name)
	if level >= active_level:
		active_level = level
		if not muted:
			play(name)

## PopBGM: every level, or one.
func pop(all_levels: bool, level: int = 0) -> void:
	if all_levels:
		for i in range(LEVELS):
			levels[i] = []
		active_level = -1
	else:
		levels[clampi(level, 0, LEVELS - 1)] = []
		active_level = -1
		for i in range(LEVELS - 1, -1, -1):
			if not (levels[i] as Array).is_empty():
				active_level = i
				break
	if muted:
		return
	var name := _wanted()
	if name != "":
		play(name)

## BGM mute box.
func set_muted(value: bool) -> void:
	if value == muted:
		return
	muted = value
	if muted:
		stop()
	else:
		var name := _wanted()
		if name != "":
			play(name)

## The loading screen: silence, no area, no playlist.
func enter_loading() -> void:
	stop()
	zone_bgm = ""
	for i in range(LEVELS):
		levels[i] = []
	active_level = -1

## What should be playing: the active level's entry, else the zone's.
func _wanted() -> String:
	if active_level >= 0 and not (levels[active_level] as Array).is_empty():
		return levels[active_level][0]
	return zone_bgm

func _start() -> void:
	state = State.PLAYING
	sounding = track
	_step = 0
	_clock = 0.0
	commands.append(["start", track])
