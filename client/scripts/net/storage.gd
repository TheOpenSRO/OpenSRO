extends RefCounted
class_name StorageNet

## Opcodes and payloads for the warehouse (storage NPC), mirroring
## server/internal/session (storage.go). Requires a prior login. The list
## result has the same wire shape as the inventory list, so
## InventoryNet.decode_list_result parses it.

const OP_LIST := 0x0056           # client -> server
const OP_LIST_RESULT := 0x0057    # server -> client
const OP_DEPOSIT := 0x0058        # client -> server (bag -> warehouse)
const OP_DEPOSIT_RESULT := 0x0059 # server -> client
const OP_WITHDRAW := 0x005A       # client -> server (warehouse -> bag)
const OP_WITHDRAW_RESULT := 0x005B # server -> client

## Result of decode_move_result() (deposit or withdraw).
class MoveResult:
	var ok: bool
	var reason: String
	var error: String

## Encodes an OpStorageList request: just the character name.
static func encode_list_request(character_name: String) -> PackedByteArray:
	return InventoryNet.encode_list_request(character_name)

## Encodes a deposit/withdraw: character name, slot (u32), quantity (u32).
static func encode_move(character_name: String, slot: int, quantity: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var tail := PackedByteArray()
	tail.resize(8)
	tail.encode_u32(0, slot)
	tail.encode_u32(4, quantity)
	out.append_array(tail)
	return out

## Decodes a deposit/withdraw result: 1 OK byte + a length-prefixed reason.
static func decode_move_result(data: PackedByteArray) -> MoveResult:
	var result := MoveResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result
	result.ok = data[0] != 0
	if data.size() < 3:
		result.error = "truncated reason length prefix"
		return result
	var reason_len := data.decode_u16(1)
	if 3 + reason_len > data.size():
		result.error = "declared reason length %d exceeds remaining bytes" % reason_len
		return result
	result.reason = data.slice(3, 3 + reason_len).get_string_from_utf8()
	return result

## The list result is the inventory list shape.
static func decode_list_result(data: PackedByteArray) -> InventoryNet.ListResult:
	return InventoryNet.decode_list_result(data)
