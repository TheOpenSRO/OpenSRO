package main

import (
	"io"
	"log/slog"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/nest"
	"github.com/OpenSRO/srrevamp/server/internal/spawn"
	"github.com/OpenSRO/srrevamp/server/internal/species"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// Round 660's full map, on SYNTHETIC rows only: no npcpos, characterdata or
// DB row ships with the tests.

// synthSpecies is a monsters CSV of the given rows: id, code, rarity, level,
// max HP, TypeID4.
func synthSpecies(t *testing.T, rows ...[6]string) *species.Table {
	t.Helper()
	var b strings.Builder
	b.WriteString(strings.Join(species.CSVColumns, ",") + "\n")
	for _, r := range rows {
		rec := []string{r[0], r[1], "", "0", "SN_" + r[1], "Synthetic " + r[1], r[5], r[2], r[3], r[4], "10", "40", "5"}
		for i := 0; i < species.NumParams+species.NumSkills; i++ {
			rec = append(rec, "0")
		}
		rec = append(rec, "xxx", "0", "10", "20")
		b.WriteString(strings.Join(rec, ",") + "\n")
	}
	tab, err := species.Read(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	return tab
}

const synthTactics = "dwTacticsID,dwObjID,nSightRange,btAggressType,AggressData,btChangeTarget,btTraceBoundary,TraceData,btHomingType,HomingData,btAggressTypeOnHoming,btFleeType,dwChampionTacticsID,AdditionOptionFlag\n" +
	"1,7001,115,1,0,2,1,500,1,0,1,0,2,0\n" +
	"2,7001,130,0,0,2,1,500,0,0,1,0,0,0\n" +
	"3,9001,100,0,0,2,1,500,0,0,1,0,0,0\n" +
	"4,7002,150,0,0,2,1,450,0,0,1,0,0,0\n"

const synthNests = "dwNestID,dwHiveID,dwTacticsID,nRegionDBID,fLocalPosX,fLocalPosY,fLocalPosZ,wInitialDir,nRadius,nGenerateRadius,nChampionGenPercentage,dwDelayTimeMin,dwDelayTimeMax,dwMaxTotalCount,btFlag,btRespawn,btType\n" +
	"11,50,1,25000,960,0,960,0,700,600,10,1,3,6,0,1,0\n" +
	"12,51,3,25000,100,0,100,0,350,100,10,2,3,3,0,1,0\n"

const synthHives = "dwHiveID,btKeepMonsterCountType,dwOverwriteMaxTotalCount,fMonsterCountPerPC,dwSpawnSpeedIncreaseRate,dwMaxIncreaseRate,btFlag,GameWorldID,HatchObjType\n" +
	"50,0,120,0,0,0,0,1,2\n51,0,0,0,0,0,0,1,2\n"

func synthDB(t *testing.T) *nest.DB {
	t.Helper()
	tac, err := nest.ReadTactics(strings.NewReader(synthTactics))
	if err != nil {
		t.Fatal(err)
	}
	ns, err := nest.ReadNests(strings.NewReader(synthNests))
	if err != nil {
		t.Fatal(err)
	}
	hs, err := nest.ReadHives(strings.NewReader(synthHives))
	if err != nil {
		t.Fatal(err)
	}
	return nest.NewDB(tac, ns, hs)
}

func synthWorld(t *testing.T) (spawn.Table, *species.Table) {
	tab := synthSpecies(t,
		[6]string{"7001", "MOB_SYN_A", "0", "30", "500", "1"},
		[6]string{"7002", "MOB_SYN_B", "0", "5", "100", "1"},
		[6]string{"7003", "MOB_SYN_UNIQUE", "3", "110", "90000", "1"},
		[6]string{"9001", "MOB_ETERNITY_SYN", "0", "90", "9000", "1"},
	)
	npcs := spawn.Table{
		7001: {{ObjectID: 7001, RegionID: 25000, LocalX: 960, LocalZ: 960}}, // nest 11: matched
		7002: {{ObjectID: 7002, RegionID: 25000, LocalX: 100, LocalZ: 100}, // nest 12 names 9001: swapped, own row 4
			{ObjectID: 7002, RegionID: -32767, LocalX: 1, LocalZ: 1}}, // a dungeon row
		7003: {{ObjectID: 7003, RegionID: 25000, LocalX: 500, LocalZ: 500}}, // a unique: round 661
	}
	return npcs, tab
}

// Without the DB files every field row is a stand-in nest: one monster, the
// 10 s window, no spread, the stand-in behaviour; the unique and the dungeon
// row are left out.
func TestFullMapWithoutDBIsStandIns(t *testing.T) {
	npcs, tab := synthWorld(t)
	slots, rep := fullMapSlots(npcs, tab, nil, nil)
	if len(slots) != 2 || rep.join.Unique != 1 || rep.join.Dungeon != 1 || rep.join.StandIn != 2 {
		t.Fatalf("%d slots, report %+v", len(slots), rep.join)
	}
	for _, sl := range slots {
		d := sl.Data.(*hatchData)
		if sl.Cap != 1 || sl.DelayMin != 10 || sl.DelayMax != 10 || sl.GenerateRadius != 0 || d.tactics != nil || sl.Hive != nil {
			t.Fatalf("stand-in slot %+v, tactics %+v", sl, d.tactics)
		}
		if d.spec.Zone != worldmap.WorldBucket {
			t.Fatalf("zone %q, want the one world bucket", d.spec.Zone)
		}
	}
	var d *hatchData
	for _, sl := range slots {
		if x := sl.Data.(*hatchData); x.spec.RefObjID == 7001 {
			d = x
		}
	}
	if wx, wz := worldmap.ToWorld(97, 168, 960, 960, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1]); d.homeX != wx || d.homeZ != wz {
		t.Fatalf("home (%.1f, %.1f), want region 97/168's (%.1f, %.1f)", d.homeX, d.homeZ, wx, wz)
	}
}

// With the DB: the matched row takes its nest (window, cap, generate radius,
// champion chance, capped hive) and its tactics with the nest's radius, and
// its champion row; the swapped row places the npcpos species under its own
// row, on its DB nest's numbers (round 660's review; the stand-in only under
// -nest-swapped-stand-in, TestSwappedSpotTakesItsNest).
func TestFullMapTakesTheDBNest(t *testing.T) {
	npcs, tab := synthWorld(t)
	slots, rep := fullMapSlots(npcs, tab, nil, synthDB(t))
	if len(slots) != 2 || rep.join.Matched != 1 || rep.join.SwappedOwn != 1 || rep.cappedHives != 1 || rep.capTotal != 9 {
		t.Fatalf("%d slots, report %+v %+v", len(slots), rep, rep.join)
	}
	var matched, swapped *nest.Slot
	for _, sl := range slots {
		if sl.ID == 11 {
			matched = sl
		} else {
			swapped = sl
		}
	}
	d := matched.Data.(*hatchData)
	if matched.Cap != 6 || matched.DelayMin != 1 || matched.DelayMax != 3 || matched.GenerateRadius != 600 ||
		matched.Input.ChampionPct != 10 || !matched.Input.HasChampionTactics || matched.Hive == nil || matched.Hive.TotalCap != 120 || matched.Level != 30 {
		t.Fatalf("matched slot %+v", matched)
	}
	if d.tactics == nil || d.tactics.ID != 1 || d.tactics.AggressType != 1 || d.tactics.SightRange != 115 || d.tactics.RoamRadius != 700 || d.tactics.HomingType != 1 {
		t.Fatalf("matched tactics %+v", d.tactics)
	}
	if d.champion == nil || d.champion.ID != 2 || d.champion.AggressType != 0 || d.champion.RoamRadius != 700 {
		t.Fatalf("champion tactics %+v", d.champion)
	}
	ds := swapped.Data.(*hatchData)
	if swapped.ID != 12 || swapped.Cap != 3 || swapped.DelayMin != 2 || ds.tactics == nil || ds.tactics.ID != 4 || ds.tactics.TraceData != 450 ||
		ds.tactics.RoamRadius != 350 || ds.spec.RefObjID != 7002 || swapped.Input.HasChampionTactics || swapped.Hive != nil {
		t.Fatalf("swapped slot %+v, tactics %+v", swapped, ds.tactics)
	}
	// densest: one nest's 6 -- the two synthetic nests stand 1,216 apart, and
	// retail's 3 x 3 message-block window (960 wide, round 664) never holds
	// both (it did the 5 x 5 regions before).
	if rep.passive != 1 || rep.aggressive != 1 || rep.standIn != 0 || rep.densest != 6 {
		t.Fatalf("report %+v", rep)
	}
}

// A hatch makes the monster the roll says: a champion runs under the champion
// row at x2 HP, a giant at x20, a party monster at x10 more; a champion roll
// whose row does not exist leaves the rank cleared under the own row; the home
// is the nest and the monster stands the offset away.
func TestHatchMakesTheRolledMonster(t *testing.T) {
	npcs, tab := synthWorld(t)
	slots, _ := fullMapSlots(npcs, tab, nil, synthDB(t))
	var matched *nest.Slot
	for _, sl := range slots {
		if sl.ID == 11 {
			matched = sl
		}
	}
	monsters := combat.NewHub()
	s := newRespawnScheduler(monsters, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	s.quiet = true
	get := func(roll nest.HatchRoll, dx, dz float64) combat.Monster {
		t.Helper()
		id, ok, _ := s.hatch(matched, roll, dx, dz)
		m, alive := monsters.Get(id)
		if !ok || !alive {
			t.Fatal("no monster hatched")
		}
		return m
	}
	d := matched.Data.(*hatchData)
	m := get(nest.HatchRoll{Class: 1, Champion: true}, 30, -40)
	if m.Rarity != 1 || m.MaxHP != 1000 || m.Tactics != d.champion || m.Party {
		t.Fatalf("champion %+v", m)
	}
	if m.HomeX != d.homeX || m.HomeZ != d.homeZ || math.Abs(m.X-(d.homeX+30)) > 1e-9 || math.Abs(m.Z-(d.homeZ-40)) > 1e-9 {
		t.Fatalf("champion at (%.1f, %.1f) home (%.1f, %.1f), nest (%.1f, %.1f)", m.X, m.Z, m.HomeX, m.HomeZ, d.homeX, d.homeZ)
	}
	if g := get(nest.HatchRoll{Class: 4, Champion: true}, 0, 0); g.Rarity != 4 || g.MaxHP != 10000 {
		t.Fatalf("giant %+v", g)
	}
	if p := get(nest.HatchRoll{Class: nest.ClassParty}, 0, 0); !p.Party || p.Rarity != 0 || p.MaxHP != 5000 || p.Tactics != d.tactics {
		t.Fatalf("party monster %+v", p)
	}
	noRow := *d
	noRow.champion = nil
	matched.Data = &noRow
	if c := get(nest.HatchRoll{Class: nest.ClassParty | 1, Champion: true}, 0, 0); c.Rarity != 0 || !c.Party || c.Tactics != d.tactics {
		t.Fatalf("a champion roll without its row: %+v", c)
	}
}

// The full map runs through the one scheduler: a matched nest refills to its
// cap one monster a pass, each after its window; the -nest-respawn override
// replaces the window.
func TestFullMapNestsRefill(t *testing.T) {
	npcs, tab := synthWorld(t)
	slots, _ := fullMapSlots(npcs, tab, nil, synthDB(t))
	monsters := combat.NewHub()
	s := newRespawnScheduler(monsters, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	s.quiet = true
	s.delayOverride = 5 * time.Second
	for _, sl := range slots {
		s.addSlot(sl)
	}
	t0 := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	s.check(t0)
	if monsters.Count() != 2 {
		t.Fatalf("first pass: %d alive, want one per nest", monsters.Count())
	}
	for i := 1; i <= 10; i++ {
		s.check(t0.Add(time.Duration(i) * 5 * time.Second))
	}
	if monsters.Count() != 9 {
		t.Fatalf("after 50 s at a 5 s window: %d alive, want the caps' 6 + 3", monsters.Count())
	}
	for _, sl := range slots {
		if sl.DelayMin != 5 || sl.DelayMax != 5 {
			t.Fatalf("the override left a window of %d..%d s", sl.DelayMin, sl.DelayMax)
		}
	}
}

// Round 660's review: a -nest-respawn under 1 s would round to a 0 s window
// and re-hatch every nest each pass; it is refused.
func TestNestRespawnUnderASecondIsRefused(t *testing.T) {
	for _, c := range []struct {
		d  time.Duration
		ok bool
	}{{0, true}, {time.Second, true}, {30 * time.Second, true}, {500 * time.Millisecond, false}, {-time.Second, false}} {
		if err := checkNestRespawn(c.d); (err == nil) != c.ok {
			t.Errorf("checkNestRespawn(%v) = %v, want ok %v", c.d, err, c.ok)
		}
	}
}

// Round 660's review, the user's decision on the swapped spots: a spot whose
// shard nest was repointed keeps the npcpos species (and its own tactics row,
// or the stand-in behaviour) but takes that nest's cap, respawn window, radii
// and champion chance (EXTERNAL), the champion roll gated by the col 41 of the
// row the monster runs. Before, it was a one-monster stand-in.
func TestSwappedSpotTakesItsNest(t *testing.T) {
	tab := synthSpecies(t,
		[6]string{"7004", "MOB_SYN_OWN", "0", "40", "800", "1"},
		[6]string{"7005", "MOB_SYN_NOROW", "0", "40", "800", "1"},
		[6]string{"9001", "MOB_ETERNITY_SYN", "0", "90", "9000", "1"},
	)
	tac, err := nest.ReadTactics(strings.NewReader(synthTactics[:strings.Index(synthTactics, "\n")+1] +
		"3,9001,100,0,0,2,1,500,0,0,1,0,0,0\n5,7004,120,1,0,2,1,480,0,0,1,0,6,0\n6,7004,120,0,0,2,1,480,0,0,1,0,0,0\n"))
	if err != nil {
		t.Fatal(err)
	}
	ns, err := nest.ReadNests(strings.NewReader(synthNests[:strings.Index(synthNests, "\n")+1] +
		"21,51,3,25000,300,0,300,0,450,250,20,4,6,5,0,1,0\n22,51,3,25000,700,0,700,0,350,150,10,1,3,7,0,1,0\n"))
	if err != nil {
		t.Fatal(err)
	}
	db := nest.NewDB(tac, ns, nil)
	npcs := spawn.Table{
		7004: {{ObjectID: 7004, RegionID: 25000, LocalX: 300, LocalZ: 300}},
		7005: {{ObjectID: 7005, RegionID: 25000, LocalX: 700, LocalZ: 700}},
	}
	slots, rep := fullMapSlots(npcs, tab, nil, db)
	if len(slots) != 2 || rep.capTotal != 12 {
		t.Fatalf("%d slots, max alive %d; want 2 slots holding their nests' 5 + 7", len(slots), rep.capTotal)
	}
	for _, sl := range slots {
		d := sl.Data.(*hatchData)
		switch d.spec.RefObjID {
		case 7004:
			if sl.Cap != 5 || sl.DelayMin != 4 || sl.DelayMax != 6 || sl.GenerateRadius != 250 || sl.Input.ChampionPct != 20 ||
				!sl.Input.HasChampionTactics || d.tactics == nil || d.tactics.ID != 5 || d.tactics.RoamRadius != 450 ||
				d.champion == nil || d.champion.ID != 6 {
				t.Fatalf("the swapped spot with its own row: slot %+v, tactics %+v, champion %+v", sl, d.tactics, d.champion)
			}
		case 7005:
			if sl.Cap != 7 || sl.DelayMin != 1 || sl.DelayMax != 3 || sl.Input.ChampionPct != 10 || sl.Input.HasChampionTactics || d.tactics != nil {
				t.Fatalf("the swapped spot with no row: slot %+v, tactics %+v -- its nest's numbers, the stand-in behaviour, no champion row", sl, d.tactics)
			}
		default:
			t.Fatalf("placed species %d", d.spec.RefObjID)
		}
	}
}

// The fallback (OURS): -nest-swapped-stand-in puts the swapped spots back on
// the one-monster stand-in nest.
func TestSwappedStandInFlag(t *testing.T) {
	npcs, tab := synthWorld(t)
	nestSwappedStandIn = true
	t.Cleanup(func() { nestSwappedStandIn = false })
	slots, rep := fullMapSlots(npcs, tab, nil, synthDB(t))
	for _, sl := range slots {
		if d := sl.Data.(*hatchData); d.spec.RefObjID == 7002 && (sl.Cap != 1 || sl.DelayMin != 10 || sl.ID != 0 || d.tactics == nil) {
			t.Fatalf("stand-in swapped slot %+v", sl)
		}
	}
	if rep.capTotal != 7 || rep.swappedOnNest != 0 {
		t.Fatalf("max alive %d, swapped on a nest %d; want 6 + 1 and none", rep.capTotal, rep.swappedOnNest)
	}
}
