package nest

import (
	"math"
	"strings"
	"testing"
	"time"
)

// Every row here is synthetic: no DB row or game data ships with the tests.

// script is a Dice that throws the given values in order and fails the test
// when it runs out.
func script(t *testing.T, throws ...int) Dice {
	t.Helper()
	i := 0
	return func() int {
		if i >= len(throws) {
			t.Fatalf("dice thrown %d times, scripted %d", i+1, len(throws))
		}
		v := throws[i]
		i++
		return v
	}
}

const tacticsCSV = `dwTacticsID,dwObjID,btAIQoS,nMaxStamina,btMaxStaminaVariance,nSightRange,btAggressType,AggressData,btChangeTarget,btHelpRequestTo,btHelpResponseTo,btBattleStyle,BattleStyleData,btDiversionBasis,DiversionBasisData1,DiversionBasisData2,DiversionBasisData3,DiversionBasisData4,DiversionBasisData5,DiversionBasisData6,DiversionBasisData7,DiversionBasisData8,btDiversionKeepBasis,DiversionKeepBasisData1,DiversionKeepBasisData2,DiversionKeepBasisData3,DiversionKeepBasisData4,DiversionKeepBasisData5,DiversionKeepBasisData6,DiversionKeepBasisData7,DiversionKeepBasisData8,btKeepDistance,KeepDistanceData,btTraceType,btTraceBoundary,TraceData,btHomingType,HomingData,btAggressTypeOnHoming,btFleeType,dwChampionTacticsID,AdditionOptionFlag,szDescString128
10,5001,0,100,50,130,0,0,2,2,2,0,0,5,0,0,0,0,0,30,0,0,4,0,0,0,0,0,0,0,0,0,0,0,1,500,0,0,1,0,0,0,x
11,5001,0,100,50,115,1,0,2,2,2,0,0,5,0,0,0,0,0,30,0,0,4,0,0,0,0,0,0,0,0,0,0,0,1,500,1,0,1,0,10,0,y
20,9999,0,100,50,100,0,0,2,2,2,0,0,5,0,0,0,0,0,30,0,0,4,0,0,0,0,0,0,0,0,0,0,0,1,500,0,0,1,0,0,0,custom
30,5002,0,100,50,150,1,0,2,2,2,0,0,5,0,0,0,0,0,30,0,0,4,0,0,0,0,0,0,0,0,0,0,0,1,300,0,0,1,0,0,0,z
`

const nestCSV = `dwNestID,dwHiveID,dwTacticsID,nRegionDBID,fLocalPosX,fLocalPosY,fLocalPosZ,wInitialDir,nRadius,nGenerateRadius,nChampionGenPercentage,dwDelayTimeMin,dwDelayTimeMax,dwMaxTotalCount,btFlag,btRespawn,btType
1,100,11,25000,100,0,200,-16385,700,600,10,1,3,6,0,1,0
2,100,20,25000,500.00012,,500,0,350,100,10,2,3,3,0,1,0
3,101,20,25000,900,0,900,0,350,100,10,2,3,3,0,1,0
4,100,11,-32767,10,0,10,0,700,600,10,1,3,6,0,1,0
5,102,30,25001,50,0,50,0,500,400,0,8,12,0,0,1,0
`

const hiveCSV = `dwHiveID,btKeepMonsterCountType,dwOverwriteMaxTotalCount,fMonsterCountPerPC,dwSpawnSpeedIncreaseRate,dwMaxIncreaseRate,btFlag,GameWorldID,HatchObjType,szDescString128
100,1,120,2.5,30,80,0,1,2,"a
multi-line description"
101,0,0,0,0,0,0,1,2,b
102,0,0,0,0,0,0,1,2,c
`

