extends RefCounted
class_name ChatNet

## Opcodes and payload encoding for chat, mirroring
## server/internal/session/chat.go (round 634). The framing is OpenSRO's own;
## the fields are the retail client's (0x7025's request, 0x3026's line,
## 0xB025's answer, and 0x704c's global chatting item use) -- see
## docs/protocol/chat.md. Requires the character to already be in the world.

const OP_SEND := 0x00A5    # client -> server: type, index, target, text
const OP_UPDATE := 0x00A6  # server -> client: type, sender, text
const OP_RESULT := 0x00A7  # server -> client: ok, type, index, code, target
const OP_GLOBAL := 0x00A8  # client -> server: inventory slot, text

## Result of decode_update().
class Update:
	var type: int
	var sender_name: String
	var message_text: String
	## A coloured global's colour, 0xAARRGGBB (round 838, OURS: the server's
	## GlobalChatColor, a strict suffix); 0 draws the type's own.
	var color: int = 0

## Result of decode_result().
class Result:
	var ok: bool
	var type: int
	var index: int
	var code: int
	var target: String

## Encodes an OpChatSend request.
static func encode_send(type: int, index: int, target_name: String, message_text: String) -> PackedByteArray:
	var out := PackedByteArray([type & 0xff, index & 0xff])
	out.append_array(_encode_string(target_name))
	out.append_array(_encode_string(message_text))
	return out

## Encodes an OpChatGlobal request: the bag slot holding the global chatting
## item, then the text.
static func encode_global(inventory_slot: int, message_text: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, inventory_slot)
	out.append_array(_encode_string(message_text))
	return out

static func _encode_string(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

## Reads a u16-length string at `offset`; returns [string, next offset] or []
## when the buffer is short.
static func _read_string(data: PackedByteArray, offset: int) -> Array:
	if offset + 2 > data.size():
		return []
	var n := data.decode_u16(offset)
	if offset + 2 + n > data.size():
		return []
	return [data.slice(offset + 2, offset + 2 + n).get_string_from_utf8(), offset + 2 + n]

## Decodes an OpChatUpdate payload, or null.
static func decode_update(data: PackedByteArray) -> Update:
	if data.size() < 1:
		return null
	var sender := _read_string(data, 1)
	if sender.is_empty():
		return null
	var text := _read_string(data, int(sender[1]))
	if text.is_empty():
		return null
	var u := Update.new()
	u.type = data[0]
	u.sender_name = sender[0]
	u.message_text = text[0]
	var end := int(text[1])
	if data.size() >= end + 4:
		u.color = data.decode_u32(end)
	return u

## Decodes an OpChatResult payload, or null.
static func decode_result(data: PackedByteArray) -> Result:
	if data.size() < 5:
		return null
	var target := _read_string(data, 5)
	if target.is_empty():
		return null
	var r := Result.new()
	r.ok = data[0] != 0
	r.type = data[1]
	r.index = data[2]
	r.code = data.decode_u16(3)
	r.target = target[0]
	return r
