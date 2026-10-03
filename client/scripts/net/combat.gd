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
## OpenSRO's own monster messages (placeholders, additive; layouts in
## docs/protocol/monster_ai.md, "OpenSRO's own monster protocol
## (placeholders)"). The server sends 0x007C/0x007F only with its -monster-ai
## flag on, 0x007D only with -monster-strike-push (round 541) and 0x007E only
## with -monster-spawn-push (round 542); all three flags are off by default,
## and round 540 built the client half first. World3D draws all four.
const OP_MONSTER_MOVED := 0x007c        # server -> every session in the zone, one monster's new leg
const OP_MONSTER_ATTACKED := 0x007d     # server -> every session in the zone, the attacker too: one monster's blow
const OP_MONSTER_SPAWNED := 0x007e      # server -> every session in the zone: a monster that has just appeared
const OP_MONSTER_MOTION_LIST := 0x007f  # server -> the requester, right after an OpMonsterListResult
## Round 656: the monsters that left this player's area of interest (the
## 5x5 regions around it): u16 n, then n s64 ids. The body goes as on a zone
## change, with no death.
const OP_MONSTER_LEFT := 0x00b5         # server -> one session

## Result of decode_monster_moved(): one monster's new leg. (x, z) is where the
## server had the monster when it issued the move; the body walks from there to
## (dest_x, dest_z) at `speed` world units per second. dest == (x, z) is a
## stop at (x, z). `mode` picks the clip, 0 walk and 1 run.
class MonsterMoved:
	var monster_id: int
	var x: float
	var z: float
	var dest_x: float
	var dest_z: float
	var speed: float
	var mode: int

## One entry of decode_monster_motion_list(): a listed monster's current leg,
## without a position -- the list result just before it carries that.
class MotionEntry:
	var monster_id: int
	var dest_x: float
	var dest_z: float
	var speed: float
	var mode: int

## Result of decode_monster_attacked(): one monster's blow on a player. The
## numbers are the counterattack's own, resolved in session/combat.go
## performAttack's counter branch (rounds 254, 505) -- the PlayerDamageTaken,
## MonsterCritical, PlayerBlocked, PlayerDied, PlayerHP and DeathExpLost the
## attacker's OpAttackResult carries, which a server with the push sends to
## the whole zone right behind that result.
class MonsterAttacked:
	var monster_id: int
	var target_character_id: int
	## 0 for a blocked blow: a block skips the whole damage pipeline
	## (combat.ResolveBlow returns Blow{Blocked: true}).
	var damage: int
	var critical: bool
	var blocked: bool
	var target_died: bool
	## Round 659's review: not a swing but a state's damage tick (poison,
	## burn, bleeding) -- the server's StrikeStatusTick, OURS. No monster
	## attack is drawn for it.
	var status_tick: bool
	## The target's HP after the blow -- after a death, the HP it was put
	## back on its feet with (character.RespawnFraction), as PlayerHP is.
	var target_hp: int
	## The death penalty's experience loss, 0 when the target did not die.
	var death_exp_lost: int
	## The blow's meeting with the target's protection wall (round 640), or
	## null when it met none -- see WallHit.
	var wall: WallHit = null

## A monster's blow on a protection wall (round 640, the server's
## session/walls.go WallInfo): a strict suffix on OpAttackResult (after the
## echoed targetType) and on OpMonsterAttacked (after its 33 bytes), present
## only when there is one. u8 flags, s32 the damage the wall took, s32 the
## wall's HP left, s32 its maximum. Retail's damage entry of kind 7
## (FUN_00a55e00, READ) carries the same numbers; this layout is OpenSRO's.
class WallHit:
	## The wall took the whole blow: the target's HP did not move.
	var absorbed: bool = false
	## This blow emptied the wall (retail's 0x80 on the entry kind).
	var broke: bool = false
	## The blow against the wall was a critical.
	var critical: bool = false
	## Not a blow at all: the reply to a recast that switched an 'onff'
	## toggle off (Tick_UseSkill's phase 0) -- no cast is drawn.
	var toggled_off: bool = false
	var damage: int = 0
	var hp: int = 0
	var max_hp: int = 0

const WALL_ABSORBED := 0x01
const WALL_BROKE := 0x02
const WALL_CRITICAL := 0x04
const WALL_TOGGLED_OFF := 0x08
const WALL_SUFFIX_SIZE := 13

