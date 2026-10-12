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
## player's dead state"). Two more of OpenSRO's own placeholders
## (docs/protocol/PROTOCOL_DECISION.md), free in the world group on
## 2026-09-24: 0x0028/0x0029 appeared in no non-test file under
## server/internal or client/scripts/net. OpRevive is empty; OpReviveResult
## is a u16-prefixed error string, then s32 HP and s32 MP -- the pools the
## character came back with, character.RespawnFraction of their maxima. A
## server sends the result only with its -player-dead-state flag on (the
## server half; off by default), to the reviving session alone.
##
## The retail request is 0x3053 (the client's FUN_00797d90 pushes 0x3053 at
## 0x797e30; round 665 -- "0x7053" before it was the 0x7000|op precedent) ->
## GObjPC_HandleResurrectMsg_053 (0x50fee0), which reads ONE u8 option: 1
## returns the character to its return point (GObjPC::Revive(0)), 2 revives it
## where it lies -- only while its max level is at most 10 (`cmp al,0xa` at
## 0x51017f on IGObj::GetMaxLevel, vtable +0x128). Since round 665
## OpenSRO's placeholder carries that byte (encode_revive); an empty request
## (a client before it) is read by the server as the one choice the level has.
const OP_REVIVE := 0x0028              # client -> server, u8 option
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
## 0x30BF kind 0xb: a scroll's teleport state (round 779, FUN_004e0b50) --
## (Param2 == 0) + 1 while a return scroll casts, 0 when it ends or is
## cancelled. The client's 0x8a80a0 case 0xb stores it (+0x7c0) and, for its
## own player and value 0, ends the casting bar (DelayInfoBar).
const STATE_KIND_TELEPORT := 0xb
## MOTIONSTATE values, named by the server's own table at .rdata 0x00c63f90.
const MOTION_STAND := 0
## Round 781: the action window's Walk/Run sends 2 (walk) or 3 (run) on the
## same request (0x9d4a00, READ); the answer is the same 0x30BF kind 1 with
## that value, and no transition (FUN_004b1480 case 2/3, READ).
const MOTION_WALK := 2
const MOTION_RUN := 3
const MOTION_SIT := 4
## Round 781: the emotes, on the retail 0x3091 both ways (READ: the client's
## 0x793b00 sends u8; the server's GObjPC::FUN_004b1630 answers {u32 id, u8},
## which the client's FUN_008a7950 plays).
const OP_EMOTE := 0x3091
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
	## The body the character was made from -- one of the 52 creatable Figures'
	## characterdata ids -- and its scale byte (Height low nibble, Volume high),
	## from the round-689 models tails (server EntitySnapshot.RefObjID).
	## has_model is false from an older server, which sends none: World3D then
	## draws the body `gender` names, as before.
	var ref_obj_id: int = 0
	var scale: int = 0x22
	var has_model: bool = false
	## slot -> the worn item's effective plus (OptLevel + advanced elixir;
	## round 735, the server's pluses tail), for the slots whose item has
	## one. A slot not here is +0, which is also what an older server means.
	var pluses: Dictionary = {}
	## Round 737 (a retail spawn record, UserSpawnNet): whether the record's
	## motion byte says SIT -- World3D draws the body seated -- and whether an
	## OpPlayerZoneNotice named it arriving in the zone, as opposed to walking
	## into view -- World3D logs "X entered the zone." only then.
	var seated: bool = false
	var zone_arrival: bool = false
	## Round 749 (the record's mover, 0x48be00): a character spawned while
	## walking to a point (has_dest, dest in world coordinates), or on a
	## heading run (run_wire, the u16 wire angle; -1 for none), and its run
	## speed (the record's param 24; 0 when the message carries none) --
	## World3D walks the body on (FUN_009ca320 aims a body that spawned
	## moving).
	var has_dest: bool = false
	var dest := Vector3.ZERO
	var run_wire: int = -1
	var run_speed: float = 0.0
	## Round 781: the walk speed of a character whose run flag is 0 (it
	## walks, the action window's Walk); 0 when it runs.
	var walk_speed: float = 0.0

	func item_in(slot: int) -> int:
		return int(equipped.get(slot, 0))

	func plus_in(slot: int) -> int:
		return int(pluses.get(slot, 0))

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
##
## `stopped` (round 749, OURS, docs/rounds/r749.md): the flags byte's bit 2 --
## where the walk stopped short of the destination the client's 0x7021 named
## (a wall, an approach in reach, a sit). The server takes it on its own leg
## and relays retail's 0xB023 (DestMoveNet). An older server reads a walked
## position.
const MOVE_FLAG_RELOCATED := 1
const MOVE_FLAG_HEADING_RUN := 2
const MOVE_FLAG_STOPPED := 4
const MOVEMENT_KIND_HEADING := 0

static func encode_move(x: float, y: float, z: float, relocated: bool = false, heading_wire: int = -1, stopped: bool = false) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(12)
	out.encode_float(0, x)
	out.encode_float(4, y)
	out.encode_float(8, z)
	var flags := (MOVE_FLAG_RELOCATED if relocated else 0) | (MOVE_FLAG_HEADING_RUN if heading_wire >= 0 else 0) \
		| (MOVE_FLAG_STOPPED if stopped else 0)
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
	## This player's own model (round 689; EntitySnapshot.ref_obj_id), from the
	## models tail after the wire angle; has_model false from an older server.
	var ref_obj_id: int = 0
	var scale: int = 0x22
	var has_model: bool = false
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
				# The models tail (round 689): this player's own model, then
				# the others'. Nothing there is an older server.
				var tail := own + 2
				if tail < data.size():
					if tail + 5 > data.size():
						result.error = "truncated own model"
						return result
					var ref := data.decode_u32(tail)
					if ref != 0:
						result.ref_obj_id = ref
						result.scale = data[tail + 4]
						result.has_model = true
					var models := _decode_models(data, tail + 5, result.others)
					result.error = models[0]
					# The pluses tail (round 735), after the models.
					if result.error == "":
						result.error = _decode_pluses_list(data, int(models[1]), result.others)[0]
	return result

