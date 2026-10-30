extends RefCounted
class_name CosNet

## Round 795: the COS messages -- a summoned pet's, ride's or transport's data
## and the requests that command it -- as sro_client.exe reads and writes
## them (docs/protocol/pets.md, "Round 795"; the server's twin is
## server/internal/cos/wire.go). Every integer little-endian; a string is a
## u16 length and its bytes.

const OP_DATA := 0x30C8
const OP_UPDATE := 0x30C9
const OP_OWNER_STATE := 0x30CA
const OP_ITEM_STATE := 0x3040
const OP_LEVEL_UP := 0x3054
const OP_SPEED := 0x30D0
const OP_COMMAND := 0x70C5
const OP_COMMAND_ACK := 0xB0C5
const OP_TERMINATE := 0x70C6
const OP_TERMINATE_ACK := 0xB0C6
const OP_RIDE := 0x70CB
const OP_RIDE_ACK := 0xB0CB
const OP_UNSUMMON := 0x7116
const OP_UNSUMMON_ACK := 0xB116
const OP_NAME := 0x7117
const OP_NAME_ACK := 0xB117
const OP_SETTING := 0x7420
const OP_SETTING_ACK := 0xB420

## The summoned row's TypeID4.
const KIND_RIDE := 1
const KIND_TRANSPORT := 2
const KIND_GROWTH := 3
const KIND_ABILITY := 4
const KIND_SOLDIER := 5

## 0x30C9's types (c:FUN_008aa340).
const UPDATE_REMOVED := 1
const UPDATE_INVENTORY := 2
const UPDATE_EXP := 3
const UPDATE_HGP := 4
const UPDATE_NAME := 5
const UPDATE_REF := 7

## 0x70C5's commands (c:FUN_007a0980, c:FUN_009ebd10).
const COMMAND_MOVE := 1
const COMMAND_ATTACK := 2
const COMMAND_PICK := 8
const COMMAND_FOLLOW := 9

## 0x7420's kinds: a growth pet's AI mode, an ability pet's pickup flags.
const SETTING_AI := 1
const SETTING_PICKUP := 2
const PICK_GOLD := 0x01
const PICK_EQUIPMENT := 0x02
const PICK_OTHER := 0x04
const PICK_ALL := 0x40
const PICK_ON := 0x80

## A summon item's state byte (item record, 0x3040 mask 0x40).
const ITEM_STATE_NONE := 1
const ITEM_STATE_SUMMONED := 2
const ITEM_STATE_STORED := 3
const ITEM_STATE_DEAD := 4

## 0xB034's pet-bag types (cosbag.go).
const BAG_COS_TO_COS := 0x10
const BAG_PICK := 0x11
const BAG_COS_TO_BAG := 0x1a
const BAG_BAG_TO_COS := 0x1b

const BAG_WIRE_OFFSET := 13

## The HGP gauge's full value and the 30 % line.
const HGP_FULL := 10000
const HGP_LOW := 3000

## The client's COS kind byte (COSData +0x14, c:0x9a19ee..0x9a1aa8): 0 ride, 1
## transport, 2 ability pet, 3 growth pet, 4 guild soldier.
static func client_kind(type4: int) -> int:
	match type4:
		KIND_RIDE: return 0
		KIND_TRANSPORT: return 1
		KIND_ABILITY: return 2
		KIND_GROWTH: return 3
	return 4

static func is_pet(type4: int) -> bool:
	return type4 == KIND_GROWTH or type4 == KIND_ABILITY

## The owner's 0x30C8.
class Data:
	var uid: int
	var ref_id: int
	var kind: int
	var hp: int
	var mp: int
	var exp: int
	var level: int = 1
	var hgp: int = HGP_FULL
	var pet_option: int
	var name := ""
	var inv_size: int
	## bag slot -> ItemInstance
	var items := {}
	var owner_uid: int
	## The summon item's bag index (the wire's slot - 13); -1 for none.
	var item_slot := -1
	var error := ""

static func _str(r: NpcSpawnNet.Reader) -> String:
	return r.bytes(r.u16()).get_string_from_utf8()

