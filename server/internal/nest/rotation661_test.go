package nest

import (
	"strings"
	"testing"
	"time"
)

// Round 661: the unique rotation, on synthetic rows. Every test in this file
// uses only the API round 660 already had (Scheduler, Hive, Slot, Join), so it
// runs against the base revision too: the round's negative (docs/
// WORLD_ISSUES.md, round 661).

// lenient throws the given values in order, then CRandMax for ever.
func lenient(throws ...int) Dice {
	return func() int {
		if len(throws) == 0 {
			return CRandMax
		}
		v := throws[0]
		throws = throws[1:]
		return v
	}
}

// rotationHive is a total-1 hive of n nests of cap 1, each a window of
// [minS, maxS] s, added to a new scheduler throwing dice.
func rotationHive(dice Dice, n, minS, maxS int) (*Scheduler, *fakeHatch, *Hive, []*Slot) {
	f := &fakeHatch{}
	s := NewSchedulerDice(dice, f.hatch)
	h := &Hive{ID: 193, TotalCap: 1}
	var nests []*Slot
	for i := 0; i < n; i++ {
		sl := &Slot{ID: int64(1000 + i), Cap: 1, Respawn: true, Active: true, Hive: h, DelayMin: minS, DelayMax: maxS,
			Input: HatchInput{Rarity: 3}, Level: 110}
		s.Add(sl)
		nests = append(nests, sl)
	}
	return s, f, h, nests
}

// aliveAt is the index of the one nest with a monster alive, -1 for none, -2
// for more than one.
func aliveAt(nests []*Slot) int {
	at := -1
	for i, sl := range nests {
		if sl.Alive() > 0 {
			if at >= 0 || sl.Alive() > 1 {
				return -2
			}
			at = i
		}
	}
	return at
}

var t661 = time.Date(2026, 9, 30, 18, 0, 0, 0, time.UTC)

// A total-1 hive pins one nest at build -- nests[rand() % n], CMainProcess::
// FUN_0055efe0 -- and hatches there alone: one unique alive, never more,
// however many passes run and whatever the other nests' caps (Lord Yarkan's
// hive has a nest of cap 7).
func TestUniqueRotationOneAliveAtItsPinnedSpot(t *testing.T) {
	s, f, h, nests := rotationHive(lenient(3), 5, 1200, 1400)
	nests[4].Cap = 7
	for i := 0; i < 20; i++ {
		s.Pass(t661.Add(time.Duration(i)*time.Hour), nil)
	}
	if got := aliveAt(nests); got != 3 {
		t.Fatalf("the unique is alive at spot %d, want 3 (the build pin's throw 3 %% 5)", got)
	}
	if h.Alive() != 1 || len(f.rolls) != 1 {
		t.Fatalf("hive alive %d, hatched %d times: want one unique, hatched once", h.Alive(), len(f.rolls))
	}
}

// At the unique's death the hive re-pins nests[min(rand() % (n+1), n-1)] --
// AI::CNest::FUN_0055eec0 -- so over the n+1 outcomes of the throw the LAST
// nest comes up twice and every other once: the bias is the engine's and is
// kept. The unique reappears there, and nowhere else.
func TestUniqueRepinKeepsTheLastNestBias(t *testing.T) {
	const n = 4
	count := make([]int, n)
	for k := 0; k <= n; k++ {
		// The build pin throws 0 (spot 0); the death throws k.
		s, _, _, nests := rotationHive(lenient(0, k), n, 1, 1)
		s.Pass(t661, nil)
		if got := aliveAt(nests); got != 0 {
			t.Fatalf("k=%d: first hatch at spot %d, want 0", k, got)
		}
		s.Died(1, t661.Add(time.Minute))
		s.Pass(t661.Add(time.Hour), nil)
		got := aliveAt(nests)
		want := k
		if want > n-1 {
			want = n - 1
		}
		if got != want {
			t.Fatalf("death throw %d: the unique came back at spot %d, want %d (min(k, n-1))", k, got, want)
		}
		count[got]++
	}
	for i, c := range count {
		want := 1
		if i == n-1 {
			want = 2
		}
		if c != want {
			t.Fatalf("over the %d outcomes spot %d came up %d times, want %d: %v", n+1, i, c, want, count)
		}
	}
}

