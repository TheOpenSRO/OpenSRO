extends RefCounted
class_name RemoteFacing

## How another player's or a monster's body turns to face where it is going,
## as the client's own mover turns it (round 637). Pure and static so a
## headless test can hold every rule to account; World3D._aim_remote_body and
## _step_remote_turns are the glue.
##
## READ (sro_client.exe, round 637): a movement message (0xB021, read by
## NetProcessInNavAndSkill::FUN_008a5750) with a destination hands it to the
## object's mover, FUN_009e0550. That takes the vector from the object's
## position (+0x74) to the destination (FUN_009ecc70, which zeroes its y),
## turns it into a heading (FUN_009ed130, heading_toward below) and calls
## FUN_009e02f0(heading, 0). FUN_009e02f0 is the turn (turn below): it stores
## the target heading at mover+0xa8, points the mover's travel direction
## (+0x68) along the TARGET at once (FUN_009ec850), and moves the object's
## drawn heading (+0x8c, through FUN_009c4260) only by what the elapsed time
## allows. Every frame the mover's tick FUN_009e0e60 -> FUN_009e0c10 calls
## FUN_009e02f0 again with the time since the last call (object +0x3c minus
## mover +0xa0) while mover+0xa4 says a turn is in progress. So the body walks
## straight at its destination at once, and its facing turns toward it by the
## shorter way at TURN_RATE_PER_MS; nothing turns it once it has arrived, so a
## body that stops keeps its last heading.
##
## The heading-only form of the message (kind 0: FUN_009e08a0) goes through
## the same FUN_009e02f0, so it turns at the same rate. srrevamp's protocol
## sends neither form for a player: OpEntityMoved is a stream of positions,
## each of which World3D treats as the destination (see World3D._on_entity_moved).
##
## The heading h is the client's own (+0x8c, [0, 2 pi)): FUN_009ec850 turns it
## into the facing (sin h, 0, -cos h) in the region-local frame (x east, z
## north; docs/protocol/minimap.md). The region group's basis mirrors z (world
## z = -local z; World3D.minimap_facing), so in world space the facing is
## (sin h, cos h) -- exactly where a node with rotation.y = h points its local
## +Z. So for a body whose front is its node's +Z (another player: the skeleton
## is turned PI inside it) rotation.y IS the client's heading, and for a
## monster whose front is measured (MonsterMotion.FRONT_BY_MODEL) rotation.y is
## h less that front's yaw (yaw_of / heading_of_yaw).

## The turn rate: FUN_009e02f0 scales the elapsed time (an unsigned int, +2^32
## when its sign bit is set, 0xe1b7c8) by the .rdata double at 0xde3128,
## 9.42477798461914 (3 pi at float precision), and divides by the double at
## 0xd83268, 1000.0 -- values read out of the PE image on the box in round 637.
## The time is the object's clock, CObj +0x3c, which the scene's update loop
## (FUN_00ba34e0, 0xba359b..0xba35a1) advances by the frame's milliseconds
## (DAT_0110f7f8); every character is a CObj (RTTI: CICUser : CICharactor :
## CIGIDObject : CIObject : CIEntity : CObjChild : CObj). So 3 pi radians a
## second: a half turn takes a third of a second.
const TURN_RATE_PER_SECOND := 9.42477798461914
const MS_PER_SECOND := 1000.0

## FUN_009ed130 leaves the heading as it was when the vector is no longer than
## the float at 0xe1b848, 1e-6 (9.999999974752427e-07 as read).
const MIN_LENGTH := 9.999999974752427e-07

## The heading of the ground vector `dir` (WORLD x, z; y is ignored, as
## FUN_009ecc70 zeroes it), or `current` when the vector is too short to have
## one. FUN_009ed130 (0x9ed130..0x9ed1cd): len = |v|; if len <= 1e-6 the
## output is untouched; otherwise a = acos(-z_local / len), and the heading is
## a when x >= 0 and 2 pi - a when x < 0. -z_local is world z.
static func heading_toward(current: float, dir: Vector3) -> float:
	var flat := Vector3(dir.x, 0.0, dir.z)
	var length := flat.length()
	if not (length > MIN_LENGTH):
		return current
	var a := acos(clampf(flat.z / length, -1.0, 1.0))
	if flat.x >= 0.0:
		return a
	return TAU - a