func testDB(t *testing.T) *DB {
	t.Helper()
	tac, err := ReadTactics(strings.NewReader(tacticsCSV))
	if err != nil {
		t.Fatal(err)
	}
	nests, err := ReadNests(strings.NewReader(nestCSV))
	if err != nil {
		t.Fatal(err)
	}
	hives, err := ReadHives(strings.NewReader(hiveCSV))
	if err != nil {
		t.Fatal(err)
	}
	return NewDB(tac, nests, hives)
}

// The loaders read the columns by the DB's own names, the smallints as the
// engine's u16 and an empty fLocalPosY as NULL.
func TestReadTheThreeTables(t *testing.T) {
	db := testDB(t)
	if len(db.Tactics) != 4 || len(db.Nests) != 5 || len(db.Hives) != 3 {
		t.Fatalf("%d tactics, %d nests, %d hives", len(db.Tactics), len(db.Nests), len(db.Hives))
	}
	r := db.Tactics[11]
	if r.ObjID != 5001 || r.SightRange != 115 || r.AggressType != 1 || r.TraceBoundary != 1 || r.TraceData != 500 ||
		r.HomingType != 1 || r.ChampionTacticsID != 10 {
		t.Fatalf("tactics 11 read as %+v", r)
	}
	n := db.Nests[0]
	if n.Region != 25000 || n.Dir != 0xbfff || n.Radius != 700 || n.GenerateRadius != 600 || n.ChampionPct != 10 ||
		n.DelayMin != 1 || n.DelayMax != 3 || n.MaxCount != 6 || n.Respawn != 1 || n.Type != 0 || !n.HasY {
		t.Fatalf("nest 1 read as %+v", n)
	}
	if db.Nests[1].HasY || db.Nests[3].Region != 0x8001 {
		t.Fatalf("NULL y or the signed dungeon region misread: %+v %+v", db.Nests[1], db.Nests[3])
	}
	if h := db.Hives[100]; h.OverwriteMax != 120 || h.KeepType != 1 || h.CountPerPC != 2.5 || h.WorldID != 1 {
		t.Fatalf("hive 100 read as %+v", h)
	}
	// A species' own row is its lowest-id row that is no row's champion row.
	if own := db.OwnTactics(5001); own == nil || own.ID != 11 {
		t.Fatalf("own tactics of 5001 = %+v, want row 11 (row 10 is 11's champion row)", own)
	}
	if _, err := ReadNests(strings.NewReader("dwNestID,dwHiveID\n1,2\n")); err == nil {
		t.Fatal("a nest CSV without its columns loaded")
	}
}