// The wait: every nest of the hive is re-armed at the death to a fresh
// uniform draw in its [min, max] window (RearmHatchTimer 0x560e50), so the
// unique reappears min..max seconds after it died -- at min with a throw of 0,
// at max with CRandMax -- and not a moment before.
func TestUniqueTimersRearmedWithinTheWindow(t *testing.T) {
	for _, c := range []struct {
		name  string
		throw int
		wait  time.Duration
	}{{"a throw of 0", 0, 1200 * time.Second}, {"a throw of CRandMax", CRandMax, 1400 * time.Second}} {
		// The build pin 0; the first hatch's own delay 0; the death's pick 1;
		// then the re-arm's window throws (nest 0, the pinned nest 1's
		// discarded roll and its own, nest 2).
		s, _, _, nests := rotationHive(lenient(0, 0, 1, c.throw, c.throw, c.throw, c.throw), 3, 1200, 1400)
		s.Pass(t661, nil)
		died := t661.Add(10 * time.Minute)
		s.Died(1, died)
		if s.Pass(died.Add(c.wait-time.Millisecond), nil); aliveAt(nests) != -1 {
			t.Fatalf("%s: the unique reappeared at spot %d before its %v wait", c.name, aliveAt(nests), c.wait)
		}
		if s.Pass(died.Add(c.wait), nil); aliveAt(nests) != 1 {
			t.Fatalf("%s: %v after the death the unique is at %d, want spot 1", c.name, c.wait, aliveAt(nests))
		}
	}
}

// The re-arm is every nest's, in any capped hive (the `hive+0x30 == 1` test
// covers every non-zero total, not only 1): a nest that never hatched, left
// due since the build, waits a whole window from a loss out of the full hive
// instead of hatching at once.
func TestCappedHiveRearmsEveryNestAtALoss(t *testing.T) {
	f := &fakeHatch{}
	s := NewSchedulerDice(lenient(), f.hatch)
	h := &Hive{ID: 7, TotalCap: 2}
	var nests []*Slot
	for i := 0; i < 3; i++ {
		sl := &Slot{Cap: 1, Respawn: true, Active: true, Hive: h, DelayMin: 10, DelayMax: 10}
		s.Add(sl)
		nests = append(nests, sl)
	}
	s.Pass(t661, nil)
	if nests[0].Alive() != 1 || nests[1].Alive() != 1 || nests[2].Alive() != 0 {
		t.Fatalf("first pass: %d %d %d alive, want the hive's cap 2 from nests 0 and 1", nests[0].Alive(), nests[1].Alive(), nests[2].Alive())
	}
	died := t661.Add(time.Minute)
	s.Died(1, died)
	if s.Pass(died.Add(9999*time.Millisecond), nil); h.Alive() != 1 {
		t.Fatalf("a nest hatched %v after the loss, inside the 10 s window every nest was re-armed to", 9999*time.Millisecond)
	}
	if s.Pass(died.Add(10*time.Second), nil); h.Alive() != 2 {
		t.Fatalf("no hatch 10 s after the loss (hive alive %d)", h.Alive())
	}
}

