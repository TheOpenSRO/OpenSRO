package session

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
)

// Round 838: the mall's premium, pet and spirit items (goldtime.go,
// petgrowth.go, compositeextra.go, the umdu term in buffstats.go).

// The Gold Time's day roll and drain (CTJ_PremiumKeeper::Tick 0x6529d0):
// 28 days of 3 h, today carried one day, the previous day drained first.
func TestGoldTimeRollAndDrain(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	g := &goldTime{started: start, days: 28, daily: 10800, today: 10800}
	for i := 0; i < 100; i++ {
		g.drain()
	}
	if g.today != 10700 || g.prev != 0 {
		t.Fatalf("after 100 s: today %d prev %d, want 10700 / 0", g.today, g.prev)
	}
	if g.roll(start.Add(86399 * time.Second)) {
		t.Fatal("rolled before a whole day")
	}
	if !g.roll(start.Add(86400 * time.Second)) {
		t.Fatal("no roll at 86,400 s")
	}
	if g.days != 27 || g.prev != 10700 || g.today != 10800 {
		t.Fatalf("after the roll: days %d prev %d today %d, want 27 / 10700 / 10800", g.days, g.prev, g.today)
	}
	g.drain()
	if g.prev != 10699 || g.today != 10800 {
		t.Errorf("the previous day drains first: prev %d today %d", g.prev, g.today)
	}
	// Two days missed at once (a logged-out owner): yesterday's carry is lost.
	g.roll(start.Add(3 * 86400 * time.Second))
	if g.days != 25 || g.prev != 10800 || g.today != 10800 {
		t.Errorf("after two more rolls: days %d prev %d today %d, want 25 / 10800 / 10800", g.days, g.prev, g.today)
	}
	if got := g.periodLeft(start.Add(3*86400*time.Second + 3600*time.Second)); got != 25*86400-3600 {
		t.Errorf("period left %d, want %d (days * 86400 - seconds into the day)", got, 25*86400-3600)
	}
	// The last day: days 0, today 0, the carry kept one more day, then the end.
	g.roll(start.Add(28 * 86400 * time.Second))
	if g.days != 0 || g.today != 0 || g.prev == 0 || g.ended() {
		t.Fatalf("after the last roll: days %d today %d prev %d ended %v", g.days, g.today, g.prev, g.ended())
	}
	g.roll(start.Add(29 * 86400 * time.Second))
	if !g.ended() {
		t.Errorf("one day after the period the job should end: %+v", *g)
	}
}

func TestGoldTimeStateBytes(t *testing.T) {
	got := (&GoldTimeState{RefID: 9278, PeriodLeft: 2419200, Prev: 100, Today: 10800, Paused: true}).Encode()
	want := []byte{3, 1, 0x3e, 0x24, 0, 0, 0x00, 0xea, 0x24, 0x00, 0x30, 0x2a, 0x64, 0x00, 1}
	if !bytes.Equal(got, want) {
		t.Errorf("state % x, want % x", got, want)
	}
	end := (&GoldTimeState{RefID: 9278, End: true}).Encode()
	if !bytes.Equal(end, []byte{3, 1, 0x3e, 0x24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}) {
		t.Errorf("end % x", end)
	}
}

// vslot_420's term and the pet's (FUN_004fcb00): trunc(E * pct / 100.0).
func TestPercentTerms(t *testing.T) {
	for _, c := range []struct {
		e    int64
		pct  int
		want int64
	}{{23, 100, 23}, {57, 50, 28}, {0, 100, 0}, {100, 0, 0}, {99, -5, 0}} {
		if got := petExpBonus(c.e, c.pct); got != c.want {
			t.Errorf("petExpBonus(%d, %d) = %d, want %d", c.e, c.pct, got, c.want)
		}
	}
}

