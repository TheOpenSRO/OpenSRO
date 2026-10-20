package jobs

import (
	"bytes"
	"context"
	"testing"
)

// The leveldata job columns of the y0gi server package (MEASURED, round 799):
// levels 1..6, then INT_MAX at 7.
var testNeeds = []uint32{70875, 2388750, 8793750, 38745000, 91665000, 240187500, 2147483647}

func testNeed(level int, _ Kind) (uint32, bool) {
	if level < 1 || level > len(testNeeds) {
		return 0, false
	}
	return testNeeds[level-1], true
}

func TestRound799GainExp(t *testing.T) {
	r := Record{Kind: KindHunter, Level: 1}
	if GainExp(&r, 0, testNeed) {
		t.Fatal("a zero change sent 0x30E6")
	}
	// Below the need: exp grows, a hunter's contribution with it.
	if !GainExp(&r, 70000, testNeed) || r.Level != 1 || r.Exp != 70000 || r.Contribution != 70000 {
		t.Fatalf("after 70000: %+v", r)
	}
	// Reaching it levels once, the rest carried.
	if !GainExp(&r, 1000, testNeed) || r.Level != 2 || r.Exp != 125 {
		t.Fatalf("after the level-up: %+v", r)
	}
	// One level per call even when the gain covers two.
	r = Record{Kind: KindThief, Level: 1}
	GainExp(&r, 70875+2388750+5, testNeed)
	if r.Level != 2 || r.Exp != 2388755 {
		t.Fatalf("a double gain: %+v", r)
	}
	// A loss floors at 0 and never lowers the level; with exp 0 it is nothing.
	GainExp(&r, -5000000, testNeed)
	if r.Level != 2 || r.Exp != 0 {
		t.Fatalf("a loss: %+v", r)
	}
	if GainExp(&r, -1, testNeed) {
		t.Fatal("a loss at exp 0 sent 0x30E6")
	}
	// A trader's contribution does not move with exp.
	tr := Record{Kind: KindTrader, Level: 1}
	GainExp(&tr, 500, testNeed)
	if tr.Contribution != 0 {
		t.Fatalf("a trader's contribution moved with exp: %+v", tr)
	}
	AddTraderContribution(&tr, SaleShare(44000))
	if tr.Contribution != 4400 {
		t.Fatalf("a trader's sale share: %d", tr.Contribution)
	}
	// Level 7 keeps the exp past it.
	top := Record{Kind: KindHunter, Level: MaxLevel, Exp: 10}
	GainExp(&top, 3000000000, testNeed)
	if top.Level != MaxLevel || top.Exp != 3000000010 {
		t.Fatalf("level 7: %+v", top)
	}
	// A need of -1 is never reached (unsigned compare).
	never := func(int, Kind) (uint32, bool) { return 0xFFFFFFFF, true }
	n := Record{Kind: KindHunter, Level: 3}
	GainExp(&n, 2000000000, never)
	if n.Level != 3 {
		t.Fatalf("a need of -1 levelled: %+v", n)
	}
	// Contribution clamps.
	c := Record{Kind: KindHunter, Level: 1, Contribution: MaxContribution - 1}
	GainExp(&c, 10, testNeed)
	if c.Contribution != MaxContribution {
		t.Fatalf("contribution clamp: %d", c.Contribution)
	}
}

func TestRound799Formulas(t *testing.T) {
	// levelgold.txt level 1's min is 28 (MEASURED): trunc(280 x 0.125) = 35.
	if Unit(28) != 35 || DeathLoss(28) != 105 {
		t.Fatalf("Unit(28) %d, DeathLoss %d", Unit(28), DeathLoss(28))
	}
	// Equal levels: a x 1.0; a trader killer halves it.
	if KillExp(28, 28, false) != 35 || KillExp(28, 28, true) != 17 {
		t.Fatalf("equal levels: %d / %d", KillExp(28, 28, false), KillExp(28, 28, true))
	}
	// A far stronger victim caps at 1.5, a far weaker one at 0.5.
	if got := KillExp(800, 28, false); got != int64(float32(1000)*1.5) {
		t.Fatalf("strong victim: %d", got)
	}
	if got := KillExp(28, 800, false); got != 17 {
		t.Fatalf("weak victim: %d", got)
	}
	if JoinFee(20) != 0 || JoinFee(57) != 185000 || AliasChangeFee(57) != 2850000 {
		t.Fatal("fees")
	}
	if p, ok := RewardPool(KindTrader); !ok || p != KindHunter {
		t.Fatal("a trader's sale feeds the hunters' pool")
	}
	if p, ok := RewardPool(KindThief); !ok || p != KindThief {
		t.Fatal("a robber's sale feeds the robbers' pool")
	}
	if _, ok := RewardPool(KindHunter); ok {
		t.Fatal("a hunter has no pool")
	}
}

