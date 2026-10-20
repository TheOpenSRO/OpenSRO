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
## Retail's own opcode and payload (round 785): u32 the picker's id, u8 the
## angle toward the item. sro_client.exe's handler FUN_008a78b0 (registered for
## 0x3036 at 0x87065b) turns the object to it and enters character state 10,
## which plays action type 38 (the body's `_pickup` clip) once. The server
## sends it to the zone after every successful pick, the picker's own client
## included (SR_GameServer.exe FUN_00526090, 0x52643c).
const OP_PICK_UP_MOTION := 0x3036  # server -> zone

## Why an item left the ground (Removed.reason).
const REMOVED_PICKED := 0
const REMOVED_EXPIRED := 1

## The server's refusal codes, the engine's own (GObjPC::CheckCanPickUp).
## 3 is the function's opening result, left standing when the id resolves to
## no item: a drop that is already gone (picked, decayed, or a duplicate
## request for one we just took). 0x1839 is IGObj::CanPick answering 0 -- an
## item whose row says it cannot be picked up at all.
const ERR_NOT_THERE := 3
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
	## The stack instance's name string (round 805): a trade good's buyer's
	## job alias, "" for most items (session.GroundItemSnapshot.Creator).
	var creator := ""

class ListResult:
	var items: Array[Snapshot] = []
	var error := ""

class Removed:
	var id: int
	var reason: int
	var picker_id: int

## 0x3036: who picked something up, and which way it faces as it does.
class PickUpMotion:
	var object_id: int  # u32: a character id's low 32 bits
	var angle: int      # u8

## 0x3036 is exactly 5 bytes; a shorter payload is null.
static func decode_pick_up_motion(data: PackedByteArray) -> PickUpMotion:
	if data.size() < 5:
		return null
	var m := PickUpMotion.new()
	m.object_id = data.decode_u32(0)
	m.angle = data.decode_u8(4)
	return m

## The heading (the client's own, RemoteFacing's [0, 2 pi)) a 0x3036 angle
## byte faces. READ, FUN_008a78b0 (0x8a78f0..0x8a792d): the byte / 255.0
## (0xd83108) * 360.0 (0xdde7a8) * 0.01745329238474369 (0xe1b8d8), through
## FUN_009c40b0 -- the quarter turn and the wrap every wire angle gets
## (RemoteFacing.from_wire_angle) -- into FUN_009c4260, which sets the heading
## at once (no turn).
static func heading_of_pickup_angle(angle: int) -> float:
	var h := (float(angle & 0xff) / 255.0) * 360.0 * 0.01745329238474369 + RemoteFacing.WIRE_QUARTER_TURN
	while h >= RemoteFacing.WIRE_FULL_TURN:
		h -= RemoteFacing.WIRE_FULL_TURN
	return h

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

## OpGroundItemSpawned: the snapshot, then (round 805) its creator as a u16
## length and UTF-8 bytes; a payload without it leaves creator "".
static func decode_snapshot(data: PackedByteArray) -> Snapshot:
	var decoded := _decode_snapshot(data, 0)
	var s: Snapshot = decoded[0]
	if s != null:
		var named := _decode_string(data, int(decoded[1]))
		if named[1] >= 0:
			s.creator = named[0]
	return s

## A u16-length string at offset: [text, next offset], or ["", -1] when it
## is not there whole.
static func _decode_string(data: PackedByteArray, offset: int) -> Array:
	if offset < 0 or offset + 2 > data.size():
		return ["", -1]
	var n := data.decode_u16(offset)
	if offset + 2 + n > data.size():
		return ["", -1]
	return [data.slice(offset + 2, offset + 2 + n).get_string_from_utf8(), offset + 2 + n]

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
	# Round 805: the creators, in order, after the last snapshot (absent from
	# an older server).
	for item in result.items:
		var named := _decode_string(data, offset)
		if named[1] < 0:
			break
		(item as Snapshot).creator = named[0]
		offset = named[1]
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
