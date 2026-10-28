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
	## Round 779: the used item's ref id on an accepted scroll (OURS: retail's
	## 0xB04C names the slot and the type word and the client finds the ref
	## through the slot), so the casting bar reads the item's name and Param1
	## from the client's own table. 0 from a server before it.
	var item_id: int = 0

## The reverse return scroll's option byte (round 778, READ: the message box
## kind 0x21's results 1/2/3 send 2/3/7, FUN_00797d90 0x798862..0x7988d8).
const OPTION_RECALL := 2
const OPTION_DEATH := 3
const OPTION_MAP := 7
## Round 838, OURS: the special reverse return scroll's party member (+ u32
## its party JID) and saved location (+ u32 the slot), the server's
## ReverseOptionParty / ReverseOptionSaved.
const OPTION_PARTY := 4
const OPTION_SAVED := 5

## Encodes an OpUseItem request: the character's name and the bag slot --
## and, for a reverse return scroll (round 778), the option byte and, for the
## map option, the u32 refoptionalteleport id, as retail's 0x704C carries
## {u8 option, u32 id} (SendItem_HandleUseItem 0x796660). Option 0 sends
## neither.
## Round 795: a pet consumable's target (OURS, session.UseOptionCOSTarget):
## the COS uid, or the pet item's bag index for the revival and the clock.
const OPTION_COS_TARGET := 0xC5
## Round 824 (OURS, the server's UseOptionCrest): a crest register's use, the
## 256 palette indices after the option (retail's 0x704C carries them after
## the slot and type word, c:0x7974a2).
const OPTION_CREST := 0xC6

## Whether TypeIDs are an item the client sends with the current COS's uid
## (round 805; SendItem_HandleUseItem 0x796660, READ): a COS HP potion 3/3/1/4,
## /5, /7, the HGP potion 3/3/1/9 and the pet cure 3/3/2/7 set local_160, which
## appends the u32 uid to 0x704C.
static func is_cos_target_item(types: PackedInt32Array) -> bool:
	if types.size() < 4 or types[0] != 3 or types[1] != 3:
		return false
	if types[2] == 1:
		return types[3] == 4 or types[3] == 5 or types[3] == 7 or types[3] == 9
	return types[2] == 2 and types[3] == 7

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
		if option == OPTION_MAP or option == OPTION_COS_TARGET or option == OPTION_PARTY or option == OPTION_SAVED:
			var id := PackedByteArray()
			id.resize(4)
			id.encode_u32(0, target)
			out.append_array(id)
	return out

## Round 838, OURS: the special reverse return scroll's saved locations
## (server session/scroll838.go): OP_REVERSE_SAVED {u8 action, u8 slot, i64
## the bag slot of the scroll}, answered by OP_REVERSE_SAVED_RESULT {u8 ok, u8
## registered, u16-len reason, u8 n, n x {i32 region, f32 x, f32 y, f32 z}}
## -- region 0 an empty slot, the position region-local.
const OP_REVERSE_SAVED := 0x00FE
const OP_REVERSE_SAVED_RESULT := 0x00FF
const SAVED_LIST := 0
const SAVED_REGISTER := 1

static func encode_reverse_saved(action: int, saved_slot: int, bag_slot: int) -> PackedByteArray:
	var out := PackedByteArray([action & 0xff, saved_slot & 0xff])
	out.resize(10)
	out.encode_s64(2, bag_slot)
	return out

## {"ok", "registered", "reason", "slots": [{"region", "x", "y", "z"}, ...]},
## or {} for a short payload.
static func decode_reverse_saved(data: PackedByteArray) -> Dictionary:
	if data.size() < 4:
		return {}
	var n_reason := data.decode_u16(2)
	var at := 4 + n_reason
	if data.size() < at + 1:
		return {}
	var out := {"ok": data[0] != 0, "registered": data[1] != 0,
		"reason": data.slice(4, at).get_string_from_utf8(), "slots": []}
	var n := data[at]
	at += 1
	if data.size() < at + n * 16:
		return {}
	for i in n:
		out["slots"].append({"region": data.decode_s32(at), "x": data.decode_float(at + 4),
			"y": data.decode_float(at + 8), "z": data.decode_float(at + 12)})
		at += 16
	return out

## A crest register's use: the plain use, OPTION_CREST, the 256 bytes.
static func encode_use_crest(character_name: String, inventory_slot: int, pixels: PackedByteArray) -> PackedByteArray:
	var out := encode_use(character_name, inventory_slot)
	out.append(OPTION_CREST)
	out.append_array(pixels)
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
	if offset + 44 > data.size():
		return res
	res.item_id = data.decode_u32(offset + 40)
	return res

## The casting bar's cancel (round 779, READ): retail's 0x705B with no body
## (UI_SILKMALL::FUN_0081ee60 case 0). The server answers only a refusal,
## 0xB05B {u8 2, u16 code} (GObjPC::FUN_00513ea0: 6, no scroll working),
## which the client's FUN_008727a0 reads and shows nothing for; a cancel that
## works is answered by the 0x30BF kind 0xb value 0.
const OP_SCROLL_CANCEL := 0x705B
const OP_SCROLL_CANCEL_RESULT := 0xB05B

## 0xB05B's code, or -1 when it is not a refusal (result 1 would show
## UIIT_MSG_TRANSITION_CANCEL_RESULT, which this server never sends).
static func decode_cancel_result(data: PackedByteArray) -> int:
	if data.size() >= 3 and data[0] == 2:
		return data.decode_u16(1)
	return -1
