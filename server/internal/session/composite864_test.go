package session

import (
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 864: a premium's UIL1 grants live the composite's Param1 and refill
// every period (the entry's seconds), as CUsedItemLimit does (READ
// s:0x49f605..0x49fa9e, s:0x653a40).

func premium864Items() *refdata.MemStore {
	items := refdata.NewMemStore()
	_ = items.ImportItems(context.Background(), []refdata.Item{
		{ID: 9277, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 14, CanUse: true, RestoreHP: 2419200,
			CodeName:      "ITEM_MALL_PREMIUM_GOLDTIME",
			CompositeDesc: "[UIL1:ITEM_MALL_RESURRECTION_100P_SCROLL, A, 86400, 1],[UIL1:ITEM_MALL_RETURN_SCROLL_HIGH_SPEED, A, 86400, 3]"},
		{ID: 3783, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 6, CanUse: true, RestoreHPPct: 100, RestoreMP: 100,
			CodeName: "ITEM_MALL_RESURRECTION_100P_SCROLL"},
		{ID: 3769, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 1, CanUse: true, RestoreHP: 1000,
			CodeName: "ITEM_MALL_RETURN_SCROLL_HIGH_SPEED"},
	})
	return items
}

func TestPremiumGrantsLiveParam1AndRefillEachPeriod(t *testing.T) {
	ctx := context.Background()
	items := premium864Items()
	scroll, err := items.GetItem(ctx, 9277)
	if err != nil {
		t.Fatal(err)
	}
	keeper := NewCompositeKeeper()
	now := time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)
	plan, refusal := planComposite(ctx, items, keeper, berserk.NewTracker(), 7, scroll, now)
	if refusal != "" {
		t.Fatalf("plan refused: %q", refusal)
	}
	if len(plan.grants) != 2 {
		t.Fatalf("%d grants, want 2", len(plan.grants))
	}
	for i, g := range plan.grants {
		// MEASURED: 0x3159 carries 2,419,200 s left at the use, not 86,400.
		if got := g.until.Sub(now); got != 2419200*time.Second || plan.grantFor[i] != got {
			t.Errorf("grant %d lives %v (timer %v), want the composite's Param1, 2419200 s", g.fillID, got, plan.grantFor[i])
		}
		if g.period != 86400*time.Second || !g.periodEnd.Equal(now.Add(86400*time.Second)) {
			t.Errorf("grant %d period %v ending %v, want the entry's 86400 s from the use", g.fillID, g.period, g.periodEnd)
		}
	}
	// The refill: spent to 0 in the first period, back to the maximum at its
	// end; the end moves to the first boundary after now (s:0x653a73..0x653aa6).
	g := plan.grants[1]
	g.remaining = 0
	if g.refill(now.Add(86399 * time.Second)) {
		t.Fatal("refilled before the period's end")
	}
	if !g.refill(now.Add(86400*time.Second)) || g.remaining != 3 || !g.periodEnd.Equal(now.Add(2*86400*time.Second)) {
		t.Fatalf("at the period's end: refilled to %d, next end %v; want 3 and day 2", g.remaining, g.periodEnd)
	}
	g.remaining = 1
	if !g.refill(now.Add(5*86400*time.Second+3600*time.Second)) || g.remaining != 3 || !g.periodEnd.Equal(now.Add(6*86400*time.Second)) {
		t.Fatalf("three days away: %d uses, next end %v; want 3 and day 6", g.remaining, g.periodEnd)
	}
	// NEGATIVE: a grant kept before round 864 (no period) never refills.
	old := compositeGrant{remaining: 0, max: 3}
	if old.refill(now.Add(100 * 86400 * time.Second)) {
		t.Fatal("a grant with no period refilled")
	}
}

