package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The monster's blow as a zone push (round 541): the server half of round
// 540's client (docs/protocol/monster_ai.md, "The strike and spawn pushes";
// client/scripts/net/combat.gd decode_monster_attacked). A counterattack is
// resolved in performAttack's counter branch (rounds 254 and 505), now
// monsterStrike below, and until this round its outcome reached only the
// attacker, inside that attack's OpAttackResult. OpMonsterAttacked repeats the
// same outcome to everyone in the zone, the attacker included, so the other
// players can draw the blow. It adds no number of its own.
//
// Behind cmd/server's -monster-strike-push (OPENSRO_MONSTER_STRIKE_PUSH),
// which is OFF by default: off, nothing is sent and the wire is what it was.
// It is flipped only once a client release that draws the push is out; an
// older client ignores 0x007D with an "unhandled opcode" warning.
//
// An additive placeholder like every opcode here
// (docs/protocol/PROTOCOL_DECISION.md). 0x007D was free: before round 540 no
// non-test file under server/ or client/scripts/net used it, and before this
// round none under server/ did (grep, 2026-09-24).
const OpMonsterAttacked uint16 = 0x007d // server -> every session in the zone, the attacker too: one monster's blow

// MonsterAttackedSize is an OpMonsterAttacked payload's length: s64 monster,
// s64 target character, s32 damage, u8 flags, s32 target HP, s64 death exp
// lost (docs/protocol/monster_ai.md's table row; the client's
// CombatNet.MONSTER_ATTACKED_SIZE).
const MonsterAttackedSize = 33

// OpMonsterAttacked's flag bits, the client's CombatNet.STRIKE_* (round 540).
const (
	StrikeCritical   uint8 = 0x01 // the monster's critical (AttackResult.MonsterCritical)
	StrikeBlocked    uint8 = 0x02 // the target's shield blocked it (AttackResult.PlayerBlocked)
	StrikeTargetDied uint8 = 0x04 // the blow killed the target (AttackResult.PlayerDied)
	// StrikeStatusTick (round 659's review, OURS): not a swing but a state's
	// damage tick (status.go) -- the client draws no monster attack for it.
	// Retail's message for a death by a tick is not read (OPEN).
	StrikeStatusTick uint8 = 0x08
)

// MonsterAttacked is the OpMonsterAttacked payload: monster MonsterID struck
// character TargetCharacterID. Every field is the attacker's OpAttackResult's
// own number for that counter: Damage is PlayerDamageTaken (0 when blocked),
// TargetHP is PlayerHP (after a death, the HP the target was put back on its
// feet with -- or 0 under -player-dead-state, round 549) and DeathExpLost is
// DeathExpLost.
type MonsterAttacked struct {
	MonsterID         int64
	TargetCharacterID int64
	Damage            int32
	Critical          bool
	Blocked           bool
	TargetDied        bool
	// StatusTick marks a state's damage tick rather than a blow
	// (StrikeStatusTick).
	StatusTick   bool
	TargetHP     int32
	DeathExpLost int64
	// Wall is the blow's meeting with the target's protection wall (round
	// 640, walls.go): a strict suffix after the 33 bytes, present only when
	// the blow met a wall -- or when SkillID follows it.
	Wall WallInfo
	// SkillID is the attack skill the monster swung (round 785): retail's
	// 0xB070 names it (u32 skillId, the AI-picked row's CRefSkill+4 that
	// 0x5411a0 posts as a 0x7070 to the monster's own command source; READ),
	// and the client keys the swing's clip (skilleffect.txt skillaniset2),
	// its swing and shout sounds and the blow's hit sound by it. A u32 after
	// the wall block, which is then always written (13 zero bytes when the
	// blow met no wall); 0 writes neither, so a blow without one is byte for
	// byte what it was.
	SkillID int64
}

