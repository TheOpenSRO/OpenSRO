class_name RetailCamera
extends RefCounted

## The original's third-person game camera (round 778): how far it can look
## up and down, how the wheel zooms, where it looks on the character, how it
## keeps out of the ground and the scenery, and how the player's own model
## fades away when the camera looks up steeply. Everything below is READ from
## the client (/opt/sro-files/client/sro_client.exe on the render box: the
## decompile in /var/tmp/decomp_client and objdump of the same bytes) unless
## it says otherwise; docs/WORLD_ISSUES.md "Round 778 (part): the camera" has
## the addresses in one place.
##
## Where the state lives in retail. The game camera is the object at
## 0x110f7d0 with a CGFXVideo3d at +0x33c, so its look-at point is +0x34c,
## its pitch +0x370, its yaw +0x374 and its distance +0x37c (the
## CGFXVideo3d's +0x10/+0x34/+0x38/+0x40, round 761's portrait read). The
## interface (CGInterface, 0x110f80c) keeps the zoom: +0x3e8 the distance the
## player asked for, +0x3ec the distance in force, +0x3f8 the distance the
## collision ray left (+0x3f4 set while it does).
##
## The eye. CGFXVideo3d's FUN_00bae580 builds R = RotZ(roll) RotX(pitch)
## RotY(yaw) and puts the eye at `target - (0, 0, d) R` (round 761), so in the
## game's coordinates the eye is target + d (-cos p sin y, sin p, -cos p cos y):
## a POSITIVE retail pitch puts the eye ABOVE the target (looking down), a
## negative one below it (looking up). This client's CameraArm pitch is the
## negative of that (a negative arm pitch lifts the camera, World3D's
## CAMERA_PITCH_* note) and its yaw is the retail yaw + pi; the drag signs
## below are the retail ones carried through that (DERIVED: the arm's offset
## is d (cos a sin w, -sin a, cos a cos w) for arm pitch a and yaw w, which is
## the retail offset with a = -p and w = y + pi).

## The pitch's limit either way, radians: the float at 0xdb8d70 (+1.0708, the
## clamp from above in CGInterface::vslot_017's WM_MOUSEMOVE, 0x77c363) and
## the float at 0xdb8d64 (-1.0708, the clamp from below). 61.35 degrees: the
## camera looks DOWN at most 61.35 degrees and UP at most 61.35 degrees.
const PITCH_LIMIT := 1.0707963705062866
const PITCH_LIMIT_DEGREES := 61.35211274793701
## Radians of pitch and of yaw per pixel the mouse moves with the right button
## held: the double at 0xd986e8 (0.005, `fmul qword [0xd986e8]` at 0x77c351).
## pitch -= (old_y - new_y) x 0.005 and yaw -= (old_x - new_x) x 0.005.
const DRAG_RADIANS_PER_PIXEL := 0.005
const DRAG_DEGREES_PER_PIXEL := 0.2864788975654116
## The zoom's range, world units: the float at 0xd81a88 (10.0, the floor
## every wheel step clamps to) and the float at 0xdb8d74 (150.0, the ceiling,
## applied while the interface's byte +0x3cf is set -- 1 from its constructor
## CGInterface::FUN_0078d050, toggled only by a developer console command at
## 0x53a970).
const ZOOM_MIN := 10.0
const ZOOM_MAX := 150.0
## One wheel notch: CGInterface::vslot_036 (WM_MOUSEWHEEL, reached from
## CGWndBase::vslot_017's `cmp esi, 0x20a` with the high word of wParam) does
## distance -= delta / 20.0 (the double at 0xe1b830). Windows' notch is
## WHEEL_DELTA = 120, so 6 units a notch; a notch forward zooms in. The new
## distance is both the one asked for and the one in force (+0x3e8 = +0x3ec),
## and it applies at once: there is no zoom smoothing anywhere in the camera.
const WHEEL_DIVISOR := 20.0
const WHEEL_DELTA := 120.0
const ZOOM_STEP := WHEEL_DELTA / WHEEL_DIVISOR