## Reads the bag block: u8 size, then [u8 n, n x (u8 slot, item record)].
static func _read_bag(data: PackedByteArray, r: NpcSpawnNet.Reader, into: Dictionary) -> int:
	var size := r.u8()
	if size == 0 or r.error != "":
		return size
	var n := r.u8()
	for i in n:
		var slot := r.u8()
		if r.error != "":
			return size
		# The whole record, its rent word first (c:FUN_0099dbd0 ->
		# SOItem::FUN_008be4f0, which starts with the rent block FUN_008bb130).
		var rec := ItemInstance.read_record(data, r.pos)
		if rec[0] == null:
			r.error = "a COS bag record does not read"
			return size
		var it: ItemInstance = rec[0]
		it.slot = slot
		into[slot] = it
		r.pos = rec[1]
	return size

## 0x30C8 (c:COSDataMgr::FUN_009a1900); kind_of answers a RefObjID's TypeID4.
static func decode_data(data: PackedByteArray, kind_of: Callable) -> Data:
	var d := Data.new()
	var r := NpcSpawnNet.Reader.new(data)
	d.uid = r.u32()
	d.ref_id = r.u32()
	d.kind = int(kind_of.call(d.ref_id)) if kind_of.is_valid() else 0
	d.hp = r.u32()
	d.mp = r.u32()
	if d.kind == KIND_GROWTH:
		d.exp = r.u32() | (r.u32() << 32)
		d.level = r.u8()
		d.hgp = r.u16()
	if is_pet(d.kind):
		d.pet_option = r.u32()
		d.name = _str(r)
	d.inv_size = _read_bag(data, r, d.items)
	if is_pet(d.kind) or d.kind == KIND_TRANSPORT:
		d.owner_uid = r.u32()
	if is_pet(d.kind):
		d.item_slot = r.u8() - BAG_WIRE_OFFSET
	d.error = r.error
	return d

## A 0x30C9.
class Update:
	var uid: int
	var type: int
	var inv_size: int
	var items := {}
	var exp_delta: int
	var source: int
	var hgp: int
	var name := ""
	var ref_id: int
	var error := ""

static func decode_update(data: PackedByteArray) -> Update:
	var u := Update.new()
	var r := NpcSpawnNet.Reader.new(data)
	u.uid = r.u32()
	u.type = r.u8()
	match u.type:
		UPDATE_INVENTORY:
			u.inv_size = _read_bag(data, r, u.items)
		UPDATE_EXP:
			var lo := r.u32()
			var hi := r.u32()
			u.exp_delta = lo | (hi << 32)
			u.source = r.u32()
		UPDATE_HGP:
			u.hgp = r.u16()
		UPDATE_NAME:
			u.name = _str(r)
		UPDATE_REF, 6:
			u.ref_id = r.u32()
	u.error = r.error
	return u

