extends RefCounted
class_name NightLight

## Two OURS deviations on top of retail's day cycle (round 787; DayCycle has
## what retail does): dark nights, and shadows that follow the sun. Both are
## the user's requests ("It doesn't appear to actually get dark out"; "change
## shadow positions based off sun position ... worth deviating"), and each
## has an OURS Video row (VideoOptions.NIGHT, VideoOptions.SUN_SHADOWS).
##
## Labels: READ (sro_client.exe), MEASURED, INFERRED, OURS, OPEN.
##
## **Why retail's nights are bright (MEASURED, READ).** Retail lights the
## world with the environment record's channels at the day phase and nothing
## else: `Map::FUN_00a1baf0` builds the one D3DLIGHT9 (type 3, directional)
## from them -- Diffuse = channel 2 x 0.8 / 0.6 (world +0x68c3), Ambient =
## channel 3 x the same, halved underwater (+0x26bb) -- and its direction is
## the constant the world's constructor stores at DAT_01101944 (0xa3008b..
## 0xa3013f, never written again); the material it sets (vtable +0xc4) is
## channel 2 / channel 3 / white / channel 1. No other darkening is applied
## at night: the night flag (0x1112fb0 +0x1a8) only turns lighting OFF for
## material flag 0x8 (a lamp drawn unlit) and runs night-only particles.
## So a night is exactly as dark as the record's night keys, and those are
## mild (Jangan, environment 15: channels 2 + 3 at midnight are 62 % of noon)
## or as bright as noon (environment 23, `Env21`, around Bandit's Mountain
## Stronghold: 82 %, and the terrain's `clamp(N.L x ch2 + ch5)` saturates at
## midnight as at noon -- ch5 is (0.73, 0.78, 0.82) at 0.0 against 1.0 at
## noon). WORLD_ISSUES round 787 has the keys.
##
## **Dark nights (OURS).** As the sun sets, every light the world draws is
## scaled so that at full night the zone's light is `level` of its own noon
## light -- the same darkness in every zone, however its night keys were set:
##
##     amount = 1 - smoothstep(NIGHT_SIN, DAY_SIN, sun height)   (0 day .. 1 night)
##     full   = min(1, level x metric(noon) / metric(now))        (never brightens)
##     k      = lerp(1, full, amount)
##
## metric = luma(channel 2) + luma(channel 3), the objects' light (READ
## formula, ObjectLight). The objects' and characters' light, the terrain's
## (after its clamp: TerrainLight's `srr_terrain_night`) and the water's tint
## take k; the sky, the fog colour and the clouds take k^SKY_EXPONENT (a
## lighter hand, so the horizon keeps a glow and silhouettes stay readable;
## 0.75 chosen on the box's frames: with sqrt(k) the night sky over the
## Bandit area kept a luma of 74 over a ground of 15). The
## sun disc, the moon, the effects and the interface are not touched.
## `level` is the Night Darkness row: Original (no change -- retail's own
## values), Dim (0.5) and Dark (0.3, the default). Only the world's clock
## drives it: the front end's fixed hour and a dungeon keep retail's values.
##
## **Shadows that follow the sun (OURS).** Retail's character shadows (Shadow
## Detail = Detail) keep one fixed direction: SWorld::vslot_025 renders each
## silhouette from normalize(1, 1, 0) (0xa17b20..0xa17b34) -- the same as the
## objects' light, DAT_01109510 = normalize(-1, -1, 0), to the light. READ,
## and worth knowing: SWorld::vslot_024 (0xa18493..0xa184e2) DOES form a
## direction from the sun's place (world +0x209a, x halved) and passes it to
## the projector `Map::FUN_009f35f0`, which takes two arguments (`ret 8`) and
## never reads the second; `Map::FUN_00a1e530` stores +0x209a at 0x1112fb0
## +0x17c, whose one getter (0xbc1170) nothing calls. So the sun-following
## shadow is retail's dead code, and drawing it is ours.
## Here, under Shadow Detail = Detail (the shadow map), the shadow light's
## direction is the sun's (DayCycle.sun_direction, READ path), its height
## kept at least SHADOW_MIN_ELEVATION (so a low sun gives long shadows, not
## endless ones); as the sun nears the horizon its shadows fade out, and at
## night the moon (DayCycle.moon_direction, when it is drawn) casts fainter
## ones (MOON_SHADOW_STRENGTH); the source changes only while both are faded
## out. To keep the shadow map from swimming the target direction moves only
## in steps of SHADOW_STEP_DEG, the light glides to it (SHADOW_EASE_PER_SECOND)
## and is not touched at all once there; Godot fits a directional shadow's
## splits on a sphere and snaps them to texels (stable cascades).

## The Night Darkness row's levels (OURS): the night's light as a fraction of
## the zone's noon light; 0 is Original (no darkening).
const LEVELS := [0.0, 0.5, 0.3]
const DEFAULT_CHOICE := 2
const CHOICE_NAMES := ["Original", "Dim", "Dark"]

## The night amount by the sun's height (the y of DayCycle.sun_direction,
## the sine of its angle above the horizon). OURS: day while the sun is
## 5.7 degrees up or more, full night from 14.5 degrees below. On the sky's
## clock: night begins to fall at 17:37 and is full at 18:58 (the game
## clock's 19:29 and 20:39), and lifts from 05:02 to 06:23 (03:21, 04:30).
const DAY_SIN := 0.1
const NIGHT_SIN := -0.25

