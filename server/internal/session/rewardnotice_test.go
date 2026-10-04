package session

import (
	"context"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
)

// Round 716: every receiver of a kill share is told its gain with 0x3056 --
// the killer and the member who never hit -- and a member whose level rose
// gets the stat-point u16. A character outside the party hears nothing.
func TestKillShareSendsExpGainToEveryReceiver(t *testing.T) {
	// Level 7 needs only 50 EXP to the next level, so Bram's share raises it.
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n" +
		"7,50,1,200\n8,100000000,1,220\n10,100000000,1,300\n"))
	if err != nil {
		t.Fatal(err)
	}
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })

	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.move(t, "Aria", 10, 10)
	w.move(t, "Bram", 20, 10)
	w.move(t, "Cato", 30, 10)

	m := combat.Monster{ID: 4321, Zone: "jangan", Level: 10, MaxHP: 100, ExpToGive: 300, HasExpToGive: true}
	hits := []combat.Hit{{AttackerID: w.ids["Aria"], Damage: 100}}
	deps := combatDeps{chars: w.chars, hub: w.hub, parties: w.parties}
	killer, err := distributeKill(context.Background(), deps, w.ids["Aria"], m, hits)
	if err != nil {
		t.Fatal(err)
	}

	got := map[string]charmsg.ExpGain{}
	for _, n := range []string{"Aria", "Bram"} {
		g, err := charmsg.DecodeExpGain(w.c[n].next(charmsg.OpExpGain).Data)
		if err != nil {
			t.Fatalf("%s: %v", n, err)
		}
		if g.Source != 4321 || g.Exp <= 0 || g.SkillExp <= 0 {
			t.Errorf("%s's 0x3056 %+v: want source 4321 and a positive EXP and skill EXP", n, g)
		}
		got[n] = g
	}
	if got["Aria"].Exp != killer.expAdded || got["Aria"].SkillExp != killer.sp {
		t.Errorf("the killer's 0x3056 says %d/%d, its payout %d/%d", got["Aria"].Exp, got["Aria"].SkillExp, killer.expAdded, killer.sp)
	}
	if got["Aria"].LevelUp {
		t.Errorf("Aria (level 10, a 100,000,000 requirement) did not level, but the u16 was sent")
	}
	bram, err := w.chars.GetByID(context.Background(), w.ids["Bram"])
	if err != nil {
		t.Fatal(err)
	}
	if bram.Level != 8 || !got["Bram"].LevelUp || got["Bram"].StatPoints != uint16(bram.StatPoints) {
		t.Errorf("Bram: level %d, 0x3056 level-up %v with %d stat points, row has %d; want level 8 and the row's points",
			bram.Level, got["Bram"].LevelUp, got["Bram"].StatPoints, bram.StatPoints)
	}
	w.c["Cato"].none(charmsg.OpExpGain)
}

// An award of nothing sends nothing (GS 0x4e5393..0x4e53a1).
func TestExpGainNotSentForNothing(t *testing.T) {
	w := newPartyWorld(t)
	sendExpGain(w.hub, w.ids["Aria"], charmsg.ExpGain{Source: 1})
	w.c["Aria"].none(charmsg.OpExpGain)
}

// A gold-share member is told its new total with 0x304E kind 1, shown.
func TestTellGoldSendsTheTotal(t *testing.T) {
	w := newPartyWorld(t)
	ctx := context.Background()
	if err := w.chars.AddGold(ctx, w.ids["Bram"], 777); err != nil {
		t.Fatal(err)
	}
	tellGold(ctx, w.chars, w.hub, w.ids["Bram"])
	total, show, err := charmsg.DecodeGold(w.c["Bram"].next(charmsg.OpCharInfo).Data)
	c, _ := w.chars.GetByID(ctx, w.ids["Bram"])
	if err != nil || !show || total != c.Gold {
		t.Fatalf("0x304E: total %d show %v err %v; the row has %d", total, show, err, c.Gold)
	}
}
