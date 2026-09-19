extends RefCounted
class_name InventoryNet

## Opcodes and payload encoding for listing a character's inventory,
## mirroring server/internal/session (inventory.go). Requires a prior login.

const OP_LIST := 0x0030          # client -> server
const OP_LIST_RESULT := 0x0031   # server -> client
## Rearranging the bag (session/inventorymove.go): move a slot's stack onto
## another slot. The server decides what that means -- a move into a free
## slot, a merge into a same-item stack, or a swap -- and answers with the
## whole bag as it stands, in OP_LIST_RESULT's shape (decode_list_result).
const OP_MOVE := 0x0032          # client -> server
const OP_MOVE_RESULT := 0x0033   # server -> client

## One occupied inventory slot.
class Slot:
	var slot_index: int
	var item_id: int
	var quantity: int

## One slot's per-instance durability, from the trailing block a newer
## server appends (session/durability.go). Absent for items with none.
class Durability:
	var slot: int
	var current: int
	var maximum: int

## Result of decode_list_result(): either an error, or the occupied slots,
## plus any per-slot durability (empty against an older server).
class ListResult:
	var error: String
	var slots: Array[Slot] = []
	var durabilities: Array[Durability] = []

## Encodes an OpInventoryList request: just a character name (same shape
## as CharacterNet's create/delete name requests).
static func encode_list_request(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## Encodes an OpInventoryMove request: the character name, then the source
## and destination slot indices as signed 64-bit, the same shape as
## UseItemNet.encode_use with a second index.
static func encode_move_request(character_name: String, from_slot: int, to_slot: int) -> PackedByteArray:
	var out := encode_list_request(character_name)
	var tail := PackedByteArray()
	tail.resize(16)
	tail.encode_s64(0, from_slot)
	tail.encode_s64(8, to_slot)
	out.append_array(tail)
	return out

## Parses one Slot from data starting at offset, returning it along with
## the offset just past it (or -1 on truncation).
static func _decode_slot(data: PackedByteArray, offset: int) -> Array:
	if offset + 4 > data.size():
		return [null, -1]
	var sl := Slot.new()
	sl.slot_index = data.decode_u32(offset)
	offset += 4

	if offset + 8 > data.size():
		return [null, -1]
	sl.item_id = data.decode_s64(offset)
	offset += 8

	if offset + 4 > data.size():
		return [null, -1]
	sl.quantity = data.decode_u32(offset)
	offset += 4

	return [sl, offset]

## Decodes an OpInventoryListResult payload.
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

	if offset + 2 > data.size():
		result.error = "truncated slot count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_slot(data, offset)
		if decoded[0] == null:
			result.error = "truncated slot %d" % i
			return result
		result.slots.append(decoded[0])
		offset = decoded[1]

	result.durabilities = decode_durability_block(data, offset)
	return result

## Decodes the trailing durability block (u16 count, then per entry u32 slot,
## s32 current, s32 max) written by session/durability.go. A short or absent
## tail -- an older server -- yields an empty array, never an error.
static func decode_durability_block(data: PackedByteArray, offset: int) -> Array:
	var out: Array = []
	if offset + 2 > data.size():
		return out
	var count := data.decode_u16(offset)
	offset += 2
	for i in range(count):
		if offset + 12 > data.size():
			break
		var d := Durability.new()
		d.slot = data.decode_u32(offset)
		d.current = data.decode_s32(offset + 4)
		d.maximum = data.decode_s32(offset + 8)
		offset += 12
		out.append(d)
	return out