func TestParsePSU1(t *testing.T) {
	es, other, err := parsePSU1("[PSU1:SKILL_MALL_PET_GROWTH_POTION_01,0]")
	if err != nil || len(es) != 1 || len(other) != 0 || es[0].byLevel || es[0].petSkillCode(7) != "SKILL_MALL_PET_GROWTH_POTION_01" {
		t.Fatalf("growth potion: %+v %v %v", es, other, err)
	}
	es, _, err = parsePSU1("[PSU1:SKILL_MALL_PET_SKILL_COLD,1]")
	if err != nil || !es[0].byLevel || es[0].petSkillCode(7) != "SKILL_MALL_PET_SKILL_COLD_007" {
		t.Fatalf("by level: %+v %v", es, err)
	}
}

func TestParseBFI1AndUQL1(t *testing.T) {
	es, err := parseCompositeDesc("[BFI1:ITEM_MALL_BOOTH_MOB_MANGYANG,A,2419200],[UQL1:QSP_ALL_POTION_3, A, 2419200, 4]")
	if err != nil || len(es) != 2 {
		t.Fatalf("%v %v", es, err)
	}
	if es[0].fourCC != "BFI1" || es[0].code != "ITEM_MALL_BOOTH_MOB_MANGYANG" || es[0].seconds != 2419200 {
		t.Errorf("BFI1: %+v", es[0])
	}
	if es[1].fourCC != "UQL1" || es[1].code != "QSP_ALL_POTION_3" || es[1].seconds != 2419200 || es[1].count != 4 {
		t.Errorf("UQL1: %+v", es[1])
	}
}

// Formula_Mitigate*'s umdu term: p259 joins p128 only against a class-3
// (unique) monster.
func TestUniqueDamagePercent(t *testing.T) {
	const who = int64(83801)
	was := uniqueDamagePercent
	uniqueDamagePercent = func(id int64) float64 {
		if id != who {
			return 0
		}
		return 10
	}
	t.Cleanup(func() { uniqueDamagePercent = was })
	if buff.ParamUniqueDamage != 259 {
		t.Fatalf("umdu's param %d, want 259 (Stat_ApplyTaggedModifier 0x499192)", buff.ParamUniqueDamage)
	}
	if got := applyBuffDamageVs(who, false, true, 1000); got != 1100 {
		t.Errorf("against a unique: %d, want 1100", got)
	}
	if got := applyBuffDamageVs(who, false, false, 1000); got != 1000 {
		t.Errorf("against any other: %d, want 1000", got)
	}
}

func TestCompositeUseRequestOption(t *testing.T) {
	for _, r := range []CompositeUseRequest{{CharacterName: "A", ItemID: 3795, Option: 7, Target: 12},
		{CharacterName: "A", ItemID: 3795, Option: 2}, {CharacterName: "A", ItemID: 3769}} {
		got, err := DecodeCompositeUseRequest(r.Encode())
		if err != nil || *got != r {
			t.Errorf("%+v -> %+v (%v)", r, got, err)
		}
	}
	res, err := DecodeCompositeUseResult((&CompositeUseResult{ItemID: 3769, Remaining: 2, CastMs: 1000}).Encode())
	if err != nil || res.CastMs != 1000 || res.Remaining != 2 {
		t.Errorf("result: %+v %v", res, err)
	}
}

func TestTimedJobMemStore(t *testing.T) {
	s := timedjob.NewMemStore()
	ctx := context.Background()
	j := timedjob.Job{CharID: 1, Type: timedjob.TypeComposite, Sub: "BFI1", Ref: 3847, Key: 35567,
		Start: time.Unix(1, 0), End: time.Unix(2419201, 0)}
	if err := s.Put(ctx, j); err != nil {
		t.Fatal(err)
	}
	j.V1 = 3
	_ = s.Put(ctx, j)
	got, _ := s.List(ctx, 1)
	if len(got) != 1 || got[0].V1 != 3 {
		t.Fatalf("list %+v", got)
	}
	_ = s.Delete(ctx, 1, timedjob.TypeComposite, "BFI1", 3847)
	if got, _ := s.List(ctx, 1); len(got) != 0 {
		t.Errorf("after delete %+v", got)
	}
}
