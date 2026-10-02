extends RefCounted
class_name CharCreateView

## The customize screen's motion (round 685): the preview model's spin, its
## camera's zoom, and the backdrop camera's slow turn. All READ from
## sro_client.exe (the per-frame `CPSCharacterCreateChina::vslot_012`
## 0x850500; Europe's 0x8542d0 is the same code), constants read out of the
## exe's bytes:
##
## **The spin** (this+0x220 the angle, +0x224 the velocity):
## - rotate left (id 21, 0x84cfb0) subtracts 50.0 (the double at 0xd8f0b0)
##   from the velocity; rotate right (22, 0x84cfd0) adds it; clicks stack;
## - each frame (0x850804..0x8508a4), dt the frame's seconds (0x110f7fc):
##   d = dt * v * 0.5 (0.5 the double at 0xe1b7d0), d = v when |v| < |d|;
##   angle += (2v - d) * dt * 0.5; v -= d; and v = 0 once |v| < 30.0 (the
##   double at 0xdd6018);
## - the model's yaw = angle / 180.0 * 3.14 (0xdd6010, 0xdd6008 -- 3.14,
##   not pi), through FUN_00a5a8c0.
## So v decays as e^(-t/2) and stops at 30: one click turns (50 - 30) / 0.5
## = 40 "degrees" over ln(5/3) / 0.5 = 1.02 s (MEASURED by the test below,
## integrating at 60 Hz).
##
## **The model and its camera** (CIFCharacterWnd, window 6, set up in
## OnCreate 0x850243..0x8504b4): the model at (3.0, 0.5, 0.0) yaw 0
## (FUN_0080bf80, 0xd8adc4 = 3.0, 0xe1b7e0 = 0.5); the window's camera
## (its object at +0x57c, the CGFXVideo3d layout) looking at (0.5, 9.8, 0.0)
## (+0x58c..; 0xe1b7e0, 0xdd5f8c) at pitch 0.2 (+0x5b0, 0xda95f8), yaw 0,
## roll 0, distance 28.5 (+0x5bc, 0xdd5f88), vertical field of view 45.0
## (+0x5cc = camera +0x50, 0xdd5f74; the constructor 0xbae0a0 had set 60).
##
## **The zoom** (id 23, 0x84fa90): toggles +0x228 and swaps the button's art
## between zoomin.ddj and zoomout.ddj (0xdd5f3c / 0xdd5f58), and asks for a
## move (+0x229). The next frame starts a 1.0 s path (FUN_0084f9e0: two keys,
## the current pose at 0 and the new one at 1.0, the title's Catmull-Rom
## curves, IntroCameraPath) to:
## - zoomed out: target (0.5, 9.8, 0), distance 28.5;
## - zoomed in: target (2.0, h x 15 for a man / h x 14 for a woman, 0)
##   (0x84f36b..0x84f3b3: 0xd86ecc = 2.0, 0xdd5e2c = 15.0, 0xdd5e30 = 14.0),
##   h the window's +0x528 (Height's factor), distance 11.0 (0xd8acf8);
## both at pitch 0.2, yaw 0, roll 0.
##
## **The backdrop** (0x8505ed..0x850665): the world camera's pitch 0, roll 0,
## distance 0.1 (0xe1b7fc) and yaw = clock / 30000.0 + 0.390955 (0xdd6028,
## 0xdd6020), clock the unsigned DAT_0110f800 (INFERRED milliseconds: a turn
## in 2 pi x 30 s = 188 s); target China (960.4189, 50.0, 458.2598) in region
## 0x62a8 = 98/168 (0xdd5f7c, 0xd851a0, 0xdd5f78), Europe (335, 140, 1460) in
## 0x694f = 105/79 (charselect.md section 4).

const SPIN_STEP := 50.0
const SPIN_DECAY := 0.5
const SPIN_STOP := 30.0
const DEG_TO_YAW := 3.14 / 180.0

