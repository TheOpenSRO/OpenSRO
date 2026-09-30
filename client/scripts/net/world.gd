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

## Sitting down and standing up (round 607), on the RETAIL opcodes: the payloads
## are read from both binaries (docs/protocol/opcodes/motion.md), so they are not
## placeholders. The N key sends OP_MOTION_REQUEST with the one byte 4, as the
## client's 0x793b00 -> 0x81e750(4) does, and nothing animates until the server
## answers with OP_STATE_CHANGE {u32 id, u8 kind, u8 value} -- kind 1 is the
## motion state, value 4 sitting and 0 standing (the client's 0x8a80a0 handler).
## The id is the server's character id in the retail u32 field (ours).
const OP_MOTION_REQUEST := 0x704F      # client -> server, u8
const OP_STATE_CHANGE := 0x30BF        # server -> client, broadcast
const STATE_KIND_MOTION := 1
## 0x30BF kind 4: the body mode, 1 = berserk (CGObjChar::SetBodyMode). A value-1
## change carries one more byte (chardata+5), read only then (0x8a80a0).
const STATE_KIND_BODY_MODE := 4
## MOTIONSTATE values, named by the server's own table at .rdata 0x00c63f90.
const MOTION_STAND := 0
const MOTION_SIT := 4
## The server's sit/stand transition, .rdata 0x00b45c10 = 1.5 s: it refuses a
## move or another request for that long after it accepts one.
const MOTION_CHANGE_SECONDS := 1.5

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
	## The client heading the character faces (RemoteFacing's frame), from
	## OpEntityEntered's trailing wire angle (round 637's review follow-up);
	## NAN from a list or an older server, which send none.
	var heading: float = NAN

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
## `relocated` (round 637's review follow-up) adds a trailing flags byte, bit
## 0: the position is one the player was put at, not walked to
## (World3D._position_relocated). Sent only when set; an older server reads
## the three floats and ignores it.
##
## `heading_wire` (round 653, OURS framing of a READ form): a position sent
## while a heading run is in effect (SkyRun, the sky click) sets the flags
## byte's bit 1 and appends retail's own heading form of 0x7021
## (docs/protocol/opcodes/movement.md): kind 0, the command byte
## (SkyRun.COMMAND_FORWARD) and the u16 wire angle. -1 sends none. An older
## server reads bit 0 alone and ignores the rest.
const MOVE_FLAG_RELOCATED := 1
const MOVE_FLAG_HEADING_RUN := 2
const MOVEMENT_KIND_HEADING := 0

static func encode_move(x: float, y: float, z: float, relocated: bool = false, heading_wire: int = -1) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(12)
	out.encode_float(0, x)
	out.encode_float(4, y)
	out.encode_float(8, z)
	var flags := (MOVE_FLAG_RELOCATED if relocated else 0) | (MOVE_FLAG_HEADING_RUN if heading_wire >= 0 else 0)
	if flags != 0:
		out.append(flags)
	if heading_wire >= 0:
		out.append(MOVEMENT_KIND_HEADING)
		out.append(SkyRun.COMMAND_FORWARD)
		out.append(heading_wire & 0xff)
		out.append((heading_wire >> 8) & 0xff)
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
	## True when x/y/z are where the character last stood, read back from its
	## row under the server's -persist-position (round 573), rather than the
	## zone's arrival point: World3D then keeps the position instead of moving
	## the player on to the zone's landing spot (ZONE_SPAWN_LOCAL). One byte
	## after the frame, sent only when set -- server/internal/session/world.go's
	## EnterWorldResult.Restored -- so false from every server that did not
	## restore and from every older one.
	var restored: bool = false
	## The ids among `others` who sit or are sitting down (round 607), from the
	## tail after Restored; empty when nobody sits or from an older server.
	var seated: Array[int] = []
	## This player's own heading, restored with its position (round 637's
	## review follow-up; the last field of the headings tail); NAN from a
	## server that sends none.
	var heading: float = NAN
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
	# Restored (round 573): the byte after the frame, absent -- false -- from a
	# server that did not restore the position or predates the field.
	var after_frame: int = frame[2]
	if result.error == "" and after_frame < data.size():
		result.restored = data[after_frame] != 0
		# Seated (round 607): after Restored, which the server then always
		# writes.
		var seated := _decode_seated(data, after_frame + 1)
		result.seated = seated[0]
		result.error = seated[1]
		# The headings tail (round 637's review follow-up), then this
		# player's own wire angle.
		if result.error == "":
			var heads := _decode_headings(data, int(seated[2]), result.others)
			result.error = heads[0]
			var own: int = heads[1]
			if result.error == "" and own + 2 <= data.size():
				result.heading = RemoteFacing.from_wire_angle(data.decode_u16(own))
	return result

## Reads the Seated tail of an OpEnterWorldResult or OpChangeZoneResult (round
## 607; server/internal/session/world.go's decodeSeated): a u16 count and an
## s64 id per sitter, nothing when nobody sits. Returns [ids, error].
static func _decode_seated(data: PackedByteArray, offset: int) -> Array:
	var ids: Array[int] = []
	if offset >= data.size():
		return [ids, "", offset]
	if offset + 2 > data.size():
		return [ids, "truncated seated count", offset]
	var n := data.decode_u16(offset)
	offset += 2
	for i in range(n):
		if offset + 8 > data.size():
			return [ids, "truncated seated %d" % i, offset]
		ids.append(data.decode_s64(offset))
		offset += 8
	return [ids, "", offset]

