package main

import (
	"context"
	"log/slog"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/jobs"
	"github.com/OpenSRO/OpenSRO/server/internal/nest"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// waveTacticsIDs are the _RefTactics rows the waves run under (s:0x60bfe2:
// 2001 + k thieves, 2011 + k hunters, k 0..3).
var waveTacticsIDs = []int64{2001, 2002, 2003, 2004, 2011, 2012, 2013, 2014}

// installCaravans builds the NPC thieves' and hunters' tables (s:0x6bb8a0,
// s:0x6bc5a0: every monster row of TypeID4 2 / 3, grouped by code-name prefix
// and level) and the waves' tactics rows, and starts the caravans' tick
// (round 804, session/caravan.go). No species table: no waves.
func installCaravans(ctx context.Context, logger *slog.Logger, table *species.Table, lookup species.SkillLookup,
	db *nest.DB, hub *world.Hub, monsters *combat.Hub, monFactor uint32, npcThieves bool) {
	if table == nil {
		logger.Info("caravans: no monster table (-monsters-csv): no NPC thieves or hunters round a caravan")
		return
	}
	var thieves, hunters jobs.MobLevels
	specs := map[int64]*combat.MinionSpec{}
	nThief, nHunter := 0, 0
	for _, row := range table.Rows {
		if row.TypeID4 != jobs.MobNPCThief && row.TypeID4 != jobs.MobNPCHunter || nest.IsCustomSpecies(row.CodeName) {
			continue
		}
		spec, _ := specFromRow(monsterSpec{}, row, lookup)
		d := hatchDataOf(spec)
		specs[row.ID] = &combat.MinionSpec{Species: d.species, MaxHP: d.maxHP, Defense: d.defense, Attack: d.attack, Gold: d.gold}
		g := jobs.MobGroup(row.CodeName, row.TypeID4)
		if row.TypeID4 == jobs.MobNPCThief {
			thieves.Add(g, row.Level, row.ID)
			nThief++
		} else {
			hunters.Add(g, row.Level, row.ID)
			nHunter++
		}
	}
	tactics := map[int64]*combat.Tactics{}
	if db != nil {
		for _, id := range waveTacticsIDs {
			if t := db.Tactics[id]; t != nil {
				tactics[id] = combatTactics(t, float64(session.MonsterRoamRadius))
			}
		}
	}
	session.SetCaravanDeps(session.CaravanDeps{Thieves: &thieves, Hunters: &hunters, Specs: specs, Tactics: tactics,
		MonFactor: monFactor, NPCThieves: npcThieves, Hub: hub, Monsters: monsters, Logger: logger})
	session.RunCaravans(ctx)
	logger.Info("caravans: NPC thieves and hunters round a trade transport (s:0x60bf30)", "thief_rows", nThief,
		"hunter_rows", nHunter, "tactics_rows", len(tactics), "trade_mon_factor", monFactor, "npc_thieves", npcThieves)
	if len(tactics) < len(waveTacticsIDs) {
		logger.Warn("caravans: the waves' _RefTactics rows 2001-2004 / 2011-2014 are missing (-nest-db-dir): the waves run the stand-in tactics",
			"found", len(tactics))
	}
}
