extends RefCounted
class_name OtherWalk

## Round 749: how another player's body walks the move the server told this
## client of -- retail's 0xB021 (DestMoveNet), or a spawn record that names a
## destination -- instead of easing toward a stream of positions. Pure and
## static so a headless test holds it to account; World3D._on_entity_move_echo,
## _on_entity_move_stop and _step_other_bodies are the glue.
##
## READ (docs/protocol/opcodes/movement.md, "0xB021 in full", "How the client
## steps a mover"): the client walks every object toward its destination
## itself, every frame, `speed * seconds` along the line and never past the
## point (FUN_009e0e60, the same cut as the server's CGObjMoverByDest::
## vslot_003, MonsterMotion.step); a heading form walks along its heading with
## nothing to arrive at (FUN_009e08a0); a flag-1 message places the object at
## its source first (FUN_009e11e0); 0xB023 snaps it (FUN_008a4f80).
##
## Round 846, READ (sro_client.exe; docs/protocol/opcodes/movement.md, "How an
## observer keeps up"): the flag-1 source is placed through
## NetProcessInNavAndSkill::FUN_009e11e0, which moves the mover's own record
## (+0x4c) there but re-places the drawn object (+0x74, vtable +0x94 through
## GlobalDataManager::FUN_009e0d50) only when FUN_009e1050 finds the two more
## than 50.0 apart (double 0xd8f0b0, FUN_009ecdb0's distance). The aim
## FUN_009e0550 then sets the mover's speed factor (+0x8c, which the tick
## FUN_009e0e60 multiplies the walk/run speed by) to the drawn object's
## ground distance to the destination over the record's (FUN_009ecc70),
## capped at 3.0 (float 0xd8adc4; 3.0 too when the record already stands on
## the point, double 0xe1b808), and to 1.0 when the drawn object is no
## farther than the record. So a body drawn behind where the server has its
## mover walks on from where it is drawn, up to three times its speed, and
## reaches the point about when the server's mover does -- small steps and
## large ones walked, never put back -- and only a body more than 50 off is
## moved. (INFERRED: that the factor drives the drawn body's walk; where the
## object's +0x74 follows the record each tick was not read.)
##
## OURS, disclosed:
##   - RESYNC_DISTANCE is measured on the ground (x, z); retail's
##     FUN_009ecdb0 is 3-D, and the server's height for a player is a guess
##     (world.Mover's straight line) that must not move a body.
##   - Round 852: the body's walk meets walls as the mover's does (BodyWalk,
##     READ c:0x9e0fca for every mover): a leg's "walled" says whether it is
##     walked through the navigation graph a frame at a time (true until
##     BodyWalk.meets_wall finds the straight leg clear). Before, the body
##     walked a straight line and a wall reached the observer only as the
##     mover's stop (0xB023), one transit later: it pressed into the wall and
##     was pulled back.

## A player's base run speed, characterdata column 47 (server
## session.PlayerRunSpeed, MEASURED): the speed of a body whose spawn or buffs
## named none.
const DEFAULT_SPEED := 50.0

## READ (0xd8f0b0, FUN_009e1050): a drawn body more than this far from the
## message's source is put there; a nearer one walks on from where it is.
const RESYNC_DISTANCE := 50.0
## READ (float 0xd8adc4): the most a body's speed is multiplied by to catch up.
const CATCH_UP_MAX := 3.0

## A walk to `dest` at `speed`, `mult` times faster while it catches up
## (catch_up). The leg keeps the factor apart, so a buff's new speed
## (World3D._note_other_speed) keeps it.
static func to_point(dest: Vector3, speed: float, mult: float = 1.0) -> Dictionary:
	return {"dest": dest, "speed": speed, "mult": mult, "run": false, "dir": Vector2.ZERO, "h_xz": Vector2.INF, "walled": true}

## READ (FUN_009e0550): the speed factor of a walk to `dest` by a body drawn at
## `drawn` whose mover the message puts at `source`: the drawn body's ground
## distance to the point over the source's, at most CATCH_UP_MAX (and
## CATCH_UP_MAX when the source is on the point); 1.0 when the drawn body is
## no farther from the point than the source, or there is no source.
static func catch_up(drawn: Vector3, source: Vector3, has_source: bool, dest: Vector3) -> float:
	if not has_source:
		return 1.0
	var from_drawn := Vector2(dest.x - drawn.x, dest.z - drawn.z).length()
	var from_source := Vector2(dest.x - source.x, dest.z - source.z).length()
	if from_source >= from_drawn:
		return 1.0
	if from_source == 0.0:
		return CATCH_UP_MAX
	return minf(from_drawn / from_source, CATCH_UP_MAX)

## A heading run along the u16 wire angle `wire` at `speed`.
static func on_heading(wire: int, speed: float) -> Dictionary:
	var dir := RemoteFacing.facing_of(RemoteFacing.from_wire_angle(wire))
	return {"dest": Vector3.INF, "speed": speed, "run": true, "dir": dir, "h_xz": Vector2.INF, "walled": true}

## Where a new leg starts: the drawn position, or the message's source when the
## body is more than RESYNC_DISTANCE from it (x, z only).
static func start_at(drawn: Vector3, source: Vector3, has_source: bool) -> Vector3:
	if has_source and Vector2(drawn.x - source.x, drawn.z - source.z).length() > RESYNC_DISTANCE:
		return source
	return drawn

## One frame of the leg from `at`: {"pos": Vector3, "done": bool}. The height is
## left as it was: the caller resolves the ground as the body goes, and on the
## point (the wire's height is the click's, truncated to a whole unit).
static func step(leg: Dictionary, at: Vector3, delta: float) -> Dictionary:
	var speed := float(leg["speed"])
	if bool(leg["run"]):
		var s := minf(absf(speed * delta), MonsterMotion.MOVER_STEP_CAP)
		var d: Vector2 = leg["dir"]
		return {"pos": Vector3(at.x + d.x * s, at.y, at.z + d.y * s), "done": false}
	var dest: Vector3 = leg["dest"]
	speed *= float(leg.get("mult", 1.0))
	var next := MonsterMotion.step(Vector2(at.x, at.z), Vector2(dest.x, dest.z), speed, delta)
	if next == Vector2(dest.x, dest.z):
		return {"pos": Vector3(dest.x, at.y, dest.z), "done": true}
	return {"pos": Vector3(next.x, at.y, next.y), "done": false}

## The direction a leg faces its body from `at` (x, z), for the turn.
static func facing(leg: Dictionary, at: Vector3) -> Vector3:
	if bool(leg["run"]):
		var d: Vector2 = leg["dir"]
		return Vector3(d.x, 0.0, d.y)
	# Round 852: a leg whose end a wall moved still faces the end it was told
	# of (World3D._plan_body_leg's "aim").
	var dest: Vector3 = leg.get("aim", leg["dest"])
	return Vector3(dest.x - at.x, 0.0, dest.z - at.z)
