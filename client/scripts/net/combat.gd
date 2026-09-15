extends RefCounted
class_name CombatNet

## Opcodes and payload encoding for combat, mirroring
## server/internal/session (combat.go). OpAttack requires a prior
## successful OpEnterWorld.

const OP_ATTACK := 0x0060           # client -> server
const OP_ATTACK_RESULT := 0x0061    # server -> client, direct ack to the attacker
const OP_MONSTER_DAMAGED := 0x0062  # server -> client, broadcast to the zone
const OP_MONSTER_DIED := 0x0063     # server -> client, broadcast to the zone
const OP_LOOT_DROPPED := 0x0064     # server -> client, direct to the killer (only sent if there's loot)
const OP_MONSTER_LIST := 0x0065     # client -> server
const OP_MONSTER_LIST_RESULT := 0x0066 # server -> client
const OP_LEVEL_UP := 0x0067         # server -> client, direct to the character that levelled
const OP_BERSERK := 0x0068          # client -> server, request to go berserk
const OP_BERSERK_RESULT := 0x0069   # server -> client, the gauge/active after the request

## Result of decode_berserk_result(). activated is true only when this request
## actually started a berserk (the gauge was full); gauge/active are the state.
class BerserkResult:
	var activated: bool
	var gauge: int
	var active: bool

## Encodes an OpBerserk request: just the character name.
static func encode_berserk(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

static func decode_berserk_result(data: PackedByteArray) -> BerserkResult:
	var r := BerserkResult.new()
	if data.size() >= 6:
		r.activated = data[0] != 0
		r.gauge = data.decode_u32(1)
		r.active = data[5] != 0
	return r

## Result of decode_level_up(): the character's new level and its unspent
## stat points, so the client can play the level-up effect and announce it.
class LevelUp:
	var new_level: int
	var stat_points: int

static func decode_level_up(data: PackedByteArray) -> LevelUp:
	var r := LevelUp.new()
	if data.size() >= 8:
		r.new_level = data.decode_u32(0)
		r.stat_points = data.decode_u32(4)
	return r

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
	## The berserk gauge (0..100, five HUD orbs) and whether berserk is active,
	## carried on every attack so the orbs fill as you fight.
	var berserk_gauge: int = 0
	var berserk_active: bool = false
	## Whether the monster's counterattack was a critical. The chance is the
	## species' own characterdata col 78, the doubling is the game's.
	var monster_critical: bool = false
	## Whether the player's blow was a critical -- the equipped weapon's own
	## Critical column (itemdata 116).
	var player_critical: bool = false
	## Whether the player's shield blocked the counterattack outright. A
	## blocked hit deals nothing at all.
	var player_blocked: bool = false
	## Experience lost to the death penalty, 0 when the player did not die or
	## is still inside the level-10 grace period.
	var death_exp_lost: int = 0

## Result of decode_monster_damaged().
class MonsterDamaged:
	var monster_id: int
	var damage: int
	var remaining_hp: int

## One live monster, from decode_monster_list_result().
class MonsterSnapshot:
	var monster_id: int
	var monster_name: String
	## The species' characterdata key (`MOB_CH_MANGNYANG`) -- what the model
	## is resolved by, since the display name depends on which language
	## column the player's archive carries. May be empty.
	var code_name: String
	var x: float
	var y: float
	var z: float
	var max_hp: int
	var hp: int
	## The monster's real level (characterdata _RefObjChar col 57), 0 if unknown.
	var level: int
	## The monster's rank/rarity (characterdata _RefObjChar col 15): 0 normal,
	## 1 champion, 3/8 unique, 4 giant, 5 titan, 6 elite. The target window's
	## rank gem is picked from it (mapping recovered from the retail client).
	var rarity: int

## Result of decode_monster_list_result().
class MonsterListResult:
	var error: String
	var monsters: Array[MonsterSnapshot] = []

## One item dropped from a kill.
class LootDrop:
	var item_id: int
	var quantity: int

## Result of decode_loot_dropped().
class LootDropped:
	var monster_id: int
	var drops: Array[LootDrop] = []

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
	# The berserk tail is appended; an older 18-byte result omits it.
	if offset + 23 <= data.size():
		result.berserk_gauge = data.decode_u32(offset + 18)
		result.berserk_active = data[offset + 22] != 0
	# Each of these was appended in its own turn, so every width in between
	# still decodes and an older server simply reports none of them.
	if offset + 31 <= data.size():
		result.death_exp_lost = data.decode_s64(offset + 23)
	if offset + 32 <= data.size():
		result.monster_critical = data[offset + 31] != 0
	if offset + 33 <= data.size():
		result.player_critical = data[offset + 32] != 0
	if offset + 34 <= data.size():
		result.player_blocked = data[offset + 33] != 0

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

## Decodes an OpLootDropped payload.
static func decode_loot_dropped(data: PackedByteArray) -> LootDropped:
	if data.size() < 10:
		return null
	var result := LootDropped.new()
	result.monster_id = data.decode_s64(0)
	var count := data.decode_u16(8)
	var offset := 10
	for i in range(count):
		if offset + 12 > data.size():
			return null
		var d := LootDrop.new()
		d.item_id = data.decode_s64(offset)
		d.quantity = data.decode_u32(offset + 8)
		result.drops.append(d)
		offset += 12
	return result

## Encodes an OpMonsterList request (no payload -- the server resolves the
## requester's zone from world.Hub).
static func encode_monster_list() -> PackedByteArray:
	return PackedByteArray()

static func _decode_monster_snapshot(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var m := MonsterSnapshot.new()
	m.monster_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	m.monster_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	if offset + 2 > data.size():
		return [null, -1]
	var code_len := data.decode_u16(offset)
	offset += 2
	if offset + code_len > data.size():
		return [null, -1]
	m.code_name = data.slice(offset, offset + code_len).get_string_from_utf8()
	offset += code_len

	if offset + 12 > data.size():
		return [null, -1]
	m.x = data.decode_float(offset)
	m.y = data.decode_float(offset + 4)
	m.z = data.decode_float(offset + 8)
	offset += 12

	if offset + 16 > data.size():
		return [null, -1]
	m.max_hp = data.decode_u32(offset)
	m.hp = data.decode_u32(offset + 4)
	m.level = data.decode_u32(offset + 8)
	m.rarity = data.decode_u32(offset + 12)
	offset += 16

	return [m, offset]

## Decodes an OpMonsterListResult payload.
static func decode_monster_list_result(data: PackedByteArray) -> MonsterListResult:
	var result := MonsterListResult.new()
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

	if offset + 2 > data.size():
		result.error = "truncated monster count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_monster_snapshot(data, offset)
		if decoded[0] == null:
			result.error = "truncated monster %d" % i
			return result
		result.monsters.append(decoded[0])
		offset = decoded[1]

	return result
