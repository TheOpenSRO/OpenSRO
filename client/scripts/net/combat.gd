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
	## The monster this result is about (the one that took monster_damage and
	## counterattacked). 0 when the server predates the field or refused
	## before resolving a target; World3D then falls back to the id it sent.
	var monster_id: int = 0

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

## ---------------------------------------------------------------------------
## The attack-distance rule, so the client can walk into reach BEFORE it asks.
##
## A mirror of server/internal/combat/reach.go (ApproachBand, EffectiveRange,
## InReach), which is the server's reading of the plain-attack tick
## CGCharAutoCommandActor::Tick_Attack (0x004ad8e0). The skill tick 0x004ae590
## computes a band of the same shape, with the skill's Range, ONLY for a skill
## that needs a target: a row with Target_Required 0, or a land-targeted one,
## goes straight to the cast with no band, no reach test and no walk
## (skill_tick_approaches). Its modifiers for the rest -- reqc bit 1, the
## weapon-range +0x250 param, CBRA/WIRU, the Myopia cut
## (docs/protocol/auto_command.md, "The skill tick") -- are not applied by
## srrevamp's skillInReach either, and the client mirrors the server. The
## server decides: firstSwingInReach and skillInReach (session/keepup.go)
## refuse a blow out of reach with "too far away". What the engine does next
## is WALK: phase 1 tests
## Action_IsTargetWithinReach (0x004ad4a0: `int(dist) <= reach + 2`) on every
## tick and, while it fails, GObjPC::MoveTowardObject(target, round(stop))
## (0x004b0350) aims the walk at the stop distance. The retail engine walks the
## attacker on the SERVER; srrevamp's server does not drive player movement,
## so World3D does the walk and only then sends (see World3D._attack_monster).
## docs/protocol/auto_command.md, "The attack tick".

## The BCRadius (characterdata col 50) of every playable body row -- all 52
## CHAR_* rows read 4. combat.PlayerBCRadius, which the server uses for the
## attacker whatever body it has.
const PLAYER_BC_RADIUS := 4
## The +2 world units Action_IsTargetWithinReach (0x004ad4a0) allows:
## `return iVar3 <= param_2 + 2`. combat.ReachSlack.
const REACH_SLACK := 2
## The band edges and factors of Tick_Attack phase 0 (0x004ad8e0), with the
## constants' own addresses as reach.go records them: 4.0 at 0xb45dc0 (at or
## below it the walk stops exactly at reach), 10.0 at 0xb45b44 (above it the
## walk stops at 0.7 of the range, 0.7 at 0xb45ef8), and the 2.0 at 0xb45f30
## the middle band backs off by.
const REACH_SHORT_BAND := 4.0
const REACH_LONG_BAND := 10.0
const REACH_MID_BACKOFF := 2.0
const REACH_LONG_FACTOR := 0.7

## Vector2(stop, reach): the pair the action carries at +0x14/+0x18 --
## where the walk aims, and how far away the blow still lands. caster_bc and
## target_bc are the two BCRadius values; range_units the effective range
## (effective_range), in world units (tenths of a metre, round 247).
##
## At exactly 10 the one `if (10 < r)` guards both adds, so stop and reach
## are the bare BC sum (round 488) -- the server's ApproachBand after that fix.
static func approach_band(caster_bc: int, target_bc: int, range_units: float) -> Vector2:
	var base := float(caster_bc + target_bc)
	var reach := base + range_units
	var stop: float
	if range_units > REACH_LONG_BAND:
		stop = base + REACH_LONG_FACTOR * range_units
	elif range_units > REACH_SHORT_BAND and range_units < REACH_LONG_BAND:
		stop = base + range_units - REACH_MID_BACKOFF
	elif range_units <= REACH_SHORT_BAND:
		stop = base + range_units
	else:
		stop = base
		reach = base
	return Vector2(stop, reach)

## The range a blow uses: the skill's own Range (skilldata col 21, CRefSkill
## +0x92) when it has one, else the weapon's (itemdata col 94, param 33; 0
## unarmed or broken). combat.EffectiveRange.
static func effective_range(skill_range: int, weapon_range: int) -> float:
	return float(skill_range) if skill_range != 0 else float(weapon_range)

## Action_IsTargetWithinReach (0x004ad4a0): the truncated distance against the
## truncated reach plus the slack. combat.InReach.
static func in_reach(distance: float, reach: float) -> bool:
	return int(distance) <= int(reach) + REACH_SLACK

## Whether the skill tick walks into reach before it casts a row with these
## targeting bytes. Tick_UseSkill (0x004ae590) phase 0 reads Target_Required
## (CRefSkill+0x94, skilldata col 22) and jumps straight to 0x4aecfd --
## `mov eax,2 ; call 0x4ac9e0`, phase 2, which posts the cast -- past the band
## and the reach test, in two cases (docs/protocol/auto_command.md, "The skill
## tick", phase 0):
##   0x4ae743  `test al,al ; je 0x4aecfd`: Target_Required 0 -- 115 of the
##             264 level-1 China board rows on the box's skilldata, e.g.
##             SKILL_CH_WATER_SELFHEAL, SKILL_CH_COLD_SHIELD,
##             SKILL_CH_WATER_CUREAREA;
##   0x4ae753  `cmp al,1 ; jne ; cmp [edi+0x96],al ; je 0x4aecfd`:
##             Target_Required 1 with TargetType_Land (+0x96, col 24) 1.
## Every other row computes the band and walks (phase 1). Rows whose
## Basic_Activity (+0x65) is not 2 leave phase 0 even earlier (0x4ae6ea); on
## the box's skilldata all 256 such China board rows carry Target_Required 0,
## so the first case covers them. srrevamp's server accepts the non-damaging
## ones at any distance (session/skill.go's NoCombatParam/ZeroDamage return
## comes before skillInReach) -- see docs/TODO.md, "Attack distance", for the
## damaging Target_Required 0 rows it still reach-gates.
static func skill_tick_approaches(target_required: int, target_land: int) -> bool:
	if target_required == 0:
		return false
	if target_required == 1 and target_land == 1:
		return false
	return true

## Where a walk toward `target` (ground-plane x/z) that stops `stop` units
## short of it ends, starting from `from`: MoveTowardObject's destination.
## A walker already that close stays where it is.
static func approach_point(from: Vector2, target: Vector2, stop: float) -> Vector2:
	var away := from - target
	var gap := away.length()
	if gap <= stop or gap == 0.0:
		return from
	return target + away / gap * stop

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
	if offset + 42 <= data.size():
		result.monster_id = data.decode_s64(offset + 34)

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
