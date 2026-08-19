extends RefCounted
class_name ChatNet

## Opcodes and payload encoding for the chat system, mirroring
## server/internal/session (chat.go). Requires the character to already be
## in the world -- chat identity/zone comes from the server's world.Hub, not
## a client-supplied character name.

const OP_SAY := 0x00A0              # client -> server
const OP_MESSAGE := 0x00A1          # server -> client, broadcast to sender's zone (incl. sender)
const OP_WHISPER := 0x00A2          # client -> server
const OP_WHISPER_RESULT := 0x00A3   # server -> client
const OP_WHISPER_MESSAGE := 0x00A4  # server -> client, delivered to the whisper's target

## Result of decode_message().
class Message:
	var sender_name: String
	var message_text: String

## Result of decode_whisper_result().
class WhisperResult:
	var ok: bool
	var reason: String
	var error: String

## Encodes an OpChatSay request.
static func encode_say(message_text: String) -> PackedByteArray:
	return _encode_string(message_text)

## Encodes an OpChatWhisper request.
static func encode_whisper(target_name: String, message_text: String) -> PackedByteArray:
	var out := _encode_string(target_name)
	out.append_array(_encode_string(message_text))
	return out

static func _encode_string(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

## Decodes an OpChatMessage/OpChatWhisperMessage payload.
static func decode_message(data: PackedByteArray) -> Message:
	var m := Message.new()
	if data.size() < 2:
		return null
	var sender_len := data.decode_u16(0)
	var offset := 2 + sender_len
	if offset > data.size():
		return null
	m.sender_name = data.slice(2, offset).get_string_from_utf8()

	if offset + 2 > data.size():
		return null
	var msg_len := data.decode_u16(offset)
	offset += 2
	if offset + msg_len > data.size():
		return null
	m.message_text = data.slice(offset, offset + msg_len).get_string_from_utf8()

	return m

## Decodes an OpChatWhisperResult payload (same OK/Reason shape as
## Auth.decode_result).
static func decode_whisper_result(data: PackedByteArray) -> WhisperResult:
	var result := WhisperResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result

	var ok := data[0] != 0
	if data.size() < 3:
		result.error = "truncated reason length prefix"
		return result

	var reason_len := data.decode_u16(1)
	if 3 + reason_len > data.size():
		result.error = "declared reason length %d exceeds remaining bytes" % reason_len
		return result

	result.ok = ok
	result.reason = data.slice(3, 3 + reason_len).get_string_from_utf8()
	return result
