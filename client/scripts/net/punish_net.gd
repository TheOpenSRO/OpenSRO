extends RefCounted
class_name PunishNet

## Round 840 (lane B): a GM's chat or trade ban answering a request. READ from
## SR_GameServer.exe (s:) and sro_client.exe (c:); docs/protocol/stall.md
## and server/internal/session/restriction.go have the reading.
##
## - 0x3405 {u8 kind, u32 packed end}: kind 0 the chat ban (restriction slot
##   4), 1 the trade ban (slot 3), sent by FUN_004f0a00 (s:0x4f0a00) when the
##   request it guards is dropped -- a chat line, the global chatting item,
##   the exchange request, the stall's open and enter, the chat-banned
##   owner's stall name.
## - The end is PackSystemTime's (s:0x4f8860): year - 2000 (6 bits), month
##   (4), day (5), hour (5), minute (6), second (6).
## - The client (c:0x86e5b0) formats UIIT_MSG_GM_PUNISHMENT_CHAT_BLOCK (kind
##   0) or UIIT_MSG_GM_PUNISHMENT_TRADE_BLOCK (kind 1) with swprintf: year
##   + 2000, month, day, UIIT_STT_LETTER_FORENOON for an hour below 12 else
##   UIIT_STT_LETTER_AFTEMOON, the hour less 12 above 12 (12 stays 12), the
##   minute; then shows it in GDR_WARNING_WND (0x77b580) and as a system line
##   of type 5 (0x7781b0). Another kind shows nothing.
## - MEASURED on the box's Media.pk2: textuisystem.txt spells the trade row's
##   key "UIIT_MSG_GM_PUNISHMENT_TRADE _BLOCK" (a space before _BLOCK), so
##   the client's lookup of the right key misses and resolves to its empty
##   string (FUN_008c9b20 -> c:0xec3b70): a trade ban shows nothing with that
##   archive. This client does the same (text() returns ""), and shows the
##   line when an archive spells the key right.

const OP_RESTRICTION := 0x3405

const KIND_CHAT := 0
const KIND_TRADE := 1

const KEYS := {
	KIND_CHAT: "UIIT_MSG_GM_PUNISHMENT_CHAT_BLOCK",
	KIND_TRADE: "UIIT_MSG_GM_PUNISHMENT_TRADE_BLOCK",
}
const FORENOON_KEY := "UIIT_STT_LETTER_FORENOON"
const AFTERNOON_KEY := "UIIT_STT_LETTER_AFTEMOON"
## The system line's type (0x7781b0(5, ..)), HudSystemMessage.TYPE_GAME.
const SYSTEM_TYPE := 5

## {kind, packed, year, month, day, hour, minute, second}, or {} when short.
static func decode(data: PackedByteArray) -> Dictionary:
	if data.size() < 5:
		return {}
	var v := data.decode_u32(1)
	return {
		"kind": int(data[0]), "packed": v,
		"year": (v & 0x3f) + 2000, "month": (v >> 6) & 0xf, "day": (v >> 10) & 0x1f,
		"hour": (v >> 15) & 0x1f, "minute": (v >> 20) & 0x3f, "second": (v >> 26) & 0x3f,
	}

## The line c:0x86e5b0 shows for d. `resolve` maps a text key to its text,
## "" when the archive lacks it (the client's empty string). "" shows nothing.
static func text(d: Dictionary, resolve: Callable) -> String:
	var key := String(KEYS.get(int(d.get("kind", -1)), ""))
	if key == "":
		return ""
	var fmt := String(resolve.call(key))
	if fmt == "":
		return ""
	var hour := int(d["hour"])
	var forenoon := hour <= 11
	if hour > 12:
		hour -= 12
	var ampm := String(resolve.call(FORENOON_KEY if forenoon else AFTERNOON_KEY))
	return printf(fmt, [int(d["year"]), int(d["month"]), int(d["day"]), ampm, hour, int(d["minute"])])

## swprintf over %d and %s in order (the two the rows use); a spec with no
## argument left is dropped, "%%" is a percent.
static func printf(fmt: String, args: Array) -> String:
	var out := ""
	var i := 0
	var a := 0
	while i < fmt.length():
		var c := fmt[i]
		if c == "%" and i + 1 < fmt.length():
			var spec := fmt[i + 1]
			if spec == "%":
				out += "%"
				i += 2
				continue
			if spec == "d" or spec == "s":
				if a < args.size():
					out += str(args[a])
				a += 1
				i += 2
				continue
		out += c
		i += 1
	return out