func (m *MonsterAttacked) Encode() []byte {
	out := make([]byte, MonsterAttackedSize)
	binary.LittleEndian.PutUint64(out[0:8], uint64(m.MonsterID))
	binary.LittleEndian.PutUint64(out[8:16], uint64(m.TargetCharacterID))
	binary.LittleEndian.PutUint32(out[16:20], uint32(m.Damage))
	var flags uint8
	if m.Critical {
		flags |= StrikeCritical
	}
	if m.Blocked {
		flags |= StrikeBlocked
	}
	if m.TargetDied {
		flags |= StrikeTargetDied
	}
	if m.StatusTick {
		flags |= StrikeStatusTick
	}
	out[20] = flags
	binary.LittleEndian.PutUint32(out[21:25], uint32(m.TargetHP))
	binary.LittleEndian.PutUint64(out[25:33], uint64(m.DeathExpLost))
	if m.Wall == (WallInfo{}) && m.SkillID == 0 {
		// No wall: the 33 bytes as they were (round 640's suffix is only
		// there when the blow met one).
		return out
	}
	out = append(out, m.Wall.encode()...)
	if m.SkillID == 0 {
		return out
	}
	return binary.LittleEndian.AppendUint32(out, uint32(m.SkillID))
}

// MonsterAttackedSkillOffset is where OpMonsterAttacked's skill id sits:
// after the 33 bytes and the 13-byte wall block (round 785).
const MonsterAttackedSkillOffset = MonsterAttackedSize + wallInfoSize

// skillFrom decodes the round-785 skill id, 0 when a payload predates it.
func skillFrom(data []byte) int64 {
	if len(data) < MonsterAttackedSkillOffset+4 {
		return 0
	}
	return int64(binary.LittleEndian.Uint32(data[MonsterAttackedSkillOffset:]))
}

// strikeSkillID is the skill a monster's blow names (round 785): the swing's
// drawn skill, or -- for the counter and a swing with none drawn, which roll
// the primary range (monsterStrike) -- the species' primary attack skill,
// characterdata col 83, first in Monster.Skills. 0 when it has no list.
func strikeSkillID(m combat.Monster, skill combat.MonsterSkill) int64 {
	if skill.ID != 0 {
		return skill.ID
	}
	if len(m.Skills) > 0 {
		return m.Skills[0].ID
	}
	return 0
}

// DecodeMonsterAttacked refuses a payload shorter than 33 bytes and ignores
// bytes past the 33rd, as the client does (CombatNet.decode_monster_attacked).
// Only tests call it -- the message goes server to client.
func DecodeMonsterAttacked(data []byte) (*MonsterAttacked, error) {
	if len(data) < MonsterAttackedSize {
		return nil, fmt.Errorf("session: decoding MonsterAttacked: %d bytes, want %d", len(data), MonsterAttackedSize)
	}
	flags := data[20]
	return &MonsterAttacked{
		MonsterID:         int64(binary.LittleEndian.Uint64(data[0:8])),
		TargetCharacterID: int64(binary.LittleEndian.Uint64(data[8:16])),
		Damage:            int32(binary.LittleEndian.Uint32(data[16:20])),
		Critical:          flags&StrikeCritical != 0,
		Blocked:           flags&StrikeBlocked != 0,
		TargetDied:        flags&StrikeTargetDied != 0,
		StatusTick:        flags&StrikeStatusTick != 0,
		TargetHP:          int32(binary.LittleEndian.Uint32(data[21:25])),
		DeathExpLost:      int64(binary.LittleEndian.Uint64(data[25:33])),
		Wall:              wallFrom(data[33:]),
		SkillID:           skillFrom(data),
	}, nil
}

// wallFrom decodes the wall suffix, zero when a payload predates it.
func wallFrom(b []byte) WallInfo {
	w, _ := decodeWallInfo(b)
	return w
}

// monsterStrikePush is cmd/server's -monster-strike-push, OFF by default. An
// atomic rather than a plain variable because cmd/server sets it on the boot
// goroutine and performAttack reads it on session readers and keep-up
// goroutines.
var monsterStrikePush atomic.Bool

// SetMonsterStrikePush turns the strike push on or off. cmd/server calls it
// once at boot, before the gateway serves, with -monster-strike-push.
func SetMonsterStrikePush(on bool) { monsterStrikePush.Store(on) }

