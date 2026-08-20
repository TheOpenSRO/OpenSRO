extends RefCounted
class_name FriendNet

## Opcodes and payload encoding for the friends list system, mirroring
## server/internal/session (friend.go). All require a prior login.
##
## OpFriendRequest requires the target to be online (server-side, resolved
## via world.Hub -- same limitation as chat whispers/duels/trades). Accept/
## decline/remove take a character ID (from a prior pending-list/friends-
## list response), not a name, so they work regardless of whether the
## other side is online.

const OP_REQUEST := 0x00E0             # client -> server
const OP_REQUEST_RESULT := 0x00E1      # server -> client, ack to the sender
const OP_REQUEST_RECEIVED := 0x00E2    # server -> client, direct to the target (if online)
const OP_ACCEPT := 0x00E3              # client -> server
const OP_ACCEPT_RESULT := 0x00E4       # server -> client, ack to the accepter
const OP_ACCEPTED := 0x00E5            # server -> client, direct to the original requester (if online)
const OP_DECLINE := 0x00E6             # client -> server
const OP_DECLINE_RESULT := 0x00E7      # server -> client, ack
const OP_LIST := 0x00E8                # client -> server
const OP_LIST_RESULT := 0x00E9         # server -> client
const OP_REMOVE := 0x00EA              # client -> server
const OP_REMOVE_RESULT := 0x00EB       # server -> client, ack
const OP_PENDING_LIST := 0x00EC        # client -> server
const OP_PENDING_LIST_RESULT := 0x00ED # server -> client

## Result of decode_request_received().
class RequestReceived:
	var requester_name: String

## Result of decode_accepted().
class Accepted:
	var accepter_name: String

## One friends-list entry.
class FriendEntry:
	var character_id: int
	var friend_name: String
	var online: bool

## Result of decode_list_result().
class ListResult:
	var error: String
	var friends: Array[FriendEntry] = []

## One incoming pending request.
class PendingRequest:
	var requester_id: int
	var requester_name: String

## Result of decode_pending_list_result().
class PendingListResult:
	var error: String
	var requests: Array[PendingRequest] = []

static func _encode_string(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

## Encodes an OpFriendRequest.
static func encode_request(character_name: String, target_name: String) -> PackedByteArray:
	var out := _encode_string(character_name)
	out.append_array(_encode_string(target_name))
	return out

## Encodes an OpFriendAccept.
static func encode_accept(character_name: String, requester_id: int) -> PackedByteArray:
	var out := _encode_string(character_name)
	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, requester_id)
	out.append_array(id_buf)
	return out

## Encodes an OpFriendDecline.
static func encode_decline(character_name: String, requester_id: int) -> PackedByteArray:
	return encode_accept(character_name, requester_id) # identical shape

## Encodes an OpFriendList/OpFriendPendingList request: just a character
## name.
static func encode_name_request(character_name: String) -> PackedByteArray:
	return _encode_string(character_name)

## Encodes an OpFriendRemove.
static func encode_remove(character_name: String, friend_id: int) -> PackedByteArray:
	var out := _encode_string(character_name)
	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, friend_id)
	out.append_array(id_buf)
	return out

## Decodes an OpFriendRequestReceived payload.
static func decode_request_received(data: PackedByteArray) -> RequestReceived:
	if data.size() < 2:
		return null
	var name_len := data.decode_u16(0)
	if 2 + name_len > data.size():
		return null
	var r := RequestReceived.new()
	r.requester_name = data.slice(2, 2 + name_len).get_string_from_utf8()
	return r

## Decodes an OpFriendAccepted payload.
static func decode_accepted(data: PackedByteArray) -> Accepted:
	if data.size() < 2:
		return null
	var name_len := data.decode_u16(0)
	if 2 + name_len > data.size():
		return null
	var a := Accepted.new()
	a.accepter_name = data.slice(2, 2 + name_len).get_string_from_utf8()
	return a

static func _decode_friend_entry(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var f := FriendEntry.new()
	f.character_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	f.friend_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	if offset + 1 > data.size():
		return [null, -1]
	f.online = data[offset] != 0
	offset += 1

	return [f, offset]

## Decodes an OpFriendListResult payload.
static func decode_list_result(data: PackedByteArray) -> ListResult:
	var result := ListResult.new()
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

	if offset + 2 > data.size():
		result.error = "truncated friend count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_friend_entry(data, offset)
		if decoded[0] == null:
			result.error = "truncated friend %d" % i
			return result
		result.friends.append(decoded[0])
		offset = decoded[1]

	return result

static func _decode_pending_request(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var r := PendingRequest.new()
	r.requester_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	r.requester_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	return [r, offset]

## Decodes an OpFriendPendingListResult payload.
static func decode_pending_list_result(data: PackedByteArray) -> PendingListResult:
	var result := PendingListResult.new()
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

	if offset + 2 > data.size():
		result.error = "truncated request count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_pending_request(data, offset)
		if decoded[0] == null:
			result.error = "truncated request %d" % i
			return result
		result.requests.append(decoded[0])
		offset = decoded[1]

	return result
