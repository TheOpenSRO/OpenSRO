extends RefCounted
class_name TeleportNet

## The town teleporters' MOVE (round 576), mirroring
## server/internal/session/teleport.go: the client names the gate the player
## is at and the destination it chose, both teleportdata ids, and the server
## answers with a receipt -- then, on success, the ordinary
## OpChangeZoneResult that moves the player (World3D._on_change_zone_result,
## the loading screen and all). OpenSRO's own placeholder pair
## (docs/protocol/PROTOCOL_DECISION.md); 0x00F3/0x00F4 were free on
## 2026-09-26, the highest op in client/scripts/net being GmNet's 0x00F2. The
## retail request (0x705a, CIF_NPCTalk::FUN_0081ddf0) and reply (0xb05a, read
## by FUN_008809d0) are recorded in docs/protocol/teleport_network.md, "What
## OpenSRO built", not copied.

const OP_USE := 0x00F3     # client -> server
const OP_RESULT := 0x00F4  # server -> client, the requester

## Why a charged fee is 0 when the link has one (server/internal/teleport's
## Waiver): the engine's own waiver below level 21 (GObjPC::HandleTeleportUse,
## `cmp al,0x14; ja` at 0x5136de), and OpenSRO's own two -- a GM account, and
## the server's -teleport-free testing switch.
const WAIVER_NONE := 0
const WAIVER_LEVEL := 1
const WAIVER_GM := 2
const WAIVER_FLAG := 3

## The engine's refusal for a link that does not exist: HandleTeleportUse's
## `uStack_2c = 2` when the gate has no such link (0x513910). OpenSRO's
## server answers it for an unknown gate as well.
const ERR_NO_LINK := 2

## The server's answer, decoded.
class Result:
	var ok: bool = false
	## The engine's refusal code, or 0 for one of the server's own refusals.
	var code: int = 0
	var waiver: int = WAIVER_NONE
	## The gold charged.
	var fee: int = 0
	## The destination point's zone-name token (SN_ZONE_22002), resolved
	## through textdata_object like every SN_ name.
	var destination: String = ""
	## The server's own wording for a refusal: the fallback when the archive
	## has no message for the code (ErrorText.teleport_line).
	var reason: String = ""

## Encodes an OpTeleportUse: the gate's and the destination's teleportdata
## ids, two u16 LE -- the four bytes DecodeTeleportUseRequest reads.
static func encode_use(gate_id: int, dest_id: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u16(0, gate_id)
	out.encode_u16(2, dest_id)
	return out

## Decodes an OpTeleportResult (teleport.go's TeleportResult.Encode): u8 ok,
## u16 code, u8 waiver, u64 fee, then the destination and the reason as
## u16-prefixed UTF-8 strings. Returns null on a truncated payload rather than
## a half-filled result.
static func decode_result(data: PackedByteArray) -> Result:
	if data.size() < 12:
		return null
	var r := Result.new()
	r.ok = data.decode_u8(0) != 0
	r.code = data.decode_u16(1)
	r.waiver = data.decode_u8(3)
	r.fee = data.decode_u64(4)
	var dest := _decode_string(data, 12)
	if dest[1] < 0:
		return null
	r.destination = dest[0]
	var reason := _decode_string(data, dest[1])
	if reason[1] < 0:
		return null
	r.reason = reason[0]
	return r

## The receipt line, in the archive's own format: UIIT_CTL_TELEPORT_RESULT
## ("[%s]" place, "%d" gold) when gold was charged, UIIT_CTL_TELEPORT_FREE_RESULT
## ("[%s]" place) when none was -- the retail dialog's own choice between the
## two, made on whether the link's fee word is 0 (UI_TELEPORT::FUN_006fd3e0,
## docs/protocol/teleport_network.md "The client's list, read"). `place` is
## the destination's name ("" when textdata_object has none). The file carries
## two rows of each token and UiTextTable keeps the last; either shape is
## filled. A template whose placeholders are not exactly those, a missing
## row, or no place falls back to OpenSRO's own wording.
static func receipt_line(place: String, fee: int, table: UiTextTable) -> String:
	var key := "UIIT_CTL_TELEPORT_RESULT" if fee > 0 else "UIIT_CTL_TELEPORT_FREE_RESULT"
	var template := ""
	if table != null and table.has(key):
		template = table.get_text(key).strip_edges()
	if place != "" and template != key and _fits(template, fee > 0):
		return template % ([place, fee] if fee > 0 else [place])
	if fee > 0:
		return ("Teleporting to %s for %d gold." % [place, fee]) if place != "" else ("Teleporting for %d gold." % fee)
	return ("Teleporting to %s at no cost." % place) if place != "" else "Teleporting at no cost."

## True when template holds one %s -- then one %d, when with_fee -- and no
## other % sequence, so the `%` operator can fill it without an error.
static func _fits(template: String, with_fee: bool) -> bool:
	if template == "" or template.count("%") != (2 if with_fee else 1):
		return false
	var s := template.find("%s")
	if s < 0:
		return false
	if not with_fee:
		return true
	return template.find("%d") > s

## Reads one length-prefixed string at offset, returning [text, next_offset]
## (next_offset -1 on truncation).
static func _decode_string(data: PackedByteArray, offset: int) -> Array:
	if offset + 2 > data.size():
		return ["", -1]
	var n := data.decode_u16(offset)
	offset += 2
	if offset + n > data.size():
		return ["", -1]
	return [data.slice(offset, offset + n).get_string_from_utf8(), offset + n]
