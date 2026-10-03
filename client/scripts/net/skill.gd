extends RefCounted
class_name SkillNet

## Opcodes and payload encoding for learning/using skills, mirroring
## server/internal/session (skill.go). OpUseSkill's response reuses
## CombatNet's OP_ATTACK_RESULT/decode_attack_result -- using a skill is
## just an attack with a damage bonus, same response shape either way.

const OP_LEARN := 0x0070          # client -> server
const OP_LEARN_RESULT := 0x0071   # server -> client
const OP_USE := 0x0072            # client -> server (response: CombatNet.OP_ATTACK_RESULT)
const OP_LIST := 0x0073           # client -> server
const OP_LIST_RESULT := 0x0074    # server -> client
# The skill economy: the character's skill points + per-mastery levels, and
# raising a mastery by spending points (what the skill window is driven by).
const OP_STATE := 0x0075          # client -> server
const OP_STATE_RESULT := 0x0076   # server -> client
const OP_RAISE := 0x0077          # client -> server
const OP_RAISE_RESULT := 0x0078   # server -> client
# Buffs and the Ghost Walk move (round 617, the client half of the skills
# epic's shared contract, docs/protocol/auto_command.md "OpenSRO's cast and
# buff messages"; OURS -- OpenSRO's own
# protocol, with retail analogues 0xB0BD / 0xB072 / 0x7074 kind 5 / 0xB070).
const OP_BUFF_START := 0x00F5     # server -> client (the region)
const OP_BUFF_END := 0x00F6       # server -> client (the region)
const OP_BUFF_CANCEL := 0x00F7    # client -> server
const OP_SKILL_MOVE := 0x00F8     # server -> client (the region)
const OP_SELF_ID := 0x00F9        # server -> client, on world entry: {i64 characterId}
## OpSkillCast (round 622): someone else in the zone cast a skill -- its
## start, then its act (retail 0xB070 result 1 / 0xB071 kind 1). The caster's
## own client is not sent it.
const OP_SKILL_CAST := 0x00FA     # server -> client (the zone, not the caster)

## OpBuffStart / OpBuffEnd's trailing ownerKind (the contract's review
## follow-up): whose id ownerId is.
const OWNER_CHARACTER := 0
const OWNER_MONSTER := 1

## OpUseSkill's targetType suffix (round 617, §4.0 of the contract): what the
## cast is aimed at. 0 nothing / the caster itself, 1 an entity (the
## targetMonsterId field), 2 a point on the ground (three f32 follow). A
## request without the byte -- every client before round 617 -- reads as 1.
const TARGET_NONE := 0
const TARGET_ENTITY := 1
const TARGET_GROUND := 2
## Round 622: the targetMonsterId field names a CHARACTER (a heal or a party
## buff on another player, or on oneself). Monster and character ids overlap,
## so the kind travels with the id. No point follows.
const TARGET_CHARACTER := 3

## OpSkillCast's phases.
const CAST_START := 0
const CAST_ACT := 1

## Encodes an OpLearnSkill request.
static func encode_learn(character_name: String, skill_id: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)

	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, skill_id)
	out.append_array(id_buf)
	return out

## Encodes an OpUseSkill request: {name, i64 skillId, i64 targetMonsterId,
## u8 targetType, [targetType 2: f32 x, f32 y, f32 z]}. The type byte and the
## point are a strict suffix (round 617), so a server that predates them
## reads the first three fields exactly as before and ignores the rest.
## `point` is read only for TARGET_GROUND, and is in the coordinates OpMove
## sends (World3D's player.position space).
static func encode_use(character_name: String, skill_id: int, target_monster_id: int,
		target_type: int = TARGET_ENTITY, point: Vector3 = Vector3.ZERO) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)

	var buf := PackedByteArray()
	buf.resize(17 if target_type != TARGET_GROUND else 29)
	buf.encode_s64(0, skill_id)
	buf.encode_s64(8, target_monster_id)
	buf[16] = target_type
	if target_type == TARGET_GROUND:
		buf.encode_float(17, point.x)
		buf.encode_float(21, point.y)
		buf.encode_float(25, point.z)
	out.append_array(buf)
	return out

