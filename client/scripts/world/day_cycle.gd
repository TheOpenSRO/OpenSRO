extends RefCounted
class_name DayCycle

## The world's time of day (round 786): the environment record's graphs read
## at the day phase, eased toward as retail eases them, and the sun's and the
## moon's places in the sky. World3D owns one, feeds it the phase every frame
## (GameClock.phase in the world, the title's hour on the front end) and
## writes what it returns into the sky, the lights, the fog, the water, the
## clouds and the terrain.
##
## READ (sro_client.exe; docs/protocol/ENVIRONMENT_FORMAT.md, "The day phase"):
## - `Map::FUN_00a1baf0` (every frame, from SWorld::vslot_004) samples the
##   current block's record at SWorld's phase (+0x26a3): the ColorGraphs at
##   record +0x88, +0xbc, +0xf0, +0x124, +0x158, +0x18c, +0x1c0, +0x2b4,
##   +0x1f4, +0x228 (channels 0-6, 9, 13, 14) and the FloatGraphs at +0x25c,
##   +0x288, +0x2e8, +0x314, +0x340, +0x36c (7, 8, 10, 11, 12, 15), through
##   EnvironmentReader's spline.
## - Each lands in a world field: 0 +0x682f, 1 +0x683b, 2 +0x6847, 3 +0x6853,
##   4 +0x685f, 5 +0x686b, 6 +0x6883, 9 +0x68a3, 13 +0x6877, 14 +0x688f; 10
##   and 11 times the view distance +0x68af / +0x68b3; (12 + 1) / 2 +0x68c7.
## - With world +0x2f38 set (the constructor sets it, param_1[0xbce] = 1) and
##   the snap flag +0x238c clear, every field moves toward its new value by
##   f = dt x 0.5 (0xe1b7d0), f at most 1 (0xa1c1d5..): field += (new -
##   field) x f -- a 2 s time constant. With +0x238c set (the constructor
##   sets it; one frame) the fields take the new values at once and the flag
##   is cleared. Then every colour field and +0x68c7 is clamped to [0, 1]
##   (0xa1ca22..0xa1cf..).
## - SWorld::vslot_004 (0xa2d1cb..0xa2d241): the sun at (cos a, sin a, 0) x
##   20000 (0xde4d88) with a = (phase - 0.25) x 2 pi (0xd83070, 0xd81930) --
##   `0xb44a10` is cos (fcos at 0xb44a7d), `0xb44b40` sin (fsin at 0xb44bad):
##   it rises at +x at 6:00, stands overhead at noon, sets at -x at 18:00.
## - The sun disc (`Map::FUN_00a207a0`, from the sky step `Map::FUN_00a26f60`
##   0xa2727d): drawn for 0.25 <= phase <= 0.875 (0xd9a2b8, 0xde4d90), a quad
##   facing the eye at the sun's place, half-size 666.67 (0xde4d70), its alpha
##   `sun\lens2.ddj`'s (stage 0 ALPHAOP SELECTARG1 TEXTURE) and its colour the
##   texture factor -- channel 0, SunColor, x 255 (COLOROP SELECTARG1 TFACTOR,
##   0xa20953..0xa209fa) -- alpha-blended, Z off, before the clouds.
## - The moon (`Map::FUN_00a20d60`, 0xa27284, after the sun): drawn while the
##   clock's day (SWorld +0x6778) is below 29 and phase < 0.5 or phase > 0.75
##   (0xe1b7e0, 0xdd8eec); at angle ((frac(phase - 0.75) - 0.25) x 1.2 + 0.25)
##   x 2 pi (0xda34b0, 0xe1b7f0, 0xd83070, 0xde4d98, 0xd81930), 20000 away,
##   half-size 1000 (0xd83268), `sun\moon%02d.ddj` of day + 1 (the textures
##   at world +0x299b, loaded 1..30 by `Map::FUN_00a0d1b0`), the texture's own
##   colour and alpha (SELECTARG1 TEXTURE), alpha-blended.
## - Night (SWorld::vslot_004 0xa2d1ae, FUN_00bbdbf0 -> 0x1112fb0 +0x1a8):
##   the shifted phase (phase - 0.25, or + 0.75 below 0.25) above 0.5 --
##   18:00 to 6:00.
## - Neither the sun nor the moon is drawn in a dungeon (FUN_009fb1f0: region
##   id bit 0x8000).

## READ: the easing rate (0xe1b7d0).
const EASE_PER_SECOND := 0.5
## READ: the sun and moon distance and the half-sizes of their quads.
const BODY_DISTANCE := 20000.0
const SUN_HALF_SIZE := 666.6666870117188
const MOON_HALF_SIZE := 1000.0
## READ: the moon is drawn while the clock's day is below this.
const MOON_DAYS := 29
## READ: the sun disc's phase window.
const SUN_FROM := 0.25
const SUN_TO := 0.875

