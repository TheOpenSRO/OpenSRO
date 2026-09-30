package session

import (
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/ai"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/nest"
)

// A unique's summons and AI-skill triggers (round 661). The rules are READ
// from SR_GameServer.exe (docs/protocol/monster_ai.md, "The unique rotation
// and the minions"); the rows they run on -- which selector a unique gets,
// its summon skills' tuples, its _RefAISkill triggers -- are carried on the
// monster (combat.Monster.Summon / Triggers), built by cmd/server from the
// shard DB (EXTERNAL).
//
// The pick, in the engine's order (Summon_A/B::PickSkill before the Basic
// PickSkill 0x561b00):
//
//  1. the summon: once the damage the unique has taken since its last summon
//     reaches 10 % of its MaxHP (ai.SummonDue), the summon skill its selector
//     names for the HP bucket (ai.SummonAIndex / SummonBIndex) is armed;
//  2. the triggers (CheckTriggers 0x561a50): the first enabled row whose
//     condition holds -- an HP threshold fires once a life, a period on its
//     timer;
//  3. the weighted draw over the attack list (armSkill's ai.PickSkill).
//
// A summon skill fires like a swing on the action machine's cooldown, but
// with no reach to close: it has no target (INFERRED: the executor spawns
// around the caster, `vslot 0x14` of the unique, and takes no target). Firing
// runs the minion executor (0x596e50, spawnMinions) and zeroes the damage
// total (slot 6, FUN_00562540).

// creditDamage is AITactics_CreditAttacker's `ctx+0xb0 += damage` (0x5473c0)
// for a monster with a summon selector, read off its HP: each drop since the
// last look is damage taken; a rise (a heal) is not. The first look counts
// from the MaxHP the monster hatched with, so blows landed before its first
// BATTLE tick -- the one that engaged it among them -- are in the total, as
// the engine's credit is on every blow. INFERRED equivalence: the engine adds
// each blow's damage as the blow lands; a blow's overkill past 0 HP is not
// seen here, and a dead monster summons nothing anyway.
func (a *monsterAI) creditDamage(b *brain) {
	if b.m.Summon == nil {
		return
	}
	if !b.hpSeen {
		b.hpSeen, b.lastHP = true, b.m.MaxHP
	}
	if b.m.HP < b.lastHP {
		b.damageTaken += int64(b.lastHP - b.m.HP)
	}
	b.lastHP = b.m.HP
}

// armUniqueSkill is steps 1 and 2 of the pick for a monster with a summon
// selector or triggers: it arms the summon or the trigger skill and answers
// true, or answers false for the draw.
func (a *monsterAI) armUniqueSkill(b *brain) (combat.MonsterSkill, bool) {
	if s := b.m.Summon; s != nil && ai.SummonDue(b.damageTaken, b.m.MaxHP) {
		idx := -1
		switch s.Kind {
		case combat.SummonKindA:
			idx = ai.SummonAIndex(ai.HPBucket(b.m.HP, b.m.MaxHP))
		case combat.SummonKindB:
			r := nest.RandDice(a.rng)() // thrown before the bucket is read (0x56261f)
			idx = ai.SummonBIndex(ai.HPBucket(b.m.HP, b.m.MaxHP), r)
		}
		// Summon_A's empty slot falls to the Basic pick (0x5622d6); an index
		// past Summon_B's list is the engine's bounds assert (FUN_00562f20),
		// which here arms nothing and falls through as well (disclosed).
		if idx >= 0 && idx < len(s.Skills) && s.Skills[idx].Skill.ID != 0 {
			ss := &s.Skills[idx]
			b.armedSummon = ss
			b.armed, b.hasArmed = ss.Skill, true
			return ss.Skill, true
		}
	}
	for i := range b.m.Triggers {
		t := &b.m.Triggers[i]
		if b.trigFired == nil {
			b.trigFired = make([]bool, len(b.m.Triggers))
			b.trigLast = make([]time.Time, len(b.m.Triggers))
		}
		fire := false
		switch t.Type {
		case 0: // HPBelow (0x5611d0): once a life
			if !b.trigFired[i] && ai.TriggerHPBelowHolds(b.m.HP, b.m.MaxHP, t.Data) {
				b.trigFired[i], fire = true, true
			}
		case 1: // Periodic (0x561210): the first look starts the clock
			switch {
			case b.trigLast[i].IsZero():
				b.trigLast[i] = a.now
				fire = t.Option&1 != 0
			case a.now.Sub(b.trigLast[i]) >= time.Duration(t.Data)*time.Millisecond:
				b.trigLast[i], fire = a.now, true
			}
		}
		if fire {
			b.armed, b.hasArmed = t.Skill, true
			a.tracef("ai: monster %d arms trigger skill %d (type %d, %d)", b.id, t.Skill.ID, t.Type, t.Data)
			return t.Skill, true
		}
	}
	return combat.MonsterSkill{}, false
}

