package session

// Where Dimension holes come from (round 869, lane W3;
// docs/protocol/forgotten_world.md 2 and 11 SERVER item 6):
//
//  1. World 1's seven TRI_GOD_PILLAR_* triggers (the trigger engine, run on
//     the open world's unit): a kill of a rarity-0 monster inside a band by a
//     killer inside the wider band loads one MOB_GOD_PILLAR_<theme>_<band> at
//     the killer, at FLOAT_INPUT 0.001 (INFERRED the chance; the engine's
//     LOAD_MONSTER, internal/trigger).
//  2. The pillar's one skill, MSKILL_GOD_PILLAR_<band>_ATTACK01, carries an
//     'ssou' summon block (MEASURED _RefSkill: {36048, class 1, 4..6} and
//     {36048, class 1, 1..1} for 35-50 -- the band's ENVY_DROP pillar) with
//     AI_AttackChance 0 and AI_SkillType 'D' (68). READ s:0x5614d0: a 'D'
//     skill is filed apart from the attack list (the selector's +0x34, not
//     +0x14), so the Basic pick never swings it; READ s:0x593738..0x593754:
//     engaging any skill with a summon block (+0x354) runs the minion
//     executor (s:0x596e50). INFERRED: 'D' is the death skill -- the pillar
//     summons its Envies when it dies (the reader of +0x34 is OPEN).
//  3. MOB_GOD_PILLAR_ENVY_DROP_<band> is the only Forgotten World monster
//     with assigned drops (MEASURED, _RefMonster_AssignedItemDrop): the
//     band's holes, grade 1 at 0.3, grade 2 at 0.2, grade 3 at 0.2, grade 4
//     at 0.1, each row DropAmountMin 0 / DropAmountMax 1. READ s:0x724a00
//     (CRefDropData::AddAssignedItemDrop): a row's attempts are
//     rand() % (max - min + 1) + min, each rolled at the ratio -- so a 0..1
//     row makes no attempt half the time, and a grade-1 hole falls from 15 %
//     of the kills, not 30 % (refdata.MonsterDrop.RollAssignedDrop is that
//     roll).

import (
	"context"
	"math/rand"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// fgwDropRand is the assigned drops' random source (a test seam: seeded).
var (
	fgwDropRand   = rand.New(rand.NewSource(rand.Int63()))
	fgwDropRandMu sync.Mutex
)

// fgwAssignedDrops are the assigned drops of a Forgotten World monster (the
// game-world data's _RefMonster_AssignedItemDrop rows; gameworld.InFGWDropScope).
func fgwAssignedDrops(m combat.Monster) []LootDrop {
	mgr := GameWorlds()
	if mgr == nil || m.RefObjID == 0 || !gameworld.InFGWDropScope(m.CodeName) {
		return nil
	}
	rows := mgr.Ref().AssignedDrops[m.RefObjID]
	if len(rows) == 0 {
		return nil
	}
	fgwDropRandMu.Lock()
	defer fgwDropRandMu.Unlock()
	var out []LootDrop
	for _, r := range rows {
		d := refdata.MonsterDrop{MonsterID: r.Monster, DropAmountMin: r.AmountMin, DropAmountMax: r.AmountMax, DropRatio: r.Ratio}
		for n := d.RollAssignedDrop(fgwDropRand); n > 0; n-- {
			out = append(out, LootDrop{ItemID: r.Item, Quantity: 1})
		}
	}
	return out
}

// fgwPillarDied runs a dead pillar's summon (the package note's step 2):
// the minions cmd/server's PillarSummon spawns, pushed to the players around.
func fgwPillarDied(hub *world.Hub, m combat.Monster) {
	if !gameworld.IsPillar(m.CodeName) {
		return
	}
	d := gameWorldDeps()
	w := unitOf(hub)
	if d.PillarSummon == nil || w == nil || w.Monsters == nil {
		return
	}
	ids := d.PillarSummon(w, m)
	for _, id := range ids {
		BroadcastMonsterSpawned(hub, w.Monsters, id)
	}
	if d.Logger != nil {
		d.Logger.Info("dimension pillar died: its summon", "pillar", m.CodeName, "world", w.ID.String(), "spawned", len(ids))
	}
}

// fgwKillLoot is what dropsForKill adds for a Forgotten World monster.
func fgwKillLoot(_ context.Context, m combat.Monster) []LootDrop { return fgwAssignedDrops(m) }
