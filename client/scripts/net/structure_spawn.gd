extends RefCounted
class_name StructureSpawnNet

## The runtime structures of the game worlds (round 869, lane C1;
## docs/protocol/game_worlds.md 7, forgotten_world.md 4): the Dimension
## hole's gate (CITeleportGate) and the trigger doors (CIEventRuntimeObj),
## which reach the client in the ordinary spawn messages (0x3015 single,
## 0x3017 / 0x3019 / 0x3018 groups) with a structure record. Every width and
## rule below is READ from sro_client.exe unless it says otherwise.
##
## WHICH CLASS (READ, IGIDObject::FUN_009c1fa0 c:0x9c1fa0, the class factory
## FUN_008a6bd0 calls for a plain RefObjID): by the object's type word --
## not bionic, TypeID1 4, TypeID2 1 (c:0x9c1ca0) -> CITeleportGate (class
## 0xef1dac); not bionic, TypeID1 4, TypeID2 2 (c:0x9c1cc0) -> CIEventRuntimeObj
## (0xee77d8). Both are teleportbuilding.txt rows (MEASURED: 19556
## INS_QUEST_TELEPORT 4/1/2, the gate; 36513 STORE_EVENTZONE_DEFAULT 4/2/1, the
## only 4/2 row: the door object). A bionic 1/2/1/4 row (the STRUCTURE_GOD_*
## doors' own characterdata rows) is a monster class (c:0x9c1fa0's 1/2/1 arm,
## CICMonster): the door's MODEL is named through its event zone, not its own
## RefObjID (CIEventRuntimeObj::FUN_00535750 below).
##
## THE RECORD (READ): FUN_008a6bd0's u32 RefObjID, then the class's slot 25:
## - CIRuntimeStruct::vslot_025 (c:0x56dfa0): slot 23 GlobalDataManager::
##   FUN_009c3a70 -- u32 unique id, u16 region, f32 x, y, z, u16 angle (the
##   head every CIGIDObject reads) -- then u8 +0x260, u8 +0x261 (the state:
##   CIEventRuntimeObj draws its model at 0 and removes it at 1), u8 +0x254
##   (1 = an owner rule applies), u8 +0x255 (the access type); type 6: a
##   string (FUN_004f7a70: u16 length + ANSI) at +0x264, the owner's name;
##   any other type: u32 +0x258 (type 7: the owner's party id); then u32
##   +0x25c (the Dimension hole's RefObjID; 0 for none).
## - CITeleportGate::vslot_025 (c:0x9e9eb0) reads nothing more.
## - CIEventRuntimeObj::vslot_025 (c:0x535980): + u32 +0x280 (the event
##   zone's id, eventzonedata.txt column 2) and u8 +0x284.
## - A 0x3015 ends with slot 26 (c:0x9c2180): one u8 (+0xf4).
## MEASURED (the gate): {19556, uid, region, x, y, z, angle, 1, 0, 1, 6,
## str the creator's name, u32 35883} and the 0x3015 trailer 1.
##
## FUN_008a6bd0's two other forms -- a RefObjID of 0xFFFFFFFF (u16 type word
## next; TypeID 5/2 makes class 0xef1c08) and 0xFFFFFFFE (u32, u16) -- are not
## structures of the game worlds and are not read here (NpcSpawnNet refuses
## them, as before).

const KIND_NONE := 0
const KIND_GATE := 1
const KIND_EVENT := 2

## The access types (+0x255; READ s:0x4865a0 on the server, c:0x9e9eb0 here).
const ACCESS_OWNER := 6
const ACCESS_PARTY := 7

## 0x351E {u32 object, u8 field, u8 state} (READ c:0x89a7b0): only field 0x10
## is acted on -- the object's +0x261 set to `state` and its model rebuilt
## (FUN_005359c0 -> CIEventRuntimeObj::FUN_00535750).
const OP_EVENT_ZONE_STATE := 0x351E
const EVENT_FIELD_TRIGGER := 0x10
const STATE_DRAWN := 0
const STATE_REMOVED := 1

class Record:
	var ref_id: int
	var uid: int
	var kind: int
	var region: int
	var region_x: int # the region id's high byte, as NpcSpawnNet keys it
	var region_y: int
	var local_position: Vector3
	var angle: int
	## +0x260 (OPEN), +0x261 the state.
	var b260: int
	var state: int
	## +0x254 (1: an owner rule) and +0x255 (6 a named owner, 7 a party).
	var owned: int
	var access: int
	var owner_name: String = ""
	## +0x258: type 7's party id (any other u32 for another type).
	var owner_id: int
	## +0x25c: the Dimension hole's RefObjID.
	var hole_ref: int
	## CIEventRuntimeObj: +0x280 the event zone, +0x284.
	var zone_id: int
	var b284: int
	## The 0x3015 trailer (-1 in a group).
	var spawn_type := -1

