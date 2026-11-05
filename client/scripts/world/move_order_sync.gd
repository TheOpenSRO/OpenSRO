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
##
## 1.0 s since round 749's verification (FP4), down from 1.5: the stop it
## sends lies up to this much run from the server's anchor, and the server's
## claim bound grants one slack (9) plus AllowanceSeconds (1.0) of run banked
## while standing (server/internal/world/claim.go). At 1.5 s a lag spike past
## 1.0 s made an honest stop exceed it and be corrected. Raising the
## allowance to 2.0 s instead would let every client, honest or not, bank a
## second more of free movement on every stop and placement; lowering the
## timeout costs only an honest player whose echo takes over 1 s an early
## stop, which the next click resumes.
const ECHO_TIMEOUT_MS := 1000

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
## The server point the last correction was answered at (Vector3.INF: none
## answered since the last order).
var answered := Vector3.INF

## Round 846: until when (ms) the server may still be walking the last
## destination sent -- its echo's time plus the leg's length at the run speed
## (confirm), or ECHO_TIMEOUT_MS after the send while no echo has come; 0 when
## the server has no destination leg (a stop, a placement, a heading run).
var server_free_ms := 0
## Round 846: a new point within NEAR_DESTINATION of that destination, held
## back until server_free_ms (Vector3.INF: none held).
var held := Vector3.INF

## Round 863: the destination the original's own mover holds -- the one the
## ground click's filter measures a new click against (RemoteFacing.click_rule's
## "snap"). READ: UI_SILKMALL::FUN_009eb2a0 compares the click with the
## mover's destination (player +0x684 = mover +0x1c, the record FUN_009e0550
## writes), and the mover takes it from this player's own 0xB021 (0x8a5750 ->
## FUN_009e0550) or from the snap's local re-aim (FUN_009e04b0), never from
## the click itself: until its echo comes, a click is measured against the
## order before it. This client walks its click at once (OURS, round 749), so
## the click's point is not the mover's. Set by every destination echo
## (confirm) and by a snap (mover_snapped); a heading echo or a stop or
## placement (the server's 0xB023, FUN_008a4f80 -> FUN_009e00f0 clears the
## order) clears it; an arrival does not (FUN_009e0e60 clears +0x84 only).
var mover_dest := Vector3.INF

## The tick's decision for the order in effect (has_order, the walk's point
## `target` and that point as the wire truncates it, `qtarget`; or a heading
## run with `wire`) and the player at `pos`, at now_ms.
##
## Round 846 adds "held": send the held point (the walk to it has ended).
## OURS (the reason): this client walks its click at once, while the server
## starts the leg one transit later, so its walk ends before the server's. A
## click near the point just reached, sent at once, reached the server while
## its leg still ran and was refused (READ, within 5.0 of the destination
## while moving, 0xb45b28), silently -- the others never saw the step and,
## a second later (ECHO_TIMEOUT_MS), saw the stop put the player there in
## one jump (MEASURED, docs/WORLD_ISSUES.md round 846). Such a point goes out
## once the server's leg is over instead.
func decide(has_order: bool, run: bool, target: Vector3, qtarget: Vector3, wire: int, pos: Vector3, now_ms: int) -> String:
	if pending_ms >= 0 and now_ms - pending_ms > ECHO_TIMEOUT_MS:
		pending_ms = -1
		held = Vector3.INF
		return "unconfirmed"
	if held != Vector3.INF:
		if has_order and run:
			held = Vector3.INF # a run replaced the walk
		elif now_ms < server_free_ms:
			return ""
		elif has_order:
			held = Vector3.INF
			return "dest"
		else:
			return "held"
	if has_order:
		if run:
			if not active or not heading_run or wire != heading_wire:
				return "heading"
			return ""
		if active and not heading_run:
			return "dest" if _flat(qtarget - dest) > NEAR_DESTINATION else ""
		if _flat(target - pos) < MIN_ORDER:
			return ""
		if now_ms < server_free_ms and rest != Vector3.INF and _flat(qtarget - rest) <= NEAR_DESTINATION:
			held = qtarget
			return ""
		return "dest"
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
	answered = Vector3.INF
	active = true
	heading_run = false
	dest = sent_dest
	heading_wire = -1
	pending_ms = now_ms
	held = Vector3.INF
	# Round 846: until its echo says how long the leg is, the server may be
	# walking it for as long as the echo may take.
	server_free_ms = now_ms + ECHO_TIMEOUT_MS

## A heading form went out at now_ms.
func sent_heading(wire: int, now_ms: int = 0) -> void:
	answered = Vector3.INF
	active = true
	heading_run = true
	heading_wire = wire
	dest = Vector3.INF
	pending_ms = now_ms
	held = Vector3.INF
	server_free_ms = 0 # a heading leg refuses no destination (destmove.go)

## This player's own 0xB021 came (kind, its destination in world coordinates,
## its heading form's angle): it confirms the last order when it names it. An
## echo of an older order (superseded) confirms nothing.
##
## Round 846: `free_ms` (-1: unknown) is when the server's leg to that
## destination is over at the latest -- the echo's arrival plus the leg's
## length at the run speed (the server started the leg before it sent the
## echo); a near point held back (decide) goes out then. It is taken even when
## the walk here already ended (arrived) before the echo came.
func confirm(kind: int, echo_dest: Vector3, angle: int, free_ms: int = -1) -> void:
	# Round 863: every echo is the mover's (FUN_009e0550 takes it whatever
	# came after; a heading form has no point).
	mover_dest = Vector3.INF if kind == DestMoveNet.KIND_HEADING else echo_dest
	if free_ms >= 0 and kind != DestMoveNet.KIND_HEADING and not heading_run \
			and dest != Vector3.INF and _flat(echo_dest - dest) < 0.01:
		server_free_ms = free_ms
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
	# Round 749's verification: an echo still awaited for an order that has
	# ended is not awaited any more (the next tick would otherwise take the
	# ended order as refused and send a stop).
	pending_ms = -1

## A stop or placement went out, or the server placed the player (its own
## 0xB023): the server has the player at `at`, with no leg.
func placed(at: Vector3) -> void:
	active = false
	heading_run = false
	heading_wire = -1
	dest = Vector3.INF
	mover_dest = Vector3.INF
	rest = at
	pending_ms = -1
	# Round 846: the server has no leg now (a stop, a placement); a point the
	# walk still holds back goes out at once.
	server_free_ms = 0

## The server's correction (its own 0xB023 for this player) put the player at
## `at`, with no leg. Returns whether the client answers it with a stop there
## (round 749's verification, FP1-FP3): only when a 0x7021 may still be in
## flight -- sent, and its echo not yet come -- which the server would take
## after the correction and start a leg from there that this client does not
## walk; and never twice for the same server point. Any other correction is
## the server's last word: answering it with a stop could only be corrected
## again, which is how the 1d06b4ab client looped.
func corrected(at: Vector3) -> bool:
	var in_flight := pending_ms >= 0
	var again := answered != Vector3.INF and at.distance_to(answered) < 0.01
	placed(at)
	held = Vector3.INF # the player stands where the server put it
	if in_flight and not again:
		answered = at
		return true
	return false

## Round 863: a click the filter called "snap" re-aimed the mover at `point`
## locally (FUN_009e04b0 writes the destination record, READ).
func mover_snapped(point: Vector3) -> void:
	mover_dest = point

static func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
