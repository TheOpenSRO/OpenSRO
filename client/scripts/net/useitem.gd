extends RefCounted
class_name UseItemNet

## Using a consumable: spend one from a bag slot and get back what it
## restored. The restore amounts are the game's own -- the item table stores
## each Param value beside its own label ("HP..." / "MP..."), so a small potion
## gives 120 and a large one 370.

const OP_USE_ITEM := 0x0080   # client -> server
const OP_RESULT := 0x0081     # server -> client

## What the item did. hp/mp are the values *after* using it, so both bars can
## be redrawn without asking for stats again.
class Result extends RefCounted:
	var error: String = ""
	var hp: int = 0
	var max_hp: int = 0
	var mp: int = 0
	var max_mp: int = 0
	var restored_hp: int = 0
	var restored_mp: int = 0
	var remaining: int = 0

## Encodes an OpUseItem request: the character's name and the bag slot.
static func encode_use(character_name: String, inventory_slot: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var tail := PackedByteArray()
	tail.resize(8)
	tail.encode_s64(0, inventory_slot)
	out.append_array(tail)
	return out

static func decode_result(data: PackedByteArray) -> Result:
	var res := Result.new()
	if data.size() < 2:
		res.error = "truncated"
		return res
	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		res.error = "truncated error field"
		return res
	res.error = data.slice(2, offset).get_string_from_utf8()
	if offset + 28 > data.size():
		return res
	res.hp = data.decode_s32(offset)
	res.max_hp = data.decode_s32(offset + 4)
	res.mp = data.decode_s32(offset + 8)
	res.max_mp = data.decode_s32(offset + 12)
	res.restored_hp = data.decode_s32(offset + 16)
	res.restored_mp = data.decode_s32(offset + 20)
	res.remaining = data.decode_s32(offset + 24)
	return res