## Reads the headings tail after the Seated list of an OpEnterWorldResult or
## OpChangeZoneResult (round 637's review follow-up; the server's
## decodeHeadings): a u16 count equal to the list's length and one u16 wire
## angle per other, set as each snapshot's heading (RemoteFacing.
## from_wire_angle). Nothing there is an older server. Returns [error, next].
static func _decode_headings(data: PackedByteArray, offset: int, others: Array) -> Array:
	if offset >= data.size():
		return ["", offset]
	if offset + 2 > data.size():
		return ["truncated heading count", offset]
	var n := data.decode_u16(offset)
	offset += 2
	if n != others.size():
		return ["%d headings for %d others" % [n, others.size()], offset]
	if offset + 2 * n > data.size():
		return ["truncated headings", offset]
	for i in range(n):
		(others[i] as EntitySnapshot).heading = RemoteFacing.from_wire_angle(data.decode_u16(offset + 2 * i))
	return ["", offset + 2 * n]

## Reads the FrameRegion that trails an OpEnterWorldResult or an
## OpChangeZoneResult (round 570; server/internal/session/world.go's
## decodeFrameRegion is the same rule): a u16-prefixed "x/y" string after the
## entity list. Returns [frame, error, next]: ["", "", offset] when the payload
## ends at the list -- an older server's -- and an error when the field is cut
## short; `next` is the offset just past the field, where an
## OpEnterWorldResult's Restored byte sits (round 573). The field trails the
## list because that is where a client before round 570 stops reading: both
## decoders above returned right after the loop without looking at what was
## left, so it reaches them unread -- and a round-570 client returns right
## after the frame the same way, so the Restored byte reaches it unread.
static func _decode_frame(data: PackedByteArray, offset: int) -> Array:
	if offset >= data.size():
		return ["", "", offset]
	if offset + 2 > data.size():
		return ["", "truncated frame length", offset]
	var frame_len := data.decode_u16(offset)
	offset += 2
	if offset + frame_len > data.size():
		return ["", "truncated frame", offset]
	return [data.slice(offset, offset + frame_len).get_string_from_utf8(), "", offset + frame_len]

## Decodes an OpEntityEntered broadcast payload (a single EntitySnapshot),
## and the heading after it when the server sends one (round 637's review
## follow-up: server EntitySnapshot.EncodeEntered): retail's u16 wire angle,
## turned into the client's heading as NetProcessInNavAndSkill::FUN_008a5640
## and FUN_009c40b0 turn it (RemoteFacing.from_wire_angle).
static func decode_entity_entered(data: PackedByteArray) -> EntitySnapshot:
	var decoded := _decode_entity_snapshot(data, 0)
	var snap: EntitySnapshot = decoded[0]
	var end: int = decoded[1]
	if snap != null and end >= 0 and end + 2 <= data.size():
		snap.heading = RemoteFacing.from_wire_angle(data.decode_u16(end))
	return snap

## Result of decode_entity_moved().
class EntityMoved:
	var character_id: int
	var x: float
	var y: float
	var z: float
	## The mover was put here, not walked here (server EntityMoved.Relocated,
	## a trailing flags byte; round 637's review follow-up): the body is placed
	## and not turned. False from an older server.
	var relocated: bool = false
	## Round 653: the mover is on a heading run (the sky click) and this is
	## its u16 wire angle (retail's heading form, relayed: flags bit 1), or
	## -1. The body faces the run's heading rather than the next position.
	var heading_wire: int = -1

static func decode_entity_moved(data: PackedByteArray) -> EntityMoved:
	if data.size() < 20:
		return null
	var m := EntityMoved.new()
	m.character_id = data.decode_s64(0)
	m.x = data.decode_float(8)
	m.y = data.decode_float(12)
	m.z = data.decode_float(16)
	var flags := int(data[20]) if data.size() > 20 else 0
	m.relocated = (flags & MOVE_FLAG_RELOCATED) != 0
	if (flags & MOVE_FLAG_HEADING_RUN) != 0 and data.size() >= 25 and data[21] == MOVEMENT_KIND_HEADING:
		m.heading_wire = data.decode_u16(23)
	return m

## One OP_STATE_CHANGE broadcast: whose state, which kind, what value.
class StateChange:
	var object_id: int
	var kind: int
	var value: int
	## The kind-4 value-1 byte: chardata+5 on the server, READ -- SetBodyMode's
	## fifth argument (the flag granting param 189's 0.3), which the berserk
	## activation passes as 0 (0x515cc6).
	var extra: int = 0

## Encodes an OP_MOTION_REQUEST: the one requested byte (4 toggles sitting).
static func encode_motion_request(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(1)
	out.encode_u8(0, value)
	return out

## Round 651: `change` noted in a character id -> body mode book (NetClient's
## body_modes): a kind-4 value 1 marks the character berserk, any other kind-4
## value clears it, and other kinds change nothing. Returns whether it was a
## body mode.
static func note_body_mode(modes: Dictionary, change: StateChange) -> bool:
	if change == null or change.kind != STATE_KIND_BODY_MODE:
		return false
	if change.value == 1:
		modes[change.object_id] = 1
	else:
		modes.erase(change.object_id)
	return true

## Decodes an OP_STATE_CHANGE payload, or null when it is short.
static func decode_state_change(data: PackedByteArray) -> StateChange:
	if data.size() < 6:
		return null
	var s := StateChange.new()
	s.object_id = data.decode_u32(0)
	s.kind = data.decode_u8(4)
	s.value = data.decode_u8(5)
	if s.kind == STATE_KIND_BODY_MODE and s.value == 1:
		if data.size() < 7:
			return null
		s.extra = data.decode_u8(6)
	return s

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
	## The ids among `others` who sit (round 607), as on EnterWorldResult.
	var seated: Array[int] = []
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
	if result.error == "":
		var seated := _decode_seated(data, frame[2])
		result.seated = seated[0]
		result.error = seated[1]
		if result.error == "":
			result.error = _decode_headings(data, int(seated[2]), result.others)[0]
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