## Reads the models tail (round 689; the server's decodeModels) of an
## OpEnterWorldResult (after the player's own model) or an OpChangeZoneResult
## (after the headings): a u16 count equal to the list's length and one model
## per other -- a u32 RefObjID and the u8 scale byte; a RefObjID of 0 is an
## other sent without one. Nothing there is an older server. Returns [error, next].
static func _decode_models(data: PackedByteArray, offset: int, others: Array) -> Array:
	if offset >= data.size():
		return ["", offset]
	if offset + 2 > data.size():
		return ["truncated model count", offset]
	var n := data.decode_u16(offset)
	offset += 2
	if n != others.size():
		return ["%d models for %d others" % [n, others.size()], offset]
	if offset + 5 * n > data.size():
		return ["truncated models", offset]
	for i in range(n):
		var ref := data.decode_u32(offset + 5 * i)
		if ref != 0:
			var snap := others[i] as EntitySnapshot
			snap.ref_obj_id = ref
			snap.scale = data[offset + 5 * i + 4]
			snap.has_model = true
	return ["", offset + 5 * n]

## Reads one snapshot's pluses block (round 735; the server's decodePluses):
## a u8 count, then a u8 slot and a u8 plus per entry, onto snap.pluses.
## Retail sends the byte after each item's RefItemID in its 0x3015 spawn
## (CICUser vslot 25, 0x9de2f0, READ); OpenSRO's snapshot carries it in this
## trailing block. Returns [error, next].
static func _decode_pluses(data: PackedByteArray, offset: int, snap: EntitySnapshot) -> Array:
	if offset >= data.size():
		return ["truncated plus count", offset]
	var n := int(data[offset])
	offset += 1
	if offset + 2 * n > data.size():
		return ["truncated pluses", offset]
	for i in range(n):
		snap.pluses[int(data[offset + 2 * i])] = int(data[offset + 2 * i + 1])
	return ["", offset + 2 * n]

## Reads a result's pluses tail (round 735; the server's decodePluses List),
## after the models tail: a u16 count equal to the list's length and one
## block per other. Nothing there is an older server. Returns [error, next].
static func _decode_pluses_list(data: PackedByteArray, offset: int, others: Array) -> Array:
	if offset >= data.size():
		return ["", offset]
	if offset + 2 > data.size():
		return ["truncated pluses count", offset]
	var n := data.decode_u16(offset)
	offset += 2
	if n != others.size():
		return ["%d pluses blocks for %d others" % [n, others.size()], offset]
	for i in range(n):
		var r := _decode_pluses(data, offset, others[i] as EntitySnapshot)
		if r[0] != "":
			return r
		offset = int(r[1])
	return ["", offset]

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
	# The model (round 689; the server's EncodeEntered), after the angle.
	if snap != null and end >= 0 and end + 2 + 5 <= data.size():
		snap.ref_obj_id = data.decode_u32(end + 2)
		snap.scale = data[end + 6]
		snap.has_model = snap.ref_obj_id != 0
	# The pluses (round 735), after the model -- which the server writes as
	# 0/0 when it has none and pluses follow.
	if snap != null and end >= 0 and end + 2 + 5 < data.size():
		_decode_pluses(data, end + 7, snap)
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

## Encodes an OP_EMOTE request: the one emote byte (round 781).
static func encode_emote(emote: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(1)
	out.encode_u8(0, emote & 0xff)
	return out

## Decodes an OP_EMOTE broadcast as [object id, emote byte], or [] when short.
static func decode_emote(data: PackedByteArray) -> Array:
	if data.size() < 5:
		return []
	return [data.decode_u32(0), data.decode_u8(4)]

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
static func encode_change_zone(zone: String, spot: Variant = null) -> PackedByteArray:
	var zone_bytes := zone.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, zone_bytes.size())
	out.append_array(zone_bytes)
	# Round 764 (OURS framing, server ChangeZoneRequest.Spot): the region-local
	# point in the zone's centre region the player will stand at -- the zone
	# box's `@x,z` -- as two trailing f32s, sent only when there is one.
	if spot is Vector2:
		var at := out.size()
		out.resize(at + 8)
		out.encode_float(at, (spot as Vector2).x)
		out.encode_float(at + 4, (spot as Vector2).y)
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
			var heads := _decode_headings(data, int(seated[2]), result.others)
			result.error = heads[0]
			# The models tail (round 689), after the headings.
			if result.error == "":
				var models := _decode_models(data, int(heads[1]), result.others)
				result.error = models[0]
				# The pluses tail (round 735), after the models.
				if result.error == "":
					result.error = _decode_pluses_list(data, int(models[1]), result.others)[0]
	return result

## Encodes an OpRevive request: retail's one option byte (see OP_REVIVE) --
## 1 the return point, 2 the present point. The server knows who asks from
## the session.
static func encode_revive(option: int) -> PackedByteArray:
	return PackedByteArray([option & 0xff])

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