// The keeper refills on read and keeps the period across the store (V3/V4).
func TestPremiumGrantRefillOnReadAndStore(t *testing.T) {
	keeper := NewCompositeKeeper()
	store := timedjob.NewMemStore()
	keeper.SetStore(store)
	now := time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	clock := now
	useItemClock = func() time.Time { return clock }
	keeper.put(7, compositeGrant{fillID: 3769, scrollID: 9277, remaining: 0, max: 3, until: now.Add(28 * 24 * time.Hour),
		period: 24 * time.Hour, periodEnd: now.Add(24 * time.Hour)}, time.Hour)
	if g, ok := keeper.get(7, 3769, now.Add(time.Hour)); !ok || g.remaining != 0 {
		t.Fatalf("an hour in: %+v %v, want 0 left", g, ok)
	}
	clock = now.Add(25 * time.Hour)
	g, ok := keeper.get(7, 3769, clock)
	if !ok || g.remaining != 3 {
		t.Fatalf("a day in: %+v %v, want refilled to 3", g, ok)
	}
	jobs, _ := store.List(context.Background(), 7)
	if len(jobs) != 1 || jobs[0].V1 != 3 || jobs[0].V3 != 86400 || jobs[0].V4 != now.Add(48*time.Hour).Unix() {
		t.Fatalf("stored %+v, want V1 3, V3 86400, V4 the second day's end", jobs)
	}
}

// The resurrection share: ceil(lost x Param3 / 100), and the pools
// trunc(max x Param2 / 100) (FUN_0049ff20, READ).
func TestResurrectionScrollArithmetic(t *testing.T) {
	for _, c := range []struct {
		lost int64
		pct  int
		want int64
	}{{1000, 100, 1000}, {1001, 60, 601}, {999, 60, 600}, {1000, 0, 0}, {-1000, 100, 1000}, {0, 100, 0}} {
		if got := resurrectionExp(c.lost, c.pct); got != c.want {
			t.Errorf("resurrectionExp(%d, %d) = %d, want %d", c.lost, c.pct, got, c.want)
		}
	}
	if hp, mp := resurrectionPools(1277, 1277, 100); hp != 1277 || mp != 1277 {
		t.Errorf("pools at 100 %%: %d/%d", hp, mp)
	}
	if hp, mp := resurrectionPools(1001, 999, 50); hp != 500 || mp != 499 {
		t.Errorf("pools at 50 %%: %d/%d", hp, mp)
	}
}

// A dead character revived by the scroll: alive, HP and MP full (1 + 100 %
// clamped), the last death's EXP given back. NEGATIVE: the living are refused.
func TestReviveByResurrectionScroll(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	if err := chars.SetLeveling(ctx, c.ID, c.Level, 500, c.StatPoints, c.Str, c.Int); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(8640), c.ID, "Aria", 1, "jangan", world.Position{})
	deps := RegenDeps{Mana: mana.NewTracker()}
	if _, _, _, err := reviveByScroll(ctx, chars, deps, hub, c.ID, 100, 100); err == nil {
		t.Fatal("a living character was revived")
	}
	if _, _, err := chars.ApplyDamage(ctx, c.ID, 1<<30); err != nil {
		t.Fatal(err)
	}
	hub.SetLifeState(c.ID, world.LifeAlive, world.LifeDead, time.Now())
	noteDeathLoss(c.ID, 300)
	t.Cleanup(func() { lastDeathLoss.Delete(c.ID) })
	after, mpNow, back, err := reviveByScroll(ctx, chars, deps, hub, c.ID, 100, 60)
	if err != nil {
		t.Fatal(err)
	}
	if e, _ := hub.EntityByCharacterID(c.ID); e.Life != world.LifeAlive {
		t.Fatalf("life state %v after the scroll, want alive", e.Life)
	}
	if after.HP != after.MaxHP() || mpNow != after.MaxMP() {
		t.Errorf("HP %d/%d MP %d/%d, want both full", after.HP, after.MaxHP(), mpNow, after.MaxMP())
	}
	stored, _ := chars.GetByID(ctx, c.ID)
	if back.added != 180 || stored.Exp != 680 {
		t.Errorf("EXP given back %d (now %d), want 180 (60 %% of 300) on top of 500", back.added, stored.Exp)
	}
}