func TestRound799Wire(t *testing.T) {
	r, err := DecodeRequest(OpAlias, []byte{1, 0, 0, 0, 1, 3, 0, 'B', 'o', 'b'})
	if err != nil || r.NPC != 1 || r.Op != 1 || r.Alias != "Bob" {
		t.Fatalf("alias request: %+v %v", r, err)
	}
	if _, err := DecodeRequest(OpAlias, []byte{1, 0, 0, 0, 1, 9, 0, 'B'}); err == nil {
		t.Fatal("a short alias decoded")
	}
	r, _ = DecodeRequest(OpRanking, []byte{7, 0, 0, 0, 3, 1})
	if r.Kind != KindHunter || r.Type != RankContribution {
		t.Fatalf("ranking request: %+v", r)
	}
	if !bytes.Equal(JoinOK(KindThief, 1, 0x0102), []byte{1, 2, 1, 2, 1, 0, 0}) {
		t.Fatal("0xB0E1")
	}
	if !bytes.Equal(AliasFail(0x4823, 0, "x"), []byte{2, 0x23, 0x48, 0, 1, 0, 'x'}) {
		t.Fatal("0xB0E3 failure keeps the string")
	}
	if !bytes.Equal(RankingOK(KindTrader, RankActivity, []RankRow{{Rank: 1, Alias: "a", Level: 2, Exp: 3, Country: 1}}),
		[]byte{1, 1, 0, 1, 1, 1, 0, 'a', 2, 3, 0, 0, 0, 1}) {
		t.Fatal("0xB0E4 activity")
	}
	if !bytes.Equal(RankingOK(KindHunter, RankContribution, []RankRow{{Rank: 1, Alias: "a", Level: 2, Contribution: 3}}),
		[]byte{1, 3, 1, 1, 1, 1, 0, 'a', 2, 3, 0, 0, 0}) {
		t.Fatal("0xB0E4 contribution")
	}
	if !bytes.Equal(PrevJobOK(OldJob{Level: [3]int{1, 2, 3}, Exp: [3]int64{4, 5, 6}}),
		[]byte{1, 1, 4, 0, 0, 0, 2, 5, 0, 0, 0, 3, 6, 0, 0, 0}) {
		t.Fatal("0xB0E6")
	}
	if !bytes.Equal(JobExp(Record{Kind: KindHunter, Level: 4, Exp: 9}), []byte{3, 4, 9, 0, 0, 0}) {
		t.Fatal("0x30E6")
	}
}

func TestRound799Weekly(t *testing.T) {
	ctx := context.Background()
	st := NewMemStore()
	put := func(id int64, k Kind, lvl int, exp, con int64, alias string) {
		_ = st.SetAlias(ctx, id, alias)
		_ = st.Save(ctx, Record{CharID: id, Kind: k, Level: lvl, Exp: exp, Contribution: con})
	}
	put(1, KindHunter, 2, 10, 300, "h1")
	put(2, KindHunter, 3, 0, 100, "h2")
	put(3, KindTrader, 1, 50, 0, "t1")
	_ = st.AddPool(ctx, KindHunter, 1000)
	if err := Weekly(ctx, st, func(id int64) uint8 { return uint8(id % 2) }); err != nil {
		t.Fatal(err)
	}
	h1, _ := st.Get(ctx, 1)
	h2, _ := st.Get(ctx, 2)
	if h1.Reward != 750 || h2.Reward != 250 || h1.Contribution != 0 || h2.Contribution != 0 {
		t.Fatalf("shares: %+v %+v", h1, h2)
	}
	if p, _ := st.TakePool(ctx, KindHunter); p != 0 {
		t.Fatalf("pool left %d", p)
	}
	act, _ := st.Rankings(ctx, KindHunter, RankActivity)
	if len(act) != 2 || act[0].Alias != "h2" || act[1].Alias != "h1" || act[0].Country != 0 || act[1].Country != 1 {
		t.Fatalf("activity: %+v", act)
	}
	con, _ := st.Rankings(ctx, KindHunter, RankContribution)
	if len(con) != 2 || con[0].Alias != "h1" || con[0].Contribution != 300 {
		t.Fatalf("contribution: %+v", con)
	}
	// No trader had contribution: no table.
	if tc, _ := st.Rankings(ctx, KindTrader, RankContribution); len(tc) != 0 {
		t.Fatalf("trader contribution table: %+v", tc)
	}
	// Aliases are unique without case.
	if err := st.SetAlias(ctx, 3, "H1"); err != ErrAliasTaken {
		t.Fatalf("a taken alias: %v", err)
	}
}