// strikeDeps is what a monster's counterattack reads and writes: the
// defender's character row, the gear it wears and wears down, the item table
// that gear resolves against, the mana pool a death refills, and -- for the
// dead state (round 549) -- the world hub that keeps the life state and the
// potion queue a death empties. hub nil means no dead state can be kept, so a
// kill respawns as with the flag off; cmd/server passes both.
type strikeDeps struct {
	chars   character.Store
	eq      equipment.Store
	items   combat.ItemLookup
	mp      *mana.Tracker
	hub     *world.Hub
	potions *PotionQueue
}

// monsterStrikeOutcome is what one counterattack did to its target: the
// numbers performAttack copies into the attacker's OpAttackResult
// (PlayerDamageTaken, MonsterCritical, PlayerBlocked, PlayerDied, PlayerHP,
// DeathExpLost) and the push repeats.
type monsterStrikeOutcome struct {
	damage       int
	critical     bool
	blocked      bool
	died         bool
	hp           int
	deathExpLost int64
	// dropped is a blow whose damage left its target at 0 HP but which lost
	// the kill to another (round 550; the arbiter is killLock since round
	// 551): the target was already in the dead state, or already back on her
	// feet, when this blow read her back under the lock. The blow is
	// UNREPORTED -- its damage is in the pool the winner read (or under the
	// winner's RespawnHP), but performAttack's result carries no counter,
	// runStrike pushes nothing, and no penalty is charged for it -- the
	// engine's GObjPC::FUN_004a87d0 landing nothing on a character whose life
	// state is not 1 (`cmp al,0x1` at 0x4a87e8) being the nearest thing to it
	// (round 555 corrected "nothing landed"). The other fields are zero.
	dropped bool
	// wall is the blow's meeting with the target's protection wall (round
	// 640): when Absorbed, the wall took it and the target nothing.
	wall WallInfo
}

// killLocks holds one mutex per character a blow has ever left at 0 HP: the
// kill arbiter (round 551). A blow whose damage leaves the pool at 0 takes the
// character's lock and, under it, reads her back (fallen): alive and still at
// 0, it is THE kill and completes the death -- the penalty, then markDead or
// RespawnHP (monsterStrike), the duel's ResetHP (handleDuelAttack) -- before
// it releases; dead already, or above 0 again, it lost to another kill and is
// dropped. revivePlayer holds the same lock across its compare-and-swap 2 -> 1
// and its pool writes, so no blow can read "alive at 0" between a revive's
// state and its pools. Two kills racing each other therefore charge ONE death
// penalty under either flag: with -player-dead-state on the loser finds life
// state 2, off it finds the winner's RespawnHP already written.
//
// Round 550 arbitrated on character.Store.ApplyDamage's transition flag
// instead (died only for the blow that took the pool from above 0 to 0), and
// that left a living character at 0 HP unkillable: an HP-cost cast lands its
// caster at exactly 0 -- the engine's own gate passes on equal, `cmp
// eax,[esp+0x10]; jge` at 0x58e28c/0x58e290 in SR_GameServer.exe
// (combat.CanPaySkillHealth) -- and every later blow then read (0, false) and
// was dropped, for ever (the batch-18 review's blocking note). The lock tells
// the two apart by reading the character, not the write.
//
// OWN DESIGN: the engine has no such lock -- its blows and revives run on one
// game-object queue. Entries are never removed: one mutex per character ever
// taken to 0 or regenerated (round 607: the regen tick takes it too) in the
// process's life, a few dozen bytes each.
var killLocks sync.Map

// killLock is characterID's kill lock (killLocks).
func killLock(characterID int64) *sync.Mutex {
	l, _ := killLocks.LoadOrStore(characterID, new(sync.Mutex))
	return l.(*sync.Mutex)
}

