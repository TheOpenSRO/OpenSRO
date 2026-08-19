extends RefCounted
class_name PartyNet

## Opcodes and payload encoding for the party system, mirroring
## server/internal/session (party.go). All require a prior login.

const OP_CREATE := 0x0080          # client -> server
const OP_CREATE_RESULT := 0x0081   # server -> client
const OP_JOIN := 0x0082            # client -> server
const OP_JOIN_RESULT := 0x0083     # server -> client
const OP_LEAVE := 0x0084           # client -> server
const OP_LEAVE_RESULT := 0x0085    # server -> client
const OP_MEMBER_JOINED := 0x0086   # server -> client, broadcast
const OP_MEMBER_LEFT := 0x0087     # server -> client, broadcast

## One party member.
class Member:
	var character_id: int
	var member_name: String

## Result of decode_result(): shared by OP_CREATE_RESULT and
## OP_JOIN_RESULT. On failure only error is meaningful.
class Result:
	var error: String
	var party_id: int
	var members: Array[Member] = []

## Result of decode_leave_result().
class LeaveResult:
	var ok: bool
	var reason: String
	var error: String

## Result of decode_member_joined().
class MemberJoined:
	var character_id: int
	var member_name: String

## Encodes an OpPartyCreate/OpPartyLeave request: just a character name.
static func encode_name_request(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## Encodes an OpPartyJoin request.
static func encode_join(character_name: String, party_id: int) -> PackedByteArray:
	var out := encode_name_request(character_name)
	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, party_id)
	out.append_array(id_buf)
	return out

static func _decode_member(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var m := Member.new()
	m.character_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	m.member_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	return [m, offset]

## Decodes an OpPartyCreateResult/OpPartyJoinResult payload.
static func decode_result(data: PackedByteArray) -> Result:
	var result := Result.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()
	if result.error != "":
		return result

	if offset + 8 > data.size():
		result.error = "truncated party id"
		return result
	result.party_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		result.error = "truncated member count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_member(data, offset)
		if decoded[0] == null:
			result.error = "truncated member %d" % i
			return result
		result.members.append(decoded[0])
		offset = decoded[1]

	return result

## Decodes an OpPartyLeaveResult payload (same OK/Reason shape as
## Auth.decode_result).
static func decode_leave_result(data: PackedByteArray) -> LeaveResult:
	var result := LeaveResult.new()
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

## Decodes an OpPartyMemberJoined broadcast payload.
static func decode_member_joined(data: PackedByteArray) -> MemberJoined:
	if data.size() < 8:
		return null
	var m := MemberJoined.new()
	m.character_id = data.decode_s64(0)
	if data.size() < 10:
		return null
	var name_len := data.decode_u16(8)
	if 10 + name_len > data.size():
		return null
	m.member_name = data.slice(10, 10 + name_len).get_string_from_utf8()
	return m

## Decodes an OpPartyMemberLeft broadcast payload, returning the character
## ID (or -1 on truncation).
static func decode_member_left(data: PackedByteArray) -> int:
	if data.size() < 8:
		return -1
	return data.decode_s64(0)
