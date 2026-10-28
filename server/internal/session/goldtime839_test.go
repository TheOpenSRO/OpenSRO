package session

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 839 lane P: the Gold Time across a restart. The job keeps retail's
// _TIMEDJOB words (TimeToKeep = into << 8 | days, Data2 = prev << 16 |
// today), its day clock runs only while the owner is in the world, and a
// load catches it up with the wall clock (CTJ_PremiumKeeper::vslot_012
// s:0x6525bf): R = (Data3 + 1) * 86400 + P1 - (now - start).

type goldTimeItems map[int64]*refdata.Item

func (m goldTimeItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	if it, ok := m[id]; ok {
		return it, nil
	}
	return nil, fmt.Errorf("no item %d", id)
}

// goldTime4W is ITEM_PRE_GOLTAM_4W's params (MEASURED in the shard's item
// export: P1 2,419,200, P3 10,800,000).
func goldTime4W() *refdata.Item {
	return &refdata.Item{ID: 9278, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeExpendable, TypeID3: 13, TypeID4: 4,
		Param1: 2419200, ReinforceRate2: 10800000, ReinforceRate3: 50, Param5: 50}
}

// goldTimeRestartHarness wires the premium's deps on a MemStore (the store
// that outlives the "restart") and a fake clock, and forgets the process's
// running premiums between steps the way a restart does.
func goldTimeRestartHarness(t *testing.T, clock *time.Time) timedjob.Store {
	t.Helper()
	store := timedjob.NewMemStore()
	savedDeps := goldTimes.deps.Load()
	goldTimes.deps.Store(&goldTimeDeps{store: store, items: goldTimeItems{9278: goldTime4W()}})
	savedClock := useItemClock
	useItemClock = func() time.Time { return *clock }
	t.Cleanup(func() {
		goldTimes.deps.Store(savedDeps)
		useItemClock = savedClock
		goldTimes.mu.Lock()
		delete(goldTimes.m, 839)
		goldTimes.mu.Unlock()
	})
	return store
}

func restartProcess() {
	goldTimes.mu.Lock()
	goldTimes.m = map[int64]*goldTime{}
	goldTimes.mu.Unlock()
}

func TestGoldTimeAcrossRestart(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	clock := start
	store := goldTimeRestartHarness(t, &clock)
	ctx := context.Background()
	restartProcess()
	startGoldTime(ctx, nil, 839, goldTime4W(), clock)

	// Ten hours online, one of them in battle: the day clock and the drain.
	g := goldTimes.m[839]
	for i := 0; i < 3600; i++ {
		g.drain()
	}
	clock = start.Add(10 * time.Hour)
	g.advance(clock)
	goldTimeLeft(839) // the save a logout (or the last periodic save) makes
	jobs, _ := store.List(ctx, 839)
	if len(jobs) != 1 || jobs[0].V1 != int64(36000)<<8|28 || jobs[0].V2 != 7200 || !jobs[0].Start.Equal(start) {
		t.Fatalf("saved row %+v, want TimeToKeep 36000<<8|28, Data2 0<<16|7200, Data1 the start", jobs)
	}

	// The server is down for 3 days and 2 hours; the owner comes back.
	restartProcess()
	clock = start.Add(3*24*time.Hour + 12*time.Hour)
	goldTimeArrived(ctx, world.Entity{CharacterID: 839})
	cp, ok := goldTimeOf(839)
	if !ok {
		t.Fatal("no gold time after the restart")
	}
	// Three rolls (at +1 d, +2 d, +3 d): the first carried 7,200, the next
	// two full days; today is full again; into is 12 h.
	if cp.days != 25 || cp.prev != 10800 || cp.today != 10800 || cp.into != 12*3600 {
		t.Errorf("after the restart: days %d prev %d today %d into %d, want 25 / 10800 / 10800 / 43200",
			cp.days, cp.prev, cp.today, cp.into)
	}
	if got := cp.periodLeft(); got != 25*86400-12*3600 {
		t.Errorf("period word %d, want %d", got, 25*86400-12*3600)
	}
	jobs, _ = store.List(ctx, 839)
	if len(jobs) != 1 || jobs[0].V1 != int64(12*3600)<<8|25 {
		t.Errorf("the load saves its catch-up: %+v", jobs)
	}

	// A second restart a minute later replays nothing more.
	goldTimeLeft(839)
	restartProcess()
	clock = clock.Add(time.Minute)
	goldTimeArrived(ctx, world.Entity{CharacterID: 839})
	if cp, _ := goldTimeOf(839); cp.days != 25 || cp.into != 12*3600+60 {
		t.Errorf("a quick second restart: days %d into %d, want 25 / %d", cp.days, cp.into, 12*3600+60)
	}
}