## One structure record of class `kind` from r (the RefObjID first). null
## with r.error set when it is cut short.
static func read_record(r: NpcSpawnNet.Reader, kind: int) -> Record:
	var rec := Record.new()
	rec.kind = kind
	rec.ref_id = r.u32()
	rec.uid = r.u32()
	rec.region = r.u16()
	rec.region_x = (rec.region >> 8) & 0xff
	rec.region_y = rec.region & 0xff
	var x := r.f32()
	var y := r.f32()
	var z := r.f32()
	rec.local_position = Vector3(x, y, z)
	rec.angle = r.u16()
	rec.b260 = r.u8()
	rec.state = r.u8()
	rec.owned = r.u8()
	rec.access = r.u8()
	if rec.access == ACCESS_OWNER:
		var n := r.u16()
		rec.owner_name = r.bytes(n).get_string_from_ascii()
	else:
		rec.owner_id = r.u32()
	rec.hole_ref = r.u32()
	if kind == KIND_EVENT:
		rec.zone_id = r.u32()
		rec.b284 = r.u8()
	if r.error != "":
		return null
	return rec

## A 0x3015 payload read as a structure of class `kind`.
static func decode_single_spawn(data: PackedByteArray, kind: int) -> Record:
	var r := NpcSpawnNet.Reader.new(data)
	var rec := read_record(r, kind)
	if rec == null:
		return null
	rec.spawn_type = r.u8()
	return rec if r.error == "" and r.pos == data.size() else null

## The class a teleportbuilding row's type ids make (c:0x9c1ca0 / 0x9c1cc0;
## the rows are never bionic).
static func kind_of_type(type1: int, type2: int) -> int:
	if type1 != 4:
		return KIND_NONE
	if type2 == 1:
		return KIND_GATE
	if type2 == 2:
		return KIND_EVENT
	return KIND_NONE

## Whether this client draws and picks a gate (READ CITeleportGate::vslot_025
## c:0x9e9eb0): with +0x254 == 1, type 7 returns before the model, the pick box
## and the talk lines when +0x258 is not the player's own party id
## (c:0x9e9f1a..0x9e9f2d: FUN_00986f50()+0x5c); type 6 when the name at +0x264
## is not the player's own (c:0x9e9fbb..0x9e9ff1: FUN_009d6580, the own name,
## compared by CIFDropDownButton::FUN_00657290, which is "not equal"). MEASURED:
## the creator drew the type-6 gate, another member of its party drew nothing.
static func gate_visible(rec: Record, own_name: String, own_party_id: int) -> bool:
	if rec.owned != 1:
		return true
	if rec.access == ACCESS_PARTY:
		return own_party_id != 0 and rec.owner_id == own_party_id
	if rec.access == ACCESS_OWNER:
		return rec.owner_name == own_name
	return true

## 0x351E: {"uid", "field", "state"}, {} when short.
static func decode_event_zone_state(data: PackedByteArray) -> Dictionary:
	if data.size() < 6:
		return {}
	return {"uid": data.decode_u32(0), "field": int(data[4]), "state": int(data[5])}

## The record's bytes (the tests, the QA fixtures; the server's twin writes
## the same order).
static func encode_record(rec: Record) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(26)
	b.encode_u32(0, rec.ref_id)
	b.encode_u32(4, rec.uid)
	b.encode_u16(8, rec.region)
	b.encode_float(10, rec.local_position.x)
	b.encode_float(14, rec.local_position.y)
	b.encode_float(18, rec.local_position.z)
	b.encode_u16(22, rec.angle)
	b[24] = rec.b260 & 0xff
	b[25] = rec.state & 0xff
	b.append(rec.owned & 0xff)
	b.append(rec.access & 0xff)
	if rec.access == ACCESS_OWNER:
		var name := rec.owner_name.to_ascii_buffer()
		var n := PackedByteArray()
		n.resize(2)
		n.encode_u16(0, name.size())
		b.append_array(n)
		b.append_array(name)
	else:
		var w := PackedByteArray()
		w.resize(4)
		w.encode_u32(0, rec.owner_id)
		b.append_array(w)
	var h := PackedByteArray()
	h.resize(4)
	h.encode_u32(0, rec.hole_ref)
	b.append_array(h)
	if rec.kind == KIND_EVENT:
		var z := PackedByteArray()
		z.resize(5)
		z.encode_u32(0, rec.zone_id)
		z[4] = rec.b284 & 0xff
		b.append_array(z)
	return b

## Every structure the server has spawned for this connection and not
## despawned, by uid (NetClient keeps it, as it keeps the NPC roster).
class Roster:
	var structures: Dictionary = {}

	func clear() -> void:
		structures.clear()

	func spawn(rec: Record) -> Record:
		structures[rec.uid] = rec
		return rec

	func despawn(uid: int) -> bool:
		return structures.erase(uid)

	func has(uid: int) -> bool:
		return structures.has(uid)