// fallen decides, under characterID's kill lock (the caller holds it), whether
// a blow that left her pool at 0 is THE kill: her row when she is not in the
// dead state and her HP is still 0 -- the caller completes the death from that
// row; nil when another kill has already put her in life state 2 or back on
// her feet, or a heal landed between the blow's write and the lock. In the
// heal's case the damage DID land -- the pool went to 0 -- and the heal
// covered it: the blow is then unreported (no push, no counter, no penalty),
// and with -player-dead-state on a potion step in that microsecond window
// keeps her alive at the healed HP with no death. Not an exploit -- she stays
// killable by the next blow -- and disclosed (round 551; wording corrected in
// round 555 from "that blow landed nothing").
func fallen(ctx context.Context, chars character.Store, hub *world.Hub, characterID int64) (*character.Character, error) {
	if deadCharacter(hub, characterID) {
		return nil, nil
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return nil, err
	}
	if c.HP > 0 {
		return nil, nil
	}
	return c, nil
}

// message is the outcome as the OpMonsterAttacked the zone is sent.
func (o monsterStrikeOutcome) message(monsterID, targetID int64) *MonsterAttacked {
	return &MonsterAttacked{
		MonsterID: monsterID, TargetCharacterID: targetID,
		Damage: int32(o.damage), Critical: o.critical, Blocked: o.blocked, TargetDied: o.died,
		TargetHP: int32(o.hp), DeathExpLost: o.deathExpLost, Wall: o.wall,
	}
}

