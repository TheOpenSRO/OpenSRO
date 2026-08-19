extends RefCounted
class_name SkillNet

## Opcodes and payload encoding for learning/using skills, mirroring
## server/internal/session (skill.go). OpUseSkill's response reuses
## CombatNet's OP_ATTACK_RESULT/decode_attack_result -- using a skill is
## just an attack with a damage bonus, same response shape either way.

const OP_LEARN := 0x0070          # client -> server
const OP_LEARN_RESULT := 0x0071   # server -> client
const OP_USE := 0x0072            # client -> server (response: CombatNet.OP_ATTACK_RESULT)

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