## Decodes the wall suffix at offset, or null when the payload stops short.
static func decode_wall_suffix(data: PackedByteArray, offset: int) -> WallHit:
	if offset < 0 or offset + WALL_SUFFIX_SIZE > data.size():
		return null
	var w := WallHit.new()
	var f: int = data[offset]
	w.absorbed = (f & WALL_ABSORBED) != 0
	w.broke = (f & WALL_BROKE) != 0
	w.critical = (f & WALL_CRITICAL) != 0
	w.toggled_off = (f & WALL_TOGGLED_OFF) != 0
	w.damage = data.decode_s32(offset + 1)
	w.hp = data.decode_s32(offset + 5)
	w.max_hp = data.decode_s32(offset + 9)
	return w

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
	## What the request this answers was aimed at (round 617): 1
	## (SkillNet.TARGET_ENTITY) for a swing, an entity cast or a keep-up
	## repeat, 0 for a self-cast, 2 for a ground cast. The server echoes it as
	## a trailing u8 after monster_id (the contract's review follow-up);
	## target_type_echoed says it did. From a server that does not, NetClient
	## fills it from the request queue, which a keep-up repeat or a dropped
	## swing can put out of step -- so an unechoed value is only a hint
	## (SelfCast.is_self_reply).
	var target_type: int = 1
	var target_type_echoed: bool = false
	## What a kill earned (round 639): the experience and the skill
	## experience the server granted, two trailing s64s after target_type; 0
	## for a blow that killed nothing, a server with no level table, or a
	## server too old to send them. World3D writes them to the system window
	## as retail's Client_ApplyExpAndLevelUp (0x8a97c0) does.
	var exp_gained: int = 0
	var skill_exp_gained: int = 0
	## The counter's meeting with the player's protection wall, or the
	## toggle-off marker (round 640); null when neither.
	var wall: WallHit = null

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
	## The party-monster flag (round 660): retail's +0x7ad, the high nibble
	## of the class byte (CICMonster::vslot_025 0x9d3850). OpenSRO's server
	## sends it in bit 8 of the rarity word, and only to a client whose list
	## request carries MONSTER_LIST_FLAG_PARTY.
	var party: bool

## Result of decode_monster_list_result().
class MonsterListResult:
	var error: String
	var monsters: Array[MonsterSnapshot] = []
	## The paging trailer (round 656): a list too big for one frame comes as
	## `pages` frames, page 0 first. 0/0 on a list that carries no trailer,
	## which is the whole list. NetClient gathers the pages.
	var page: int = 0
	var pages: int = 0

## Result of decode_monster_spawned(): a monster that has just appeared (a
## respawn, a GM /spawn), in the monster list's own record, and the heading it
## faces.
class MonsterSpawned:
	var monster: MonsterSnapshot
	## Radians in OpenSRO's world frame, measured from +x toward +z: the
	## direction is (cos h, sin h) on the (x, z) ground plane, the unit
	## heading SetHeading writes (server/internal/ai/wander.go;
	## MonsterMotion.heading_dir).
	var heading: float

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
## OpenSRO's skillInReach either, and the client mirrors the server. The
## server decides: firstSwingInReach and skillInReach (session/keepup.go)
## refuse a blow out of reach with "too far away". What the engine does next
## is WALK: phase 1 tests
## Action_IsTargetWithinReach (0x004ad4a0: `int(dist) <= reach + 2`) on every
## tick and, while it fails, GObjPC::MoveTowardObject(target, round(stop))
## (0x004b0350) aims the walk at the stop distance. The retail engine walks the
## attacker on the SERVER; OpenSRO's server does not drive player movement,
## so World3D does the walk and only then sends (see World3D._attack_monster).
## docs/protocol/auto_command.md, "The attack tick".

## The BCRadius (characterdata col 50) of every playable body row -- all 52
## CHAR_* rows read 4 (re-counted round 523 over the box's six characterdata
## data files). combat.PlayerBCRadius, which the server uses for the attacker
## whatever body it has; the client reads the body row itself
## (World3D._attack_band) and falls back to this.
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
## Basic_Activity (+0x65, skilldata col 8) is not 2 never reach either test:
## `0x4ae6e6 cmp [edi+0x65],2 ; 0x4ae6ea jne 0x4ae9dc`, and 0x4ae9dc is
## `mov eax,1 ; ... ; ret 8` -- the tick returns 1 and STAYS in phase 0 (the
## decompile: `if (+0x65 != 2) return 1;`). What then casts such a row was not
## followed (docs/TODO.md, "Attack distance"). On the box's skilldata all 256
## such China board rows (174 with Activity 1, 82 with 0; re-counted round 523)
## carry Target_Required 0, so this function gives them no walk either way.
## OpenSRO's server accepts the non-damaging ones at any distance
## (session/skill.go skips skillInReach for a NoCombatParam/ZeroDamage row) --
## see docs/TODO.md, "Attack distance", for the damaging Target_Required 0 rows
## it still reach-gates.
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

