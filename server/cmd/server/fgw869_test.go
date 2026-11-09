package main

// Round 869 lane W3: a dead dimension pillar's summon through the minion
// executor -- the 35-50 pillar's measured 'ssou' block {36048, class 1, 4..6}
// and {36048, class 1, 1..1} spawns 5..7 of its ENVY_DROP pillar around it,
// champions (class 1).

import (
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

func TestPillarSummon(t *testing.T) {
	const header = "ID,CodeName,OrgCodeName,OrgID,NameKey,Name,TypeID4,Rarity,Level,MaxHP,WalkSpeed,RunSpeed,BCRadius,Col71,Col72,Col73,Col74,Col75,Col76,Col77,Col78,Skill1,Skill2,Skill3,Skill4,Skill5,Skill6,Skill7,Skill8,Skill9,Skill10,Model,ModelFromOrg,GoldMin,GoldMax,ExpToGive,Knockdown,KORecoverTime\n"
	rows := "36034,MOB_GOD_PILLAR_TOGUI_35_50,,0,SN_MOB_GOD_PILLAR,Dimension pillar,1,0,35,1940,0,0,10,148,236,35,35,95,0,95,2,32101,0,0,0,0,0,0,0,0,0,quest\\red_ins_quest_teleport.bsr,0,147,309,1074,0,0\n" +
		"36048,MOB_GOD_PILLAR_ENVY_DROP_35_50,MOB_GOD_GHOST_ENVY_A1,36305,SN_MOB_GOD_GHOST_ENVY,Envy,1,0,40,5561,15,75,7,186,297,40,40,105,0,105,2,32108,0,0,0,0,0,0,0,0,0,mob\\god\\elemental.bsr,0,165,345,5484,3,3000\n"
	tab, err := species.Read(strings.NewReader(header + rows))
	if err != nil {
		t.Fatal(err)
	}
	db := &nest.DB{Skills: map[int64]*nest.SkillRow{32101: {ID: 32101, Code: "MSKILL_GOD_PILLAR_TOGUI_35_50_ATTACK01", Summon: true,
		Tuples: []nest.SummonTuple{{RefObjID: 36048, Class: 1, Min: 4, Max: 6}, {RefObjID: 36048, Class: 1, Min: 1, Max: 1}}}}}
	b := &gameWorldBuild{db: db, table: tab}
	monsters := combat.NewHub()
	mgr := gameworld.NewManager(gameworld.ManagerConfig{})
	w := mgr.AttachOpenWorld(world.NewHub(), monsters, grounditem.NewHub())
	pillar := combat.Monster{ID: 1, RefObjID: 36034, CodeName: "MOB_GOD_PILLAR_TOGUI_35_50", Zone: "jangan", X: 100, Z: 200, BCRadius: 10}
	for run := 0; run < 20; run++ {
		ids := b.pillarSummon(w, pillar)
		if len(ids) < 5 || len(ids) > 7 {
			t.Fatalf("run %d: %d minions, want 5..7", run, len(ids))
		}
		for _, id := range ids {
			m, ok := monsters.Get(id)
			if !ok || m.CodeName != "MOB_GOD_PILLAR_ENVY_DROP_35_50" || m.RefObjID != 36048 || m.Rarity != 1 || m.Zone != "jangan" {
				t.Fatalf("minion %+v", m)
			}
			// At the executor's minimum: the pillar's 10 + 30 + the Envy's 7.
			if d := (m.X-100)*(m.X-100) + (m.Z-200)*(m.Z-200); d < 46.9*46.9 || d > 47.1*47.1 {
				t.Errorf("minion at %.1f, %.1f: %.2f off, want 47", m.X, m.Z, d)
			}
		}
	}
}