## Encodes an OpBuffCancel request: {name, i64 skillId, u32 token} -- the
## right-click on a buff icon (retail 0x7074 kind 5, sender 0x81c5b0). The
## server refuses an `nbuf` skill silently (skills_spec §2.5 item 7).
static func encode_buff_cancel(character_name: String, skill_id: int, token: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var buf := PackedByteArray()
	buf.resize(12)
	buf.encode_s64(0, skill_id)
	buf.encode_u32(8, token)
	out.append_array(buf)
	return out

## OpBuffStart: a buff began on an owner (a character or a monster) --
## {i64 ownerId, i64 skillId, u32 token, i64 durationMs (-1 = none),
## i64 remainingMs, u32 runSpeed (the owner's new, 0 = unchanged),
## u8 ownerKind (0 character, 1 monster; a trailing suffix -- absent, it
## reads 0 and owner_kind_sent is false)}.
## The token is the server's own per-application id; icons and auras are
## keyed by (owner_id, token).
class BuffStart:
	var owner_id: int
	var skill_id: int
	var token: int
	var duration_ms: int
	var remaining_ms: int
	var run_speed: int
	var owner_kind: int = OWNER_CHARACTER
	var owner_kind_sent: bool = false

const BUFF_START_SIZE := 40

## Decodes an OpBuffStart payload; null when it is short.
static func decode_buff_start(data: PackedByteArray) -> BuffStart:
	if data.size() < BUFF_START_SIZE:
		return null
	var b := BuffStart.new()
	b.owner_id = data.decode_s64(0)
	b.skill_id = data.decode_s64(8)
	b.token = data.decode_u32(16)
	b.duration_ms = data.decode_s64(20)
	b.remaining_ms = data.decode_s64(28)
	b.run_speed = data.decode_u32(36)
	if data.size() >= BUFF_START_SIZE + 1:
		b.owner_kind = data[BUFF_START_SIZE]
		b.owner_kind_sent = true
	return b

## OpBuffEnd: buffs ended on an owner -- {i64 ownerId, u8 count,
## count x u32 token, u32 runSpeed (the owner's new, 0 = unchanged),
## u8 ownerKind (trailing, as OpBuffStart's)}.
class BuffEnd:
	var owner_id: int
	var tokens: Array[int] = []
	var run_speed: int
	var owner_kind: int = OWNER_CHARACTER
	var owner_kind_sent: bool = false

## Decodes an OpBuffEnd payload; null when it is short.
static func decode_buff_end(data: PackedByteArray) -> BuffEnd:
	if data.size() < 9:
		return null
	var e := BuffEnd.new()
	e.owner_id = data.decode_s64(0)
	var count: int = data[8]
	if data.size() < 9 + count * 4 + 4:
		return null
	for i in count:
		e.tokens.append(data.decode_u32(9 + i * 4))
	e.run_speed = data.decode_u32(9 + count * 4)
	if data.size() >= 9 + count * 4 + 5:
		e.owner_kind = data[9 + count * 4 + 4]
		e.owner_kind_sent = true
	return e

## OpSkillMove: a skill moved a character to a point -- Ghost Walk's landing
## {i64 characterId, i64 skillId, f32 x, f32 y, f32 z}, in OpMove's
## coordinates.
class SkillMove:
	var character_id: int
	var skill_id: int
	var x: float
	var y: float
	var z: float

const SKILL_MOVE_SIZE := 28

## Decodes an OpSkillMove payload; null when it is short.
static func decode_skill_move(data: PackedByteArray) -> SkillMove:
	if data.size() < SKILL_MOVE_SIZE:
		return null
	var m := SkillMove.new()
	m.character_id = data.decode_s64(0)
	m.skill_id = data.decode_s64(8)
	m.x = data.decode_float(16)
	m.y = data.decode_float(20)
	m.z = data.decode_float(24)
	return m

## OpSkillCast (round 622): {i64 casterId, u8 casterKind (0 character,
## 1 monster), i64 skillId, u32 castId, u8 phase (0 start, 1 act),
## u8 targetType (0 none, 1 monster, 2 ground, 3 character), i64 targetId,
## f32 x, f32 y, f32 z} -- 43 bytes. castId pairs a start with its act; the
## point is the ground target for targetType 2.
class SkillCast:
	var caster_id: int
	var caster_kind: int
	var skill_id: int
	var cast_id: int
	var phase: int
	var target_type: int
	var target_id: int
	var x: float
	var y: float
	var z: float

const SKILL_CAST_SIZE := 43

## Decodes an OpSkillCast payload; null when it is short.
static func decode_skill_cast(data: PackedByteArray) -> SkillCast:
	if data.size() < SKILL_CAST_SIZE:
		return null
	var c := SkillCast.new()
	c.caster_id = data.decode_s64(0)
	c.caster_kind = data[8]
	c.skill_id = data.decode_s64(9)
	c.cast_id = data.decode_u32(17)
	c.phase = data[21]
	c.target_type = data[22]
	c.target_id = data.decode_s64(23)
	c.x = data.decode_float(31)
	c.y = data.decode_float(35)
	c.z = data.decode_float(39)
	return c

## Result of decode_learn_result().
class LearnResult:
	var ok: bool
	var reason: String
	var error: String

## Decodes an OpLearnSkillResult payload (same OK/Reason shape as
## Auth.decode_result).
static func decode_learn_result(data: PackedByteArray) -> LearnResult:
	var result := LearnResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result

	var ok := data[0] != 0
	if data.size() < 3:
		result.error = "truncated reason length prefix"
		return result

	var reason_len := data.decode_u16(1)
	if 3 + reason_len > data.size():
		result.error = "declared reason length %d exceeds remaining bytes" % reason_len
		return result

	result.ok = ok
	result.reason = data.slice(3, 3 + reason_len).get_string_from_utf8()
	return result

## Encodes an OpSkillList request.
static func encode_list(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## One catalog skill, with the requesting character's own real relationship
## to it -- mirrors session.SkillSnapshot (Go).
class SkillSnapshot:
	var skill_id: int
	var skill_name: String
	var damage_bonus: int
	var cooldown_seconds: int
	var known: bool
	var ready_seconds: int

## Result of decode_list_result().
class SkillListResult:
	var error: String
	var skills: Array[SkillSnapshot] = []

static func _decode_skill_snapshot(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var s := SkillSnapshot.new()
	s.skill_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	s.skill_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	if offset + 13 > data.size():
		return [null, -1]
	s.damage_bonus = data.decode_u32(offset)
	s.cooldown_seconds = data.decode_u32(offset + 4)
	s.known = data[offset + 8] != 0
	s.ready_seconds = data.decode_u32(offset + 9)
	offset += 13

	return [s, offset]

## Decodes an OpSkillListResult payload.
static func decode_list_result(data: PackedByteArray) -> SkillListResult:
	var result := SkillListResult.new()
	if data.size() < 2:
		result.error = "truncated error length prefix"
		return result
	var error_len := data.decode_u16(0)
	if 2 + error_len > data.size():
		result.error = "declared error length %d exceeds remaining bytes" % error_len
		return result
	var offset := 2 + error_len
	if error_len > 0:
		result.error = data.slice(2, offset).get_string_from_utf8()
		return result

	if offset + 2 > data.size():
		result.error = "truncated skill count"
		return result
	var count := data.decode_u16(offset)
	offset += 2
	for i in range(count):
		var decoded := _decode_skill_snapshot(data, offset)
		if decoded[0] == null:
			result.error = "truncated skill %d" % i
			return result
		result.skills.append(decoded[0])
		offset = decoded[1]
	return result

## Encodes an OpSkillState request (character name only -- same shape as a
## skill-list request).
static func encode_state_request(character_name: String) -> PackedByteArray:
	return encode_list(character_name)

## The character's skill economy state -- mirrors session.SkillStateResult (Go).
class SkillState:
	var error: String
	var level: int
	var skill_points: int
	var mastery_levels: Dictionary = {}   ## mastery id -> trained level
	var known_skills: Dictionary = {}     ## unique skill id -> true (a set)

## Decodes an OpSkillStateResult payload.
static func decode_state_result(data: PackedByteArray) -> SkillState:
	var s := SkillState.new()
	if data.size() < 2:
		s.error = "truncated error length prefix"
		return s
	var error_len := data.decode_u16(0)
	if 2 + error_len > data.size():
		s.error = "declared error length %d exceeds remaining bytes" % error_len
		return s
	var offset := 2 + error_len
	if error_len > 0:
		s.error = data.slice(2, offset).get_string_from_utf8()
		return s
	if offset + 10 > data.size():
		s.error = "truncated state header"
		return s
	s.level = data.decode_u32(offset)
	s.skill_points = data.decode_u32(offset + 4)
	var count := data.decode_u16(offset + 8)
	offset += 10
	for i in range(count):
		if offset + 12 > data.size():
			s.error = "truncated mastery %d" % i
			return s
		s.mastery_levels[data.decode_s64(offset)] = data.decode_u32(offset + 8)
		offset += 12
	# Known (learned) skills: a u16 count then that many s64 unique ids.
	if offset + 2 <= data.size():
		var kcount := data.decode_u16(offset)
		offset += 2
		for i in range(kcount):
			if offset + 8 > data.size():
				break
			s.known_skills[data.decode_s64(offset)] = true
			offset += 8
	return s

## Encodes an OpRaiseMastery request (name + mastery id -- same shape as a
## learn request).
static func encode_raise_mastery(character_name: String, mastery_id: int) -> PackedByteArray:
	return encode_learn(character_name, mastery_id)

## Result of an OpRaiseMastery -- mirrors session.RaiseMasteryResult (Go); the
## mastery id, its new level and the remaining skill points are always present
## (zero on an error).
class RaiseMasteryResult:
	var error: String
	var mastery_id: int
	var new_level: int
	var skill_points: int

## Decodes an OpRaiseMasteryResult payload.
static func decode_raise_mastery_result(data: PackedByteArray) -> RaiseMasteryResult:
	var r := RaiseMasteryResult.new()
	if data.size() < 2:
		r.error = "truncated error length prefix"
		return r
	var error_len := data.decode_u16(0)
	if 2 + error_len > data.size():
		r.error = "declared error length %d exceeds remaining bytes" % error_len
		return r
	var offset := 2 + error_len
	if error_len > 0:
		r.error = data.slice(2, offset).get_string_from_utf8()
	if offset + 16 > data.size():
		if r.error == "":
			r.error = "truncated raise result"
		return r
	r.mastery_id = data.decode_s64(offset)
	r.new_level = data.decode_u32(offset + 8)
	r.skill_points = data.decode_u32(offset + 12)
	return r

## Decodes an OpSelfId payload -- this client's own character id, the one
## OpBuffStart / OpSkillMove / the state change name it by -- or -1 when it
## is short.
static func decode_self_id(data: PackedByteArray) -> int:
	if data.size() < 8:
		return -1
	return data.decode_s64(0)