// fireSummon is BATTLE's step for an armed summon skill: on the action
// machine's cooldown (the last swing's ReuseDelay), standing, it runs the
// executor and zeroes the damage total.
func (a *monsterAI) fireSummon(b *brain) {
	if !b.lastSwing.IsZero() && a.now.Sub(b.lastSwing) < time.Duration(b.swungReuseMs)*time.Millisecond {
		return
	}
	if b.m.Moving {
		if m, ok := a.monsters.StopMotion(b.id); ok {
			b.m = m
			a.queueStop(m)
		}
	}
	ss := b.armedSummon
	b.lastSwing, b.swungReuseMs = a.now, ss.Skill.ReuseMs
	b.armedSummon, b.hasArmed = nil, false
	b.armed = combat.MonsterSkill{}
	b.damageTaken = 0
	ids := a.spawnMinions(b, ss)
	a.summons++
	if a.logger != nil {
		a.logger.Info("unique summons", "monster", b.id, "name", b.m.Name, "skill", ss.Skill.ID,
			"hp", b.m.HP, "max_hp", b.m.MaxHP, "bucket", ai.HPBucket(b.m.HP, b.m.MaxHP), "spawned", len(ids), "minions", ids)
	}
}

// spawnMinions is the minion executor, FUN_00596e50 (READ, round
// 661), for one summon skill: for each of up to nine tuples with a non-zero
// id, in order --
//
//	radius = rand() / 32767.0 * float(2 pi)        ; nest.SummonRadius
//	n      = min + abs(rand()) % (max - min + 1)   ; nest.MinionCount, cap 50, < 1 none
//	n times: the spawn routine 0x5f6eb0 around the unique (its vslot 0x14),
//	    ring radius `radius`, minimum uniqueBC + 30 + minionBC
//	    (nest.HatchOffsetMin with nest.SummonDistance), class = the tuple's
//	    low nibble through the field world's clamp (0x5eb9a0, which the
//	    spawn routine calls through the world's slot 6: nest.ClampClassByLevel),
//	    announce flag 1 (a minion is never rank 3, so nothing is announced)
//	then command 0xb {2, unique id} to the minion's AI: bound (Leader).
//
// A minion hatches from no nest: it never respawns and counts toward no
// nest or hive. Nothing removes it when its unique dies -- the only sender of
// the unbinding command 0xc is the pet (COS) path (0x4d2109), and the
// executor keeps no list of what it spawned -- so it stays until killed
// (READ, round 661). Its home is where it appeared (OURS: the engine's
// HOMING asks a nest-less monster's spawn record, 0x558af0).
func (a *monsterAI) spawnMinions(b *brain, ss *combat.SummonSkill) []int64 {
	dice := nest.RandDice(a.rng)
	var ids []int64
	for i, t := range ss.Tuples {
		if i >= nest.SummonTuplesMax {
			break
		}
		if t.RefObjID == 0 || t.Minion == nil {
			continue
		}
		radius := nest.SummonRadius(dice)
		n := nest.MinionCount(dice, t.Min, t.Max)
		minimum := nest.SummonDistance(b.m.BCRadius, t.Minion.Species.BCRadius)
		for k := 0; k < n; k++ {
			dx, dz := nest.HatchOffsetMin(dice, radius, minimum)
			sp := t.Minion.Species
			sp.Rarity = nest.ClampClassByLevel(nest.Class(t.Class), sp.Level).Rank()
			x, z := b.m.X+dx, b.m.Z+dz
			m := a.monsters.SpawnHatched(b.m.Zone, sp, x, 0, z, t.Minion.MaxHP, t.Minion.Defense, t.Minion.Attack, t.Minion.Gold,
				combat.Hatch{HomeX: x, HomeZ: z, Tactics: t.Minion.Tactics, Leader: b.id})
			ids = append(ids, m.ID)
			a.minions = append(a.minions, m.ID)
		}
	}
	return ids
}

// announceMinions pushes each minion the pass spawned to the players whose
// window holds it, after the pass (tick step 5), as a nest's hatch is.
func (a *monsterAI) announceMinions(ids []int64) {
	for _, id := range ids {
		if a.onMinion != nil {
			a.onMinion(id)
			continue
		}
		BroadcastMonsterSpawned(a.world, a.monsters, id)
	}
}