const MODEL_POSITION := Vector3(3.0, 0.5, 0.0)
const FOV_Y_DEGREES := 45.0
const PITCH := 0.2
const OUT_TARGET := Vector3(0.5, 9.8, 0.0)
const OUT_DISTANCE := 28.5
const IN_X := 2.0
const IN_HEIGHT_MAN := 15.0
const IN_HEIGHT_WOMAN := 14.0
const IN_DISTANCE := 11.0
const ZOOM_SECONDS := 1.0

const BACKDROP_DISTANCE := 0.1
const BACKDROP_YAW_MS := 30000.0
const BACKDROP_YAW0 := 0.390955
const BACKDROP := {
	CharCatalog.RACE_CHINA: {"region": Vector2i(98, 168), "target": Vector3(960.4189, 50.0, 458.2598)},
	CharCatalog.RACE_EUROPE: {"region": Vector2i(105, 79), "target": Vector3(335.0, 140.0, 1460.0)},
}

## The spin's angle ("degrees" before the 3.14/180) and velocity.
var angle := 0.0
var velocity := 0.0

## The zoom: whether it is in, and the path running to the new pose (null
## when resting).
var zoomed := false
var _path: IntroCameraPath = null
var _pose: IntroCameraPath.Pose = null

func _init() -> void:
	_pose = pose_for(false, 1.0, false)

## A rotate button: -1 left, +1 right.
func click(direction: int) -> void:
	velocity += SPIN_STEP * signf(direction)

## One frame of the spin (READ above).
func step_spin(dt: float) -> void:
	var d := dt * velocity * SPIN_DECAY
	if absf(velocity) < absf(d):
		d = velocity
	angle += (velocity + velocity - d) * dt * SPIN_DECAY
	velocity -= d
	if absf(velocity) < SPIN_STOP:
		velocity = 0.0

func yaw() -> float:
	return angle * DEG_TO_YAW

## The camera pose for a zoom state.
static func pose_for(zoom_in: bool, height_factor: float, woman: bool) -> IntroCameraPath.Pose:
	var p := IntroCameraPath.Pose.new()
	p.pitch = PITCH
	p.yaw = 0.0
	p.roll = 0.0
	if zoom_in:
		p.target = Vector3(IN_X, height_factor * (IN_HEIGHT_WOMAN if woman else IN_HEIGHT_MAN), 0.0)
		p.distance = IN_DISTANCE
	else:
		p.target = OUT_TARGET
		p.distance = OUT_DISTANCE
	return p

## The zoom button: flips the state and starts the 1.0 s move from where the
## camera is now.
func toggle_zoom(height_factor: float, woman: bool) -> void:
	zoomed = not zoomed
	var to := pose_for(zoomed, height_factor, woman)
	_path = IntroCameraPath.from_keyframes([_key(0.0, _pose), _key(ZOOM_SECONDS, to)])

static func _key(t: float, p: IntroCameraPath.Pose) -> IntroScript.Keyframe:
	var k := IntroScript.Keyframe.new()
	k.time = t
	k.pos = p.target
	k.pitch = p.pitch
	k.yaw = p.yaw
	k.roll = p.roll
	k.distance = p.distance
	return k

## Advances the zoom; returns the camera's pose.
func step_zoom(dt: float) -> IntroCameraPath.Pose:
	if _path != null:
		_pose = _path.advance(dt)
		if _path.finished():
			_path = null
	return _pose

func pose() -> IntroCameraPath.Pose:
	return _pose

func zoom_moving() -> bool:
	return _path != null

## The backdrop camera's pose at `clock_ms` (READ above).
static func backdrop_pose(race: int, clock_ms: int) -> IntroCameraPath.Pose:
	var p := IntroCameraPath.Pose.new()
	p.target = BACKDROP[race]["target"]
	p.pitch = 0.0
	p.roll = 0.0
	p.distance = BACKDROP_DISTANCE
	# The clock is read as unsigned (fild then +2^32 when negative, READ).
	var clock := float(clock_ms & 0xffffffff)
	p.yaw = clock / BACKDROP_YAW_MS + BACKDROP_YAW0
	return p