static func level(choice: int) -> float:
	return float(LEVELS[clampi(choice, 0, LEVELS.size() - 1)])

## 0 by day, 1 at full night (OURS curve on the READ sun).
static func amount(phase: float) -> float:
	var s := DayCycle.sun_direction(phase).y
	return 1.0 - smoothstep(NIGHT_SIN, DAY_SIN, s)

static func _luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

## The zone's light at an hour: luma(channel 2) + luma(channel 3).
static func light_metric(diffuse: Color, ambient: Color) -> float:
	return _luma(diffuse) + _luma(ambient)

## The record's light at noon (sky phase 0.5), clamped as the state is.
static func noon_metric(rec: EnvironmentReader.Record) -> float:
	if rec == null:
		return 0.0
	var t := DayCycle.targets(rec, 0.5)
	return light_metric(DayCycle._clamp01(t.diffuse), DayCycle._clamp01(t.object_ambient))

## The light scale k (see the header). 1 with no darkening.
static func scale(noon: float, now: float, night_amount: float, lvl: float) -> float:
	if lvl <= 0.0 or night_amount <= 0.0 or now <= 0.0 or noon <= 0.0:
		return 1.0
	var full := minf(1.0, lvl * noon / now)
	return lerpf(1.0, full, clampf(night_amount, 0.0, 1.0))

## OURS: the sky's, the fog's and the clouds' share of it, k^SKY_EXPONENT.
const SKY_EXPONENT := 0.75

static func sky_scale(k: float) -> float:
	return pow(clampf(k, 0.0, 1.0), SKY_EXPONENT)

## A colour scaled, its alpha kept.
static func scaled(c: Color, k: float) -> Color:
	return Color(c.r * k, c.g * k, c.b * k, c.a)

# --- the shadow light --------------------------------------------------------

## OURS: the lowest a shadow light stands (shadows at most 3.7 heights long).
const SHADOW_MIN_ELEVATION := 0.2617993877991494  # 15 degrees
## OURS: the target moves only in steps this large (the sun crosses it in
## about 3 s of the day, 1.6 s of the night).
const SHADOW_STEP_DEG := 0.5
## OURS: the light's glide toward a new target (a 0.5 s time constant), and
## within this angle it takes the target and stops.
const SHADOW_EASE_PER_SECOND := 2.0
const SHADOW_SETTLE_DEG := 0.02
## OURS: the sun's shadows fade out between these heights (sines: 7 and -1
## degrees), the moon's in between 0 and 9 degrees up, to this strength.
const SUN_FADE_FULL := 0.12
const SUN_FADE_NONE := -0.02
const MOON_FADE_FULL := 0.15
const MOON_SHADOW_STRENGTH := 0.5
## OURS: a strength change smaller than this is not written.
const STRENGTH_EPSILON := 1.0 / 255.0

## `to_light` with its height raised to SHADOW_MIN_ELEVATION; the bodies move
## in the x-y plane (DayCycle), so the azimuth is +x or -x.
static func clamp_elevation(to_light: Vector3) -> Vector3:
	var d := to_light.normalized()
	var e := asin(clampf(d.y, -1.0, 1.0))
	if e >= SHADOW_MIN_ELEVATION:
		return d
	var horiz := Vector3(d.x, 0.0, d.z)
	if horiz.length_squared() < 1e-8:
		horiz = Vector3(1, 0, 0)
	horiz = horiz.normalized()
	return horiz * cos(SHADOW_MIN_ELEVATION) + Vector3.UP * sin(SHADOW_MIN_ELEVATION)

## The shadow light at `phase` on the clock's `day`: [direction to the light
## (Godot's world: the bodies' z is 0, so the mirror leaves it), strength 0..1].
static func shadow_light(phase: float, day: int) -> Array:
	var sun := DayCycle.sun_direction(phase)
	var sun_k := smoothstep(SUN_FADE_NONE, SUN_FADE_FULL, sun.y)
	var moon_k := 0.0
	var moon := DayCycle.moon_direction(phase)
	if DayCycle.moon_drawn(phase, day):
		moon_k = smoothstep(0.0, MOON_FADE_FULL, moon.y) * MOON_SHADOW_STRENGTH
	if sun_k >= moon_k:
		return [clamp_elevation(sun), sun_k]
	return [clamp_elevation(moon), moon_k]

## Whether the target should move to `want` from `have` (the step rule).
static func should_retarget(have: Vector3, want: Vector3) -> bool:
	return rad_to_deg(have.angle_to(want)) >= SHADOW_STEP_DEG

## One frame of the glide: `cur` toward `target` by dt; returns [direction,
## settled]. A light at zero strength takes the target at once (a change of
## source is never seen).
static func glide(cur: Vector3, target: Vector3, dt: float, strength: float) -> Array:
	if strength <= STRENGTH_EPSILON or rad_to_deg(cur.angle_to(target)) <= SHADOW_SETTLE_DEG:
		return [target, true]
	var f := minf(dt * SHADOW_EASE_PER_SECOND, 1.0)
	var d := cur.slerp(target, f).normalized()
	if rad_to_deg(d.angle_to(target)) <= SHADOW_SETTLE_DEG:
		return [target, true]
	return [d, false]

## The light's basis for a direction to the light: -z shines along -to_light
## (DirectionalLight3D), up kept on +z (the bodies' path never meets it, so
## the shadow map's roll never flips).
static func light_basis(to_light: Vector3) -> Basis:
	return Basis.looking_at(-to_light.normalized(), Vector3.BACK)