// The join: a row whose spot has a nest of its own species is Matched and
// takes that nest; a row whose spot's nest names another species (the shard's
// swaps) keeps the npcpos species, with its own tactics row when it has one;
// uniques, dungeon rows and custom species are left out; a DB nest no row
// reaches is counted, never placed.
func TestJoinMatchesSwapsAndExcludes(t *testing.T) {
	db := testDB(t)
	species := map[int64]SpeciesInfo{
		5001: {Rarity: 0, CodeName: "MOB_TEST_A"},
		5002: {Rarity: 0, CodeName: "MOB_TEST_B"},
		5003: {Rarity: 0, CodeName: "MOB_TEST_C"},
		5004: {Rarity: 3, CodeName: "MOB_TEST_UNIQUE"},
		9999: {Rarity: 0, CodeName: "MOB_ETERNITY_TEST"},
	}
	look := func(id int64) (SpeciesInfo, bool) { s, ok := species[id]; return s, ok }
	spots := []Spot{
		{ObjectID: 5001, Region: 25000, X: 100.0001, Z: 200}, // nest 1, same species
		{ObjectID: 5002, Region: 25000, X: 500, Z: 500},      // nest 2 names 9999: swapped, own row 30
		{ObjectID: 5003, Region: 25000, X: 900, Z: 900},      // nest 3 names 9999: swapped, no row
		{ObjectID: 5001, Region: -32767, X: 10, Z: 10},       // dungeon
		{ObjectID: 5004, Region: 25000, X: 1, Z: 1},          // unique
		{ObjectID: 9999, Region: 25000, X: 5, Z: 5},          // custom species
		{ObjectID: 7777, Region: 25000, X: 5, Z: 5},          // not a monster
		{ObjectID: 5001, Region: 25000, X: 1500, Z: 1500},    // no nest near: stand-in
	}
	got, rep := Join(spots, db, look)
	if len(got) != 4 || rep.Placed != 4 || rep.Matched != 1 || rep.SwappedOwn != 1 || rep.SwappedStandIn != 1 || rep.StandIn != 1 {
		t.Fatalf("placed %d: %+v", len(got), rep)
	}
	if rep.Dungeon != 1 || rep.Unique != 1 || rep.Custom != 1 || rep.NotMonster != 1 {
		t.Fatalf("exclusions %+v", rep)
	}
	if got[0].Cat != Matched || got[0].Nest.ID != 1 || got[0].Tactics.ID != 11 || got[0].Hive.ID != 100 {
		t.Fatalf("row 0 joined %+v", got[0])
	}
	if got[1].Cat != SwappedOwn || got[1].Nest == nil || got[1].Nest.ID != 2 || got[1].Tactics.ID != 30 || got[1].DBSpecies != 9999 {
		t.Fatalf("row 1 joined %+v", got[1])
	}
	if got[2].Cat != SwappedStandIn || got[2].Tactics != nil || got[2].Spot.ObjectID != 5003 {
		t.Fatalf("row 2 joined %+v", got[2])
	}
	if got[3].Cat != StandIn {
		t.Fatalf("row 3 joined %+v", got[3])
	}
	if rep.SwappedTo[9999] != 2 || rep.MaxMatchDist > 0.001 || rep.ZeroCap != 0 {
		t.Fatalf("report %+v", rep)
	}
	// Nest 5 (region 25001) and the dungeon nest 4 are not reached; only the
	// field one of species 5002 counts (4 is a dungeon nest).
	if rep.Unjoined != 1 {
		t.Fatalf("unjoined %d, want 1", rep.Unjoined)
	}
	// Without a DB every row is a stand-in.
	got, rep = Join(spots, nil, look)
	if len(got) != 4 || rep.StandIn != 4 || got[0].Nest != nil || got[0].Tactics != nil {
		t.Fatalf("no DB: %+v", rep)
	}
}

// NestSlot_RollHatchDelay: uniform between the two columns in seconds; a
// window of one value is that value.
func TestHatchDelayWindow(t *testing.T) {
	if d := HatchDelayMs(script(t, 0), 1, 3, 0); d != 1000 {
		t.Fatalf("lowest throw: %d ms, want 1000", d)
	}
	if d := HatchDelayMs(script(t, CRandMax), 1, 3, 0); d != 3000 {
		t.Fatalf("highest throw: %d ms, want 3000", d)
	}
	if d := HatchDelayMs(script(t, 16383), 8, 12, 0); d < 9999 || d > 10001 {
		t.Fatalf("middle throw: %d ms, want ~10000", d)
	}
	if d := HatchDelayMs(script(t), 10, 10, 0); d != 10000 {
		t.Fatalf("a one-value window threw dice or gave %d", d)
	}
	if d := HatchDelayMs(script(t, CRandMax), 1, 3, 50); d != 1500 {
		t.Fatalf("a hive rate of 50 %%: %d, want 1500", d)
	}
	if HalvedDelayMs(3000) != 1500 || HalvedDelayMs(1500) != 1000 {
		t.Fatal("the halving or its 1000 ms floor")
	}
}

