extends RefCounted
class_name MoveOrderSync

## Round 749: what the player's own walk tells the server, now that a walk is
## retail's 0x7021 (one per click) rather than a stream of positions
## (docs/rounds/r749.md; DestMoveNet; server/internal/session/destmove.go).
##
## The player's walk stays the client's own -- it starts on the click, as
## before, and nothing waits for the server -- so the feel is unchanged. This
## decides, once a physics tick, which message the walk owes:
##   "dest"    a 0x7021 to the order's point: a new order, or the order's
##             point moved NEAR_DESTINATION or more from the one sent (READ:
##             the server refuses one within 5.0 of the destination it has,
##             0xb45b28; an approach re-aimed every tick at a walking target
##             is sent only as its point moves that far).
##   "heading" a 0x7021 heading form: a heading run began, or its heading
##             changed.
##   "stop"    OpMove with the stop flag (OURS): the order ended short of the
##             point the server walks to -- a wall, an approach in reach, a
##             sit, the end of a heading run -- by more than ARRIVE_SLACK.
##   ""        nothing: the server's leg is the walk's.
## A walk that ends within ARRIVE_SLACK of the point sent says nothing, as
## retail's arrival says nothing: the client stops within its stop distance
## (2.39, World3D.MOVE_TARGET_STOP_DISTANCE) of a point the wire truncated to
## whole units (up to 1.42 away).

## READ (0xb45b28): the server's "same destination" distance.
const NEAR_DESTINATION := 5.0
## OURS: how far short of the point sent a walk may end unreported (the stop
## distance 2.39 plus the truncation, rounded up). The server takes a report
## within its own idle bound of 8 (destmove.go idleSlack).
const ARRIVE_SLACK := 3.0
## OURS: the explicit flush's bound (before an attack, a pick-up, a talk, a
## sit): the position goes out when it is more than this from where the
## server will have the player, so the request is measured from here.
const FLUSH_SLACK := 0.5
## OURS: a new order closer than this to where the player stands is not sent
## (it would walk nowhere).
const MIN_ORDER := 0.5

## The server has a leg this client sent (as far as the client knows).
var active := false
## That leg is a heading run (heading_wire) or a walk to dest.
var heading_run := false
var dest := Vector3.INF
var heading_wire := -1
## Where the server has (or will have) the player once its leg is over: the
## destination sent, or the last stop or placement reported.
var rest := Vector3.INF

## The tick's decision for the order in effect (has_order, the walk's point
## `target`, or a heading run with `wire`) and the player at `pos`.
func decide(has_order: bool, run: bool, target: Vector3, wire: int, pos: Vector3) -> String:
	if has_order:
		if run:
			if not active or not heading_run or wire != heading_wire:
				return "heading"
			return ""
		if active and not heading_run:
			return "dest" if _flat(target - dest) >= NEAR_DESTINATION else ""
		return "dest" if _flat(target - pos) >= MIN_ORDER else ""
	if not active:
		return ""
	if heading_run or _flat(pos - dest) > ARRIVE_SLACK:
		return "stop"
	return "ended"

## The explicit flush (the request that follows is measured from where the
## server has the player): "stop" when the player stands more than
## FLUSH_SLACK from it.
func flush(pos: Vector3) -> String:
	if active and heading_run:
		return "stop"
	var at := dest if active else rest
	if at == Vector3.INF or _flat(pos - at) > FLUSH_SLACK:
		return "stop"
	return ""

## A 0x7021 to `sent_dest` (the truncated point the server walks to) went out.
func sent_destination(sent_dest: Vector3) -> void:
	active = true
	heading_run = false
	dest = sent_dest
	heading_wire = -1

## A heading form went out.
func sent_heading(wire: int) -> void:
	active = true
	heading_run = true
	heading_wire = wire
	dest = Vector3.INF

## The order ended at its point unreported: the server's leg ends there too.
func arrived() -> void:
	active = false
	heading_run = false
	rest = dest
	heading_wire = -1

## A stop or placement went out, or the server placed the player (its own
## 0xB023): the server has the player at `at`, with no leg.
func placed(at: Vector3) -> void:
	active = false
	heading_run = false
	heading_wire = -1
	dest = Vector3.INF
	rest = at

static func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
