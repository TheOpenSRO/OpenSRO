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

## Encodes an OpUseSkill request.
static func encode_use(character_name: String, skill_id: int, target_monster_id: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)

	var buf := PackedByteArray()
	buf.resize(16)
	buf.encode_s64(0, skill_id)
	buf.encode_s64(8, target_monster_id)
	out.append_array(buf)
	return out

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
