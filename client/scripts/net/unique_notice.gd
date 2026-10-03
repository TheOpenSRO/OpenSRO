extends RefCounted
class_name UniqueNoticeNet

## The unique monster notices (round 657): "Tiger Girl has appeared on Tiger
## Mountain." when a unique appears and "[Name] killed Tiger girl from Tiger
## Mountain." when one dies. Mirrors server/internal/session/uniquenotice.go;
## docs/protocol/unique_notice.md has the whole read.
##
## The payload is retail 0x300C's: a u16 word (0x0C05 appeared, 0x0C06
## killed), the monster's u32 RefObjID and, for a kill, the killer's name
## (u16 length + bytes). The opcode is OpenSRO's own (PROTOCOL_DECISION.md).
##
## READ, the handler 0x874ea0 (sro_client.exe): the line is chosen by the
## monster's name key -- its characterdata SN_ string (the object's +0x60) --
## compared with five keys, and every line goes BOTH to the system window
## (0x7781b0 with type 0: colour 0xffdbc99b) AND to GDR_WARNING_WND, the blue
## banner (0x77b580 -> child 0x23 -> 0x7b3eb0). See line_for.

const OP_UNIQUE_NOTICE := 0x0110  # server -> every character in the world

const KIND_SPAWN := 0x0C05
const KIND_KILL := 0x0C06

## What the server calls a killer that is not a live player (READ:
## SR_GameServer.exe 0xaedda4); the handler compares with its own "???"
## (0xdda02c) to choose the DEAD_ ("... has disappeared") lines.
const UNKNOWN_KILLER := "???"

## The system window's type for the line (READ: `push 0` / `push ebp` with
## ebp 0 before each 0x7781b0 call in 0x874ea0) -- HudSystemMessage's
## TYPE_ALWAYS, drawn in 0xffdbc99b.
const SYSTEM_TYPE := 0

## The five uniques the handler names, by their SN_ key (READ: the wide
## strings at 0xdda1f4, 0xdda194, 0xdda140, 0xdda0e8, 0xdda090), with the
## appearance line, the "killed by nobody" line and the "killed by [%s]" line
## each takes. Tahomet has no DEAD_ line of its own: with the "???" killer it
## takes UIIT_MSG_DEAD_UNIC with its own name (0x87572e..0x8757ba).
const NAMED := {
	"SN_MOB_CH_TIGERWOMAN": ["UIIT_MSG_APPEAR_TIGER_GIRL", "UIIT_MSG_DEAD_TIGER_GIRL", "UIIT_MSG_ANYONE_DEAD_TIGER_GIRL"],
	"SN_MOB_KK_ISYUTARU": ["UIIT_MSG_APPEAR_IYUTARU", "UIIT_MSG_DEAD_IYUTARU", "UIIT_MSG_ANYONE_DEAD_IYUTARU"],
	"SN_MOB_OA_URUCHI": ["UIIT_MSG_APPEAR_URRUCHI", "UIIT_MSG_DEAD_URRUCHI", "UIIT_MSG_ANYONE_DEAD_URRUCHI"],
	"SN_MOB_TK_BONELORD": ["UIIT_MSG_APPEAR_BONELORD", "UIIT_MSG_DEAD_BONELORD", "UIIT_MSG_ANYONE_DEAD_BONELORD"],
	"SN_MOB_RM_TAHOMET": ["UIIT_MSG_APPEAR_TAHOMET", "", "UIIT_MSG_ANYONE_DEAD_TAHOMET"],
}
const APPEAR_UNIC := "UIIT_MSG_APPEAR_UNIC"
const DEAD_UNIC := "UIIT_MSG_DEAD_UNIC"
const ANYONE_DEAD_UNIC := "UIIT_MSG_ANYONE_DEAD_UNIC"

## Result of decode().
class Notice:
	var kind: int
	var ref_obj_id: int
	var killer: String

## Parses an OP_UNIQUE_NOTICE payload, or null when it is malformed.
static func decode(data: PackedByteArray) -> Notice:
	if data.size() < 6:
		return null
	var n := Notice.new()
	n.kind = data.decode_u16(0)
	n.ref_obj_id = data.decode_u32(2)
	if n.kind == KIND_SPAWN:
		if data.size() != 6:
			return null
		return n
	if n.kind != KIND_KILL or data.size() < 8:
		return null
	var name_len := data.decode_u16(6)
	if 8 + name_len != data.size():
		return null
	n.killer = data.slice(8, 8 + name_len).get_string_from_utf8()
	return n

## The line 0x874ea0 shows for `n`. `name_key` is the monster's SN_ key
## (characterdata), `monster_name` what that key resolves to, and `text` looks
## a UIIT_ key up in the UI text table ("" when it has none). The branches:
##
##   appeared (0x0C05, 0x8752ad..0x8754da):
##     a named key          -> its APPEAR_ line as it stands
##     any other            -> APPEAR_UNIC with the monster's name
##   killed (0x0C06, 0x8754df..0x875849):
##     named, killer "???"  -> its DEAD_ line as it stands
##     named, a killer      -> its ANYONE_DEAD_ line with the killer's name
##     Tahomet, "???"       -> DEAD_UNIC with Tahomet's name
##     any other, "???"     -> DEAD_UNIC with the monster's name
##     any other, a killer  -> ANYONE_DEAD_UNIC with the killer, then the monster
##
## The comparisons are exact: an _L2 or _L3 row (SN_MOB_CH_TIGERWOMAN_L2) is
## not the named one and takes the generic lines.
static func line_for(n: Notice, name_key: String, monster_name: String, text: Callable) -> String:
	var named: Array = NAMED.get(name_key, [])
	if n.kind == KIND_SPAWN:
		if not named.is_empty():
			return String(text.call(named[0]))
		return sprintf(String(text.call(APPEAR_UNIC)), [monster_name])
	var nobody := n.killer == UNKNOWN_KILLER
	if not named.is_empty():
		if nobody:
			if String(named[1]) == "":
				return sprintf(String(text.call(DEAD_UNIC)), [monster_name])
			return sprintf(String(text.call(named[1])), [])
		return sprintf(String(text.call(named[2])), [n.killer])
	if nobody:
		return sprintf(String(text.call(DEAD_UNIC)), [monster_name])
	return sprintf(String(text.call(ANYONE_DEAD_UNIC)), [n.killer, monster_name])

## The UIIT_ keys line_for reads for `n` (a test and log aid).
static func keys_for(n: Notice, name_key: String) -> String:
	var named: Array = NAMED.get(name_key, [])
	if n.kind == KIND_SPAWN:
		return String(named[0]) if not named.is_empty() else APPEAR_UNIC
	var nobody := n.killer == UNKNOWN_KILLER
	if not named.is_empty():
		if nobody:
			return String(named[1]) if String(named[1]) != "" else DEAD_UNIC
		return String(named[2])
	return DEAD_UNIC if nobody else ANYONE_DEAD_UNIC

## swprintf's %s, in order, and %% as a percent: the handler formats every
## template with _swprintf_s (0xb434fc) into a 0x200-character buffer.
## A template with fewer %s than arguments leaves the rest unused, as
## swprintf does.
static func sprintf(template: String, args: Array) -> String:
	var out := ""
	var used := 0
	var i := 0
	while i < template.length():
		var ch := template[i]
		if ch == "%" and i + 1 < template.length():
			var nx := template[i + 1]
			if nx == "s" or nx == "S":
				out += String(args[used]) if used < args.size() else ""
				used += 1
				i += 2
				continue
			if nx == "%":
				out += "%"
				i += 2
				continue
		out += ch
		i += 1
	return out.substr(0, 0x1ff)