// monsterStrike is a surviving monster's counterattack on characterID, whose
// level is playerLevel: the monster's blow through the same pipeline a
// player's takes, the gear it wears, the damage, and -- on a death -- the
// experience penalty, the end of the keep-up and then either the respawn and
// the mana refill (the default) or, under -player-dead-state, the dead state
// (markDead). performAttack calls it once CounterattackReady has said the
// monster may strike. It is performAttack's counter branch moved here
// unchanged in round 541 (rounds 254 and 505); only its result is returned
// instead of written into the AttackResult, so the push can repeat it.
//
// skill is the attack skill the swing fires (round 554): BATTLE's armed pick,
// whose 'att' block the blow rolls in place of the monster's primary range.
// The zero value -- performAttack's counter, and a monster with no skill list
// -- is the primary range, monster.AttackMin/AttackMax, as before.
func monsterStrike(ctx context.Context, deps strikeDeps, monster combat.Monster, skill combat.MonsterSkill, characterID int64, playerLevel int) (monsterStrikeOutcome, error) {
	chars, eq, items := deps.chars, deps.eq, deps.items
	// Round 800: a blow taken is the battle state (jobsuit.go).
	markBattle(deps.hub, characterID, time.Now())
	var out monsterStrikeOutcome
	armor, err := defenderArmor(ctx, characterID, eq, items)
	if err != nil {
		return monsterStrikeOutcome{}, fmt.Errorf("combat: reading armor: %w", err)
	}
	// A monster attacks with its SKILL's damage range (characterdata col 83
	// -> that skill's 'att' param), rolled the same way a weapon is. The
	// flat disclosed Attack remains only for a monster with no range.
	raw := monster.Attack
	// A swing of a drawn skill rolls THAT skill's 'att' block (round 554). A
	// block whose max is 0 -- MSKILL_CH_WATERGHOST_ATTACK02 169, att
	// 9,0,0,0,100 (its effect is a `ps` param OpenSRO has no status system
	// for) -- deals nothing, explicitly: monsterBlow's AttackMax <= 0 branch
	// is the flat disclosed Attack for a monster with no range at all, which
	// a zero-damage skill is not, and the pipeline below is skipped rather
	// than run on a 0 (its floor band and level term each raise a 0 to 1).
	// combat.Monster's own range stands in for the swing's when no skill is
	// named.
	swung := monster
	if skill.ID != 0 {
		swung.AttackMin, swung.AttackMax = skill.AttMin, skill.AttMax
		if skill.AttMax <= 0 {
			hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
			if err != nil {
				return monsterStrikeOutcome{}, fmt.Errorf("combat: applying counterattack: %w", err)
			}
			out.hp = hp
			// A zero-damage skill's states still land (round 659): this is
			// MSKILL_CH_WATERGHOST_ATTACK02's poison.
			if hp > 0 {
				statusFX.applyToCharacter(ctx, deps, monster, skill, characterID)
			}
			return out, nil
		}
	}
	if swung.AttackMax > 0 {
		// WHERE in that range the blow lands is the same centre-biased
		// roll the player's attack takes, with the sides swapped: the
		// monster's attack rate (2*level + 25) against the player's parry.
		//
		// Guarded the same way, and for the same reason: a player with no
		// armour parry at all means an item table imported before itemdata
		// col 68 existed, and treating that as a real zero would put every
		// monster blow at the 90 % ceiling on exactly the deployments that
		// have imported least.
		parry, perr := defenderParryRate(ctx, characterID, eq, items)
		if perr != nil {
			parry = 0
		}
		raw = monsterBlow(swung, playerLevel, parry)
	}
	// The player's side of the SAME mitigation the monster gets, through
	// the same function -- percentage term first, then the flat absorb.
	// The player's percentage is ZERO, and that is recovered rather than
	// a simplification: a player's ParamKeeper param 7 has exactly three
	// writers, and none of them can make it non-zero here.
	//
	//   GObjMob_PublishStats     mobs only (characterdata col 73)
	//   Char_PublishCombatStats  from a field no item column populates --
	//                            a census of all 21,560 item rows finds
	//                            no percentage-reduction column at all
	//   the skill-effect applier only through the skill param code 'ar',
	//                            which appears on ZERO of 29,342 skill
	//                            rows (the one numeric hit is a skill id)
	//
	// So the asymmetry this code already had -- monsters carry a
	// percentage, players do not -- is the game's own. Written as an
	// explicit 0 through combat.MitigateDamage rather than as a bare
	// subtraction, so the zero carries its citation instead of being a
	// coincidence that happens to compute the same number.
	// A blocked blow deals NOTHING, and the whole damage pipeline is
	// skipped rather than reduced to zero -- which is exactly what the
	// real resolve function does: a successful block jumps past every
	// Formula_Mitigate* call and leaves the damage record at its
	// zero-initialised value. So the roll comes first, and mitigation,
	// the critical and the level term are the things it skips.
	// The counterattack is the same pipeline with the roles swapped: the
	// monster is the attacker, so its Critical applies and the player's
	// shield is what blocks. combat.ResolveBlow does not care which side
	// is a player, which is the point of it being one function.
	// THE PROTECTION WALL (round 640, walls.go). Combat_ResolveDamage
	// (0x58e5f0, READ) looks at the target's wall (pc+0xc0c) before anything
	// else touches the target's own entry. While the wall has HP it resolves
	// the blow against the wall -- FUN_0040ebe0 / FUN_0040eef0, the mitigation
	// formulas with the defender's params 5 and 7 replaced by 'pw' value[2]
	// (flat) and value[3] (percent), the critical flag shared with the
	// target's entry -- and accumulates that damage on the wall BEFORE the
	// absorb test (buff.Books.HitWall). When the blow's type is one the wall
	// covers (buff.WallAbsorbs) the target's entry is marked 8 and skips the
	// rest: no block roll, no mitigation, no armour or shield wear, no HP.
	// Otherwise the blow lands as below. The wall is looked for first
	// (round 640's review): monsterBlowType reads the skill table, which a
	// blow on an unwalled player never needs.
	var wallCrit bool
	if buffBooks.HoldsWall(characterID) {
		hit, ok := buffBooks.HitWall(characterID, monsterBlowType(ctx, monster, skill), func(w buff.Wall) int {
			b := resolveBlow(raw, w.DefPct, w.Def,
				combat.EvadedChance(monster.Critical, playerEvadeCrit(ctx, characterID, eq)), 0,
				monster.Level, playerLevel, monster.ID, characterID)
			wallCrit = b.Critical
			return b.Damage
		})
		if ok {
			out.wall = WallInfo{Absorbed: hit.Absorbed, Broke: hit.Broke, Critical: wallCrit,
				Damage: int32(hit.Damage), HP: int32(hit.HP), Max: int32(hit.Max)}
		}
		if ok && hit.Absorbed {
			hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
			if err != nil {
				return monsterStrikeOutcome{}, fmt.Errorf("combat: reading the walled target: %w", err)
			}
			out.hp = hp
			out.critical = wallCrit
			slog.Info("wall: took a blow", "character", characterID, "monster", monster.ID, "damage", hit.Damage,
				"wall", hit.HP, "max", hit.Max, "critical", wallCrit, "caster hp", hp)
			// A broken wall is ended by the caller once this blow's
			// messages are out (endBrokenWall), as retail's book update
			// ends it after the action's packet.
			return out, nil
		}
	}
	counter := resolveBlow(raw, playerMitigationPercent, armor,
		combat.EvadedChance(monster.Critical, playerEvadeCrit(ctx, characterID, eq)),
		combat.EvadedChance(defenderBlock(ctx, characterID, eq, items), monsterEvasion),
		monster.Level, playerLevel, monster.ID, characterID)
	incoming := counter.Damage
	// The defender's damage-taken multiplier (round 838, applyPlayerTaken):
	// a monster's blow is physical here, p174 (defenderBlock's p136 too).
	if !counter.Blocked {
		incoming = applyPlayerTaken(characterID, false, incoming)
	}
	out.critical = counter.Critical
	out.blocked = counter.Blocked
	// A rider's blow lands on its mount (round 795: a single-target blow at
	// a riding PC is retargeted to the ridden COS, s:0x59b480, READ): the
	// rider keeps its HP and wears nothing; the mount loses the damage and,
	// at 0, dies and throws its rider (cosTakeDamage).
	if mount := riderMount(characterID); mount != nil && incoming > 0 && !counter.Blocked {
		cosTakeDamage(mount, incoming)
		hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
		if err != nil {
			return monsterStrikeOutcome{}, fmt.Errorf("combat: reading the rider: %w", err)
		}
		out.hp, out.damage = hp, incoming
		return out, nil
	}
	// The counterattack wears the defender's gear: a blocked hit the
	// shield, any other hit one armour piece.
	broke := false
	if counter.Blocked {
		broke = wearShield(ctx, eq, characterID)
	} else if counter.Damage > 0 {
		broke = wearArmour(ctx, eq, characterID)
	}
	if broke {
		clampHP(ctx, deps.chars, characterID) // round 769's review F2
	}
	// The store's died flag (the transition from above 0 to 0) is not the
	// arbiter here -- round 551, killLock's comment: it cannot tell a
	// character alive at 0 (an HP-cost cast's caster) from one another blow
	// is killing this instant.
	hp, _, err := chars.ApplyDamage(ctx, characterID, incoming)
	if err != nil {
		return monsterStrikeOutcome{}, fmt.Errorf("combat: applying counterattack: %w", err)
	}
	out.damage = incoming
	// A blow that lands stands a sitter up (Combat_ApplyActionEffects'
	// FUN_004b1480(0) at 0x593aec; round 607, motion.go).
	standOnHit(deps.hub, characterID, incoming)
	if hp > 0 || incoming == 0 {
		// Health left; or a blow that landed nothing -- blocked, or a zero
		// roll -- which kills nobody whatever pool it found and is reported
		// as it is, at the HP it found.
		out.hp = hp
		// The skill's states land on a living target (round 659, status.go);
		// a blocked blow applies none.
		if hp > 0 && !counter.Blocked {
			statusFX.applyToCharacter(ctx, deps, monster, skill, characterID)
		}
		return out, nil
	}
	// The blow's damage left the pool at 0. Whether it is THE kill is decided
	// under her kill lock (killLock, round 551): alive and still at 0 when
	// read back, it is; already in the dead state, or already respawned or
	// revived above 0, another kill got there first and this blow landed
	// nothing -- dropped, nothing reported (the roll and the wear above
	// stand, as before). So a character a cast has left alive at exactly 0
	// dies to the next blow, and two kills racing each other charge ONE death
	// penalty, flag on or off. The lock is held through the death below, so
	// the second of two racing kills reads the first's life state 2 or its
	// RespawnHP, never the pool between the two.
	// Round 802: an NPC thief's or hunter's kill of a player in a job is a
	// job death (ResolveDeathCause s:0x4e6590, cause 1).
	if kind := jobMobKind(monster.CodeName); kind != 0 && jobs.JobDeathByMonster(jobStateNow(ctx, characterID), kind) {
		setDeathCause(characterID, deathCause{job: true, killerLevel: monster.Level})
	}
	return finishKill(ctx, deps, characterID, out)
}

