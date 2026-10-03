extends RefCounted
class_name SitState

## The local player's sit state (round 607; docs/protocol/opcodes/motion.md):
## what this client believes about its own motion, and what it must tell the
## server so the two agree. Pure, so a headless test holds every rule to
## account; World3D (_request_sit_toggle, _on_state_changed,
## _leave_sit_by_moving, _physics_step's movement lock and send gate) is the
## glue. Times are in seconds on any one clock the caller keeps.
##
## THE SERVER'S RULES THIS MIRRORS (read, SR_GameServer.exe):
##   - N (0x704f [04]) is answered only by the 0x30bf broadcast; a refused
##     request has no answer at all.
##   - After it accepts, it refuses a move for 1.5 s (CHANGEMOTION).
##   - A move while seated is accepted and stands the character at once.
##
## OURS: how long an unanswered N holds movement and counts as "mine"
## (REQUEST_WAIT); learning this player's own id from the answer to its own N,
## because the enter-world result does not carry it.

## The server's transition, .rdata 0x00b45c10 = 1.5 s (WorldNet.MOTION_CHANGE_SECONDS).
const CHANGE_SECONDS := 1.5
## How long an unanswered N holds movement and may teach this player's id. Ours.
const REQUEST_WAIT := 1.0

## Whether the server has told this player it sits.
var sitting := false
## Until when movement is held (the transition after an answer).
var lock_until := 0.0
## When the last N went out, or -1.
var request_sent_at := -1.0
## This player's server id, learned from the answer to its own N; -1 until then.
var own_id := -1

## A request is out and not yet answered or expired.
func request_pending(now: float) -> bool:
	return request_sent_at >= 0.0 and now - request_sent_at < REQUEST_WAIT

## Movement (input and position sends) is held: a request in flight, or the
## server's transition.
func locked(now: float) -> bool:
	return request_pending(now) or now < lock_until

## N pressed. False when the press must do nothing (a request in flight, the
## transition); true when the request is to be sent now.
func press(now: float) -> bool:
	if locked(now):
		return false
	request_sent_at = now
	return true

## Whose 0x30bf this is. "other" when the id is a body this client draws,
## "self" when it is this player's (learning the id from the answer to a
## pending N), "unknown" otherwise -- including an answer that arrives after a
## request has expired, which is not taken as this player's.
func classify(object_id: int, is_other_body: bool, now: float) -> String:
	if is_other_body:
		return "other"
	if own_id == -1 and request_pending(now):
		own_id = object_id
	return "self" if object_id == own_id else "unknown"

## The server's answer for this player: value 4 sits, 0 stands. Returns
## "sit_down" (play 13 then the loop), "sit" (the loop only), "stand_up" (play
## 15), "stand" (nothing to play) or "" for a value OpenSRO does not play.
func answer(value: int, now: float) -> String:
	request_sent_at = -1.0
	var was := sitting
	match value:
		4:
			sitting = true
			lock_until = now + CHANGE_SECONDS
			return "sit" if was else "sit_down"
		0:
			sitting = false
			lock_until = now + CHANGE_SECONDS
			return "stand_up" if was else "stand"
	return ""

## The body is about to move while seated. The server stands a seated
## character on its first accepted move, so the move must reach it at once --
## returns true when the caller must send its position now (it may not have
## moved far enough for the ordinary send gate yet). The sit ends here either
## way; the server's answer is the move itself.
func leave_by_moving() -> bool:
	if not sitting:
		return false
	sitting = false
	return true

## Back to standing with nothing pending: entering the world, a zone change, a
## death.
func reset() -> void:
	sitting = false
	lock_until = 0.0
	request_sent_at = -1.0