// GObjPC::FUN_00531240: 70 of 101 band rolls land in the outer third, 20 in
// the middle, 11 in the inner; no radius, no offset and no dice.
func TestHatchOffsetBands(t *testing.T) {
	if dx, dz := HatchOffset(script(t), 0); dx != 0 || dz != 0 {
		t.Fatal("a zero generate radius moved the hatch")
	}
	for _, c := range []struct {
		band     int
		min, max float64
	}{{0, 400, 600}, {69, 400, 600}, {70, 200, 400}, {89, 200, 400}, {90, 0, 200}, {100, 0, 200}} {
		for _, within := range []int{0, CRandMax} {
			dx, dz := HatchOffset(script(t, c.band, within, 8191), 600)
			d := math.Hypot(dx, dz)
			if d < c.min-1e-6 || d > c.max+1e-6 {
				t.Fatalf("band roll %d, throw %d: %.2f from the nest, want %.0f..%.0f", c.band, within, d, c.min, c.max)
			}
		}
	}
	// The angle throw is the last: a quarter turn puts the whole offset on z.
	dx, dz := HatchOffset(script(t, 0, CRandMax, 8192), 600)
	if math.Abs(dx) > 1 || math.Abs(dz-600) > 1 {
		t.Fatalf("quarter-turn angle: (%.1f, %.1f)", dx, dz)
	}
}

// Nest_Hatch's roll with scripted dice: party first (only while armed, at
// < 50 of 101, never for TypeID4 4), then the champion roll against the
// nest's chance and the giant split against GiantMonster_SpawnRatio; ranked
// species pass through without a throw.
func TestRollClassChampionGiantParty(t *testing.T) {
	in := HatchInput{Rarity: 0, TypeID4: 1, HasChampionTactics: true, ChampionPct: 10}
	if r := RollClass(script(t, 9, 15), in, GiantMonsterSpawnRatio); r.Class != 1 || !r.Champion {
		t.Fatalf("9 < 10 then 15 > 14: %+v, want a champion", r)
	}
	if r := RollClass(script(t, 9, 14), in, GiantMonsterSpawnRatio); r.Class != 4 || !r.Champion {
		t.Fatalf("9 < 10 then 14 <= 14: %+v, want a giant", r)
	}
	if r := RollClass(script(t, 10), in, GiantMonsterSpawnRatio); r.Class != 0 || r.Champion {
		t.Fatalf("10 is not under 10: %+v", r)
	}
	// rand() % 101: 101 folds to 0.
	if r := RollClass(script(t, 101, 15), in, GiantMonsterSpawnRatio); r.Class != 1 {
		t.Fatalf("101 %% 101 = 0 < 10: %+v", r)
	}
	armed := in
	armed.PartyArmed = true
	if r := RollClass(script(t, 49, 9, 15), armed, GiantMonsterSpawnRatio); r.Class != ClassParty|1 || !r.Class.Party() || r.Class.Rank() != 1 {
		t.Fatalf("a party champion: %+v", r)
	}
	if r := RollClass(script(t, 50, 50), armed, GiantMonsterSpawnRatio); r.Class != 0 {
		t.Fatalf("50 is not under 50: %+v", r)
	}
	tid4 := armed
	tid4.TypeID4 = 4
	if r := RollClass(script(t, 0, 50), tid4, GiantMonsterSpawnRatio); r.Class.Party() {
		t.Fatalf("a TypeID4-4 species rolled party: %+v", r)
	}
	noRow := in
	noRow.HasChampionTactics = false
	if r := RollClass(script(t), noRow, GiantMonsterSpawnRatio); r.Class != 0 {
		t.Fatalf("no champion row, yet %+v", r)
	}
	for _, rank := range []int{1, 3, 4, 5, 6, 7, 8} {
		ranked := armed
		ranked.Rarity = rank
		if r := RollClass(script(t), ranked, GiantMonsterSpawnRatio); r.Class != Class(rank) || r.Champion {
			t.Fatalf("rank %d species: %+v", rank, r)
		}
	}
}

