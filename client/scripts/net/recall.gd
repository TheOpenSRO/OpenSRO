extends RefCounted
class_name RecallNet

## The town gates' "Designate as return/recall point" (round 686), mirroring
## server/internal/session/recall.go: the client names the gate the player is
## talking to (its teleportdata id, as TeleportNet does) and the server
## answers in retail's 0xb059 shape -- u8 1, or u8 2 and a u16 code.
##
## READ (docs/protocol/teleport_network.md, "The return point (round 686)"):
## the talk line (item 9, UIIT_CTL_RECALL_POSITION) opens message box kind 5
## (CIF_NPCTalk::FUN_007020c0 case 9, 0x7027b5), titled UIIT_STT_AGREEMENT_BOX
## with UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS ("The current position : [%s]", the
## current region's zone name) over UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY
## (UI_SILKMALL::FUN_00644c90, entry 0x644f93); its OK sends retail's 0x7059
## (FUN_00797d90 case 5). The reply's handler (Client_OnDesignateRecallResult) shows
## UIIT_MSG_STATE_REBIRTH_POINT_APPOINT on 1 -- the system window as type 5
## and GDR_WARNING_WND -- and nothing on 2.
##
## srrevamp's own placeholder pair (docs/protocol/PROTOCOL_DECISION.md);
## 0x0111/0x0112 were free on 2026-10-02 (the highest op in client/scripts/net
## was UniqueNoticeNet's 0x0110). Retail's are 0x7059 / 0xb059.

const OP_DESIGNATE := 0x0111         # client -> server
const OP_DESIGNATE_RESULT := 0x0112  # server -> client, the requester

## The reply's result byte (retail's envelope).
const RESULT_OK := 1
const RESULT_REFUSED := 2

## The text keys the box and the confirmation use, all from the player's own
## textuisystem.txt (the fallbacks are its English column).
const TITLE_STRID := "UIIT_STT_AGREEMENT_BOX"
const CURPOS_STRID := "UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS"
const ASK_STRID := "UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY"
const DONE_STRID := "UIIT_MSG_STATE_REBIRTH_POINT_APPOINT"
const TITLE_FALLBACK := "Agreement window"
const CURPOS_FALLBACK := "The current position : [%s]"
const ASK_FALLBACK := "Will you designate the place to be returned /resurrected?"
const DONE_FALLBACK := "Resurrection spawn point has changed."

## The server's answer, decoded.
class Result:
	var ok: bool = false
	## The refusal's code: IsWithinInteractionRange's 3 (not a gate, or not
	## in a neighbouring region) or 4 (too far), or 0 (no such gate).
	var code: int = 0

## Encodes an OpRecallDesignate: the gate's teleportdata id, one u16 LE --
## the two bytes DecodeRecallDesignateRequest reads.
static func encode_designate(gate_id: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, gate_id)
	return out

## Decodes an OpRecallDesignateResult: {1}, or {2, u16 code}. null for any
## other shape rather than a guess.
static func decode_result(data: PackedByteArray) -> Result:
	if data.size() == 1 and data[0] == RESULT_OK:
		var r := Result.new()
		r.ok = true
		return r
	if data.size() == 3 and data[0] == RESULT_REFUSED:
		var r := Result.new()
		r.code = data.decode_u16(1)
		return r
	return null

## The box's "current position" line: the archive's template filled with the
## zone name, when the template holds exactly one %s; else the fallback.
static func current_position_line(template: String, zone_name: String) -> String:
	var t := template.strip_edges()
	if t == "" or t == CURPOS_STRID or t.count("%") != 1 or t.find("%s") < 0:
		t = CURPOS_FALLBACK
	return t % zone_name
