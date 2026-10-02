extends RefCounted
class_name IntroCameraPath

## The title camera's path: what the client does with an intro script's
## keyframes each frame. Everything here is READ from the client (round 678;
## docs/protocol/intro_script.md has the addresses in full):
##
## - The path object (ctor 0x4e6c40) holds five curves: the position (a
##   vec3 curve at +0x4, keys {x, y, z, t}, interpolator 0x4e0920) and four
##   scalar curves at +0x38, +0x64, +0x90, +0xbc (keys {v, t}, interpolator
##   0x4df7d0) -- pitch, yaw, roll and distance, in keyframe order
##   (FUN_004e67b0 adds a keyframe's four rotation values to them in that
##   order; FUN_004e5bf0 reads them back into path +0x104..+0x110, which
##   CPSTitle::vslot_012 copies to the camera's +0x370..+0x37c).
## - Keys are inserted sorted by time, a key equal in time going after the
##   ones already there (FUN_004e6040 / FUN_004e6170: insert before the
##   first key with key.t - t > 0).
## - Sampling at t (FUN_004e55e0, FUN_004e5770): the first key k with
##   t <= key[k].t; k == 0 gives key 0; no such key gives the last key;
##   otherwise segment i = k - 1 at u = (t - t_i) / (t_k - t_i), u = 0 when
##   that span is <= 1e-4 (the double at 0xe1b880).
## - Segment i of n keys (FUN_004e4530, FUN_004e4770): p0 = key[i-1] (key 0
##   when i == 0), p1 = key[i], p2 = key[i+1], p3 = key[i+2] (key[i+1] when
##   i == n-2); i < 0 gives key 0, i >= n-1 the last key.
## - Both interpolators are the uniform Catmull-Rom spline,
##   0.5 * (2 p1 + (p2 - p0) u + (2 p0 - 5 p1 + 4 p2 - p3) u^2
##          + (-p0 + 3 p1 - 3 p2 + p3) u^3),
##   with the constants 2.0, 5.0, 4.0, 3.0 and 0.5 at 0xe1b898, 0xd81950,
##   0xe1b860, 0xe1b808 and 0xe1b7d0.
## - The three angle curves (+0x38, +0x64, +0x90 -- not the distance) carry
##   a fix-up callback (0x4deee0, set at 0x4e6cea..0x4e6cf0) run on COPIES of
##   the four points before interpolating: for each consecutive pair (a, b),
##   d = b - a; if d > pi, b -= 2 pi while b > a; if d < -pi, b += 2 pi while
##   b < a (pi and 2 pi are the doubles at 0xd81948 and 0xd81930). The stored
##   keys are not changed.
## - Playing (FUN_004e5bf0): time += dt; past the length it either wraps
##   (path +0xec set) or CLAMPS to the length -- the title never sets +0xec
##   (FUN_004e6630 clears it), so it clamps and the camera rests on the last
##   keyframe. The length is the last keyframe's time in file order
##   (FUN_00869b50).
## - Before the first frame the camera stands on the last keyframe
##   (CPSTitle::OnCreate, FUN_0056be40 at 0x86bda0); CPSTitle::vslot_012
##   only advances the path while its length is non-zero.

const ANGLE_PI := 3.1415927410125732 # READ: the double at 0xd81948
const ANGLE_TWO_PI := 6.2831854820251465 # READ: the double at 0xd81930
const SPAN_EPSILON := 9.999999747378752e-05 # READ: the double at 0xe1b880

## One sampled pose: the camera's look-at target in the path's region frame
## (region-local, SRO axes), and pitch / yaw / roll / distance.
class Pose:
	var target := Vector3.ZERO
	var pitch: float = 0.0
	var yaw: float = 0.0
	var roll: float = 0.0
	var distance: float = 0.0

var _times := PackedFloat32Array()
var _pos: Array[Vector3] = []
var _pitch := PackedFloat32Array()
var _yaw := PackedFloat32Array()
var _roll := PackedFloat32Array()
var _dist := PackedFloat32Array()

## The path's length: the last keyframe's time in file order (READ).
var length: float = 0.0
## The playing clock (path +0xe8).
var time: float = 0.0
## Never set at the title (READ); kept for completeness and tests.
var loop: bool = false
var _start_pose: Pose = null

## At most IntroScript.MAX_KEYFRAMES keys are taken (_insert is a sorted
## insert, quadratic in the count).
static func from_keyframes(keyframes: Array) -> IntroCameraPath:
	var p := IntroCameraPath.new()
	if keyframes.size() > IntroScript.MAX_KEYFRAMES:
		keyframes = keyframes.slice(0, IntroScript.MAX_KEYFRAMES)
	for kf in keyframes:
		p._insert(kf.time, kf.pos, kf.pitch, kf.yaw, kf.roll, kf.distance)
		p.length = kf.time
	if not keyframes.is_empty():
		var last = keyframes[keyframes.size() - 1]
		p._start_pose = Pose.new()
		p._start_pose.target = last.pos
		p._start_pose.pitch = last.pitch
		p._start_pose.yaw = last.yaw
		p._start_pose.roll = last.roll
		p._start_pose.distance = last.distance
	return p

