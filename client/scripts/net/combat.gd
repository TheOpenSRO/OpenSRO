extends RefCounted
class_name CombatNet

## Opcodes and payload encoding for combat, mirroring
## server/internal/session (combat.go). OpAttack requires a prior
## successful OpEnterWorld.

const OP_ATTACK := 0x0060           # client -> server
const OP_ATTACK_RESULT := 0x0061    # server -> client, direct ack to the attacker
const OP_MONSTER_DAMAGED := 0x0062  # server -> client, broadcast to the zone
const OP_MONSTER_DIED := 0x0063     # server -> client, broadcast to the zone

## Result of decode_attack_result(): both sides of the exchange -- what
## happened to the monster, and what happened to the attacker in the
## monster's counterattack (skipped fields stay 0/false if the monster died).
class AttackResult:
	var error: String
	var monster_damage: int
	var monster_remaining_hp: int
	var monster_died: bool
	var player_damage_taken: int
	var player_hp: int
	var player_died: bool

## Result of decode_monster_damaged().
class MonsterDamaged:
	var monster_id: int
	var damage: int
	var remaining_hp: int

## Encodes an OpAttack request.
static func encode_attack(character_name: String, target_monster_id: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)

	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, target_monster_id)
	out.append_array(id_buf)
	return out

## Decodes an OpAttackResult payload.
static func decode_attack_result(data: PackedByteArray) -> AttackResult:
	var result := AttackResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()

	if offset + 18 > data.size():
		result.error = "truncated result fields"
		return result
	result.monster_damage = data.decode_u32(offset)
	result.monster_remaining_hp = data.decode_u32(offset + 4)
	result.monster_died = data[offset + 8] != 0
	result.player_damage_taken = data.decode_u32(offset + 9)
	result.player_hp = data.decode_u32(offset + 13)
	result.player_died = data[offset + 17] != 0

	return result

## Decodes an OpMonsterDamaged broadcast payload.
static func decode_monster_damaged(data: PackedByteArray) -> MonsterDamaged:
	if data.size() < 16:
		return null
	var m := MonsterDamaged.new()
	m.monster_id = data.decode_s64(0)
	m.damage = data.decode_u32(8)
	m.remaining_hp = data.decode_u32(12)
	return m

## Decodes an OpMonsterDied broadcast payload, returning the monster ID
## (or -1 on truncation).
static func decode_monster_died(data: PackedByteArray) -> int:
	if data.size() < 8:
		return -1
	return data.decode_s64(0)