// finishKill decides and completes a death: a blow or a state's damage tick
// (status.go) has left characterID's pool at 0, and out is what it did so
// far. monsterStrike's tail moved here unchanged in round 659 so the
// damage-over-time kill takes the same lock, penalty and death.
func finishKill(ctx context.Context, deps strikeDeps, characterID int64, out monsterStrikeOutcome) (monsterStrikeOutcome, error) {
	chars, mp := deps.chars, deps.mp
	l := killLock(characterID)
	l.Lock()
	defer l.Unlock()
	c, err := fallen(ctx, chars, deps.hub, characterID)
	if err != nil {
		return monsterStrikeOutcome{}, fmt.Errorf("combat: reading the fallen character: %w", err)
	}
	if c == nil {
		return monsterStrikeOutcome{dropped: true}, nil
	}
	out.died = true
	// Where she fell is her death point (round 778, scroll.go): the death
	// path's GObjPC::FUN_004e0330 (from CGObjPC vslot_306, 0x529b10), which
	// the reverse return scroll's option 3 sends her back to. Before the
	// flag-off respawn moves her.
	recordDeathPoint(ctx, chars, deps.hub, characterID)
	// A death ends a scroll's cast (round 779, scroll.go): CGObjPC
	// vslot_306 / vslot_307 run the 0x705B handler when the state is set.
	cancelScrollForDeath(deps.hub, characterID)
	// The COS she rides is done with (round 795: CGObjPC vslot_306/307 ->
	// PC_ReleaseCOS(ridden, 1), READ): dismounted and deleted.
	cosOwnerDied(characterID)
	// Her states end with her (round 659, status.go).
	statusFX.endCharacter(deps.hub, characterID)
	// Dying costs experience, above level 10. Real: GObjPC_OnDeath
	// multiplies the level's EXP unit -- the same field a kill is
	// paid from -- by 100 when a monster did the killing and the
	// victim carries no PK penalty points, which is the only branch
	// this project can reach until there is a PK system. See
	// leveldata.DeathPenaltyExp for the other three and for why the
	// reduction stat is left out.
	cause, hasCause := takeDeathCause(characterID)
	if levelTable != nil && hasCause && cause.job {
		// A job death (round 802, jobpvp.go): the cause-1 handler's penalty
		// instead of GObjPC_OnDeath's.
		unlock := character.LockLeveling(characterID)
		if fresh, err := chars.GetByID(ctx, characterID); err == nil {
			c = fresh
		}
		out.deathExpLost = jobDeathPenalty(ctx, chars, c, cause.killerLevel)
		unlock()
	} else if levelTable != nil {
		// The EXP is re-read under the leveling lock (round 712: a party
		// member's kill can pay this character from another goroutine
		// between fallen's read and this write).
		unlock := character.LockLeveling(characterID)
		if fresh, err := chars.GetByID(ctx, characterID); err == nil {
			c = fresh
		}
		loss, ok := levelTable.DeathPenaltyExp(c.Level, leveldata.DeathPenaltyKilledByMonster)
		if ok && loss > 0 {
			exp := c.Exp - loss
			if exp < 0 {
				// The real formula clamps the LOSS so it cannot
				// exceed what is there; clamping the result to
				// zero is the same thing from this side. A death
				// never costs a level -- nothing in
				// GObjPC_OnDeath touches CurLevel.
				exp = 0
			}
			// A death penalty takes experience only: level, stat
			// points, Str and Int are carried through unchanged.
			if err := chars.SetLeveling(ctx, characterID, c.Level, exp, c.StatPoints, c.Str, c.Int); err != nil {
				unlock()
				return monsterStrikeOutcome{}, fmt.Errorf("combat: applying death penalty: %w", err)
			}
			out.deathExpLost = loss
		}
		unlock()
	}
	if playerDeadState.Load() && deps.hub != nil {
		// -player-dead-state (round 549, deadstate.go): the character
		// STAYS dead -- life state 2, HP where ApplyDamage left it (0),
		// the potion lists emptied and the keep-up ended, as
		// GObjPC::FUN_004e67b0 and the engine's death path do -- until
		// it asks for one of the resurrect choices (OpRevive; round 665 removed
		// the auto-revive fallback). The result and the push
		// therefore carry HP 0, which is how round 548's client knows
		// (MonsterStrikes.leaves_dead). The compare-and-swap inside
		// cannot lose to another kill or a revive: both take the kill
		// lock this blow holds (round 551); its result is therefore not
		// read here.
		markDead(deps, characterID, time.Now())
		out.hp = 0
		return out, nil
	}
	if err := chars.RespawnHP(ctx, characterID); err != nil {
		return monsterStrikeOutcome{}, fmt.Errorf("combat: respawning player: %w", err)
	}
	// Death ends the action queue with everything else: no repeat
	// fires for a character who has just been put back on their feet.
	cancelActions(characterID)
	// A death ends every buff on this path too (the rounds 636-640
	// integration review), as markDead's does on the dead-state path (round
	// 616's rule, OURS) -- the protection wall and its root with it: before,
	// a player killed through Crystal Wall by magical blows respawned still
	// walled, rooted, in state 0x11 and drained. Under the kill lock, the
	// same order markDead takes (kill lock, then buff lock).
	endBuffsOf(deps.hub, characterID)
	// Back at character.RespawnFraction of the maximum, not all of
	// it: the game restores a character whose stored pool is zero --
	// which is what death leaves -- to 40%, for HP and MP alike. See
	// character.RespawnFraction for the recovery. A level-up still
	// heals to full, which is why that path calls ResetHP instead.
	//
	// Falls back to the starting maximum only if the re-read fails,
	// which would mean the character vanished mid-respawn.
	out.hp = character.StartingMaxHP
	if reborn, e := chars.GetByID(ctx, characterID); e == nil {
		out.hp = reborn.HP
		if mp != nil {
			mp.Refill(characterID, character.RespawnMP(reborn.MaxMP()))
		}
	}
	return out, nil
}

