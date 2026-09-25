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
## The player's own revive (round 548; docs/protocol/monster_ai.md, "The
## player's dead state"). Two more of srrevamp's own placeholders
## (docs/protocol/PROTOCOL_DECISION.md), free in the world group on
## 2026-09-24: 0x0028/0x0029 appeared in no non-test file under
## server/internal or client/scripts/net. OpRevive is empty; OpReviveResult
## is a u16-prefixed error string, then s32 HP and s32 MP -- the pools the
## character came back with, character.RespawnFraction of their maxima. A
## server sends the result only with its -player-dead-state flag on (the
## server half; off by default), to the reviving session alone.
##
## The retail request is 0x7053 -> GObjPC_HandleResurrectMsg_053 (0x50fee0,
## docs/protocol/server_handlers.tsv), which reads ONE u8 option: 1 returns
## the character to its return point (GObjPC::Revive(0)), 2 revives it where
## it lies -- only while its max level is at most 10 (`cmp al,0xa` at
## 0x51017f on IGObj::GetMaxLevel, vtable +0x128). srrevamp's placeholder
## carries no option and revives in place at any level: a disclosed stand-in.
const OP_REVIVE := 0x0028              # client -> server, empty
const OP_REVIVE_RESULT := 0x0029       # server -> client

## One character's presence in the world: who they are, where they are,
## which real armor pieces + whether a weapon/shield are equipped (the
## server's actual, live equipment-store answer at the moment this
## snapshot was sent -- see server/internal/session/world.go's
## equippedSlots), and their real Gender (CharacterNet.GENDER_CHINA_MAN/
## GENDER_CHINA_WOMAN), which picks which real body/skeleton assets they
## render with.
##
## `equipped` maps each worn slot (EquipmentNet.SLOT_*) to the item id in
## it. The id is what dressing needs: the client's own item table names the
## model every item is worn as, so "slot 1 holds 4842" draws a Cotton Suit
## and nothing else.
class EntitySnapshot:
	var character_id: int
	var char_name: String
	var x: float
	var y: float
	var z: float
	## slot -> item id, for every slot with something in it.
	var equipped: Dictionary = {}
	var gender: String

	func item_in(slot: int) -> int:
		return int(equipped.get(slot, 0))

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
	## Vitals as of entering the world, so the HUD can draw a real health
	## bar immediately. Combat reports player_hp on every attack after that.
	var hp: int
	var max_hp: int
	var others: Array[EntitySnapshot] = []
	## The region x/y/z are relative to, "x/y" -- the server's FrameRegion
	## (round 570), trailing the entity list. "" from an older server, which
	## does not send it; World3D then frames the grid on the zone's own
	## centre, which is what the server's frame was before it named it.
	var frame: String = ""
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

	# One byte of count, then a slot byte and an item id per worn slot.
	if offset + 1 > data.size():
		return [null, -1]
	var worn_count := data[offset]
	offset += 1
	for _i in range(worn_count):
		if offset + 9 > data.size():
			return [null, -1]
		var slot := data[offset]
		var item_id := data.decode_s64(offset + 1)
		offset += 9
		snap.equipped[slot] = item_id

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

	if offset + 8 > data.size():
		result.error = "truncated vitals"
		return result
	result.hp = data.decode_s32(offset)
	result.max_hp = data.decode_s32(offset + 4)
	offset += 8

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

	var frame := _decode_frame(data, offset)
	result.frame = frame[0]
	result.error = frame[1]
	return result

## Reads the FrameRegion that trails an OpEnterWorldResult or an
## OpChangeZoneResult (round 570; server/internal/session/world.go's
## decodeFrameRegion is the same rule): a u16-prefixed "x/y" string after the
## entity list. Returns [frame, error]: ["", ""] when the payload ends at the
## list -- an older server's -- and an error when the field is cut short. The
## field trails the list because that is where a client before round 570
## stops reading: both decoders above returned right after the loop without
## looking at what was left, so it reaches them unread.
static func _decode_frame(data: PackedByteArray, offset: int) -> Array:
	if offset >= data.size():
		return ["", ""]
	if offset + 2 > data.size():
		return ["", "truncated frame length"]
	var frame_len := data.decode_u16(offset)
	offset += 2
	if offset + frame_len > data.size():
		return ["", "truncated frame"]
	return [data.slice(offset, offset + frame_len).get_string_from_utf8(), ""]

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
	var others: Array[EntitySnapshot] = []
	## The region x/y/z are relative to, "x/y" (round 570), as on
	## EnterWorldResult; "" from an older server.
	var frame: String = ""
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
	offset += 12

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

	var frame := _decode_frame(data, offset)
	result.frame = frame[0]
	result.error = frame[1]
	return result

## Encodes an OpRevive request: nothing. The server knows who asks from the
## session, and the retail option byte is not carried (see OP_REVIVE).
static func encode_revive() -> PackedByteArray:
	return PackedByteArray()

## Result of decode_revive_result(): the HP and MP the character came back
## with -- character.RespawnFraction (0.4) of each maximum, the same double
## the retail resurrect handler applies (`GetParam(3) * 0.4` and
## `GetParam(4) * 0.4`, `fmul QWORD PTR ds:0xb460f0` at 0x5100fa and
## 0x510130; 0xb460f0 reads 00 00 00 a0 99 99 d9 3f) -- or why the server
## refused ("not dead", ...). `error` also carries a decode error.
class ReviveResult:
	var error: String
	var hp: int
	var mp: int

## Decodes an OpReviveResult payload: u16 error length, the error, then, when
## the error is empty, s32 HP and s32 MP. A refusal's tail is optional.
static func decode_revive_result(data: PackedByteArray) -> ReviveResult:
	var result := ReviveResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result
	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()
	if result.error != "":
		return result
	if offset + 8 > data.size():
		result.error = "truncated vitals"
		return result
	result.hp = data.decode_s32(offset)
	result.mp = data.decode_s32(offset + 4)
	return result
