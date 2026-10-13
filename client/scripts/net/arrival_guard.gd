class_name ArrivalGuard
extends RefCounted
## Round 786 (part): the protection after a teleport, the client's half.
## docs/protocol/arrival_guard.md has the whole sequence with its addresses.
##
## The loading-done report (READ, sro_client.exe): retail's 0x3012
## (SR_READY_TO_PLAY) is sent by FUN_0084c060, CPSMission's per-frame loading
## step (reached through CPSMission::vslot_012, 0x84c300). That step returns
## until +0xe5 says the zone is in -- set by FUN_0084ab50 (0x8ab272) at the
## end of the 0x34a6 handler, after the own player was built and the region
## and its 3x3 neighbours loaded around it (CICPlayer::vslot_027 0x9d53d0 ->
## CGWorld::FUN_00aa2190) -- then removes the loading screen's windows
## (0x84c0e5..0x84c11b) and sends 0x3012 (0x84c1b1..0x84c208), once. There is
## no timer and no minimum display time on that gate. The server holds the
## character out of the world until it (CGame::EnterWorld 0x417240 inserts it
## into its block on that message).
##
## OpenSRO's load ends in World3D._drain_initial_load (the zone's cells built,
## the screen lifted); the report is armed by each arrival (an enter-world
## result, a zone change's result) and sent there, once, when nothing is left
## to build and no screen is up (ReadyReport below).
##
## The body mode 2 the server then sets for 6.0 s (CGObjPC::vslot_391) is
## shown as retail shows it: nothing on the body (SetBodyMode 0x9cf880 changes
## no alpha, effect or colour for mode 2, READ), the screen flash for this
## player on any non-zero mode (the 0x30BF handler's `test bl,bl` at 0x8a826f,
## then 0xa42d20 with (255, 255, 255, 128), 0.2 s up and 0.5 s back), and the
## client's own refusals: every skill (FUN_0081ba10, own +0x2c2 == 2 at
## 0x81ba58) and a normal attack on a player (0x791fda) are refused with
## category 4 code 0x3020 -- UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_TEMPORARILY
## outside a fortress (0x7b99f3) -- and nothing is sent. A normal attack on a
## monster is not checked on the client; the server refuses it (0x529240).

## 0x30BF kind 4's protection value (READ: vslot_391's SetBodyMode(2, ...)).
const BODY_MODE_UNTOUCHABLE := 2

## The refusal's text key (READ, 0x7b99f3; the text is the player's own
## textuisystem.txt, read at runtime).
const REFUSAL_KEY := "UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_TEMPORARILY"

## The server's refusal of an attack, a skill or a duel blow for the
## protection (server/internal/session/arrival.go untouchableRefusal, OURS
## wording; shown as REFUSAL_KEY's text).
const SERVER_REFUSAL := "cannot attack while untouchable"

## OURS: the words when the archive has no REFUSAL_KEY.
const FALLBACK_TEXT := "You cannot attack or be attacked for a moment after arriving."

## Whether this player's own skill use is refused in body mode `own_mode`
## (READ, FUN_0081ba10 at 0x81ba58).
static func refuses_skill(own_mode: int) -> bool:
	return own_mode == BODY_MODE_UNTOUCHABLE

## Whether this player's normal attack on a PLAYER is refused (READ,
## SendMagicStateMsg_074_791d40 at 0x791fda). On a monster it is sent.
static func refuses_attack_on_player(own_mode: int) -> bool:
	return own_mode == BODY_MODE_UNTOUCHABLE

## Whether a body-mode change flashes the screen: this player's, any non-zero
## value (READ, `test bl,bl` at 0x8a826f).
static func flashes(own: bool, value: int) -> bool:
	return own and value != 0

## The refusal's line: the archive's REFUSAL_KEY text, else FALLBACK_TEXT.
static func refusal_text(table) -> String:
	if table != null and table.has(REFUSAL_KEY):
		var text: String = String(table.get_text(REFUSAL_KEY)).strip_edges()
		if text != "" and text != REFUSAL_KEY:
			return text
	return FALLBACK_TEXT

## The line for an attack result's error: the protection's refusal in the
## archive's words, anything else as it came.
static func error_line(error: String, table) -> String:
	if error == SERVER_REFUSAL:
		return refusal_text(table)
	return error

## The loading-done report's gate: armed by an arrival, sent once when the
## load is over. `send` is the network call (NetClient.report_ready_to_play).
class ReadyReport:
	extends RefCounted
	var armed := false
	var sent := 0
	var why := ""
	var send: Callable

	func _init(sender: Callable = Callable()) -> void:
		send = sender

	## An arrival whose load is to come: the enter-world result, a zone
	## change's (or a teleport's) result.
	func arm(reason: String) -> void:
		armed = true
		why = reason

	## The load's end: sends 0x3012 when armed, the screen is down and no cell
	## is left to build -- FUN_0084c060's order: the windows go, then the send.
	## Returns whether it sent.
	func loading_done(screen_up: bool, cells_left: int) -> bool:
		if not armed or screen_up or cells_left > 0:
			return false
		armed = false
		sent += 1
		if send.is_valid():
			send.call()
		return true