// Past P1 + 1 day (R <= 0) the load zeroes the words and tells nothing; the
// first tick ends the job.
func TestGoldTimeExpiredWhileAway(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	clock := start
	store := goldTimeRestartHarness(t, &clock)
	ctx := context.Background()
	restartProcess()
	startGoldTime(ctx, nil, 839, goldTime4W(), clock)
	goldTimeLeft(839)

	// 28 days and 23 hours later: still the carry day (R > 0).
	restartProcess()
	clock = start.Add(29*24*time.Hour - time.Hour)
	goldTimeArrived(ctx, world.Entity{CharacterID: 839})
	cp, _ := goldTimeOf(839)
	if cp.days != 0 || cp.today != 0 || cp.prev != 10800 || cp.ended() {
		t.Fatalf("on the carry day: %+v", cp)
	}
	goldTimeLeft(839)

	// One more hour: P1 + 1 day after the start, R = 0.
	restartProcess()
	clock = start.Add(29 * 24 * time.Hour)
	goldTimeArrived(ctx, world.Entity{CharacterID: 839})
	cp, ok := goldTimeOf(839)
	if !ok || !cp.ended() {
		t.Fatalf("expired at the load: ok %v %+v, want kept zeroed for the first tick to end", ok, cp)
	}
	if jobs, _ := store.List(ctx, 839); len(jobs) != 1 || jobs[0].V1 != 0 || jobs[0].V2 != 0 {
		t.Errorf("the zeroed words are saved: %+v", jobs)
	}
}

// A round-838 row (V1 = days, V4 = its own roll count) loads as into 0 and
// catches up to the same day; V4 is not read as Data3.
func TestGoldTimeRound838Row(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	clock := start.Add(5*24*time.Hour + time.Hour)
	store := goldTimeRestartHarness(t, &clock)
	ctx := context.Background()
	restartProcess()
	// Saved by round 838 two days in: days 26, rolled 2, 100 s left today.
	_ = store.Put(ctx, timedjob.Job{CharID: 839, Type: timedjob.TypePremium, Ref: 9278, Key: 9278, Start: start,
		V1: 26, V2: 100, V4: 2})
	goldTimeArrived(ctx, world.Entity{CharacterID: 839})
	cp, _ := goldTimeOf(839)
	if cp.days != 23 || cp.into != 3600 || cp.prev != 10800 || cp.today != 10800 {
		t.Errorf("old row: days %d into %d prev %d today %d, want 23 / 3600 / 10800 / 10800", cp.days, cp.into, cp.prev, cp.today)
	}
}

// The words ahead of the clock (a clock set back) change nothing at the load.
func TestGoldTimeWordsAheadOfClock(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	g := &goldTime{started: start, period: 28 * 86400, days: 27, into: 7200, today: 500, prev: 9, daily: 10800}
	if !g.catchUp(start.Add(86400 * time.Second)) {
		t.Fatal("ended")
	}
	if g.days != 27 || g.into != 7200 || g.today != 500 || g.prev != 9 {
		t.Errorf("words moved: %+v", *g)
	}
}