## One call of FUN_009e02f0 (0x9e02f0..0x9e0461): from heading `current`
## toward `target`, with `elapsed_ms` since the last call. Returns
## {"heading": the new heading, "turning": whether the turn goes on}.
##   d = target - current; sign = +1, or -1 (and d = -d) when d < 0;
##   when d > pi the other way round is shorter: sign = -sign, d = 2 pi - d;
##   step = elapsed_ms * 9.42477798461914 / 1000;
##   step <= d (fcom, C0|C3 at 0x9e039d): heading += sign * step, wrapped into
##     [0, 2 pi), and the turn stays on (+0x88 bit 0, +0xa4 = 1);
##   step > d: the heading is the target and the turn is over.
## A call with no time (the mover's own, from FUN_009e0550) only starts the
## turn: step 0 <= d.
static func turn(current: float, target: float, elapsed_ms: float) -> Dictionary:
	var d := target - current
	var sign := 1.0
	if d < 0.0:
		sign = -1.0
		d = -d
	if d > PI:
		sign = -sign
		d = TAU - d
	var step := elapsed_ms * TURN_RATE_PER_SECOND / MS_PER_SECOND
	if step <= d:
		var h := current + sign * step
		while h < 0.0:
			h += TAU
		while h >= TAU:
			h -= TAU
		return {"heading": h, "turning": true}
	return {"heading": wrap_heading(target), "turning": false}

## FUN_009c4260's wrap: into [0, 2 pi).
static func wrap_heading(h: float) -> float:
	var w := fposmod(h, TAU)
	return 0.0 if w >= TAU else w

## A body's rotation.y for heading `h`, its front `front_yaw` radians round
## from its node's +Z (0 for another player, PI for a -Z-front monster).
static func yaw_of(h: float, front_yaw: float) -> float:
	return wrapf(h - front_yaw, -PI, PI)

## The heading a body's rotation.y shows, the inverse of yaw_of.
static func heading_of_yaw(yaw: float, front_yaw: float) -> float:
	return wrap_heading(yaw + front_yaw)

## The ground direction heading `h` faces, in world space (x, z).
static func facing_of(h: float) -> Vector2:
	return Vector2(sin(h), cos(h))

## A u16 wire angle as the client turns it into a heading (round 637's review
## follow-up): FUN_008a5640 makes radians of it, (a / 65535.0) * 360.0 *
## 0.01745329238474369 (0xdde7b0, 0xdde7a8, 0xe1b8d8), and FUN_009c40b0 adds
## pi/2 (0xe1b8f0, 1.5707963705062866) and takes 2 pi (0xd81930,
## 6.2831854820251465) off while the result is 2 pi or more. The spawn reader
## FUN_009c3a70 converts its angle the same way, and FUN_009d17e0 stores it
## with a bare FUN_009c4260: a spawn is placed facing it, not turned.
const WIRE_QUARTER_TURN := 1.5707963705062866
const WIRE_FULL_TURN := 6.2831854820251465

static func from_wire_angle(a: int) -> float:
	var h := (float(a & 0xffff) / 65535.0) * 360.0 * 0.01745329238474369 + WIRE_QUARTER_TURN
	while h >= WIRE_FULL_TURN:
		h -= WIRE_FULL_TURN
	return h

## The player's own ground click, UI_SILKMALL::FUN_009eb2a0 (called by
## FUN_009ec240 before it sends the move; a 1 sends it):
##   no movement order in effect (the player's +0x714, mover +0xac): a click
##     whose squared distance from the player is under 25.0 (0xe1b8a0) is not
##     sent -- "ignore";
##   an order in effect, the click and the order's destination both 10000.0
##     (0xd82efc, 100 units) or more away in squared distance, and the angle
##     between the two ground vectors (FUN_0045c590, y zeroed) 0.0872664600610733
##     (0xdb9828, 5 degrees) or less: the local mover is re-aimed at once by
##     FUN_009e04b0, whose FUN_009e0050 SNAPS the heading and ends a turn --
##     "snap";
##   otherwise the move is sent, and its echo (0xB021 -> FUN_008a5750 ->
##     FUN_009e0550) turns the player at TURN_RATE_PER_SECOND -- "turn".
## The distances are FUN_009ed1e0's, 3-D.
const CLICK_IDLE_MIN_SQ := 25.0
const SNAP_FAR_SQ := 10000.0
const SNAP_MAX_ANGLE := 0.0872664600610733

static func click_rule(order_in_effect: bool, to_click: Vector3, to_dest: Vector3) -> String:
	if not order_in_effect:
		return "ignore" if to_click.length_squared() < CLICK_IDLE_MIN_SQ else "turn"
	if to_click.length_squared() >= SNAP_FAR_SQ and to_dest.length_squared() >= SNAP_FAR_SQ:
		var a := Vector3(to_click.x, 0.0, to_click.z)
		var b := Vector3(to_dest.x, 0.0, to_dest.z)
		if not a.is_zero_approx() and not b.is_zero_approx() and a.angle_to(b) <= SNAP_MAX_ANGLE:
			return "snap"
	return "turn"
