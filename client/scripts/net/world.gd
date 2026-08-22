extends RefCounted
class_name WorldNet

## Opcodes and payload encoding for entering the world and movement,
## mirroring server/internal/session (world.go). OpEnterWorld requires a
## prior successful login; OpMove requires a prior successful OpEnterWorld.

const OP_ENTER_WORLD := 0x0020         # client -> server
const OP_ENTER_WORLD_RESULT := 0x0021  # server -> client
const OP_MOVE := 0x0022                # client -> server, no reply
const OP_ENTITY_ENTERED := 0x0023      # server -> client, broadcast
const OP_ENTITY_MOVED := 0x0024        # server -> client, broadcast
const OP_ENTITY_LEFT := 0x0025         # server -> client, broadcast
const OP_CHANGE_ZONE := 0x0026         # client -> server
const OP_CHANGE_ZONE_RESULT := 0x0027  # server -> client

## One character's presence in the world: who they are, where they are,
## which real armor pieces + whether a weapon/shield are equipped (the
## server's actual, live equipment-store answer at the moment this
## snapshot was sent -- see server/internal/session/world.go's
## equippedSlots), and their real Gender (CharacterNet.GENDER_CHINA_MAN/
## GENDER_CHINA_WOMAN), which picks which real body/skeleton assets they
## render with.
##
## armor_slots_mask is a real per-piece bitmask, one bit per entry in
## EquipmentNet.ARMOR_SLOTS (bit 0 = ARMOR_SLOTS[0], etc.) -- see
## docs/protocol/EQUIP_SLOTS.md for the real slot names/order this
## reflects (HELM, MAIL, SHOULDERGUARD, PANTS, BOOTS).
class EntitySnapshot:
	var character_id: int
	var char_name: String
	var x: float
	var y: float
	var z: float
	var armor_slots_mask: int
	var has_weapon: bool
	var has_shield: bool
	var gender: String

