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
## OURS, disclosed:
##   - The source is taken only when the drawn body is more than
##     MonsterMotion.RESYNC_DISTANCE from it (the monsters' own rule): a body
##     drawn one latency behind is not jerked back on every click.
##   - The body walks a straight line: the observer does not run its own
##     collision. A wall the mover meets reaches the observer as the mover's
##     stop (0xB023), one transit later.

## A player's base run speed, characterdata column 47 (server
## session.PlayerRunSpeed, MEASURED): the speed of a body whose spawn or buffs
## named none.
const DEFAULT_SPEED := 50.0

## A walk to `dest` at `speed`.
static func to_point(dest: Vector3, speed: float) -> Dictionary:
	return {"dest": dest, "speed": speed, "run": false, "dir": Vector2.ZERO, "h_xz": Vector2.INF}

## A heading run along the u16 wire angle `wire` at `speed`.
static func on_heading(wire: int, speed: float) -> Dictionary:
	var dir := RemoteFacing.facing_of(RemoteFacing.from_wire_angle(wire))
	return {"dest": Vector3.INF, "speed": speed, "run": true, "dir": dir, "h_xz": Vector2.INF}

## Where a new leg starts: the drawn position, or the message's source when the
## body has drifted more than RESYNC_DISTANCE from it (x, z only).
static func start_at(drawn: Vector3, source: Vector3, has_source: bool) -> Vector3:
	if has_source and Vector2(drawn.x - source.x, drawn.z - source.z).length() > MonsterMotion.RESYNC_DISTANCE:
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
	var next := MonsterMotion.step(Vector2(at.x, at.z), Vector2(dest.x, dest.z), speed, delta)
	if next == Vector2(dest.x, dest.z):
		return {"pos": Vector3(dest.x, at.y, dest.z), "done": true}
	return {"pos": Vector3(next.x, at.y, next.y), "done": false}

## The direction a leg faces its body from `at` (x, z), for the turn.
static func facing(leg: Dictionary, at: Vector3) -> Vector3:
	if bool(leg["run"]):
		var d: Vector2 = leg["dir"]
		return Vector3(d.x, 0.0, d.y)
	var dest: Vector3 = leg["dest"]
	return Vector3(dest.x - at.x, 0.0, dest.z - at.z)