## Looking up pulls the camera in (UI_SILKMALL::FUN_0078dc50, the per-frame
## camera placer, 0x78dd21..0x78ddc3). While the retail pitch is below 0 the
## distance in force may not exceed
##   40 + 110 x (1 - sin(1.5707963 x (-pitch) / 0.9))
## (doubles 0xe1b8f8 = 40, 0xdb97f8 = 110, 0xd83a98 = 0.9, 0xe1b8f0 =
## 1.5707963; FUN_00b44b40 is `fsin`): 150 looking level, 62.9 at 30 degrees
## up, 40 at 51.57 degrees, 44.8 at the 61.35 limit.
const LOOK_UP_NEAR := 40.0
const LOOK_UP_SPAN := 110.0
const LOOK_UP_PITCH := 0.9
const HALF_PI_READ := 1.5707963705062866

## The look-at point (FUN_0078dc50, 0x78ddc9..0x78de58), for a character on
## foot: right above the player's feet, at
##   14.2 + (d - 150) x (14.2 - (h - 3.8)) / 140
## over them (doubles 0xd83068 = 14.2, 0xd83060 = 140, 0xd83058 = 150,
## 0xd83078 = 3.8), d the distance in force (the collided one while the ray
## is cut short) and h the player's +0x228 (FUN_009c7730). So 14.2 at 150
## and h - 3.8 at d = 10. Mounted it is 0.25 x h over (mount y + mount h - 13)
## instead (0xd83070 = 0.25, 0xdb9808 = 13) -- this client has no mounts, so
## that branch is recorded, not built. A camera shake adds +0x418/+0x41c
## (CGInterface::vslot_005's timer; not built).
const TARGET_HEIGHT_FAR := 14.2
const TARGET_SPAN := 140.0
const TARGET_FAR := 150.0
const TARGET_NEAR_DROP := 3.8
## A character's +0x228: `20.0 x size x scale` (slot 28 FUN_009c7780: the
## double at 0xe1b830 times FUN_009c7740 = [+0x728]+8 x [+0xc4]), where
## [+0x728]+8 is the third column of textdata\skilleffect.txt's
## `characterInfo` section times 0.5 (UI_ALCHEMYBOX::FUN_00a9ae80, the double
## at 0xe1b7d0). MEASURED (Media.pk2): all 52 CHAR_CH_* / CHAR_EU_* rows have
## size 2, so h = 20 for every player. INFERRED: +0xc4 is the object's scale,
## 1.0 from FUN_009c4860 and changed only by FUN_009c4510 (no normal player
## is rescaled); the character creator's height/volume byte scales bones,
## not this.
const PLAYER_SIZE_HEIGHT := 20.0

## The collision ray (UI_SILKMALL::FUN_0078def0, run after the placer while
## the interface's byte +0x3cc is set -- 1 from the constructor, 0x78df10):
## from 5 units out along the eye's direction to the full distance, through
## SWorld::vslot_030 (the same nearest-hit test as the ground pick: terrain
## cells and the objects' own meshes of the blocks drawn). On a hit the
## camera sits at |hit - target| - 5 (the double at 0xd81950, both ends).
const COLLISION_SKIP := 5.0

## The own character fades when the camera looks up steeply. Each mouse move
## that turns the camera calls `FUN_009d54c0(pitch < -0.9)` on the player
## (0x77c39e, 0x7790ed; the double at 0xdb8d68), which starts a ramp of the
## player's alpha (+0x2068) from where it is to 0 (true) or 255 (false);
## CICPlayer::vslot_009 steps it (FUN_009d4e80: t += 2.0 x dt, the float at
## 0xd86ecc set by the constructor at 0x9da6d0; alpha = start + t x delta,
## truncated; t >= 1 gives the target) and hands it to the model's compound
## (vtable slot 5, the alpha the appear fade sets, AppearFade). So past 51.57
## degrees up the character fades out in 0.5 s, and fades back in 0.5 s when
## the camera comes down. Only the player's own model: monsters, NPCs, other
## players and effects keep theirs (the setter's three callers all pass the
## player, [0xeef5ec]). There is NO distance test: a camera zoomed to 10 units
## from above does not fade the character; looking up is what brings the
## camera that close (LOOK_UP_*) and what fades it.
const FADE_PITCH := -0.9
const FADE_RATE := 2.0

