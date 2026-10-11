extends RefCounted
class_name UseItemNet

## Using a consumable: spend one from a bag slot and get back what it
## restored. The restore amounts are the game's own -- the item table stores
## each Param value beside its own label ("HP..." / "MP..."), so a small potion
## gives 120 and a large one 370.

## MOVED from 0x0080/0x0081 on 2026-09-20: those were OpenSRO's own party create and its
## result, held since a month earlier, and this pair collided with them. The
## server offers a packet to every handler, so a use-item request was handled
## twice -- the item was consumed and a success sent, then the party handler
## failed to read a party-create payload from the same bytes and answered
## "malformed request", and both replies carried 0x0081 so the client showed
## both.
const OP_USE_ITEM := 0x008a   # client -> server
const OP_RESULT := 0x008b     # server -> client

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
	## A berserk potion's reply (round 632): the orb gauge (0..100, orbs x 20)
	## and whether berserk is active after the use. has_berserk is false on
	## every other reply, and on a server older than the tail.
	var has_berserk: bool = false
	var berserk_gauge: int = 0
	var berserk_active: bool = false
	## Round 778: the engine's refusal code (the scrolls' -- the client's
	## category-1 table, ErrorText.scroll_line), 0 when `error` alone says
	## why; and an accepted scroll's delay before its move, in ms. Both after
	## the berserk tail; 0 from a server before them.
	var code: int = 0
	var cast_ms: int = 0

## The reverse return scroll's option byte (round 778, READ: the message box
## kind 0x21's results 1/2/3 send 2/3/7, FUN_00797d90 0x798862..0x7988d8).
const OPTION_RECALL := 2
const OPTION_DEATH := 3
const OPTION_MAP := 7

## Encodes an OpUseItem request: the character's name and the bag slot --
## and, for a reverse return scroll (round 778), the option byte and, for the
## map option, the u32 refoptionalteleport id, as retail's 0x704C carries
## {u8 option, u32 id} (SendItem_HandleUseItem 0x796660). Option 0 sends
## neither.
static func encode_use(character_name: String, inventory_slot: int, option: int = 0, target: int = 0) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var tail := PackedByteArray()
	tail.resize(8)
	tail.encode_s64(0, inventory_slot)
	out.append_array(tail)
	if option != 0:
		out.append(option & 0xff)
		if option == OPTION_MAP:
			var id := PackedByteArray()
			id.resize(4)
			id.encode_u32(0, target)
			out.append_array(id)
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
	if offset + 34 > data.size():
		return res
	res.has_berserk = data[offset + 28] != 0
	res.berserk_gauge = data.decode_s32(offset + 29)
	res.berserk_active = data[offset + 33] != 0
	if offset + 40 > data.size():
		return res
	res.code = data.decode_u16(offset + 34)
	res.cast_ms = data.decode_u32(offset + 36)
	return res