func key_count() -> int:
	return _times.size()

## Where the camera stands before the path's first frame: the last keyframe.
func start_pose() -> Pose:
	return _start_pose

## Whether the clock has reached the end (CPSTitle::vslot_012's test that
## fades the login window in: path time == path length -- true at once for
## a path of length 0, which the title never advances).
func finished() -> bool:
	return time == length

## FUN_004e5bf0's clock: advance, then wrap or clamp. Returns the pose.
func advance(dt: float) -> Pose:
	time += dt
	if length < time:
		if not loop:
			time = length
		else:
			while length < time:
				time -= length
	return sample(time)

func sample(t: float) -> Pose:
	return _pose_at(_locate(t))

## The same pose as sample(t), for a caller that walks the path forward
## (round 680's review, TitleCellPlan): the key search resumes where the last
## call left it instead of starting at key 0, so a whole walk costs O(samples
## + keys), not O(samples x keys). A t below the last one starts over.
func sample_forward(t: float) -> Pose:
	if t < _scan_t:
		_scan_k = 0
	_scan_t = t
	var n := _times.size()
	while _scan_k < n and not (t <= _times[_scan_k]):
		_scan_k += 1
	return _pose_at(_at_from(t, _scan_k))

var _scan_k := 0
var _scan_t := -INF

func _pose_at(at: Array) -> Pose:
	var pose := Pose.new()
	pose.target = _sample_vec3(at)
	pose.pitch = _sample_scalar(_pitch, at, true)
	pose.yaw = _sample_scalar(_yaw, at, true)
	pose.roll = _sample_scalar(_roll, at, true)
	pose.distance = _sample_scalar(_dist, at, false)
	return pose

func _insert(t: float, pos: Vector3, pitch: float, yaw: float, roll: float, dist: float) -> void:
	var at := _times.size()
	for i in range(_times.size()):
		if 0.0 < _times[i] - t:
			at = i
			break
	_times.insert(at, t)
	_pos.insert(at, pos)
	_pitch.insert(at, pitch)
	_yaw.insert(at, yaw)
	_roll.insert(at, roll)
	_dist.insert(at, dist)

## [segment index, u], or [-2, 0] for "the last key" and [-1, 0] for key 0.
func _locate(t: float) -> Array:
	var n := _times.size()
	for k in range(n):
		if t <= _times[k]:
			return _at_from(t, k)
	return [-2, 0.0]

## _locate's answer once k -- the first key with t <= its time, or the key
## count for none -- is known.
func _at_from(t: float, k: int) -> Array:
	if k >= _times.size():
		return [-2, 0.0]
	if k == 0:
		return [-1, 0.0]
	var span := _times[k] - _times[k - 1]
	var u := 0.0 if span <= SPAN_EPSILON else (t - _times[k - 1]) / span
	return [k - 1, u]

func _sample_vec3(at: Array) -> Vector3:
	var n := _pos.size()
	if n == 0:
		return Vector3.ZERO
	var i: int = at[0]
	if i == -1:
		return _pos[0]
	if i == -2 or i >= n - 1:
		return _pos[n - 1]
	var p0: Vector3 = _pos[i - 1] if i > 0 else _pos[0]
	var p3: Vector3 = _pos[i + 1] if i == n - 2 else _pos[i + 2]
	return catmull_rom_vec3(p0, _pos[i], _pos[i + 1], p3, at[1])

func _sample_scalar(keys: PackedFloat32Array, at: Array, angle: bool) -> float:
	var n := keys.size()
	if n == 0:
		return 0.0
	var i: int = at[0]
	if i == -1:
		return keys[0]
	if i == -2 or i >= n - 1:
		return keys[n - 1]
	var p := [keys[i - 1] if i > 0 else keys[0], keys[i], keys[i + 1],
		keys[i + 1] if i == n - 2 else keys[i + 2]]
	if angle:
		unwrap_angles(p)
	return catmull_rom(p[0], p[1], p[2], p[3], at[1])

## READ 0x4deee0 (see the header): each point made continuous with the one
## before it, in order, on a copy. Retail loops `b -= 2 pi` while b > a (and
## `b += 2 pi` while b < a); the same count of steps is computed here, k =
## ceil(|b - a| / 2 pi), so a huge value cannot spin for ever (round 678's
## review -- above ~1e17, b - 2 pi == b and the loop never ends). The two
## agree to float rounding on any value a script could fly (IntroScript's
## bounds); a non-finite value is left as it is.
static func unwrap_angles(p: Array) -> void:
	for j in range(1, p.size()):
		var a: float = p[j - 1]
		var b: float = p[j]
		if is_nan(a) or is_inf(a) or is_nan(b) or is_inf(b):
			continue
		var d := b - a
		if d > ANGLE_PI:
			b -= ceilf(d / ANGLE_TWO_PI) * ANGLE_TWO_PI
		elif d < -ANGLE_PI:
			b += ceilf(-d / ANGLE_TWO_PI) * ANGLE_TWO_PI
		p[j] = b