// pushMonsterStrike sends a monster's blow to the attacker's session sess and
// to others -- the entities performAttack has just sent the swing's
// OpMonsterDamaged, everyone else in the monster's zone at that moment -- when
// -monster-strike-push is on, and does nothing when it is off. So the push's
// recipients are exactly the OpMonsterDamaged recipients plus the attacker,
// off the one zone snapshot performAttack took for the swing (round 544;
// round 541 took a second snapshot here, so a session entering or leaving
// the zone between the two could get one of the two messages without the
// other). performAttack calls it after the attacker's OpAttackResult and
// after the zone's OpMonsterDamaged for the same swing, from the goroutine
// that ran the swing, so the attacker's client always has the result before
// the push (round 540's MonsterStrikes pairs the two in that order); the
// attacker is sent first. The sending pattern is the ground-item pushes'
// (dropKillLoot): one packet, a failed write left to that session's own
// reader. The `e.Session == sess` test below is a guard for a caller other
// than performAttack, whose others already excludes the attacker's session by
// id; only the direct-call test reaches it (round 547's review note).
func pushMonsterStrike(sess *gateway.Session, others []world.Entity, msg *MonsterAttacked) {
	if !monsterStrikePush.Load() {
		return
	}
	p := &proto.Packet{Opcode: OpMonsterAttacked, Data: msg.Encode()}
	if sess != nil {
		_ = sess.Send(p)
	}
	for _, e := range others {
		if e.Session == nil || e.Session == sess {
			continue
		}
		_ = e.Session.Send(p)
	}
}