## The refusal session/combat.go and session/skill.go send for a blow out of
## reach (firstSwingInReach / skillInReach). OpenSRO's own wording; the result
## carries no code, so the text is what marks it.
const REFUSED_TOO_FAR := "too far away"
## How many times an attack the server refused as too far away walks again
## before the client gives up. OpenSRO's own number: the engine's phase 1
## re-tests reach every tick and walks for as long as it fails
## (docs/protocol/auto_command.md, "The attack tick"), with no count.
const APPROACH_RETRY_CAP := 3

## Whether the approach walk releases the attack at `distance` from the target.
## The engine's rule is in_reach -- the truncated distance within the reach plus
## the +2 slack (0x004ad4a0) -- and that is the rule while the target stands.
## Released on the first frame that holds, the walk sends from the band's OUTER
## edge (about 0-0.7 units of margin at a closing speed of 42 u/s, a 50 u/s run
## against an 8 u/s walk, at 60 frames a second), and a target walking away
## gains v x the round trip before the server measures it
## (docs/TODO.md, "Attack distance"). So while the target is known to be moving,
## or after a refusal, the release waits for `stop` -- the distance the walk
## aims at (phase 0's band), never beyond the reach -- which leaves at least 3
## units (`int(d) <= reach + 2` holds for every d below reach + 3) plus the
## reach's excess over the stop. OpenSRO's own rule, for OpenSRO's
## client-side walk: the engine walks on the server and has no round trip to
## cover.
static func approach_releases(distance: float, stop: float, reach: float, tight: bool) -> bool:
	if tight:
		return distance <= stop
	return in_reach(distance, reach)

## How far short of the target the walk aims. The stop distance normally; in a
## tight approach (approach_releases) `arrive` shorter, so a walk that arrives --
## World3D stops a walk `arrive` from its point (MOVE_TARGET_STOP_DISTANCE) and
## releases the attack there -- has already come within the stop distance.
static func approach_aim(stop: float, tight: bool, arrive: float) -> float:
	if tight:
		return maxf(stop - arrive, 0.0)
	return stop

## Whether an attack released from the approach walk and refused walks again:
## it is a plain swing (skill_id 0), the refusal is the reach one, the target
## is still alive and not dying, and it has walked again fewer than
## APPROACH_RETRY_CAP times. Any other refusal (a cooldown, a dead target) ends
## it, as before.
##
## A SKILL is never sent again (round 534). The client plays a cast -- its
## animation, the battle stance, the hit effect it arms -- when the request
## goes out (World3D._send_attack), so a second request after the walk would
## play a second cast for one use of the skill. Until round 534 the server had
## also already charged the refused cast: session/skill.go spent the HP and MP
## and armed the cooldown before skillInReach refused it, so the second request
## spent MP again or was refused on cooldown. The server now tests the reach
## first, as the engine does (Tick_UseSkill 0x4ae590 tests reach at 0x4aea39,
## before its phase-2 post of 0x7070 at 0x4aebc6, and nothing is spent before
## that post -- docs/protocol/skill_use_gate.md, round 534), so a skill refused
## as too far away costs nothing and the player can cast it again.
static func should_rewalk(error: String, target_alive: bool, retries: int, skill_id: int) -> bool:
	return skill_id == 0 and error == REFUSED_TOO_FAR and target_alive and retries < APPROACH_RETRY_CAP

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
	# Round 617's review: the request's targetType, echoed.
	if offset + 43 <= data.size():
		result.target_type = data[offset + 42]
		result.target_type_echoed = true
	# Round 639: the kill's experience and skill experience.
	if offset + 59 <= data.size():
		result.exp_gained = data.decode_s64(offset + 43)
		result.skill_exp_gained = data.decode_s64(offset + 51)
	# Round 640: the wall suffix, after round 639's EXP tail, only when there
	# is one.
	result.wall = decode_wall_suffix(data, offset + 59)

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

## Bit 0 of the OpMonsterList request's one byte (round 656's review): this
## client gathers a paged list (NetClient). A server answers a request
## without it in the old form, one frame of the nearest monsters.
const MONSTER_LIST_FLAG_PAGED := 0x01
## Bit 1 (round 660): this client reads the party flag in the rarity word
## (MONSTER_RARITY_PARTY_BIT); a server sends it only then.
const MONSTER_LIST_FLAG_PARTY := 0x02
## Where the rarity word carries the party flag (round 660): bit 8, above
## every rank.
const MONSTER_RARITY_PARTY_BIT := 0x100

