package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"sync/atomic"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
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
// Behind cmd/server's -monster-strike-push (SRREVAMP_MONSTER_STRIKE_PUSH),
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
)

// MonsterAttacked is the OpMonsterAttacked payload: monster MonsterID struck
// character TargetCharacterID. Every field is the attacker's OpAttackResult's
// own number for that counter: Damage is PlayerDamageTaken (0 when blocked),
// TargetHP is PlayerHP (after a death, the HP the target was put back on its
// feet with) and DeathExpLost is DeathExpLost.
type MonsterAttacked struct {
	MonsterID         int64
	TargetCharacterID int64
	Damage            int32
	Critical          bool
	Blocked           bool
	TargetDied        bool
	TargetHP          int32
	DeathExpLost      int64
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
	out[20] = flags
	binary.LittleEndian.PutUint32(out[21:25], uint32(m.TargetHP))
	binary.LittleEndian.PutUint64(out[25:33], uint64(m.DeathExpLost))
	return out
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
		TargetHP:          int32(binary.LittleEndian.Uint32(data[21:25])),
		DeathExpLost:      int64(binary.LittleEndian.Uint64(data[25:33])),
	}, nil
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
// that gear resolves against, and the mana pool a death refills.
type strikeDeps struct {
	chars character.Store
	eq    equipment.Store
	items combat.ItemLookup
	mp    *mana.Tracker
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
}

// message is the outcome as the OpMonsterAttacked the zone is sent.
func (o monsterStrikeOutcome) message(monsterID, targetID int64) *MonsterAttacked {
	return &MonsterAttacked{
		MonsterID: monsterID, TargetCharacterID: targetID,
		Damage: int32(o.damage), Critical: o.critical, Blocked: o.blocked, TargetDied: o.died,
		TargetHP: int32(o.hp), DeathExpLost: o.deathExpLost,
	}
}

// monsterStrike is a surviving monster's counterattack on characterID, whose
// level is playerLevel: the monster's blow through the same pipeline a
// player's takes, the gear it wears, the damage, and -- on a death -- the
// experience penalty, the respawn, the end of the keep-up and the mana
// refill. performAttack calls it once CounterattackReady has said the monster
// may strike. It is performAttack's counter branch moved here unchanged in
// round 541 (rounds 254 and 505); only its result is returned instead of
// written into the AttackResult, so the push can repeat it.
func monsterStrike(ctx context.Context, deps strikeDeps, monster combat.Monster, characterID int64, playerLevel int) (monsterStrikeOutcome, error) {
	chars, eq, items, mp := deps.chars, deps.eq, deps.items, deps.mp
	var out monsterStrikeOutcome
	armor, err := defenderArmor(ctx, characterID, eq, items)
	if err != nil {
		return monsterStrikeOutcome{}, fmt.Errorf("combat: reading armor: %w", err)
	}
	// A monster attacks with its SKILL's damage range (characterdata col 83
	// -> that skill's 'att' param), rolled the same way a weapon is. The
	// flat disclosed Attack remains only for a monster with no range.
	raw := monster.Attack
	if monster.AttackMax > 0 {
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
		raw = monsterBlow(monster, playerLevel, parry)
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
	counter := resolveBlow(raw, playerMitigationPercent, armor,
		combat.EvadedChance(monster.Critical, playerEvasion),
		combat.EvadedChance(defenderBlock(ctx, characterID, eq, items), monsterEvasion),
		monster.Level, playerLevel, monster.ID, characterID)
	incoming := counter.Damage
	out.critical = counter.Critical
	out.blocked = counter.Blocked
	// The counterattack wears the defender's gear: a blocked hit the
	// shield, any other hit one armour piece.
	if counter.Blocked {
		wearShield(ctx, eq, characterID)
	} else if counter.Damage > 0 {
		wearArmour(ctx, eq, characterID)
	}
	hp, playerDied, err := chars.ApplyDamage(ctx, characterID, incoming)
	if err != nil {
		return monsterStrikeOutcome{}, fmt.Errorf("combat: applying counterattack: %w", err)
	}
	out.damage = incoming
	out.died = playerDied
	if playerDied {
		// Dying costs experience, above level 10. Real: GObjPC_OnDeath
		// multiplies the level's EXP unit -- the same field a kill is
		// paid from -- by 100 when a monster did the killing and the
		// victim carries no PK penalty points, which is the only branch
		// this project can reach until there is a PK system. See
		// leveldata.DeathPenaltyExp for the other three and for why the
		// reduction stat is left out.
		if levelTable != nil {
			if c, e := chars.GetByID(ctx, characterID); e == nil && c != nil {
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
						return monsterStrikeOutcome{}, fmt.Errorf("combat: applying death penalty: %w", err)
					}
					out.deathExpLost = loss
				}
			}
		}
		if err := chars.RespawnHP(ctx, characterID); err != nil {
			return monsterStrikeOutcome{}, fmt.Errorf("combat: respawning player: %w", err)
		}
		// Death ends the action queue with everything else: no repeat
		// fires for a character who has just been put back on their feet.
		keepUp.Cancel(characterID)
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
	} else {
		out.hp = hp
	}

	return out, nil
}

// pushMonsterStrike sends a monster's blow to every session in zone, the
// attacker included, when -monster-strike-push is on, and does nothing when
// it is off. performAttack calls it after the attacker's OpAttackResult and
// after the zone's OpMonsterDamaged for the same swing, from the goroutine
// that ran the swing, so the attacker's client always has the result before
// the push (round 540's MonsterStrikes pairs the two in that order). The
// sending pattern is the ground-item pushes' (dropKillLoot): one packet, every
// session in the zone, a failed write left to that session's own reader.
func pushMonsterStrike(hub *world.Hub, zone string, msg *MonsterAttacked) {
	if !monsterStrikePush.Load() {
		return
	}
	p := &proto.Packet{Opcode: OpMonsterAttacked, Data: msg.Encode()}
	for _, e := range hub.EntitiesInZone(zone) {
		if e.Session == nil {
			continue
		}
		_ = e.Session.Send(p)
	}
}
