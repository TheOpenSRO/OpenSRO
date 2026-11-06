package session

import (
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
)

// Round 864 follow-up (OURS): a premium used before v0.1.634 kept its BFI1
// and UQL1 rows but lost its UIL1 fill rows after a day. The first world
// entry re-creates the fills: full, ending with the composite, refilling on
// the use's daily boundaries.
func TestDroppedPremiumFillsAreRestored(t *testing.T) {
	ctx := context.Background()
	items := premium864Items()
	_ = items.ImportItems(ctx, []refdata.Item{
		{ID: 23937, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 8, CanUse: true, CodeName: "ITEM_ETC_SECOND_HWAN"},
		{ID: 23944, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 14, CanUse: true, RestoreHP: 3600,
			CodeName: "ITEM_ETC_SECOND_HWAN_SCROLL_01", CompositeDesc: "[UIL1:ITEM_ETC_SECOND_HWAN,A,3600,1]"},
	})
	store := timedjob.NewMemStore()
	keeper := NewCompositeKeeper()
	keeper.SetStore(store)
	keeper.SetItems(items)
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	// Pain's rows (prod, 2026-11-06): the use at 2026-10-28 07:05:59, 28 days.
	use := time.Date(2026, 10, 28, 7, 5, 59, 178000000, time.UTC)
	end := use.Add(2419200 * time.Second)
	now := time.Date(2026, 11, 6, 1, 38, 0, 0, time.UTC)
	useItemClock = func() time.Time { return now }
	const char = 12
	rows := []timedjob.Job{
		{CharID: char, Type: timedjob.TypeComposite, Sub: "BFI1", Ref: 3847, Key: 9277, Start: use, End: end},
		{CharID: char, Type: timedjob.TypeComposite, Sub: "UQL1", Ref: 224, Key: 9277, Start: use, End: end, V1: 4, V2: 4},
		{CharID: char, Type: timedjob.TypePremium, Ref: 9278, Key: 9278, Start: use, V1: 17085716, V2: 674703920},
		// NEGATIVE: an Energy of life used an hour ago has no BFI1 / UQL1 row;
		// its spent fill must not come back.
	}
	for _, j := range rows {
		if err := store.Put(ctx, j); err != nil {
			t.Fatal(err)
		}
	}
	jobs, _ := store.List(ctx, char)
	if n := keeper.restoreDroppedFills(ctx, char, jobs, now); n != 2 {
		t.Fatalf("restored %d grants, want 2 (the composite's two UIL1 fills)", n)
	}
	nextDay := time.Date(2026, 11, 6, 7, 5, 59, 178000000, time.UTC)
	for _, want := range []struct {
		fill int64
		max  int
	}{{3783, 1}, {3769, 3}} {
		g, ok := keeper.get(char, want.fill, now)
		if !ok {
			t.Fatalf("fill %d not running", want.fill)
		}
		if g.scrollID != 9277 || g.remaining != want.max || g.max != want.max || !g.until.Equal(end) ||
			g.period != 24*time.Hour || !g.periodEnd.Equal(nextDay) {
			t.Errorf("fill %d: %+v; want composite 9277, %d/%d, until %v, period 24h ending %v", want.fill, g, want.max, want.max, end, nextDay)
		}
	}
	kept, _ := store.List(ctx, char)
	uil1 := 0
	for _, j := range kept {
		if j.Sub == "UIL1" {
			uil1++
			if j.V3 != 86400 || j.V4 != nextDay.Unix() || !j.End.Equal(end) {
				t.Errorf("stored %+v, want V3 86400, V4 the next boundary, End the composite's", j)
			}
		}
	}
	if uil1 != 2 {
		t.Fatalf("%d UIL1 rows stored, want 2", uil1)
	}
	// Done once: a second pass (a spent fill stays spent).
	keeper.setRemaining(char, 3769, 1)
	jobs, _ = store.List(ctx, char)
	if n := keeper.restoreDroppedFills(ctx, char, jobs, now); n != 0 {
		t.Fatalf("a second pass restored %d", n)
	}
	if g, _ := keeper.get(char, 3769, now); g.remaining != 1 {
		t.Fatalf("a running fill was reset to %d", g.remaining)
	}
	// NEGATIVE: rows that have ended restore nothing.
	other := NewCompositeKeeper()
	other.SetItems(items)
	if n := other.restoreDroppedFills(ctx, char, jobs, end.Add(time.Second)); n != 0 {
		t.Fatalf("an ended composite restored %d", n)
	}
	// NEGATIVE: a hwan composite's TypeID3 1 fill is never restored, even
	// with a row naming it.
	hw := []timedjob.Job{{CharID: 13, Type: timedjob.TypeComposite, Sub: "UQL1", Ref: 1, Key: 23944, Start: now, End: now.Add(time.Hour)}}
	if n := other.restoreDroppedFills(ctx, 13, hw, now); n != 0 {
		t.Fatalf("the Energy of life's fill was restored (%d)", n)
	}
}

func TestRestoredPeriodEnd(t *testing.T) {
	start := time.Date(2026, 10, 28, 7, 0, 0, 0, time.UTC)
	day := 24 * time.Hour
	for _, c := range []struct {
		now, want time.Time
	}{
		{start, start.Add(day)},
		{start.Add(day - time.Second), start.Add(day)},
		{start.Add(day), start.Add(2 * day)},
		{start.Add(9*day + time.Hour), start.Add(10 * day)},
	} {
		if got := restoredPeriodEnd(start, c.now, day); !got.Equal(c.want) {
			t.Errorf("at %v: %v, want %v", c.now, got, c.want)
		}
	}
}