// The field world's spawn clamp (0x5eb9a0): no giant at level 10 or below,
// no party below 10, and the party flag only on the ranks each band allows.
func TestClampClassByLevel(t *testing.T) {
	for _, c := range []struct {
		in    Class
		level int
		want  Class
	}{
		{4, 10, 1}, {4, 11, 4}, {ClassParty | 4, 10, 1}, {ClassParty | 4, 25, 4}, {ClassParty | 4, 35, ClassParty | 4},
		{ClassParty, 9, 0}, {ClassParty, 10, ClassParty}, {ClassParty | 1, 15, 1}, {ClassParty | 1, 20, ClassParty | 1},
		{ClassParty | 6, 30, ClassParty | 6}, {ClassParty | 5, 39, 5}, {ClassParty | 5, 40, ClassParty | 5}, {1, 1, 1},
	} {
		if got := ClampClassByLevel(c.in, c.level); got != c.want {
			t.Errorf("class %#x at level %d -> %#x, want %#x", c.in, c.level, got, c.want)
		}
	}
}

// fakeHatch records hatches and hands out ids.
type fakeHatch struct {
	next  int64
	fail  bool
	rolls []HatchRoll
}

func (f *fakeHatch) hatch(s *Slot, roll HatchRoll, dx, dz float64) (int64, bool, bool) {
	if f.fail {
		return 0, false, true
	}
	f.next++
	f.rolls = append(f.rolls, roll)
	return f.next, true, false
}

// The respawn window, READ: one hatch per nest per pass up to the cap, the
// next after the rolled delay; a loss out of a full nest starts the wait at
// the death, a later loss does not; a failed placement halves the wait.
func TestSchedulerNestWindow(t *testing.T) {
	f := &fakeHatch{}
	// Every throw CRandMax: the delay is the window's maximum, 3 s.
	s := NewSchedulerDice(func() int { return CRandMax }, f.hatch)
	sl := &Slot{Cap: 2, Respawn: true, Active: true, DelayMin: 1, DelayMax: 3, Input: HatchInput{}}
	s.Add(sl)
	t0 := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	if got := s.Pass(t0, nil); len(got) != 1 {
		t.Fatalf("first pass hatched %d, want 1 (one per nest per pass)", len(got))
	}
	if got := s.Pass(t0.Add(2999*time.Millisecond), nil); len(got) != 0 {
		t.Fatal("hatched inside the 3 s window")
	}
	if got := s.Pass(t0.Add(3*time.Second), nil); len(got) != 1 || sl.Alive() != 2 {
		t.Fatalf("at 3 s: %d hatched, %d alive", len(got), sl.Alive())
	}
	if got := s.Pass(t0.Add(time.Hour), nil); len(got) != 0 {
		t.Fatal("hatched past the cap")
	}
	// The first loss out of the full nest starts the wait there...
	d1 := t0.Add(time.Hour + time.Second)
	s.Died(1, d1)
	// ...and the second loss, from a nest no longer full, does not restart it.
	s.Died(2, d1.Add(2*time.Second))
	if got := s.Pass(d1.Add(2999*time.Millisecond), nil); len(got) != 0 {
		t.Fatal("respawned before the window ran from the first loss")
	}
	if got := s.Pass(d1.Add(3*time.Second), nil); len(got) != 1 {
		t.Fatalf("no respawn 3 s after the first loss (%d)", len(got))
	}
	// A failed placement halves the base (3000 -> 1500) and stamps nothing.
	f.fail = true
	at := d1.Add(6 * time.Second)
	s.Pass(at, nil)
	f.fail = false
	if got := s.Pass(d1.Add(3*time.Second+1499*time.Millisecond), nil); len(got) != 0 {
		t.Fatal("hatched before the halved wait")
	}
	if got := s.Pass(d1.Add(3*time.Second+1500*time.Millisecond), nil); len(got) != 1 {
		t.Fatal("the halved wait did not hatch")
	}
	// A cap of 0 never hatches; a non-respawning nest spends its budget.
	zero := &Slot{Cap: 0, Respawn: true, Active: true}
	once := &Slot{Cap: 1, Respawn: false, Budget: 1, Active: true}
	idle := &Slot{Cap: 1, Respawn: true, Active: false}
	s.Add(zero)
	s.Add(once)
	s.Add(idle)
	s.Pass(at.Add(time.Hour), nil)
	if zero.Alive() != 0 || once.Alive() != 1 || idle.Alive() != 0 {
		t.Fatalf("zero cap %d, budget %d, trigger nest %d alive", zero.Alive(), once.Alive(), idle.Alive())
	}
	s.Died(f.next, at.Add(time.Hour))
	s.Pass(at.Add(2*time.Hour), nil)
	if once.Alive() != 0 || once.Budget != 0 {
		t.Fatalf("a spent non-respawning nest hatched again: %d alive, budget %d", once.Alive(), once.Budget)
	}
}

