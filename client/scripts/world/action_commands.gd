extends RefCounted
class_name ActionCommands

## What each action-window button does (round 781): retail's dispatcher
## GInterfaceSend::FUN_00793b00(owner, id), the one both the action window's
## right click (CIFSlotWithHelp vslot 33 -> 0x682040, slot kind 0x4a) and a
## quick slot holding an action (0x60b850, kind 0x4a -> 0x60bace) call, and
## what OpenSRO does in its place. Pure, so a headless test holds the table.
##
## READ (0x793b00's switch on the id):
##   1000 sit/stand        0x9d4a20: 0x704f [04] unless client state bit 2
##                         (+0x65c) or a stall (+0x78c)
##   1001 walk/run         0x9d4a00: 0x704f [02] while running (+0x25d != 0),
##                         else [03]
##   1002 auto attack      0x792f00, the object click, on the selection
##                         (+0x628) when it exists
##   1003 trace            0x7074 [01 03 01 <u32 selection>]
##   1004 auto run         no case: the switch's exit label is case 0x3ec
##   1005 auto select      0x9d3340: the nearest object of the list 0xec4d50
##                         strictly within 70.0 (.rdata 0xd990a8, 3-D) ->
##                         0x78f5f0, the select request
##   1006 exchange         SendTradeMsg_081(0) (0x81d790)
##   1007 party            the main popup's party tab, then 0x6d5970 (the
##                         party window's Invite)
##   1008 auto grab        0x9e18f0, the G key's pick
##   1009 stall            the stall window (0x6bafb0 / 0x6baeb0) after its
##                         gates (premium avatar shop, 0x3c3b, 0x5416, 0x1834)
##   1010 alchemy          0x798e20, the alchemy window
##   1011 helper           toggles bit 2 of 0x9db080's flags, 0x7402 [flags]
##   1012 auto potion      0x79c750(1)
##   1014 academy          0x79af70
##   1015 fortress return  a guild fortress's return (0x93a610 / 0x822970),
##                         messages 0x7c07 / 0x7c08
##   1016 party matching   0x79c170, the party matching window
##   1017 free PvP         0x9d7100, the free battle PvP status window
##   4000..4006 emotes     0x3091 [byte] (EMOTE_BYTE)
##   5000 charm            a COS command, 0x70c5 [cos id, 0x0b]
##
## OURS: an action whose system OpenSRO lacks writes UNSUPPORTED's line to the
## system window instead of doing nothing (the user's request, round 781).

const SIT := 1000
const WALK_RUN := 1001
const AUTO_ATTACK := 1002
const TRACE := 1003
const AUTO_RUN := 1004
const AUTO_SELECT := 1005
const EXCHANGE := 1006
const PARTY := 1007
const AUTO_GET := 1008
const STALL := 1009
const ALCHEMY := 1010
const HELPER := 1011
const AUTO_POTION := 1012
const ACADEMY := 1014
const FORT_RETURN := 1015
const PARTY_MATCH := 1016
const FREE_PVP := 1017
const CHARM := 5000

## The byte 0x3091 carries for each emote (READ, 0x793b00): note 4001 is 6,
## not 1. The animation is action type 0x32 + the byte (ANI_EMOTION01..,
## state 0xd's entry 0xa59bc0, READ).
const EMOTE_BYTE := {4000: 0, 4001: 6, 4002: 1, 4003: 5, 4004: 2, 4005: 3, 4006: 4}
const EMOTE_ANIMATION_BASE := 0x32

## Auto Select's reach (READ, .rdata 0xd990a8 = 70.0; strict, 3-D).
const AUTO_SELECT_RANGE := 70.0

## The request bytes of 0x704f (READ, FUN_004b1480's switch).
const MOTION_WALK := 2
const MOTION_RUN := 3

## The panel each window action opens (HudPanels ids).
const PANELS := {ALCHEMY: "alchemy", AUTO_POTION: "autopotion", ACADEMY: "academy", PARTY_MATCH: "partymatch"}

## The system line for an action OpenSRO has no system for (OURS).
const UNSUPPORTED := {
	AUTO_RUN: "Auto Run does nothing in the original client either.",
	HELPER: "The helper mark is not available yet on this server.",
	FORT_RETURN: "Fortress return is not available yet: this server has no fortress war.",
	FREE_PVP: "Free PvP is not available yet on this server.",
	CHARM: "Pets are not available yet on this server.",
}

## What OpenSRO does for an action id: {"kind": ..., ...}.
##   sit, walk_run, auto_attack, auto_select, exchange, party, auto_get, trace
##   panel     {"panel": HudPanels id}
##   emote     {"emote": the 0x3091 byte}
##   unsupported {"line": the system line}
##   unknown   (no such action)
static func plan(id: int) -> Dictionary:
	if EMOTE_BYTE.has(id):
		return {"kind": "emote", "emote": int(EMOTE_BYTE[id])}
	if PANELS.has(id):
		return {"kind": "panel", "panel": String(PANELS[id])}
	if UNSUPPORTED.has(id):
		return {"kind": "unsupported", "line": String(UNSUPPORTED[id])}
	match id:
		SIT:
			return {"kind": "sit"}
		WALK_RUN:
			return {"kind": "walk_run"}
		AUTO_ATTACK:
			return {"kind": "auto_attack"}
		AUTO_SELECT:
			return {"kind": "auto_select"}
		EXCHANGE:
			return {"kind": "exchange"}
		STALL:
			# Round 839: the stall (StallController.start after World3D's gates).
			return {"kind": "stall"}
		PARTY:
			return {"kind": "party"}
		AUTO_GET:
			return {"kind": "auto_get"}
		TRACE:
			return {"kind": "trace"}
	return {"kind": "unknown"}

## The 0x704f byte the Walk/Run button sends (0x9d4a00, READ): 2 (walk) while
## running, 3 (run) while walking.
static func walk_run_request(running: bool) -> int:
	return MOTION_WALK if running else MOTION_RUN

## The body action type an emote byte plays (READ, 0xa59bc0: 0x32 + byte).
static func emote_animation(emote: int) -> int:
	return EMOTE_ANIMATION_BASE + emote

## Auto Select's pick (0x9d3340, READ): the id of the candidate strictly
## nearest `from` in 3-D and strictly within AUTO_SELECT_RANGE, or -1.
## `candidates` maps an id to its Vector3 position. A tie keeps the first met
## (the engine replaces only on a strictly smaller distance).
static func nearest_within(from: Vector3, candidates: Dictionary, reach: float = AUTO_SELECT_RANGE) -> int:
	var best := -1
	var best_d := reach
	for id in candidates:
		var d := from.distance_to(candidates[id] as Vector3)
		if d < best_d:
			best_d = d
			best = int(id)
	return best
