class_name SkyRun
extends RefCounted

## Round 653: a click on the sky, or on ground too far away, runs the
## character along the click's heading until it is stopped or meets a wall.
##
## READ, sro_client.exe (docs/protocol/opcodes/movement.md, "The heading
## move: a click on the sky"):
## - The world click `UI_SILKMALL::FUN_0078f8d0` makes the pick ray with
##   `FUN_00a5ade0` (the camera's position, and the camera's ray through the
##   cursor times 5000.0, `0xde5188`). It hands the ray to the world pick
##   `SWorld::vslot_034` (`0xa01310`, slot 34 of `0xde4fb4`), which normalises
##   the direction and scales it by **1000.0** (`0xd83268`) before testing the
##   terrain blocks and the objects (`[0x111a02c]` vtable +0x3c) against that
##   segment. The pick answers only inside 1000 units of the camera.
## - A hit walks to the point, as before (`FUN_009ec570` -> the destination
##   form of 0x7021).
## - **No hit** takes the other path: the ray's direction with its height
##   zeroed (`fldz` into y at `0x78fb07`), normalised (`FUN_00410cd0`), made a
##   heading with `FUN_009ed130` (RemoteFacing.heading_toward's reading), and
##   sent as the **heading form** of 0x7021 by `FUN_009ebec0(h, 1)`: kind 0,
##   the command byte 1, and the u16 angle of `h - pi/2` (`FUN_009c4060`).
## - It is not sent -- the click does nothing -- when the player's state word
##   (`+0x65c`) has bit 9, `+0x6e8` is not 1, and the new heading is within
##   0.0872664600610733 rad (5 degrees, `0xdb9828`) of the player's current
##   heading `+0x8c`. The difference is taken raw, not wrapped: `|cur - h|`
##   (`fsub`, then `fmul -1.0` `0xe1b8e8` when negative). Bit 9 is the state
##   `FUN_009c9920(9, 0)` sets on every movement echo (`FUN_008a5750`); that
##   it means "moving" is INFERRED.
##
## READ, the run (the client's mover and the server's):
## - The echo's heading form reaches the mover as `FUN_009e08a0`: `+0x80 = 2`
##   (no destination), `+0x84 = 1` (moving), `+0xac = 1` (an order), the
##   travel direction at once (`FUN_009e0090`) and the facing turned at 3 pi
##   rad/s (`FUN_009e02f0`).
## - The mover's tick `FUN_009e0e60` tests a destination only when
##   `+0x80 == 1`, so a heading move steps `speed * seconds` along the travel
##   direction on every frame, with no end of its own.
## - It ends when the collision query (`CRegionManagerBody::vslot_012`,
##   `0x412660`, slot 12 of `0xe16184`) refuses the step (bit `0x10000000`:
##   the body stays) or returns bit 0 (the step is taken to the point the
##   query set, then the movement ends). The query's terrain walk
##   (`CRTNavMeshTerrain::vslot_002`, `0x4047a0`) answers a blocking edge with
##   the crossing point nudged at most 0.2 (`FUN_004472d0`, `0xe1b850`) and
##   bit 0: the body **stops at the wall**, it does not slide along it
##   (NavGraph.step_tracked's no-slide walk has the same reading).
## - The server steps its own heading mover the same way: `CGObjMoverByCmd`
##   (server `0x48c1b0`) steps while the forward bit is set, along the
##   object's heading times the speed (`CGObjMoverByDest::FUN_0048bff0`), with
##   no distance of its own.
##
## OURS: srrevamp's movement is client-authoritative positions. The run is the
## click walk's order with a heading instead of a point (World3D
## `_move_heading_run`); each position it sends carries the heading form
## (WorldNet.encode_move), which the server relays so other players face the
## run's heading (World3D._on_entity_moved).

## The pick's reach from the camera: SWorld::vslot_034 scales the ray to
## 1000.0 (0xd83268, READ). Ground farther than this is not a destination.
const PICK_LENGTH := 1000.0

## FUN_0078f8d0's no-resend window: 5 degrees (0xdb9828, READ).
const RESEND_MAX_ANGLE := 0.0872664600610733

## The heading form's command byte, the record's +0x14 (READ): the sky click
## sends 1 (FUN_009ebec0's `local_4 = 1`). The server's CGObjMoverByCmd reads
## bit 0 as "move forward" (vslot_004 sets its stepping flag +0xc on it),
## 0x10 and 0x20 as turning one way and the other at pi rad/s (vslot_010,
## 0xb45c20); the arrow keys send 0x10 and 0x20 (FUN_0077b070 ->
## FUN_009ebf40). Only 1 is used here.
const COMMAND_FORWARD := 1

## The ray the click-to-move pick casts: from the camera, PICK_LENGTH along
## `dir`, on `mask`, not hitting `exclude`.
static func pick_query(from: Vector3, dir: Vector3, mask: int, exclude: Array) -> PhysicsRayQueryParameters3D:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir.normalized() * PICK_LENGTH)
	q.collision_mask = mask
	q.exclude = exclude
	return q

## The heading of a pick ray: its ground direction (y zeroed), or `current`
## when the ray points straight up or down (FUN_009ed130 keeps the heading
## for a vector no longer than 1e-6).
static func heading_of_ray(current: float, ray_dir: Vector3) -> float:
	return RemoteFacing.heading_toward(current, ray_dir)

## FUN_0078f8d0's test before it sends a heading move: "keep" when the player
## is moving and `target` is within RESEND_MAX_ANGLE of `current` (raw
## difference, as retail's), else "run".
static func click_rule(moving: bool, current: float, target: float) -> String:
	if moving and absf(current - target) <= RESEND_MAX_ANGLE:
		return "keep"
	return "run"

## One tick of a heading run: the full speed along heading `h`. There is no
## destination to cut the step to (round 649's no-overshoot rule is for
## `+0x80 == 1`, a destination; the heading form sets 2).
static func velocity(h: float, speed: float) -> Vector2:
	return RemoteFacing.facing_of(h) * speed

## Whether a heading run's step ends the run: any step the navigation graph
## blocked (the no-slide walk stopped it at the wall), READ as above.
static func blocked_ends(blocked: bool) -> bool:
	return blocked

## The u16 the heading form carries for heading `h`: FUN_009c4060 takes pi/2
## off (0xe1b8f0) and adds 2 pi (0xd81930) while negative; FUN_009ebbf0 then
## writes ROUND(r * 57.295780181884766 / 360 * 65535) (0xdde8f0, 0xdde7a8,
## 0xdde7b0) truncated to 16 bits. RemoteFacing.from_wire_angle is the
## inverse. The x87 rounding at a tie is not read; this rounds half away from
## zero.
static func wire_angle(h: float) -> int:
	var r := h - RemoteFacing.WIRE_QUARTER_TURN
	while r < 0.0:
		r += RemoteFacing.WIRE_FULL_TURN
	return int(roundf(r * 57.295780181884766 / 360.0 * 65535.0)) & 0xffff