// A capped hive (dwOverwriteMaxTotalCount) stops at its total; a pinned nest
// alone hatches (the unique rotation's shape, round 661).
func TestSchedulerHiveCap(t *testing.T) {
	f := &fakeHatch{}
	s := NewSchedulerDice(func() int { return 0 }, f.hatch)
	h := &Hive{ID: 1, TotalCap: 3}
	a := &Slot{Cap: 2, Hive: h, DelayMin: 1, DelayMax: 1}
	b := &Slot{Cap: 2, Hive: h, DelayMin: 1, DelayMax: 1}
	s.Add(a)
	s.Add(b)
	t0 := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		s.Pass(t0.Add(time.Duration(i)*time.Second), nil)
	}
	if h.Alive() != 3 || a.Alive()+b.Alive() != 3 {
		t.Fatalf("hive alive %d (a %d, b %d), want the cap 3", h.Alive(), a.Alive(), b.Alive())
	}
	one := &Hive{ID: 2, TotalCap: 1}
	p1, p2 := &Slot{Cap: 1, Hive: one}, &Slot{Cap: 1, Hive: one}
	s.Add(p1)
	s.Add(p2)
	one.Pinned = p2
	s.Pass(t0.Add(time.Minute), nil)
	if p1.Alive() != 0 || p2.Alive() != 1 {
		t.Fatalf("pinned hive: %d and %d alive, want only the pinned nest", p1.Alive(), p2.Alive())
	}
}

// Party arming: a kill with more than one party member near arms the nest --
// even when the pass drained the death first -- and the next rank-0 hatch
// rolls for a party monster, which disarms it.
func TestSchedulerPartyArming(t *testing.T) {
	f := &fakeHatch{}
	throws := []int{}
	dice := func() int {
		if len(throws) == 0 {
			return CRandMax
		}
		v := throws[0]
		throws = throws[1:]
		return v
	}
	s := NewSchedulerDice(dice, f.hatch)
	sl := &Slot{Cap: 1, Respawn: true, Active: true, DelayMin: 1, DelayMax: 1, Level: 50, Input: HatchInput{TypeID4: 1}}
	s.Add(sl)
	t0 := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	s.Pass(t0, nil)
	if s.ArmParty(1, 1) {
		t.Fatal("one member armed the nest")
	}
	s.Died(1, t0.Add(time.Second))
	s.Pass(t0.Add(1500*time.Millisecond), nil) // drains nothing new; the death is in the graveyard
	if !s.ArmParty(1, 2) || !sl.Input.PartyArmed {
		t.Fatal("two members did not arm the nest of a monster the pass had already buried")
	}
	throws = []int{0} // the party throw: 0 < 50
	s.Pass(t0.Add(3*time.Second), nil)
	if last := f.rolls[len(f.rolls)-1]; !last.Class.Party() || sl.Input.PartyArmed {
		t.Fatalf("the armed hatch: %+v, still armed %v", last, sl.Input.PartyArmed)
	}
}