// The join: a unique's npcpos spot takes its own species' nest in its total-1
// hive and is placed; the shard's _STR twin, whose nest stands on the same
// spot in a hive of its own, is never placed (a custom species, and no npcpos
// row names it); a unique with no capped hive, and every unique without a DB,
// stay out. A spot whose nest's hive belongs to another game world (the
// Pharaoh temple's 57-59) is not in the field, and a rank-8 boss with no nest
// of its own (APIS: its spot's nest is the shard's custom monster, cap 0) is
// not placed on a stand-in.
func TestJoinPlacesUniqueSpotsNotTheirTwins(t *testing.T) {
	const tac = "dwTacticsID,dwObjID,nSightRange,btAggressType,AggressData,btChangeTarget,btTraceBoundary,TraceData,btHomingType,HomingData,btAggressTypeOnHoming,btFleeType,dwChampionTacticsID,AdditionOptionFlag\n" +
		"33,5004,140,0,0,2,1,500,0,0,1,0,0,112\n" +
		"43891,43969,140,0,0,2,1,500,0,0,1,0,0,112\n" +
		"38480,5006,100,0,0,2,1,500,0,0,1,0,0,0\n" +
		"77,5005,140,0,0,2,1,500,0,0,1,0,0,0\n" +
		"90,62584,100,0,0,2,1,500,0,0,1,0,0,0\n"
	const nests = "dwNestID,dwHiveID,dwTacticsID,nRegionDBID,fLocalPosX,fLocalPosY,fLocalPosZ,wInitialDir,nRadius,nGenerateRadius,nChampionGenPercentage,dwDelayTimeMin,dwDelayTimeMax,dwMaxTotalCount,btFlag,btRespawn,btType\n" +
		"1,193,33,23198,100,0,100,0,1000,0,0,1200,1400,1,0,1,0\n" +
		"2,193,33,23198,300,0,300,0,1000,0,0,1200,1400,1,0,1,0\n" +
		"3,1579,43891,23198,100,0,100,0,1000,0,0,1200,1400,1,0,1,0\n" +
		"4,1579,43891,23198,300,0,300,0,1000,0,0,1200,1400,1,0,1,0\n" +
		"5,611,38480,29376,50,0,50,0,500,0,0,10800,10800,1,0,1,0\n" +
		"6,40,77,23198,700,0,700,0,1000,0,0,60,60,1,0,1,0\n" +
		"7,584,90,19017,1578,0,1780,0,500,0,0,10800,21600,0,0,1,0\n"
	const hives = "dwHiveID,btKeepMonsterCountType,dwOverwriteMaxTotalCount,fMonsterCountPerPC,dwSpawnSpeedIncreaseRate,dwMaxIncreaseRate,btFlag,GameWorldID,HatchObjType\n" +
		"193,0,1,0,0,0,0,1,1\n1579,0,1,0,0,0,0,1,1\n611,0,0,0,0,0,0,57,1\n40,0,0,0,0,0,0,1,1\n584,0,0,0,0,0,0,1,1\n"
	tr, err := ReadTactics(strings.NewReader(tac))
	if err != nil {
		t.Fatal(err)
	}
	nr, err := ReadNests(strings.NewReader(nests))
	if err != nil {
		t.Fatal(err)
	}
	hr, err := ReadHives(strings.NewReader(hives))
	if err != nil {
		t.Fatal(err)
	}
	db := NewDB(tr, nr, hr)
	species := map[int64]SpeciesInfo{
		5004:  {Rarity: 3, CodeName: "MOB_CH_SYNTIGER"},
		43969: {Rarity: 3, CodeName: "MOB_CH_SYNTIGER_STR"},
		5005:  {Rarity: 3, CodeName: "MOB_SYN_NOROTATION"},
		5006:  {Rarity: 8, CodeName: "MOB_SD_SYNBOSS"},
		5007:  {Rarity: 8, CodeName: "MOB_SD_SYNAPIS"},
		62584: {Rarity: 0, CodeName: "MOB_ETERNITY_DEADWARRIOR"},
	}
	look := func(id int64) (SpeciesInfo, bool) { s, ok := species[id]; return s, ok }
	spots := []Spot{
		{ObjectID: 5004, Region: 23198, X: 100, Z: 100},
		{ObjectID: 5004, Region: 23198, X: 300, Z: 300},
		{ObjectID: 43969, Region: 23198, X: 100, Z: 100},  // a twin row, were there one
		{ObjectID: 5005, Region: 23198, X: 700, Z: 700},   // a unique in an uncapped hive
		{ObjectID: 5006, Region: 29376, X: 50, Z: 50},     // a temple boss
		{ObjectID: 5007, Region: 19017, X: 1578, Z: 1780}, // a boss whose spot's nest is the shard's own
	}
	got, rep := Join(spots, db, look)
	if len(got) != 2 {
		t.Fatalf("placed %d rows %+v, want the unique's two spots", len(got), got)
	}
	for i, j := range got {
		if j.Spot.ObjectID != 5004 || j.Nest == nil || j.Hive == nil || j.Hive.ID != 193 || j.Cat != Matched {
			t.Fatalf("row %d joined %+v (nest %+v, hive %+v), want the unique on its own hive 193", i, j, j.Nest, j.Hive)
		}
	}
	if got[0].Nest.ID != 1 || got[1].Nest.ID != 2 {
		t.Fatalf("the spots joined nests %d and %d, want 1 and 2 -- never the twin's 3 and 4", got[0].Nest.ID, got[1].Nest.ID)
	}
	if rep.Custom != 1 || rep.Unique != 1 {
		t.Fatalf("report %+v: want the twin as custom and the uncapped unique left out", rep)
	}
	if _, rep := Join(spots[:2], nil, look); rep.Unique != 2 || rep.Placed != 0 {
		t.Fatalf("without a DB: %+v, want both unique spots left out", rep)
	}
}