## Encodes an OpEnterWorld request: just a character name.
static func encode_enter_world(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## Encodes an OpMove request: three float32 fields, no length prefix.
static func encode_move(x: float, y: float, z: float) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(12)
	out.encode_float(0, x)
	out.encode_float(4, y)
	out.encode_float(8, z)
	return out

## Result of decode_enter_world_result(): either an error, or the assigned
## zone/position/own real Gender, plus a snapshot of everyone else already
## there.
class EnterWorldResult:
	var ok: bool
	var reason: String
	var zone: String
	var x: float
	var y: float
	var z: float
	var gender: String
	var others: Array[EntitySnapshot] = []
	var error: String # decode error, distinct from a well-formed "not ok" response

## Parses one EntitySnapshot from data starting at offset, returning it
## along with the offset just past it (or -1 on truncation).
static func _decode_entity_snapshot(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var snap := EntitySnapshot.new()
	snap.character_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	snap.char_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	if offset + 12 > data.size():
		return [null, -1]
	snap.x = data.decode_float(offset)
	snap.y = data.decode_float(offset + 4)
	snap.z = data.decode_float(offset + 8)
	offset += 12

	if offset + 1 > data.size():
		return [null, -1]
	snap.armor_slots_mask = data[offset]
	offset += 1

	if offset + 1 > data.size():
		return [null, -1]
	snap.has_weapon = data[offset] != 0
	offset += 1

	if offset + 1 > data.size():
		return [null, -1]
	snap.has_shield = data[offset] != 0
	offset += 1

	if offset + 2 > data.size():
		return [null, -1]
	var gender_len := data.decode_u16(offset)
	offset += 2
	if offset + gender_len > data.size():
		return [null, -1]
	snap.gender = data.slice(offset, offset + gender_len).get_string_from_utf8()
	offset += gender_len

	return [snap, offset]

## Decodes an OpEnterWorldResult payload.
static func decode_enter_world_result(data: PackedByteArray) -> EnterWorldResult:
	var result := EnterWorldResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result

	result.ok = data[0] != 0
	var offset := 1

	if offset + 2 > data.size():
		result.error = "truncated reason length"
		return result
	var reason_len := data.decode_u16(offset)
	offset += 2
	if offset + reason_len > data.size():
		result.error = "truncated reason"
		return result
	result.reason = data.slice(offset, offset + reason_len).get_string_from_utf8()
	offset += reason_len

	if not result.ok:
		return result

	if offset + 2 > data.size():
		result.error = "truncated zone length"
		return result
	var zone_len := data.decode_u16(offset)
	offset += 2
	if offset + zone_len > data.size():
		result.error = "truncated zone"
		return result
	result.zone = data.slice(offset, offset + zone_len).get_string_from_utf8()
	offset += zone_len

	if offset + 12 > data.size():
		result.error = "truncated position"
		return result
	result.x = data.decode_float(offset)
	result.y = data.decode_float(offset + 4)
	result.z = data.decode_float(offset + 8)
	offset += 12

	if offset + 2 > data.size():
		result.error = "truncated gender length"
		return result
	var gender_len := data.decode_u16(offset)
	offset += 2
	if offset + gender_len > data.size():
		result.error = "truncated gender"
		return result
	result.gender = data.slice(offset, offset + gender_len).get_string_from_utf8()
	offset += gender_len

	if offset + 2 > data.size():
		result.error = "truncated entity count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_entity_snapshot(data, offset)
		if decoded[0] == null:
			result.error = "truncated entity %d" % i
			return result
		result.others.append(decoded[0])
		offset = decoded[1]

	return result

## Decodes an OpEntityEntered broadcast payload (a single EntitySnapshot).
static func decode_entity_entered(data: PackedByteArray) -> EntitySnapshot:
	var decoded := _decode_entity_snapshot(data, 0)
	return decoded[0]

## Result of decode_entity_moved().
class EntityMoved:
	var character_id: int
	var x: float
	var y: float
	var z: float

static func decode_entity_moved(data: PackedByteArray) -> EntityMoved:
	if data.size() < 20:
		return null
	var m := EntityMoved.new()
	m.character_id = data.decode_s64(0)
	m.x = data.decode_float(8)
	m.y = data.decode_float(12)
	m.z = data.decode_float(16)
	return m

## Decodes an OpEntityLeft broadcast payload, returning the character ID
## (or -1 on truncation).
static func decode_entity_left(data: PackedByteArray) -> int:
	if data.size() < 8:
		return -1
	return data.decode_s64(0)

## Encodes an OpChangeZone request: a target zone label. Server-side this is
## an opaque string, but a client pointed at real Map.pk2 data is expected
## to pass something shaped like a real region folder/filename pair (e.g.
## "100/100", "102/101" -- see docs/protocol/MAPO_FORMAT.md/MAPM_FORMAT.md),
## since that's the real convention this project's own zone loading (see
## World3D.gd) resolves against.
static func encode_change_zone(zone: String) -> PackedByteArray:
	var zone_bytes := zone.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, zone_bytes.size())
	out.append_array(zone_bytes)
	return out

## Result of decode_change_zone_result(): either an error, or the new
## zone/position (always a fixed spawn point -- see ChangeZoneResult's
## server-side doc comment for why a zone change is a discrete warp, not a
## continuous cross-region walk).
class ChangeZoneResult:
	var ok: bool
	var reason: String
	var zone: String
	var x: float
	var y: float
	var z: float
	var error: String # decode error, distinct from a well-formed "not ok" response

## Decodes an OpChangeZoneResult payload.
static func decode_change_zone_result(data: PackedByteArray) -> ChangeZoneResult:
	var result := ChangeZoneResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result

	result.ok = data[0] != 0
	var offset := 1

	if offset + 2 > data.size():
		result.error = "truncated reason length"
		return result
	var reason_len := data.decode_u16(offset)
	offset += 2
	if offset + reason_len > data.size():
		result.error = "truncated reason"
		return result
	result.reason = data.slice(offset, offset + reason_len).get_string_from_utf8()
	offset += reason_len

	if not result.ok:
		return result

	if offset + 2 > data.size():
		result.error = "truncated zone length"
		return result
	var zone_len := data.decode_u16(offset)
	offset += 2
	if offset + zone_len > data.size():
		result.error = "truncated zone"
		return result
	result.zone = data.slice(offset, offset + zone_len).get_string_from_utf8()
	offset += zone_len

	if offset + 12 > data.size():
		result.error = "truncated position"
		return result
	result.x = data.decode_float(offset)
	result.y = data.decode_float(offset + 4)
	result.z = data.decode_float(offset + 8)

	return result
