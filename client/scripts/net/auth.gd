extends RefCounted
class_name Auth

## Opcodes and payload encoding for login/registration, mirroring
## server/internal/session (login.go, register.go). Keep the two in sync if
## the wire shape changes -- there's no shared schema, just matching
## conventions on both ends.

const OP_LOGIN := 0x0001            # client -> server
const OP_LOGIN_RESULT := 0x0002     # server -> client
const OP_REGISTER := 0x0003         # client -> server
const OP_REGISTER_RESULT := 0x0004  # server -> client

## Encodes (username, password) the same way for both login and register
## requests: for each field, a uint16 LE byte length then UTF-8 bytes.
static func encode_credentials(username: String, password: String) -> PackedByteArray:
	var out := PackedByteArray()
	for field: String in [username, password]:
		var field_bytes: PackedByteArray = field.to_utf8_buffer()
		var len_buf := PackedByteArray()
		len_buf.resize(2)
		len_buf.encode_u16(0, field_bytes.size())
		out.append_array(len_buf)
		out.append_array(field_bytes)
	return out

## Result of decode_result(): whether it succeeded and, on failure or
## malformed input, why.
class Result:
	var ok: bool
	var reason: String
	var error: String # set instead of ok/reason when the payload itself was malformed

## Decodes an OpLoginResult/OpRegisterResult payload (both share the same
## shape: one OK byte, then a length-prefixed reason string).
static func decode_result(data: PackedByteArray) -> Result:
	var result := Result.new()
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