## Encodes an OpMonsterList request: the capability byte only -- the server
## resolves the requester's zone and window from world.Hub.
static func encode_monster_list() -> PackedByteArray:
	return PackedByteArray([MONSTER_LIST_FLAG_PAGED | MONSTER_LIST_FLAG_PARTY])

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
	var rarity_word := data.decode_u32(offset + 12)
	m.rarity = rarity_word & ~MONSTER_RARITY_PARTY_BIT
	m.party = (rarity_word & MONSTER_RARITY_PARTY_BIT) != 0
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

	# The paging trailer, u16 page and u16 pages, when the frame carries one.
	if offset + 4 <= data.size():
		result.page = data.decode_u16(offset)
		result.pages = data.decode_u16(offset + 2)
	return result

## Decodes an OpMonsterLeft payload (round 656) into the ids it names; an id
## cut short is dropped with everything after it.
static func decode_monster_left(data: PackedByteArray) -> Array[int]:
	var out: Array[int] = []
	if data.size() < 2:
		return out
	var count := data.decode_u16(0)
	for i in range(count):
		var at := 2 + 8 * i
		if at + 8 > data.size():
			break
		out.append(data.decode_s64(at))
	return out

## The size of an OpMonsterMoved payload: s64 id, five f32 (x, z, dest_x,
## dest_z, speed) and the u8 mode.
const MONSTER_MOVED_SIZE := 29
## The size of one OpMonsterMotionList entry: s64 id, three f32 (dest_x,
## dest_z, speed) and the u8 mode.
const MOTION_ENTRY_SIZE := 21

## Decodes an OpMonsterMoved payload, or null when it is shorter than 29 bytes.
static func decode_monster_moved(data: PackedByteArray) -> MonsterMoved:
	if data.size() < MONSTER_MOVED_SIZE:
		return null
	var m := MonsterMoved.new()
	m.monster_id = data.decode_s64(0)
	m.x = data.decode_float(8)
	m.z = data.decode_float(12)
	m.dest_x = data.decode_float(16)
	m.dest_z = data.decode_float(20)
	m.speed = data.decode_float(24)
	m.mode = data[28]
	return m

## The size of an OpMonsterAttacked payload: s64 monster id, s64 target
## character id, s32 damage, u8 flags, s32 target HP, s64 death exp lost.
const MONSTER_ATTACKED_SIZE := 33
## OpMonsterAttacked's flag bits.
const STRIKE_CRITICAL := 0x01
const STRIKE_BLOCKED := 0x02
const STRIKE_TARGET_DIED := 0x04
const STRIKE_STATUS_TICK := 0x08

## Decodes an OpMonsterAttacked payload, or null when it is shorter than 33
## bytes. Past the 33rd, only round 640's wall suffix is read.
static func decode_monster_attacked(data: PackedByteArray) -> MonsterAttacked:
	if data.size() < MONSTER_ATTACKED_SIZE:
		return null
	var m := MonsterAttacked.new()
	m.monster_id = data.decode_s64(0)
	m.target_character_id = data.decode_s64(8)
	m.damage = data.decode_s32(16)
	var flags: int = data[20]
	m.critical = (flags & STRIKE_CRITICAL) != 0
	m.blocked = (flags & STRIKE_BLOCKED) != 0
	m.target_died = (flags & STRIKE_TARGET_DIED) != 0
	m.status_tick = (flags & STRIKE_STATUS_TICK) != 0
	m.target_hp = data.decode_s32(21)
	m.death_exp_lost = data.decode_s64(25)
	# Round 640: the wall suffix, only when the blow met one.
	m.wall = decode_wall_suffix(data, MONSTER_ATTACKED_SIZE)
	return m

## Decodes an OpMonsterSpawned payload: one record in OpMonsterListResult's
## own encoding (_decode_monster_snapshot), then an f32 heading. null when
## either is cut short.
static func decode_monster_spawned(data: PackedByteArray) -> MonsterSpawned:
	var decoded := _decode_monster_snapshot(data, 0)
	if decoded[0] == null:
		return null
	var offset: int = decoded[1]
	if offset + 4 > data.size():
		return null
	var s := MonsterSpawned.new()
	s.monster = decoded[0]
	s.heading = data.decode_float(offset)
	return s

## Decodes an OpMonsterMotionList payload: u16 n, then n entries of 21 bytes.
## A truncated tail is dropped and every whole entry before it is kept.
static func decode_monster_motion_list(data: PackedByteArray) -> Array[MotionEntry]:
	var out: Array[MotionEntry] = []
	if data.size() < 2:
		return out
	var count := data.decode_u16(0)
	var offset := 2
	for i in range(count):
		if offset + MOTION_ENTRY_SIZE > data.size():
			break
		var e := MotionEntry.new()
		e.monster_id = data.decode_s64(offset)
		e.dest_x = data.decode_float(offset + 8)
		e.dest_z = data.decode_float(offset + 12)
		e.speed = data.decode_float(offset + 16)
		e.mode = data[offset + 20]
		out.append(e)
		offset += MOTION_ENTRY_SIZE
	return out