## Which view turns what (the interface's +0x3e4, F9's cycle 0x780590):
## view 0 (free) -- the drag turns pitch and yaw; view 1 (third person) --
## the placer sets the yaw every frame to (1.57 - heading) + 1.5707963 (the
## doubles 0xdb9800, 0xe1b8f0), straight behind the character with no easing,
## and the drag still turns the pitch; view 2 (quarter) -- the drag turns the
## yaw only and the pitch stays where it was (nothing writes a quarter pitch:
## FUN_00780590 / 0x780420 only change the view and announce it). No key turns
## the camera: the arrow keys run and turn the character (FUN_0077b070) and the
## arrow/WASD camera of FUN_0078e0e0 is the developer free camera (+0x3ce,
## set only by console commands).

## The retail pitch after a mouse move of `dy` pixels down (new y - old y),
## clamped: moving the mouse down raises the camera (looks down more).
static func drag_pitch(pitch: float, dy: float) -> float:
	return clampf(pitch + dy * DRAG_RADIANS_PER_PIXEL, -PITCH_LIMIT, PITCH_LIMIT)

## The distance after `notches` wheel notches (positive: forward, zoom in),
## from the distance in force.
static func wheel(distance: float, notches: float) -> float:
	return clampf(distance - notches * WHEEL_DELTA / WHEEL_DIVISOR, ZOOM_MIN, ZOOM_MAX)

## The farthest the camera may be at retail pitch `pitch` (no limit at or
## above level).
static func look_up_max(pitch: float) -> float:
	if pitch >= 0.0:
		return INF
	return LOOK_UP_NEAR + LOOK_UP_SPAN * (1.0 - sin(HALF_PI_READ * (-pitch) / LOOK_UP_PITCH))

## The distance in force after a frame of the placer, from the one in force
## `current` and the one asked for `wanted`: below level it is pulled to the
## look-up limit (each branch as 0x78dd7b..0x78ddc3 takes it); at or above
## level it goes back out to the one asked for.
static func settle(current: float, wanted: float, pitch: float) -> float:
	if pitch < 0.0:
		var m := look_up_max(pitch)
		if current >= m or wanted >= m:
			return m
		return wanted
	if wanted > current:
		return wanted
	return current

## The look-at point's height over the feet of a character on foot, for
## distance `d` and the character's `h`.
static func target_height(d: float, h: float = PLAYER_SIZE_HEIGHT) -> float:
	return TARGET_HEIGHT_FAR + (d - TARGET_FAR) * (TARGET_HEIGHT_FAR - (h - TARGET_NEAR_DROP)) / TARGET_SPAN

## The camera's distance when the ray from COLLISION_SKIP out hits something
## `hit` units from the target.
static func collided(hit: float) -> float:
	return hit - COLLISION_SKIP

## Whether the own model fades out at retail pitch `pitch`.
static func fades(pitch: float) -> bool:
	return pitch < FADE_PITCH

## The retail pitch of a CameraArm pitch in degrees, and back.
static func retail_pitch(arm_pitch_degrees: float) -> float:
	return -deg_to_rad(arm_pitch_degrees)

static func arm_pitch_degrees(pitch: float) -> float:
	return -rad_to_deg(pitch)