static func catmull_rom(p0: float, p1: float, p2: float, p3: float, u: float) -> float:
	var u2 := u * u
	var u3 := u2 * u
	return 0.5 * (2.0 * p1 + (p2 - p0) * u + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u2 \
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * u3)

static func catmull_rom_vec3(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: float) -> Vector3:
	return Vector3(catmull_rom(p0.x, p1.x, p2.x, p3.x, u), catmull_rom(p0.y, p1.y, p2.y, p3.y, u),
		catmull_rom(p0.z, p1.z, p2.z, p3.z, u))

# --- The camera ---------------------------------------------------------------

## The vertical field of view, degrees: READ, the camera's +0x50 is set to
## 60.0 (the float at 0xd89ddc) in its constructor FUN_00bae0a0 and
## CGFXVideo3d::FUN_00bae810 builds the projection with it times pi/180
## (0xe1b8d8). That it is the VERTICAL angle is INFERRED from the D3DX
## PerspectiveFov convention its argument order matches.
const FOV_Y_DEGREES := 60.0

## The eye, target and up of a pose, in SRO's own (left-handed, y-up) axes.
## READ, CGFXVideo3d::FUN_00bae580 for the camera whose +0x44 flag is set
## (the main camera's constructor sets it): M = Rz(roll) * Rx(pitch) *
## Ry(yaw) (D3DXMatrixMultiply at 0xbae6f0 and 0xbae70a; the rotations are
## the d3dx RotationZ/X/Y at 0xaa449f, 0xaa434c, 0xaa4402, row vectors),
## offset = (0, 0, distance) * M (0xbae758), up = (0, 1, 0) * M (0xbae782),
## eye = target - offset (0xbae7ab..0xbae7de).
static func sro_eye_target_up(pose: Pose) -> Array:
	var m := rotation_rows(pose)
	var offset := row_times(Vector3(0.0, 0.0, pose.distance), m)
	var up := row_times(Vector3(0.0, 1.0, 0.0), m)
	return [pose.target - offset, pose.target, up]

## M = Rz(roll) * Rx(pitch) * Ry(yaw) as three row vectors (D3D convention).
static func rotation_rows(pose: Pose) -> Array:
	return mul_rows(mul_rows(_rot_z(pose.roll), _rot_x(pose.pitch)), _rot_y(pose.yaw))

## The d3dx rotations as row vectors: RotationX rows [1,0,0] [0,c,s]
## [0,-s,c]; RotationY [c,0,-s] [0,1,0] [s,0,c]; RotationZ [c,s,0] [-s,c,0]
## [0,0,1] -- READ from where each generic body stores cos and sin
## (0xaa434c, 0xaa4402, 0xaa449f).
static func _rot_x(a: float) -> Array:
	var c := cos(a)
	var s := sin(a)
	return [Vector3(1, 0, 0), Vector3(0, c, s), Vector3(0, -s, c)]

static func _rot_y(a: float) -> Array:
	var c := cos(a)
	var s := sin(a)
	return [Vector3(c, 0, -s), Vector3(0, 1, 0), Vector3(s, 0, c)]

static func _rot_z(a: float) -> Array:
	var c := cos(a)
	var s := sin(a)
	return [Vector3(c, s, 0), Vector3(-s, c, 0), Vector3(0, 0, 1)]

## v * M for a row vector v and M given as its three rows.
static func row_times(v: Vector3, m: Array) -> Vector3:
	return (m[0] as Vector3) * v.x + (m[1] as Vector3) * v.y + (m[2] as Vector3) * v.z

## A * B for row-matrices: row r of the product is row_r(A) * B.
static func mul_rows(a: Array, b: Array) -> Array:
	return [row_times(a[0], b), row_times(a[1], b), row_times(a[2], b)]

## A Godot camera transform for a pose, given how the path's region frame
## maps into the world: `to_world(v)` for SRO region-local points (the
## world's z -> -z mirror lives in it; directions are mapped by
## differencing two points).
static func camera_transform(pose: Pose, to_world: Callable) -> Transform3D:
	var etu := sro_eye_target_up(pose)
	var eye: Vector3 = to_world.call(etu[0])
	var target: Vector3 = to_world.call(etu[1])
	var up_tip: Vector3 = to_world.call(etu[1] + etu[2])
	var up := (up_tip - target).normalized()
	if eye.is_equal_approx(target):
		# A zero distance: look along the forward direction instead.
		var fwd_tip: Vector3 = to_world.call(etu[1] + _forward_sro(pose))
		return Transform3D(Basis.IDENTITY, eye).looking_at(fwd_tip, up)
	return Transform3D(Basis.IDENTITY, eye).looking_at(target, up)

static func _forward_sro(pose: Pose) -> Vector3:
	return row_times(Vector3(0.0, 0.0, 1.0), rotation_rows(pose))