## 0x30CA: {uid, job, pvp} (a field absent from the mask is -1).
static func decode_owner_state(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := {"uid": r.u32(), "job": -1, "pvp": -1}
	var mask := r.u8()
	if mask & 1:
		out["job"] = r.u8()
	if mask & 2:
		out["pvp"] = r.u8()
	return out

## 0x3040 (s:GObjPC::FUN_004efa00): {slot (bag index), mask, state, rent_secs,
## ref} -- the COS fields and mask 1's RefItemID; the others are read past.
static func decode_item_state(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := {"slot": r.u8() - BAG_WIRE_OFFSET, "mask": 0, "state": -1, "rent_secs": -1, "ref": -1}
	var mask := r.u8()
	out["mask"] = mask
	# Round 843: mask 1's new RefItemID (a switcher's result) -- its slot
	# flashes (RepairFlash.play_switch_on).
	if mask & 0x01:
		out["ref"] = r.u32()
	if mask & 0x02:
		r.u8()
	if mask & 0x04:
		r.bytes(8)
	if mask & 0x08:
		r.u16()
	elif mask & 0x10:
		r.u32()
	if mask & 0x20:
		r.bytes(8 * r.u8())
	if mask & 0x40:
		out["state"] = r.u8()
	if mask & 0x80:
		out["rent_secs"] = r.u32()
	out["error"] = r.error
	return out

## 0xB0CB: {ok, code, rider, mounted, cos}.
static func decode_ride_ack(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var ok := r.u8() == 1
	if not ok:
		return {"ok": false, "code": r.u16()}
	return {"ok": true, "code": 0, "rider": r.u32(), "mounted": r.u8() == 1, "cos": r.u32()}

## 0xB0C5 (c:0x872590): {ok, type, code, cos, item}.
static func decode_command_ack(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var ok := r.u8() == 1
	var t := r.u8()
	var out := {"ok": ok, "type": t, "code": 0, "cos": 0, "item": 0}
	if not ok:
		out["code"] = r.u16()
	out["cos"] = r.u32()
	if t == COMMAND_PICK:
		out["item"] = r.u32()
	return out

## A two-field reply (0xB0C6, 0xB116, 0xB117): {ok, code}.
static func decode_reply(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var ok := r.u8() == 1
	return {"ok": ok, "code": 0 if ok else r.u16()}

## 0xB420: {ok, code, uid, kind, value}.
static func decode_setting_ack(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	if r.u8() != 1:
		return {"ok": false, "code": r.u16()}
	return {"ok": true, "code": 0, "uid": r.u32(), "kind": r.u8(), "value": r.u32()}

## 0x30D0: {uid, walk, run}.
static func decode_speed(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	return {"uid": r.u32(), "walk": r.f32(), "run": r.f32()}

## 0xB034's pet-bag forms: {ok, code, type, cos, src, dst, slot, item}.
static func decode_bag_op(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	if r.u8() != 1:
		return {"ok": false, "code": r.u16()}
	var t := r.u8()
	var out := {"ok": true, "code": 0, "type": t, "cos": r.u32(), "src": -1, "dst": -1, "slot": -1, "item": null}
	if t == BAG_PICK:
		out["slot"] = r.u8()
		var rec := ItemInstance.read_record(data, r.pos)
		if rec[0] != null:
			out["item"] = rec[0]
	else:
		out["src"] = r.u8()
		out["dst"] = r.u8()
	return out

static func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

## 0x70C5 {uid, 1, movement}: a ridden COS's move (the 0x7021 body).
static func encode_command_move(uid: int, movement: PackedByteArray) -> PackedByteArray:
	var out := _u32(uid)
	out.append(COMMAND_MOVE)
	out.append_array(movement)
	return out

static func encode_command_target(uid: int, command: int, target: int) -> PackedByteArray:
	var out := _u32(uid)
	out.append(command)
	out.append_array(_u32(target))
	return out

static func encode_command_follow(uid: int) -> PackedByteArray:
	var out := _u32(uid)
	out.append(COMMAND_FOLLOW)
	return out

static func encode_uid(uid: int) -> PackedByteArray:
	return _u32(uid)

## 0x70CB {u8 1 mount / 0 dismount, u32 uid}.
static func encode_ride(mount: bool, uid: int) -> PackedByteArray:
	var out := PackedByteArray([1 if mount else 0])
	out.append_array(_u32(uid))
	return out

## 0x7117 {u32 uid, string name}.
static func encode_name(uid: int, name: String) -> PackedByteArray:
	var out := _u32(uid)
	var b := name.to_utf8_buffer()
	out.append(b.size() & 0xff)
	out.append((b.size() >> 8) & 0xff)
	out.append_array(b)
	return out

## 0x7420 {u32 uid, u8 kind, u32 value}.
static func encode_setting(uid: int, kind: int, value: int) -> PackedByteArray:
	var out := _u32(uid)
	out.append(kind)
	out.append_array(_u32(value))
	return out

## 0x7034's pet-bag moves: 0x10 {uid, src, dst, u16 count}, 0x1a {uid, pet
## slot, bag + 13}, 0x1b {uid, bag + 13, pet slot}.
static func encode_bag_move(t: int, uid: int, src: int, dst: int, count: int = 1) -> PackedByteArray:
	var out := PackedByteArray([t])
	out.append_array(_u32(uid))
	out.append(src & 0xff)
	out.append(dst & 0xff)
	if t == BAG_COS_TO_COS:
		out.append(count & 0xff)
		out.append((count >> 8) & 0xff)
	return out
