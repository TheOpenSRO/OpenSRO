extends RefCounted
class_name MoveOrderSync

## Round 749: what the player's own walk tells the server, now that a walk is
## retail's 0x7021 (one per click) rather than a stream of positions
## (docs/rounds/r749.md; DestMoveNet; server/internal/session/destmove.go).
##
## The player's walk stays the client's own -- it starts on the click, as
## before, and nothing waits for the server -- so the feel is unchanged. This
## decides, once a physics tick, which message the walk owes:
##   "dest"        a 0x7021 to the order's point: a new order, or the order's
##                 point moved more than NEAR_DESTINATION from the one sent,
##                 both TRUNCATED as the wire carries them (round 749's review,
##                 F5: READ, the server refuses a new destination within 5.0
##                 of its own, `<=`, on the truncated coordinates, 0x48c35f).
##   "heading"     a 0x7021 heading form: a heading run began, or its heading
##                 changed.
##   "stop"        OpMove with the stop flag (OURS): the order ended short of
##                 the point the server walks to by more than ARRIVE_SLACK, or
##                 a wall ended it (the caller says so: blocked), or a heading
##                 run ended.
##   "ended"       the order ended within ARRIVE_SLACK of the point, unblocked:
##                 the server's leg ends there too, nothing is sent, as
##                 retail's arrival sends nothing. (The caller probes the
##                 navigation graph from where the player stands to the point
##                 first, and reports a stop when a wall lies between: round
##                 749's review, F6.)
##   "unconfirmed" the last 0x7021 has had no echo for ECHO_TIMEOUT_MS: the
##                 server refused it (round 749's review, F3).
##   ""            nothing: the server's leg is the walk's.
##
## THE ECHO (F3). READ: retail's 0x7021 handler refuses silently -- every
## refusal in GObjPC::FUN_004b0ea0 is a bare return, no reply on any path
## (re-read in round 749's review) -- and retail's client walks only on its
## echo, so a refused click leaves it standing. OpenSRO's client walks at once,
## so it keeps the last order unconfirmed until its own 0xB021 names it, and
## takes no echo within ECHO_TIMEOUT_MS as the refusal (OURS): the walk stops
## where it is and the stop goes out, which the server takes within its bound
## or answers with where it has the player.

## READ (0xb45b28): the server's "same destination" distance.
const NEAR_DESTINATION := 5.0
## OURS: how far short of the point sent a walk may end unreported (the stop
## distance 2.39 plus the truncation, rounded up). The server's free slack is
## 9 (destmove.go claimSlack): this, plus a click within 5.0 of the point
## walked but not sent (5 + 2.39 + 1.42 = 8.8).
const ARRIVE_SLACK := 3.0
## OURS: the explicit flush's bound (before an attack, a pick-up, a talk, a
## sit): the position goes out when it is more than this from where the
## server will have the player, so the request is measured from here.
const FLUSH_SLACK := 0.5
## OURS: a new order closer than this to where the player stands is not sent
## (it would walk nowhere).
const MIN_ORDER := 0.5
## OURS: how long a sent 0x7021 waits for its echo before the client takes it
## as refused. A round trip on the public server is well under it; a click
## the server refuses (or its bucket drops) costs at most this much walk,
## which the stop then reconciles.
const ECHO_TIMEOUT_MS := 1500

## The server has a leg this client sent (as far as the client knows).
var active := false
## That leg is a heading run (heading_wire) or a walk to dest.
var heading_run := false
var dest := Vector3.INF
var heading_wire := -1
## Where the server has (or will have) the player once its leg is over: the
## destination sent, or the last stop or placement reported.
var rest := Vector3.INF
## The last 0x7021's echo, awaited since pending_ms (-1: none awaited).
var pending_ms := -1

## The tick's decision for the order in effect (has_order, the walk's point
## `target` and that point as the wire truncates it, `qtarget`; or a heading
## run with `wire`) and the player at `pos`, at now_ms.
func decide(has_order: bool, run: bool, target: Vector3, qtarget: Vector3, wire: int, pos: Vector3, now_ms: int) -> String:
	if pending_ms >= 0 and now_ms - pending_ms > ECHO_TIMEOUT_MS:
		pending_ms = -1
		return "unconfirmed"
	if has_order:
		if run:
			if not active or not heading_run or wire != heading_wire:
				return "heading"
			return ""
		if active and not heading_run:
			return "dest" if _flat(qtarget - dest) > NEAR_DESTINATION else ""
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

## A 0x7021 to `sent_dest` (the truncated point the server walks to) went out
## at now_ms.
func sent_destination(sent_dest: Vector3, now_ms: int = 0) -> void:
	active = true
	heading_run = false
	dest = sent_dest
	heading_wire = -1
	pending_ms = now_ms

## A heading form went out at now_ms.
func sent_heading(wire: int, now_ms: int = 0) -> void:
	active = true
	heading_run = true
	heading_wire = wire
	dest = Vector3.INF
	pending_ms = now_ms

## This player's own 0xB021 came (kind, its destination in world coordinates,
## its heading form's angle): it confirms the last order when it names it. An
## echo of an older order (superseded) confirms nothing.
func confirm(kind: int, echo_dest: Vector3, angle: int) -> void:
	if pending_ms < 0:
		return
	if kind == DestMoveNet.KIND_HEADING:
		if heading_run and angle == heading_wire:
			pending_ms = -1
	elif not heading_run and dest != Vector3.INF and _flat(echo_dest - dest) < 0.01:
		pending_ms = -1

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
	pending_ms = -1

static func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
