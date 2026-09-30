package session

import "github.com/OpenSRO/srrevamp/server/internal/combat"

// The round-661 shim: everything summon661_test.go needs of the round's new
// API, in one file. The round's negative runs summon661_test.go against the
// base revision with a stub of this file that spawns the unique plainly --
// its summon and trigger skills on its attack list, no selector, no leader --
// since the base has no summons (docs/WORLD_ISSUES.md, round 661).

// uniqueSpec661 is a synthetic unique: its attack skills, its summon slots
// (Summon_A's four, a zero ID an empty slot, or Summon_B's list) and its
// triggers.
type uniqueSpec661 struct {
	kindB    bool
	attacks  []combat.MonsterSkill
	summons  []summonSpec661
	triggers []trigger661
}

type summonSpec661 struct {
	skill  combat.MonsterSkill
	tuples []tuple661
}

type tuple661 struct {
	id       int64
	class    uint8
	min, max int
	bc       int
	level    int
}

type trigger661 struct {
	skill combat.MonsterSkill
	typ   uint8
	data  int
}

// spawnUnique661 spawns the unique at (x, z) in jangan, standing (no speed),
// BCRadius 28, level 110, rank 3.
func spawnUnique661(monsters *combat.Hub, x, z float64, maxHP int, u uniqueSpec661) combat.Monster {
	sp := combat.Species{Name: "Tiger Girl", CodeName: "MOB_CH_TIGERWOMAN", RefObjID: 1954, Level: 110, Rarity: 3, BCRadius: 28,
		Skills: u.attacks}
	if len(u.attacks) > 0 {
		sp.AttackReuseMs, sp.AttackRange, sp.AttackMin, sp.AttackMax = u.attacks[0].ReuseMs, u.attacks[0].Range, u.attacks[0].AttMin, u.attacks[0].AttMax
	}
	s := &combat.SummonAI{Kind: combat.SummonKindA}
	if u.kindB {
		s.Kind = combat.SummonKindB
	}
	for _, ss := range u.summons {
		cs := combat.SummonSkill{Skill: ss.skill}
		for _, t := range ss.tuples {
			cs.Tuples = append(cs.Tuples, combat.SummonTuple{RefObjID: t.id, Class: t.class, Min: t.min, Max: t.max,
				Minion: &combat.MinionSpec{Species: combat.Species{Name: "White Tiger", CodeName: "MOB_CH_WHITETIGER", RefObjID: t.id,
					Level: t.level, BCRadius: t.bc, WalkSpeed: 0, RunSpeed: 0}, MaxHP: 1000, Defense: 1, Attack: 1}})
		}
		s.Skills = append(s.Skills, cs)
	}
	if len(u.summons) > 0 {
		sp.Summon = s
	}
	for _, t := range u.triggers {
		sp.Triggers = append(sp.Triggers, combat.AITrigger{Skill: t.skill, Type: t.typ, Data: t.data})
	}
	m := monsters.SpawnHatched("jangan", sp, x, 0, z, maxHP, 1, 1, 0, combat.Hatch{HomeX: x, HomeZ: z,
		Tactics: &combat.Tactics{ID: 33, SightRange: 140, TraceBoundary: 1, TraceData: 500, RoamRadius: 1000}})
	return *m
}

// minionsOf661 is every live monster bound to leader.
func minionsOf661(monsters *combat.Hub, leader int64) []combat.Monster {
	var out []combat.Monster
	for _, m := range monsters.AppendAll(nil) {
		if m.Leader == leader && leader != 0 {
			out = append(out, m)
		}
	}
	return out
}

// summons661 is how many summons the runtime has fired.
func summons661(a *monsterAI) int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.summons
}
