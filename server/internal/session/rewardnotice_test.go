package session

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Round 716: every receiver of a kill share is told its gain with 0x3056 --
// the member who never hit by distributeKill, after its OpLevelUp; the killer
// by the attack path -- and a member whose level rose gets the stat-point u16.
// A character outside the party hears nothing.
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

	// The killer's 0x3056 is left to the attack path (sent after its
	// OpAttackResult and OpLevelUp); distributeKill tells the others.
	w.c["Aria"].none(charmsg.OpExpGain)
	if kg := expGainFor(m, killer); kg.Exp != killer.exp || kg.SkillExp != killer.sp || kg.LevelUp || kg.Source != 4321 {
		t.Errorf("the killer's 0x3056 would say %+v; its payout %d/%d, no level-up", kg, killer.exp, killer.sp)
	}

	// Bram levelled: OpLevelUp first, then 0x3056 last (GObjPC_SetLevel's
	// 0x3054 precedes 0x3056 in GainExpAndLevel).
	var seen []uint16
	var bramGain *proto.Packet
	for bramGain == nil {
		w.c["Bram"].conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(w.c["Bram"].r, nil, nil)
		if err != nil {
			t.Fatalf("Bram: waiting for 0x3056 after %x: %v", seen, err)
		}
		seen = append(seen, p.Opcode)
		if p.Opcode == charmsg.OpExpGain {
			bramGain = p
		}
	}
	levelUpFirst := false
	for _, op := range seen {
		if op == OpLevelUp {
			levelUpFirst = true
		}
	}
	if !levelUpFirst {
		t.Errorf("Bram's messages %x: OpLevelUp must come before 0x3056", seen)
	}
	got := map[string]charmsg.ExpGain{}
	g, err := charmsg.DecodeExpGain(bramGain.Data)
	if err != nil || g.Source != 4321 || g.Exp <= 0 || g.SkillExp <= 0 {
		t.Errorf("Bram's 0x3056 %+v (%v): want source 4321 and a positive EXP and skill EXP", g, err)
	}
	got["Bram"] = g
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

// The EXP is clamped only for a receiver that starts at 110 (GS 0x4e52c7):
// below it the award is written as awarded, even past what it added.
func TestExpGainClampsOnlyAtTheCap(t *testing.T) {
	m := combat.Monster{ID: 9}
	below := killPayout{exp: 5000, expAdded: 1200, startLevel: 109}
	if g := expGainFor(m, below); g.Exp != 5000 {
		t.Errorf("from 109: %d, want the award 5000", g.Exp)
	}
	at := killPayout{exp: 5000, expAdded: 17, startLevel: leveldata.MaxCharacterLevel}
	if g := expGainFor(m, at); g.Exp != 17 {
		t.Errorf("at 110: %d, want what fits, 17", g.Exp)
	}
}

// The gold pick-up through the real handler (round 716's review, F6): in an
// Item Auto Share party every credited share -- the picker's included -- is
// sent a shown 0x304E kind 1 with its row's new total; a character outside
// the party hears nothing; a solo pick-up sends the picker an unshown one.
func TestGoldPickUpTellsEveryShare(t *testing.T) {
	ctx := context.Background()
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare|party.FlagItemShare)
	w.move(t, "Aria", 10, 10)
	w.move(t, "Bram", 20, 10)
	w.move(t, "Cato", 25, 10)
	w.move(t, "Dara", 400, 400)
	aria, _ := w.hub.FindByName("Aria")

	pile := w.ground.Drop(aria.Zone, 1, 1001, true, float32(aria.Pos.X), float32(aria.Pos.Y), float32(aria.Pos.Z), 0)
	// The credits (and their 0x304E) come before the picker's own reply.
	w.c["Aria"].send(OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: pile.ID}).Encode())
	for _, n := range []string{"Aria", "Bram"} {
		total, show, err := charmsg.DecodeGold(w.c[n].next(charmsg.OpCharInfo).Data)
		c, _ := w.chars.GetByID(ctx, w.ids[n])
		if err != nil || !show || total != c.Gold {
			t.Errorf("%s's 0x304E: total %d show %v (%v); the row has %d", n, total, show, err, c.Gold)
		}
	}
	pr, err := DecodePickUpResult(w.c["Aria"].next(OpPickUpResult).Data)
	if err != nil || pr.Code != 0 || !pr.Gold || pr.Quantity != 501 {
		t.Fatalf("Aria's pick-up %+v (%v): want gold, her share 501 (1001 split in two, the remainder hers)", pr, err)
	}
	w.c["Cato"].none(charmsg.OpCharInfo)

	dara, _ := w.hub.FindByName("Dara")
	solo := w.ground.Drop(dara.Zone, 1, 70, true, float32(dara.Pos.X), float32(dara.Pos.Y), float32(dara.Pos.Z), 0)
	w.c["Dara"].send(OpPickUp, (&PickUpRequest{CharacterName: "Dara", GroundItemID: solo.ID}).Encode())
	total, show, err := charmsg.DecodeGold(w.c["Dara"].next(charmsg.OpCharInfo).Data)
	c, _ := w.chars.GetByID(ctx, w.ids["Dara"])
	if err != nil || show || total != c.Gold {
		t.Errorf("Dara's solo 0x304E: total %d show %v (%v); want unshown, the row's %d", total, show, err, c.Gold)
	}
	if pr, err := DecodePickUpResult(w.c["Dara"].next(OpPickUpResult).Data); err != nil || pr.Code != 0 || pr.Quantity != 70 {
		t.Fatalf("Dara's solo pick-up %+v (%v)", pr, err)
	}
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
	tellGold(ctx, w.chars, w.hub, w.ids["Bram"], true)
	total, show, err := charmsg.DecodeGold(w.c["Bram"].next(charmsg.OpCharInfo).Data)
	c, _ := w.chars.GetByID(ctx, w.ids["Bram"])
	if err != nil || !show || total != c.Gold {
		t.Fatalf("0x304E: total %d show %v err %v; the row has %d", total, show, err, c.Gold)
	}
}