## The player's alpha ramp (+0x2068..+0x2084): set() is FUN_009d54c0, step()
## FUN_009d4e80 as CICPlayer::vslot_009 runs it.
class Ramp:
	var alpha := 255
	var start := 255
	var target := 255
	var delta := 0
	var done := true
	var t := 1.0
	var hidden := false

	## FUN_009d54c0: only a change starts a ramp, from the alpha now.
	func set_hidden(on: bool) -> void:
		if on == hidden:
			return
		hidden = on
		t = 0.0
		done = false
		start = alpha
		target = 0 if on else 255
		delta = target - start

	## FUN_009d4e80: one frame of `dt` seconds. Returns the alpha.
	func step(dt: float) -> int:
		if done:
			return alpha
		t += FADE_RATE * dt
		if t >= 1.0:
			alpha = target
			t = 1.0
			done = true
			return alpha
		# `fimul` delta, `fiadd` start, then FUN_00b42d10 (the CRT's
		# float-to-int, which truncates; INFERRED from its use as _ftol):
		# the sum is never negative, so int() matches.
		alpha = int(float(start) + t * float(delta))
		return alpha

## Draws the ramp on a model: every mesh under it (AppearFade.instances_of --
## effects excluded) on its material's blended fade twin at the ramp's alpha
## while it is below 255, its own material back at 255. OURS: the same twins
## the appear fade draws with (AppearFade.fade_twin), kept per source
## material while the fade lasts. A mesh another fade holds (its meta set) is
## left to that fade.
class ModelFade:
	var model: Node = null
	## [MeshInstance3D, surface (-1: material_override), original, twin]
	var meshes: Array = []
	var twins := {}
	var alpha := 255

	func apply(node: Node, a: int) -> void:
		if node != model:
			release()
			model = node
		if model == null or not is_instance_valid(model):
			model = null
			return
		if a >= 255:
			release()
			model = node
			return
		if meshes.is_empty():
			_take()
		if a != alpha:
			alpha = a
			var f := float(a) / 255.0
			for twin in twins.values():
				if twin != null:
					AppearFade.set_twin_alpha(twin, f)

	func _take() -> void:
		var f := float(alpha) / 255.0
		for mi in AppearFade.instances_of(model):
			if mi.has_meta(AppearFade.ORIGINAL_META):
				continue
			if mi.material_override != null:
				_take_one(mi, -1, mi.material_override, f)
			elif mi.mesh != null:
				for s in range(mi.mesh.get_surface_count()):
					var src := mi.get_active_material(s)
					if src != null:
						_take_one(mi, s, src, f)

	func _take_one(mi: MeshInstance3D, surface: int, src: Material, f: float) -> void:
		var id := src.get_instance_id()
		if not twins.has(id):
			var made := AppearFade.fade_twin(src)
			if made != null:
				AppearFade.set_twin_alpha(made, f)
			twins[id] = made
		var twin: Material = twins[id]
		if twin == null:
			return
		var original: Material = src if surface < 0 else mi.get_surface_override_material(surface)
		if surface < 0:
			mi.set_meta(AppearFade.ORIGINAL_META, original)
			mi.material_override = twin
		else:
			mi.set_surface_override_material(surface, twin)
		meshes.append([mi, surface, original, twin])

	## Every mesh gets its own material back (one something else replaced
	## meanwhile keeps what it has now, as AppearFade's restore does).
	func release() -> void:
		for m in meshes:
			var mi = m[0]
			if mi == null or not is_instance_valid(mi):
				continue
			var surface: int = m[1]
			if surface < 0:
				if (mi as MeshInstance3D).material_override == m[3]:
					(mi as MeshInstance3D).material_override = (mi as Node).get_meta(AppearFade.ORIGINAL_META, m[2])
				(mi as Node).remove_meta(AppearFade.ORIGINAL_META)
			elif (mi as MeshInstance3D).get_surface_override_material(surface) == m[3]:
				(mi as MeshInstance3D).set_surface_override_material(surface, m[2])
		meshes.clear()
		twins.clear()
		alpha = 255
		model = null
