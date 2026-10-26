extends RefCounted
class_name ActionNet

## Round 832: the character action request 0x7074 and its answer 0xB074, as
## far as OpenSRO uses them (the trace), and the Extra tab's ping (OURS).
##
## READ, sro_client.exe:
##   - The trace: GInterfaceSend::FUN_00793b00 case 1003 sends
##     0x7074 [01 03 01 <u32 selection, GI+0x628>] (0x793c1d..0x793c62).
##   - The cancel: 0x7074 [02], from the ground click 0x78f8d0 when the
##     action byte GI+0x620 is not 0 and below 2.
##   - The answer FUN_00880b60: {u8 result, u8 depth}, a u16 code after a
##     result of 3. The depth goes to GI+0x620 (FUN_00778c30); a result of 3
##     calls FUN_00778190(0x19, code, ...), the system window's line for the
##     code (the switch at 0x7baf0d); nothing else is shown for a start or an
##     end.
## READ, SR_GameServer.exe: docs/protocol/trace.md (server/internal/session/trace.go).

const OP_ACTION_REQUEST := 0x7074
const OP_ACTION_RESULT := 0xB074

const CMD_START := 1
const CMD_CANCEL := 2
const KIND_TRACE := 3
## The context's target type for an object (READ, the 01 before the uid).
const TARGET_OBJECT := 1

const RESULT_STARTED := 1
const RESULT_ENDED := 2
const RESULT_ERROR := 3

## The action byte at or above which the client sends no action and no
## cancel (READ, FUN_0077c9b0: GI+0x620 >= 2).
const BUSY_DEPTH := 2

## Category 0x19's lines (READ, 0x7baf0d, jump table 0x7bbf34): 0x4001 and
## 0x4002 UIIT_SKILL_USE_FAIL_SEALED, 0x4005 UIIT_MSG_COS_BAN_FOLLOW_COS;
## 0x4003 and 0x4004 show nothing. Another code's line is OPEN (the default
## path looks up an empty key), so none is shown.
const ERROR_LINES := {
	0x4001: "UIIT_SKILL_USE_FAIL_SEALED",
	0x4002: "UIIT_SKILL_USE_FAIL_SEALED",
	0x4005: "UIIT_MSG_COS_BAN_FOLLOW_COS",
}

## The Extra tab's ping (OURS, server/internal/session/ping.go).
const OP_PING := 0x00FC
const OP_PING_ECHO := 0x00FD

static func encode_trace(target: int) -> PackedByteArray:
	var out := PackedByteArray([CMD_START, KIND_TRACE, TARGET_OBJECT, 0, 0, 0, 0])
	out.encode_u32(3, target & 0xffffffff)
	return out

static func encode_cancel() -> PackedByteArray:
	return PackedByteArray([CMD_CANCEL])

## {result, depth, code}; empty when short.
static func decode_result(data: PackedByteArray) -> Dictionary:
	if data.size() < 2:
		return {}
	var out := {"result": int(data[0]), "depth": int(data[1]), "code": 0}
	if out["result"] == RESULT_ERROR:
		if data.size() < 4:
			return {}
		out["code"] = data.decode_u16(2)
	return out

static func encode_ping(token: int) -> PackedByteArray:
	var out := PackedByteArray([0, 0, 0, 0])
	out.encode_u32(0, token & 0xffffffff)
	return out

## The echoed token, or -1.
static func decode_ping_echo(data: PackedByteArray) -> int:
	return data.decode_u32(0) if data.size() == 4 else -1
