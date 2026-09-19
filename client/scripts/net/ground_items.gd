extends RefCounted
class_name GroundItemsNet

## Items lying on the ground -- what a kill leaves near the corpse until it
## is picked up. Our own protocol (server/internal/session/grounditem.go);
## the rules behind it are the engine's, read off SR_GameServer.exe: a pick
## within 10 world units, the owner's 30 s window (then anyone), a same-party
## picker allowed. See docs/protocol/ground_items.md.
const OP_LIST := 0x006a            # client -> server: what lies in my zone
const OP_LIST_RESULT := 0x006b     # server -> client
const OP_SPAWNED := 0x006c         # server -> zone: one item appeared
const OP_REMOVED := 0x006d         # server -> zone: one item is gone
const OP_OWNER_RELEASED := 0x006e  # server -> zone: its 30 s window passed
const OP_PICK_UP := 0x006f         # client -> server
const OP_PICK_UP_RESULT := 0x0079  # server -> client

## Why an item left the ground (Removed.reason).
const REMOVED_PICKED := 0
const REMOVED_EXPIRED := 1

## The server's refusal codes, the engine's own (GObjPC::CheckCanPickUp).
const ERR_TOO_FAR := 4
const ERR_NOT_OWNER := 0x1812
const ERR_BUSY := 0x1813
const ERR_CANNOT_PICK := 0x1839

## The pick range the server enforces, in world units (.rdata 0xb45b44).
const PICK_RANGE := 10.0

class Snapshot:
	var id: int
	var item_id: int
	var quantity: int
	var gold: bool
	var x: float
	var y: float
	var z: float
	var owner_id: int  # 0 = anyone may pick it

class ListResult:
	var items: Array[Snapshot] = []
	var error := ""

class Removed:
	var id: int
	var reason: int
	var picker_id: int

class PickUpResult:
	var code: int       # 0 = picked; else one of ERR_*
	var ground_id: int
	var item_id: int
	var quantity: int
	var gold: bool

static func encode_list() -> PackedByteArray:
	return PackedByteArray()

static func encode_pick_up(character_name: String, ground_id: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, ground_id)
	out.append_array(id_buf)
	return out

## Snapshot layout: s64 id, s64 item id, u32 quantity, u8 gold, f32 x/y/z,
## s64 owner. Returns [Snapshot, next offset] or [null, -1] if truncated.
static func _decode_snapshot(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 + 8 + 5 + 12 + 8 > data.size():
		return [null, -1]
	var s := Snapshot.new()
	s.id = data.decode_s64(offset)
	s.item_id = data.decode_s64(offset + 8)
	s.quantity = data.decode_u32(offset + 16)
	s.gold = data.decode_u8(offset + 20) == 1
	s.x = data.decode_float(offset + 21)
	s.y = data.decode_float(offset + 25)
	s.z = data.decode_float(offset + 29)
	s.owner_id = data.decode_s64(offset + 33)
	return [s, offset + 41]

static func decode_snapshot(data: PackedByteArray) -> Snapshot:
	var decoded := _decode_snapshot(data, 0)
	return decoded[0]

static func decode_list_result(data: PackedByteArray) -> ListResult:
	var result := ListResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result
	var count := data.decode_u16(0)
	var offset := 2
	for i in range(count):
		var decoded := _decode_snapshot(data, offset)
		if decoded[0] == null:
			result.error = "truncated item %d" % i
			return result
		result.items.append(decoded[0])
		offset = decoded[1]
	return result

static func decode_removed(data: PackedByteArray) -> Removed:
	if data.size() < 24:
		return null
	var r := Removed.new()
	r.id = data.decode_s64(0)
	r.reason = int(data.decode_s64(8))
	r.picker_id = data.decode_s64(16)
	return r

## OwnerReleased carries only the item id.
static func decode_owner_released(data: PackedByteArray) -> int:
	if data.size() < 8:
		return -1
	return data.decode_s64(0)

static func decode_pick_up_result(data: PackedByteArray) -> PickUpResult:
	if data.size() < 8 + 8 + 8 + 5:
		return null
	var r := PickUpResult.new()
	r.code = int(data.decode_s64(0))
	r.ground_id = data.decode_s64(8)
	r.item_id = data.decode_s64(16)
	r.quantity = data.decode_u32(24)
	r.gold = data.decode_u8(28) == 1
	return r
