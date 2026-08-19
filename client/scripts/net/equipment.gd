extends RefCounted
class_name EquipmentNet

## Opcodes and payload encoding for equip/unequip, mirroring
## server/internal/session (equipment.go). Requires a prior login.

const OP_LIST := 0x0040    # client -> server
const OP_RESULT := 0x0041  # server -> client (list, or equip/unequip result)
const OP_EQUIP := 0x0042   # client -> server
const OP_UNEQUIP := 0x0043 # client -> server

const SLOT_WEAPON := 0
const SLOT_ARMOR := 1

## One equipped item.
class Equipped:
	var slot: int
	var item_id: int

## Result of decode_result(): either a list (from OP_LIST) or just an
## error/success marker (from OP_EQUIP/OP_UNEQUIP -- items is empty then).
class Result:
	var error: String
	var items: Array[Equipped] = []

## Encodes an OpEquipmentList request: just a character name.
static func encode_list_request(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## Encodes an OpEquip request.
static func encode_equip(character_name: String, slot: int, inventory_slot: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_u32(0, slot)
	buf.encode_u32(4, inventory_slot)
	out.append_array(buf)
	return out

## Encodes an OpUnequip request.
static func encode_unequip(character_name: String, slot: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_u32(0, slot)
	out.append_array(buf)
	return out

static func _decode_equipped(data: PackedByteArray, offset: int) -> Array:
	if offset + 4 > data.size():
		return [null, -1]
	var e := Equipped.new()
	e.slot = data.decode_u32(offset)
	offset += 4
	if offset + 8 > data.size():
		return [null, -1]
	e.item_id = data.decode_s64(offset)
	offset += 8
	return [e, offset]

## Decodes an OpEquipmentResult payload.
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

	if offset + 2 > data.size():
		result.error = "truncated item count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_equipped(data, offset)
		if decoded[0] == null:
			result.error = "truncated item %d" % i
			return result
		result.items.append(decoded[0])
		offset = decoded[1]

	return result