## What the step produces (display values, clamped as retail clamps them).
class State:
	var sun := Color(1, 1, 1)          ## channel 0
	var sky_top := Color(1, 1, 1)      ## channel 1
	var diffuse := Color(1, 1, 1)      ## channel 2
	var object_ambient := Color(1, 1, 1) ## channel 3
	var cloud := Color(1, 1, 1)        ## channel 4
	var terrain_ambient := Color(1, 1, 1) ## channel 5
	var terrain_shadow := Color(0, 0, 0) ## channel 6
	var fog := Color(1, 1, 1)          ## channel 9 (the raw channel; render_fog_color roots it)
	var sky_bottom := Color(1, 1, 1)   ## channel 13
	var water := Color(1, 1, 1)        ## channel 14
	var fog_near := 0.0                ## channel 10, a fraction of the view distance
	var fog_far := 1.0                 ## channel 11
	var cloud_alpha := 0.6             ## (channel 12 + 1) / 2, clamped
	func copy() -> State:
		var s := State.new()
		s.sun = sun; s.sky_top = sky_top; s.diffuse = diffuse; s.object_ambient = object_ambient
		s.cloud = cloud; s.terrain_ambient = terrain_ambient; s.terrain_shadow = terrain_shadow
		s.fog = fog; s.sky_bottom = sky_bottom; s.water = water
		s.fog_near = fog_near; s.fog_far = fog_far; s.cloud_alpha = cloud_alpha
		return s

const COLOR_FIELDS := ["sun", "sky_top", "diffuse", "object_ambient", "cloud", "terrain_ambient",
	"terrain_shadow", "fog", "sky_bottom", "water"]
const COLOR_CHANNELS := [0, 1, 2, 3, 4, 5, 6, 9, 13, 14]

## The record the cycle reads (the camera's block's, as retail's +0x7b28).
var record: EnvironmentReader.Record = null
## The eased values (null before the first step).
var state: State = null
## The next step takes its values at once (retail's +0x238c).
var _snap := true

## The next step snaps instead of easing (world built, zone changed).
func snap() -> void:
	_snap = true

func set_record(rec: EnvironmentReader.Record) -> void:
	record = rec

## The record's values at phase, unclamped, as the graphs give them.
static func targets(rec: EnvironmentReader.Record, phase: float) -> State:
	var s := State.new()
	for i in range(COLOR_FIELDS.size()):
		s.set(COLOR_FIELDS[i], EnvironmentReader.sample_color_channel(rec, COLOR_CHANNELS[i], phase))
	s.fog_near = EnvironmentReader.sample_float_channel(rec, EnvironmentReader.CHANNEL_FOG_NEAR_PLANE, phase)
	s.fog_far = EnvironmentReader.sample_float_channel(rec, EnvironmentReader.CHANNEL_FOG_FAR_PLANE, phase)
	s.cloud_alpha = (EnvironmentReader.sample_float_channel(rec, 12, phase) + 1.0) * 0.5
	return s

static func _clamp01(c: Color) -> Color:
	return Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0), clampf(c.b, 0.0, 1.0), 1.0)

## The targets last sampled (step's `resample`).
var _targets: State = null
var _targets_record: EnvironmentReader.Record = null

## One frame: the record at phase, eased from the last values by dt (READ),
## clamped. Returns the state (also kept in `state`), or null with no record.
## `resample` false eases toward the targets last sampled (OURS: World3D
## samples the graphs ten times a second -- the phase moves 0.0006 in that
## time -- and eases every frame).
func step(phase: float, dt: float, resample: bool = true) -> State:
	if record == null:
		return null
	if resample or _targets == null or _targets_record != record or _snap:
		_targets = targets(record, phase)
		_targets_record = record
	var t := _targets
	if state == null or _snap:
		state = t.copy()
		_snap = false
	else:
		var f := minf(dt * EASE_PER_SECOND, 1.0)
		for field in COLOR_FIELDS:
			var cur: Color = state.get(field)
			state.set(field, cur + ((t.get(field) as Color) - cur) * f)
		state.fog_near += (t.fog_near - state.fog_near) * f
		state.fog_far += (t.fog_far - state.fog_far) * f
		state.cloud_alpha += (t.cloud_alpha - state.cloud_alpha) * f
	for field in COLOR_FIELDS:
		state.set(field, _clamp01(state.get(field)))
	state.cloud_alpha = clampf(state.cloud_alpha, 0.0, 1.0)
	return state

## The sun's direction from the eye (READ): (cos a, sin a, 0), a = (phase -
## 0.25) x 2 pi. The world's z mirror leaves it as it is.
static func sun_direction(phase: float) -> Vector3:
	var a := (phase - 0.25) * TAU
	return Vector3(cos(a), sin(a), 0.0)

static func sun_disc_drawn(phase: float) -> bool:
	return phase >= SUN_FROM and phase <= SUN_TO

## The moon's angle (READ, 0xa20d9e..0xa20ded).
static func moon_angle(phase: float) -> float:
	var m := phase - 0.75
	if m < 0.0:
		m += 1.0
	return ((m - 0.25) * 1.2 + 0.25) * TAU

static func moon_direction(phase: float) -> Vector3:
	var a := moon_angle(phase)
	return Vector3(cos(a), sin(a), 0.0)

static func moon_drawn(phase: float, day: int) -> bool:
	return day < MOON_DAYS and (phase < 0.5 or phase > 0.75)

## The moon's picture for the clock's day: `sun\moon%02d.ddj` % (day + 1).
static func moon_texture(day: int) -> String:
	return "Sun\\moon%02d.ddj" % (clampi(day, 0, MOON_DAYS - 1) + 1)

## The quad's "up" axis for a body at angle a (READ: the corner table at
## 0xec554c rotated about z by a): (-sin a, cos a, 0).
static func body_axis(direction: Vector3) -> Vector3:
	return Vector3(-direction.y, direction.x, 0.0)

## Night by the sky's phase (READ, 0xa2d1ae): 18:00 to 6:00.
static func is_night(phase: float) -> bool:
	var shifted := phase - 0.25 if phase >= 0.25 else phase + 0.75
	return shifted > 0.5
